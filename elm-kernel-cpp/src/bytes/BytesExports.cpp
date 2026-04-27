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
extern "C" HPtr eco_closure_call_saturated(HPtr closure_hptr, uint64_t* new_args, uint32_t num_newargs, const Elm::EvalParamLayout* layout);
extern "C" HPtr eco_alloc_int(int64_t value);
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
    auto& allocator = Allocator::instance();
    Tuple2* t = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
    // 2-bit kinds: slot 0 Int (01) + slot 1 Int (01) = 0b0101 = 5
    t->header.unboxed = 5;
    t->a.i = a;
    t->b.i = b;
    return Export::encode(allocator.wrap(t));
}

static uint64_t makeTuple2_if(int64_t a, double b) {
    auto& allocator = Allocator::instance();
    Tuple2* t = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
    // 2-bit kinds: slot 0 Int (01) + slot 1 Float (10) = 0b1001 = 9
    t->header.unboxed = 9;
    t->a.i = a;
    t->b.f = b;
    return Export::encode(allocator.wrap(t));
}

static uint64_t makeTuple2_ip(int64_t a, HPointer b) {
    auto& allocator = Allocator::instance();
    // Root `b` across the allocation: Allocator::allocate may fire a minor GC
    // that relocates `b`'s referent. `b` is a C++ parameter and is not visible
    // to the compiler's stackmap, so without a manual stack-range push, `b`
    // would hold a stale HPointer after GC.
    uint64_t roots[1];
    std::memcpy(&roots[0], &b, sizeof(b));
    size_t saved = eco_gc_stack_range_point();
    eco_gc_push_stack_range(roots, 1, 1);
    Tuple2* t = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
    std::memcpy(&b, &roots[0], sizeof(b));
    eco_gc_restore_stack_range_point(saved);
    t->header.unboxed = 1;  // only field a unboxed
    t->a.i = a;
    t->b.p = b;
    return Export::encode(allocator.wrap(t));
}

// Resolve a ByteBuffer from an eco.value encoded uint64_t.
static ByteBuffer* resolveByteBuffer(uint64_t bytes) {
    auto& allocator = Allocator::instance();
    HPointer hp = Export::decode(bytes);
    return static_cast<ByteBuffer*>(allocator.resolve(hp));
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

// Endianness type: LE = ctor 0, BE = ctor 1
static bool encoderIsBigEndian(HPointer endianness) {
    auto& allocator = Allocator::instance();
    void* ptr = allocator.resolve(endianness);
    Custom* c = static_cast<Custom*>(ptr);
    return c->ctor == 1;
}

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
            auto& allocator = Allocator::instance();
            void* bbPtr = allocator.resolve(c->values[0].p);
            ByteBuffer* bb = static_cast<ByteBuffer*>(bbPtr);
            return bb->header.size;
        }
        default: return 0;
    }
}

