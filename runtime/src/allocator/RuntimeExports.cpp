//===- RuntimeExports.cpp - C-linkage runtime function implementations ----===//
//
// This file implements the C-linkage functions that are called from
// LLVM-generated code.
//
//===----------------------------------------------------------------------===//

#include "RuntimeExports.h"
#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "StringOps.hpp"
#include "ThreadLocalHeap.hpp"
#include "TypeInfo.hpp"

#include <cassert>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>

using namespace Elm;

//===----------------------------------------------------------------------===//
// HPointer Conversion Helpers
//===----------------------------------------------------------------------===//

namespace {

/// Convert a raw void* pointer to a uint64_t HPointer representation.
/// The HPointer will have constant=0, indicating a regular heap pointer.
/// Note: Elm never produces null pointers, so obj must be a valid heap pointer.
/// Validation is performed in Allocator::wrap().
inline HPtr ptrToHPointer(void* obj) {
    HPointer hp = Allocator::instance().wrap(obj);
    return HPtr::fromHPointer(hp);
}

/// Convert a uint64_t HPointer representation to a raw void* pointer.
/// Uses Allocator::resolve() to handle forwarding pointers during GC.
/// Returns nullptr for embedded constants (Nil, True, False, Unit, etc.)
/// since they don't have actual heap objects.
inline void* hpointerToPtr(uint64_t val) {
    HPointer hp;
    memcpy(&hp, &val, sizeof(hp));
    // Embedded constants don't have heap objects - return nullptr.
    if (hp.constant != 0) {
        return nullptr;
    }
    return Allocator::instance().resolve(hp);
}

} // anonymous namespace

//===----------------------------------------------------------------------===//
// Thread-Local Output Stream for Capture Support
//===----------------------------------------------------------------------===//

namespace {

/// Thread-local output stream. When non-null, print output goes here instead of stderr.
thread_local std::ostringstream* tl_output_stream = nullptr;

/// Helper to output text - either to capture stream or stderr.
void output_text(const char* text) {
    if (tl_output_stream) {
        *tl_output_stream << text;
    } else {
        fputs(text, stderr);
    }
}

/// Helper to output formatted text.
template<typename... Args>
void output_format(const char* fmt, Args... args) {
    char buffer[256];
    snprintf(buffer, sizeof(buffer), fmt, args...);
    output_text(buffer);
}

/// Helper to output a single character.
void output_char(char c) {
    if (tl_output_stream) {
        *tl_output_stream << c;
    } else {
        fputc(c, stderr);
    }
}

/// Helper to print float values with proper Infinity and NaN formatting.
/// Elm uses "Infinity", "-Infinity", and "NaN" (not "inf", "-inf", "nan").
/// -0.0 is printed as "0", like Elm does.
void print_float(double d) {
    if (std::isinf(d)) {
        if (d > 0) {
            output_text("Infinity");
        } else {
            output_text("-Infinity");
        }
    } else if (std::isnan(d)) {
        output_text("NaN");
    } else if (d == 0.0) {
        // Print both +0.0 and -0.0 as "0", like Elm does.
        output_text("0");
    } else {
        // Use std::to_chars for the shortest round-trip representation,
        // matching JavaScript/Elm's Number.prototype.toString() behavior.
        char buf[32];
        auto [ptr, ec] = std::to_chars(buf, buf + sizeof(buf), d);
        *ptr = '\0';
        output_text(buf);
    }
}

} // namespace

//===----------------------------------------------------------------------===//
// Output Capture API Implementation
//===----------------------------------------------------------------------===//

extern "C" void* eco_set_output_stream(void* stream) {
    void* prev = tl_output_stream;
    tl_output_stream = static_cast<std::ostringstream*>(stream);
    return prev;
}

extern "C" void* eco_get_output_stream() {
    return tl_output_stream;
}

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

extern "C" void* eco_alloc_with_roots(uint32_t tag, uint64_t size,
                                       uint64_t* roots, uint32_t n_roots,
                                       uint64_t hptr_mask) {
    // Fast path: bump-pointer with no rooting. allocateFast cannot trigger
    // GC, so values in roots[] cannot move during this call.
    void* obj = Allocator::instance().allocateFast(static_cast<size_t>(size));
    if (obj) {
        // allocateFast does not init the header; do it consistently with
        // the slow path (which calls initHeaderForTag inside allocateSlow).
        initHeaderForTag(getHeader(obj), static_cast<Tag>(tag),
                         static_cast<size_t>(size));
        return obj;
    }

    // Slow path: open a stack root range over roots[], run allocateSlow,
    // close the range. After return, caller reads HPointer slots from
    // roots[] to pick up GC-relocated addresses.
    size_t saved = eco_gc_stack_range_point();
    if (n_roots > 0 && hptr_mask != 0) {
        eco_gc_push_stack_range(roots, n_roots, hptr_mask);
    }
    obj = Allocator::instance().allocateSlow(static_cast<size_t>(size),
                                             static_cast<Tag>(tag));
    eco_gc_restore_stack_range_point(saved);
    return obj;
}

extern "C" HPtr eco_alloc_custom(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes) {
    // Calculate size: Header + ctor/unboxed (8 bytes) + fields
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;

    // No HPointer args to root: ctor_id/field_count/scalar_bytes are scalars,
    // and the field values are written by the caller after this returns.
    void* obj = eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;
    return ptrToHPointer(obj);
}

extern "C" void eco_set_unboxed(HPtr obj_hptr, uint64_t bitmap) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);
    switch (header->tag) {
        case Tag_Custom: {
            // Custom's 48-bit bitmap stores 24 × 2-bit kinds.
            assert((bitmap >> 48) == 0 && "Custom unboxed bitmap overflow (>48 bits)");
            Custom* custom = static_cast<Custom*>(obj);
            custom->unboxed = bitmap & 0x0000FFFFFFFFFFFFULL;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            tuple->header.unboxed = static_cast<u8>(bitmap & 0xF);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            tuple->header.unboxed = static_cast<u8>(bitmap & 0x3F);
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            cons->header.unboxed = static_cast<u8>(bitmap & 0x3);
            break;
        }
        default:
            // For other types (e.g. Array's uniform kind), set in header.
            header->unboxed = static_cast<u8>(bitmap & 0x3);
            break;
    }
}

// `head_kind`: 2-bit primitive kind for the head slot (0=boxed, 1=Int, 2=Float,
// 3=Char). Stored into `cons->header.unboxed` at slot 0 (bits 1:0).
extern "C" HPtr eco_alloc_cons(uint64_t head, HPtr tail, uint32_t head_kind) {
    // Pack the field values as roots so the generic helper can keep them
    // valid across a slow-path GC. Mask bit i is set iff slot i is an
    // HPointer. tail (slot 1) is always a list HPointer; head (slot 0) is
    // a boxed HPointer iff head_kind == 0.
    uint64_t roots[2] = { head, tail.toBits() };
    uint64_t mask = (head_kind != 0) ? 0x2 : 0x3;

    void* obj = eco_alloc_with_roots(Tag_Cons, sizeof(Cons), roots, 2, mask);
    if (!obj) return HPtr::fromBits(0);

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    cons->head.i = static_cast<i64>(roots[0]);
    HPointer tail_hp;
    memcpy(&tail_hp, &roots[1], sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

// `unboxed_mask`: 2-bit-per-slot kind bitmap (4 bits used for 2 slots).
extern "C" HPtr eco_alloc_tuple2(uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    uint64_t roots[2] = { a, b };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 2);

    void* obj = eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), roots, 2, mask);
    if (!obj) return HPtr::fromBits(0);

    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);
    return ptrToHPointer(obj);
}

// `unboxed_mask`: 2-bit-per-slot kind bitmap (6 bits used for 3 slots).
extern "C" HPtr eco_alloc_tuple3(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    uint64_t roots[3] = { a, b, c };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 3);

    void* obj = eco_alloc_with_roots(Tag_Tuple3, sizeof(Tuple3), roots, 3, mask);
    if (!obj) return HPtr::fromBits(0);

    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);
    tup->c.i = static_cast<i64>(roots[2]);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap) {
    // Size: Header (8) + unboxed bitmap (8) + fields (N * 8).
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable);

    // No HPointer args to root: field values are written by caller after.
    void* obj = eco_alloc_with_roots(Tag_Record, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    Record* rec = static_cast<Record*>(obj);
    rec->header.size = field_count;
    rec->unboxed = unboxed_bitmap;
    return ptrToHPointer(obj);
}

extern "C" void eco_store_record_field(HPtr record_hptr, uint32_t index, HPtr value) {
    // Per-write stale-pointer tripwire on the boxed value being stored.
    alloc::validateNurseryHPtrBits(value.toBits());
    void* record = hpointerToPtr(record_hptr.toBits());
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    // Store as raw 64-bit value (HPointer).
    rec->values[index].i = static_cast<i64>(value.toBits());
}

extern "C" void eco_store_record_field_i64(HPtr record_hptr, uint32_t index, int64_t value) {
    void* record = hpointerToPtr(record_hptr.toBits());
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    rec->values[index].i = value;
}

extern "C" void eco_store_record_field_f64(HPtr record_hptr, uint32_t index, double value) {
    void* record = hpointerToPtr(record_hptr.toBits());
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    rec->values[index].f = value;
}

