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

end
