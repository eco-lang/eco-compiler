// =============================================================================
// EXTRACTED FROM: crates/compiler/builtins/bitcode/src/utils.zig
// =============================================================================
// Runtime support for Perceus reference counting.
//
// This Zig code provides atomic reference counting operations that are
// called from the LLVM-generated code.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// DEBUG FLAGS
// =============================================================================

const DEBUG_INCDEC = false;     // Log increment/decrement operations
const DEBUG_TESTING_ALLOC = false;  // Log test allocator activity
const DEBUG_ALLOC = false;      // Log allocation activity

// =============================================================================
// HOST-PROVIDED ALLOCATION FUNCTIONS
// =============================================================================

// The host must provide these functions:

/// Allocate memory. Must NOT return null - should throw on failure.
extern fn roc_alloc(size: usize, alignment: u32) callconv(.C) ?*anyopaque;

/// Reallocate memory. Must NOT return null - should throw on failure.
extern fn roc_realloc(c_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) ?*anyopaque;

/// Free memory. Pointer must not be null.
extern fn roc_dealloc(c_ptr: *anyopaque, alignment: u32) callconv(.C) void;

// =============================================================================
// REFCOUNT TYPES AND CONSTANTS
// =============================================================================

/// Special refcount value meaning "constant/static data - never free"
const REFCOUNT_MAX_ISIZE: isize = 0;

/// Reference counting mode
const Refcount = enum {
    none,    // No reference counting (for testing)
    normal,  // Non-atomic reference counting
    atomic,  // Atomic reference counting (thread-safe)
};

/// Current mode - always atomic for safety
const RC_TYPE: Refcount = .atomic;

// =============================================================================
// TYPE DEFINITIONS
// =============================================================================

pub const Inc = fn (?[*]u8) callconv(.C) void;
pub const IncN = fn (?[*]u8, u64) callconv(.C) void;
pub const Dec = fn (?[*]u8) callconv(.C) void;

pub const IntWidth = enum(u8) {
    U8 = 0, U16 = 1, U32 = 2, U64 = 3, U128 = 4,
    I8 = 5, I16 = 6, I32 = 7, I64 = 8, I128 = 9,
};

pub const UpdateMode = enum(u8) {
    Immutable = 0,
    InPlace = 1,
};

// =============================================================================
// MEMORY LAYOUT
// =============================================================================
//
// Memory allocation layout:
//
// ┌─────────────────────────────────────────────────────────────┐
// │                      Allocated Block                        │
// ├─────────────────┬─────────────────┬─────────────────────────┤
// │  Extra Bytes    │   Refcount      │         Data            │
// │  (for alignment)│   (1 usize)     │                         │
// └─────────────────┴─────────────────┴─────────────────────────┘
//                    ↑                 ↑
//                    │                 └── returned to caller
//                    └── refcount stored here (index -1 from data)
//
// If elements are refcounted (e.g., List of refcounted values),
// an additional usize is allocated before the refcount for the
// element count (used by seamless slices).

// =============================================================================
// INCREMENT REFCOUNT
// =============================================================================

/// Increment the reference count.
/// Called from LLVM-generated code.
///
/// ptr_to_refcount: pointer to the refcount (NOT the data)
/// amount: how much to increment by (usually 1)
pub fn increfRcPtrC(ptr_to_refcount: *isize, amount: isize) callconv(.C) void {
    if (RC_TYPE == .none) return;

    if (DEBUG_INCDEC and builtin.target.cpu.arch != .wasm32) {
        std.debug.print("| increment {*}: ", .{ptr_to_refcount});
    }

    const refcount: isize = ptr_to_refcount.*;

    // Skip if this is constant/static data (refcount == 0)
    if (!rcConstant(refcount)) {
        // We assume refcount never overflows
        switch (RC_TYPE) {
            .normal => {
                ptr_to_refcount.* = refcount +% amount;
            },
            .atomic => {
                // Atomic add for thread safety
                _ = @atomicRmw(isize, ptr_to_refcount, .Add, amount, .monotonic);
            },
            .none => unreachable,
        }
    }
}