extern "C" HPtr eco_alloc_string(uint32_t length) {
    // Size: Header + length * sizeof(u16), aligned to 8 bytes
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;  // Align to 8 bytes

    void* obj = eco_alloc_with_roots(Tag_String, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    // initHeaderForTag derives Tag_String header.size from byte size; for the
    // common case that matches `length`, but writing it explicitly is robust
    // to subsequent rounding.
    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_string_literal(const uint16_t* chars, uint32_t length) {
    // Allocate string literal directly in old generation (permanent, never collected).
    // Size: Header + length * sizeof(u16), aligned to 8 bytes
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;  // Align to 8 bytes

    void* obj = Allocator::instance().allocatePermanent(size, Tag_String);
    if (!obj) return HPtr::fromBits(0);

    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;
    std::memcpy(str->chars, chars, length * sizeof(u16));

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_closure_k(void* func_ptr, uint32_t num_captures,
                                    uint8_t result_kind) {
    assert(result_kind <= 3 && "eco_alloc_closure_k: result_kind out of range");
    // Size: Header + metadata (8 bytes) + evaluator ptr + captures
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + num_captures * sizeof(Unboxable);

    // No HPointer args to root (func_ptr is a code pointer, not a heap pointer;
    // captures are filled by the caller via closureCapture afterwards).
    void* obj = eco_alloc_with_roots(Tag_Closure, size, nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);

    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->result_kind = result_kind;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<EvalFunction>(func_ptr);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_closure(void* func_ptr, uint32_t num_captures) {
    return eco_alloc_closure_k(func_ptr, num_captures, /*result_kind=*/0);
}

extern "C" HPtr eco_alloc_int(int64_t value) {
    void* obj = eco_alloc_with_roots(Tag_Int, sizeof(ElmInt), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    static_cast<ElmInt*>(obj)->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_float(double value) {
    void* obj = eco_alloc_with_roots(Tag_Float, sizeof(ElmFloat), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    static_cast<ElmFloat*>(obj)->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_char(uint32_t value) {
    void* obj = eco_alloc_with_roots(Tag_Char, sizeof(ElmChar), nullptr, 0, 0);
    if (!obj) return HPtr::fromBits(0);
    static_cast<ElmChar*>(obj)->value = static_cast<u16>(value);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_allocate(uint64_t size, uint32_t tag) {
    // Generic allocation with specified size and tag. Used by the JIT for
    // sizes/tags not covered by the per-type entry points; rare.
    void* obj = eco_alloc_with_roots(tag, size, nullptr, 0, 0);
    return ptrToHPointer(obj);
}

//===----------------------------------------------------------------------===//
// Fast/Slow Allocation Split
//
// Fast variants: bump-pointer only, no GC trigger, return 0/nullptr on failure.
// Slow variants: may trigger GC, always succeed or abort.
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_alloc_custom_fast(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    // Init header + ctor
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Custom;
    hdr->size = (size - sizeof(Custom)) / sizeof(Unboxable);
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_custom_slow(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;
    void* obj = Allocator::instance().allocateSlow(size, Tag_Custom);
    if (!obj) return HPtr::fromBits(0);

    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_cons_fast(uint64_t head, HPtr tail, uint32_t head_kind) {
    size_t size = sizeof(Cons);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Cons;
    hdr->size = static_cast<u32>(size);
    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    cons->head.i = static_cast<i64>(head);
    uint64_t tail_bits = tail.toBits();
    HPointer tail_hp;
    memcpy(&tail_hp, &tail_bits, sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_cons_slow(uint64_t head, HPtr tail, uint32_t head_kind) {
    size_t size = sizeof(Cons);

    // Root head/tail across allocateSlow. Caller's RS4GC statepoint covers
    // these args at the call site, but our by-value parameter copies are
    // local to this frame and the caller's stackmap doesn't see them, so
    // a GC during allocateSlow would leave them pointing at the pre-swap
    // location. Mask bit i set iff slot i is an HPointer.
    uint64_t roots[2] = { head, tail.toBits() };
    uint64_t mask = (head_kind != 0) ? 0x2 : 0x3;

    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 2, mask);

    void* obj = Allocator::instance().allocateSlow(size, Tag_Cons);

    eco_gc_restore_stack_range_point(saved);

    if (!obj) return HPtr::fromBits(0);

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    // Read post-GC values back from roots[].
    cons->head.i = static_cast<i64>(roots[0]);
    HPointer tail_hp;
    memcpy(&tail_hp, &roots[1], sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple2_fast(uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple2);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple2;
    hdr->size = static_cast<u32>(size);
    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple2_slow(uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple2);

    // Root HPointer slots across allocateSlow (see eco_alloc_cons_slow above
    // for the full rationale).
    uint64_t roots[2] = { a, b };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 2);

    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 2, mask);

    void* obj = Allocator::instance().allocateSlow(size, Tag_Tuple2);

    eco_gc_restore_stack_range_point(saved);

    if (!obj) return HPtr::fromBits(0);

    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple3_fast(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple3);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple3;
    hdr->size = static_cast<u32>(size);
    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0x3F);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);
    tup->c.i = static_cast<i64>(c);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_tuple3_slow(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple3);

    // Root HPointer slots across allocateSlow (see eco_alloc_cons_slow above
    // for the full rationale).
    uint64_t roots[3] = { a, b, c };
    uint64_t mask = pointerMaskFromKindBitmap(unboxed_mask, 3);

    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 3, mask);

    void* obj = Allocator::instance().allocateSlow(size, Tag_Tuple3);

    eco_gc_restore_stack_range_point(saved);

    if (!obj) return HPtr::fromBits(0);

    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0x3F);
    tup->a.i = static_cast<i64>(roots[0]);
    tup->b.i = static_cast<i64>(roots[1]);
    tup->c.i = static_cast<i64>(roots[2]);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_record_fast(uint32_t field_count, uint64_t unboxed_bitmap) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Record;
    hdr->size = field_count;
    Record* rec = static_cast<Record*>(obj);
    rec->unboxed = unboxed_bitmap;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_record_slow(uint32_t field_count, uint64_t unboxed_bitmap) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable);
    void* obj = Allocator::instance().allocateSlow(size, Tag_Record);
    if (!obj) return HPtr::fromBits(0);

    Record* rec = static_cast<Record*>(obj);
    rec->header.size = field_count;
    rec->unboxed = unboxed_bitmap;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_string_fast(uint32_t length) {
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_String;
    hdr->size = length;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_string_slow(uint32_t length) {
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;
    void* obj = Allocator::instance().allocateSlow(size, Tag_String);
    if (!obj) return HPtr::fromBits(0);

    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_closure_fast(void* func_ptr, uint32_t num_captures) {
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + num_captures * sizeof(Unboxable);
    void* obj = Allocator::instance().allocateFast(size);
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Closure;
    hdr->size = (size - sizeof(Closure)) / sizeof(Unboxable);
    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->result_kind = 0;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<EvalFunction>(func_ptr);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_closure_slow(void* func_ptr, uint32_t num_captures) {
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + num_captures * sizeof(Unboxable);
    void* obj = Allocator::instance().allocateSlow(size, Tag_Closure);
    if (!obj) return HPtr::fromBits(0);

    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->result_kind = 0;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<EvalFunction>(func_ptr);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_int_fast(int64_t value) {
    void* obj = Allocator::instance().allocateFast(sizeof(ElmInt));
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Int;
    hdr->size = static_cast<u32>(sizeof(ElmInt));
    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_int_slow(int64_t value) {
    void* obj = Allocator::instance().allocateSlow(sizeof(ElmInt), Tag_Int);
    if (!obj) return HPtr::fromBits(0);

    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_float_fast(double value) {
    void* obj = Allocator::instance().allocateFast(sizeof(ElmFloat));
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Float;
    hdr->size = static_cast<u32>(sizeof(ElmFloat));
    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_float_slow(double value) {
    void* obj = Allocator::instance().allocateSlow(sizeof(ElmFloat), Tag_Float);
    if (!obj) return HPtr::fromBits(0);

    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_char_fast(uint32_t value) {
    void* obj = Allocator::instance().allocateFast(sizeof(ElmChar));
    if (!obj) return HPtr::fromBits(0);

    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Char;
    hdr->size = static_cast<u32>(sizeof(ElmChar));
    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_alloc_char_slow(uint32_t value) {
    void* obj = Allocator::instance().allocateSlow(sizeof(ElmChar), Tag_Char);
    if (!obj) return HPtr::fromBits(0);

    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);

    return ptrToHPointer(obj);
}

extern "C" void* eco_gc_alloc_region_fast(size_t total) {
    return Allocator::instance().allocateFast(total);
}

extern "C" void* eco_gc_alloc_region_slow(size_t total) {
    return Allocator::instance().allocateRegionSlow(total);
}

extern "C" void eco_alloc_closure_group_slow(
    uint64_t numSiblings,
    const void* const* evaluators,
    const uint32_t* arities,
    const uint32_t* numCaptured,
    const uint64_t* unboxedBitmaps,
    const uint8_t* resultKinds,
    const uint32_t* captureOffsets,
    const uint64_t* captures,
    const uint64_t* crossEdges,
    uint64_t numCrossEdges,
    uint64_t* outClosures) {
    // Compute total size: sum of per-sibling closure sizes, all naturally
    // 8-byte aligned since Header/metadata/EvalFunction/Unboxable are each
    // 8 bytes. Closure capacity uses `arities[i]` (max_values) so the
    // allocated storage has room for future PAP-extend slots too.
    size_t totalBytes = 0;
    for (uint64_t i = 0; i < numSiblings; ++i) {
        const size_t perSibling = sizeof(Header) + 8 + sizeof(EvalFunction)
                                + static_cast<size_t>(arities[i]) * sizeof(Unboxable);
        totalBytes += perSibling;
    }

    // Reserve one contiguous region so every sibling lives in a single
    // generation (nursery or pinned large-obj). Any GC triggered by the
    // slow path happens BEFORE any sibling is written, so input
    // `captures[]` raw HPointers passed in must have been kept alive by
    // the caller's GC-root frame up to this call.
    void* region = eco_gc_alloc_region_fast(totalBytes);
    if (!region) {
        region = eco_gc_alloc_region_slow(totalBytes);
    }

    // First pass: initialize each sibling's header and publish HPointer.
    // Producers need each sibling's HPointer to be known before we wire
    // up cross-edges in pass two.
    char* cursor = static_cast<char*>(region);
    for (uint64_t i = 0; i < numSiblings; ++i) {
        const uint32_t arity = arities[i];
        const uint32_t nc = numCaptured[i];
        const size_t perSibling = sizeof(Header) + 8 + sizeof(EvalFunction)
                                + static_cast<size_t>(arity) * sizeof(Unboxable);

        void* obj = cursor;
        Header* hdr = getHeader(obj);
        std::memset(hdr, 0, sizeof(Header));
        hdr->tag = Tag_Closure;
        hdr->size = static_cast<u32>(
            (perSibling - sizeof(Closure)) / sizeof(Unboxable));

        Closure* closure = static_cast<Closure*>(obj);
        closure->n_values = nc;
        closure->max_values = arity;
        // result_kind matches the wrapper's real C-ABI return type so the
        // closure-invocation paths can cast `evaluator` correctly without
        // per-call-site plumbing.
        closure->result_kind = resultKinds[i] & 0x3;
        closure->unboxed = unboxedBitmaps[i];
        closure->evaluator = reinterpret_cast<EvalFunction>(
            const_cast<void*>(evaluators[i]));

        // Non-sibling captures: pre-ordered into slots [0 .. capture_counts[i]).
        const uint32_t capStart = captureOffsets[i];
        const uint32_t capEnd = captureOffsets[i + 1];
        for (uint32_t k = capStart, slot = 0; k < capEnd; ++k, ++slot) {
            closure->values[slot].i = static_cast<i64>(captures[k]);
        }

        outClosures[i] = ptrToHPointer(obj).toBits();
        cursor += perSibling;
    }

    // Second pass: wire cross-edges. All siblings share a generation so a
    // plain i64 store is correct — no write barrier needed.
    for (uint64_t e = 0; e < numCrossEdges; ++e) {
        const uint64_t producer = crossEdges[3 * e + 0];
        const uint64_t consumer = crossEdges[3 * e + 1];
        const uint64_t slot     = crossEdges[3 * e + 2];

        Closure* consumerClosure = static_cast<Closure*>(
            hpointerToPtr(outClosures[consumer]));
        consumerClosure->values[slot].i = static_cast<i64>(outClosures[producer]);
    }
}

//===----------------------------------------------------------------------===//
// Init-at-pointer Functions (for group allocation)
//===----------------------------------------------------------------------===//

extern "C" HPtr eco_init_int_at(void* obj, int64_t value) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Int;
    hdr->size = static_cast<u32>(sizeof(ElmInt));
    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_float_at(void* obj, double value) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Float;
    hdr->size = static_cast<u32>(sizeof(ElmFloat));
    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_char_at(void* obj, uint32_t value) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Char;
    hdr->size = static_cast<u32>(sizeof(ElmChar));
    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_cons_at(void* obj, uint64_t head, HPtr tail, uint32_t head_kind) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Cons;
    hdr->size = static_cast<u32>(sizeof(Cons));
    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_kind & 0x3);
    cons->head.i = static_cast<i64>(head);
    uint64_t tail_bits = tail.toBits();
    HPointer tail_hp;
    memcpy(&tail_hp, &tail_bits, sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_tuple2_at(void* obj, uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple2;
    hdr->size = static_cast<u32>(sizeof(Tuple2));
    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0xF);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_tuple3_at(void* obj, uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Tuple3;
    hdr->size = static_cast<u32>(sizeof(Tuple3));
    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask & 0x3F);
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);
    tup->c.i = static_cast<i64>(c);
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_record_at(void* obj, uint32_t field_count, uint64_t unboxed_bitmap) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Record;
    hdr->size = field_count;
    Record* rec = static_cast<Record*>(obj);
    rec->unboxed = unboxed_bitmap;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_custom_at(void* obj, uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_Custom;
    hdr->size = (sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes - sizeof(Custom)) / sizeof(Unboxable);
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;
    return ptrToHPointer(obj);
}

extern "C" HPtr eco_init_string_at(void* obj, uint32_t length) {
    Header* hdr = getHeader(obj);
    std::memset(hdr, 0, sizeof(Header));
    hdr->tag = Tag_String;
    hdr->size = length;
    return ptrToHPointer(obj);
}

//===----------------------------------------------------------------------===//
// Stale-pointer validator (called from the EcoBoxedStoreVerify-inserted
// barrier in front of compiled-Elm direct heap stores)
//===----------------------------------------------------------------------===//

extern "C" void eco_validate_nursery_hptr_bits(uint64_t bits) {
    alloc::validateNurseryHPtrBits(bits);
}

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

extern "C" void eco_store_field(HPtr obj_hptr, uint32_t index, HPtr value) {
    // Always-on per-write stale-pointer tripwire. Catches stale `value`
    // writes at the moment they happen, producing a backtrace showing the
    // compiled function. Skips null/zero and embedded constants. See
    // HeapHelpers.hpp `validateNurseryHPtr` for the rationale.
    alloc::validateNurseryHPtrBits(value.toBits());
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    // Get the header to determine object type
    Header* header = static_cast<Header*>(obj);

    // In JIT mode, pointers are full 64-bit addresses.
    // Store the full value directly in the Unboxable union's i field.
    // This preserves all 64 bits for proper pointer traversal.

    uint64_t value_bits = value.toBits();
    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].i = static_cast<i64>(value_bits);
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            Unboxable* field = (index == 0) ? &tuple->a : &tuple->b;
            field->i = static_cast<i64>(value_bits);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            Unboxable* field = (index == 0) ? &tuple->a : (index == 1) ? &tuple->b : &tuple->c;
            field->i = static_cast<i64>(value_bits);
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            if (index == 0) {
                cons->head.i = static_cast<i64>(value_bits);
            } else {
                // Tail is HPointer, not Unboxable - store as raw bits
                // Note: This may cause issues with 64-bit pointers in JIT mode
                cons->tail.ptr = value_bits & 0xFFFFFFFFFF;
                cons->tail.constant = (value_bits >> 40) & 0xF;
                cons->tail.padding = 0;
            }
            break;
        }
        case Tag_Closure: {
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].i = static_cast<i64>(value_bits);
            break;
        }
        default:
            // Unknown object type
            fprintf(stderr, "eco_store_field: unknown object type %d\n", header->tag);
            break;
    }
}

extern "C" void eco_store_field_i64(HPtr obj_hptr, uint32_t index, int64_t value) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);

    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].i = value;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            if (index == 0) tuple->a.i = value;
            else tuple->b.i = value;
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            if (index == 0) tuple->a.i = value;
            else if (index == 1) tuple->b.i = value;
            else tuple->c.i = value;
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            if (index == 0) cons->head.i = value;
            break;
        }
        case Tag_Closure: {
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].i = value;
            break;
        }
        default:
            fprintf(stderr, "eco_store_field_i64: unknown object type %d\n", header->tag);
            break;
    }
}

extern "C" void eco_store_field_f64(HPtr obj_hptr, uint32_t index, double value) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);

    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].f = value;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            if (index == 0) tuple->a.f = value;
            else tuple->b.f = value;
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            if (index == 0) tuple->a.f = value;
            else if (index == 1) tuple->b.f = value;
            else tuple->c.f = value;
            break;
        }
        case Tag_Closure: {
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].f = value;
            break;
        }
        default:
            fprintf(stderr, "eco_store_field_f64: unknown object type %d\n", header->tag);
            break;
    }
}

//===----------------------------------------------------------------------===//
// Closure Operations
//===----------------------------------------------------------------------===//

