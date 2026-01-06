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

# Binary protocol constants
const PROTOCOL_MAGIC = 0x4A444301  # "JDC\x01" little-endian
const PROTOCOL_VERSION = 0x01
const ENV_REQUEST = 0x3F  # '?' - request full environment from client

# Environment fingerprint caching
const ENV_CACHE = Dict{UInt64, Vector{Pair{String, String}}}()
const ENV_CACHE_LOCK = ReentrantLock()

"""
    readclientinfo(connection)

Using the input stream `connection`, read client information using binary protocol
and construct a `Client`.

Binary Protocol Format:
  Header (8 bytes):
    [4 bytes] Magic: 0x4A444301 ("JDC\\x01" LE)
    [1 byte]  Flags: bit 0 = TTY
    [3 bytes] Reserved

  Body:
    [4 bytes] PID (u32 LE)
    [2 bytes] CWD length (u16 LE)
    [N bytes] CWD string
    [8 bytes] Env fingerprint (u64 LE)
    [2 bytes] Arg count (u16 LE)
    For each arg:
      [2 bytes] Arg length (u16 LE)
      [N bytes] Arg string
"""
function readclientinfo(connection::IO)
    # Read and validate magic
    magic = read(connection, UInt32)
    if magic != PROTOCOL_MAGIC
        error("Invalid protocol magic: expected $(repr(PROTOCOL_MAGIC)), got $(repr(magic))")
    end

    # Read flags
    flags = read(connection, UInt8)
    tty = (flags & 0x01) != 0

    # Skip reserved bytes
    read(connection, 3)

    # Read PID
    pid = Int(read(connection, UInt32))

    # Read CWD (length-prefixed)
    cwd_len = read(connection, UInt16)
    cwd = String(read(connection, cwd_len))

    # Read environment fingerprint
    fingerprint = read(connection, UInt64)

    # Read args (count, then length-prefixed strings)
    arg_count = read(connection, UInt16)
    allargs = Vector{String}(undef, arg_count)
    for i in 1:arg_count
        arg_len = read(connection, UInt16)
        allargs[i] = String(read(connection, arg_len))
    end

    # Resolve environment: check cache, request full env if needed
    env = lock(ENV_CACHE_LOCK) do
        get(ENV_CACHE, fingerprint, nothing)
    end

    if isnothing(env)
        # Cache miss - request full environment from client
        write(connection, ENV_REQUEST)
        flush(connection)

        # Read binary environment response
        # Format: [2 bytes count][for each: 2 bytes key_len, key, 2 bytes val_len, val]
        env_count = read(connection, UInt16)
        env = Vector{Pair{String, String}}(undef, env_count)
        for i in 1:env_count
            key_len = read(connection, UInt16)
            key = String(read(connection, key_len))
            val_len = read(connection, UInt16)
            val = String(read(connection, val_len))
            env[i] = key => val
        end

        # Cache the environment
        lock(ENV_CACHE_LOCK) do
            ENV_CACHE[fingerprint] = env
        end
    end

    Client(tty, pid, cwd, env, splitargs!(allargs)...)
end

"""
    send_socket_paths(connection::IO, stdio_path::AbstractString, signals_path::AbstractString)

Send socket paths to client using binary length-prefix encoding.
Returns `:ok` if successful, `:disconnected` if client closed after reading,
or throws if client disconnected before data could be written.
"""
function send_socket_paths(connection::IO, stdio_path::AbstractString, signals_path::AbstractString)
    # Write stdio path (length-prefixed)
    write(connection, UInt16(ncodeunits(stdio_path)))
    write(connection, stdio_path)

    # Write signals path (length-prefixed)
    write(connection, UInt16(ncodeunits(signals_path)))
    write(connection, signals_path)

    # Flush may fail if client read the data and closed quickly - that's OK
    try
        flush(connection)
    catch err
        err isa Base.IOError || rethrow(err)
        return :disconnected
    end
    :ok
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
Split a vector of args into a tuple of:
- switches that apply to the julia(client) invocation
- the program file
- arguments that are applied to the program file
"""
function splitargs!(args::Vector{String})
    switches = Vector{Tuple{String, String}}()
    seendoubledash = false # To record if -- seen
    programfile = nothing
    # Skip first arg (program name)
    args = length(args) > 0 ? args[2:end] : args
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
                push!(switches, (arg, if isempty(args) "" else popfirst!(args) end))
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
    project_path = let proj_env_index = findfirst(==("JULIA_PROJECT"), Iterators.map(first, client.env))
        if isnothing(proj_env_index)
            get(ENV, "JULIA_PROJECT", Base.load_path_expand("@v#.#") |> dirname)
        else
            last(client.env[proj_env_index])
        end
    end
    if !isnothing(project_index) && project_index <= length(client.switches)
        project_path = last(client.switches[project_index])
    end
    if project_path ∈ ("@.", "")
        projectfile_path = joinpath(client.cwd, "Project.toml")
        while !ispath(projectfile_path)
            parent = joinpath(projectfile_path |> dirname |> dirname,
                              "Project.toml")
            if parent == projectfile_path
                projectfile_path = Base.load_path_expand("@v#.#")
            else
                projectfile_path = parent
            end
        end
        projectfile_path |> dirname
    else
        rstrip(abspath(client.cwd, expanduser(project_path)), '/') |> String
    end
end