module DaemonConductor

using BaseDirs
using Sockets
using Base.Threads
using Dates
using Pkg
using Serialization

const PACKAGE_VERSION = # Replace with `pkgversion` with Julia 1.9.
    VersionNumber(Pkg.TOML.parsefile(joinpath(pkgdir(@__MODULE__), "Project.toml"))["version"])

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