namespace {

// Phase C shim support: a 4×64 static table of all-`PK_Boxed`-args
// `EvalParamLayout`s indexed by `(result_kind, num_params)`. The legacy
// `eco_apply_closure` entry — called by C++ effect-manager kernels and
// the platform runtime with HPointer-encoded args — looks up the right
// row from the closure header's `result_kind` field, so it forwards
// through `eco_apply_closure_typed` with a layout whose `result_kind`
// matches the closure's wrapper return ABI. Without this, primitive-
// return wrappers would be mis-cast as `void *(void *[])` on the
// dispatch path.
//
// Each layout's bytes match `EvalParamLayout` exactly:
//   byte 0       : num_params
//   byte 1       : result_kind (the row's K)
//   bytes 2..N+1 : kinds[N] (all PK_Boxed)
constexpr unsigned kMaxClosureArity = 63;
constexpr unsigned kNumResultKinds = 4;  // PK_Boxed, PK_Int, PK_Float, PK_Char

constexpr auto buildAllBoxedLayouts() {
    struct LayoutBytes {
        unsigned char num_params;
        unsigned char result_kind;
        unsigned char kinds[kMaxClosureArity];
    };
    struct Holder {
        LayoutBytes data[kNumResultKinds][kMaxClosureArity + 1];
    };
    Holder h{};
    for (unsigned k = 0; k < kNumResultKinds; ++k) {
        for (unsigned n = 0; n <= kMaxClosureArity; ++n) {
            h.data[k][n].num_params = static_cast<unsigned char>(n);
            h.data[k][n].result_kind = static_cast<unsigned char>(k);
            // kinds[] are PK_Boxed (0) from value-initialisation.
        }
    }
    return h;
}
constexpr auto kAllBoxedLayoutsHolder = buildAllBoxedLayouts();

// Pick the layout whose `result_kind` byte matches `K`. The legacy entry
// `eco_apply_closure` reads K off the closure header so primitive-return
// wrappers are dispatched correctly even for callers that don't carry K.
inline const EvalParamLayout* getAllBoxedLayout(unsigned n, uint8_t K) {
    if (n > kMaxClosureArity) n = kMaxClosureArity;
    if (K >= kNumResultKinds) K = 0;
    return reinterpret_cast<const EvalParamLayout*>(&kAllBoxedLayoutsHolder.data[K][n]);
}

} // anonymous namespace

// Phase C: legacy boxed-args entry point. C++ callers that construct a
// `uint64_t* args` of HPointer-encoded values (effect-manager workers,
// `Scheduler::callClosureN`, `PlatformRuntime`) reach
// `eco_apply_closure_typed` through here. The layout's `result_kind`
// byte is filled from `closure->result_kind` so primitive-return
// wrappers route via the correct `invokeSaturatedTyped` cast. Boxed-args
// callers that target a primitive-result closure get a freshly boxed
// `ElmInt`/`ElmFloat`/`ElmChar` back — semantics-preserving for legacy
// callers that always expected an `HPtr`.
extern "C" HPtr eco_apply_closure(HPtr closure_hptr, uint64_t* args, uint32_t num_args) {
    void* closure_ptr = hpointerToPtr(closure_hptr.toBits());
    uint8_t K = closure_ptr ? static_cast<Closure*>(closure_ptr)->result_kind : 0;
    const EvalParamLayout* layout =
        (num_args == 0) ? nullptr : getAllBoxedLayout(num_args, K);
    return eco_apply_closure_typed(closure_hptr,
                                   reinterpret_cast<int64_t*>(args),
                                   num_args, layout);
}

namespace {

// Forward declarations for helpers defined further down. `eco_apply_closure_eval`
// needs to call `invokeSaturatedTyped`, which itself uses
// `spliceArgsForSaturatedCall`; both are also reused by
// `eco_closure_call_saturated`.
inline Closure* spliceArgsForSaturatedCall(uint64_t& closure_bits_inout,
                                            uint64_t* new_args,
                                            uint32_t num_newargs,
                                            const EvalParamLayout* layout,
                                            void** combined_args,
                                            uint32_t& max_values_out,
                                            uint64_t& bitmap_out);

void invokeSaturatedTyped(uint64_t closure_bits,
                          int64_t* typed_args,
                          uint32_t num_args,
                          const EvalParamLayout* args_layout,
                          uint8_t K,
                          uint8_t desired_kind,
                          void* result_slot);

// Extract a primitive payload from an HPointer-encoded boxed value (an
// ElmInt / ElmFloat / ElmChar) and store it into `result_slot` per
// `desired_kind`. Used by the boxed-evaluator path of
// `eco_apply_closure_eval` when the caller wants a typed primitive.
void deliverPrimitiveFromBoxed(HPtr boxed, uint8_t desired_kind, void* result_slot) {
    void* obj = hpointerToPtr(boxed.toBits());
    assert(obj && "deliverPrimitiveFromBoxed: cannot un-box null/embedded HPointer");
    const char* base = static_cast<const char*>(obj) + sizeof(Header);
    switch (desired_kind) {
        case 1: { // PK_Int
            int64_t v;
            memcpy(&v, base, sizeof(v));
            *static_cast<int64_t*>(result_slot) = v;
            break;
        }
        case 2: { // PK_Float
            double f;
            memcpy(&f, base, sizeof(f));
            *static_cast<double*>(result_slot) = f;
            break;
        }
        case 3: { // PK_Char
            uint16_t c;
            memcpy(&c, base, sizeof(c));
            *static_cast<uint16_t*>(result_slot) = c;
            break;
        }
        default:
            assert(false && "deliverPrimitiveFromBoxed: unreachable desired_kind");
            __builtin_unreachable();
    }
}

} // anonymous namespace

// Phase E: canonical generic-apply entry point with typed result delivery.
//
// Args interpretation is fully typed per REP_ABI_001:
//   - layout->kinds[i] == 0 (PK_Boxed)  → typed_args[i] is an HPointer.
//   - layout->kinds[i] == 1 (PK_Int)    → typed_args[i] is a raw i64.
//   - layout->kinds[i] == 2 (PK_Float)  → typed_args[i] is f64 bits in i64.
//   - layout->kinds[i] == 3 (PK_Char)   → typed_args[i] is i16 zext in i64.
// `args_layout` may be null only when num_args == 0.
//
// `args_layout->result_kind` (`K`) is the closure evaluator's real C-ABI
// return kind. The saturated branch reinterprets `closure->evaluator`
// based on `K`. `desired_kind` is what the caller wants delivered into
// `result_slot`; the helper boxes/unboxes across the K↔desired_kind
// boundary as needed.
//
// Saturation cases:
//   - num_args == 0        → no-op apply, return closure unchanged
//                            (`desired_kind` must be PK_Boxed).
//   - num_args <  remaining → eco_pap_extend (always returns a closure HPtr;
//                              `desired_kind` must be PK_Boxed).
//   - num_args == remaining → call evaluator (per K), then deliver result.
//   - num_args >  remaining → saturate this stage, recurse with trailing args
//                              and a PK_Boxed sub-layout.
extern "C" void eco_apply_closure_eval(HPtr closure_hptr,
                                       int64_t* typed_args,
                                       uint32_t num_args,
                                       const EvalParamLayout* args_layout,
                                       void* result_slot,
                                       uint8_t desired_kind) {
    assert(desired_kind <= 3 && "eco_apply_closure_eval: desired_kind out of range");

    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) {
        // Null/embedded closure: deliver zero in the desired slot so the
        // caller doesn't read uninitialised storage.
        switch (desired_kind) {
            case 0: *static_cast<HPtr*>(result_slot) = HPtr::fromBits(0); break;
            case 1: *static_cast<int64_t*>(result_slot) = 0; break;
            case 2: *static_cast<double*>(result_slot) = 0.0; break;
            case 3: *static_cast<uint16_t*>(result_slot) = 0; break;
        }
        return;
    }

    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;
    uint32_t max_values = closure->max_values;
    assert(max_values <= 63 && "max_values exceeds 6-bit field cap");
    uint32_t remaining = max_values - n_values;

    // Phase C/D: K is read from the closure header, not the layout. The
    // layout's `result_kind` byte (if present) is a redundant hint and
    // is allowed to drift — the frontend can only derive layout K from
    // the static call-site type, which loses precision for staged-curried
    // closures (e.g. `Mono.stageReturnType` peels one MFunction layer,
    // returning the inner MFunction for a flat single-stage closure
    // whose actual return type lives one more level in). The closure
    // header is the authoritative source of truth so C++-kernel callers
    // (which don't see the layout) still get correct dispatch via
    // `eco_apply_closure(legacy)` → `eco_apply_closure_typed` → here.
    uint8_t K = closure->result_kind;
    assert(K <= 3 && "eco_apply_closure_eval: closure result_kind out of range");

    if (num_args == 0) {
        // No-op apply: closure is unchanged. By construction the caller
        // wants a boxed result here (a no-op apply on a closure is itself
        // a closure HPtr).
        assert(desired_kind == 0 &&
               "eco_apply_closure_eval: no-op apply requires PK_Boxed desired_kind");
        *static_cast<HPtr*>(result_slot) = closure_hptr;
        return;
    }

    // Root `closure_bits` and the typed args buffer's HPointer slots
    // across the inner runtime call. Mask comes from the layout's kinds
    // so primitive slots are correctly skipped by the GC scan.
    size_t saved_range = eco_gc_stack_range_point();
    eco_gc_push_stack_range(&closure_bits, 1, 1);
    if (num_args > 0 && args_layout) {
        uint64_t hptrMask = 0;
        for (uint32_t i = 0; i < num_args && i < 64; ++i) {
            if (args_layout->kinds[i] == 0) hptrMask |= (uint64_t{1} << i);
        }
        if (hptrMask != 0) {
            eco_gc_push_stack_range(reinterpret_cast<uint64_t*>(typed_args),
                                    num_args, hptrMask);
        }
    }

#if ECO_HEAP_VALIDATE
    // Stale-arg tripwire: every PK_Boxed slot must resolve to an allocated
    // region. Catches callers that hold an HPointer by-value across an
    // earlier `eco_alloc_*` GC point. Primitive slots carry raw bits, not
    // HPointers, so they are skipped via `args_layout`.
    for (uint32_t dbg_i = 0; dbg_i < num_args; ++dbg_i) {
        uint8_t kind = args_layout ? args_layout->kinds[dbg_i] : 0;
        if (kind != 0) continue;
        uint64_t raw = static_cast<uint64_t>(typed_args[dbg_i]);
        HPointer hp;
        memcpy(&hp, &raw, sizeof(hp));
        if (hp.constant == 0 && hp.ptr != 0) {
            hpointerToPtr(raw);
        }
    }
#endif

    if (num_args < remaining) {
        // Under-saturated: extend with newargs. Always produces a closure
        // HPtr regardless of `K`, so the caller must want PK_Boxed.
        assert(desired_kind == 0 &&
               "eco_apply_closure_eval: under-saturated apply requires PK_Boxed "
               "desired_kind (well-typed IR cannot have a primitive result on "
               "an under-saturated apply)");
        assert(num_args <= 32 &&
               "eco_apply_closure_eval: under-saturated bitmap derivation caps at 32 args");
        uint64_t bitmap = 0;
        if (args_layout != nullptr) {
            for (uint32_t i = 0; i < num_args; ++i) {
                bitmap |= (static_cast<uint64_t>(args_layout->kinds[i]) & 0x3ULL) << (2 * i);
            }
        }
        HPtr extended = eco_pap_extend(HPtr::fromBits(closure_bits),
                                       reinterpret_cast<uint64_t*>(typed_args),
                                       num_args, bitmap);
        *static_cast<HPtr*>(result_slot) = extended;
        eco_gc_restore_stack_range_point(saved_range);
        return;
    }

    if (num_args == remaining) {
        // Exactly saturated. Dispatch on the evaluator's real C ABI (`K`).
        // `invokeSaturatedTyped` casts `closure->evaluator` to the matching
        // primitive-return signature and converts the result to
        // `desired_kind` (boxing if the caller wants a boxed result).
        invokeSaturatedTyped(closure_bits, typed_args, num_args, args_layout,
                             K, desired_kind, result_slot);
        eco_gc_restore_stack_range_point(saved_range);
        return;
    }

    // Over-saturated: saturate this stage (always boxed result intermediate,
    // since under-saturation produces a closure HPtr), then apply the
    // remainder to the result closure with a PK_Boxed sub-layout. If the
    // caller wants a primitive result, we recurse asking for that primitive
    // on the final saturated apply.
    HPtr intermediate = eco_closure_call_saturated(
        HPtr::fromBits(closure_bits),
        reinterpret_cast<uint64_t*>(typed_args),
        remaining, args_layout);

    uint32_t trailing = num_args - remaining;
    unsigned char sub_buf[2 + 64] = {};
    EvalParamLayout* sub = reinterpret_cast<EvalParamLayout*>(sub_buf);
    sub->num_params = static_cast<unsigned char>(trailing);
    // Phase C: the recursive call reads K from `intermediate->result_kind`,
    // not from the sub-layout. Mirror it on the layout so the
    // layout-vs-closure cross-check assertion holds.
    {
        void* inter_ptr = hpointerToPtr(intermediate.toBits());
        sub->result_kind = inter_ptr
            ? static_cast<Closure*>(inter_ptr)->result_kind
            : 0;
    }
    if (args_layout != nullptr) {
        memcpy(sub->kinds, args_layout->kinds + remaining, trailing);
    }
    eco_apply_closure_eval(intermediate, typed_args + remaining,
                           trailing, sub, result_slot, desired_kind);

    eco_gc_restore_stack_range_point(saved_range);
}

