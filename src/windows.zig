const std = @import("std");
pub const ws2_32 = @import("ws2_32.zig");

const WORD = ws2_32.WORD;
const DWORD = ws2_32.DWORD;
const WCHAR = ws2_32.WCHAR;
const BOOL = ws2_32.BOOL;

pub const std_windows = std.os.windows;
const HANDLE = std_windows.HANDLE;
const ULONG_PTR = std_windows.ULONG_PTR;
const PVOID = std_windows.PVOID;
const UnexpectedError = std.posix.UnexpectedError;
const GetLastError = std_windows.GetLastError;

pub const CloseHandle = std_windows.CloseHandle;

pub fn unexpectedWSAError(err: ws2_32.WinsockError) UnexpectedError {
    @branchHint(.cold);
    // Do NOT route this through std_windows.unexpectedError: it takes a
    // Win32Error and prints it with `{t}` (@tagName). Winsock codes live in the
    // 10000+ range and have no Win32Error tag, so @tagName panics with "invalid
    // enum value". ws2_32.WinsockError is its own exhaustive enum that does have
    // tags for these codes, so format it directly.
    if (std.options.unexpected_error_tracing) {
        std.debug.print("error.Unexpected: WSAGetLastError({d}): {t}\n", .{ @intFromEnum(err), err });
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    }
    return error.Unexpected;
}

pub fn WSASocketW(
    af: i32,
    socket_type: i32,
    protocol: i32,
    protocolInfo: ?*ws2_32.WSAPROTOCOL_INFOW,
    g: ws2_32.GROUP,
    dwFlags: DWORD,
) !ws2_32.SOCKET {
    var first = true;
    while (true) {
        const rc = ws2_32.WSASocketW(af, socket_type, protocol, protocolInfo, g, dwFlags);
        if (rc == ws2_32.INVALID_SOCKET) {
            switch (ws2_32.WSAGetLastError()) {
                .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .WSAEMFILE => return error.ProcessFdQuotaExceeded,
                .WSAENOBUFS => return error.SystemResources,
                .WSAEPROTONOSUPPORT => return error.ProtocolNotSupported,
                .WSANOTINITIALISED => {
                    if (!first) return error.Unexpected;
                    first = false;
                    try callWSAStartup();
                    continue;
                },
                else => |err| return unexpectedWSAError(err),
            }
        }
        return rc;
    }
}

fn callWSAStartup() !void {
    // WSAStartup is itself thread-safe (reference-counted internally). We
    // never call WSACleanup, intentionally leaking. A concurrent caller may
    // race and end up calling WSAStartup twice; that's harmless given we
    // never clean up.
    _ = WSAStartup(2, 2) catch |err| switch (err) {
        error.SystemNotAvailable => return error.SystemResources,
        error.VersionNotSupported => return error.Unexpected,
        error.BlockingOperationInProgress => return error.Unexpected,
        error.ProcessFdQuotaExceeded => return error.ProcessFdQuotaExceeded,
        error.Unexpected => return error.Unexpected,
    };
}

fn WSAStartup(majorVersion: u8, minorVersion: u8) !ws2_32.WSADATA {
    var wsadata: ws2_32.WSADATA = undefined;
    return switch (ws2_32.WSAStartup((@as(WORD, minorVersion) << 8) | majorVersion, &wsadata)) {
        0 => wsadata,
        else => |err_int| switch (@as(ws2_32.WinsockError, @enumFromInt(@as(u16, @intCast(err_int))))) {
            .WSASYSNOTREADY => return error.SystemNotAvailable,
            .WSAVERNOTSUPPORTED => return error.VersionNotSupported,
            .WSAEINPROGRESS => return error.BlockingOperationInProgress,
            .WSAEPROCLIM => return error.ProcessFdQuotaExceeded,
            else => |err| return unexpectedWSAError(err),
        },
    };
}

pub fn bind(s: ws2_32.SOCKET, name: *const std.posix.sockaddr, namelen: std.posix.socklen_t) i32 {
    return ws2_32.bind(s, name, @as(i32, @intCast(namelen)));
}

pub fn listen(s: ws2_32.SOCKET, backlog: u31) i32 {
    return ws2_32.listen(s, backlog);
}

pub fn accept(s: ws2_32.SOCKET, name: ?*std.posix.sockaddr, namelen: ?*std.posix.socklen_t) ws2_32.SOCKET {
    std.debug.assert((name == null) == (namelen == null));
    return ws2_32.accept(s, name, @as(?*i32, @ptrCast(namelen)));
}

