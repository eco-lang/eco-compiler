//===- BytesExports.cpp - C-linkage exports for Bytes module ---------------===//
//
// Implements the Bytes kernel functions using the runtime's ByteBuffer type.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/BytesOps.hpp"
#include "allocator/StringOps.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>

// Declare the runtime helper from ElmBytesRuntime
extern "C" uint32_t elm_bytebuffer_len(uint64_t bb);

// Declare the closure call function from RuntimeExports
namespace Elm { struct EvalParamLayout; }
extern "C" HPtr eco_apply_closure_typed(HPtr closure_hptr, int64_t* typed_args,
                                        uint32_t num_args,
                                        const Elm::EvalParamLayout* args_layout);
extern "C" size_t eco_gc_stack_range_point();
extern "C" void   eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask);
extern "C" void   eco_gc_restore_stack_range_point(size_t saved);

using namespace Elm;
using namespace Elm::Kernel;

// ============================================================================
// Helpers
// ============================================================================

// Embedded constant encoding: True = constant field 3, encoded as 3 << 40
static constexpr uint64_t CONST_TRUE  = 3ULL << 40;
static constexpr uint64_t CONST_FALSE = 4ULL << 40;

static bool isLittleEndian(uint64_t isLE) {
    return isLE == CONST_TRUE;
}

// Create a Tuple2 with both fields unboxed (i64/i64 or i64/f64).
static uint64_t makeTuple2_ii(int64_t a, int64_t b) {
    Tuple2* t = static_cast<Tuple2*>(
        eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), nullptr, 0, 0));
    // 2-bit kinds: slot 0 Int (01) + slot 1 Int (01) = 0b0101 = 5
    t->header.unboxed = 5;
    t->a.i = a;
    t->b.i = b;
    return Export::encode(Allocator::instance().wrap(t));
}

static uint64_t makeTuple2_if(int64_t a, double b) {
    Tuple2* t = static_cast<Tuple2*>(
        eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), nullptr, 0, 0));
    // 2-bit kinds: slot 0 Int (01) + slot 1 Float (10) = 0b1001 = 9
    t->header.unboxed = 9;
    t->a.i = a;
    t->b.f = b;
    return Export::encode(Allocator::instance().wrap(t));
}

static uint64_t makeTuple2_ip(int64_t a, HPointer b) {
    // b is the only HPointer to root; helper pushes only on slow path.
    uint64_t roots[2] = { static_cast<uint64_t>(a), 0 };
    std::memcpy(&roots[1], &b, sizeof(b));
    Tuple2* t = static_cast<Tuple2*>(
        eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), roots, 2, 0x2));
    std::memcpy(&b, &roots[1], sizeof(b));
    t->header.unboxed = 1;  // only field a unboxed
    t->a.i = a;
    t->b.p = b;
    return Export::encode(Allocator::instance().wrap(t));
}

// Read-only view of a ByteBuffer in any structural form. byteBufferView
// resolves through Tag_LargeByteHeader split headers and Tag_ByteBufferSlice
// transparently, so callers downstream can index `data[offset]` regardless
// of the source structure.
static alloc::ByteBufferView resolveByteBufferView(uint64_t bytes) {
    auto& allocator = Allocator::instance();
    HPointer hp = Export::decode(bytes);
    void* obj = allocator.resolve(hp);
    return alloc::byteBufferView(obj);
}

// ============================================================================
// Encoder tree walker for non-fused Bytes.Encode.encode fallback
// ============================================================================

enum EncoderTag : u16 {
    ENC_I8   = 0,
    ENC_I16  = 1,
    ENC_I32  = 2,
    ENC_U8   = 3,
    ENC_U16  = 4,
    ENC_U32  = 5,
    ENC_F32  = 6,
    ENC_F64  = 7,
    ENC_SEQ  = 8,
    ENC_UTF8 = 9,
    ENC_BYTES = 10,
};