/// Increment from a data pointer (handles tagged pointers).
pub fn increfDataPtrC(
    bytes_or_null: ?[*]u8,
    inc_amount: isize,
) callconv(.C) void {
    const bytes = bytes_or_null orelse return;

    // Clear any tag bits from the pointer
    const ptr = @intFromPtr(bytes);
    const tag_mask: usize = if (@sizeOf(usize) == 8) 0b111 else 0b11;
    const masked_ptr = ptr & ~tag_mask;

    // Refcount is at index -1 from data
    const isizes: *isize = @as(*isize, @ptrFromInt(masked_ptr - @sizeOf(usize)));

    return increfRcPtrC(isizes, inc_amount);
}

// =============================================================================
// DECREMENT REFCOUNT
// =============================================================================

/// Decrement the reference count.
/// If count reaches zero, free the memory.
///
/// bytes_or_null: pointer to the REFCOUNT (not the data!)
/// alignment: allocation alignment
/// elements_refcounted: whether elements need refcounting
pub fn decrefRcPtrC(
    bytes_or_null: ?[*]isize,
    alignment: u32,
    elements_refcounted: bool,
) callconv(.C) void {
    const bytes = @as([*]isize, @ptrCast(bytes_or_null));
    return @call(.always_inline, decref_ptr_to_refcount, .{ bytes, alignment, elements_refcounted });
}

/// Decrement from a data pointer (handles null).
pub fn decrefCheckNullC(
    bytes_or_null: ?[*]u8,
    alignment: u32,
    elements_refcounted: bool,
) callconv(.C) void {
    if (bytes_or_null) |bytes| {
        const isizes: [*]isize = @as([*]isize, @ptrCast(@alignCast(bytes)));
        return @call(.always_inline, decref_ptr_to_refcount, .{ isizes - 1, alignment, elements_refcounted });
    }
}

/// Decrement from a data pointer (handles tagged pointers).
pub fn decrefDataPtrC(
    bytes_or_null: ?[*]u8,
    alignment: u32,
    elements_refcounted: bool,
) callconv(.C) void {
    const bytes = bytes_or_null orelse return;

    // Clear any tag bits
    const data_ptr = @intFromPtr(bytes);
    const tag_mask: usize = if (@sizeOf(usize) == 8) 0b111 else 0b11;
    const unmasked_ptr = data_ptr & ~tag_mask;

    // Get refcount pointer (at index -1)
    const isizes: [*]isize = @as([*]isize, @ptrFromInt(unmasked_ptr));
    const rc_ptr = isizes - 1;

    return decrefRcPtrC(rc_ptr, alignment, elements_refcounted);
}

/// Internal decrement implementation.
inline fn decref_ptr_to_refcount(
    refcount_ptr: [*]isize,
    element_alignment: u32,
    elements_refcounted: bool,
) void {
    if (RC_TYPE == .none) return;

    if (DEBUG_INCDEC and builtin.target.cpu.arch != .wasm32) {
        std.debug.print("| decrement {*}: ", .{refcount_ptr});
    }

    // Alignment must account for pointer size
    const ptr_width = @sizeOf(usize);
    const alignment = @max(ptr_width, element_alignment);

    const refcount: isize = refcount_ptr[0];

    // Skip if constant/static
    if (!rcConstant(refcount)) {
        switch (RC_TYPE) {
            .normal => {
                refcount_ptr[0] = refcount -% 1;
                if (refcount == 1) {
                    // Was 1, now 0: free
                    free_ptr_to_refcount(refcount_ptr, alignment, elements_refcounted);
                }
            },
            .atomic => {
                // Atomic subtract, returns previous value
                const last = @atomicRmw(isize, &refcount_ptr[0], .Sub, 1, .monotonic);
                if (last == 1) {
                    // Was 1, now 0: free
                    free_ptr_to_refcount(refcount_ptr, alignment, elements_refcounted);
                }
            },
            .none => unreachable,
        }
    }
}

// =============================================================================
// FREE MEMORY
// =============================================================================