// Phase E: legacy boxed-result entry point, now a thin shim around
// `eco_apply_closure_eval` with `desired_kind = PK_Boxed`. Every existing
// caller that wants an HPtr result reaches the canonical helper through
// here. For primitive-result closures the inner helper allocates the
// matching ElmInt/ElmFloat/ElmChar to satisfy the boxed return.
extern "C" HPtr eco_apply_closure_typed(HPtr closure_hptr,
                                        int64_t* typed_args,
                                        uint32_t num_args,
                                        const EvalParamLayout* args_layout) {
    HPtr result = HPtr::fromBits(0);
    eco_apply_closure_eval(closure_hptr, typed_args, num_args, args_layout,
                           &result, /*desired_kind=*/0);
    return result;
}

// Phase D Part 2: typed-args entry point for segmentation-unknown apply.
//
// Takes a single typed `int64_t*` buffer plus an `EvalParamLayout` (instead
// of the previous dual buffer + bitmap form). The runtime decides at the
// closure header whether the call is under- or saturated, and routes:
//
//   under-saturated  → eco_pap_extend (with a bitmap derived from layout)
//   saturated/over   → eco_apply_closure_typed (which centralises any
//                      necessary primitive re-boxing for the saturated path)
//
// `args_layout` may be null only for the all-boxed fallback case; every
// emitter today passes a non-null layout.
extern "C" HPtr eco_apply_segmentation_unknown(HPtr closure_hptr,
                                               int64_t* typed_args,
                                               uint32_t num_args,
                                               const EvalParamLayout* args_layout) {
    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) return HPtr::fromBits(0);

    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;
    uint32_t max_values = closure->max_values;

    // DIAG: Check for corrupted closure header
    if (max_values == 0 || max_values > 63) {
        uint64_t packed;
        memcpy(&packed, reinterpret_cast<char*>(closure_ptr) + 8, sizeof(packed));
        // Check if the closure has been forwarded (GC moved it)
        fprintf(stderr, "DIAG: eco_apply_segmentation_unknown bad closure: hptr=0x%lx ptr=%p tag=%u n_values=%u max_values=%u num_args=%u packed=0x%lx\n",
                closure_bits, closure_ptr, closure->header.tag, n_values, max_values, num_args, packed);
        fprintf(stderr, "  header: color=%u pin=%u age=%u unboxed=%u size=%u\n",
                closure->header.color, closure->header.pin,
                closure->header.age, closure->header.unboxed, closure->header.size);
        fprintf(stderr, "  evaluator=%p\n", (void*)closure->evaluator);
        fflush(stderr);
        // Abort early so we get the full output before the assertion
        abort();
    }
    uint32_t remaining = max_values - n_values;

    // Root closure_bits across the inner call.
    size_t saved_range = eco_gc_stack_range_point();
    eco_gc_push_stack_range(&closure_bits, 1, 1);
    HPtr result;

    if (num_args < remaining) {
        // Under-saturated: hand the typed args to eco_pap_extend along with a
        // 2-bit-per-slot bitmap derived from the layout's kinds. This matches
        // the encoding `eco_pap_extend` expects (kind 0 = HPointer; non-zero =
        // primitive index into ParamKind).
        //
        // The bitmap is u64 with 2 bits per slot, so it holds at most 32 slots.
        // Closures with >32 typed newargs under-saturated would silently lose
        // primitive-ness for slots 32+ — fail loud instead. Lifting this cap
        // requires switching from a packed bitmap to a heap- or stack-allocated
        // kind array.
        assert(num_args <= 32 &&
               "eco_apply_segmentation_unknown: bitmap derivation caps at 32 args");
        uint64_t bitmap = 0;
        if (args_layout != nullptr) {
            for (uint32_t i = 0; i < num_args; ++i) {
                bitmap |= (static_cast<uint64_t>(args_layout->kinds[i]) & 0x3ULL) << (2 * i);
            }
        }
        if (num_args > 0) {
            uint64_t mask = pointerMaskFromKindBitmap(bitmap, num_args);
            if (mask != 0) {
                eco_gc_push_stack_range(reinterpret_cast<uint64_t*>(typed_args), num_args, mask);
            }
        }
        result = eco_pap_extend(HPtr::fromBits(closure_bits),
                                reinterpret_cast<uint64_t*>(typed_args),
                                num_args, bitmap);
    } else {
        // Saturated/over-saturated: forward to the typed-apply entry point,
        // which centralises any required primitive re-boxing before invoking
        // the evaluator. No parallel boxed buffer is needed.
        result = eco_apply_closure_typed(HPtr::fromBits(closure_bits),
                                         typed_args, num_args, args_layout);
    }

    eco_gc_restore_stack_range_point(saved_range);
    return result;
}

extern "C" HPtr eco_pap_extend(HPtr closure_hptr, uint64_t* args, uint32_t num_newargs,
                                   uint64_t new_unboxed_bitmap) {
    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) return HPtr::fromBits(0);

    Closure* old_closure = static_cast<Closure*>(closure_ptr);

    // Get the current state of the closure.
    uint32_t old_n_values = old_closure->n_values;
    uint32_t max_values = old_closure->max_values;
    uint64_t old_unboxed = old_closure->unboxed;
    uint8_t old_result_kind = old_closure->result_kind;

    // Calculate new n_values.
    uint32_t new_n_values = old_n_values + num_newargs;

    // Sanity check: should not exceed max_values for partial application.
    // (Saturated calls should use eco_closure_call_saturated instead.)
    if (new_n_values > max_values) {
        fprintf(stderr, "eco_pap_extend: new_n_values (%u) exceeds max_values (%u)\n",
                new_n_values, max_values);
        return HPtr::fromBits(0);
    }

    // Allocate a new closure with room for all captured values.
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + new_n_values * sizeof(Unboxable);

    // Fast path: bump-pointer with no rooting. allocateFast cannot GC, so
    // closure_bits and args remain valid across the allocation.
    void* obj = Allocator::instance().allocateFast(size);
    bool slow_path_rooted = false;
    size_t saved_range = 0;
    if (obj) {
        Header* hdr = getHeader(obj);
        std::memset(hdr, 0, sizeof(Header));
        hdr->tag = Tag_Closure;
        hdr->size = (size - sizeof(Closure)) / sizeof(Unboxable);
    } else {
        // Slow path: root closure_bits and HPointer args across the GC that
        // allocateSlow may run.
        saved_range = eco_gc_stack_range_point();
        slow_path_rooted = true;
        eco_gc_push_stack_range(&closure_bits, 1, 1);
        if (num_newargs > 0) {
            uint64_t mask = pointerMaskFromKindBitmap(new_unboxed_bitmap, num_newargs);
            if (mask != 0) {
                eco_gc_push_stack_range(args, num_newargs, mask);
            }
        }
        obj = Allocator::instance().allocateSlow(size, Tag_Closure);
        if (!obj) {
            eco_gc_restore_stack_range_point(saved_range);
            return HPtr::fromBits(0);
        }
    }

    // Re-resolve old_closure: allocateSlow may have triggered GC and moved it.
    // (Cheap on the fast path: hpointerToPtr is a single shift+add.)
    old_closure = static_cast<Closure*>(hpointerToPtr(closure_bits));

    Closure* new_closure = static_cast<Closure*>(obj);

    // Copy metadata from old closure. `result_kind` propagates because the
    // extended closure shares the same evaluator and therefore the same
    // C-ABI return type.
    new_closure->n_values = new_n_values;
    new_closure->max_values = max_values;
    new_closure->result_kind = old_result_kind;
    new_closure->evaluator = old_closure->evaluator;

    // Merge 2-bit-per-slot unboxed bitmaps: old kinds + new kinds shifted by
    // old_n_values * 2 bits per slot.
    uint64_t new_bitmap_width = num_newargs < 32 ? (1ULL << (2 * num_newargs)) - 1 : ~0ULL;
    uint64_t masked_new_bitmap = new_unboxed_bitmap & new_bitmap_width;
    uint64_t shifted_new_bitmap = masked_new_bitmap << (2 * old_n_values);
    new_closure->unboxed = old_unboxed | shifted_new_bitmap;

    // Copy old captured values.
    for (uint32_t i = 0; i < old_n_values; i++) {
        new_closure->values[i] = old_closure->values[i];
    }

    // Copy new arguments.
    for (uint32_t i = 0; i < num_newargs; i++) {
        new_closure->values[old_n_values + i].i = static_cast<i64>(args[i]);
    }

    // Only the slow path opened a root range; fast path skipped rooting
    // entirely.
    if (slow_path_rooted) {
        eco_gc_restore_stack_range_point(saved_range);
    }
    return ptrToHPointer(obj);
}

namespace {

// Splice captures + newargs into a single typed buffer matching the
// closure's wrapper convention. Used by both `eco_closure_call_saturated`
// (boxed-result path) and `eco_apply_closure_eval`'s K!=0 saturated path
// (primitive-result path).
//
// On entry `closure_bits_inout` and the buffer must already be GC-rooted
// by the caller. Returns the (possibly re-resolved) `Closure*` after any
// boxing allocations, since `eco_alloc_*` calls inside this helper may
// trigger GC.
//
// `closure_bits_inout` is updated to reflect the (re-)resolved closure
// pointer, and the *output* `bitmap` mirrors `closure->unboxed` after
// any GC-induced re-resolves.
inline Closure* spliceArgsForSaturatedCall(uint64_t& closure_bits_inout,
                                            uint64_t* new_args,
                                            uint32_t num_newargs,
                                            const EvalParamLayout* layout,
                                            void** combined_args,
                                            uint32_t& max_values_out,
                                            uint64_t& bitmap_out) {
    Closure* closure = static_cast<Closure*>(hpointerToPtr(closure_bits_inout));
    assert(closure && "spliceArgsForSaturatedCall: null closure");
    uint32_t max_values = closure->max_values;
    uint32_t n_values = closure->n_values;
    assert(n_values + num_newargs == max_values
           && "spliceArgsForSaturatedCall: argument count mismatch");
    assert(max_values <= 63 && "max_values exceeds 6-bit field cap");

    uint64_t bitmap = closure->unboxed;

    // Captures: stored raw per closure->unboxed; copy directly.
    for (uint32_t i = 0; i < n_values; ++i) {
        combined_args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }

    // Newargs: convert from caller's layout convention to closure's
    // wrapper convention slot-by-slot.
    for (uint32_t i = 0; i < num_newargs; ++i) {
        uint32_t slot = n_values + i;
        uint64_t closureKind = (bitmap >> (2 * slot)) & 0x3ULL;
        uint64_t callerKind = layout ? (layout->kinds[i] & 0x3ULL) : 0ULL;
        uint64_t raw = new_args[i];
        if (closureKind == callerKind) {
            // Already in the right encoding.
        } else if (callerKind == 0 && closureKind != 0) {
            // Boxed → primitive: un-box. The HPointer points at an
            // ElmInt/ElmFloat/ElmChar with the value at offset 8.
            void* hp_ptr = hpointerToPtr(raw);
            assert(hp_ptr && "spliceArgsForSaturatedCall: cannot un-box null/embedded HPointer");
            const char* base = reinterpret_cast<const char*>(hp_ptr) + sizeof(Header);
            switch (closureKind) {
                case 1: { // PK_Int
                    int64_t v;
                    memcpy(&v, base, sizeof(int64_t));
                    raw = static_cast<uint64_t>(v);
                    break;
                }
                case 2: { // PK_Float
                    double f;
                    memcpy(&f, base, sizeof(double));
                    memcpy(&raw, &f, sizeof(uint64_t));
                    break;
                }
                case 3: { // PK_Char
                    u16 c;
                    memcpy(&c, base, sizeof(u16));
                    raw = static_cast<uint64_t>(c);
                    break;
                }
                default:
                    assert(false && "unreachable closureKind");
                    __builtin_unreachable();
            }
        } else if (callerKind != 0 && closureKind == 0) {
            // Primitive → boxed: box via the matching allocator. (Rare —
            // happens when a typed-args caller targets a closure whose
            // wrapper expects an !eco.value at this slot.)
            switch (callerKind) {
                case 1:
                    raw = eco_alloc_int(static_cast<int64_t>(raw)).toBits();
                    break;
                case 2: {
                    double f;
                    memcpy(&f, &raw, sizeof(double));
                    raw = eco_alloc_float(f).toBits();
                    break;
                }
                case 3:
                    raw = eco_alloc_char(static_cast<uint32_t>(raw & 0xFFFFu)).toBits();
                    break;
                default:
                    assert(false && "unreachable callerKind");
                    __builtin_unreachable();
            }
            // Re-resolve closure: eco_alloc_* may have GC'd.
            closure = static_cast<Closure*>(hpointerToPtr(closure_bits_inout));
        } else {
            // Both kinds primitive but distinct (e.g. Int vs Float). This
            // is a representation mismatch the compiler should have ruled
            // out. Trust it and pass through.
        }
        combined_args[slot] = reinterpret_cast<void*>(raw);
    }

#if ECO_HEAP_VALIDATE
    // Stale-arg tripwire: validate combined_args before the helper returns.
    // Catches stale entries arising from caller bugs or missed re-resolves
    // across the boxing/un-boxing GC points above. Primitive slots carry
    // raw bits, not HPointers, so they are skipped via `bitmap`
    // (closure->unboxed). Centralised here so both `eco_closure_call_saturated`
    // (K==0) and `invokeSaturatedTyped` (K!=0) get the check.
    for (uint32_t dbg_i = 0; dbg_i < max_values; ++dbg_i) {
        uint64_t closureKind = (bitmap >> (2 * dbg_i)) & 0x3ULL;
        if (closureKind != 0) continue;
        uint64_t raw = reinterpret_cast<uint64_t>(combined_args[dbg_i]);
        HPointer hp;
        memcpy(&hp, &raw, sizeof(hp));
        if (hp.constant == 0 && hp.ptr != 0) {
            hpointerToPtr(raw);
        }
    }
#endif

    max_values_out = max_values;
    bitmap_out = bitmap;
    return closure;
}

} // anonymous namespace