// Endianness type at the kernel boundary: LE = ctor 0, BE = ctor 1.
// Used once per encoder-construction call. The constructed encoder
// Custom stores the bool directly in slot 0 (unboxed Int), which lets
// writeEncoder read the flag without a per-primitive resolve.
static bool endiannessHPointerToBool(HPointer endianness) {
    auto& allocator = Allocator::instance();
    void* ptr = allocator.resolve(endianness);
    Custom* c = static_cast<Custom*>(ptr);
    return c->ctor == 1;
}

// O(1) per call: leaf primitives encode their width in the case label.
// The Elm-side `Encoder` constructors already cache the total byte width
// in values[0].i for ENC_SEQ (`Seq Int (List Encoder)`) and ENC_UTF8
// (`Utf8 Int String`). ENC_BYTES (`Bytes Bytes`) has a single field —
// the source ByteBuffer — so we look up its length via byteBufferLength
// without resolving any further indirection.
static size_t encoderSize(Custom* c) {
    switch (c->ctor) {
        case ENC_I8:   return 1;
        case ENC_I16:  return 2;
        case ENC_I32:  return 4;
        case ENC_U8:   return 1;
        case ENC_U16:  return 2;
        case ENC_U32:  return 4;
        case ENC_F32:  return 4;
        case ENC_F64:  return 8;
        case ENC_SEQ:  return static_cast<size_t>(c->values[0].i);
        case ENC_UTF8: return static_cast<size_t>(c->values[0].i);
        case ENC_BYTES: {
            void* bbPtr = Allocator::instance().resolve(c->values[0].p);
            return alloc::byteBufferLength(bbPtr);
        }
        default: return 0;
    }
}