pub fn getsockname(s: ws2_32.SOCKET, name: *std.posix.sockaddr, namelen: *std.posix.socklen_t) i32 {
    return ws2_32.getsockname(s, name, @as(*i32, @ptrCast(namelen)));
}

pub fn closesocket(s: ws2_32.SOCKET) !void {
    switch (ws2_32.closesocket(s)) {
        0 => {},
        ws2_32.SOCKET_ERROR => switch (ws2_32.WSAGetLastError()) {
            else => |err| return unexpectedWSAError(err),
        },
        else => unreachable,
    }
}

pub const RecvError = error{
    WouldBlock,
    ConnectionResetByPeer,
    SocketNotConnected,
    NetworkSubsystemFailed,
    Unexpected,
};

/// Synchronous `recv` for a `WSA_FLAG_OVERLAPPED` socket. Used in place of
/// `ReadFile`, which fails with INVALID_PARAMETER on overlapped sockets when
/// passed a null OVERLAPPED. Returns 0 on graceful shutdown.
pub fn recv(s: ws2_32.SOCKET, buf: []u8) RecvError!usize {
    const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
    const rc = ws2_32.recv(s, buf.ptr, len, 0);
    if (rc != ws2_32.SOCKET_ERROR) return @intCast(rc);
    switch (ws2_32.WSAGetLastError()) {
        .WSAEWOULDBLOCK => return error.WouldBlock,
        .WSAECONNRESET,
        .WSAECONNABORTED,
        .WSAENETRESET,
        .WSAETIMEDOUT,
        => return error.ConnectionResetByPeer,
        .WSAENETDOWN => return error.NetworkSubsystemFailed,
        .WSAENOTCONN => return error.SocketNotConnected,
        .WSAESHUTDOWN => return 0,
        .WSAEINTR, .WSAEINPROGRESS => unreachable,
        .WSAEINVAL, .WSAEFAULT => unreachable,
        .WSAENOTSOCK => unreachable,
        .WSAEOPNOTSUPP => unreachable,
        else => |err| return unexpectedWSAError(err),
    }
}

pub const SendError = error{
    WouldBlock,
    ConnectionResetByPeer,
    BrokenPipe,
    SocketNotConnected,
    NetworkSubsystemFailed,
    AccessDenied,
    SystemResources,
    MessageTooBig,
    Unexpected,
};

/// Synchronous `send` for a `WSA_FLAG_OVERLAPPED` socket.
pub fn send(s: ws2_32.SOCKET, bytes: []const u8) SendError!usize {
    const len: i32 = @intCast(@min(bytes.len, std.math.maxInt(i32)));
    const rc = ws2_32.send(s, bytes.ptr, len, 0);
    if (rc != ws2_32.SOCKET_ERROR) return @intCast(rc);
    switch (ws2_32.WSAGetLastError()) {
        .WSAEWOULDBLOCK => return error.WouldBlock,
        .WSAECONNRESET, .WSAENETRESET, .WSAETIMEDOUT, .WSAEHOSTUNREACH => return error.ConnectionResetByPeer,
        .WSAECONNABORTED, .WSAESHUTDOWN => return error.BrokenPipe,
        .WSAENETDOWN => return error.NetworkSubsystemFailed,
        .WSAENOTCONN => return error.SocketNotConnected,
        .WSAEACCES => return error.AccessDenied,
        .WSAENOBUFS => return error.SystemResources,
        .WSAEMSGSIZE => return error.MessageTooBig,
        .WSAEINTR, .WSAEINPROGRESS => unreachable,
        .WSAEINVAL, .WSAEFAULT => unreachable,
        .WSAENOTSOCK => unreachable,
        .WSAEOPNOTSUPP => unreachable,
        else => |err| return unexpectedWSAError(err),
    }
}

pub const ReadFileError = error{
    BrokenPipe,
    /// The specified network name is no longer available.
    ConnectionResetByPeer,
    OperationAborted,
    /// Unable to read file due to lock.
    LockViolation,
    /// Known to be possible when:
    /// - Unable to read from disconnected virtual com port (Windows)
    AccessDenied,
    NotOpenForReading,
    Unexpected,
};