extern "C" HPtr eco_closure_call_saturated(HPtr closure_hptr, uint64_t* new_args, uint32_t num_newargs, const EvalParamLayout* layout) {
    uint64_t closure_bits = closure_hptr.toBits();
    void* closure_ptr = hpointerToPtr(closure_bits);
    if (!closure_ptr) return HPtr::fromBits(0);

    // Phase C: dispatch on the closure evaluator's real C-ABI return
    // kind, read from `closure->result_kind` (set by papCreate /
    // eco_alloc_closure_k from the wrapper's compiled return ABI).
    // Reading from the closure header — rather than from the optional
    // `layout` argument — lets C++ kernel callers (List, JsArray,
    // String, Bytes) keep passing `layout=nullptr` and still dispatch
    // primitive-return wrappers correctly.
    Closure* hdr_closure = static_cast<Closure*>(closure_ptr);
    uint8_t K = hdr_closure->result_kind;
    if (K != 0) {
        size_t saved_range = eco_gc_stack_range_point();
        eco_gc_push_stack_range(&closure_bits, 1, 1);
        // Root the typed-args buffer's HPointer slots so GC inside the
        // evaluator can update them in place.
        if (num_newargs > 0 && layout) {
            uint64_t hptrMask = 0;
            for (uint32_t i = 0; i < num_newargs && i < 64; ++i) {
                if (layout->kinds[i] == 0) hptrMask |= (uint64_t{1} << i);
            }
            if (hptrMask != 0) {
                eco_gc_push_stack_range(new_args, num_newargs, hptrMask);
            }
        }
        HPtr result = HPtr::fromBits(0);
        invokeSaturatedTyped(closure_bits,
                             reinterpret_cast<int64_t*>(new_args),
                             num_newargs, layout, K,
                             /*desired_kind=*/0, &result);
        eco_gc_restore_stack_range_point(saved_range);
        return result;
    }

    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t max_values = closure->max_values;

    // Phase E: typed calling convention (REP_ABI_001). Splice captures +
    // newargs into a single buffer matching the closure's wrapper
    // convention via the shared helper.
    void* stack_args[16];
    void** combined_args = (max_values <= 16) ? stack_args :
                           static_cast<void**>(alloca(max_values * sizeof(void*)));

    memset(combined_args, 0, max_values * sizeof(void*));

    // Open a stack root range over closure_bits and the combined buffer.
    // The boxed-slot mask comes from `closure->unboxed` (the full-params
    // bitmap), so primitive slots are correctly skipped by GC.
    size_t saved_range = eco_gc_stack_range_point();
    eco_gc_push_stack_range(&closure_bits, 1, 1);
    uint64_t bitmap = closure->unboxed;
    if (max_values > 0) {
        uint64_t mask = pointerMaskFromKindBitmap(bitmap, max_values);
        if (mask != 0) {
            eco_gc_push_stack_range(
                reinterpret_cast<uint64_t*>(combined_args), max_values, mask);
        }
    }
    // Also root the caller's new_args buffer's HPointer slots: when the
    // layout declares a primitive but the wrapper expects a boxed value,
    // spliceArgsForSaturatedCall allocates inside its Primitive→Boxed
    // branch, and the GC could otherwise move HPointer values held in
    // `new_args[i+1..]` between iterations of the splice loop.
    if (num_newargs > 0 && layout) {
        uint64_t hptrMask = 0;
        for (uint32_t i = 0; i < num_newargs && i < 64; ++i) {
            if (layout->kinds[i] == 0) hptrMask |= (uint64_t{1} << i);
        }
        if (hptrMask != 0) {
            eco_gc_push_stack_range(new_args, num_newargs, hptrMask);
        }
    }

    uint32_t out_max_values = 0;
    uint64_t out_bitmap = 0;
    closure = spliceArgsForSaturatedCall(closure_bits, new_args, num_newargs,
                                         layout, combined_args,
                                         out_max_values, out_bitmap);

    void* result = closure->evaluator(combined_args);

    eco_gc_restore_stack_range_point(saved_range);
    return HPtr::fromBits(reinterpret_cast<uint64_t>(result));
}

namespace {

// Saturated dispatch for `eco_apply_closure_eval`. Builds the combined
// captures+newargs buffer and invokes `closure->evaluator` with the C-ABI
// signature matched to `K`. Stores the result into `result_slot`,
// converting between the evaluator's actual return ABI (`K`) and the
// caller's `desired_kind` as needed (boxing or extracting primitives).
//
// `closure_bits` must be GC-rooted by the caller across this call.
// `typed_args` holds newargs in the format described by `args_layout`.
void invokeSaturatedTyped(uint64_t closure_bits,
                          int64_t* typed_args,
                          uint32_t num_args,
                          const EvalParamLayout* args_layout,
                          uint8_t K,
                          uint8_t desired_kind,
                          void* result_slot) {
    Closure* closure = static_cast<Closure*>(hpointerToPtr(closure_bits));
    assert(closure && "invokeSaturatedTyped: null closure");
    uint32_t max_values = closure->max_values;

    // Splice captures + newargs into combined_args. Re-uses the shared
    // helper used by the boxed-result path.
    void* stack_args[16];
    void** combined_args = (max_values <= 16) ? stack_args :
                           static_cast<void**>(alloca(max_values * sizeof(void*)));
    memset(combined_args, 0, max_values * sizeof(void*));

    // Root the combined buffer's boxed slots. closure_bits is already
    // rooted by the eval caller.
    size_t saved_range = eco_gc_stack_range_point();
    uint64_t bitmap = closure->unboxed;
    if (max_values > 0) {
        uint64_t mask = pointerMaskFromKindBitmap(bitmap, max_values);
        if (mask != 0) {
            eco_gc_push_stack_range(
                reinterpret_cast<uint64_t*>(combined_args), max_values, mask);
        }
    }

    uint32_t out_max_values = 0;
    uint64_t out_bitmap = 0;
    closure = spliceArgsForSaturatedCall(closure_bits,
                                         reinterpret_cast<uint64_t*>(typed_args),
                                         num_args,
                                         args_layout, combined_args,
                                         out_max_values, out_bitmap);

    // Cast the evaluator function pointer to its real C ABI (per K) and
    // invoke. The wrapper was generated with this exact return ABI by
    // `getOrCreateWrapper(.., resultKind=K)` in the JIT pass.
    void* eval = reinterpret_cast<void*>(closure->evaluator);
    switch (K) {
        case 0: {  // PK_Boxed (HPtr)
            using FnT = void* (*)(void**);
            void* r = reinterpret_cast<FnT>(eval)(combined_args);
            HPtr boxed = HPtr::fromBits(reinterpret_cast<uint64_t>(r));
            if (desired_kind == 0) {
                *static_cast<HPtr*>(result_slot) = boxed;
            } else {
                deliverPrimitiveFromBoxed(boxed, desired_kind, result_slot);
            }
            break;
        }
        case 1: {  // PK_Int (i64)
            using FnT = int64_t (*)(void**);
            int64_t r = reinterpret_cast<FnT>(eval)(combined_args);
            if (desired_kind == 1) {
                *static_cast<int64_t*>(result_slot) = r;
            } else if (desired_kind == 0) {
                // Caller wants a boxed result: allocate ElmInt.
                *static_cast<HPtr*>(result_slot) = eco_alloc_int(r);
            } else {
                assert(false && "PK_Int evaluator with non-Int/Boxed desired_kind");
                __builtin_unreachable();
            }
            break;
        }
        case 2: {  // PK_Float (f64)
            using FnT = double (*)(void**);
            double r = reinterpret_cast<FnT>(eval)(combined_args);
            if (desired_kind == 2) {
                *static_cast<double*>(result_slot) = r;
            } else if (desired_kind == 0) {
                *static_cast<HPtr*>(result_slot) = eco_alloc_float(r);
            } else {
                assert(false && "PK_Float evaluator with non-Float/Boxed desired_kind");
                __builtin_unreachable();
            }
            break;
        }
        case 3: {  // PK_Char (i16)
            using FnT = uint16_t (*)(void**);
            uint16_t r = reinterpret_cast<FnT>(eval)(combined_args);
            if (desired_kind == 3) {
                *static_cast<uint16_t*>(result_slot) = r;
            } else if (desired_kind == 0) {
                *static_cast<HPtr*>(result_slot) = eco_alloc_char(static_cast<uint32_t>(r));
            } else {
                assert(false && "PK_Char evaluator with non-Char/Boxed desired_kind");
                __builtin_unreachable();
            }
            break;
        }
        default:
            assert(false && "invokeSaturatedTyped: unreachable result_kind K");
            __builtin_unreachable();
    }

    eco_gc_restore_stack_range_point(saved_range);
}

} // anonymous namespace

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

extern "C" [[noreturn]] void eco_crash(HPtr message_val) {
    // message_val must be an HPointer to a heap-allocated string (any form).
    void* message = hpointerToPtr(message_val.toBits());

    if (message && alloc::isString(message)) {
        // Read via charAt so this works for both flat leaves and slices.
        size_t len = static_cast<Header*>(message)->size;
        fprintf(stderr, "Elm runtime error: ");
        for (size_t i = 0; i < len; i++) {
            u16 cu = Elm::StringOps::charAt(message, static_cast<i64>(i));
            char c = (cu < 128) ? static_cast<char>(cu) : '?';
            fputc(c, stderr);
        }
        fputc('\n', stderr);
    }

    // Use exit(1) instead of abort() to avoid triggering LLVM's signal handlers
    // which would print a misleading "PLEASE submit a bug report" message.
    std::exit(1);
}

// Forward declaration for recursive printing
static void print_value(uint64_t val, int depth);

// Print string content (without quotes) - for Debug.log labels.
// Accepts any string form (Tag_String / Tag_StringSlice) via tag-aware
// Elm::StringOps::charAt.
static void print_string_content(void* str) {
    if (!str) return;
    size_t len = static_cast<Header*>(str)->size;
    for (size_t i = 0; i < len; i++) {
        u16 c = Elm::StringOps::charAt(str, static_cast<i64>(i));
        if (c < 128) {
            output_char(static_cast<char>(c));
        } else {
            output_format("\\u%04X", c);
        }
    }
}

// Print a string value (with quotes). See print_string_content for tag handling.
static void print_string(void* str) {
    output_char('"');
    if (str) {
        size_t len = static_cast<Header*>(str)->size;
        for (size_t i = 0; i < len; i++) {
            u16 c = Elm::StringOps::charAt(str, static_cast<i64>(i));
            if (c == '"') {
                output_text("\\\"");
            } else if (c == '\\') {
                output_text("\\\\");
            } else if (c == '\n') {
                output_text("\\n");
            } else if (c == '\r') {
                output_text("\\r");
            } else if (c == '\t') {
                output_text("\\t");
            } else if (c < 32 || c >= 127) {
                output_format("\\u%04X", c);
            } else {
                output_char(static_cast<char>(c));
            }
        }
    }
    output_char('"');
}

// Print a character value in Elm syntax
static void print_char(u16 c) {
    output_char('\'');
    if (c == '\'') {
        output_text("\\'");
    } else if (c == '\\') {
        output_text("\\\\");
    } else if (c == '\n') {
        output_text("\\n");
    } else if (c == '\r') {
        output_text("\\r");
    } else if (c == '\t') {
        output_text("\\t");
    } else if (c < 32 || c >= 127) {
        output_format("\\u%04X", c);
    } else {
        output_char(static_cast<char>(c));
    }
    output_char('\'');
}

// Print an unboxed primitive value from a container field.
// ONLY called when: (1) unboxed bitmap indicates field is unboxed, AND
//                   (2) type graph says field type is primitive.
// NEVER called from eco_dbg_print_typed directly - that always receives
// boxed HPointer values.
static void printPrimitive(uint64_t bits, Elm::EcoPrimKind kind) {
    switch (kind) {
    case Elm::EcoPrimKind::Int:
        output_format("%lld", (long long)static_cast<int64_t>(bits));
        break;
    case Elm::EcoPrimKind::Float: {
        double d;
        std::memcpy(&d, &bits, sizeof(d));
        print_float(d);
        break;
    }
    case Elm::EcoPrimKind::Char:
        print_char(static_cast<u16>(bits));
        break;
    case Elm::EcoPrimKind::Bool:
        output_text(bits ? "True" : "False");
        break;
    case Elm::EcoPrimKind::String:
        // String is NEVER unboxed - if we get here, it's a bug.
        // Fall through to print as pointer (will likely show <null> or garbage).
        assert(false && "String cannot be unboxed");
        output_text("<unboxed-string-bug>");
        break;
    }
}

// MLIR ConstantKind enum (1-based, from Ops.td)
// These values are stored directly in bits 40-43 of the pointer
enum MlirConstantKind {
    MlirConst_Unit = 1,
    MlirConst_EmptyRec = 2,
    MlirConst_True = 3,
    MlirConst_False = 4,
    MlirConst_Nil = 5,
    MlirConst_Nothing = 6,
    MlirConst_EmptyString = 7,
};