static void writeEncoder(Custom* encoder, u8* buf, size_t& offset) {
    auto& allocator = Allocator::instance();

    // The Encoder Custom layout is determined by the Elm-side
    // `Bytes.Encode` module's `type Encoder = I16 Endianness Int | …`:
    // for the multi-byte primitives values[0] is the BOXED Endianness
    // HPointer (slot 0 = 00 in the unboxed bitmap) and values[1] is the
    // unboxed payload (slot 1 = 01 for Int or 10 for Float). We must
    // resolve the Endianness Custom to know LE vs BE.
    switch (encoder->ctor) {
        case ENC_I8:
        case ENC_U8: {
            buf[offset++] = static_cast<u8>(encoder->values[0].i & 0xFF);
            break;
        }
        case ENC_I16:
        case ENC_U16: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            uint16_t val = static_cast<uint16_t>(encoder->values[1].i);
            if (be) val = __builtin_bswap16(val);
            std::memcpy(buf + offset, &val, 2);
            offset += 2;
            break;
        }
        case ENC_I32:
        case ENC_U32: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            uint32_t val = static_cast<uint32_t>(encoder->values[1].i);
            if (be) val = __builtin_bswap32(val);
            std::memcpy(buf + offset, &val, 4);
            offset += 4;
            break;
        }
        case ENC_F32: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            float val = static_cast<float>(encoder->values[1].f);
            uint32_t bits;
            std::memcpy(&bits, &val, 4);
            if (be) bits = __builtin_bswap32(bits);
            std::memcpy(buf + offset, &bits, 4);
            offset += 4;
            break;
        }
        case ENC_F64: {
            bool be = endiannessHPointerToBool(encoder->values[0].p);
            double val = encoder->values[1].f;
            uint64_t bits;
            std::memcpy(&bits, &val, 8);
            if (be) bits = __builtin_bswap64(bits);
            std::memcpy(buf + offset, &bits, 8);
            offset += 8;
            break;
        }
        case ENC_SEQ: {
            HPointer list = encoder->values[1].p;
            while (!alloc::isNil(list)) {
                void* cellPtr = allocator.resolve(list);
                Cons* cons = static_cast<Cons*>(cellPtr);
                void* subPtr = allocator.resolve(cons->head.p);
                writeEncoder(static_cast<Custom*>(subPtr), buf, offset);
                list = cons->tail;
            }
            break;
        }
        case ENC_UTF8: {
            // Empty strings are represented as the EmptyString embedded constant,
            // which resolve() cannot dereference. encoderSize already returned 0
            // for this case (values[0].i == 0), so there is simply nothing to
            // write.
            if (alloc::isEmptyString(encoder->values[1].p)) {
                break;
            }
            void* strPtr = allocator.resolve(encoder->values[1].p);

            // Fast path for flat leaves and Tag_LargeStringHeader bodies:
            // read chars[] directly without materialising a snapshot. The
            // pointer is valid for the duration of this call because we
            // don't allocate inside the loop. Slices and ropes still go
            // through toStdU16String — full streaming-rope support is
            // tracked as item 10's deferred follow-up.
            const u16* chars = nullptr;
            size_t nchars = 0;
            std::u16string snapshot_storage;
            if (Elm::StringOps::isLeaf(strPtr)) {
                ElmString* s = alloc::resolveStringBody(strPtr);
                chars = s->chars;
                nchars = s->header.size;
            } else {
                snapshot_storage = Elm::StringOps::toStdU16String(strPtr);
                chars = reinterpret_cast<const u16*>(snapshot_storage.data());
                nchars = snapshot_storage.size();
            }
            for (size_t i = 0; i < nchars; i++) {
                u16 ch = chars[i];
                if (ch >= 0xD800 && ch <= 0xDBFF && i + 1 < nchars) {
                    u16 lo = chars[i + 1];
                    if (lo >= 0xDC00 && lo <= 0xDFFF) {
                        uint32_t cp = 0x10000 + ((ch - 0xD800) << 10) + (lo - 0xDC00);
                        buf[offset++] = static_cast<u8>(0xF0 | ((cp >> 18) & 0x07));
                        buf[offset++] = static_cast<u8>(0x80 | ((cp >> 12) & 0x3F));
                        buf[offset++] = static_cast<u8>(0x80 | ((cp >> 6) & 0x3F));
                        buf[offset++] = static_cast<u8>(0x80 | (cp & 0x3F));
                        i++;
                        continue;
                    }
                }
                if (ch < 0x80) {
                    buf[offset++] = static_cast<u8>(ch);
                } else if (ch < 0x800) {
                    buf[offset++] = static_cast<u8>(0xC0 | ((ch >> 6) & 0x1F));
                    buf[offset++] = static_cast<u8>(0x80 | (ch & 0x3F));
                } else {
                    buf[offset++] = static_cast<u8>(0xE0 | ((ch >> 12) & 0x0F));
                    buf[offset++] = static_cast<u8>(0x80 | ((ch >> 6) & 0x3F));
                    buf[offset++] = static_cast<u8>(0x80 | (ch & 0x3F));
                }
            }
            break;
        }
        case ENC_BYTES: {
            void* bbPtr = allocator.resolve(encoder->values[0].p);
            auto vbb = alloc::byteBufferView(bbPtr);
            std::memcpy(buf + offset, vbb.data, vbb.length);
            offset += vbb.length;
            break;
        }
    }
}

// ============================================================================
// Decoder read functions
// ============================================================================
//
// IMPORTANT: The argument order for arity-3 read functions is determined by
// the PAP capture order in the Elm decoder combinators:
//   papCreate(read_fn, arity=3) -> papExtend(pap, first_captured) -> call(bytes, offset)
// So arity-3: (first_captured_arg, bytes, offset)
// And arity-2: (bytes, offset)
//
// All params are i64 in the LLVM ABI. Bool (isLE) is an eco.value constant.
// Return value is always a Tuple2(new_offset: i64, decoded_value) as eco.value.

// ============================================================================
// extern "C" exports
// ============================================================================

