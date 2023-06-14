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
end

include("precompile.jl")

end