/// Free from refcount pointer.
pub fn freeRcPtrC(
    bytes_or_null: ?[*]isize,
    alignment: u32,
    elements_refcounted: bool,
) callconv(.C) void {
    const bytes = bytes_or_null orelse return;
    return free_ptr_to_refcount(bytes, alignment, elements_refcounted);
}

/// Free from data pointer (handles tagged pointers).
pub fn freeDataPtrC(
    bytes_or_null: ?[*]u8,
    alignment: u32,
    elements_refcounted: bool,
) callconv(.C) void {
    const bytes = bytes_or_null orelse return;

    // Clear tag bits
    const ptr = @intFromPtr(bytes);
    const tag_mask: usize = if (@sizeOf(usize) == 8) 0b111 else 0b11;
    const masked_ptr = ptr & ~tag_mask;

    const isizes: [*]isize = @as([*]isize, @ptrFromInt(masked_ptr));

    // Refcount is at index -1
    return freeRcPtrC(isizes - 1, alignment, elements_refcounted);
}

/// Internal free implementation.
inline fn free_ptr_to_refcount(
    refcount_ptr: [*]isize,
    alignment: u32,
    elements_refcounted: bool,
) void {
    if (RC_TYPE == .none) return;

    const ptr_width = @sizeOf(usize);
    const required_space: usize = if (elements_refcounted) (2 * ptr_width) else ptr_width;
    const extra_bytes = @max(required_space, alignment);

    // Calculate the original allocation pointer
    const allocation_ptr = @as([*]u8, @ptrCast(refcount_ptr)) - (extra_bytes - @sizeOf(usize));

    // NOTE: We don't check for constant refcount here!
    // Caller should have already checked.
    dealloc(allocation_ptr, alignment);

    if (DEBUG_ALLOC and builtin.target.cpu.arch != .wasm32) {
        std.debug.print("freed {*}\n", .{allocation_ptr});
    }
}

// =============================================================================
// UNIQUENESS CHECK
// =============================================================================

/// Check if a value is unique (refcount == 1).
/// Used for in-place mutation optimization.
pub fn isUnique(bytes_or_null: ?[*]u8) callconv(.C) bool {
    const bytes = bytes_or_null orelse return true;

    // Clear tag bits
    const ptr = @intFromPtr(bytes);
    const tag_mask: usize = if (@sizeOf(usize) == 8) 0b111 else 0b11;
    const masked_ptr = ptr & ~tag_mask;

    // Get refcount (at index -1)
    const isizes: [*]isize = @as([*]isize, @ptrFromInt(masked_ptr));
    const refcount = (isizes - 1)[0];

    if (DEBUG_INCDEC and builtin.target.cpu.arch != .wasm32) {
        std.debug.print("| is unique {*}\n", .{isizes - 1});
    }

    return rcUnique(refcount);
}

/// Check if refcount indicates uniqueness.
pub inline fn rcUnique(refcount: isize) bool {
    switch (RC_TYPE) {
        .normal, .atomic => return refcount == 1,
        .none => return false,
    }
}

/// Check if refcount indicates constant/static data.
pub inline fn rcConstant(refcount: isize) bool {
    switch (RC_TYPE) {
        .normal, .atomic => return refcount == REFCOUNT_MAX_ISIZE,
        .none => return true,
    }
}

// =============================================================================
// ALLOCATION
// =============================================================================

/// Allocate memory with a refcount header.
/// Returns pointer to the DATA (not the allocation start).
pub fn allocateWithRefcountC(
    data_bytes: usize,
    element_alignment: u32,
    elements_refcounted: bool,
) callconv(.C) [*]u8 {
    return allocateWithRefcount(data_bytes, element_alignment, elements_refcounted);
}

