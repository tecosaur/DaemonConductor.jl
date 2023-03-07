using Pkg.Artifacts

const SYSTEMD_SERVICE_FILE_CONTENT = """
[Unit]
Description=Julia ($(@__MODULE__).jl) server daemon

[Service]
Type=simple
ExecStart=$(Sys.which("julia")) --startup-file=no --project="$(dirname(@__DIR__))" -e "using $(@__MODULE__); $(@__MODULE__).start()"
Restart=on-failure

[Install]
WantedBy=default.target
"""

const SYSTEMD_SERVICE_NAME = "julia-daemon"

function install()
    if !Sys.islinux()
        error("$(@__MODULE__)'s service and client can only be installed on Linux at the moment")
    end
    if isnothing(Sys.which("systemctl"))
        @warn "Systemctl not found, skipping service setup"
    else
        servicefile = XDG.User.config("systemd", "user", SYSTEMD_SERVICE_NAME * ".service",
                                      create=true)
        @info "Installing systemd service to $servicefile"
        write(servicefile, SYSTEMD_SERVICE_FILE_CONTENT)
        run(`systemctl --user daemon-reload`)
        run(`systemctl --user enable --now $SYSTEMD_SERVICE_NAME.service`)
        @info "Started the daemon"
    end
    binpath = XDG.User.bin(CLIENT_NAME)
    @info "Installing client binary to $binpath"
    symlink(joinpath(artifact"client", "client"), binpath)
    chmod(binpath, 0o555)
    @info "Done"
end

function uninstall()
    if !Sys.islinux()
        error("$(@__MODULE__)'s service and client are only installed on Linux at the moment")
    end
    servicefile = XDG.User.config("systemd", "user", SYSTEMD_SERVICE_NAME * ".service",
                                  create=true)
    if ispath(servicefile)
        @info "Disabling systemd service"
        run(`systemctl --user disable --now $SYSTEMD_SERVICE_NAME.service`)
        @info "Removing systemd service file $servicefile"
        rm(servicefile)
        run(`systemctl --user daemon-reload`)
    end
    binpath = XDG.User.bin(CLIENT_NAME)
    @info "Removing binary client $binpath"
    ispath(binpath) && rm(binpath)
    @info "Done"
end
