using Sockets
using Serialization
using Base.Threads
using REPL

# Use Revise.jl if possible
const revise_pkg = Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")
if !isnothing(Base.locate_package(revise_pkg))
    using Revise
end

const STATE = (
    ctime = time(),
    clients = Vector{Tuple{Float64, NamedTuple}}(),
    lastclient = Ref(time()),
    lock = SpinLock(),
    soft_exit = Ref(false))

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

# Basically a bootleg version of `exec_options`.
function runclient(client::NamedTuple, stdio, signals)
    function getval(pairlist, key, default)
        index = findfirst(p -> first(p) == key, pairlist)
        if isnothing(index) default else last(pairlist[index]) end
    end
    signal_exit(n) = write(signals, "\x01exit\x02", string(n), "\x04")

    lock(STATE.lock) do
        push!(STATE.clients, (time(), client))
    end

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