pub fn allocateWithRefcount(
    data_bytes: usize,
    element_alignment: u32,
    elements_refcounted: bool,
) [*]u8 {
    const ptr_width = @sizeOf(usize);
    const alignment = @max(ptr_width, element_alignment);

    // Extra space for refcount (and element count if needed)
    const required_space: usize = if (elements_refcounted) (2 * ptr_width) else ptr_width;
    const extra_bytes = @max(required_space, element_alignment);
    const length = extra_bytes + data_bytes;

    // Allocate
    const new_bytes: [*]u8 = alloc(length, alignment) orelse unreachable;

    if (DEBUG_ALLOC and builtin.target.cpu.arch != .wasm32) {
        std.debug.print("+ allocated {*} ({} bytes with alignment {})\n", .{ new_bytes, data_bytes, alignment });
    }

    // Calculate data pointer
    const data_ptr = new_bytes + extra_bytes;

    // Initialize refcount to 1
    const refcount_ptr = @as([*]usize, @ptrCast(@as([*]align(ptr_width) u8, @alignCast(data_ptr)) - ptr_width));
    refcount_ptr[0] = if (RC_TYPE == .none) REFCOUNT_MAX_ISIZE else 1;

    return data_ptr;
}

// =============================================================================
// REALLOCATION
// =============================================================================

/// Reallocate memory (for growing lists).
pub fn unsafeReallocate(
    source_ptr: [*]u8,
    alignment: u32,
    old_length: usize,
    new_length: usize,
    element_width: usize,
    elements_refcounted: bool,
) [*]u8 {
    const ptr_width: usize = @sizeOf(usize);
    const required_space: usize = if (elements_refcounted) (2 * ptr_width) else ptr_width;
    const extra_bytes = @max(required_space, alignment);

    const old_width = extra_bytes + old_length * element_width;
    const new_width = extra_bytes + new_length * element_width;

    // No-op if shrinking
    if (old_width >= new_width) {
        return source_ptr;
    }

    // Reallocate (deallocs original)
    const old_allocation = source_ptr - extra_bytes;
    const new_allocation = realloc(old_allocation, new_width, old_width, alignment);

    const new_source = @as([*]u8, @ptrCast(new_allocation)) + extra_bytes;
    return new_source;
}

// =============================================================================
// CAPACITY CALCULATION (FBVector-style growth)
// =============================================================================

/// Calculate new capacity for list growth.
/// Follows Facebook's fbvector growth strategy.
pub inline fn calculateCapacity(
    old_capacity: usize,
    requested_length: usize,
    element_width: usize,
) usize {
    // If explicit request, trust it
    if (requested_length != old_capacity + 1) {
        return requested_length;
    }

    var new_capacity: usize = 0;
    if (element_width == 0) {
        return requested_length;
    } else if (old_capacity == 0) {
        // Initial allocation: at least 64 bytes
        new_capacity = 64 / element_width;
    } else if (old_capacity < 4096 / element_width) {
        // Small: 2x growth
        new_capacity = old_capacity * 2;
    } else if (old_capacity > 4096 * 32 / element_width) {
        // Large: 2x growth
        new_capacity = old_capacity * 2;
    } else {
        // Medium: 1.5x growth
        new_capacity = (old_capacity * 3 + 1) / 2;
    }

    return @max(new_capacity, requested_length);
}

// =============================================================================
// WRAPPERS FOR HOST FUNCTIONS
// =============================================================================

pub fn alloc(size: usize, alignment: u32) ?[*]u8 {
    return @as(?[*]u8, @ptrCast(roc_alloc(size, alignment)));
}

pub fn realloc(c_ptr: [*]u8, new_size: usize, old_size: usize, alignment: u32) [*]u8 {
    return @as([*]u8, @ptrCast(roc_realloc(c_ptr, new_size, old_size, alignment)));
}

pub fn dealloc(c_ptr: [*]u8, alignment: u32) void {
    return roc_dealloc(c_ptr, alignment);
}

// =============================================================================
// DICT PSEUDO-RANDOM SEED
// =============================================================================

/// Returns a pseudo-random seed for dictionaries.
/// Uses function address (affected by ASLR) to avoid DoS attacks.
pub fn dictPseudoSeed() callconv(.C) u64 {
    return @as(u64, @intCast(@intFromPtr(&dictPseudoSeed)));
}
