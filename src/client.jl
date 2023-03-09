const CLIENT_NAME = "juliaclient"

const CLIENT_HELP = """

    $CLIENT_NAME [switches] -- [programfile] [args...]

Switches (a '*' marks the default value, if applicable):

 -v, --version              Display version information
 -h, --help                 Print this message
 --project[=<dir>|@.]       Set <dir> as the home project/environment
 -e, --eval <expr>          Evaluate <expr>
 -E, --print <expr>         Evaluate <expr> and display the result
 -L, --load <file>          Load <file> immediately on all processors
 -i                         Interactive mode; REPL runs and `isinteractive()` is true
 --banner={yes|no|auto*}    Enable or disable startup banner
 --color={yes|no|auto*}     Enable or disable color text
 --history-file={yes*|no}   Load or save history
"""

struct Client
    tty::Bool
    pid::Int
    cwd::String
    env::Vector{Pair{String, String}}
    switches::Vector{Tuple{String, String}}
    programfile::Union{Nothing, String}
    args::Vector{String}
end

function Base.convert(::Type{NamedTuple}, client::Client)
    (; tty, pid, cwd, env, switches, programfile, args) = client
    (; tty, pid, cwd, env, switches, programfile, args)
end

const CLIENT_CODES = (
    #  = U+E800, which is private use char used for the Julia logo in JuliaMono.
    start = "DaemonClient Initialisation",
    tty = "DaemonClient is a TTY",
    pid = "DaemonClient PID",
    cwd = "DaemonClient Current Working Directory",
    env = "DaemonClient Environment",
    args = "DaemonClient Arguments",
    argsep = "--seperator--",
    finish = "DaemonClient End Info")

"""
    readclientinfo(connection)
Using the input stream `connection`, read client information and
construct a `Client`.
"""
function readclientinfo(connection::IO)
    tty = if readline(connection) == CLIENT_CODES.tty
        parse(Bool, readline(connection))
    else error("Client info parsing: Expected TTY header") end
    pid = if readline(connection) == CLIENT_CODES.pid
        parse(Int, readline(connection))
    else error("Client info parsing: Expected PID header") end
    cwd = if readline(connection) == CLIENT_CODES.cwd
        readline(connection)
    else error("Client info parsing: Expected CWD header") end
    env = Pair{String, String}[]
    if readline(connection) == CLIENT_CODES.env
        while (envline = readline(connection)) != CLIENT_CODES.args
            key, value = split(envline, '=', limit=2)
            push!(env, key => value)
        end
    else error("Client info parsing: Expected Env header") end
    allargs = split(readuntil(connection, CLIENT_CODES.finish),
                    CLIENT_CODES.argsep, keepempty=true)[3:end] .|> String
    Client(tty, pid, cwd, env, splitargs!(allargs)...)
end

"""
Short arguments that should be converted to their long form.
"""
const SWITCH_SHORT_MAPPING = Dict(
    "-e" => "--eval",
    "-E" => "--print",
    "-L" => "--load")

"""
    splitargs!(allargs::Vector{<:AbstractString})
Split a vector of args into, a tuple of:
- switches that apply to the julia(client) invocation
- the program file
- arguments that are applied to the program file
"""
function splitargs!(args::Vector{String})
    switches = Vector{Tuple{String, String}}()
    seendoubledash = false # To record if -- seen
    programfile = nothing
    while isnothing(programfile) && !isempty(args)
        arg = popfirst!(args)
        if arg == "--"
            seendoubledash = true
        elseif seendoubledash
            programfile = arg
        elseif startswith(arg, "--")
            if occursin('=', arg)
                switch, value = split(arg, '=', limit=2)
                push!(switches, (switch, value))
            else
                push!(switches, (arg, if isempty(args) "" else popfirst!(arg) end))
            end
        elseif startswith(arg, "-") && length(arg) > 1
            thearg = get(SWITCH_SHORT_MAPPING, arg[1:2], arg[1:2])
            push!(switches, (thearg, if length(arg) > 2
                                 arg[3:end]
                             elseif isempty(args) ""
                             else popfirst!(args) end))
        else
            programfile = arg
        end
    end
    switches, programfile, args
end

"""
    projectpath(client::Client)
Obtain the project path specified in `client`, returning the default
project path if unspecified.
"""
function projectpath(client::Client)
    project_index = findlast(==("--project"), Iterators.map(first, client.switches))
    project_path = get(ENV, "JULIA_PROJECT", Base.load_path_expand("@v#.#") |> dirname)
    if !isnothing(project_index) && project_index < length(client.switches)
        project_path = last(client.switches[project_index])
    end
    if project_path == "@."
        projectfile_path = joinpath(client.cwd, "Project.toml")
        while !ispath(projectfile_path)
            parent = joinpath(projectfile_path |> dirname |> dirname,
                                "Project.toml")
            if parent == projectfile_path
                projectfile_path = Base.load_path_expand("@v#.#")
            end
        end
        projectfile_path |> dirname
    else
        abspath(client.cwd, project_path)
    end
    project_path
end