// Check if a value is an embedded constant and print it
// Returns true if it was a constant, false otherwise
static bool print_if_constant(uint64_t val) {
    // For JIT execution, pointers are full 64-bit addresses.
    // Constants are small values with only bits 40-43 set (values 1-7 shifted left by 40).
    // A real pointer will have bits above 43 set (e.g., 0x7f...).
    // So we check: if val > (7 << 40), it's definitely a pointer, not a constant.
    // And if val > 0 and val <= (7 << 40), it's a constant.

    // Constants are in range [1<<40, 7<<40] = [0x10000000000, 0x70000000000]
    // Real heap pointers will be above 0x100000000000 (bit 44 set for typical 48-bit addresses)

    // Simple check: constants have zero in the low 40 bits AND a small value in upper bits
    uint64_t ptr_part = val & 0xFFFFFFFFFF;  // Lower 40 bits
    uint64_t const_part = val >> 40;          // Upper 24 bits

    // If there's a pointer component, it's not a pure constant
    if (ptr_part != 0) {
        return false;
    }

    // Pure constant: ptr_part is 0, const_part is 1-7
    if (const_part >= 1 && const_part <= 7) {
        switch (const_part) {
            case MlirConst_Unit:
                output_text("()");
                return true;
            case MlirConst_EmptyRec:
                output_text("{}");
                return true;
            case MlirConst_True:
                output_text("True");
                return true;
            case MlirConst_False:
                output_text("False");
                return true;
            case MlirConst_Nil:
                output_text("[]");
                return true;
            case MlirConst_Nothing:
                output_text("Nothing");
                return true;
            case MlirConst_EmptyString:
                output_text("\"\"");
                return true;
        }
    }

    return false;  // Regular pointer
}

// Check if a value is Nil constant
static bool is_nil(uint64_t val) {
    // Nil is encoded as MlirConst_Nil << 40 with zero in lower bits
    return (val & 0xFFFFFFFFFF) == 0 && (val >> 40) == MlirConst_Nil;
}

// Check if a Custom object is a list cons cell.
// MLIR generates: List Nil with tag=0, size=0; List Cons with tag=1, size=2.
// The tail (field 1) must be boxed (not unboxed) since it points to next cell or Nil.
static inline bool is_list_cons(const Custom* custom) {
    // Field 1 (the tail) must be boxed: kind 0 at bits [2,3] → mask 0xC is zero.
    return custom->ctor == 1 &&
           custom->header.size == 2 &&
           fieldKind(custom->unboxed, 1) == 0;
}

// Print a list in Elm syntax: [1, 2, 3]
static void print_list(uint64_t val, int depth) {
    output_char('[');

    bool first = true;
    uint64_t current = val;
    int count = 0;
    const int MAX_LIST_ITEMS = 100;  // Prevent infinite loops

    while (count < MAX_LIST_ITEMS) {
        // Check for Nil (end of list)
        if (is_nil(current)) {
            break;
        }

        // Check for other embedded constants (invalid in list tail)
        uint64_t ptr_part = current & 0xFFFFFFFFFF;
        uint64_t const_part = current >> 40;
        if (ptr_part == 0 && const_part >= 1 && const_part <= 7) {
            if (!first) output_text(", ");
            output_text("<invalid_list_tail>");
            break;
        }

        // Convert HPointer to raw pointer
        void* ptr = hpointerToPtr(current);
        if (!ptr) {
            if (!first) output_text(", ");
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        // eco.construct uses Tag_Custom with ctor=1 for list cons cells
        // MLIR: List Nil has tag=0, size=0; List Cons has tag=1, size=2
        // Native Cons type uses Tag_Cons
        if (header->tag == Tag_Custom) {
            Custom* custom = static_cast<Custom*>(ptr);
            // Use is_list_cons helper to validate cons cell
            if (!is_list_cons(custom)) {
                if (!first) output_text(", ");
                output_text("<non_cons_custom>");
                break;
            }

            if (!first) {
                output_text(", ");
            }
            first = false;

            // Print the head element (field 0)
            switch (fieldKind(custom->unboxed, 0)) {
                case 1: output_format("%lld", (long long)custom->values[0].i); break;
                case 2: output_format("%g", (double)custom->values[0].f); break;
                case 3: output_format("'%c'", (int)custom->values[0].c); break;
                default: {
                    uint64_t head_val = static_cast<uint64_t>(custom->values[0].i);
                    print_value(head_val, depth + 1);
                    break;
                }
            }

            // Move to tail (field 1) - read as full 64-bit value
            current = static_cast<uint64_t>(custom->values[1].i);
        } else if (header->tag == Tag_Cons) {
            Cons* cons = static_cast<Cons*>(ptr);

            if (!first) {
                output_text(", ");
            }
            first = false;

            // Print the head element
            switch (tupleFieldKind(header->unboxed, 0)) {
                case 1: output_format("%lld", (long long)cons->head.i); break;
                case 2: output_format("%g", (double)cons->head.f); break;
                case 3: output_format("'%c'", (int)cons->head.c); break;
                default: {
                    uint64_t head_val = cons->head.p.ptr |
                                       (static_cast<uint64_t>(cons->head.p.constant) << 40);
                    print_value(head_val, depth + 1);
                    break;
                }
            }

            // Move to tail
            current = cons->tail.ptr | (static_cast<uint64_t>(cons->tail.constant) << 40);
        } else {
            if (!first) output_text(", ");
            output_format("<non_cons_tag_%d>", header->tag);
            break;
        }

        count++;
    }

    if (count >= MAX_LIST_ITEMS) {
        output_text(", ...");
    }

    output_char(']');
}

// Print a single slot whose kind is encoded in `kind` (0=boxed, 1=Int, 2=Float, 3=Char).
static void print_unboxable_slot(const Unboxable& v, uint32_t kind, int depth) {
    switch (kind) {
        case 1: output_format("%lld", (long long)v.i); break;
        case 2: output_format("%g", (double)v.f); break;
        case 3: output_format("'%c'", (int)v.c); break;
        default: print_value(static_cast<uint64_t>(v.i), depth + 1); break;
    }
}

// Print a tuple
static void print_tuple2(Tuple2* tuple, int depth) {
    output_char('(');
    print_unboxable_slot(tuple->a, tupleFieldKind(tuple->header.unboxed, 0), depth);
    output_text(", ");
    print_unboxable_slot(tuple->b, tupleFieldKind(tuple->header.unboxed, 1), depth);
    output_char(')');
}

static void print_tuple3(Tuple3* tuple, int depth) {
    output_char('(');
    print_unboxable_slot(tuple->a, tupleFieldKind(tuple->header.unboxed, 0), depth);
    output_text(", ");
    print_unboxable_slot(tuple->b, tupleFieldKind(tuple->header.unboxed, 1), depth);
    output_text(", ");
    print_unboxable_slot(tuple->c, tupleFieldKind(tuple->header.unboxed, 2), depth);
    output_char(')');
}

// Print a custom type constructor
static void print_custom(Custom* custom, int depth) {
    uint32_t ctor = custom->ctor;
    uint32_t size = custom->header.size;

    // Print generic constructor name (1-indexed for readability)
    output_format("Ctor%u", ctor);

    // Print fields if any
    if (size > 0) {
        output_char(' ');
        for (uint32_t i = 0; i < size; i++) {
            if (i > 0) output_char(' ');

            uint32_t k = static_cast<uint32_t>(fieldKind(custom->unboxed, i));
            if (k != 0) {
                print_unboxable_slot(custom->values[i], k, depth);
            } else {
                // Read as full 64-bit value for JIT mode
                uint64_t val = static_cast<uint64_t>(custom->values[i].i);

                if (val == 0) {
                    // Null pointer
                    output_text("<null>");
                } else if (!print_if_constant(val)) {
                    // Heap pointer - resolve HPointer
                    void* ptr = hpointerToPtr(val);
                    bool needs_parens = false;
                    if (ptr) {
                        Header* h = static_cast<Header*>(ptr);
                        needs_parens = (h->tag == Tag_Custom && static_cast<Custom*>(ptr)->header.size > 0);
                    }
                    if (needs_parens) output_char('(');
                    print_value(val, depth + 1);
                    if (needs_parens) output_char(')');
                }
            }
        }
    }
}

// Print a record
static void print_record(Record* record, int depth) {
    uint32_t size = record->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        // We don't have field names, so use numeric indices
        output_format("f%u = ", i);

        uint32_t k = static_cast<uint32_t>(fieldKind(record->unboxed, i));
        if (k != 0) {
            print_unboxable_slot(record->values[i], k, depth);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(record->values[i].i), depth + 1);
        }
    }
    output_text(" }");
}

// Print a dynamic record
static void print_dynrecord(DynRecord* dynrec, int depth) {
    uint32_t size = dynrec->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        // We don't have field names, so use numeric indices
        output_format("f%u = ", i);

        // DynRecord values are HPointer, not Unboxable
        // For JIT mode, we need to read the full pointer differently
        // Since HPointer is a bitfield struct, we can't easily store 64-bit pointers
        // Fall back to the 44-bit encoding for now
        uint64_t val = dynrec->values[i].ptr |
                      (static_cast<uint64_t>(dynrec->values[i].constant) << 40);
        print_value(val, depth + 1);
    }
    output_text(" }");
}

// Print an array
static void print_array(ElmArray* array, int depth) {
    output_text("Array.fromList [");
    uint32_t kind = array->header.unboxed & 0x3;
    for (uint32_t i = 0; i < array->length; i++) {
        if (i > 0) output_text(", ");

        if (kind != 0) {
            print_unboxable_slot(array->elements[i], kind, depth);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(array->elements[i].i), depth + 1);
        }
    }
    output_char(']');
}

// Main value printer
static void print_value(uint64_t val, int depth) {
    // Prevent infinite recursion
    if (depth > 50) {
        output_text("...");
        return;
    }

    // Check for embedded constants first
    if (print_if_constant(val)) {
        return;
    }

    // Convert HPointer to raw pointer via allocator
    void* ptr = hpointerToPtr(val);
    if (!ptr) {
        output_text("<null>");
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    switch (header->tag) {
        case Tag_Int: {
            ElmInt* intval = static_cast<ElmInt*>(ptr);
            output_format("%lld", (long long)intval->value);
            break;
        }

        case Tag_Float: {
            ElmFloat* floatval = static_cast<ElmFloat*>(ptr);
            print_float(floatval->value);
            break;
        }

        case Tag_Char: {
            ElmChar* charval = static_cast<ElmChar*>(ptr);
            print_char(charval->value);
            break;
        }

        case Tag_String:
        case Tag_StringSlice:
        case Tag_StringRope:
        case Tag_LargeStringHeader: {
            print_string(ptr);
            break;
        }

        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(ptr);
            print_tuple2(tuple, depth);
            break;
        }

        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(ptr);
            print_tuple3(tuple, depth);
            break;
        }

        case Tag_Cons: {
            // Print as a list
            print_list(val, depth);
            break;
        }

        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(ptr);
            // Check if this is a list cons cell using the is_list_cons helper.
            // MLIR: List Cons has ctor=1, size=2 (NOT ctor=0 which is used for tuples).
            if (is_list_cons(custom)) {
                print_list(val, depth);
            } else {
                print_custom(custom, depth);
            }
            break;
        }

        case Tag_Record: {
            Record* record = static_cast<Record*>(ptr);
            print_record(record, depth);
            break;
        }

        case Tag_DynRecord: {
            DynRecord* dynrec = static_cast<DynRecord*>(ptr);
            print_dynrecord(dynrec, depth);
            break;
        }

        case Tag_Closure: {
            output_text("<fn>");
            break;
        }

        case Tag_Process: {
            Process* proc = static_cast<Process*>(ptr);
            output_format("<process:%llu>", (unsigned long long)proc->id);
            break;
        }

        case Tag_Task: {
            output_text("<task>");
            break;
        }

        case Tag_FieldGroup: {
            output_text("<fieldgroup>");
            break;
        }

        case Tag_ByteBuffer:
        case Tag_LargeByteHeader: {
            // Both forms carry the logical byte count in header.size; the
            // split-header form's body lives elsewhere and we don't need it
            // for the size-only debug rendering.
            output_format("<bytes:%u>", header->size);
            break;
        }

        case Tag_Array: {
            ElmArray* array = static_cast<ElmArray*>(ptr);
            print_array(array, depth);
            break;
        }

        case Tag_Forward: {
            output_text("<forward>");
            break;
        }

        case Tag_Free: {
            output_text("<free>");
            break;
        }

        default:
            output_format("<unknown_tag_%u>", header->tag);
            break;
    }
}

extern "C" void eco_dbg_print(uint64_t* args, uint32_t num_args) {
    output_text("[eco.dbg] ");
    for (uint32_t i = 0; i < num_args; i++) {
        if (i > 0) output_char(' ');
        print_value(args[i], 0);
    }
    output_text("\n");
}

// Debug print for unboxed integer (i64)
extern "C" void eco_dbg_print_int(int64_t value) {
    output_format("[eco.dbg] %lld\n", (long long)value);
}

// Debug print for unboxed float (f64)
extern "C" void eco_dbg_print_float(double value) {
    output_text("[eco.dbg] ");
    print_float(value);
    output_text("\n");
}

// Debug print for unboxed char (i32 Unicode code point)
extern "C" void eco_dbg_print_char(int32_t value) {
    output_text("[eco.dbg] ");
    print_char(static_cast<u16>(value));
    output_text("\n");
}

// Global type graph pointer - set by eco_register_type_graph from JITed code
static const Elm::EcoTypeGraph* g_type_graph = nullptr;

// Register the type graph from JITed code
extern "C" void eco_register_type_graph(const void* graph) {
    g_type_graph = static_cast<const Elm::EcoTypeGraph*>(graph);
}

