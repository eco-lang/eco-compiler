/**
 * Binary Data Operations Implementation.
 *
 * Implements byte buffer manipulation for the Elm runtime, including
 * creation, UTF-8 encoding/decoding, Base64, and hex conversion.
 */

#include "BytesOps.hpp"
#include "StringOps.hpp"

namespace Elm {
namespace BytesOps {

// Creates a ByteBuffer from a list of integers (0-255).
HPointer fromList(HPointer list) {
    auto& allocator = Allocator::instance();

    // First pass: count elements
    size_t count = 0;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        ++count;
        current = c->tail;
    }

    if (count == 0) return empty();

    // Allocate buffer
    size_t total_size = sizeof(ByteBuffer) + count;
    total_size = (total_size + 7) & ~7;

    ByteBuffer* buf = static_cast<ByteBuffer*>(allocator.allocate(total_size, Tag_ByteBuffer));
    buf->header.size = static_cast<u32>(count);

    // Second pass: fill bytes
    current = list;
    size_t i = 0;

    while (!alloc::isNil(current) && i < count) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        // Truncate to 8 bits
        buf->bytes[i] = static_cast<u8>(c->head.i & 0xFF);
        ++i;
        current = c->tail;
    }

    return allocator.wrap(buf);
}

// Creates a ByteBuffer from a UTF-8 encoded string.
HPointer fromString(void* str) {
    return encodeUtf8(str);
}

// Decodes a ByteBuffer as UTF-8 into an ElmString.
HPointer decodeUtf8(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t len = b->header.size;

    if (len == 0) {
        return alloc::just(alloc::boxed(alloc::emptyString()), true);
    }

    // Decode UTF-8 to UTF-16
    std::u16string utf16;
    utf16.reserve(len);  // Worst case

    size_t i = 0;
    while (i < len) {
        u8 c = b->bytes[i];
        u32 codepoint;

        if ((c & 0x80) == 0) {
            // 1-byte (ASCII)
            codepoint = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            // 2-byte sequence
            if (i + 1 >= len) return alloc::nothing();  // Invalid
            u8 c2 = b->bytes[i + 1];
            if ((c2 & 0xC0) != 0x80) return alloc::nothing();
            codepoint = ((c & 0x1F) << 6) | (c2 & 0x3F);
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            // 3-byte sequence
            if (i + 2 >= len) return alloc::nothing();
            u8 c2 = b->bytes[i + 1];
            u8 c3 = b->bytes[i + 2];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80) return alloc::nothing();
            codepoint = ((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            // 4-byte sequence
            if (i + 3 >= len) return alloc::nothing();
            u8 c2 = b->bytes[i + 1];
            u8 c3 = b->bytes[i + 2];
            u8 c4 = b->bytes[i + 3];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80 || (c4 & 0xC0) != 0x80)
                return alloc::nothing();
            codepoint = ((c & 0x07) << 18) | ((c2 & 0x3F) << 12) |
                        ((c3 & 0x3F) << 6) | (c4 & 0x3F);
            i += 4;
        } else {
            return alloc::nothing();  // Invalid UTF-8
        }

        // Convert codepoint to UTF-16
        if (codepoint <= 0xFFFF) {
            utf16.push_back(static_cast<char16_t>(codepoint));
        } else if (codepoint <= 0x10FFFF) {
            // Surrogate pair
            codepoint -= 0x10000;
            utf16.push_back(static_cast<char16_t>(0xD800 | (codepoint >> 10)));
            utf16.push_back(static_cast<char16_t>(0xDC00 | (codepoint & 0x3FF)));
        } else {
            return alloc::nothing();  // Invalid codepoint
        }
    }

    HPointer result = alloc::allocString(utf16);
    return alloc::just(alloc::boxed(result), true);
}

// Encodes an ElmString as UTF-8 into a ByteBuffer.
HPointer encodeUtf8(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return empty();

    // Convert UTF-16 to UTF-8
    std::vector<u8> utf8;
    utf8.reserve(len * 3);  // Worst case

    for (size_t i = 0; i < len; ++i) {
        u32 codepoint;
        u16 c = s->chars[i];

        // Handle surrogate pairs
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            u16 c2 = s->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                ++i;
            } else {
                codepoint = c;
            }
        } else {
            codepoint = c;
        }

        // Encode as UTF-8
        if (codepoint < 0x80) {
            utf8.push_back(static_cast<u8>(codepoint));
        } else if (codepoint < 0x800) {
            utf8.push_back(static_cast<u8>(0xC0 | (codepoint >> 6)));
            utf8.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
        } else if (codepoint < 0x10000) {
            utf8.push_back(static_cast<u8>(0xE0 | (codepoint >> 12)));
            utf8.push_back(static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F)));
            utf8.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
        } else {
            utf8.push_back(static_cast<u8>(0xF0 | (codepoint >> 18)));
            utf8.push_back(static_cast<u8>(0x80 | ((codepoint >> 12) & 0x3F)));
            utf8.push_back(static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F)));
            utf8.push_back(static_cast<u8>(0x80 | (codepoint & 0x3F)));
        }
    }

    return fromVector(utf8);
}

// Converts a ByteBuffer to a list of integers (0-255).
HPointer toList(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t len = b->header.size;

    HPointer result = alloc::listNil();

    // Build list in reverse order
    for (size_t i = len; i > 0; --i) {
        result = alloc::cons(alloc::unboxedInt(b->bytes[i - 1]), result, false);
    }

    return result;
}

