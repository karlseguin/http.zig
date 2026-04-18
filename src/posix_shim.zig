//! Zig 0.16 removed most function wrappers from `std.posix` (socket, accept,
//! bind, listen, connect, close, read, write, fcntl, kqueue, kevent,
//! epoll_*, eventfd, clock_gettime, getrandom, getsockname, shutdown). The
//! constants (fd_t, socket_t, SOCK, AF, CLOCK, ...) are still there; the
//! callable wrappers are not. This file reinstates the wrappers httpz needs
//! by calling `std.c.*` or `std.os.linux.*` directly and mapping errno to
//! the same error sets httpz already handles.
//!
//! Scoped to what httpz actually calls. Each function mirrors the 0.15
//! `std.posix.*` signature so call sites need no changes beyond the import
//! swap (`const posix = @import("posix_shim.zig")` next to the existing
//! `const posix = std.posix;` alias, or a direct namespace swap).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const linux = std.os.linux;
const native_os = builtin.os.tag;

const errno = posix.errno;
const unexpectedErrno = posix.unexpectedErrno;

// Raw syscall dispatch: on Linux call the raw sys_* via std.os.linux (returns
// usize where negative-range values encode -errno); on macOS/BSD call the C
// extern wrappers via std.c (return the normal value, errno in thread-local).
//
// linuxRc reinterprets the usize return so posix.errno() can decode it the
// same way 0.15 did.

// ── fd lifecycle ──────────────────────────────────────────────────────────

pub const closeFd = close;
pub fn close(fd: posix.fd_t) void {
    switch (native_os) {
        .linux => _ = linux.close(fd),
        else => _ = c.close(fd),
    }
}

pub const ReadError = error{
    WouldBlock,
    InputOutput,
    SystemResources,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    Canceled,
    AccessDenied,
    Unexpected,
};

pub const readFd = read;
pub fn read(fd: posix.fd_t, buf: []u8) ReadError!usize {
    while (true) {
        switch (native_os) {
            .linux => {
                const rc = linux.read(fd, buf.ptr, buf.len);
                switch (errno(rc)) {
                    .SUCCESS => return @intCast(@as(isize, @bitCast(rc))),
                    .INTR => continue,
                    .INVAL => unreachable,
                    .FAULT => unreachable,
                    .AGAIN => return error.WouldBlock,
                    .CANCELED => return error.Canceled,
                    .BADF => return error.NotOpenForReading,
                    .IO => return error.InputOutput,
                    .ISDIR => return error.Unexpected,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTCONN => return error.SocketNotConnected,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .TIMEDOUT => return error.ConnectionTimedOut,
                    .PIPE => return error.BrokenPipe,
                    .ACCES => return error.AccessDenied,
                    else => |err| return unexpectedErrno(err),
                }
            },
            else => {
                // c.read returns ssize_t (isize). Keep as-is so std.c.errno's
                // `rc == -1` check works — bitcasting to usize breaks it.
                const rc = c.read(fd, buf.ptr, buf.len);
                if (rc >= 0) return @intCast(rc);
                switch (errno(rc)) {
                    .SUCCESS => unreachable,
                    .INTR => continue,
                    .INVAL => unreachable,
                    .FAULT => unreachable,
                    .AGAIN => return error.WouldBlock,
                    .CANCELED => return error.Canceled,
                    .BADF => return error.NotOpenForReading,
                    .IO => return error.InputOutput,
                    .ISDIR => return error.Unexpected,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTCONN => return error.SocketNotConnected,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .TIMEDOUT => return error.ConnectionTimedOut,
                    .PIPE => return error.BrokenPipe,
                    .ACCES => return error.AccessDenied,
                    else => |err| return unexpectedErrno(err),
                }
            },
        }
    }
}

pub const WriteError = error{
    WouldBlock,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,
    LockViolation,
    ConnectionResetByPeer,
    ProcessNotFound,
    NoDevice,
    Canceled,
    Unexpected,
};