// Forward declaration for recursive printing
static void print_typed_value(uint64_t value, uint32_t type_id, int depth);

// Helper to print a label (string value without quotes).
// Accepts any string form (leaf or slice) via Elm::alloc::isString.
static void print_label(uint64_t value) {
    void* ptr = hpointerToPtr(value);
    if (ptr) {
        if (alloc::isString(ptr)) {
            print_string_content(ptr);
        } else {
            print_value(value, 0);
        }
    } else {
        output_text("<null>");
    }
}

// Helper: check if a type_id refers to a String primitive in the type graph.
static bool isStringType(uint32_t type_id) {
    if (!g_type_graph || !g_type_graph->types || type_id >= g_type_graph->type_count) {
        return false;
    }
    const Elm::EcoTypeInfo* info = &g_type_graph->types[type_id];
    return info->kind == Elm::EcoTypeKind::Primitive &&
           info->data.primitive.prim_kind == Elm::EcoPrimKind::String;
}

// Debug print with full type information using the global type graph.
// When called with 2 args where type_ids[0] is a String type, this is a Debug.log call
// and we format as "label: value\n"
extern "C" void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args) {
    // Special case for Debug.log: 2 args, first is a string label
    if (num_args == 2 && isStringType(type_ids[0])) {
        print_label(values[0]);
        output_text(": ");
        print_typed_value(values[1], type_ids[1], 0);
        output_text("\n");
        return;
    }

    // General case: print each value on its own line
    for (uint32_t i = 0; i < num_args; ++i) {
        print_typed_value(values[i], type_ids[i], 0);
        output_text("\n");
    }
}

// Print a value using type information from the type graph
static void print_typed_value(uint64_t value, uint32_t type_id, int depth) {
    // Prevent infinite recursion
    if (depth > 50) {
        output_text("...");
        return;
    }

    // Assert type graph is available and type_id is valid
    assert(g_type_graph && "Type graph not initialized");
    assert(g_type_graph->types && "Type graph has no types array");
    assert(type_id < g_type_graph->type_count && "Invalid type_id");
    if (!g_type_graph || !g_type_graph->types || type_id >= g_type_graph->type_count) {
        // Safety fallback in release builds
        print_value(value, depth);
        return;
    }

    const Elm::EcoTypeInfo* typeInfo = &g_type_graph->types[type_id];

    switch (typeInfo->kind) {
    case Elm::EcoTypeKind::Primitive:
        // INVARIANT: At the dbg boundary, primitives are ALWAYS boxed (!eco.value).
        // The value is an HPointer to a heap object (ElmInt, ElmFloat, ElmChar,
        // ElmString) or an embedded constant (True, False, EmptyString).
        // Just use the generic value printer which dispatches on heap tag.
        print_value(value, depth);
        break;

    case Elm::EcoTypeKind::List: {
        // Get element type for typed recursive printing
        uint32_t elem_type_id = typeInfo->data.list.elem_type_id;

        // Assert element type is in valid range
        assert(elem_type_id < g_type_graph->type_count && "Invalid elem_type_id in List type graph");

        output_char('[');
        bool first = true;
        uint64_t current = value;
        int count = 0;
        const int MAX_LIST_ITEMS = 100;

        while (count < MAX_LIST_ITEMS) {
            // Check for Nil (end of list)
            if (is_nil(current)) {
                break;
            }

            // Check for other embedded constants
            uint64_t ptr_part = current & 0xFFFFFFFFFF;
            uint64_t const_part = current >> 40;
            if (ptr_part == 0 && const_part >= 1 && const_part <= 7) {
                break;
            }

            void* ptr = hpointerToPtr(current);
            if (!ptr) break;

            Header* header = static_cast<Header*>(ptr);

            // Handle both Tag_Cons and Tag_Custom (ctor=1) for list cons cells
            uint64_t head_val;
            uint64_t tail_val;
            bool head_unboxed = false;

            if (header->tag == Tag_Cons) {
                Cons* cons = static_cast<Cons*>(ptr);
                head_val = static_cast<uint64_t>(cons->head.i);
                head_unboxed = (tupleFieldKind(cons->header.unboxed, 0) != 0);
                tail_val = cons->tail.ptr | (static_cast<uint64_t>(cons->tail.constant) << 40);
            } else if (header->tag == Tag_Custom) {
                Custom* custom = static_cast<Custom*>(ptr);
                if (!is_list_cons(custom)) break;
                head_val = static_cast<uint64_t>(custom->values[0].i);
                head_unboxed = (fieldKind(custom->unboxed, 0) != 0);
                tail_val = static_cast<uint64_t>(custom->values[1].i);
            } else {
                break;
            }

            if (!first) output_text(", ");
            first = false;

            // Print head with type info
            if (head_unboxed) {
                // Value is unboxed - use printPrimitive based on element type
                const Elm::EcoTypeInfo* elemType = &g_type_graph->types[elem_type_id];
                if (elemType->kind == Elm::EcoTypeKind::Primitive) {
                    printPrimitive(head_val, elemType->data.primitive.prim_kind);
                } else if (elemType->kind == Elm::EcoTypeKind::Polymorphic &&
                           elemType->data.polymorphic.constraint == Elm::EcoConstraintKind::Number) {
                    // Number constraint with unboxed value - assume Int
                    printPrimitive(head_val, Elm::EcoPrimKind::Int);
                } else {
                    // Unboxed but type graph says non-primitive - type mismatch
                    assert(false && "List head is unboxed but element type is not primitive");
                    output_format("<unboxed-non-prim:0x%llx>", (unsigned long long)head_val);
                }
            } else {
                // Value is boxed (HPointer) - recurse with type info
                print_typed_value(head_val, elem_type_id, depth + 1);
            }

            current = tail_val;
            count++;
        }

        if (count >= MAX_LIST_ITEMS) {
            output_text(", ...");
        }
        output_char(']');
        break;
    }

    case Elm::EcoTypeKind::Tuple: {
        uint16_t arity = typeInfo->data.tuple.arity;
        uint32_t first_field = typeInfo->data.tuple.first_field;

        // Assert fields array is valid
        assert(g_type_graph->fields && "Type graph has no fields array");
        assert(first_field + arity <= g_type_graph->field_count && "Tuple field indices out of bounds");

        // Assert field types are in valid range
        for (uint16_t i = 0; i < arity; i++) {
            assert(g_type_graph->fields[first_field + i].type_id < g_type_graph->type_count &&
                   "Invalid field type_id in Tuple type graph");
        }

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        if (header->tag == Tag_Tuple2 && arity == 2) {
            Tuple2* tuple = static_cast<Tuple2*>(ptr);
            uint32_t type_a = g_type_graph->fields[first_field].type_id;
            uint32_t type_b = g_type_graph->fields[first_field + 1].type_id;
            uint8_t unboxed = tuple->header.unboxed;

            output_char('(');
            // Field a
            if (tupleFieldKind(unboxed, 0) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_a];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple field a is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->a.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->a.i), type_a, depth + 1);
            }
            output_text(", ");
            // Field b
            if (tupleFieldKind(unboxed, 1) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_b];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple field b is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->b.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->b.i), type_b, depth + 1);
            }
            output_char(')');
        } else if (header->tag == Tag_Tuple3 && arity == 3) {
            Tuple3* tuple = static_cast<Tuple3*>(ptr);
            uint32_t type_a = g_type_graph->fields[first_field].type_id;
            uint32_t type_b = g_type_graph->fields[first_field + 1].type_id;
            uint32_t type_c = g_type_graph->fields[first_field + 2].type_id;
            uint8_t unboxed = tuple->header.unboxed;

            output_char('(');
            // Field a
            if (tupleFieldKind(unboxed, 0) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_a];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field a is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->a.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->a.i), type_a, depth + 1);
            }
            output_text(", ");
            // Field b
            if (tupleFieldKind(unboxed, 1) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_b];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field b is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->b.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->b.i), type_b, depth + 1);
            }
            output_text(", ");
            // Field c
            if (tupleFieldKind(unboxed, 2) != 0) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_c];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field c is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->c.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->c.i), type_c, depth + 1);
            }
            output_char(')');
        } else {
            // Tag doesn't match expected tuple type
            assert(false && "Tuple tag mismatch - value doesn't match type");
            output_text("<tuple-mismatch>");
        }
        break;
    }

    case Elm::EcoTypeKind::Record: {
        uint32_t first_field = typeInfo->data.record.first_field;
        uint32_t field_count = typeInfo->data.record.field_count;

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);
        if (header->tag != Tag_Record) {
            print_value(value, depth);
            break;
        }

        Record* record = static_cast<Record*>(ptr);
        uint32_t actual_size = record->header.size;
        uint64_t unboxed = record->unboxed;

        output_text("{ ");
        for (uint32_t i = 0; i < actual_size && i < field_count; i++) {
            if (i > 0) output_text(", ");

            // Get field info from type graph
            if (g_type_graph->fields && first_field + i < g_type_graph->field_count) {
                const Elm::EcoFieldInfo* field = &g_type_graph->fields[first_field + i];

                // Print field name if available
                if (g_type_graph->strings && field->name_index < g_type_graph->string_count) {
                    output_text(g_type_graph->strings[field->name_index]);
                } else {
                    output_format("f%u", i);
                }
                output_text(" = ");

                // Print field value - check unboxed bitmap from heap
                uint64_t field_val = static_cast<uint64_t>(record->values[i].i);
                bool is_unboxed = fieldKind(unboxed, i) != 0;

                if (is_unboxed) {
                    const Elm::EcoTypeInfo* ft = &g_type_graph->types[field->type_id];
                    assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                           "Record field is unboxed but type is not primitive");
                    printPrimitive(field_val, ft->data.primitive.prim_kind);
                } else {
                    print_typed_value(field_val, field->type_id, depth + 1);
                }
            } else {
                // Fallback without type info
                output_format("f%u = ", i);
                uint64_t field_val = static_cast<uint64_t>(record->values[i].i);
                print_value(field_val, depth + 1);
            }
        }
        output_text(" }");
        break;
    }

    case Elm::EcoTypeKind::Custom: {
        uint32_t first_ctor = typeInfo->data.custom.first_ctor;
        uint32_t ctor_count = typeInfo->data.custom.ctor_count;

        // Check for embedded constants first
        if (print_if_constant(value)) {
            break;
        }

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);
        assert(header->tag == Tag_Custom && "Expected Custom tag for Custom type");
        if (header->tag != Tag_Custom) {
            output_text("<not-custom>");
            break;
        }

        Custom* custom = static_cast<Custom*>(ptr);
        uint32_t ctor_id = custom->ctor;
        uint32_t size = custom->header.size;

        // Assert constructor info is available
        assert(g_type_graph->ctors && "Type graph has no ctors array");
        assert(ctor_count > 0 && "Custom type has no constructors in type graph - codegen bug");

        // Runtime-recognised types (e.g. Dict) use reserved ctor_id values
        // outside 0..ctor_count-1, so search linearly instead of indexing.
        const Elm::EcoCtorInfo* ctor_info = nullptr;
        for (uint32_t ci = 0; ci < ctor_count; ++ci) {
            if (g_type_graph->ctors[first_ctor + ci].ctor_id == ctor_id) {
                ctor_info = &g_type_graph->ctors[first_ctor + ci];
                break;
            }
        }
        assert(ctor_info != nullptr && "Constructor id not found in type graph");

        // Assert constructor name is available
        assert(g_type_graph->strings && "Type graph has no strings array");
        assert(ctor_info->name_index < g_type_graph->string_count &&
               "Constructor name_index out of bounds");

        // Print constructor name
        output_text(g_type_graph->strings[ctor_info->name_index]);

        // Print fields if any
        if (size > 0) {
            // Assert field info is available
            assert(g_type_graph->fields && "Type graph has no fields array");
            assert(ctor_info->field_count == size && "Field count mismatch");
            assert(ctor_info->first_field + size <= g_type_graph->field_count &&
                   "Field indices out of bounds");

            for (uint32_t i = 0; i < size; i++) {
                output_char(' ');

                uint64_t field_val = static_cast<uint64_t>(custom->values[i].i);
                bool is_unboxed = fieldKind(custom->unboxed, i) != 0;

                // Get field type from ctor info
                uint32_t field_type_id = g_type_graph->fields[ctor_info->first_field + i].type_id;

                // Assert field type is in valid range
                assert(field_type_id < g_type_graph->type_count &&
                       "Invalid field type_id in Custom type graph");

                // Check if nested custom needs parentheses (only for boxed values)
                bool needs_parens = false;
                if (!is_unboxed) {
                    void* field_ptr = hpointerToPtr(field_val);
                    if (field_ptr) {
                        Header* h = static_cast<Header*>(field_ptr);
                        needs_parens = (h->tag == Tag_Custom &&
                                       static_cast<Custom*>(field_ptr)->header.size > 0);
                    }
                }

                if (needs_parens) output_char('(');

                if (is_unboxed) {
                    // Unboxed value - use printPrimitive with type from type graph
                    const Elm::EcoTypeInfo* ft = &g_type_graph->types[field_type_id];
                    assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                           "Custom field is unboxed but type is not primitive");
                    printPrimitive(field_val, ft->data.primitive.prim_kind);
                } else {
                    print_typed_value(field_val, field_type_id, depth + 1);
                }

                if (needs_parens) output_char(')');
            }
        }
        break;
    }

    case Elm::EcoTypeKind::Function:
        // Functions are printed as closures
        output_text("<function>");
        break;

    case Elm::EcoTypeKind::Polymorphic:
        // Polymorphic type variable - value is always boxed (!eco.value).
        // Just dispatch based on heap tag via print_value.
        // For Number constraint, this will print Int or Float correctly.
        // For EcoValue constraint, it handles any heap type.
        print_value(value, depth);
        break;
    }
}