extern "C" {

HPtr Elm_Kernel_Bytes_width(HPtr bytes) {
    return HPtr::fromBits(static_cast<uint64_t>(elm_bytebuffer_len(bytes.toBits())));
}

HPtr Elm_Kernel_Bytes_getHostEndianness() {
    uint16_t test = 1;
    bool isLE = (*reinterpret_cast<uint8_t*>(&test) == 1);
    return HPtr::fromBits(isLE ? 0 : 1);
}

int64_t Elm_Kernel_Bytes_getStringWidth(HPtr str) {
    uint64_t strBits = str.toBits();
    HPointer h = Export::decode(strBits);
    if (h.constant == Const_EmptyString + 1) {
        return 0;
    }
    void* ptr = Export::toPtr(strBits);
    if (!ptr) return 0;

    // Flat leaves (and Tag_LargeStringHeader bodies) read chars[] directly,
    // skipping the std::u16string materialization. Slices/ropes still
    // materialize once via toStdU16String. No allocation in the count
    // loop below, so the raw pointer remains valid for the whole call.
    const u16* chars_data = nullptr;
    size_t utf16_length = 0;
    std::u16string snapshot_storage;
    if (Elm::StringOps::isLeaf(ptr)) {
        ElmString* s = alloc::resolveStringBody(ptr);
        chars_data = s->chars;
        utf16_length = s->header.size;
    } else {
        snapshot_storage = Elm::StringOps::toStdU16String(ptr);
        chars_data = reinterpret_cast<const u16*>(snapshot_storage.data());
        utf16_length = snapshot_storage.size();
    }
    if (utf16_length == 0) return 0;

    int64_t utf8_bytes = 0;
    for (size_t i = 0; i < utf16_length; i++) {
        uint16_t codeUnit = chars_data[i];
        if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
            if (i + 1 < utf16_length) {
                uint16_t lo = chars_data[i + 1];
                if (lo >= 0xDC00 && lo <= 0xDFFF) {
                    utf8_bytes += 4;
                    i++;
                    continue;
                }
            }
            utf8_bytes += 3;
        } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
            utf8_bytes += 3;
        } else if (codeUnit < 0x80) {
            utf8_bytes += 1;
        } else if (codeUnit < 0x800) {
            utf8_bytes += 2;
        } else {
            utf8_bytes += 3;
        }
    }
    return utf8_bytes;
}

// Extern wrappers for the bytes-fusion "escape hatch" (bf.encoder.width
// and bf.write.encoder MLIR ops). Both lower to direct C calls — no
// allocation, no GC pressure. The encoder argument is an `eco.value`
// (HPtr) that the wrapper resolves before delegating to the existing
// encoderSize / writeEncoder walkers.
//
// Width is returned as u32 to match the rest of the BF dialect's
// 32-bit-width convention (bf.bytes_width, bf.utf8_width). Encoders
// that would produce >4 GiB output are not supported anywhere in the
// pipeline; static_cast narrowing is safe in practice.

extern "C" u32 elm_encoder_size(HPtr encoderVal) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderVal.toBits());
    Custom* enc = static_cast<Custom*>(allocator.resolve(h));
    return static_cast<u32>(encoderSize(enc));
}

extern "C" u32 elm_encoder_write_into(HPtr encoderVal, u8* dst) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderVal.toBits());
    Custom* enc = static_cast<Custom*>(allocator.resolve(h));
    size_t offset = 0;
    writeEncoder(enc, dst, offset);
    return static_cast<u32>(offset);
}

HPtr Elm_Kernel_Bytes_encode(HPtr encoderVal) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderVal.toBits());

    // Compute size before any allocation: encoderSize doesn't allocate.
    size_t totalSize = encoderSize(static_cast<Custom*>(allocator.resolve(h)));

    // LOT-aware allocation: oversize results land in pinned old-gen via
    // the split-header path so we don't evacuate them on every minor GC.
    // The encoder tree must remain reachable across the allocate; root
    // `h` via the guard.
    alloc::BlankByteBuffer dst;
    {
        StackRootRangeGuard guard(&h, 1, 0x1);
        dst = alloc::allocByteBufferBlank(totalSize);
    }

    Custom* encoder = static_cast<Custom*>(allocator.resolve(h));
    size_t offset = 0;
    writeEncoder(encoder, dst.bytes, offset);
    return HPtr::fromBits(Export::encode(dst.hp));
}