pub fn writev(fd: posix.fd_t, iov: []posix.iovec_const) WriteError!usize {
    while (true) {
        switch (native_os) {
            .linux => {
                const rc = linux.writev(fd, iov.ptr, iov.len);
                switch (errno(rc)) {
                    .SUCCESS => return @intCast(@as(isize, @bitCast(rc))),
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .CANCELED => return error.Canceled,
                    .BADF => return error.NotOpenForWriting,
                    .PIPE => return error.BrokenPipe,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .NOSPC => return error.NoSpaceLeft,
                    else => |err| return unexpectedErrno(err),
                }
            },
            else => {
                const rc = c.writev(fd, iov.ptr, @intCast(iov.len));
                if (rc >= 0) return @intCast(rc);
                switch (errno(rc)) {
                    .SUCCESS => unreachable,
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .CANCELED => return error.Canceled,
                    .BADF => return error.NotOpenForWriting,
                    .PIPE => return error.BrokenPipe,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .NOSPC => return error.NoSpaceLeft,
                    else => |err| return unexpectedErrno(err),
                }
            },
        }
    }
}

pub const writeFd = write;
pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    while (true) {
        switch (native_os) {
            .linux => {
                const rc = linux.write(fd, bytes.ptr, bytes.len);
                switch (errno(rc)) {
                    .SUCCESS => return @intCast(@as(isize, @bitCast(rc))),
                    .INTR => continue,
                    .INVAL => unreachable,
                    .FAULT => unreachable,
                    .AGAIN => return error.WouldBlock,
                    .CANCELED => return error.Canceled,
                    .BADF => return error.NotOpenForWriting,
                    .DESTADDRREQ => unreachable,
                    .DQUOT => return error.DiskQuota,
                    .FBIG => return error.FileTooBig,
                    .IO => return error.InputOutput,
                    .NOSPC => return error.NoSpaceLeft,
                    .PERM => return error.AccessDenied,
                    .PIPE => return error.BrokenPipe,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .BUSY => return error.LockViolation,
                    .NXIO => return error.NoDevice,
                    .SRCH => return error.ProcessNotFound,
                    else => |err| return unexpectedErrno(err),
                }
            },
            else => {
                const rc = c.write(fd, bytes.ptr, bytes.len);
                if (rc >= 0) return @intCast(rc);
                switch (errno(rc)) {
                    .SUCCESS => unreachable,
                    .INTR => continue,
                    .INVAL => unreachable,
                    .FAULT => unreachable,
                    .AGAIN => return error.WouldBlock,
                    .CANCELED => return error.Canceled,
                    .BADF => return error.NotOpenForWriting,
                    .DESTADDRREQ => unreachable,
                    .DQUOT => return error.DiskQuota,
                    .FBIG => return error.FileTooBig,
                    .IO => return error.InputOutput,
                    .NOSPC => return error.NoSpaceLeft,
                    .PERM => return error.AccessDenied,
                    .PIPE => return error.BrokenPipe,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .BUSY => return error.LockViolation,
                    .NXIO => return error.NoDevice,
                    .SRCH => return error.ProcessNotFound,
                    else => |err| return unexpectedErrno(err),
                }
            },
        }
    }
}

pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
    BadFileDescriptor,
    Unexpected,
};

pub fn fcntl(fd: posix.fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        switch (native_os) {
            .linux => {
                const rc = linux.fcntl(fd, cmd, arg);
                switch (errno(rc)) {
                    .SUCCESS => return @intCast(@as(isize, @bitCast(rc))),
                    .INTR => continue,
                    .INVAL => unreachable,
                    // fcntl can race a close on another thread when the
                    // calling code is inspecting an accepted-then-abandoned
                    // socket. Surface BADF rather than panic.
                    .BADF => return error.BadFileDescriptor,
                    .ACCES => return error.PermissionDenied,
                    .AGAIN => return error.Locked,
                    .BUSY => return error.FileBusy,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .DEADLK => return error.DeadLock,
                    .NOLCK => return error.LockedRegionLimitExceeded,
                    .PERM => return error.PermissionDenied,
                    else => |err| return unexpectedErrno(err),
                }
            },
            else => {
                // On macOS/BSD, fcntl returns c_int. -1 on error. Any other
                // value (including ones with the high 32-bit bit set, e.g.
                // an inherited `O_CLOEXEC | O_NONBLOCK | ...` flagset) is a
                // success. The 0.15 shim bitcast isize↔usize would corrupt
                // negative-looking-but-really-positive flag returns; widen
                // directly via `@as(u32, @bitCast(rc))` → usize instead.
                const rc = c.fcntl(fd, cmd, arg);
                if (rc == -1) {
                    switch (errno(rc)) {
                        .SUCCESS => unreachable,
                        .INTR => continue,
                        .INVAL => unreachable,
                        .BADF => return error.BadFileDescriptor,
                        .ACCES => return error.PermissionDenied,
                        .AGAIN => return error.Locked,
                        .BUSY => return error.FileBusy,
                        .MFILE => return error.ProcessFdQuotaExceeded,
                        .DEADLK => return error.DeadLock,
                        .NOLCK => return error.LockedRegionLimitExceeded,
                        .PERM => return error.PermissionDenied,
                        else => |err| return unexpectedErrno(err),
                    }
                }
                return @as(u32, @bitCast(rc));
            },
        }
    }
}

