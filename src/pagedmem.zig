const std = @import("std");

const FileScope = @This();
pub const Utf8DecodeUtf16Le = struct {
    end: usize,
    value: ?u16,
};

/// A growable non-continguous group of fixed-width memory pages.
///
/// Access is O(1).
pub fn PagedMem(comptime page_size: usize) type {
    return struct {
        len: usize = 0,
        mmu: std.ArrayListUnmanaged(*[page_size]u8) = .{},

        pub const Slice = FileScope.PagedMemSlice(page_size);
        pub const Utf8Decode = FileScope.Utf8Decode;

        const Self = @This();
        pub fn deinit(self: *Self) void {
            for (self.mmu.items) |page| {
                std.heap.page_allocator.free(page);
            }
            self.mmu.deinit(std.heap.page_allocator);
        }

        pub fn getCapacity(self: Self) usize {
            return self.mmu.items.len * page_size;
        }

        pub fn writeByte(self: *Self, b: u8) error{OutOfMemory}!void {
            const read_buf = try self.getReadBuf();
            std.debug.assert(read_buf.len > 0);
            read_buf[0] = b;
            self.finishRead(1);
        }

        pub fn writeMax(self: *Self, bytes: []const u8) usize {
            var added: usize = 0;
            while (added < bytes.len) {
                const read_buf = self.getReadBuf() catch break;
                std.debug.assert(read_buf.len > 0);
                const copy_len = @min(bytes.len - added, read_buf.len);
                @memcpy(read_buf[0..copy_len], bytes[added..][0..copy_len]);
                added += copy_len;
                self.finishRead(copy_len);
            }
            return added;
        }

        pub const Writer = std.io.Writer(*Self, error{OutOfMemory}, writerFn);
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
        fn writerFn(self: *Self, bytes: []const u8) error{OutOfMemory}!usize {
            const original_len = self.len;
            const len = self.writeMax(bytes);
            if (len != bytes.len) {
                self.len = original_len;
                return error.OutOfMemory;
            }
            return len;
        }

        pub fn getReadBuf(self: *Self) error{OutOfMemory}![]u8 {
            if (page_size != std.mem.page_size_min) @compileError("cannot call getReadBuf unless page size is std.mem.page_size");

            const capacity = self.getCapacity();
            if (self.len == capacity) {
                const page = try std.heap.page_allocator.alloc(u8, page_size);
                errdefer std.heap.page_allocator.free(page);
                try self.mmu.append(std.heap.page_allocator, @ptrCast(page.ptr));
                std.debug.assert(self.getCapacity() > self.len);
                return page[0..page_size];
            }
            std.debug.assert(self.mmu.items.len > 0);
            return self.mmu.items[self.mmu.items.len - 1][self.len % page_size .. page_size];
        }

        pub fn finishRead(self: *Self, len: usize) void {
            std.debug.assert(len <= (self.getReadBuf() catch unreachable).len);
            self.len += len;
        }

        pub fn sliceAll(self: *const Self) PagedMemSlice(page_size) {
            return .{ .len = self.len, .pages = self.mmu.items.ptr };
        }
        pub fn sliceTo(self: *const Self, len: usize) PagedMemSlice(page_size) {
            std.debug.assert(len <= self.len);
            return .{ .len = len, .pages = self.mmu.items.ptr };
        }

        pub fn setByte(self: *const Self, offset: usize, value: u8) void {
            self.mmu.items[@divTrunc(offset, page_size)][offset % page_size] = value;
        }
        pub fn getByte(self: *const Self, offset: usize) u8 {
            return self.mmu.items[@divTrunc(offset, page_size)][offset % page_size];
        }
        pub fn lastByte(self: *const Self) ?u8 {
            return if (self.len == 0) null else self.getByte(self.len - 1);
        }

        // returns the index immediately after the given `what` byte of the first
        // occurence searching in reverse
        pub fn scanBackwardsScalar(self: *const Self, limit: usize, what: u8) usize {
            return self.sliceAll().scanBackwardsScalar(limit, what);
        }

        pub fn utf8DecodeUtf16Le(
            self: *const Self,
            offset: usize,
            limit: usize,
        ) error{ Utf8InvalidStartByte, Truncated }!FileScope.Utf8DecodeUtf16Le {
            return self.slice().utf8Decode(offset, limit);
        }
    };
}

// Analagous to a conventional slice in Zig. Consists of a pointer and a length.
// Use when you want to pass around/store an instance of PagedMem by value.
// The slice is a non-owning reference to the pages that is unable to change
// the size of the underlying PagedMem instance.
pub fn PagedMemSlice(comptime page_size: usize) type {
    return struct {
        pages: [*]const *[page_size]u8,
        len: usize,

        const Self = @This();

        pub fn getByte(self: *const Self, offset: usize) u8 {
            std.debug.assert(offset < self.len);
            return self.pages[@divTrunc(offset, page_size)][offset % page_size];
        }

        // returns the index immediately after the given `what` byte of the first
        // occurence searching in reverse
        pub fn scanBackwardsScalar(self: *const Self, limit: usize, what: u8) usize {
            std.debug.assert(limit <= self.len);
            var offset = limit;
            while (offset > 0) {
                const next_offset = offset - 1;
                if (what == self.getByte(next_offset)) return offset;
                offset = next_offset;
            }
            return 0;
        }

        pub fn utf8DecodeUtf16Le(
            self: *const Self,
            offset: usize,
        ) error{ Utf8InvalidStartByte, Truncated }!FileScope.Utf8DecodeUtf16Le {
            std.debug.assert(offset < self.len);

            var buf: [7]u8 = undefined;
            buf[0] = self.getByte(offset);
            const sequence_len = try std.unicode.utf8ByteSequenceLength(buf[0]);
            if (offset + sequence_len > self.len) return error.Truncated;
            for (1..sequence_len) |i| {
                buf[i] = self.getByte(offset + i);
            }
            var result_buf: [7]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(
                &result_buf,
                buf[0..sequence_len],
            ) catch |err| switch (err) {
                error.InvalidUtf8 => return .{
                    .end = offset + sequence_len,
                    .value = null,
                },
            };
            std.debug.assert(len == 1);
            return .{
                .end = offset + sequence_len,
                .value = result_buf[0],
            };
        }
    };
}
