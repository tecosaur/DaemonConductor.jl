// Written for Zig 0.15
// Compile with: zig build-exe -target x86_64-linux -fstrip -O ReleaseSmall -fsingle-threaded -fPIE client.zig
const std = @import("std");

const argcodes = .{
    // U+E800 is a private use char used for the Julia logo in JuliaMono.
    .start = "\u{e800}DaemonClient Initialisation\u{e800}\n",
    .tty = "\u{e800}DaemonClient is a TTY\u{e800}\n",
    .pid = "\u{e800}DaemonClient PID\u{e800}\n",
    .cwd = "\u{e800}DaemonClient Current Working Directory\u{e800}\n",
    .env = "\u{e800}DaemonClient Environment\u{e800}\n",
    .args = "\u{e800}DaemonClient Arguments\u{e800}\n",
    .argsep = "\u{e800}--seperator--\u{e800}",
    .end = "\u{e800}DaemonClient End Info\u{e800}\n\n"
};

const sigcodes = .{
    // Codes that pertain to the signal START<code>DELIM<data>END structure.
    .start = 0x01, // SOH - Start of Heading
    .delim = 0x02, // STX - Start of Text
    .end = 0x04,   // EOT - End of Transmission
    // Signal codes
    .exit = "exit",
    .displaysize = "displaysize"
};

const Location = enum(u64) {
    stdin,
    stdout,
    stderr,
    signals,
    sockwrite
};

const SocketSet = struct {
    stdio: std.net.Stream,
    // stderr: std.net.Stream, TODO
    signals: std.net.Stream
};

// Because we can't create a closure within main().
var sockets: SocketSet = undefined;

// For handling the various SIG* signals that we want
// to treat specially.
fn signals_handler(
    signals: c_int,
    _: *const std.posix.siginfo_t,
    _: ?*const anyopaque,
) callconv(.c) void {
    switch (signals) {
        std.posix.SIG.INT => {
            _ = sockets.stdio.write("\x03") catch {}; },
        else => {} }}

fn register_signal_handler() !void {
    var mask = std.mem.zeroes(std.posix.sigset_t);
    std.posix.sigaddset(&mask, std.posix.SIG.INT);
    // std.posix.sigaddset(&mask, std.posix.SIG.TERM);
    var sigact = std.posix.Sigaction{
        .handler = .{ .sigaction = signals_handler },
        .mask = mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sigact, null);
    // try std.posix.sigaction(std.posix.SIG.TERM, &sigact, null);
}

fn get_main_socket(allocator: std.mem.Allocator, env_map: std.process.EnvMap) !std.net.Stream {
    const default_main_socket_path = try std.fmt.allocPrint(
        allocator, "/run/user/{d}/julia-daemon/conductor.sock",
        .{ std.posix.getuid() });

    const main_socket_path = env_map.get("JULIA_DAEMON_SERVER")
        orelse default_main_socket_path;

    const main_socket = std.net.connectUnixSocket(main_socket_path) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Socket file {s} does not exist.\nAre you sure the daemon is running?\n", .{main_socket_path});
            std.process.exit(1); },
        else => { return err; }};

    // Since we're now connected now, we can actually delete the socket file.
    try std.fs.deleteFileAbsolute(main_socket_path);

    return main_socket;
}

fn sendinfo(
    allocator: std.mem.Allocator,
    main_socket: std.net.Stream,
    env_map: std.process.EnvMap,
) !void {
    // 1) Build the whole message in memory
    var msg = std.Io.Writer.Allocating.init(allocator);
    defer msg.deinit();
    const w: *std.Io.Writer = &msg.writer;

    try w.writeAll(argcodes.start);

    const tty_status = if (std.fs.File.stdin().isTty()) "true" else "false";
    try w.print("{s}{s}\n", .{ argcodes.tty, tty_status });

    const pid = std.os.linux.getpid();
    try w.print("{s}{d}\n", .{ argcodes.pid, pid });

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    try w.print("{s}{s}\n", .{ argcodes.cwd, cwd });

    try w.writeAll(argcodes.env);
    var iter = env_map.iterator();
    while (iter.next()) |item| {
        try w.print("{s}={s}\n", .{ item.key_ptr.*, item.value_ptr.* });
    }

    try w.writeAll(argcodes.args);
    var args = try std.process.argsWithAllocator(allocator);
    while (args.next()) |arg| {
        try w.print("{s}{s}", .{ argcodes.argsep, arg });
    }
    args.deinit();

    try w.writeAll(argcodes.end);

    const payload = msg.written(); // contiguous slice

    // 2) Send it over the stream API (TCP/unix stream both OK)
    // Use an unbuffered stream-writer to avoid “forgot to flush” footguns.
    var sock_writer = main_socket.writer(&.{});
    try sock_writer.interface.writeAll(payload);
    try sock_writer.interface.flush();
}

