//===- BytesExports.cpp - C-linkage exports for Bytes module ---------------===//
//
// Implements the Bytes kernel functions using the runtime's ByteBuffer type.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include <cassert>
#include <cstdint>

// Declare the runtime helper from ElmBytesRuntime
extern "C" uint32_t elm_bytebuffer_len(uint64_t bb);

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Bytes_width(uint64_t bytes) {
    // Return the byte length of the ByteBuffer
    return static_cast<uint64_t>(elm_bytebuffer_len(bytes));
}

uint64_t Elm_Kernel_Bytes_getHostEndianness() {
    // This one we can actually implement - detect host endianness.
    // Return 0 for little-endian, 1 for big-endian.
    uint16_t test = 1;
    bool isLittleEndian = (*reinterpret_cast<uint8_t*>(&test) == 1);
    return isLittleEndian ? 0 : 1;
}

int64_t Elm_Kernel_Bytes_getStringWidth(uint64_t str) {
    // Calculate the UTF-8 byte length of an Elm string (which is UTF-16 internally).
    // This is used by Bytes.Encode.string to know how many bytes to allocate.

    // Check for embedded constant (empty string)
    HPointer h = Export::decode(str);
    if (h.constant == Const_EmptyString + 1) {  // Constants are 1-indexed in HPointer
        return 0;
    }

    // Get pointer to the ElmString
    void* ptr = Export::toPtr(str);
    if (!ptr) {
        // Null or embedded constant that's not empty string - shouldn't happen
        return 0;
    }

    ElmString* elmStr = static_cast<ElmString*>(ptr);
    uint32_t utf16_length = elmStr->header.size;

    if (utf16_length == 0) {
        return 0;
    }

    // Calculate UTF-8 byte length from UTF-16 data
    int64_t utf8_bytes = 0;
    const uint16_t* chars = elmStr->chars;

    for (uint32_t i = 0; i < utf16_length; i++) {
        uint16_t codeUnit = chars[i];

        // Check for surrogate pairs (UTF-16 encoding of code points > 0xFFFF)
        if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
            // High surrogate - check for low surrogate
            if (i + 1 < utf16_length) {
                uint16_t lowSurrogate = chars[i + 1];
                if (lowSurrogate >= 0xDC00 && lowSurrogate <= 0xDFFF) {
                    // Valid surrogate pair - code points > 0xFFFF need 4 UTF-8 bytes
                    utf8_bytes += 4;
                    i++;  // Skip low surrogate
                    continue;
                }
            }
            // Invalid/unpaired surrogate - treat as 3-byte replacement char
            utf8_bytes += 3;
        } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
            // Unpaired low surrogate - treat as 3-byte replacement char
            utf8_bytes += 3;
        } else if (codeUnit < 0x80) {
            // ASCII - 1 byte
            utf8_bytes += 1;
        } else if (codeUnit < 0x800) {
            // 2-byte UTF-8
            utf8_bytes += 2;
        } else {
            // BMP character (0x800 - 0xFFFF, excluding surrogates) - 3 bytes
            utf8_bytes += 3;
        }
    }

    return utf8_bytes;
}

uint64_t Elm_Kernel_Bytes_encode(uint64_t encoder) {
    (void)encoder;
    assert(false && "Elm_Kernel_Bytes_encode not implemented - use BytesFusion for encoding");
    return 0;
}

uint64_t Elm_Kernel_Bytes_decode(uint64_t decoder, uint64_t bytes) {
    // This is the non-fused decoder interpreter path.
    // BytesFusion should inline decoder operations, so this shouldn't be called
    // for fuseable decoder patterns. If this is hit, the decoder pattern
    // couldn't be fused and needs the interpreter.
    (void)decoder;
    (void)bytes;
    assert(false && "Elm_Kernel_Bytes_decode not implemented - decoder pattern not fuseable");
    return 0;
}

uint64_t Elm_Kernel_Bytes_decodeFailure() {
    assert(false && "Elm_Kernel_Bytes_decodeFailure not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_i8(uint64_t bytes, int64_t offset) {
    (void)bytes;
    (void)offset;
    assert(false && "Elm_Kernel_Bytes_read_i8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_i16(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_i16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_i32(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_i32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_u8(uint64_t bytes, int64_t offset) {
    (void)bytes;
    (void)offset;
    assert(false && "Elm_Kernel_Bytes_read_u8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_u16(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_u16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_u32(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_u32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_f32(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_f32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_f64(uint64_t bytes, int64_t offset, bool isBigEndian) {
    (void)bytes;
    (void)offset;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_read_f64 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_bytes(uint64_t bytes, int64_t offset, int64_t length) {
    (void)bytes;
    (void)offset;
    (void)length;
    assert(false && "Elm_Kernel_Bytes_read_bytes not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_read_string(uint64_t bytes, int64_t offset, int64_t length) {
    (void)bytes;
    (void)offset;
    (void)length;
    assert(false && "Elm_Kernel_Bytes_read_string not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i8(int64_t value) {
    (void)value;
    assert(false && "Elm_Kernel_Bytes_write_i8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i16(int64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_i16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_i32(int64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_i32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u8(uint64_t value) {
    (void)value;
    assert(false && "Elm_Kernel_Bytes_write_u8 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u16(uint64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_u16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_u32(uint64_t value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_u32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_f32(double value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
    assert(false && "Elm_Kernel_Bytes_write_f32 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Bytes_write_f64(double value, bool isBigEndian) {
    (void)value;
    (void)isBigEndian;
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
