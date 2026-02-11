//===- BytesExports.cpp - C-linkage exports for Bytes module ---------------===//
//
// Implements the Bytes kernel functions using the runtime's ByteBuffer type.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/BytesOps.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>

// Declare the runtime helper from ElmBytesRuntime
extern "C" uint32_t elm_bytebuffer_len(uint64_t bb);

// Declare the closure call function from RuntimeExports
extern "C" uint64_t eco_closure_call_saturated(uint64_t closure_hptr, uint64_t* new_args, uint32_t num_newargs);

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
    t->header.unboxed = 3;  // both fields unboxed
    t->a.i = a;
    t->b.i = b;
    return Export::encode(allocator.wrap(t));
}

static uint64_t makeTuple2_if(int64_t a, double b) {
    auto& allocator = Allocator::instance();
    Tuple2* t = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
    t->header.unboxed = 3;  // both fields unboxed
    t->a.i = a;
    t->b.f = b;
    return Export::encode(allocator.wrap(t));
}

static uint64_t makeTuple2_ip(int64_t a, HPointer b) {
    auto& allocator = Allocator::instance();
    Tuple2* t = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
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
            void* strPtr = allocator.resolve(encoder->values[1].p);
            ElmString* str = static_cast<ElmString*>(strPtr);
            for (u32 i = 0; i < str->header.size; i++) {
                u16 ch = str->chars[i];
                if (ch >= 0xD800 && ch <= 0xDBFF && i + 1 < str->header.size) {
                    u16 lo = str->chars[i + 1];
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
//   papCreate(read_fn, arity=3) → papExtend(pap, first_captured) → call(bytes, offset)
// So arity-3: (first_captured_arg, bytes, offset)
// And arity-2: (bytes, offset)
//
// All params are i64 in the LLVM ABI. Bool (isLE) is an eco.value constant.
// Return value is always a Tuple2(new_offset: i64, decoded_value) as eco.value.

// ============================================================================
// extern "C" exports
// ============================================================================

extern "C" {

uint64_t Elm_Kernel_Bytes_width(uint64_t bytes) {
    return static_cast<uint64_t>(elm_bytebuffer_len(bytes));
}

uint64_t Elm_Kernel_Bytes_getHostEndianness() {
    uint16_t test = 1;
    bool isLE = (*reinterpret_cast<uint8_t*>(&test) == 1);
    return isLE ? 0 : 1;
}

int64_t Elm_Kernel_Bytes_getStringWidth(uint64_t str) {
    HPointer h = Export::decode(str);
    if (h.constant == Const_EmptyString + 1) {
        return 0;
    }
    void* ptr = Export::toPtr(str);
    if (!ptr) return 0;
    ElmString* elmStr = static_cast<ElmString*>(ptr);
    uint32_t utf16_length = elmStr->header.size;
    if (utf16_length == 0) return 0;

    int64_t utf8_bytes = 0;
    const uint16_t* chars = elmStr->chars;
    for (uint32_t i = 0; i < utf16_length; i++) {
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

uint64_t Elm_Kernel_Bytes_encode(uint64_t encoderVal) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(encoderVal);
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
    return Export::encode(allocator.wrap(result));
}

uint64_t Elm_Kernel_Bytes_decode(uint64_t decoder, uint64_t bytes) {
    auto& allocator = Allocator::instance();

    // Call the decoder closure with (bytes, offset=0).
    // The decoder is a function: (eco.value, i64) -> eco.value (Tuple2)
    uint64_t args[2] = { bytes, 0 };
    uint64_t result = eco_closure_call_saturated(decoder, args, 2);

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

    // Copy decoded value from Tuple2 field b, preserving boxed/unboxed status.
    if (tuple->header.unboxed & 0x2) {
        just->unboxed = 1;
        just->values[0].i = tuple->b.i;
    } else {
        just->unboxed = 0;
        just->values[0].p = tuple->b.p;
    }

    return Export::encode(allocator.wrap(just));
}

uint64_t Elm_Kernel_Bytes_decodeFailure() {
    return Export::encode(alloc::nothing());
}

// --- arity 2 read functions: (bytes, offset) ---

uint64_t Elm_Kernel_Bytes_read_i8(uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    int8_t val = static_cast<int8_t>(bb->bytes[offset]);
    return makeTuple2_ii(offset + 1, static_cast<int64_t>(val));
}

uint64_t Elm_Kernel_Bytes_read_u8(uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    uint8_t val = bb->bytes[offset];
    return makeTuple2_ii(offset + 1, static_cast<int64_t>(val));
}

// --- arity 3 read functions: (isLE_or_length, bytes, offset) ---

uint64_t Elm_Kernel_Bytes_read_i16(uint64_t isLE, uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    bool le = isLittleEndian(isLE);
    int16_t val;
    if (le) {
        val = static_cast<int16_t>(bb->bytes[offset]) |
              (static_cast<int16_t>(bb->bytes[offset + 1]) << 8);
    } else {
        val = (static_cast<int16_t>(bb->bytes[offset]) << 8) |
              static_cast<int16_t>(bb->bytes[offset + 1]);
    }
    return makeTuple2_ii(offset + 2, static_cast<int64_t>(val));
}

uint64_t Elm_Kernel_Bytes_read_i32(uint64_t isLE, uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    bool le = isLittleEndian(isLE);
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
    return makeTuple2_ii(offset + 4, static_cast<int64_t>(val));
}

uint64_t Elm_Kernel_Bytes_read_u16(uint64_t isLE, uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    bool le = isLittleEndian(isLE);
    uint16_t val;
    if (le) {
        val = static_cast<uint16_t>(bb->bytes[offset]) |
              (static_cast<uint16_t>(bb->bytes[offset + 1]) << 8);
    } else {
        val = (static_cast<uint16_t>(bb->bytes[offset]) << 8) |
              static_cast<uint16_t>(bb->bytes[offset + 1]);
    }
    return makeTuple2_ii(offset + 2, static_cast<int64_t>(val));
}

uint64_t Elm_Kernel_Bytes_read_u32(uint64_t isLE, uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    bool le = isLittleEndian(isLE);
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
    return makeTuple2_ii(offset + 4, static_cast<int64_t>(val));
}

uint64_t Elm_Kernel_Bytes_read_f32(uint64_t isLE, uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    bool le = isLittleEndian(isLE);
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
    return makeTuple2_if(offset + 4, static_cast<double>(fval));
}

uint64_t Elm_Kernel_Bytes_read_f64(uint64_t isLE, uint64_t bytes, int64_t offset) {
    ByteBuffer* bb = resolveByteBuffer(bytes);
    bool le = isLittleEndian(isLE);
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
    return makeTuple2_if(offset + 8, dval);
}

uint64_t Elm_Kernel_Bytes_read_bytes(int64_t length, uint64_t bytes, int64_t offset) {
    auto& allocator = Allocator::instance();
    ByteBuffer* src = resolveByteBuffer(bytes);

    size_t allocSize = sizeof(ByteBuffer) + length;
    allocSize = (allocSize + 7) & ~7;
    ByteBuffer* slice = static_cast<ByteBuffer*>(allocator.allocate(allocSize, Tag_ByteBuffer));
    slice->header.size = static_cast<u32>(length);
    std::memcpy(slice->bytes, src->bytes + offset, length);

    return makeTuple2_ip(offset + length, allocator.wrap(slice));
}

uint64_t Elm_Kernel_Bytes_read_string(int64_t length, uint64_t bytes, int64_t offset) {
    auto& allocator = Allocator::instance();
    ByteBuffer* bb = resolveByteBuffer(bytes);
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

    return makeTuple2_ip(offset + length, allocator.wrap(str));
}

// --- write functions (used by non-fused encoder path, stubs for now) ---

uint64_t Elm_Kernel_Bytes_write_i8(int64_t value) {
    (void)value;
    assert(false && "Elm_Kernel_Bytes_write_i8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i16(int64_t value, bool isBigEndian) {
    (void)value; (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_i16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i32(int64_t value, bool isBigEndian) {
    (void)value; (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_i32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u8(uint64_t value) {
    (void)value;
    assert(false && "Elm_Kernel_Bytes_write_u8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u16(uint64_t value, bool isBigEndian) {
    (void)value; (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_u16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u32(uint64_t value, bool isBigEndian) {
    (void)value; (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_u32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_f32(double value, bool isBigEndian) {
    (void)value; (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_f32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_f64(double value, bool isBigEndian) {
    (void)value; (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_f64 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_bytes(uint64_t bytes) {
    (void)bytes;
    assert(false && "Elm_Kernel_Bytes_write_bytes not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_string(uint64_t str) {
    (void)str;
    assert(false && "Elm_Kernel_Bytes_write_string not implemented");
    return 0;
}

} // extern "C"