// ── sockets ────────────────────────────────────────────────────────────────

pub const SocketError = error{
    PermissionDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    Unexpected,
};

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!posix.socket_t {
    // On Darwin/FreeBSD, SOCK.CLOEXEC and SOCK.NONBLOCK are Zig-invented
    // sentinel bits (not real kernel flags); the wrapper must strip them
    // and apply via fcntl after socket() succeeds. Only Linux accepts
    // these flags directly to socket(2). Match 0.15's behavior.
    const cloexec_bit: u32 = @intCast(posix.SOCK.CLOEXEC);
    const nonblock_bit: u32 = @intCast(posix.SOCK.NONBLOCK);
    const type_to_pass: u32 = if (native_os == .linux)
        socket_type
    else
        socket_type & ~(cloexec_bit | nonblock_bit);

    const fd: posix.socket_t = switch (native_os) {
        .linux => blk: {
            const rc = linux.socket(domain, type_to_pass, protocol);
            switch (errno(rc)) {
                .SUCCESS => break :blk @intCast(rc),
                .ACCES => return error.PermissionDenied,
                .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                .INVAL => return error.ProtocolFamilyNotAvailable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .PROTONOSUPPORT => return error.ProtocolNotSupported,
                .PROTOTYPE => return error.SocketTypeNotSupported,
                else => |err| return unexpectedErrno(err),
            }
        },
        else => blk: {
            const rc = c.socket(@intCast(domain), @intCast(type_to_pass), @intCast(protocol));
            if (rc == -1) {
                switch (errno(rc)) {
                    .SUCCESS => unreachable,
                    .ACCES => return error.PermissionDenied,
                    .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .INVAL => return error.ProtocolFamilyNotAvailable,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .PROTONOSUPPORT => return error.ProtocolNotSupported,
                    .PROTOTYPE => return error.SocketTypeNotSupported,
                    else => |err| return unexpectedErrno(err),
                }
            }
            break :blk @intCast(rc);
        },
    };
    errdefer close(fd);

    if (native_os != .linux) {
        // Route flag writes through our safe fcntl shim rather than c.fcntl
        // directly — the shim normalizes the c_int → usize conversion so
        // flag returns with bit 31 set don't panic the @intCast.
        if ((socket_type & cloexec_bit) != 0) {
            if (fcntl(fd, posix.F.GETFD, 0) catch null) |cur| {
                _ = fcntl(fd, posix.F.SETFD, cur | posix.FD_CLOEXEC) catch {};
            }
        }
        if ((socket_type & nonblock_bit) != 0) {
            if (fcntl(fd, posix.F.GETFL, 0) catch null) |cur| {
                _ = fcntl(fd, posix.F.SETFL, cur | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch {};
            }
        }
    }

    return fd;
}

pub const BindError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    NetworkSubsystemFailed,
    AlreadyBound,
    Unexpected,
};

pub fn bind(sock: posix.socket_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) BindError!void {
    const e = switch (native_os) {
        .linux => errno(linux.bind(sock, addr, addr_len)),
        else => blk: {
            const rc = c.bind(sock, addr, addr_len);
            if (rc == 0) return;
            break :blk errno(rc);
        },
    };
    switch (e) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable,
        .INVAL => return error.AlreadyBound,
        .NOTSOCK => unreachable,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .FAULT => unreachable,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources catch error.Unexpected,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    NetworkSubsystemFailed,
    SystemResources,
    Unexpected,
};

