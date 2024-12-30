const std = @import("std");
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const io = @import("io/io.zig");
const Tcp = @import("tcp.zig").Tcp;
const tls = @import("tls");

const log = std.log.scoped(.tls);

pub fn Tls(comptime ClientType: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        client: ClientType,
        tcp: Tcp(*Self),
        handshake: ?*tls.AsyncHandshakeClient = null,
        cipher: tls.Cipher = undefined,
        recv_buf: RecvBuf,
        write_buf: [tls.max_ciphertext_record_len]u8 = undefined,

        state: State = .closed,

        const State = enum {
            closed,
            connecting,
            handshake,
            connected,
        };

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            ev: *io.Ev,
            client: ClientType,
        ) void {
            self.* = .{
                .allocator = allocator,
                .tcp = Tcp(*Self).init(allocator, ev, self),
                .client = client,
                .recv_buf = RecvBuf.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.tcp.deinit();
            if (self.handshake) |h| self.allocator.destroy(h);
            self.recv_buf.free();
        }

        pub fn connect(self: *Self, address: net.Address, opt: tls.ClientOptions) !void {
            const handshake = try self.allocator.create(tls.AsyncHandshakeClient);
            errdefer self.allocator.destroy(handshake);
            try handshake.init(opt);
            self.tcp.connect(address);
            self.handshake = handshake;
            self.state = .connecting;
        }

        pub fn onConnect(self: *Self) !void {
            self.state = .handshake;
            try self.handshakeSend();
        }

        pub fn onRecv(self: *Self, bytes: []const u8) !void {
            const buf = try self.recv_buf.append(bytes);

            const n = if (self.handshake) |_|
                try self.handshakeRecv(buf)
            else
                self.decrypt(buf) catch |err| {
                    log.err("decrypt {}", .{err});
                    return self.tcp.close();
                };

            try self.recv_buf.set(buf[n..]);
        }

        fn decrypt(self: *Self, buf: []const u8) !usize {
            const InnerReader = std.io.FixedBufferStream([]const u8);
            var rr = tls.record.reader(InnerReader{ .buffer = buf, .pos = 0 });

            while (true) {
                const content_type, const cleartext = try rr.nextDecrypt(&self.cipher) orelse break;
                switch (content_type) {
                    .application_data => {},
                    .handshake => {
                        // TODO handle key_update and new_session_ticket separatly
                        continue;
                    },
                    .alert => {
                        self.tcp.close();
                        return 0;
                    },
                    else => {
                        log.err("unexpected content_type {}", .{content_type});
                        self.tcp.close();
                        return 0;
                    },
                }

                assert(content_type == .application_data);
                try self.client.onRecv(cleartext);
            }
            const ir = &rr.inner_reader;
            const unread = (ir.buffer.len - ir.pos) + (rr.end - rr.start);
            return buf.len - unread;
        }

        fn handshakeSend(self: *Self) io.Error!void {
            assert(self.state == .handshake);
            var h = self.handshake orelse unreachable;
            if (h.send() catch |err| {
                log.err("handshake send {}", .{err});
                return self.tcp.close();
            }) |buf| {
                try self.tcp.send(buf);
            }
        }

        fn handshakeRecv(self: *Self, buf: []const u8) !usize {
            assert(self.state == .handshake);
            var h = self.handshake orelse unreachable;
            const n = h.recv(buf) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => {
                    log.err("handshake recv {}", .{err});
                    self.tcp.close();
                    return 0;
                },
            };
            self.handshakeDone();
            if (n > 0 and self.state == .handshake) try self.handshakeSend();
            return n;
        }

        fn handshakeDone(self: *Self) void {
            assert(self.state == .handshake);
            var h = self.handshake orelse unreachable;
            if (!h.done()) return;
            log.debug("handshake done", .{});

            self.cipher = h.appCipher().?;
            self.allocator.destroy(h);
            self.handshake = null;
            self.state = .connected;
            self.client.onConnect() catch |err| {
                log.err("client connect {}", .{err});
                self.tcp.close();
            };
        }

        pub fn send(self: *Self, bytes: []const u8) !void {
            if (self.state != .connected) return error.InvalidState;

            var index: usize = 0;
            while (index < bytes.len) {
                const n = @min(bytes.len, tls.max_cleartext_len);
                const buf = bytes[index..][0..n];
                index += n;

                const rec_buf = try self.allocator.alloc(u8, self.cipher.recordLen(buf.len));
                const rec = self.cipher.encrypt(rec_buf, .application_data, buf) catch |err| {
                    log.err("encrypt {}", .{err});
                    return self.tcp.close();
                };
                assert(rec.len == rec_buf.len);
                try self.tcp.send(rec);
            }

            // // TODO sta kada je buf jako velik

            // // We don't know exact cipher record; some algorithms are adding padding
            // const rec_buf = try self.allocator.alloc(u8, self.cipher.recordLen(buf.len));
            // log.debug("send alloc {} {*}", .{ rec_buf.len, rec_buf.ptr });
            // const rec = self.cipher.encrypt(rec_buf, .application_data, buf) catch |err| {
            //     log.err("encrypt {}", .{err});
            //     return self.tcp.close();
            // };
            // assert(rec.len == rec_buf.len);
            // try self.tcp.send(rec);

            // // const send_rec = if (self.allocator.resize(rec_buf, rec.len))
            // //     rec
            // // else brk: {
            // //     log.debug("send resize new_memory {}", .{rec_buf.len});
            // //     const new_memory = try self.allocator.alloc(u8, rec.len);
            // //     @memcpy(new_memory, rec);
            // //     self.allocator.free(rec_buf);
            // //     break :brk new_memory;
            // // };

            // // log.debug("send finaly {} {*}", .{ send_rec.len, send_rec.ptr });
            // // try self.tcp.send(send_rec);
        }

        pub fn onSend(self: *Self, buf: []const u8) void {
            log.debug("onSend buf.len {}", .{buf.len});
            // TODO release send buf
            switch (self.state) {
                .handshake => self.handshakeDone(),
                else => {
                    log.debug("onSend free {} {*}", .{ buf.len, buf.ptr });
                    self.allocator.free(buf);
                },
            }
        }

        pub fn close(self: *Self) void {
            self.tcp.close();
        }

        pub fn onClose(self: *Self) void {
            self.state = .closed;
            self.client.onClose();
        }
    };
}

pub const RecvBuf = struct {
    allocator: mem.Allocator,
    buf: []u8 = &.{},

    const Self = @This();

    pub fn init(allocator: mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn free(self: *Self) void {
        self.allocator.free(self.buf);
        self.buf = &.{};
    }

    pub fn append(self: *Self, bytes: []const u8) ![]const u8 {
        if (self.buf.len == 0) return bytes;
        const old_len = self.buf.len;
        self.buf = try self.allocator.realloc(self.buf, old_len + bytes.len);
        @memcpy(self.buf[old_len..], bytes);
        return self.buf;
    }

    pub fn set(self: *Self, bytes: []const u8) !void {
        if (bytes.len == 0) return self.free();
        if (self.buf.len == bytes.len and self.buf.ptr == bytes.ptr) return;

        const new_buf = try self.allocator.dupe(u8, bytes);
        self.free();
        self.buf = new_buf;
    }
};
