module DaemonWorker

using Base.Threads
using REPL
using Serialization
using Sockets

using BaseDirs

const WORKER_ID = Ref("")

include("setup.jl")

function __init__()
    try_load_revise()
    WORKER_ID[] = String(rand('a':'z', 6))
    # With `REPL.Terminals.raw!`, there are to invocations incompatable
    # with an `IOContext`: `check_open` and `.handle`. However, `raw!` isn't
    # able to work normally anyway, so we may as well override it.
    @eval REPL.Terminals.raw!(t::REPL.TTYTerminal, raw::Bool) = raw
end

include("precompile.jl")

end
