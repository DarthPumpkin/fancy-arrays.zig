const std = @import("std");
const mem = std.mem;

const named_index = @import("named_index.zig");
const NamedIndex = named_index.NamedIndex;

pub fn NamedArray(comptime Axis: type, comptime Scalar: type) type {
    const Index = NamedIndex(Axis);
    return struct {
        idx: Index,
        buf: []Scalar,

        pub fn initAlloc(allocator: mem.Allocator, shape: Index.Axes) !@This() {
            const idx = Index.initContiguous(shape);
            return .{
                .idx = idx,
                .buf = try allocator.alloc(Scalar, idx.count()),
            };
        }

        pub fn fill(self: *const @This(), val: Scalar) *const @This() {
            var keys = self.idx.iterKeys();
            while (keys.next()) |key| {
                self.buf[self.idx.linear(key)] = val;
            }
            return self;
        }

        pub fn fillArange(self: *const @This()) *const @This() {
            var keys = self.idx.iterKeys();
            var i: Scalar = 0;
            while (keys.next()) |key| {
                self.buf[self.idx.linear(key)] = i;
                i += 1;
            }
            return self;
        }

        pub fn deinit(self: *const @This(), allocator: mem.Allocator) void {
            allocator.free(self.buf);
        }

        pub fn asConst(self: *const @This()) NamedArrayConst(Axis, Scalar) {
            return .{
                .idx = self.idx,
                .buf = self.buf,
            };
        }

        /// If possible, return a 1D slice of the buffer containing the elements of this array.
        /// If the array is non-contiguous, return null.
        /// To get a contiguous copy, see `toContiguous`.
        pub fn flat(self: *const @This()) ?[]Scalar {
            return flatGeneric(self);
        }

        /// Make a contiguous copy of the array.
        /// The new array will have the same shape and default strides.
        /// This allocates `self.idx.count()` scalars.
        pub fn toContiguous(self: *const @This(), allocator: mem.Allocator) !@This() {
            return toContiguousGeneric(Axis, Scalar, self, allocator);
        }

        pub fn getValChecked(self: *const @This(), key: Index.Axes) ?Scalar {
            return getValCheckedGeneric(self, key);
        }

        pub fn getVal(self: *const @This(), key: Index.Axes) Scalar {
            return self.asConst().getVal(key);
        }

        pub fn getPtrChecked(self: *const @This(), key: Index.Axes) ?*Scalar {
            return getPtrCheckedGeneric(self, key);
        }

        pub fn getPtr(self: *const @This(), key: Index.Axes) *Scalar {
            return &self.buf[self.idx.linear(key)];
        }

        pub fn setVal(self: *const @This(), key: Index.Axes, scalar: Scalar) void {
            self.buf[self.idx.linear(key)] = scalar;
        }
    };
}

pub fn NamedArrayConst(comptime Axis: type, comptime Scalar: type) type {
    const Index = NamedIndex(Axis);
    return struct {
        idx: Index,
        buf: []const Scalar,

        /// If possible, return a 1D slice of the buffer containing the elements of this array.
        /// If the array is non-contiguous, return null.
        /// To get a contiguous copy, see `toContiguous`.
        pub fn flat(self: *const @This()) ?[]const Scalar {
            return flatGeneric(self);
        }

        /// Make a contiguous copy of the array.
        /// The new array will have the same shape and default strides.
        /// This allocates `self.idx.count()` scalars.
        pub fn toContiguous(self: *const @This(), allocator: mem.Allocator) !NamedArray(Axis, Scalar) {
            return toContiguousGeneric(Axis, Scalar, self, allocator);
        }

        pub fn getValChecked(self: *const @This(), key: Index.Axes) ?Scalar {
            return getValCheckedGeneric(self, key);
        }

        pub fn getVal(self: *const @This(), key: Index.Axes) Scalar {
            return self.buf[self.idx.linear(key)];
        }

        pub fn getPtrChecked(self: *const @This(), key: Index.Axes) ?*const Scalar {
            return getPtrCheckedGeneric(self, key);
        }

        pub fn getPtr(self: *const @This(), key: Index.Axes) *const Scalar {
            return &self.buf[self.idx.linear(key)];
        }
    };
}

// Works for both NamedArray and NamedArrayConst
fn flatGeneric(self: anytype) ?@TypeOf(self.buf) {
    if (self.idx.isContiguous())
        return self.buf[self.idx.offset..][0..self.idx.count()];
    return null;
}