HPtr Elm_Kernel_Bytes_decode(HPtr decoder, HPtr bytes) {
    auto& allocator = Allocator::instance();

    // Call the decoder closure with (bytes, offset=0). The decoder is a
    // function `(Bytes, Int) -> Maybe a`. Pass the offset as an unboxed
    // i64 (PK_Int) instead of allocating an ElmInt. Use the PAP-aware
    // `eco_apply_closure_typed` — Bytes.Decode produces decoders by
    // composing combinators, so the runtime closure may be a multi-stage
    // wrapper rather than a flat 2-arg function, and the strict-arity
    // entry would assert on those.
    static constexpr unsigned char kLayoutBoxedInt[4] = { 2, 0, 0, 1 };
    const auto* layout = reinterpret_cast<const Elm::EvalParamLayout*>(kLayoutBoxedInt);
    int64_t args[2] = { static_cast<int64_t>(bytes.toBits()), 0 };
    uint64_t result = eco_apply_closure_typed(decoder, args, 2, layout).toBits();

    // Result is either Nothing (an embedded HPointer constant produced by a
    // primitive read that overran the buffer) or a Tuple2(new_offset: i64,
    // decoded_value). Embedded constants live in the `constant` bit-field
    // of HPointer (non-zero means embedded), so a Nothing closure-result
    // short-circuits straight back to the caller's Nothing.
    HPointer resultHP = Export::decode(result);
    if (resultHP.constant != 0) {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }

    // Pattern B: resultHP is re-resolved AFTER the allocate to copy field b
    // into Just; root via the helper's slow-path mechanism.

    // Construct Just(decoded_value) = Custom tag=0, 1 field.
    size_t justSize = sizeof(Custom) + sizeof(Unboxable);
    justSize = (justSize + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &resultHP, sizeof(resultHP));
    Custom* just = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, justSize, roots, 1, 0x1));
    std::memcpy(&resultHP, &roots[0], sizeof(resultHP));
    just->header.size = 1;
    just->ctor = 0;  // Just

    // Re-resolve the tuple via the rooted (and possibly updated) handle.
    Tuple2* tuple = static_cast<Tuple2*>(allocator.resolve(resultHP));

    // Copy decoded value from Tuple2 field b, preserving kind.
    uint32_t bKind = Elm::tupleFieldKind(tuple->header.unboxed, 1);
    just->unboxed = bKind;  // slot 0 kind matches source slot 1 kind
    just->values[0] = tuple->b;

    return HPtr::fromBits(Export::encode(allocator.wrap(just)));
}

HPtr Elm_Kernel_Bytes_decodeFailure() {
    return HPtr::fromBits(Export::encode(alloc::nothing()));
}

// --- arity 2 read functions: (bytes, offset) ---

// Read helpers below all share the same idiom: memcpy the on-wire bits
// (any width) into a register, byteswap conditionally for big-endian on
// LE hosts, and reinterpret. The compiler reliably lowers this to a
// movbe / bswap pair (one or two instructions per primitive read), much
// tighter than the manual byte-shift loops the original code emitted.
//
// Each read returns Nothing (an embedded HPointer constant) when the
// requested width would extend past the end of the buffer; the wrapper
// `Elm_Kernel_Bytes_decode` detects that constant and propagates it as
// the decoder's overall Nothing result. The bytes-fusion fast path
// performs equivalent bounds checks via `bf.require`, so reads only
// reach these helpers from the non-fused fall-back path.

static inline HPtr decoderNothing() {
    return HPtr::fromBits(Export::encode(alloc::nothing()));
}

HPtr Elm_Kernel_Bytes_read_i8(HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 1 > v.length) return decoderNothing();
    int8_t val = static_cast<int8_t>(v.data[offset]);
    return HPtr::fromBits(makeTuple2_ii(offset + 1, static_cast<int64_t>(val)));
}

HPtr Elm_Kernel_Bytes_read_u8(HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 1 > v.length) return decoderNothing();
    return HPtr::fromBits(makeTuple2_ii(offset + 1, static_cast<int64_t>(v.data[offset])));
}