pub fn listen(sock: posix.socket_t, backlog: u31) ListenError!void {
    const e = switch (native_os) {
        .linux => errno(linux.listen(sock, backlog)),
        else => blk: {
            const rc = c.listen(sock, backlog);
            if (rc == 0) return;
            break :blk errno(rc);
        },
    };
    switch (e) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub const AcceptError = error{
    ConnectionAborted,
    FileDescriptorNotASocket,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    ProtocolFailure,
    BlockedByFirewall,
    WouldBlock,
    NetworkSubsystemFailed,
    OperationNotSupported,
    Canceled,
    Unexpected,
};

pub fn accept(
    sock: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) AcceptError!posix.socket_t {
    while (true) {
        const e: posix.E = switch (native_os) {
            .linux => blk: {
                const rc = linux.accept4(sock, addr, addr_size, flags);
                const e = errno(rc);
                if (e == .SUCCESS) return @intCast(@as(isize, @bitCast(rc)));
                break :blk e;
            },
            else => blk: {
                // macOS/BSD don't have accept4; use accept + fcntl for NONBLOCK/CLOEXEC.
                const nonblock = (flags & @as(u32, @intCast(posix.SOCK.NONBLOCK))) != 0;
                const cloexec = (flags & @as(u32, @intCast(posix.SOCK.CLOEXEC))) != 0;
                const fd = c.accept(sock, addr, addr_size);
                if (fd < 0) break :blk errno(fd);
                // Apply flags via our safe fcntl shim so flag values with
                // the high 32-bit bit set don't corrupt the bitcast.
                if (nonblock) {
                    const cur = fcntl(fd, posix.F.GETFL, 0) catch return @intCast(fd);
                    _ = fcntl(fd, posix.F.SETFL, cur | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch {};
                }
                if (cloexec) {
                    const cur = fcntl(fd, posix.F.GETFD, 0) catch return @intCast(fd);
                    _ = fcntl(fd, posix.F.SETFD, cur | posix.FD_CLOEXEC) catch {};
                }
                return @intCast(fd);
            },
        };
        switch (e) {
            .SUCCESS => unreachable,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => unreachable,
            .CONNABORTED => return error.ConnectionAborted,
            .FAULT => unreachable,
            .INVAL => return error.SocketNotListening,
            .NOTSOCK => return error.FileDescriptorNotASocket,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .OPNOTSUPP => return error.OperationNotSupported,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const ShutdownError = error{
    ConnectionAborted,
    ConnectionResetByPeer,
    BlockingOperationInProgress,
    FileDescriptorNotASocket,
    SocketNotConnected,
    SystemResources,
    Unexpected,
};

pub fn shutdown(sock: posix.socket_t, how: std.Io.net.ShutdownHow) ShutdownError!void {
    const how_num: i32 = switch (how) {
        .recv => 0,
        .send => 1,
        .both => 2,
    };
    const e = switch (native_os) {
        .linux => errno(linux.shutdown(sock, how_num)),
        else => blk: {
            const rc = c.shutdown(sock, how_num);
            if (rc == 0) return;
            break :blk errno(rc);
        },
    };
    switch (e) {
        .SUCCESS => return,
        .BADF => unreachable,
        .INVAL => unreachable,
        .NOTCONN => return error.SocketNotConnected,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const GetSockNameError = error{
    SystemResources,
    SocketNotBound,
    FileDescriptorNotASocket,
    NetworkSubsystemFailed,
    Unexpected,
};

pub fn getsockname(
    sock: posix.socket_t,
    addr: *posix.sockaddr,
    addr_len: *posix.socklen_t,
) GetSockNameError!void {
    const e = switch (native_os) {
        .linux => errno(linux.getsockname(sock, addr, addr_len)),
        else => blk: {
            const rc = c.getsockname(sock, addr, addr_len);
            if (rc == 0) return;
            break :blk errno(rc);
        },
    };
    switch (e) {
        .SUCCESS => return,
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

// ── kqueue (macOS/BSD) ─────────────────────────────────────────────────────

pub const KQueueError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

pub fn kqueue() KQueueError!i32 {
    const rc = c.kqueue();
    if (rc >= 0) return rc;
    switch (errno(rc)) {
        .SUCCESS => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return unexpectedErrno(err),
    }
}

pub const KEventError = error{
    EventNotFound,
    SystemResources,
    ProcessNotFound,
    AccessDenied,
    Overflow,
    Unexpected,
};

pub fn kevent(
    kq: i32,
    changelist: []const posix.Kevent,
    eventlist: []posix.Kevent,
    timeout: ?*const posix.timespec,
) KEventError!usize {
    // Delegate to std.Io.Kqueue.kevent — same signature, proven errno handling.
    return std.Io.Kqueue.kevent(kq, changelist, eventlist, timeout);
}

// ── epoll / eventfd (Linux) ────────────────────────────────────────────────

pub const EpollCreateError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
};

pub fn epoll_create1(flags: u32) EpollCreateError!i32 {
    const rc = linux.epoll_create1(flags);
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INVAL => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const EpollCtlError = error{
    FileDescriptorAlreadyPresentInSet,
    OperationCausesCircularLoop,
    FileDescriptorNotRegistered,
    SystemResources,
    UserResourceLimitReached,
    FileDescriptorIncompatibleWithEpoll,
    Unexpected,
};

pub fn epoll_ctl(epfd: i32, op: u32, fd: i32, event: ?*linux.epoll_event) EpollCtlError!void {
    const rc = linux.epoll_ctl(epfd, op, fd, event);
    switch (errno(rc)) {
        .SUCCESS => return,
        .BADF => unreachable,
        .EXIST => return error.FileDescriptorAlreadyPresentInSet,
        .INVAL => unreachable,
        .LOOP => return error.OperationCausesCircularLoop,
        .NOENT => return error.FileDescriptorNotRegistered,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.UserResourceLimitReached,
        .PERM => return error.FileDescriptorIncompatibleWithEpoll,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn epoll_wait(epfd: i32, events: []linux.epoll_event, timeout: i32) usize {
    // 0.15 posix.epoll_wait retried on EINTR and returned the count. We match
    // that here rather than returning an error set.
    while (true) {
        const rc = linux.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => unreachable,
        }
    }
}

pub const EventFdError = error{
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

pub fn eventfd(initval: u32, flags: u32) EventFdError!i32 {
    const rc = linux.eventfd(initval, flags);
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INVAL => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NODEV => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

// ── clock / entropy ────────────────────────────────────────────────────────

pub const ClockGetTimeError = error{ UnsupportedClock, Unexpected };

pub fn clock_gettime(clock_id: posix.clockid_t) ClockGetTimeError!posix.timespec {
    var ts: posix.timespec = undefined;
    const e = switch (native_os) {
        .linux => errno(linux.clock_gettime(@intFromEnum(clock_id), &ts)),
        else => blk: {
            const rc = c.clock_gettime(clock_id, &ts);
            if (rc == 0) return ts;
            break :blk errno(rc);
        },
    };
    switch (e) {
        .SUCCESS => return ts,
        .INVAL => return error.UnsupportedClock,
        else => |err| return unexpectedErrno(err),
    }
}

pub const GetRandomError = error{ Unexpected };

pub fn getrandom(buf: []u8) GetRandomError!void {
    switch (native_os) {
        .linux => {
            while (true) {
                const rc = linux.getrandom(buf.ptr, buf.len, 0);
                switch (errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    else => |err| return unexpectedErrno(err),
                }
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // arc4random_buf never fails.
            c.arc4random_buf(buf.ptr, buf.len);
            return;
        },
        else => {
            // Fall back to /dev/urandom.
            var remaining = buf;
            const fd = c.open("/dev/urandom", c.O.RDONLY, 0);
            if (fd < 0) return error.Unexpected;
            defer _ = c.close(fd);
            while (remaining.len > 0) {
                const n = c.read(fd, remaining.ptr, remaining.len);
                if (n <= 0) return error.Unexpected;
                remaining = remaining[@intCast(n)..];
            }
        },
    }
}

pub const ConnectError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    WouldBlock,
    ConnectionPending,
    FileNotFound,
    NetworkUnreachable,
    PermissionDenied,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    SystemResources,
    NetworkSubsystemFailed,
    Canceled,
    Unexpected,
};

// ── Stream (0.15 std.net.Stream compat) ───────────────────────────────────
//
// 0.16's `std.Io.net.Stream` wraps a Socket with `.socket.handle`. httpz's
// call sites just want a socket fd wrapper; define the minimal shape so
// `.stream = .{ .handle = socket }` construction and `stream.handle` access
// continue to work unchanged.
pub const Stream = struct {
    handle: posix.socket_t,

    /// 0.15-shape nested types. `Writer` aliases 0.16's real
    /// `std.Io.net.Stream.Writer`. `Reader` aliases our `RawReader` (below)
    /// so reads go through our raw `read()` shim and don't panic on EAGAIN.
    pub const Writer = std.Io.net.Stream.Writer;
    pub const Reader = RawReader;

    pub fn close(self: Stream) void {
        closeFd(self.handle);
    }

    pub fn read(self: Stream, buf: []u8) ReadError!usize {
        return readFd(self.handle, buf);
    }

    /// Loop on `read` until at least `min` bytes are accumulated or EOF.
    /// Mirrors 0.15 `std.net.Stream.readAtLeast`. Returns actual bytes
    /// read (≥ min on success, < min only on EOF).
    pub fn readAtLeast(self: Stream, buf: []u8, min: usize) ReadError!usize {
        std.debug.assert(min <= buf.len);
        var total: usize = 0;
        while (total < min) {
            const n = try self.read(buf[total..]);
            if (n == 0) return total;
            total += n;
        }
        return total;
    }

    /// Write the full buffer, looping on short writes. Mirrors 0.15's
    /// `std.net.Stream.writeAll` behaviour.
    pub fn writeAll(self: Stream, bytes: []const u8) WriteError!void {
        var i: usize = 0;
        while (i < bytes.len) {
            const n = try writeFd(self.handle, bytes[i..]);
            if (n == 0) return error.BrokenPipe;
            i += n;
        }
    }

    pub fn writeStreamingAll(self: Stream, _: std.Io, bytes: []const u8) WriteError!void {
        return self.writeAll(bytes);
    }

    /// Construct a 0.16 `std.Io.net.Stream.Writer` over this socket fd.
    /// Pulls `io` from the httpz-internal process-wide shim so callers
    /// don't have to thread it through. The address placeholder is unused
    /// by the Writer (it's a peer-info field populated by listen/connect).
    pub fn writer(self: Stream, buffer: []u8) std.Io.net.Stream.Writer {
        const io_shim = @import("io_shim.zig");
        const s: std.Io.net.Stream = .{
            .socket = .{ .handle = self.handle, .address = .{ .ip4 = .loopback(0) } },
        };
        return std.Io.net.Stream.Writer.init(s, io_shim.stdio(), buffer);
    }

    /// A 0.15-shape Io.Reader over this socket fd. Differs from
    /// `std.Io.net.Stream.Reader` by NOT routing through `Io.Threaded`'s
    /// netReadPosix, which panics on EAGAIN. Reads go through our raw
    /// `read()` shim, which returns `error.WouldBlock` so callers can
    /// honour SO_RCVTIMEO-style timeouts without a programmer-bug panic.
    pub const RawReader = struct {
        handle: posix.socket_t,
        interface: std.Io.Reader,
        err: ?ReadError,

        pub fn init(fd: posix.socket_t, buffer: []u8) RawReader {
            return .{
                .handle = fd,
                .err = null,
                .interface = .{
                    .vtable = &.{
                        .stream = streamImpl,
                        .readVec = readVecImpl,
                    },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *RawReader = @alignCast(@fieldParentPtr("interface", io_r));
            const dest = limit.slice(try io_w.writableSliceGreedy(1));
            const n = readFd(self.handle, dest) catch |e| {
                self.err = e;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            io_w.advance(n);
            return n;
        }

        fn readVecImpl(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            const self: *RawReader = @alignCast(@fieldParentPtr("interface", io_r));
            // readVec writes into the interface buffer if any space is there,
            // otherwise direct into data[0]. Match std.Io.net.Stream.Reader's
            // semantics.
            if (data.len == 0 or data[0].len == 0) return 0;
            const n = readFd(self.handle, data[0]) catch |e| {
                self.err = e;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            return n;
        }
    };

    /// Reader that avoids `Io.Threaded`'s EAGAIN-is-programmer-bug panic.
    /// Shape is drop-in compatible with `std.Io.net.Stream.Reader` —
    /// `.interface` is an `Io.Reader`, and `.err` stashes the last read
    /// error for callers that inspect it.
    pub fn reader(self: Stream, buffer: []u8) RawReader {
        return RawReader.init(self.handle, buffer);
    }
};

/// 0.15 `std.net.tcpConnectToHost` compat — resolves `name` via the system
/// resolver, connects to the first reachable IP, returns a Stream wrapping
/// the socket fd. Mirrors the old signature so call sites don't change.
pub fn tcpConnectToHost(allocator: std.mem.Allocator, name: []const u8, port: u16) !Stream {
    _ = allocator; // 0.16 resolver uses page allocator internally
    const io_shim = @import("io_shim.zig");
    const host = try std.Io.net.HostName.init(name);
    const s = try host.connect(io_shim.stdio(), port, .{ .mode = .stream });
    return .{ .handle = s.socket.handle };
}

// 0.15 `std.net.tcpConnectToAddress` compat — opens a TCP socket and
// connects to the supplied address, returning a Stream wrapping the fd.
// Used by the test suite, mirrors the old helper so test code keeps the
// same shape.
pub fn tcpConnectToAddress(address: Address) !Stream {
    const family: u32 = switch (address.any.family) {
        posix.AF.INET => posix.AF.INET,
        posix.AF.INET6 => posix.AF.INET6,
        posix.AF.UNIX => posix.AF.UNIX,
        else => return error.AddressFamilyUnsupported,
    };
    const sock_type: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const fd = try socket(family, sock_type, if (family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP);
    errdefer close(fd);
    try connect(fd, &address.any, address.getOsSockLen());
    return .{ .handle = fd };
}

pub const PipeError = error{
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

/// 0.15-shape `posix.pipe2(flags)`. On Linux uses the raw `pipe2` syscall;
/// on macOS/BSD which lack `pipe2`, emulates via `pipe(fd[2])` + `fcntl` to
/// install the requested `O_NONBLOCK`/`O_CLOEXEC` flags on both ends.
pub fn pipe2(flags: posix.O) PipeError![2]posix.fd_t {
    var fds: [2]c_int = undefined;
    switch (native_os) {
        .linux => {
            const rc = linux.pipe2(&fds, @as(u32, @bitCast(flags)));
            switch (errno(rc)) {
                .SUCCESS => return .{ fds[0], fds[1] },
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOMEM => return error.SystemResources,
                else => |err| return unexpectedErrno(err),
            }
        },
        else => {
            if (c.pipe(&fds) != 0) {
                switch (errno(@as(c_int, -1))) {
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOMEM => return error.SystemResources,
                    else => |err| return unexpectedErrno(err),
                }
            }
            // Apply flags via our safe fcntl shim (handles the c_int → usize
            // conversion correctly for flag returns with bit 31 set).
            const nonblock = flags.NONBLOCK;
            const cloexec = flags.CLOEXEC;
            for (fds) |fd| {
                if (nonblock) {
                    if (fcntl(fd, posix.F.GETFL, 0) catch null) |cur| {
                        _ = fcntl(fd, posix.F.SETFL, cur | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch {};
                    }
                }
                if (cloexec) {
                    if (fcntl(fd, posix.F.GETFD, 0) catch null) |cur| {
                        _ = fcntl(fd, posix.F.SETFD, cur | posix.FD_CLOEXEC) catch {};
                    }
                }
            }
            return .{ fds[0], fds[1] };
        },
    }
}

// ── Address (0.15 std.net.Address compat) ─────────────────────────────────
//
// 0.16 split what used to be `std.net.Address` (a tagged-ish union with an
// embedded sockaddr) into two separate types: `std.Io.net.IpAddress` (IP-only,
// high-level) and `std.Io.net.UnixAddress`. Neither exposes the raw sockaddr
// byte layout that httpz's event-loop code reads/writes directly via
// `.any.family`, `.getOsSockLen()`, and `&addr.any` for the posix socket
// syscalls.
//
// We reintroduce the 0.15 shape as an extern union matching the four legacy
// variants. The parsing/formatting helpers match the old API so call sites
// (both httpz internal and user code like local_server.zig's
// `.{ .addr = .{ .ip4 = ... } }`) continue to work unchanged.

pub const Address = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
    un: if (@hasDecl(posix.sockaddr, "un")) posix.sockaddr.un else posix.sockaddr,

    pub fn parseIp(name: []const u8, port: u16) !Address {
        const ip = try std.Io.net.IpAddress.parse(name, port);
        return fromIpAddress(ip);
    }

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        // 0.16 `posix.sockaddr.in` declares field defaults for `len`/`family`/
        // `zero`, but extern-struct zero-init in Zig doesn't always pick them
        // up on cross-platform builds (macOS `in` has `len`; Linux does not).
        // Set the required fields explicitly so the kernel sees AF_INET.
        var r: Address = undefined;
        @memset(std.mem.asBytes(&r), 0);
        r.in.family = posix.AF.INET;
        if (@hasField(posix.sockaddr.in, "len")) r.in.len = @sizeOf(posix.sockaddr.in);
        r.in.port = std.mem.nativeToBig(u16, port);
        r.in.addr = @bitCast(bytes);
        return r;
    }

    pub fn initIp6(bytes: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        var r: Address = undefined;
        @memset(std.mem.asBytes(&r), 0);
        r.in6.family = posix.AF.INET6;
        if (@hasField(posix.sockaddr.in6, "len")) r.in6.len = @sizeOf(posix.sockaddr.in6);
        r.in6.port = std.mem.nativeToBig(u16, port);
        r.in6.flowinfo = flowinfo;
        r.in6.addr = bytes;
        r.in6.scope_id = scope_id;
        return r;
    }

    pub const UnixInitError = error{ NameTooLong, PathnameTooLong };

    pub fn initUnix(path: []const u8) UnixInitError!Address {
        if (!@hasDecl(posix.sockaddr, "un")) return error.NameTooLong;
        var a: Address = undefined;
        a.un.family = posix.AF.UNIX;
        if (path.len >= a.un.path.len) return error.PathnameTooLong;
        @memcpy(a.un.path[0..path.len], path);
        a.un.path[path.len] = 0;
        return a;
    }

    pub fn fromIpAddress(ip: std.Io.net.IpAddress) Address {
        return switch (ip) {
            .ip4 => |v| initIp4(v.bytes, v.port),
            .ip6 => |v| initIp6(v.bytes, v.port, v.flow, v.interface.index),
        };
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        return switch (self.any.family) {
            posix.AF.INET => @sizeOf(posix.sockaddr.in),
            posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
            posix.AF.UNIX => if (@hasDecl(posix.sockaddr, "un"))
                @intCast(@offsetOf(posix.sockaddr.un, "path") + std.mem.indexOfScalar(u8, &self.un.path, 0).? + 1)
            else
                @sizeOf(posix.sockaddr),
            else => @sizeOf(posix.sockaddr),
        };
    }

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.any.family) {
            posix.AF.INET => {
                const port = std.mem.bigToNative(u16, self.in.port);
                const bytes: [4]u8 = @bitCast(self.in.addr);
                try w.print("{d}.{d}.{d}.{d}:{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3], port });
            },
            posix.AF.INET6 => {
                const port = std.mem.bigToNative(u16, self.in6.port);
                try w.print("[ipv6]:{d}", .{port});
            },
            posix.AF.UNIX => try w.writeAll("unix"),
            else => try w.writeAll("?"),
        }
    }
};

pub fn connect(sock: posix.socket_t, addr: *const posix.sockaddr, addr_len: posix.socklen_t) ConnectError!void {
    while (true) {
        switch (native_os) {
            .linux => {
                const rc = linux.connect(sock, addr, addr_len);
                switch (errno(rc)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    .ACCES, .PERM => return error.AccessDenied,
                    .ADDRINUSE => return error.AddressInUse,
                    .ADDRNOTAVAIL => return error.AddressNotAvailable,
                    .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .AGAIN, .INPROGRESS => return error.WouldBlock,
                    .ALREADY => return error.ConnectionPending,
                    .BADF => unreachable,
                    .CANCELED => return error.Canceled,
                    .CONNREFUSED => return error.ConnectionRefused,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .FAULT => unreachable,
                    .ISCONN => unreachable,
                    .NETUNREACH => return error.NetworkUnreachable,
                    .NOTSOCK => unreachable,
                    .TIMEDOUT => return error.ConnectionTimedOut,
                    else => |err| return unexpectedErrno(err),
                }
            },
            else => {
                // Keep c.connect's c_int return value so std.c.errno can
                // detect -1 by value (not bit pattern). Bitcasting to usize
                // breaks `rc == -1` because Zig compares integer values, not
                // bits, and `usize(0xFFFFFFFFFFFFFFFF) == -1` is FALSE.
                const rc = c.connect(sock, addr, addr_len);
                if (rc == 0) return;
                switch (errno(rc)) {
                    .SUCCESS => unreachable,
                    .INTR => continue,
                    .ACCES, .PERM => return error.AccessDenied,
                    .ADDRINUSE => return error.AddressInUse,
                    .ADDRNOTAVAIL => return error.AddressNotAvailable,
                    .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .AGAIN, .INPROGRESS => return error.WouldBlock,
                    .ALREADY => return error.ConnectionPending,
                    .BADF => unreachable,
                    .CANCELED => return error.Canceled,
                    .CONNREFUSED => return error.ConnectionRefused,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .FAULT => unreachable,
                    .ISCONN => unreachable,
                    .NETUNREACH => return error.NetworkUnreachable,
                    .NOTSOCK => unreachable,
                    .TIMEDOUT => return error.ConnectionTimedOut,
                    else => |err| return unexpectedErrno(err),
                }
            },
        }
    }
}
