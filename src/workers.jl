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

"""
A string of Julia code which configures a new Julia process
to function as a worker.
"""
WORKER_INIT_CODE = quote # TODO make const
    using Sockets
    using Serialization
    using Base.Threads
    using REPL

    # Use Revise.jl if possible
    const revise_pkg = Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")
    if !isnothing(Base.locate_package(revise_pkg))
        using Revise
    end

    const CTIME = time()

    const BASE_OPTIONS = NamedTuple{fieldnames(Base.JLOptions)}(
        ((getfield(Base.JLOptions(), name) for name in fieldnames(Base.JLOptions))...,))

    # * Set up REPL-related overrides
    # Within `REPL`, `check_open` is called on our `stdout` IOContext,
    # and we need to add this method to make it work.
    # Core.eval(mod, :(Base.check_open(ioc::IOContext) = Base.check_open(ioc.io)))
    # With `REPL.Terminals.raw!`, there are to invocations incompatable
    # with an `IOContext`: `check_open` and `.handle`. However, `raw!` isn't
    # able to work normally anyway, so we may as well override it.
    REPL.Terminals.raw!(t::REPL.TTYTerminal, raw::Bool) = raw

    # Client evaluation

    function prepare_module(client::NamedTuple)
        mod = Module()
        Core.eval(mod, :(struct SystemExit <: Exception code::Int end))
        Core.eval(mod, :(exit() = throw(SystemExit(0))))
        Core.eval(mod, :(exit(n) = throw(SystemExit(n))))
        Core.eval(mod, :(cd($client.cwd)))
        if !isempty(client.args)
            Core.eval(mod, :(ARGS = $(client.args)))
        end
        mod
    end

    const CLIENTS = Vector{Tuple{NamedTuple, Task}}()

    # Basically a bootleg version of `exec_options`.
    function runclient(client::NamedTuple, stdio, signals)
        function getval(pairlist, key, default)
            index = findfirst(p -> first(p) == key, pairlist)
            if isnothing(index) default else last(pairlist[index]) end
        end
        signal_exit(n) = write(signals, "\x01exit\x02", string(n), "\x04")
        runrepl = client.tty && ("-i" ∈ client.switches ||
            (isnothing(client.programfile) && "--eval" ∉ first.(client.switches) &&
            "--print" ∉ first.(client.switches)))
        hascolor = getval(client.switches, "--color",
                          ifelse(startswith(getval(client.env, "TERM", ""),
                                            "xterm"),
                                 "yes", "")) == "yes"
        stdiox = IOContext(stdio, :color => hascolor)
        try
            withenv(client.env...) do
                redirect_stdio(stdin=stdiox, stdout=stdiox, stderr=stdiox) do
                    mod = prepare_module(client)
                    for (switch, value) in client.switches
                        if switch == "--eval"
                            Core.eval(mod, Base.parse_input_line(value))
                        elseif switch == "--print"
                            res = Core.eval(mod, Base.parse_input_line(value))
                            Base.invokelatest(show, res)
                            println()
                        elseif switch == "--load"
                            Base.include(mod, value)
                        end
                    end
                    if !isnothing(client.programfile)
                        try
                            if client.programfile == "-"
                                Base.include_string(mod, read(stdin, String), "stdin")
                            else
                                Base.include(mod, client.programfile)
                            end
                        catch
                            Core.eval(mod, quote
                                          Base.invokelatest(
                                              Base.display_error,
                                              Base.scrub_repl_backtrace(
                                                  current_exceptions()))
                                          if !$(runrepl)
                                              exit(1)
                                          end
                                      end)
                        end
                    end
                    if runrepl
                        quiet = "-q" in first.(client.switches) || "--quiet" in first.(client.switches)
                        banner = getval(client.switches, "--banner", "yes") != "no"
                        histfile = getval(client.switches, "--history-file", "yes") != "no"
                        Core.eval(mod, quote
                                      Core.eval(Base, $(:(have_color = $hascolor)))
                                      Base.run_main_repl(true, $quiet, $banner, $histfile, $hascolor)
                                  end)
                    end
                    signal_exit(0)
                end
            end
        catch err
            etype = typeof(err)
            if nameof(etype) == :SystemExit && parentmodule(etype) == m
                signal_exit(err.code)
            elseif isopen(stdio)
                # TODO trim the stacktrace
                Base.invokelatest(
                    Base.display_error,
                    stdiox,
                    Base.scrub_repl_backtrace(
                        current_exceptions()))
                signal_exit(1)
            end
            close(stdio)
        end
    end

    # Worker management

    function newconnection(oldconn, n::Int=1)
        try
            map(1:n) do _
                path = joinpath("/run/user/1000", string("julia--", String(rand('a':'z', 16)), ".sock"))
                server = Sockets.listen(path)
                serialize(oldconn, (:socket, path))
                server
            end .|> accept
        catch err
            if err isa InterruptException # Can occur when client disconnects partway through
                @info "Interrupt during connection setup"
                fill(nothing, n)
            else
                rethrow(err)
            end
        end
    end

    function runworker(socketpath)
        conn = Sockets.connect(socketpath)
        while ((signal, msg) = deserialize(conn)) |> !isnothing
            if signal == :client
                stdio, signals = newconnection(conn, 2)
                !isnothing(signals) &&
                    Threads.@spawn runclient(msg, stdio, signals)
            elseif signal == :eval
                serialize(conn, Base.eval(msg))
            else
                println(conn, "Unknown signal: $signal")
            end
        end
    end
end |> string

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
