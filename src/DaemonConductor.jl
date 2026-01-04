module DaemonConductor

using BaseDirs
using Sockets
using Base.Threads
using Dates
using Pkg
using Serialization

const PACKAGE_VERSION = @static if VERSION >= v"1.9"
    pkgversion(@__MODULE__)
else
    VersionNumber(Pkg.TOML.parsefile(joinpath(pkgdir(@__MODULE__), "Project.toml"))["version"])
end

const RUNTIME_DIR = "julia-daemon"
const WORKER_MAXCLIENTS = Ref(1)

macro log(msg...)
    quote
        printstyled("[$(now())] ", color=:light_black)
        $(esc(Expr(:call, :println, msg...)))
    end
end

include("client.jl")
include("workers.jl")
include("conductor.jl")
include("install.jl")

function __init__()
    WORKER_MAXCLIENTS[] =
        something(tryparse(Int, get(ENV, "JULIA_DAEMON_WORKER_MAXCLIENTS", "1")),
                  1)
end

BaseDirs.@promise_no_assign @doc """
    DaemonConductor

# Setup

Install this package anywhere and run `DaemonConductor.install()`. Re-run this
command after updating `DaemonConductor`, the configuration env vars, or Julia
itself.

# Configuration

When the daemon starts, it pays attention to the following environmental variables:
- `JULIA_DAEMON_SERVER` [`$(BaseDirs.runtime("julia-daemon", "conductor.sock"))`] \n
  The socket to connect to.
- `JULIA_DAEMON_WORKER_MAXCLIENTS` [`$DEFAULT_WORKER_MAXCLIENTS`]\n
  The maximum number of clients a worker may be attached to at once. Set to `0`
  to disable.
- `JULIA_DAEMON_WORKER_ARGS` [`--startup-file=no`] \n
  Arguments passed to the Julia worker processes.
- `JULIA_DAEMON_WORKER_EXECUTABLE` [`$(joinpath(Sys.BINDIR, "julia"))`] \n
  Path to the Julia executable used by the workers.
- `JULIA_DAEMON_WORKER_TTL` [`$DEFAULT_WORKER_TTL`] \n
  Number of seconds a worker should be kept alive for after the last client disconnects.
""" DaemonConductor

end