// Works for both NamedArray and NamedArrayConst
fn toContiguousGeneric(comptime Axis: type, comptime Scalar: type, self: anytype, allocator: mem.Allocator) !NamedArray(Axis, Scalar) {
    const Index = @TypeOf(self.idx);
    var buf = try allocator.alloc(Scalar, self.idx.count());
    errdefer comptime unreachable;
    const new_idx = Index.initContiguous(self.idx.shape);
    {
        var i: usize = 0;
        var keys = new_idx.iterKeys();
        while (keys.next()) |key| {
            buf[i] = self.getVal(key);
            i += 1;
        }
    }
    return .{ .idx = new_idx, .buf = buf };
}

fn getValCheckedGeneric(self: anytype, key: @TypeOf(self.idx).Axes) ?@TypeOf(self.buf[0]) {
    if (self.idx.linearChecked(key)) |key_| {
        return self.buf[key_];
    }
    return null;
}

fn getPtrCheckedGeneric(self: anytype, key: @TypeOf(self.idx).Axes) ?@TypeOf(&self.buf[0]) {
    if (self.idx.linearChecked(key)) |key_| {
        return &self.buf[key_];
    }
    return null;
}

/// If `idx_out` has overlapping linear indices, the output is undefined.
pub fn add(
    comptime Axis: type,
    comptime Scalar: type,
    arr1: NamedArrayConst(Axis, Scalar),
    arr2: NamedArrayConst(Axis, Scalar),
    arr_out: NamedArray(Axis, Scalar),
) void {
    if (arr1.idx.shape != arr2.idx.shape or arr1.idx.shape != arr_out.idx.shape)
        @panic("Incompatible shapes");
    // TODO: Check that arr_out.idx is non-overlapping.
    var keys = arr1.idx.iterKeys();
    while (keys.next()) |key| {
        const l = arr1.getVal(key);
        const r = arr2.getVal(key);
        arr_out.setVal(key, l + r);
    }
}

test "add inplace" {
    const Axis = enum { i };
    const idx = NamedIndex(Axis).initContiguous(.{ .i = 3 });
    const buf1 = [_]i32{ 1, 2, 3 };
    const arr1 = NamedArrayConst(Axis, i32){
        .idx = idx,
        .buf = &buf1,
    };
    var buf2 = [_]i32{ 2, 2, 2 };
    const arr_out = NamedArray(Axis, i32){
        .idx = idx,
        .buf = &buf2,
    };
    const arr2 = arr_out.asConst();
    add(Axis, i32, arr1, arr2, arr_out);

    const expected = [_]i32{ 3, 4, 5 };
    try std.testing.expectEqualSlices(i32, &expected, &buf2);
}

test "add broadcasted" {
    const I = enum { i };
    const IJ = named_index.KeyEnum(&.{ "i", "j" });
    const idx_broad = NamedIndex(I)
        .initContiguous(.{ .i = 3 })
        .addEmptyAxis("j")
        .broadcastAxis(.j, 4);
    const idx_out = NamedIndex(IJ)
        .initContiguous(.{ .i = 3, .j = 4 });
    var buf1 = [_]i32{ 1, 2, 3 };
    var buf2 = [_]i32{ 1, 1, 1 };
    var buf_out: [12]i32 = undefined;
    const arr1 = NamedArrayConst(IJ, i32){
        .idx = idx_broad,
        .buf = &buf1,
    };
    const arr2 = NamedArrayConst(IJ, i32){
        .idx = idx_broad,
        .buf = &buf2,
    };
    const arr_out = NamedArray(IJ, i32){
        .idx = idx_out,
        .buf = &buf_out,
    };
    add(IJ, i32, arr1, arr2, arr_out);

    const expected = [_]i32{
        2, 2, 2, 2,
        3, 3, 3, 3,
        4, 4, 4, 4,
    };
    try std.testing.expectEqualSlices(i32, &expected, &buf_out);
}

test "add row-major col-major" {
    const IJ = enum { i, j };
    const idx_row_major = NamedIndex(IJ).initContiguous(.{ .i = 2, .j = 3 });
    const idx_col_major = NamedIndex(IJ){
        .shape = .{ .i = 2, .j = 3 },
        .strides = .{ .i = 1, .j = 2 },
    };

    var buf_row_major = [_]i32{
        1, 2, 3,
        4, 5, 6,
    };
    var buf_col_major = [_]i32{
        10, 40,
        20, 50,
        30, 60,
    };
    var buf_out: [6]i32 = undefined;

    const arr_row_major = NamedArrayConst(IJ, i32){ .idx = idx_row_major, .buf = &buf_row_major };
    const arr_col_major = NamedArrayConst(IJ, i32){ .idx = idx_col_major, .buf = &buf_col_major };
    const arr_out = NamedArray(IJ, i32){ .idx = idx_row_major, .buf = &buf_out };

    add(IJ, i32, arr_row_major, arr_col_major, arr_out);

    const expected = [_]i32{ 11, 22, 33, 44, 55, 66 };
    try std.testing.expectEqualSlices(i32, &expected, &buf_out);
}