fn connectUnixOrDie(path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(path) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "Socket file {s} does not exist.\nSomething has gone quite wrong...\n",
                .{path},
            );
            std.process.exit(1);
        },
        else => return err,
    };
}

fn get_communication_sockets(allocator: std.mem.Allocator, main_socket: std.net.Stream) !SocketSet {
    var buf: [2 * std.fs.max_path_bytes + 2]u8 = undefined;
    var sr = main_socket.reader(&buf);
    const reader = sr.interface(); // *std.Io.Reader

    const stdio_socket_path = try allocator.dupe(
        u8,
        std.mem.trimRight(u8, try reader.takeDelimiterExclusive('\n'), "\r"),
    );
    defer allocator.free(stdio_socket_path);

    const signals_socket_path = std.mem.trimRight(u8, try reader.takeDelimiterExclusive('\n'), "\r");

    main_socket.close();

    const stdio_sock = try connectUnixOrDie(stdio_socket_path);
    errdefer stdio_sock.close();
    try std.fs.deleteFileAbsolute(stdio_socket_path);

    const signals_sock = try connectUnixOrDie(signals_socket_path);
    errdefer signals_sock.close();
    try std.fs.deleteFileAbsolute(signals_socket_path);

    return .{ .stdio = stdio_sock, .signals = signals_sock };
}

// We could use a ring-buffer here, but since we're dealing
// but a temp buffer is small enough that we may as well
// just use one for simplicity.
const signals_buffer_size: usize = 1024;
var signals_write_index: usize = 0;
var signals_buffer: [signals_buffer_size]u8 = undefined;
var signals_tempbuffer: [signals_buffer_size]u8 = undefined;

pub const MalformedSignal = error{MalformedSignal};

fn process_signal_input(siginput: []u8) !i8 {
    // Check for potentially malformed input
    var exitcode: i8 = -1;
    if (siginput.len == 0) { return exitcode; }
    if (signals_write_index == 0 and siginput[0] != sigcodes.start) {
        std.debug.print("\n\x1b[0;1m[client] \x1b[1;31mERROR:\x1b[0;31m Signal recieved, but it did not start with the signal start code!\x1b[0;33m\n  signal: \x1b[0m{any}\n",
                        .{ siginput });
        return error.MalformedSignal; }
    if (signals_write_index + siginput.len > signals_buffer.len) {
        return error.Full; }

    @memcpy(signals_buffer[signals_write_index..signals_write_index + siginput.len],
            siginput);
    signals_write_index += siginput.len;

    var num_endcodes: u8 = 0;
    for (siginput) |byte| {
        if (byte == sigcodes.end) {
            num_endcodes += 1; }}
    var signals_read_index: usize = 0;

    while (num_endcodes > 0) {
        const startindex: usize = signals_read_index;
        if (signals_buffer[startindex] != sigcodes.start) {
            std.debug.print("\n\x1b[0;1m[client] \x1b[1;31mERROR:\x1b[0;31m The signals buffer appears to be corrupted!\x1b[0;33m\n signals buffer:\x1b[0m {any}\n",
                            .{ signals_buffer[startindex..signals_write_index] });
            return error.MalformedSignal; }
        var delimindex: usize = startindex;
        var endindex: usize = startindex;

        while (endindex == startindex and signals_read_index < signals_write_index-1) {
            signals_read_index += 1;
            switch (signals_buffer[signals_read_index]) {
                sigcodes.delim => {
                    if (delimindex == startindex) {
                        delimindex = signals_read_index;
                    } else {
                        std.debug.print("\n\x1b[0;1m[client] \x1b[1;31mERROR:\x1b[0;33m The signals buffer appears to contain a signal with multiple delimiters!\x1b[0;33m\n  signal:\x1b[0m {any}\n",
                                        .{ signals_buffer[startindex..signals_read_index+1] });
                        return error.MalformedSignal; }},
                sigcodes.end => {
                    if (delimindex != startindex) {
                        endindex = signals_read_index;
                    } else {
                        std.debug.print("\n\x1b[0;1m[client] \x1b[1;31mERROR:\x1b[0;31m The signals buffer appears to contain a signal which does not contain a delimiter!\x1b[0;33m\n signal:\x1b[0m {any}\n",
                                        .{ signals_buffer[startindex..signals_read_index+1] });
                        return error.MalformedSignal; }},
                else => {} }}

        const signame = signals_buffer[startindex+1..delimindex];
        const data = signals_buffer[delimindex+1..endindex];
        exitcode = try process_signal(signame, data);
        num_endcodes -= 1; }

    const unprocessed_length = signals_write_index - signals_read_index;
    if (signals_read_index > 0 and unprocessed_length > 0) {
        @memcpy(signals_tempbuffer[0..unprocessed_length],
                signals_buffer[signals_read_index..signals_write_index]);
        @memcpy(signals_buffer[0..unprocessed_length],
                signals_tempbuffer[0..unprocessed_length]); }
    signals_write_index -= signals_read_index;
    return exitcode; }