// --- arity 3 read functions: (isLE_or_length, bytes, offset) ---

HPtr Elm_Kernel_Bytes_read_i16(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 2 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint16_t raw;
    std::memcpy(&raw, v.data + offset, 2);
    if (!le) raw = __builtin_bswap16(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 2,
        static_cast<int64_t>(static_cast<int16_t>(raw))));
}

HPtr Elm_Kernel_Bytes_read_i32(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 4 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint32_t raw;
    std::memcpy(&raw, v.data + offset, 4);
    if (!le) raw = __builtin_bswap32(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 4,
        static_cast<int64_t>(static_cast<int32_t>(raw))));
}

HPtr Elm_Kernel_Bytes_read_u16(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 2 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint16_t raw;
    std::memcpy(&raw, v.data + offset, 2);
    if (!le) raw = __builtin_bswap16(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 2, static_cast<int64_t>(raw)));
}

HPtr Elm_Kernel_Bytes_read_u32(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 4 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint32_t raw;
    std::memcpy(&raw, v.data + offset, 4);
    if (!le) raw = __builtin_bswap32(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 4, static_cast<int64_t>(raw)));
}

HPtr Elm_Kernel_Bytes_read_f32(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 4 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint32_t bits;
    std::memcpy(&bits, v.data + offset, 4);
    if (!le) bits = __builtin_bswap32(bits);
    float fval;
    std::memcpy(&fval, &bits, 4);
    return HPtr::fromBits(makeTuple2_if(offset + 4, static_cast<double>(fval)));
}

HPtr Elm_Kernel_Bytes_read_f64(HPtr isLE, HPtr bytes, int64_t offset) {
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || static_cast<size_t>(offset) + 8 > v.length) return decoderNothing();
    bool le = isLittleEndian(isLE.toBits());
    uint64_t bits;
    std::memcpy(&bits, v.data + offset, 8);
    if (!le) bits = __builtin_bswap64(bits);
    double dval;
    std::memcpy(&dval, &bits, 8);
    return HPtr::fromBits(makeTuple2_if(offset + 8, dval));
}

HPtr Elm_Kernel_Bytes_read_bytes(int64_t length, HPtr bytes, int64_t offset) {
    // Produce a Tag_ByteBufferSlice view over the source: zero payload
    // copy, just a 16-byte slice header. makeByteBufferSlice flattens to
    // a flat ByteBuffer copy under MAKE_BYTEBUFFER_SLICE_MIN_LEN bytes
    // so we don't pay the indirection cost on small ranges.
    auto v = resolveByteBufferView(bytes.toBits());
    if (offset < 0 || length < 0 || static_cast<size_t>(offset) + static_cast<size_t>(length) > v.length) return decoderNothing();
    HPointer srcHP = Export::decode(bytes.toBits());
    HPointer sliceHP = alloc::makeByteBufferSlice(srcHP,
        static_cast<u32>(offset), static_cast<u32>(length));
    return HPtr::fromBits(makeTuple2_ip(offset + length, sliceHP));
}

