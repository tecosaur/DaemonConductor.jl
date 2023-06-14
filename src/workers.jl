"""
Worker

A wrapper around a Julia process used for execution in a particular project.

In a threaded context, interaction with the worker should make use of the
provided lock, like so:

```julia
lock(worker) do
  # Interact with the socket, output, or similar.
end
```
"""
struct Worker
    ctime::DateTime
    process::Base.Process
    socket::Sockets.PipeServer
    connection::Base.PipeEndpoint
    output::IOBuffer
    lock::ReentrantLock
end

"""
    julia_env()
Return a `Vector{Pair{String, String}}` of all `JULIA_*` env vars.
"""
function julia_env()
    [key => value for (key, value) in ENV
         if startswith(key, "JULIA_")]
end

"""
    worker_command(project::AbstractString)
Create a `Cmd` that can serve as a worker process for `project`.
"""
function worker_command(project::AbstractString)
    cmd = get(ENV, "JULIA_DAEMON_WORKER_EXECUTABLE", joinpath(Sys.BINDIR, "julia"))
    args = split(get(ENV, "JULIA_DAEMON_WORKER_ARGS", "--startup-file=no"))
    Cmd(`$cmd --project=$project $args`, env=julia_env())
end

"""
    worker_command(nothing)
Create a `Cmd` that serves as a project-less worker process.
"""
function worker_command(::Nothing)
    cmd = get(ENV, "JULIA_DAEMON_WORKER_EXECUTABLE", joinpath(Sys.BINDIR, "julia"))
    args = split(get(ENV, "JULIA_DAEMON_WORKER_ARGS", "--startup-file=no"))
    env = julia_env() |> Dict
    no_project_default_load_path =
        join(("@v#.#", "@stdlib"), (@static if Sys.iswindows() ';' else ':' end))
    env["JULIA_LOAD_PATH"] = if haskey(env, "JULIA_LOAD_PATH")
        replace(env["JULIA_LOAD_PATH"], r"^:|:$" => no_project_default_load_path)
    else no_project_default_load_path end
    Cmd(`$cmd $args`; env)
end

"""
    Worker(project)

Create a `Worker` using the project `project`, where `project` is a
valid argument for `worker_command`.
"""
function Worker(project)
    input = Base.PipeEndpoint()
    output = IOBuffer()
    process = run(pipeline(worker_command(project),
                           stdin=input, stdout=output, stderr=output),
                  wait=false)
    write(input, WORKER_INIT_CODE, '\n')
    socketpath =
        BaseDirs.User.runtime(string("julia--worker-", String(rand('a':'z', 6)), ".sock"))
    server = Sockets.listen(socketpath)
    write(input, :(runworker($socketpath)) |> string, '\n')
    connection = accept(server)
    rm(socketpath) # No longer needed once the connection is active.
    Worker(now(), process, server, connection, output, ReentrantLock())
end

Base.lock(w::Worker) = lock(w.lock)
Base.lock(f::Function, w::Worker) = lock(f, w.lock)

"""
    kill(worker::Worker)
Kill the Julia process of `worker` and close the communication socket.
"""
function Base.kill(worker::Worker)
    lock(worker) do
        close(worker.socket)
        kill(worker.process)
    end
end

"""
    run(worker::Worker, expr::Union{Expr, Symbol})
Run `expr` on `worker`, and return the result.
"""
Base.run(worker::Worker, expr::Union{Expr, Symbol}) =
    lock(worker) do
        serialize(worker.connection, (:eval, expr))
        deserialize(worker.connection)
    end

# TODO Find a better way to do this, ideally one
# that reduces the compile time. Is it possible
# to precompile a script file? Perhaps a single
# worker with an 'unset' project could be pre-emptively
# started, is this possible?
"""
A string of Julia code which configures a new Julia process
to function as a worker.
"""
const WORKER_INIT_CODE = read(joinpath(@__DIR__, "worker_setup.jl"), String)

# Reserve worker

"""
An uninitialised worker, that can be easily repurposed for a particular project.
"""
const RESERVE_WORKER = Ref{Union{Worker, Nothing}}(nothing)

"""
    dummyclient(w::Worker)
Simulate a client connecting to `w` to execute `nothing`, then disconnecting.
"""
function dummyclient(worker::Worker)
    noclient = Client(false, 0, @__DIR__, Pair{String, String}[],
                      [("-e", "nothing")], nothing, String[])
    stdio_sock, signals_sock = runclient(worker, noclient)
    stdio = Sockets.connect(stdio_sock)
    signals = Sockets.connect(signals_sock)
    sleep(0.01)
    close(stdio); close(signals)
end

"""
    create_reserve_worker()
When `RESERVE_WORKER[]` is `nothing`, create an uninitialised worker
and do a dry-run with `dummyclient` to compile the client-execution path,
and set `RESERVE_WORKER[]` to this new worker.
"""
function create_reserve_worker()
    @log "Creating reserve worker"
    if isnothing(RESERVE_WORKER[])
        w = Worker(nothing)
        dummyclient(w)
        RESERVE_WORKER[] = w
        @log "Reserve worker initialised"
    end
end

# The Worker Pool

struct WorkerPool
    workers::Dict{String, Worker}
end

Base.haskey(pool::WorkerPool, key::AbstractString) =
    haskey(pool.workers, key)
Base.keys(pool::WorkerPool) = keys(pool.workers)
Base.values(pool::WorkerPool) = values(pool.workers)
Base.length(pool::WorkerPool) = length(pool.workers)
Base.iterate(pool::WorkerPool) = iterate(pool.workers)
Base.iterate(pool::WorkerPool, index::Int) = iterate(pool.workers, index)
function Base.delete!(pool::WorkerPool, project::AbstractString)
    worker = pool.workers[project]
    kill(worker)
    delete!(pool.workers, project)
end

function Base.getindex(pool::WorkerPool, project::AbstractString)
    if haskey(pool.workers, project) && process_exited(pool.workers[project].process)
        @log "Worker for $project has died"
        close(pool.workers[project].socket)
        delete!(pool.workers, project)
    end
    if haskey(pool.workers, project)
        pool.workers[project]
    elseif !isnothing(RESERVE_WORKER[])
        @log "Using reserve worker"
        worker = RESERVE_WORKER[]
        pool.workers[project] = worker
        RESERVE_WORKER[] = nothing
        lock(worker) do
            run(worker, :(push!(LOAD_PATH, "@"); Base.set_active_project($project)))
        end
        @async create_reserve_worker()
        worker
    else
        worker = Worker(project)
        pool.workers[project] = worker
        worker
    end
end

"""
The Worker pool.
Workers exist on a per-project basis, and so this takes the form of a
dictionary with project paths as the keys, and workers as the values.
"""
const WORKER_POOL = WorkerPool(Dict{String, Worker}())

"""
    runclient(worker::Worker, client::Client)
Run `client` in `worker`. Returns a socket path for the client to connect to.
"""
function runclient(worker::Worker, client::Client)
    local sig1, sig2, stdio, signals
    lock(worker) do
        serialize(worker.connection, (:client, convert(NamedTuple, client)))
        sig1, stdio = deserialize(worker.connection)
        sig2, signals = deserialize(worker.connection)
    end
    if sig1 == :socket && sig2 == :socket
        stdio, signals
    else
        error("Unexpected return value from worker when trying to start client.")
    end
end

"""
    runclient(client::Client)
Find or create an appropriate worker to run `client` in,
and call `runclient(worker, client)`.
"""
runclient(client::Client) =
    runclient(WORKER_POOL[projectpath(client)], client)