static void writeEncoder(Custom* encoder, u8* buf, size_t& offset) {
    auto& allocator = Allocator::instance();

    switch (encoder->ctor) {
        case ENC_I8: {
            buf[offset++] = static_cast<u8>(encoder->values[0].i & 0xFF);
            break;
        }
        case ENC_I16: {
            bool be = encoderIsBigEndian(encoder->values[0].p);
            int16_t val = static_cast<int16_t>(encoder->values[1].i);
            if (be) {
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>(val & 0xFF);
            } else {
                buf[offset++] = static_cast<u8>(val & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
            }
            break;
        }
        case ENC_I32: {
            bool be = encoderIsBigEndian(encoder->values[0].p);
            int32_t val = static_cast<int32_t>(encoder->values[1].i);
            if (be) {
                buf[offset++] = static_cast<u8>((val >> 24) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 16) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>(val & 0xFF);
            } else {
                buf[offset++] = static_cast<u8>(val & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 16) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 24) & 0xFF);
            }
            break;
        }
        case ENC_U8: {
            buf[offset++] = static_cast<u8>(encoder->values[0].i & 0xFF);
            break;
        }
        case ENC_U16: {
            bool be = encoderIsBigEndian(encoder->values[0].p);
            uint16_t val = static_cast<uint16_t>(encoder->values[1].i);
            if (be) {
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>(val & 0xFF);
            } else {
                buf[offset++] = static_cast<u8>(val & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
            }
            break;
        }
        case ENC_U32: {
            bool be = encoderIsBigEndian(encoder->values[0].p);
            uint32_t val = static_cast<uint32_t>(encoder->values[1].i);
            if (be) {
                buf[offset++] = static_cast<u8>((val >> 24) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 16) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>(val & 0xFF);
            } else {
                buf[offset++] = static_cast<u8>(val & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 16) & 0xFF);
                buf[offset++] = static_cast<u8>((val >> 24) & 0xFF);
            }
            break;
        }
        case ENC_F32: {
            bool be = encoderIsBigEndian(encoder->values[0].p);
            float val = static_cast<float>(encoder->values[1].f);
            uint32_t bits;
            std::memcpy(&bits, &val, sizeof(bits));
            if (be) {
                buf[offset++] = static_cast<u8>((bits >> 24) & 0xFF);
                buf[offset++] = static_cast<u8>((bits >> 16) & 0xFF);
                buf[offset++] = static_cast<u8>((bits >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>(bits & 0xFF);
            } else {
                buf[offset++] = static_cast<u8>(bits & 0xFF);
                buf[offset++] = static_cast<u8>((bits >> 8) & 0xFF);
                buf[offset++] = static_cast<u8>((bits >> 16) & 0xFF);
                buf[offset++] = static_cast<u8>((bits >> 24) & 0xFF);
            }
            break;
        }
        case ENC_F64: {
            bool be = encoderIsBigEndian(encoder->values[0].p);
            double val = encoder->values[1].f;
            uint64_t bits;
            std::memcpy(&bits, &val, sizeof(bits));
            if (be) {
                for (int i = 7; i >= 0; i--)
                    buf[offset++] = static_cast<u8>((bits >> (i * 8)) & 0xFF);
            } else {
                for (int i = 0; i < 8; i++)
                    buf[offset++] = static_cast<u8>((bits >> (i * 8)) & 0xFF);
            }
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
            // Tag-aware snapshot: works for both flat leaves and slices.
            auto snapshot = Elm::StringOps::toStdU16String(strPtr);
            for (size_t i = 0; i < snapshot.size(); i++) {
                u16 ch = snapshot[i];
                if (ch >= 0xD800 && ch <= 0xDBFF && i + 1 < snapshot.size()) {
                    u16 lo = snapshot[i + 1];
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
            ByteBuffer* bb = static_cast<ByteBuffer*>(bbPtr);
            std::memcpy(buf + offset, bb->bytes, bb->header.size);
            offset += bb->header.size;
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

    auto chars = Elm::StringOps::toStdU16String(ptr);
    size_t utf16_length = chars.size();
    if (utf16_length == 0) return 0;

    int64_t utf8_bytes = 0;
    for (size_t i = 0; i < utf16_length; i++) {
        uint16_t codeUnit = chars[i];
        if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
            if (i + 1 < utf16_length) {
                uint16_t lo = chars[i + 1];
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

HPtr Elm_Kernel_Bytes_encode(HPtr encoderVal) {
    uint64_t encoderBits = encoderVal.toBits();
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderBits);
    void* ptr = allocator.resolve(h);
    Custom* encoder = static_cast<Custom*>(ptr);

    size_t totalSize = encoderSize(encoder);
    size_t allocSize = sizeof(ByteBuffer) + totalSize;
    allocSize = (allocSize + 7) & ~7;
    ByteBuffer* result = static_cast<ByteBuffer*>(
        allocator.allocate(allocSize, Tag_ByteBuffer));
    result->header.size = static_cast<u32>(totalSize);

    size_t offset = 0;
    writeEncoder(encoder, result->bytes, offset);
    return HPtr::fromBits(Export::encode(allocator.wrap(result)));
}

HPtr Elm_Kernel_Bytes_decode(HPtr decoder, HPtr bytes) {
    uint64_t decoderBits = decoder.toBits();
    uint64_t bytesBits = bytes.toBits();
    auto& allocator = Allocator::instance();

    // Call the decoder closure with (bytes, offset=0).
    // The decoder is a function: (eco.value, i64) -> eco.value (Tuple2)
    // The offset (Int) must be boxed as HPointer for the wrapper.
    uint64_t args[2] = { bytesBits, eco_alloc_int(0).toBits() };
    uint64_t result = eco_closure_call_saturated(decoder, args, 2, /*layout=*/nullptr).toBits();

    // Result is a Tuple2(new_offset: i64, decoded_value).
    HPointer resultHP = Export::decode(result);
    void* resultPtr = allocator.resolve(resultHP);
    Tuple2* tuple = static_cast<Tuple2*>(resultPtr);

    // Construct Just(decoded_value) = Custom tag=0, 1 field.
    size_t justSize = sizeof(Custom) + sizeof(Unboxable);
    justSize = (justSize + 7) & ~7;
    Custom* just = static_cast<Custom*>(allocator.allocate(justSize, Tag_Custom));
    just->header.size = 1;
    just->ctor = 0;  // Just

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

HPtr Elm_Kernel_Bytes_read_i8(HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    int8_t val = static_cast<int8_t>(bb->bytes[offset]);
    return HPtr::fromBits(makeTuple2_ii(offset + 1, static_cast<int64_t>(val)));
}

HPtr Elm_Kernel_Bytes_read_u8(HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    uint8_t val = bb->bytes[offset];
    return HPtr::fromBits(makeTuple2_ii(offset + 1, static_cast<int64_t>(val)));
}

// --- arity 3 read functions: (isLE_or_length, bytes, offset) ---

HPtr Elm_Kernel_Bytes_read_i16(HPtr isLE, HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    bool le = isLittleEndian(isLE.toBits());
    int16_t val;
    if (le) {
        val = static_cast<int16_t>(bb->bytes[offset]) |
              (static_cast<int16_t>(bb->bytes[offset + 1]) << 8);
    } else {
        val = (static_cast<int16_t>(bb->bytes[offset]) << 8) |
              static_cast<int16_t>(bb->bytes[offset + 1]);
    }
    return HPtr::fromBits(makeTuple2_ii(offset + 2, static_cast<int64_t>(val)));
}

HPtr Elm_Kernel_Bytes_read_i32(HPtr isLE, HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    bool le = isLittleEndian(isLE.toBits());
    uint32_t raw;
    if (le) {
        raw = static_cast<uint32_t>(bb->bytes[offset]) |
              (static_cast<uint32_t>(bb->bytes[offset + 1]) << 8) |
              (static_cast<uint32_t>(bb->bytes[offset + 2]) << 16) |
              (static_cast<uint32_t>(bb->bytes[offset + 3]) << 24);
    } else {
        raw = (static_cast<uint32_t>(bb->bytes[offset]) << 24) |
              (static_cast<uint32_t>(bb->bytes[offset + 1]) << 16) |
              (static_cast<uint32_t>(bb->bytes[offset + 2]) << 8) |
              static_cast<uint32_t>(bb->bytes[offset + 3]);
    }
    int32_t val = static_cast<int32_t>(raw);
    return HPtr::fromBits(makeTuple2_ii(offset + 4, static_cast<int64_t>(val)));
}

HPtr Elm_Kernel_Bytes_read_u16(HPtr isLE, HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    bool le = isLittleEndian(isLE.toBits());
    uint16_t val;
    if (le) {
        val = static_cast<uint16_t>(bb->bytes[offset]) |
              (static_cast<uint16_t>(bb->bytes[offset + 1]) << 8);
    } else {
        val = (static_cast<uint16_t>(bb->bytes[offset]) << 8) |
              static_cast<uint16_t>(bb->bytes[offset + 1]);
    }
    return HPtr::fromBits(makeTuple2_ii(offset + 2, static_cast<int64_t>(val)));
}

HPtr Elm_Kernel_Bytes_read_u32(HPtr isLE, HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    bool le = isLittleEndian(isLE.toBits());
    uint32_t val;
    if (le) {
        val = static_cast<uint32_t>(bb->bytes[offset]) |
              (static_cast<uint32_t>(bb->bytes[offset + 1]) << 8) |
              (static_cast<uint32_t>(bb->bytes[offset + 2]) << 16) |
              (static_cast<uint32_t>(bb->bytes[offset + 3]) << 24);
    } else {
        val = (static_cast<uint32_t>(bb->bytes[offset]) << 24) |
              (static_cast<uint32_t>(bb->bytes[offset + 1]) << 16) |
              (static_cast<uint32_t>(bb->bytes[offset + 2]) << 8) |
              static_cast<uint32_t>(bb->bytes[offset + 3]);
    }
    return HPtr::fromBits(makeTuple2_ii(offset + 4, static_cast<int64_t>(val)));
}

HPtr Elm_Kernel_Bytes_read_f32(HPtr isLE, HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    bool le = isLittleEndian(isLE.toBits());
    uint32_t bits;
    if (le) {
        bits = static_cast<uint32_t>(bb->bytes[offset]) |
               (static_cast<uint32_t>(bb->bytes[offset + 1]) << 8) |
               (static_cast<uint32_t>(bb->bytes[offset + 2]) << 16) |
               (static_cast<uint32_t>(bb->bytes[offset + 3]) << 24);
    } else {
        bits = (static_cast<uint32_t>(bb->bytes[offset]) << 24) |
               (static_cast<uint32_t>(bb->bytes[offset + 1]) << 16) |
               (static_cast<uint32_t>(bb->bytes[offset + 2]) << 8) |
               static_cast<uint32_t>(bb->bytes[offset + 3]);
    }
    float fval;
    std::memcpy(&fval, &bits, sizeof(float));
    return HPtr::fromBits(makeTuple2_if(offset + 4, static_cast<double>(fval)));
}

HPtr Elm_Kernel_Bytes_read_f64(HPtr isLE, HPtr bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    bool le = isLittleEndian(isLE.toBits());
    uint64_t bits = 0;
    if (le) {
        for (int i = 0; i < 8; i++)
            bits |= (static_cast<uint64_t>(bb->bytes[offset + i]) << (i * 8));
    } else {
        for (int i = 0; i < 8; i++)
            bits |= (static_cast<uint64_t>(bb->bytes[offset + i]) << ((7 - i) * 8));
    }
    double dval;
    std::memcpy(&dval, &bits, sizeof(double));
    return HPtr::fromBits(makeTuple2_if(offset + 8, dval));
}

HPtr Elm_Kernel_Bytes_read_bytes(int64_t length, HPtr bytes, int64_t offset) {
    auto& allocator = Allocator::instance();
    ByteBuffer* src = resolveByteBuffer(bytes.toBits());

    size_t allocSize = sizeof(ByteBuffer) + length;
    allocSize = (allocSize + 7) & ~7;
    ByteBuffer* slice = static_cast<ByteBuffer*>(allocator.allocate(allocSize, Tag_ByteBuffer));
    slice->header.size = static_cast<u32>(length);
    std::memcpy(slice->bytes, src->bytes + offset, length);

    return HPtr::fromBits(makeTuple2_ip(offset + length, allocator.wrap(slice)));
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

    ByteBuffer* bb = resolveByteBuffer(bytes.toBits());
    const u8* src = bb->bytes + offset;

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

    // Allocate ElmString
    size_t strAllocSize = sizeof(ElmString) + utf16Count * sizeof(u16);
    strAllocSize = (strAllocSize + 7) & ~7;
    ElmString* str = static_cast<ElmString*>(allocator.allocate(strAllocSize, Tag_String));
    str->header.size = static_cast<u32>(utf16Count);

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
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = tag;
    enc->unboxed = 1;  // value is unboxed
    enc->values[0].i = value;
    return Export::encode(allocator.wrap(enc));
}

// Helper to create a 2-field encoder Custom (for i16, i32, u16, u32, f32, f64)
// Field 0: endianness (boxed HPointer to LE/BE Custom)
// Field 1: value (unboxed int or float)
static uint64_t makeEncoder2_pi(u16 tag, uint64_t endianness, int64_t value) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 2;
    enc->ctor = tag;
    // 2-bit kinds: slot 0 boxed (00) + slot 1 Int (01) = 0b0100 = 4
    enc->unboxed = 4;
    enc->values[0].p = Export::decode(endianness);
    enc->values[1].i = value;
    return Export::encode(allocator.wrap(enc));
}

static uint64_t makeEncoder2_pf(u16 tag, uint64_t endianness, double value) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 2;
    enc->ctor = tag;
    // 2-bit kinds: slot 0 boxed (00) + slot 1 Float (10) = 0b1000 = 8
    enc->unboxed = 8;
    enc->values[0].p = Export::decode(endianness);
    enc->values[1].f = value;
    return Export::encode(allocator.wrap(enc));
}

// Helper to create a 1-field encoder with boxed HPointer (for bytes, string)
static uint64_t makeEncoder1_p(u16 tag, uint64_t ptr) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = tag;
    enc->unboxed = 0;  // value is boxed
    enc->values[0].p = Export::decode(ptr);
    return Export::encode(allocator.wrap(enc));
}

// Helper to create UTF8 encoder with size + string pointer
static uint64_t makeEncoderUtf8(HPtr str) {
    auto& allocator = Allocator::instance();

    // Calculate UTF-8 byte count
    int64_t utf8Size = Elm_Kernel_Bytes_getStringWidth(str);

    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 2;
    enc->ctor = ENC_UTF8;
    enc->unboxed = 1;  // field 0 unboxed (size), field 1 boxed (string)
    enc->values[0].i = utf8Size;
    enc->values[1].p = Export::decode(str.toBits());
    return Export::encode(allocator.wrap(enc));
}

// Helper to create BYTES encoder
static uint64_t makeEncoderBytes(uint64_t bytes) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = ENC_BYTES;
    enc->unboxed = 0;
    enc->values[0].p = Export::decode(bytes);
    return Export::encode(allocator.wrap(enc));
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
