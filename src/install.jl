using Pkg.Artifacts

const DEFAULT_WORKER_TTL = 2*60*60 # 2h

@static if Sys.islinux()
    const SYSTEMD_SERVICE_NAME = "julia-daemon"

    # Use a function instead of a const so that this will correctly
    # adapt to environment changes that affect the config path.
    systemd_service_file_path() =
        BaseDirs.User.config("systemd", "user", SYSTEMD_SERVICE_NAME * ".service",
                        create=true)

    function systemd_service_file_content()
        worker_cmd = worker_command("")
        """
[Unit]
Description=Julia ($(@__MODULE__).jl) server daemon

[Service]
Type=simple
ExecStart=$(first(worker_cmd.exec)) --startup-file=no --project="$(dirname(@__DIR__))" -e "using $(@__MODULE__); $(@__MODULE__).start()"
Environment="JULIA_DAEMON_SERVER=$MAIN_SOCKET"
Environment="JULIA_DAEMON_WORKER_EXECUTABLE=$(first(worker_cmd.exec))"
Environment="JULIA_DAEMON_WORKER_ARGS=$(join(worker_cmd.exec[3:end-2], ' '))"
$(if !haskey(ENV, "JULIA_DAEMON_WORKER_TTL")
    "Environment=\"JULIA_DAEMON_WORKER_TTL=$DEFAULT_WORKER_TTL\"\n"
else "" end)\
$(map(julia_env()) do (key, val)
    string("Environment=\"", key, '=', val, '"', '\n')
end |> join)\
Restart=on-failure

[Install]
WantedBy=default.target
"""
    end

    @doc """
    install()
Setup the daemon and client on this machine.

More specifically this:
- Symlinks the client executable to `$(BaseDirs.User.bin(CLIENT_NAME))`
- Creates a Systemd service called `$SYSTEMD_SERVICE_NAME`, and starts it (when applicable)\n
  Note that the current `JULIA_*` environment variables will be 'baked in' to the service file."
"""
    function install()
        if isnothing(Sys.which("systemctl"))
            @warn "Systemctl not found, skipping service setup"
        else
            if ispath(systemd_service_file_path())
                @info "Stopping existing systemd service"
                run(`systemctl --user stop $SYSTEMD_SERVICE_NAME.service`)
                @info "Re-installing systemd service to $systemd_service_file_path()"
            else
                @info "Installing systemd service to $systemd_service_file_path()"
            end
            write(systemd_service_file_path(), systemd_service_file_content())
            run(`systemctl --user daemon-reload`)
            run(`systemctl --user enable --now $SYSTEMD_SERVICE_NAME.service`)
            @info "Started the daemon"
        end
        binpath = BaseDirs.User.bin(CLIENT_NAME)
        @info "Installing client binary to $binpath"
        ispath(binpath) && rm(binpath)
        symlink(joinpath(artifact"client", "client"), binpath)
        chmod(binpath, 0o555)
        @info "Done"
    end

    function uninstall()
        if ispath(systemd_service_file_path())
            @info "Disabling systemd service"
            run(`systemctl --user disable --now $SYSTEMD_SERVICE_NAME.service`)
            @info "Removing systemd service file $systemd_service_file_path()"
            rm(systemd_service_file_path())
            run(`systemctl --user daemon-reload`)
        end
        binpath = BaseDirs.User.bin(CLIENT_NAME)
        @info "Removing binary client $binpath"
        ispath(binpath) && rm(binpath)
        @info "Done"
    end
else
    @doc """
    install()
Setup the daemon and client on this machine.
!!! warning
    This is currently unimplemented for $(Sys.KERNEL)!
"""
    function install()
        @error "This functionality is currently only implemented for Linux.\n" *
            "If you're up for it, consider making a PR to add support for $(Sys.KERNEL) 🙂"
    end

    @doc """
    uninstall()
Undo `install()`.
!!! warning
    This is currently unimplemented for $(Sys.KERNEL)!
"""
    function uninstall()
        @error "This functionality is currently only implemented for Linux.\n" *
            "If you're up for it, consider making a PR to add support for $(Sys.KERNEL) 🙂"
    end
end