HPtr Elm_Kernel_Bytes_read_string(int64_t length, HPtr bytes, int64_t offset) {
    auto& allocator = Allocator::instance();

    // An empty string must round-trip to the EmptyString embedded constant, not
    // a zero-length heap ElmString — otherwise Utils::equal compares them as
    // unequal (one side is nullptr via toPtr, the other is a real pointer).
    // The function signature requires a Tuple2(new_offset, value), so wrap the
    // constant in the same makeTuple2_ip the non-empty path uses.
    if (length == 0) {
        return HPtr::fromBits(makeTuple2_ip(offset, alloc::emptyString()));
    }

    // Root the source-bytes handle. The width-counting pass below reads from
    // the buffer before any allocation, so a raw pointer is safe there; the
    // post-allocation copy must re-resolve through the rooted handle.
    HPointer srcHP = Export::decode(bytes.toBits());
    auto src_view = alloc::byteBufferView(allocator.resolve(srcHP));
    const u8* src = src_view.data + offset;

    // Count UTF-16 code units needed for the UTF-8 input.
    size_t utf16Count = 0;
    size_t pos = 0;
    while (pos < static_cast<size_t>(length)) {
        uint8_t byte = src[pos];
        if (byte < 0x80) {
            utf16Count++;
            pos++;
        } else if (byte < 0xE0) {
            utf16Count++;
            pos += 2;
        } else if (byte < 0xF0) {
            utf16Count++;
            pos += 3;
        } else {
            utf16Count += 2;  // surrogate pair
            pos += 4;
        }
    }

    // Pattern B: srcHP re-resolved after the allocate to copy/convert chars.
    // Root via helper, re-read post-call.
    size_t strAllocSize = sizeof(ElmString) + utf16Count * sizeof(u16);
    strAllocSize = (strAllocSize + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &srcHP, sizeof(srcHP));
    ElmString* str = static_cast<ElmString*>(
        eco_alloc_with_roots(Tag_String, strAllocSize, roots, 1, 0x1));
    std::memcpy(&srcHP, &roots[0], sizeof(srcHP));
    str->header.size = static_cast<u32>(utf16Count);

    src_view = alloc::byteBufferView(allocator.resolve(srcHP));
    src = src_view.data + offset;

    // Convert UTF-8 to UTF-16
    size_t srcPos = 0, dstPos = 0;
    while (srcPos < static_cast<size_t>(length)) {
        uint8_t byte = src[srcPos];
        uint32_t codepoint;
        if (byte < 0x80) {
            codepoint = byte;
            srcPos++;
        } else if (byte < 0xE0) {
            codepoint = (byte & 0x1F) << 6;
            codepoint |= (src[srcPos + 1] & 0x3F);
            srcPos += 2;
        } else if (byte < 0xF0) {
            codepoint = (byte & 0x0F) << 12;
            codepoint |= (src[srcPos + 1] & 0x3F) << 6;
            codepoint |= (src[srcPos + 2] & 0x3F);
            srcPos += 3;
        } else {
            codepoint = (byte & 0x07) << 18;
            codepoint |= (src[srcPos + 1] & 0x3F) << 12;
            codepoint |= (src[srcPos + 2] & 0x3F) << 6;
            codepoint |= (src[srcPos + 3] & 0x3F);
            srcPos += 4;
        }

        if (codepoint <= 0xFFFF) {
            str->chars[dstPos++] = static_cast<u16>(codepoint);
        } else {
            codepoint -= 0x10000;
            str->chars[dstPos++] = static_cast<u16>(0xD800 + (codepoint >> 10));
            str->chars[dstPos++] = static_cast<u16>(0xDC00 + (codepoint & 0x3FF));
        }
    }

    return HPtr::fromBits(makeTuple2_ip(offset + length, allocator.wrap(str)));
}

// --- write functions: create Encoder tree nodes (Custom types) ---
// These are processed by writeEncoder() in Elm_Kernel_Bytes_encode

// Helper to create a 1-field encoder Custom (for i8, u8)
static uint64_t makeEncoder1(u16 tag, int64_t value) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = tag;
    enc->unboxed = 1;  // value is unboxed
    enc->values[0].i = value;
    return Export::encode(Allocator::instance().wrap(enc));
}

// Helper to create a 2-field encoder Custom (for i16, i32, u16, u32, f32, f64)
// Field 0: endianness (boxed HPointer to LE/BE Custom)
// Field 1: value (unboxed int or float)
//
// This layout MUST match the Elm-side `type Encoder = I16 Endianness Int | …`
// constructors that production code uses — writeEncoder walks the result
// the same way regardless of who constructed it.
static uint64_t makeEncoder2_pi(u16 tag, uint64_t endianness, int64_t value) {
    HPointer endHP = Export::decode(endianness);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[2];
    std::memcpy(&roots[0], &endHP, sizeof(endHP));
    roots[1] = static_cast<uint64_t>(value);

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 2, 0x1));
    enc->header.size = 2;
    enc->ctor = tag;
    enc->unboxed = 4;  // slot 0 boxed (00) + slot 1 Int (01) = 0b0100
    std::memcpy(&enc->values[0].p, &roots[0], sizeof(HPointer));
    enc->values[1].i = static_cast<int64_t>(roots[1]);
    return Export::encode(Allocator::instance().wrap(enc));
}