// Concatenates a list of ByteBuffers into a single ByteBuffer.
HPointer concat(HPointer bufferList) {
    auto& allocator = Allocator::instance();

    // First pass: calculate total length
    size_t total_len = 0;
    HPointer current = bufferList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* bufObj = allocator.resolve(c->head.p);
        if (bufObj) {
            ByteBuffer* b = static_cast<ByteBuffer*>(bufObj);
            total_len += b->header.size;
        }
        current = c->tail;
    }

    if (total_len == 0) return empty();

    // Allocate result
    size_t total_size = sizeof(ByteBuffer) + total_len;
    total_size = (total_size + 7) & ~7;

    ByteBuffer* result = static_cast<ByteBuffer*>(allocator.allocate(total_size, Tag_ByteBuffer));
    result->header.size = static_cast<u32>(total_len);

    // Second pass: copy buffers
    size_t offset = 0;
    current = bufferList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* bufObj = allocator.resolve(c->head.p);
        if (bufObj) {
            ByteBuffer* b = static_cast<ByteBuffer*>(bufObj);
            std::memcpy(result->bytes + offset, b->bytes, b->header.size);
            offset += b->header.size;
        }
        current = c->tail;
    }

    return allocator.wrap(result);
}

// Base64 encoding table.
static const char base64_chars[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";

// Encodes a ByteBuffer as Base64, returning an ElmString.
HPointer toBase64(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t len = b->header.size;

    if (len == 0) return alloc::emptyString();

    // Calculate output length
    size_t output_len = ((len + 2) / 3) * 4;

    std::u16string result;
    result.reserve(output_len);

    size_t i = 0;
    while (i < len) {
        // Track how many bytes we have in this group
        size_t bytes_in_group = std::min(size_t(3), len - i);

        u32 octet_a = b->bytes[i++];
        u32 octet_b = (bytes_in_group > 1) ? b->bytes[i++] : 0;
        u32 octet_c = (bytes_in_group > 2) ? b->bytes[i++] : 0;

        u32 triple = (octet_a << 16) | (octet_b << 8) | octet_c;

        result.push_back(base64_chars[(triple >> 18) & 0x3F]);
        result.push_back(base64_chars[(triple >> 12) & 0x3F]);
        result.push_back((bytes_in_group > 1) ? base64_chars[(triple >> 6) & 0x3F] : '=');
        result.push_back((bytes_in_group > 2) ? base64_chars[triple & 0x3F] : '=');
    }

    return alloc::allocString(result);
}

// Decodes a single Base64 character to its 6-bit value.
// Returns -1 for padding ('='), -2 for invalid characters.
static int base64_decode_char(char16_t c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    if (c == '=') return -1;
    return -2;
}

// Decodes a Base64 ElmString into a ByteBuffer.
HPointer fromBase64(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::just(alloc::boxed(empty()), true);
    if (len % 4 != 0) return alloc::nothing();

    // Calculate output length (accounting for padding)
    size_t output_len = (len / 4) * 3;
    if (len >= 1 && s->chars[len - 1] == '=') output_len--;
    if (len >= 2 && s->chars[len - 2] == '=') output_len--;

    std::vector<u8> result;
    result.reserve(output_len);

    for (size_t i = 0; i < len; i += 4) {
        int a = base64_decode_char(s->chars[i]);
        int b = base64_decode_char(s->chars[i + 1]);
        int c = base64_decode_char(s->chars[i + 2]);
        int d = base64_decode_char(s->chars[i + 3]);

        if (a == -2 || b == -2 || (c == -2 && c != -1) || (d == -2 && d != -1)) {
            return alloc::nothing();  // Invalid character
        }

        if (a < 0 || b < 0) return alloc::nothing();

        u32 triple = (a << 18) | (b << 12);
        if (c >= 0) triple |= (c << 6);
        if (d >= 0) triple |= d;

        result.push_back(static_cast<u8>((triple >> 16) & 0xFF));
        if (c >= 0) result.push_back(static_cast<u8>((triple >> 8) & 0xFF));
        if (d >= 0) result.push_back(static_cast<u8>(triple & 0xFF));
    }

    HPointer buf = fromVector(result);
    return alloc::just(alloc::boxed(buf), true);
}

// Hex encoding table (lowercase).
static const char hex_chars[] = "0123456789abcdef";

// Encodes a ByteBuffer as lowercase hexadecimal.
HPointer toHex(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t len = b->header.size;

    if (len == 0) return alloc::emptyString();

    std::u16string result;
    result.reserve(len * 2);

    for (size_t i = 0; i < len; ++i) {
        u8 byte = b->bytes[i];
        result.push_back(hex_chars[(byte >> 4) & 0xF]);
        result.push_back(hex_chars[byte & 0xF]);
    }

    return alloc::allocString(result);
}

// Decodes a single hex character to its 4-bit value.
// Returns -1 for invalid characters.
static int hex_decode_char(char16_t c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Decodes a hexadecimal ElmString into a ByteBuffer.
HPointer fromHex(void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    size_t len = s->header.size;

    if (len == 0) return alloc::just(alloc::boxed(empty()), true);
    if (len % 2 != 0) return alloc::nothing();

    std::vector<u8> result;
    result.reserve(len / 2);

    for (size_t i = 0; i < len; i += 2) {
        int hi = hex_decode_char(s->chars[i]);
        int lo = hex_decode_char(s->chars[i + 1]);

        if (hi < 0 || lo < 0) return alloc::nothing();

        result.push_back(static_cast<u8>((hi << 4) | lo));
    }

    HPointer buf = fromVector(result);
    return alloc::just(alloc::boxed(buf), true);
}

} // namespace BytesOps
} // namespace Elm
