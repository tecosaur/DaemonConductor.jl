const STATE = (
    ctime = time(),
    clients = Vector{Tuple{Float64, NamedTuple}}(),
    project = Ref(""),
    lastclient = Ref(time()),
    lock = SpinLock(),
    soft_exit = Ref(false))

# Revise

const REVISE_PKG =
    Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")

function try_load_revise()
    if !isnothing(Base.locate_package(REVISE_PKG))
        Core.eval(Main, :(using Revise))
    end
end

# TTL checking

function queue_ttl_check()
    ttl = parse(Int, get(ENV, "JULIA_DAEMON_WORKER_TTL", "0"))
    if ttl > 0
        Timer(perform_ttl_check, ttl)
    end
end

function perform_ttl_check(::Timer)
    ttl = parse(Int, get(ENV, "JULIA_DAEMON_WORKER_TTL", "0"))
    if ttl > 0 && time() - lock(() -> STATE.lastclient[], STATE.lock) < ttl
        exit(0)
    end
end

# * Set up REPL-related overrides
# Within `REPL`, `check_open` is called on our `stdout` IOContext,
# and we need to add this method to make it work.
# Core.eval(mod, :(Base.check_open(ioc::IOContext) = Base.check_open(ioc.io)))

# Client evaluation

function prepare_module(client::NamedTuple)
    mod = Module(:Main)
    # MainInclude (taken from base/client.jl)
    maininclude = quote
        baremodule MainInclude
        using ..Base
        include(mapexpr::Function, fname::AbstractString) = Base._include(mapexpr, $mod, fname)
        function include(fname::AbstractString)
            isa(fname, String) || (fname = Base.convert(String, fname)::String)
            Base._include(identity, $mod, fname)
        end
        eval(x) = Core.eval($mod, x)
        end
        import .MainInclude: eval, include
    end
    maininclude.head = :toplevel # Module must be in a :toplevel Expr.
    Core.eval(mod, maininclude)
    # Exit
    Core.eval(mod, :(struct SystemExit <: Exception code::Int end))
    Core.eval(mod, :(exit() = throw(SystemExit(0))))
    Core.eval(mod, :(exit(n) = throw(SystemExit(n))))
    # State
    Core.eval(mod, :(cd($client.cwd)))
    if !isempty(client.args)
        Core.eval(mod, :(ARGS = $(client.args)))
    end
    if getval(client.switches, "--revise", get(ENV, "JULIA_DAEMON_REVISE", "no")) ∈ ("yes", "true", "1", "")
        if isdefined(Main, :Revise)
            Main.Revise.revise()
        end
    end
    mod
end

function getval(pairlist, key, default)
    index = findfirst(p -> first(p) == key, pairlist)
    if isnothing(index) default else last(pairlist[index]) end
end

# Basically a bootleg version of `exec_options`.
function runclient(client::NamedTuple, stdio::Base.PipeEndpoint, signals::Base.PipeEndpoint)
    signal_exit(n) = write(signals, "\x01exit\x02", string(n), "\x04")

    lock(STATE.lock) do
        push!(STATE.clients, (time(), client))
    end

    hascolor = getval(client.switches, "--color",
                        ifelse(startswith(getval(client.env, "TERM", ""),
                                        "xterm"),
                                "yes", "")) == "yes"
    stdiox = IOContext(stdio, :color => hascolor)
    mod = prepare_module(client)

    try
        withenv(client.env...) do
            redirect_stdio(stdin=stdiox, stdout=stdiox, stderr=stdiox) do
                runclient(mod, client; signal_exit, stdout=stdiox)
            end
        end
    catch err
        etype = typeof(err)
        if nameof(etype) == :SystemExit && parentmodule(etype) == mod
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
    finally
        lock(STATE.lock) do
            client_index = findfirst(e -> last(e) === client, STATE.clients)::Int
            deleteat!(STATE.clients, client_index)
            STATE.lastclient[] = time()
            if STATE.soft_exit[]
                exit(0)
            end
        end
        queue_ttl_check()
    end
end

function runclient(mod::Module, client::NamedTuple; signal_exit::Function, stdout::IO=stdout)
    runrepl = "-i" ∈ client.switches ||
        (isnothing(client.programfile) && "--eval" ∉ first.(client.switches) &&
         "--print" ∉ first.(client.switches))
    for (switch, value) in client.switches
        if switch == "--eval"
            Core.eval(mod, Base.parse_input_line(value))
        elseif switch == "--print"
            res = Core.eval(mod, Base.parse_input_line(value))
            Base.invokelatest(show, stdout, res)
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
        interactiveinput = runrepl && client.tty
        hascolor = get(stdout, :color, false)
        quiet = "-q" in first.(client.switches) || "--quiet" in first.(client.switches)
        banner = Symbol(getval(client.switches, "--banner", ifelse(interactiveinput, "yes", "no")))
        histfile = getval(client.switches, "--history-file", "yes") != "no"
        replcall = if VERSION < v"1.11"
            :(Base.run_main_repl($interactiveinput, $quiet, $(banner != :no), $histfile, $hascolor))
        elseif VERSION < v"1.12"
            :(Base.run_main_repl($interactiveinput, $quiet, $(QuoteNode(banner)), $histfile, $hascolor))
        else
            :(Base.run_main_repl($interactiveinput, $quiet, $(QuoteNode(banner)), $histfile))
        end
        Core.eval(mod, quote
                      setglobal!(Base, :have_color, $hascolor)
                      $replcall
                    end)
    end
    signal_exit(0)
end

# Copied from `init_active_project()` in `base/initdefs.jl`.
function set_project(project)
    Base.set_active_project(
        project === nothing ? nothing :
        project == "" ? nothing :
        startswith(project, "@") ? load_path_expand(project) :
        abspath(expanduser(project)))
end

# Worker management

function newconnection(oldconn::Base.PipeEndpoint, n::Int=1)
    try
        servers = Sockets.PipeServer[]
        for i in 1:n
            sockfile = string("worker-", WORKER_ID[], '-',
                              String(rand('a':'z', 8)), ".sock")
            path = BaseDirs.runtime("julia-daemon", sockfile)
            push!(servers, Sockets.listen(path))
            serialize(oldconn, (:socket, path))
        end
        map(accept, servers)
    catch err
        if err isa InterruptException # Can occur when client disconnects partway through
            @info "Interrupt during connection setup"
            fill(nothing, n)
        else
            rethrow(err)
        end
    end
end

function runworker(socketpath::String)
    conn = Sockets.connect(socketpath)
    while ((signal, msg) = deserialize(conn)) |> !isnothing
        if signal == :client
            stdio, signals = newconnection(conn, 2)
            !isnothing(signals) &&
                Threads.@spawn runclient($msg, $stdio, $signals)
        elseif signal == :eval
            serialize(conn, Core.eval(@__MODULE__, msg))
        elseif signal == :softexit # Exit when all clients complete
            lock(STATE.lock) do
                if isempty(STATE.clients)
                    exit(0)
                else
                    STATE.soft_exit[] = true
                end
            end
        else
            println(conn, "Unknown signal: $signal")
        end
    end
end