static uint64_t makeEncoder2_pf(u16 tag, uint64_t endianness, double value) {
    HPointer endHP = Export::decode(endianness);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &endHP, sizeof(endHP));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&endHP, &roots[0], sizeof(endHP));
    enc->header.size = 2;
    enc->ctor = tag;
    enc->unboxed = 8;  // slot 0 boxed (00) + slot 1 Float (10) = 0b1000
    enc->values[0].p = endHP;
    enc->values[1].f = value;
    return Export::encode(Allocator::instance().wrap(enc));
}

// Helper to create a 1-field encoder with boxed HPointer (for bytes, string)
static uint64_t makeEncoder1_p(u16 tag, uint64_t ptr) {
    HPointer payload = Export::decode(ptr);
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &payload, sizeof(payload));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&payload, &roots[0], sizeof(payload));
    enc->header.size = 1;
    enc->ctor = tag;
    enc->unboxed = 0;
    enc->values[0].p = payload;
    return Export::encode(Allocator::instance().wrap(enc));
}

// Helper to create UTF8 encoder with size + string pointer
static uint64_t makeEncoderUtf8(HPtr str) {
    // Calculate UTF-8 byte count (no allocation inside).
    int64_t utf8Size = Elm_Kernel_Bytes_getStringWidth(str);

    HPointer strHP = Export::decode(str.toBits());
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &strHP, sizeof(strHP));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&strHP, &roots[0], sizeof(strHP));
    enc->header.size = 2;
    enc->ctor = ENC_UTF8;
    enc->unboxed = 1;  // field 0 unboxed (size), field 1 boxed (string)
    enc->values[0].i = utf8Size;
    enc->values[1].p = strHP;
    return Export::encode(Allocator::instance().wrap(enc));
}

// Helper to create BYTES encoder. Layout must match the Elm-side
// `Bytes Bytes` constructor (single boxed-HPointer field) so writeEncoder
// can read either-source Customs identically.
static uint64_t makeEncoderBytes(uint64_t bytes) {
    HPointer payload = Export::decode(bytes);
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &payload, sizeof(payload));

    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&payload, &roots[0], sizeof(payload));
    enc->header.size = 1;
    enc->ctor = ENC_BYTES;
    enc->unboxed = 0;
    enc->values[0].p = payload;
    return Export::encode(Allocator::instance().wrap(enc));
}

HPtr Elm_Kernel_Bytes_write_i8(int64_t value) {
    return HPtr::fromBits(makeEncoder1(ENC_I8, value));
}

HPtr Elm_Kernel_Bytes_write_i16(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_I16, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_i32(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_I32, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_u8(int64_t value) {
    return HPtr::fromBits(makeEncoder1(ENC_U8, value));
}

HPtr Elm_Kernel_Bytes_write_u16(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_U16, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_u32(HPtr endianness, int64_t value) {
    return HPtr::fromBits(makeEncoder2_pi(ENC_U32, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_f32(HPtr endianness, double value) {
    return HPtr::fromBits(makeEncoder2_pf(ENC_F32, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_f64(HPtr endianness, double value) {
    return HPtr::fromBits(makeEncoder2_pf(ENC_F64, endianness.toBits(), value));
}

HPtr Elm_Kernel_Bytes_write_bytes(HPtr bytes) {
    return HPtr::fromBits(makeEncoderBytes(bytes.toBits()));
}

HPtr Elm_Kernel_Bytes_write_string(HPtr str) {
    return HPtr::fromBits(makeEncoderUtf8(str));
}

} // extern "C"