// Output text to the current output stream (for kernel functions)
extern "C" void eco_output_text(const char* text) {
    output_text(text);
}

// Print an Elm value to the current output stream
extern "C" void eco_print_value(HPtr value) {
    print_value(value.toBits(), 0);
}

// Print an Elm value, unwrapping the Ctor0 box wrapper used by Guida compiler.
// This is used by Debug.log to show clean Elm values.
extern "C" void eco_print_elm_value(HPtr value) {
    uint64_t value_bits = value.toBits();
    // Check for embedded constants first
    if (print_if_constant(value_bits)) {
        return;
    }

    // Convert HPointer to raw pointer via allocator
    void* ptr = hpointerToPtr(value_bits);
    if (!ptr) {
        output_text("<null>");
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    // Check if this is a Ctor0 size=1 wrapper (Guida's box for polymorphic values)
    if (header->tag == Tag_Custom) {
        Custom* custom = static_cast<Custom*>(ptr);
        if (custom->ctor == 0 && custom->header.size == 1) {
            // Unwrap: print the inner value directly
            uint32_t k = static_cast<uint32_t>(fieldKind(custom->unboxed, 0));
            if (k != 0) {
                print_unboxable_slot(custom->values[0], k, 0);
            } else {
                uint64_t inner = static_cast<uint64_t>(custom->values[0].i);
                // Safety check for small integers
                if (inner < 0x10000) {
                    output_format("%lld", (long long)inner);
                } else if (!print_if_constant(inner)) {
                    // Recursively print the inner value (also unwrapping if needed)
                    eco_print_elm_value(HPtr::fromBits(inner));
                }
            }
            return;
        }
    }

    // Not a wrapper, print normally
    print_value(value_bits, 0);
}

// Convert an Elm value to its string representation
extern "C" HPtr eco_value_to_string(HPtr value) {
    // Temporarily capture output to a string
    std::ostringstream capture;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &capture;

    // Print the value
    print_value(value.toBits(), 0);

    // Restore previous stream
    tl_output_stream = prev;

    // Allocate and return an ElmString from the captured output
    std::string result = capture.str();
    HPointer strPtr = alloc::allocStringFromUTF8(result);

    return HPtr::fromHPointer(strPtr);
}

extern "C" HPtr eco_value_to_string_typed(HPtr value, int64_t type_id) {
    uint64_t value_bits = value.toBits();
    // Temporarily capture output to a string
    std::ostringstream capture;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &capture;

    // Print the value using type information for constructor names
    if (type_id >= 0 && g_type_graph && g_type_graph->types &&
        static_cast<uint32_t>(type_id) < g_type_graph->type_count) {
        print_typed_value(value_bits, static_cast<uint32_t>(type_id), 0);
    } else {
        print_value(value_bits, 0);
    }

    // Restore previous stream
    tl_output_stream = prev;

    // Allocate and return an ElmString from the captured output
    std::string result = capture.str();
    HPointer strPtr = alloc::allocStringFromUTF8(result);

    return HPtr::fromHPointer(strPtr);
}

//===----------------------------------------------------------------------===//
// GC Interface
//===----------------------------------------------------------------------===//

extern "C" void eco_safepoint() {
    // No-op for now
    // In the future, this will check if GC needs to run
}

extern "C" void __eco_safepoint_poll() {
    auto& alloc = Elm::Allocator::instance();
    if (!alloc.shouldCollectAtSafepoint())
        return;
    alloc.collectAtSafepoint();
}

extern "C" void eco_minor_gc() {
    Allocator::instance().minorGC();
}

extern "C" void eco_major_gc() {
    Allocator::instance().majorGC();
}

extern "C" void eco_gc_add_root(uint64_t* root_ptr) {
    Allocator::instance().getRootSet().addJitRoot(root_ptr);
}

extern "C" void eco_gc_remove_root(uint64_t* root_ptr) {
    Allocator::instance().getRootSet().removeJitRoot(root_ptr);
}

extern "C" uint64_t eco_gc_jit_root_count() {
    return Allocator::instance().getRootSet().getJitRoots().size();
}

extern "C" void eco_gc_add_value_root(uint64_t* value_ptr) {
    Allocator::instance().getRootSet().addRoot(reinterpret_cast<HPointer*>(value_ptr));
}

extern "C" void eco_gc_remove_value_root(uint64_t* value_ptr) {
    Allocator::instance().getRootSet().removeRoot(reinterpret_cast<HPointer*>(value_ptr));
}

extern "C" size_t eco_gc_stack_range_point() {
    return Allocator::instance().getRootSet().stackRangePoint();
}

extern "C" void eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask) {
    if (!base || count == 0) return;
    assert(count <= 64 && "stack root range exceeds 64-slot limit");
    Allocator::instance().getRootSet().pushStackRootRange(
        reinterpret_cast<HPointer*>(base), count, hpointer_mask);
}

extern "C" void eco_gc_restore_stack_range_point(size_t point) {
    Allocator::instance().getRootSet().restoreStackRangePoint(point);
}

//===----------------------------------------------------------------------===//
// Tag Extraction
//===----------------------------------------------------------------------===//

extern "C" uint32_t eco_get_header_tag(HPtr obj_hptr) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return 0;

    Header* header = static_cast<Header*>(obj);
    return header->tag;
}

extern "C" uint32_t eco_get_custom_ctor(HPtr obj_hptr) {
    void* obj = hpointerToPtr(obj_hptr.toBits());
    if (!obj) return 0;

    Custom* custom = static_cast<Custom*>(obj);
    return custom->ctor;
}

/// Get the constructor tag for a value, handling both heap objects and embedded constants.
/// For heap Custom objects: returns the ctor field (16-bit constructor tag).
/// For embedded constants: returns the appropriate ctor tag:
///   - Nothing (kind=6) -> tag=1 (second constructor of Maybe)
///   - Nil (kind=5) -> tag=0 (first constructor of List)
///   - Other embedded constants -> tag=0
extern "C" uint32_t eco_get_tag(HPtr val) {
    // Null HPointer (bits == 0) is neither an embedded constant nor a valid
    // heap allocation — offset 0 in the heap is never the address of a real
    // object. Seeing this indicates an upstream bug (uninitialized field or
    // stale reference after GC). Abort loudly rather than silently reading
    // heap_base and returning a bogus tag, which can mask bugs as infinite
    // recursion (see stage-7 Dict_foldl crash, 2026-04-24).
    assert(val.bits != 0 && "eco_get_tag: null HPointer");
    HPointer hp = val.toHPointer();
    // Check if this is an embedded constant (constant field != 0).
    if (hp.constant != 0) {
        if (hp.constant == 6) {  // Nothing
            return 1;
        }
        return 0;
    }

    // Heap object: resolve pointer and check header tag.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;

    // Get the header to check the object type.
    Header* header = static_cast<Header*>(obj);

    // Handle based on heap object type.
    switch (header->tag) {
        case Tag_Cons:
            return 1;
        case Tag_Custom:
            return static_cast<Custom*>(obj)->ctor;
        default:
            return 0;
    }
}

//===----------------------------------------------------------------------===//
// List Element Access
//===----------------------------------------------------------------------===//

/// Gets the head of a Cons cell as an unboxed i64.
/// Handles both boxed and unboxed heads.
extern "C" int64_t eco_cons_head_i64(HPtr cons) {
    HPointer hp = cons.toHPointer();

    // Resolve the Cons cell pointer.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;  // Should not happen for valid Cons

    Cons* consCell = static_cast<Cons*>(obj);

    // Head is unboxed iff slot-0 kind is non-zero (2-bit encoding).
    if (tupleFieldKind(consCell->header.unboxed, 0) != 0) {
        // Head is unboxed: return the i64 value directly.
        return consCell->head.i;
    } else {
        // Head is boxed: resolve the HPointer and load from ElmInt.
        HPointer headHp = consCell->head.p;
        void* headObj = Allocator::instance().resolve(headHp);
        if (!headObj) return 0;  // Should not happen

        // ElmInt has layout: [Header:8][value:8]
        // value is at offset 8.
        ElmInt* elmInt = static_cast<ElmInt*>(headObj);
        return elmInt->value;
    }
}

/// Gets the head of a Cons cell as an unboxed f64.
/// Handles both boxed and unboxed heads.
extern "C" double eco_cons_head_f64(HPtr cons) {
    HPointer hp = cons.toHPointer();

    // Resolve the Cons cell pointer.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0.0;  // Should not happen for valid Cons

    Cons* consCell = static_cast<Cons*>(obj);

    // Head is unboxed iff slot-0 kind is non-zero (2-bit encoding).
    if (tupleFieldKind(consCell->header.unboxed, 0) != 0) {
        // Head is unboxed: return the f64 value directly.
        return consCell->head.f;
    } else {
        // Head is boxed: resolve the HPointer and load from ElmFloat.
        HPointer headHp = consCell->head.p;
        void* headObj = Allocator::instance().resolve(headHp);
        if (!headObj) return 0.0;  // Should not happen

        // ElmFloat has layout: [Header:8][value:8]
        // value is at offset 8.
        ElmFloat* elmFloat = static_cast<ElmFloat*>(headObj);
        return elmFloat->value;
    }
}

/// Gets the head of a Cons cell as an unboxed i16 (Elm Char).
/// Handles both boxed and unboxed heads.
extern "C" int16_t eco_cons_head_i16(HPtr cons) {
    HPointer hp = cons.toHPointer();

    // Resolve the Cons cell pointer.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;  // Should not happen for valid Cons

    Cons* consCell = static_cast<Cons*>(obj);

    // Head is unboxed iff slot-0 kind is non-zero (2-bit encoding).
    if (tupleFieldKind(consCell->header.unboxed, 0) != 0) {
        // Head is unboxed: return the i16 value directly.
        return consCell->head.c;
    } else {
        // Head is boxed: resolve the HPointer and load from ElmChar.
        HPointer headHp = consCell->head.p;
        void* headObj = Allocator::instance().resolve(headHp);
        if (!headObj) return 0;  // Should not happen

        // ElmChar has layout: [Header:8][value:2][padding:6]
        // value is at offset 8.
        ElmChar* elmChar = static_cast<ElmChar*>(headObj);
        return static_cast<int16_t>(elmChar->value);
    }
}

//===----------------------------------------------------------------------===//
// Arithmetic Helpers
//===----------------------------------------------------------------------===//

// Integer exponentiation: base^exp
// Returns 0 for negative exponents (caller handles this)
extern "C" int64_t eco_int_pow(int64_t base, int64_t exp) {
    if (exp < 0) {
        // Negative exponent returns 0 (caller should prevent this,
        // but handle defensively)
        return 0;
    }
    if (exp == 0) {
        return 1;
    }

    // Binary exponentiation for efficiency
    int64_t result = 1;
    while (exp > 0) {
        if (exp & 1) {
            result *= base;
        }
        base *= base;
        exp >>= 1;
    }
    return result;
}

//===----------------------------------------------------------------------===//
// HPointer Conversion
//===----------------------------------------------------------------------===//

extern "C" void* eco_resolve_hptr(HPtr hptr) {
    void* ptr = hpointerToPtr(hptr.toBits());
    assert(ptr && "eco_resolve_hptr: received an embedded constant (not a heap pointer)");
    return ptr;
}

// Update an ElmArray's `header.unboxed` to the kind of the value about
// to be stored at one of its element slots. Called from the JIT lowering
// of `eco.array.set` immediately after `eco_clone_array`, so the cloned
// array's kind flag always matches what `elements[]` actually contains.
//
// Without this, an `Array.empty`-derived array (header.unboxed=0) that
// receives a raw-i64 store via `eco.array.set` keeps `unboxed=0` while
// the slot holds an int — the next minor GC then mis-traces that int
// as an HPointer and aborts on the heap-bounds check in
// NurserySpace::evacuate.
extern "C" void eco_array_set_fix_kind(HPtr array_hptr, uint32_t intended_kind) {
    HPointer hp;
    uint64_t bits = array_hptr.toBits();
    std::memcpy(&hp, &bits, sizeof(hp));
    if (hp.constant != 0) return;
    void* ptr = Allocator::instance().resolve(hp);
    if (!ptr) return;
    ElmArray* arr = static_cast<ElmArray*>(ptr);
    arr->header.unboxed = intended_kind & 0x3F;
}

extern "C" HPtr eco_clone_array(HPtr array_hptr) {
    uint64_t array_bits = array_hptr.toBits();

    // Root source array across allocation so GC updates it
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(reinterpret_cast<HPointer*>(&array_bits), 1, 1);

    void* srcPtr = hpointerToPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;

    HPointer resultHp = alloc::allocArray(len);
    // Re-resolve source (GC may have updated array_bits through the root)
    srcPtr = hpointerToPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);

    rs.restoreStackRangePoint(saved);

    void* dstPtr = Allocator::instance().resolve(resultHp);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    // Copy header flags (unboxed), length, and all elements
    dst->header.unboxed = src->header.unboxed;
    dst->length = len;
    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }

#if ECO_HEAP_VALIDATE
    // Stale-pointer barrier — only when the array claims to be boxed.
    // Unconditional validation false-positives on integer arrays whose
    // values happen to bit-decode as in-nursery addresses (e.g. a BitSet
    // chunk = 0x60082000), which is plenty common in compiler internals.
    if ((dst->header.unboxed & 0x3) == 0) {
        for (uint32_t i = 0; i < len; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromHPointer(resultHp);
}