/// If buffer's length exceeds what a Windows DWORD integer can hold, it will be broken into
/// multiple non-atomic reads.
pub fn ReadFile(in_hFile: HANDLE, buffer: []u8, offset: ?u64) ReadFileError!usize {
    while (true) {
        const want_read_count: DWORD = @min(@as(DWORD, std.math.maxInt(DWORD)), buffer.len);
        var amt_read: DWORD = undefined;
        var overlapped_data: OVERLAPPED = undefined;
        const overlapped: ?*OVERLAPPED = if (offset) |off| blk: {
            overlapped_data = .{
                .Internal = 0,
                .InternalHigh = 0,
                .DUMMYUNIONNAME = .{
                    .DUMMYSTRUCTNAME = .{
                        .Offset = @as(u32, @truncate(off)),
                        .OffsetHigh = @as(u32, @truncate(off >> 32)),
                    },
                },
                .hEvent = null,
            };
            break :blk &overlapped_data;
        } else null;
        if (kernel32.ReadFile(in_hFile, buffer.ptr, want_read_count, &amt_read, overlapped) == .FALSE) {
            switch (GetLastError()) {
                .IO_PENDING => unreachable,
                .OPERATION_ABORTED => continue,
                .BROKEN_PIPE => return 0,
                .HANDLE_EOF => return 0,
                .NETNAME_DELETED => return error.ConnectionResetByPeer,
                .LOCK_VIOLATION => return error.LockViolation,
                .ACCESS_DENIED => return error.AccessDenied,
                .INVALID_HANDLE => return error.NotOpenForReading,
                else => |err| return std_windows.unexpectedError(err),
            }
        }
        return amt_read;
    }
}

pub const WriteFileError = error{
    SystemResources,
    OperationAborted,
    BrokenPipe,
    NotOpenForWriting,
    /// The process cannot access the file because another process has locked
    /// a portion of the file.
    LockViolation,
    /// The specified network name is no longer available.
    ConnectionResetByPeer,
    /// Known to be possible when:
    /// - Unable to write to disconnected virtual com port (Windows)
    AccessDenied,
    Unexpected,
};

pub fn WriteFile(
    handle: HANDLE,
    bytes: []const u8,
    offset: ?u64,
) WriteFileError!usize {
    var bytes_written: DWORD = undefined;
    var overlapped_data: OVERLAPPED = undefined;
    const overlapped: ?*OVERLAPPED = if (offset) |off| blk: {
        overlapped_data = .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{
                .DUMMYSTRUCTNAME = .{
                    .Offset = @truncate(off),
                    .OffsetHigh = @truncate(off >> 32),
                },
            },
            .hEvent = null,
        };
        break :blk &overlapped_data;
    } else null;
    const adjusted_len = std.math.cast(u32, bytes.len) orelse std.math.maxInt(u32);
    if (kernel32.WriteFile(handle, bytes.ptr, adjusted_len, &bytes_written, overlapped) == .FALSE) {
        switch (GetLastError()) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.OperationAborted,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .IO_PENDING => unreachable,
            .NO_DATA => return error.BrokenPipe,
            .INVALID_HANDLE => return error.NotOpenForWriting,
            .LOCK_VIOLATION => return error.LockViolation,
            .NETNAME_DELETED => return error.ConnectionResetByPeer,
            .ACCESS_DENIED => return error.AccessDenied,
            .WORKING_SET_QUOTA => return error.SystemResources,
            else => |err| return std_windows.unexpectedError(err),
        }
    }
    return bytes_written;
}

const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};

pub const HANDLE_FLAG_INHERIT = 1;
pub const HANDLE_FLAG_PROTECT_FROM_CLOSE = 2;

/// Disables handle inheritance for the given handle (Windows equivalent of
/// FD_CLOEXEC). Works on socket handles as well as regular file handles.
pub fn setNoInherit(handle: HANDLE) !void {
    if (kernel32.SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) == .FALSE) {
        switch (GetLastError()) {
            .INVALID_HANDLE => return error.Unexpected,
            .ACCESS_DENIED => return error.AccessDenied,
            else => |err| return std_windows.unexpectedError(err),
        }
    }
}

/// kernel32 was severely trimmed in Zig 0.16, so re-declare the few entry
/// points we need.
const kernel32 = struct {
    pub extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn SetHandleInformation(
        hObject: HANDLE,
        dwMask: DWORD,
        dwFlags: DWORD,
    ) callconv(.winapi) BOOL;
};