test "fill" {
    const Axis = enum { i };
    const allocator = std.testing.allocator;
    const arr = try NamedArray(Axis, i32).initAlloc(allocator, .{ .i = 4 });
    _ = arr.fill(0);
    defer arr.deinit(allocator);

    const expected_zeros = [_]i32{ 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(i32, &expected_zeros, arr.buf);

    _ = arr.fillArange();
    const expected_arange = [_]i32{ 0, 1, 2, 3 };
    try std.testing.expectEqualSlices(i32, &expected_arange, arr.buf);
}

test "flat, toContiguous" {
    const IJ = enum { i, j };

    const al = std.testing.allocator;
    var arr = try NamedArray(IJ, i32).initAlloc(al, .{ .i = 5, .j = 9 });
    defer arr.deinit(al);
    _ = arr.fillArange();

    // Non-contiguous array cannot be flattened
    arr.idx = arr.idx
        .sliceAxis(.i, 0, 4)
        .stride(.{ .j = 3 });
    try std.testing.expectEqual(arr.flat(), null);

    // After making it contiguous, .flat() works.
    const arr_cont = try arr.toContiguous(al);
    defer arr_cont.deinit(al);
    const flat = arr_cont.flat().?;
    const expected = [_]i32{
        0,  3,  6,
        9,  12, 15,
        18, 21, 24,
        27, 30, 33,
    };
    try std.testing.expectEqualSlices(i32, &expected, flat);

    // Test also for Const
    const arr_cont_const = arr_cont.asConst();
    const flat_const = arr_cont_const.flat().?;
    try std.testing.expectEqualSlices(i32, &expected, flat_const);
}

test "get*" {
    // Test all the get* methods, both for NamedArray and NamedArrayConst
    const IJ = enum { i, j };
    const idx = NamedIndex(IJ).initContiguous(.{ .i = 2, .j = 3 });
    var buf = [_]i32{ 10, 11, 12, 13, 14, 15 };
    const arr = NamedArray(IJ, i32){
        .idx = idx,
        .buf = &buf,
    };
    const arr_const = arr.asConst();

    // Test get (in bounds)
    try std.testing.expectEqual(arr.getValChecked(.{ .i = 1, .j = 2 }), 15);
    try std.testing.expectEqual(arr_const.getValChecked(.{ .i = 1, .j = 2 }), 15);

    // Test get (out of bounds)
    try std.testing.expectEqual(arr.getValChecked(.{ .i = 2, .j = 0 }), null);
    try std.testing.expectEqual(arr_const.getValChecked(.{ .i = 2, .j = 0 }), null);

    // Test getUnchecked
    try std.testing.expectEqual(arr.getVal(.{ .i = 0, .j = 1 }), 11);
    try std.testing.expectEqual(arr_const.getVal(.{ .i = 0, .j = 1 }), 11);

    // Test getPtr (in bounds)
    const ptr = arr.getPtrChecked(.{ .i = 1, .j = 0 }).?;
    try std.testing.expectEqual(ptr.*, 13);
    const ptr_const = arr_const.getPtrChecked(.{ .i = 1, .j = 0 }).?;
    try std.testing.expectEqual(ptr_const.*, 13);

    // Test getPtr (out of bounds)
    try std.testing.expectEqual(arr.getPtrChecked(.{ .i = 5, .j = 0 }), null);
    try std.testing.expectEqual(arr_const.getPtrChecked(.{ .i = 5, .j = 0 }), null);

    // Test getPtrUnchecked
    const ptr_unchecked = arr.getPtr(.{ .i = 0, .j = 2 });
    try std.testing.expectEqual(ptr_unchecked.*, 12);
    const ptr_const_unchecked = arr_const.getPtr(.{ .i = 0, .j = 2 });
    try std.testing.expectEqual(ptr_const_unchecked.*, 12);

    // Test setUnchecked
    arr.setVal(.{ .i = 1, .j = 1 }, 99);
    try std.testing.expectEqual(arr.getVal(.{ .i = 1, .j = 1 }), 99);
}

// test "einstein" {
//     const IJ = enum { i, j };
//     const JK = enum { j, k };

//     const al = std.testing.allocator;

//     const arr_ij = try NamedArray(IJ, f64).initAlloc(al, .{ .i = 4, .j = 3 });
//     defer arr_ij.deinit(al);
//     arr_ij.fillArange();

//     const arr_jk = try NamedArray(JK, f64).initAlloc(al, .{ .j = 3, .k = 2 });
//     defer arr_jk.deinit(al);
//     arr_jk.fill(1);

//     const arr_ik = einstein(al, arr_ij.asConst(), arr_jk.asConst());
//     defer arr_ik.deinit(al);

//     std.testing.expectEqual(arr_ik.shape, .{ .i = 4, .k = 2 });
// }