// Handle the signal `signame`, with associated `data`.
// Should an exit code have been signaled, that exit code
// will be returned. Otherwise a value < 0 will be returned.
fn process_signal(signame: []u8, data: []u8) !i8 {
    if (std.mem.eql(u8, signame, "exit")) {
        const exitcode = try std.fmt.parseInt(i8, data, 10);
        return exitcode;
    } else {
        std.debug.print("\n[client]: \"{s}\" signal is unrecognised\n", .{ signame});
        return error.MalformedSignal; }}

fn run_ioring() !void {
    const ring_queue_depth = 4; // (must be 2^n) stdin, stdio in, signals in
    const ring_buffer_size = 1024;

    var ring = try std.os.linux.IoUring.init(ring_queue_depth, 0);
    defer ring.deinit();

    var stdout_buf: [ring_buffer_size]u8 = undefined;
    var stdin_buf: [ring_buffer_size]u8 = undefined;
    var signals_buf: [ring_buffer_size]u8 = undefined;

    // Set up initial SQE

    _ = try ring.read(@intFromEnum(Location.stdout), sockets.stdio.handle, .{ .buffer = stdout_buf[0..] }, 0);
    _ = try ring.read(@intFromEnum(Location.stdin), std.posix.STDIN_FILENO, .{ .buffer = stdin_buf[0..] }, 0);
    _ = try ring.read(@intFromEnum(Location.signals), sockets.signals.handle, .{ .buffer = signals_buf[0..] }, 0);

    const stdout_fd = std.posix.STDOUT_FILENO;
    var exitcode: i8 = -1; // value >= 0 indicates exit

    while (true) {
        if (exitcode >= 0 and ring.cq_ready() == 0) {
            std.process.exit(@intCast(exitcode)); }

        _ = try ring.submit_and_wait(1);

        while (ring.cq_ready() > 0) {
            const cqe = try ring.copy_cqe();

            if (cqe.res < 0) {
                std.debug.panic("Oh no, something went wrong within io_uring.\n", .{}); }

            switch (cqe.user_data) {
                @intFromEnum(Location.stdout) => {
                    const len = @as(usize, @intCast(cqe.res));
                    _ = try std.posix.write(stdout_fd, stdout_buf[0..len]);
                    _ = try ring.read(@intFromEnum(Location.stdout), sockets.stdio.handle, .{ .buffer = stdout_buf[0..] }, 0); },
                @intFromEnum(Location.stdin) => {
                    const len = @as(usize, @intCast(cqe.res));
                    _ = try sockets.stdio.write(stdin_buf[0..len]);
                    _ = try ring.read(@intFromEnum(Location.stdin), std.posix.STDIN_FILENO, .{ .buffer = stdin_buf[0..] }, 0); },
                @intFromEnum(Location.signals) => {
                    const len = @as(usize, @intCast(cqe.res));
                    exitcode = try process_signal_input(signals_buf[0..len]);
                    _ = try ring.read(@intFromEnum(Location.signals), sockets.signals.handle, .{ .buffer = signals_buf[0..] }, 0); },
                else => {
                    std.debug.print("\nUnknown CQE ({d})\n", .{ cqe.user_data }); }}}}}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    defer arena.deinit();

    // Stage 0: Switch to raw mode to avoid line-buffering stdin.
    const stdin = std.fs.File.stdin();
    if (stdin.isTty()) {
        var termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        termios.lflag.ECHO = false;
        termios.lflag.ICANON = false;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, termios); }

    const env_map = try std.process.getEnvMap(alloc);

    // Stage 1: Connect to the main socket
    const main_socket = try get_main_socket(alloc, env_map);

    // Stage 2: Communicate the relevant information, namely the:
    // 1. TTY status
    // 2. PID of the client
    // 3. Current directory
    // 4. Current environment
    // 5. Call arguments
    try sendinfo(alloc, main_socket, env_map);

    // Stage 3: Switching sockets

    // At this point, the client has sent all the information needed,
    // and we expect to be given a path to a stdin/stdout socket
    // and a socket for signals.
    sockets = try get_communication_sockets(alloc, main_socket);
    // Pass ^C on instead of having it interrupt this client.
    try register_signal_handler();

    // Stage 4: Running the client over io_uring
    // TODO (someone else?) write cross-platform fallbacks
    try run_ioring(); }
