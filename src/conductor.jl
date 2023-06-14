const MAIN_SOCKET =
    get(ENV, "JULIA_DAEMON_SERVER",
        BaseDirs.User.runtime(RUNTIME_DIR, "conductor.sock"))

function start()
    try
        @log "Preparing worker environment"
        ensure_worker_env()
        @log "Running"
        @async create_reserve_worker()
        while true
            serveonce()
        end
    finally # Cleanup
        @log "Killing $(length(WORKER_POOL)) workers"
        for (key, _) in WORKER_POOL
            # These /need/ to be deleted and killed to avoid
            # potential pipe issues should `start()` be reinvoked.
            delete!(WORKER_POOL, key)
        end
        if !isnothing(RESERVE_WORKER[])
            kill(RESERVE_WORKER[])
            RESERVE_WORKER[] = nothing
        end
        @log "Stopped"
        file = if startswith(MAIN_SOCKET, '/') # Absolute socket file
            MAIN_SOCKET
        elseif startswith(MAIN_SOCKET, '~') # User-local socket file
            expanduser(MAIN_SOCKET)
        end
        if !isnothing(file) && ispath(file)
            if startswith(file, BaseDirs.User.runtime(RUNTIME_DIR))
                rm(BaseDirs.User.runtime(RUNTIME_DIR), recursive=true)
            else
                rm(file)
            end
        end
    end
end

function serveonce()
    file = if startswith(MAIN_SOCKET, '/') # Absolute socket file
        MAIN_SOCKET
    elseif startswith(MAIN_SOCKET, '~') # User-local socket file
        expanduser(MAIN_SOCKET)
    end

    server = if !isnothing(file)
        isdir(dirname(file)) || mkpath(dirname(file))
        Sockets.listen(file)
    elseif match(r"^(?:localhost)?:\d+$", MAIN_SOCKET) |> !isnothing # Port only
        _, port = split(MAIN_SOCKET, ':')
        Sockets.listen(parse(Int, port))
    elseif match(r"^\[[0-9a-f:]+\]:\d+$", MAIN_SOCKET) |> !isnothing # IPv6 address
        addr, port = split(MAIN_SOCKET[2:end], "]:")
        Sockets.listen(parse(IPv6, addr), parse(Int, port))
    elseif match(r"^\d+\.\d+\.\d+\.\d+:\d+$", MAIN_SOCKET) |> !isnothing # IPv4 address
        addr, port = split(MAIN_SOCKET, ':')
        Sockets.listen(parse(IPv4, addr), parse(Int, port))
    else
        error("Socket form $(sprint(show, MAIN_SOCKET)) did not match any recognised format.")
    end

    try
        # This blocks until the socket is connected to.
        conn = accept(server)
        if readline(conn) != CLIENT_CODES.start
            error("Malformed connection")
        end

        # Since the client deletes the socket file immediately after
        # connecting to it, we can spawn a task to handle it asyncronously
        # and immedately re-create the socket file.
        # However, changing this to `@spawn serveclient($conn)` seems to
        # add ~10ms to the time, which is a decently large factor with a
        # "hello world" type script, and sometimes the main socket file
        # disapears.
        serveclient(conn)
    catch err
        if err isa Base.IOError
            @warn "Client disconnected during setup"
        # elseif err isa InterruptException
        else
            rethrow(err)
        end
    end
end

const client_counter = Ref(0)
function serveclient(connection::Base.PipeEndpoint)
    client = readclientinfo(connection)
    @log "Client $(client_counter[] += 1); " *
        "pid: $(client.pid) project: $(projectpath(client))"
    function servestring(content)
        # Setup sockets
        rand_id = String(rand('a':'z', 16))
        stdio_sockfile = BaseDirs.User.runtime(RUNTIME_DIR, string(rand_id, "-stdio", ".sock"))
        signals_sockfile = BaseDirs.User.runtime(RUNTIME_DIR, string(rand_id, "-signals", ".sock"))
        stdio_sock = Sockets.listen(stdio_sockfile)
        signals_sock = Sockets.listen(signals_sockfile)
        # Inform client about them
        println(connection, stdio_sockfile)
        println(connection, signals_sockfile)
        # Connect to the client
        stdio = accept(stdio_sock)
        signals = accept(signals_sock)
        # Send `content` and exit code 0.
        write(stdio, content)
        write(signals, "\x01exit\x020\x04")
        close(stdio); close(signals)
        close(stdio_sock); close(signals_sock)
    end
    if "-h" in first.(client.switches) || "--help" in first.(client.switches)
        servestring(CLIENT_HELP)
    elseif "-v" in first.(client.switches) || "--version" in first.(client.switches)
        # REVIEW: Should this get the Julia version from the worker?
        servestring("julia version $VERSION, juliaclient $PACKAGE_VERSION\n")
    else
        stdio_sock, signals_sock = runclient(client)
        try
            println(connection, stdio_sock)
            println(connection, signals_sock)
        catch err
            if err isa Base.IOError
                @warn "Client disconnected during setup"
                if ispath(stdio_sock)
                    close(Sockets.connect(stdio_sock))
                    rm(stdio_sock)
                end
                if ispath(signals_sock)
                    close(Sockets.connect(signals_sock))
                    rm(signals_sock)
                end
            else
                rethrow(err)
            end
        end
    end
    close(connection)
end
