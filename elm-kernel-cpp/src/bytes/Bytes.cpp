#include "Bytes.hpp"
#include <stdexcept>

namespace Elm::Kernel::Bytes {

/*
 * Bytes module provides binary data encoding/decoding for Elm.
 *
 * Elm's Bytes are backed by JavaScript's DataView/ArrayBuffer.
 * In C++, we use std::vector<uint8_t> or similar byte buffer.
 *
 * Key concepts:
 * - Encoder: Describes how to write bytes, carries width info
 * - Decoder: Function (bytes, offset) -> (newOffset, value)
 * - All read/write operations handle endianness explicitly
 * - Strings are UTF-8 encoded in binary form
 *
 * LIBRARIES:
 * - No external library needed
 * - Use std::bit_cast (C++20) for float/int conversions
 * - Use std::endian (C++20) for endianness detection
 */

size_t width(Bytes* bytes) {
    /*
     * JS: function _Bytes_width(bytes) { return bytes.byteLength; }
     *
     * PSEUDOCODE:
     * - Return the byte length of the buffer
     * - In JS this is DataView.byteLength
     * - In C++ return vector.size() or buffer length
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.width not implemented");
}

Value* getHostEndianness() {
    /*
     * JS: var _Bytes_getHostEndianness = F2(function(le, be)
     *     {
     *         return __Scheduler_binding(function(callback)
     *         {
     *             callback(__Scheduler_succeed(
     *                 new Uint8Array(new Uint32Array([1]))[0] === 1 ? le : be
     *             ));
     *         });
     *     });
     *
     * PSEUDOCODE:
     * - Detect host machine's byte order
     * - Write 0x00000001 as uint32, check first byte:
     *   - If first byte is 1: little-endian (least significant byte first)
     *   - If first byte is 0: big-endian (most significant byte first)
     * - Return Task that succeeds with le or be argument
     *
     * NOTE: This is a Task because in Elm's design, side effects
     * (even reading system info) go through the Task system.
     *
     * HELPERS:
     * - __Scheduler_binding (create Task from callback)
     * - __Scheduler_succeed (wrap value in succeeded Task)
     *
     * LIBRARIES:
     * - In C++20: use std::endian::native == std::endian::little
     * - Pre-C++20: use union trick or reinterpret_cast
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.getHostEndianness not implemented");
}

size_t getStringWidth(const std::u16string& str) {
    /*
     * JS: function _Bytes_getStringWidth(string)
     *     {
     *         for (var width = 0, i = 0; i < string.length; i++)
     *         {
     *             var code = string.charCodeAt(i);
     *             width +=
     *                 (code < 0x80) ? 1 :
     *                 (code < 0x800) ? 2 :
     *                 (code < 0xD800 || 0xDBFF < code) ? 3 : (i++, 4);
     *         }
     *         return width;
     *     }
     *
     * PSEUDOCODE:
     * - Calculate UTF-8 encoded byte length of a UTF-16 string
     * - For each code unit:
     *   - ASCII (< 0x80): 1 byte
     *   - Latin/common (< 0x800): 2 bytes
     *   - BMP non-surrogate (< 0xD800 or > 0xDBFF): 3 bytes
     *   - Surrogate pair (0xD800-0xDBFF): 4 bytes (skip next unit)
     *
     * UTF-8 encoding widths:
     * - U+0000..U+007F:     1 byte  (0xxxxxxx)
     * - U+0080..U+07FF:     2 bytes (110xxxxx 10xxxxxx)
     * - U+0800..U+FFFF:     3 bytes (1110xxxx 10xxxxxx 10xxxxxx)
     * - U+10000..U+10FFFF:  4 bytes (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
     *
     * HELPERS: None
     * LIBRARIES: None (pure UTF-8 width calculation)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.getStringWidth not implemented");
}

Value* decode(Decoder* decoder, Bytes* bytes) {
    /*
     * JS: var _Bytes_decode = F2(function(decoder, bytes)
     *     {
     *         try {
     *             return __Maybe_Just(A2(decoder, bytes, 0).b);
     *         } catch(e) {
     *             return __Maybe_Nothing;
     *         }
     *     });
     *
     * PSEUDOCODE:
     * - Run decoder on bytes starting at offset 0
     * - Decoder returns Tuple2(newOffset, value)
     * - If successful: return Just(value)
     * - If decoder throws (via decodeFailure): return Nothing
     *
     * NOTE: Decoder is a function (bytes, offset) -> (newOffset, value)
     * The decoder can fail by throwing (see decodeFailure).
     *
     * HELPERS:
     * - __Maybe_Just, __Maybe_Nothing
     * - __Utils_Tuple2 (decoder return type)
     *
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.decode not implemented");
}

Value* decodeFailure() {
    /*
     * JS: var _Bytes_decodeFailure = F2(function() { throw 0; });
     *
     * PSEUDOCODE:
     * - Signal decoder failure by throwing/returning error
     * - Used when decoder encounters invalid/unexpected bytes
     * - Caught by decode() which returns Nothing
     *
     * NOTE: In JS this throws to abort decoding.
     * In C++ can use exception or return special error value.
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.decodeFailure not implemented");
}

Bytes* encode(Encoder* encoder) {
    /*
     * JS: function _Bytes_encode(encoder)
     *     {
     *         var mutableBytes = new DataView(new ArrayBuffer(__Encode_getWidth(encoder)));
     *         __Encode_write(encoder)(mutableBytes)(0);
     *         return mutableBytes;
     *     }
     *
     * PSEUDOCODE:
     * - Get total byte width from encoder
     * - Allocate buffer of that size
     * - Call write function starting at offset 0
     * - Return filled buffer as Bytes
     *
     * NOTE: Encoder carries width info and write function.
     * __Encode_getWidth and __Encode_write are from Bytes.Encode.
     *
     * HELPERS:
     * - __Encode_getWidth (get encoder's byte width)
     * - __Encode_write (get encoder's write function)
     *
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.encode not implemented");
}

/*
 * READ OPERATIONS (Decoders)
 *
 * All read functions return Tuple2(newOffset, value).
 * These are building blocks for decoder combinators.
 *
 * In JS, these use DataView methods:
 * - getInt8, getInt16, getInt32 (signed)
 * - getUint8, getUint16, getUint32 (unsigned)
 * - getFloat32, getFloat64 (IEEE 754)
 *
 * LIBRARIES:
 * - For endianness: std::endian (C++20) or manual byte swapping
 * - For float conversion: std::bit_cast (C++20) or memcpy
 */

Value* read_i8(Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_i8 = F2(function(bytes, offset) {
     *         return __Utils_Tuple2(offset + 1, bytes.getInt8(offset));
     *     });
     *
     * PSEUDOCODE:
     * - Read 1 byte as signed 8-bit integer
     * - Return (offset + 1, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None (direct byte read with sign extension)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_i8 not implemented");
}

Value* read_i16(bool littleEndian, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_i16 = F3(function(isLE, bytes, offset) {
     *         return __Utils_Tuple2(offset + 2, bytes.getInt16(offset, isLE));
     *     });
     *
     * PSEUDOCODE:
     * - Read 2 bytes as signed 16-bit integer
     * - If littleEndian: bytes[0] is LSB, bytes[1] is MSB
     * - If bigEndian: bytes[0] is MSB, bytes[1] is LSB
     * - Return (offset + 2, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None (manual byte assembly or std::byteswap)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_i16 not implemented");
}

Value* read_i32(bool littleEndian, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_i32 = F3(function(isLE, bytes, offset) {
     *         return __Utils_Tuple2(offset + 4, bytes.getInt32(offset, isLE));
     *     });
     *
     * PSEUDOCODE:
     * - Read 4 bytes as signed 32-bit integer
     * - Handle endianness as with i16
     * - Return (offset + 4, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_i32 not implemented");
}

Value* read_u8(Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_u8 = F2(function(bytes, offset) {
     *         return __Utils_Tuple2(offset + 1, bytes.getUint8(offset));
     *     });
     *
     * PSEUDOCODE:
     * - Read 1 byte as unsigned 8-bit integer
     * - Return (offset + 1, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_u8 not implemented");
}

Value* read_u16(bool littleEndian, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_u16 = F3(function(isLE, bytes, offset) {
     *         return __Utils_Tuple2(offset + 2, bytes.getUint16(offset, isLE));
     *     });
     *
     * PSEUDOCODE:
     * - Read 2 bytes as unsigned 16-bit integer
     * - Handle endianness
     * - Return (offset + 2, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_u16 not implemented");
}

Value* read_u32(bool littleEndian, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_u32 = F3(function(isLE, bytes, offset) {
     *         return __Utils_Tuple2(offset + 4, bytes.getUint32(offset, isLE));
     *     });
     *
     * PSEUDOCODE:
     * - Read 4 bytes as unsigned 32-bit integer
     * - Handle endianness
     * - Return (offset + 4, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_u32 not implemented");
}

Value* read_f32(bool littleEndian, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_f32 = F3(function(isLE, bytes, offset) {
     *         return __Utils_Tuple2(offset + 4, bytes.getFloat32(offset, isLE));
     *     });
     *
     * PSEUDOCODE:
     * - Read 4 bytes as IEEE 754 single-precision float
     * - Handle endianness
     * - Reinterpret bits as float
     * - Return (offset + 4, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES:
     * - std::bit_cast<float>(uint32) (C++20)
     * - Or memcpy for type punning
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_f32 not implemented");
}

Value* read_f64(bool littleEndian, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_f64 = F3(function(isLE, bytes, offset) {
     *         return __Utils_Tuple2(offset + 8, bytes.getFloat64(offset, isLE));
     *     });
     *
     * PSEUDOCODE:
     * - Read 8 bytes as IEEE 754 double-precision float
     * - Handle endianness
     * - Reinterpret bits as double
     * - Return (offset + 8, value)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES:
     * - std::bit_cast<double>(uint64) (C++20)
     * - Or memcpy for type punning
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_f64 not implemented");
}

Value* read_bytes(size_t length, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_bytes = F3(function(len, bytes, offset)
     *     {
     *         return __Utils_Tuple2(offset + len,
     *             new DataView(bytes.buffer, bytes.byteOffset + offset, len));
     *     });
     *
     * PSEUDOCODE:
     * - Create a new Bytes view/slice of given length
     * - In JS: creates DataView into same ArrayBuffer
     * - In C++: can either copy or create view (prefer copy for safety)
     * - Return (offset + length, newBytes)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_bytes not implemented");
}

Value* read_string(size_t length, Bytes* bytes, size_t offset) {
    /*
     * JS: var _Bytes_read_string = F3(function(len, bytes, offset)
     *     {
     *         var string = [];
     *         var end = offset + len;
     *         for (; offset < end;)
     *         {
     *             var byte = bytes.getUint8(offset++);
     *             string.push(
     *                 (byte < 128)
     *                     ? String.fromCharCode(byte)
     *                     :
     *                 ((byte & 0xE0) === 0xC0)
     *                     ? String.fromCharCode((byte & 0x1F) << 6
     *                         | bytes.getUint8(offset++) & 0x3F)
     *                     :
     *                 ((byte & 0xF0) === 0xE0)
     *                     ? String.fromCharCode(
     *                         (byte & 0xF) << 12
     *                         | (bytes.getUint8(offset++) & 0x3F) << 6
     *                         | bytes.getUint8(offset++) & 0x3F
     *                     )
     *                     :
     *                     (byte =
     *                         ((byte & 0x7) << 18
     *                             | (bytes.getUint8(offset++) & 0x3F) << 12
     *                             | (bytes.getUint8(offset++) & 0x3F) << 6
     *                             | bytes.getUint8(offset++) & 0x3F
     *                         ) - 0x10000
     *                     , String.fromCharCode(Math.floor(byte / 0x400) + 0xD800,
     *                                           byte % 0x400 + 0xDC00)
     *                     )
     *             );
     *         }
     *         return __Utils_Tuple2(offset, string.join(''));
     *     });
     *
     * PSEUDOCODE:
     * - Decode `length` UTF-8 bytes into UTF-16 string
     * - UTF-8 decoding:
     *   - 0xxxxxxx: 1-byte (ASCII)
     *   - 110xxxxx 10xxxxxx: 2-byte
     *   - 1110xxxx 10xxxxxx 10xxxxxx: 3-byte
     *   - 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx: 4-byte (surrogate pair)
     * - For 4-byte sequences (U+10000+):
     *   - Subtract 0x10000 from code point
     *   - High surrogate: (cp / 0x400) + 0xD800
     *   - Low surrogate: (cp % 0x400) + 0xDC00
     * - Return (newOffset, string)
     *
     * HELPERS: __Utils_Tuple2
     * LIBRARIES: None (pure UTF-8 to UTF-16 conversion)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.read_string not implemented");
}

/*
 * WRITE OPERATIONS (Encoders)
 *
 * These are low-level write functions called by the encoder system.
 * They take a mutable byte buffer, offset, and value.
 * They return the new offset after writing.
 *
 * In JS, these use DataView methods:
 * - setInt8, setInt16, setInt32 (signed)
 * - setUint8, setUint16, setUint32 (unsigned)
 * - setFloat32, setFloat64 (IEEE 754)
 *
 * NOTE: The JS implementations are F3/F4 curried functions that take
 * (buffer, offset, value, [endianness]) and write to the mutable buffer.
 * The C++ stubs here differ - they create Encoder objects.
 * The actual writing happens in encode() which calls Encode_write.
 *
 * LIBRARIES:
 * - For endianness: manual byte arrangement
 * - For float conversion: std::bit_cast (C++20) or memcpy
 */

Encoder* write_i8(int8_t value) {
    /*
     * JS: var _Bytes_write_i8 = F3(function(mb, i, n) {
     *         mb.setInt8(i, n);
     *         return i + 1;
     *     });
     *
     * PSEUDOCODE:
     * - Write 1 byte signed integer at offset
     * - Return offset + 1
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_i8 not implemented");
}

Encoder* write_i16(bool littleEndian, int16_t value) {
    /*
     * JS: var _Bytes_write_i16 = F4(function(mb, i, n, isLE) {
     *         mb.setInt16(i, n, isLE);
     *         return i + 2;
     *     });
     *
     * PSEUDOCODE:
     * - Write 2 bytes signed integer at offset
     * - If littleEndian: LSB first
     * - If bigEndian: MSB first
     * - Return offset + 2
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_i16 not implemented");
}

Encoder* write_i32(bool littleEndian, int32_t value) {
    /*
     * JS: var _Bytes_write_i32 = F4(function(mb, i, n, isLE) {
     *         mb.setInt32(i, n, isLE);
     *         return i + 4;
     *     });
     *
     * PSEUDOCODE:
     * - Write 4 bytes signed integer at offset
     * - Handle endianness
     * - Return offset + 4
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_i32 not implemented");
}

Encoder* write_u8(uint8_t value) {
    /*
     * JS: var _Bytes_write_u8 = F3(function(mb, i, n) {
     *         mb.setUint8(i, n);
     *         return i + 1;
     *     });
     *
     * PSEUDOCODE:
     * - Write 1 byte unsigned integer at offset
     * - Return offset + 1
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_u8 not implemented");
}

Encoder* write_u16(bool littleEndian, uint16_t value) {
    /*
     * JS: var _Bytes_write_u16 = F4(function(mb, i, n, isLE) {
     *         mb.setUint16(i, n, isLE);
     *         return i + 2;
     *     });
     *
     * PSEUDOCODE:
     * - Write 2 bytes unsigned integer at offset
     * - Handle endianness
     * - Return offset + 2
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_u16 not implemented");
}

Encoder* write_u32(bool littleEndian, uint32_t value) {
    /*
     * JS: var _Bytes_write_u32 = F4(function(mb, i, n, isLE) {
     *         mb.setUint32(i, n, isLE);
     *         return i + 4;
     *     });
     *
     * PSEUDOCODE:
     * - Write 4 bytes unsigned integer at offset
     * - Handle endianness
     * - Return offset + 4
     *
     * HELPERS: None
     * LIBRARIES: None
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_u32 not implemented");
}

Encoder* write_f32(bool littleEndian, float value) {
    /*
     * JS: var _Bytes_write_f32 = F4(function(mb, i, n, isLE) {
     *         mb.setFloat32(i, n, isLE);
     *         return i + 4;
     *     });
     *
     * PSEUDOCODE:
     * - Write 4 bytes IEEE 754 single-precision float at offset
     * - Reinterpret float bits as uint32
     * - Handle endianness
     * - Return offset + 4
     *
     * HELPERS: None
     * LIBRARIES:
     * - std::bit_cast<uint32_t>(float) (C++20)
     * - Or memcpy for type punning
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_f32 not implemented");
}

Encoder* write_f64(bool littleEndian, double value) {
    /*
     * JS: var _Bytes_write_f64 = F4(function(mb, i, n, isLE) {
     *         mb.setFloat64(i, n, isLE);
     *         return i + 8;
     *     });
     *
     * PSEUDOCODE:
     * - Write 8 bytes IEEE 754 double-precision float at offset
     * - Reinterpret double bits as uint64
     * - Handle endianness
     * - Return offset + 8
     *
     * HELPERS: None
     * LIBRARIES:
     * - std::bit_cast<uint64_t>(double) (C++20)
     * - Or memcpy for type punning
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_f64 not implemented");
}

Encoder* write_bytes(Bytes* bytes) {
    /*
     * JS: var _Bytes_write_bytes = F3(function(mb, offset, bytes)
     *     {
     *         for (var i = 0, len = bytes.byteLength, limit = len - 4; i <= limit; i += 4)
     *         {
     *             mb.setUint32(offset + i, bytes.getUint32(i));
     *         }
     *         for (; i < len; i++)
     *         {
     *             mb.setUint8(offset + i, bytes.getUint8(i));
     *         }
     *         return offset + len;
     *     });
     *
     * PSEUDOCODE:
     * - Copy source bytes to destination buffer at offset
     * - Optimization: copy 4 bytes at a time while possible
     * - Copy remaining bytes one at a time
     * - Return offset + byteLength
     *
     * NOTE: The optimization reads/writes as uint32 for speed.
     * In C++, use memcpy for efficient bulk copy.
     *
     * HELPERS: None
     * LIBRARIES: None (use memcpy)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_bytes not implemented");
}

Encoder* write_string(const std::u16string& str) {
    /*
     * JS: var _Bytes_write_string = F3(function(mb, offset, string)
     *     {
     *         for (var i = 0; i < string.length; i++)
     *         {
     *             var code = string.charCodeAt(i);
     *             offset +=
     *                 (code < 0x80)
     *                     ? (mb.setUint8(offset, code), 1)
     *                     :
     *                 (code < 0x800)
     *                     ? (mb.setUint16(offset, 0xC080
     *                         | (code >>> 6 & 0x1F) << 8
     *                         | code & 0x3F), 2)
     *                     :
     *                 (code < 0xD800 || 0xDBFF < code)
     *                     ? (mb.setUint16(offset, 0xE080
     *                         | (code >>> 12 & 0xF) << 8
     *                         | code >>> 6 & 0x3F),
     *                        mb.setUint8(offset + 2, 0x80 | code & 0x3F), 3)
     *                     :
     *                 (code = (code - 0xD800) * 0x400 + string.charCodeAt(++i) - 0xDC00 + 0x10000
     *                 , mb.setUint32(offset, 0xF0808080
     *                     | (code >>> 18 & 0x7) << 24
     *                     | (code >>> 12 & 0x3F) << 16
     *                     | (code >>> 6 & 0x3F) << 8
     *                     | code & 0x3F), 4);
     *         }
     *         return offset;
     *     });
     *
     * PSEUDOCODE:
     * - Encode UTF-16 string to UTF-8 bytes in buffer
     * - For each code point:
     *   - U+0000..U+007F (ASCII): 1 byte (0xxxxxxx)
     *   - U+0080..U+07FF: 2 bytes (110xxxxx 10xxxxxx)
     *   - U+0800..U+D7FF or U+E000..U+FFFF: 3 bytes (1110xxxx 10xxxxxx 10xxxxxx)
     *   - U+10000..U+10FFFF (surrogate pair): 4 bytes (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
     * - Surrogate pair decoding:
     *   - high = 0xD800..0xDBFF
     *   - low = 0xDC00..0xDFFF
     *   - codepoint = (high - 0xD800) * 0x400 + (low - 0xDC00) + 0x10000
     * - Return new offset after all bytes written
     *
     * NOTE: The JS writes bytes in specific patterns using setUint16/setUint32
     * to minimize function calls. In C++ can write byte-by-byte for clarity.
     *
     * HELPERS: None
     * LIBRARIES: None (pure UTF-16 to UTF-8 conversion)
     */
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Bytes.write_string not implemented");
}

} // namespace Elm::Kernel::Bytes
