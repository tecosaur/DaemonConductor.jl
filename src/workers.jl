julia_env() =
    [key => value for (key, value) in ENV
         if startswith(key, "JULIA_")]

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
    worker_command(project)
Create a `Cmd` that can serve as a worker process for `project`.
"""
function worker_command(project)
    cmd = get(ENV, "JULIA_DAEMON_WORKER_EXECUTABLE", joinpath(Sys.BINDIR, "julia"))
    args = split(get(ENV, "JULIA_DAEMON_WORKER_ARGS", "--startup-file=no"))
    Cmd(`$cmd --project=$project $args`, env=julia_env())
end

"""
    Worker(project)

Create a `Worker` using the project `project` (a path).
"""
function Worker(project)
    input = Base.PipeEndpoint()
    output = IOBuffer()
    process = run(pipeline(worker_command(project),
                           stdin=input, stdout=output, stderr=output),
                  wait=false)
    write(input, WORKER_INIT_CODE, '\n')
    socketpath =
        XDG.User.runtime(string("julia--worker-", String(rand('a':'z', 6)), ".sock"))
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

# The Worker Pool

struct WorkerPool
    workers::Dict{String, Worker}
end

Base.haskey(wp::WorkerPool, key::AbstractString) =
    haskey(wp.workers, key)
Base.getindex(wp::WorkerPool, key::AbstractString) =
    getindex(wp.workers, key)
Base.setindex!(wp::WorkerPool, worker::Worker, key::AbstractString) =
    setindex!(wp.workers, worker, key)
Base.keys(wp::WorkerPool) = keys(wp.workers)
Base.values(wp::WorkerPool) = values(wp.workers)
Base.length(wp::WorkerPool) = length(wp.workers)
Base.iterate(wp::WorkerPool) = iterate(wp.workers)
Base.iterate(wp::WorkerPool, index::Int) = iterate(wp.workers, index)
function Base.delete!(wp::WorkerPool, key::AbstractString)
    worker = wp[key]
    kill(worker)
    delete!(wp.workers, key)
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
function runclient(client::Client)
    project = projectpath(client)
    if haskey(WORKER_POOL, project) && process_exited(WORKER_POOL[project].process)
        @info "Worker for $project has died"
        delete!(WORKER_POOL, project)
    end
    if !haskey(WORKER_POOL, project)
        @info "Creating new worker for $project"
        WORKER_POOL[project] = Worker(project)
    end
    runclient(WORKER_POOL[project], client)
end
