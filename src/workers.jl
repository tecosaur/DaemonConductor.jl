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
    id::Int
    ctime::DateTime
    process::Base.Process
    socket::Sockets.PipeServer
    connection::Base.PipeEndpoint
    output::IOBuffer
    lock::ReentrantLock
end

const WORKER_ENV_DIR = string("julia-daemon-", replace(string(PACKAGE_VERSION), '.' => '-'), "-worker-env")
const WORKER_ENV = Ref{String}()
const WORKER_PKGDIR = joinpath(dirname(@__DIR__), "worker")

function ensure_worker_env()
    if !isassigned(WORKER_ENV)
        WORKER_ENV[] = BaseDirs.cache(WORKER_ENV_DIR)
    end
    isdir(WORKER_ENV[]) || mkpath(WORKER_ENV[])
    jlcmd = get(ENV, "JULIA_DAEMON_WORKER_EXECUTABLE", joinpath(Sys.BINDIR, "julia"))
    action = :(Pkg.develop(path=$WORKER_PKGDIR))
    success(`$jlcmd --startup-file=no --project=$(WORKER_ENV[]) -e "using Pkg; $action"`) ||
        error("Failed to set up worker environment")
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
    worker_command(socketpath::AbstractString)
Create a `Cmd` that can serve as a worker process that communicates on `socketpath`.
"""
function worker_command(socketpath::AbstractString)
    cmd = get(ENV, "JULIA_DAEMON_WORKER_EXECUTABLE", joinpath(Sys.BINDIR, "julia"))
    args = split(get(ENV, "JULIA_DAEMON_WORKER_ARGS", "--startup-file=no"))
    action = :(DaemonWorker.runworker($socketpath))
    if !isassigned(WORKER_ENV)
        WORKER_ENV[] = BaseDirs.cache(WORKER_ENV_DIR)
    end
    Cmd(`$cmd --project=$(WORKER_ENV[]) $args --eval "using DaemonWorker; $action"`, env=julia_env())
end

const WORKER_COUNT = Ref(0)

"""
    Worker(project)

Create a `Worker` using the project `project`, where `project` is a
valid argument for `worker_command`.
"""
function Worker(project::Union{String, Nothing}=nothing)
    socketpath =
        BaseDirs.runtime(RUNTIME_DIR, string("wsetup-", String(rand('a':'z', 6)), ".sock"))
    isdir(dirname(socketpath)) || mkpath(dirname(socketpath))
    server = Sockets.listen(socketpath)
    input = Base.PipeEndpoint()
    output = IOBuffer()
    process = run(pipeline(worker_command(socketpath),
                           stdin=input, stdout=output, stderr=output),
                  wait=false)
    connection = accept(server)
    rm(socketpath) # No longer needed once the connection is active.
    worker = Worker((WORKER_COUNT[] += 1), now(),
                    process, server, connection, output,
                    ReentrantLock())
    run(worker, :(set_project($project)))
    worker
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
function Base.run(worker::Worker, expr::Union{Expr, Symbol})
    lock(worker) do
        serialize(worker.connection, (:eval, expr))
        deserialize(worker.connection)
    end
end

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
        @log "Reserve worker#$(w.id) initialised"
    end
end

# The Worker Pool

struct WorkerPool
    workers::Dict{String, Vector{Worker}}
end

Base.haskey(pool::WorkerPool, key::AbstractString) =
    haskey(pool.workers, key)
Base.keys(pool::WorkerPool) = keys(pool.workers)
Base.values(pool::WorkerPool) = collect(values(pool.workers) |> Iterators.flatten)
Base.length(pool::WorkerPool) = length(pool.workers)
Base.iterate(pool::WorkerPool) = iterate(pool.workers)
Base.iterate(pool::WorkerPool, index::Int) = iterate(pool.workers, index)
function Base.delete!(pool::WorkerPool, project::AbstractString)
    kill.(pool.workers[project])
    delete!(pool.workers, project)
end

function Base.getindex(pool::WorkerPool, project::AbstractString)
    if haskey(pool.workers, project)
        for worker in pool.workers[project]
            if process_exited(worker.process)
                @log "Worker#$(worker.id) for $project has died"
            end
        end
        filter!(w -> !process_exited(w.process), pool.workers[project])
        if isempty(pool.workers[project])
            @log "All workers for $project have died"
            delete!(pool.workers, project)
        end
    end
    if haskey(pool.workers, project)
        if WORKER_MAXCLIENTS[] == 0 && !isempty(pool.workers[project])
            return first(pool.workers[project])
        end
        for worker in pool.workers[project]
            nclients = run(worker, :(length(STATE.clients)))
            nclients = run(worker, :(length(STATE.clients)))
            if nclients < WORKER_MAXCLIENTS[]
                return worker
            end
        end
        @log "All $(length(pool.workers[project])) workers have the maximum number of clients"
    else
        pool.workers[project] = Worker[]
    end
    if !isnothing(RESERVE_WORKER[])
        worker = RESERVE_WORKER[]
        @log "Using reserve worker#$(worker.id) for $project"
        push!(pool.workers[project], worker)
        RESERVE_WORKER[] = nothing
        lock(worker) do
            run(worker, :(set_project($project)))
        end
        @async create_reserve_worker()
        worker
    else
        worker = Worker(project)
        push!(pool.workers[project], worker)
        @log "Created new worker#$(worker.id) for $project"
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
