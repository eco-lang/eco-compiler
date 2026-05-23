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
//
// Two-pass: walk the list once to count cells (both reads, no allocation),
// then allocate the buffer of exact size and walk again to fill. The list
// head is rooted across the allocate via Pattern B so the second walk picks
// up GC-relocated cells.
HPointer fromList(HPointer list) {
    auto& allocator = Allocator::instance();

    // Pass 1: count. Pure reads; list cannot move during this pass because
    // no allocation occurs.
    size_t count = 0;
    {
        HPointer cur = list;
        while (!alloc::isNil(cur)) {
            void* cell = allocator.resolve(cur);
            if (!cell) break;
            Cons* c = static_cast<Cons*>(cell);
            ++count;
            cur = c->tail;
        }
    }

    if (count == 0) return empty();

    size_t total_size = sizeof(ByteBuffer) + count;
    total_size = (total_size + 7) & ~static_cast<size_t>(7);

    if (total_size >= allocator.getLargeObjectThreshold()) {
        // Large path: header + body each may GC, so we route via
        // allocLargeByteBuffer(nullptr,...) and fill the (pinned) body
        // through the re-resolved list head.
        HPointer hp;
        {
            StackRootRangeGuard guard(&list, 1, 0x1);
            hp = allocator.allocLargeByteBuffer(nullptr, count);
        }
        ByteBuffer* dst = alloc::resolveByteBufferBody(allocator.resolve(hp));
        HPointer cur = list;
        size_t i = 0;
        while (!alloc::isNil(cur) && i < count) {
            Cons* c = static_cast<Cons*>(allocator.resolve(cur));
            dst->bytes[i++] = static_cast<u8>(c->head.i & 0xFF);
            cur = c->tail;
        }
        return hp;
    }

    uint64_t roots[1];
    std::memcpy(&roots[0], &list, sizeof(list));
    ByteBuffer* dst = static_cast<ByteBuffer*>(
        eco_alloc_with_roots(Tag_ByteBuffer, total_size, roots, 1, 0x1));
    std::memcpy(&list, &roots[0], sizeof(list));
    dst->header.size = static_cast<u32>(count);

    HPointer cur = list;
    size_t i = 0;
    while (!alloc::isNil(cur) && i < count) {
        Cons* c = static_cast<Cons*>(allocator.resolve(cur));
        dst->bytes[i++] = static_cast<u8>(c->head.i & 0xFF);
        cur = c->tail;
    }
    return allocator.wrap(dst);
}

// Creates a ByteBuffer from a UTF-8 encoded string.
HPointer fromString(void* str) {
    return encodeUtf8(str);
}

// Decodes a ByteBuffer as UTF-8 into an ElmString.
//
// Two-pass: pass 1 validates the byte sequence and counts UTF-16 code
// units. Pass 2 allocates an ElmString of exact size, then re-walks the
// source (re-resolved across the allocate via Pattern B) writing code
// units directly into str->chars[]. byteBufferView handles all
// ByteBuffer forms (flat, large header, slice).
HPointer decodeUtf8(void* buf) {
    auto& allocator = Allocator::instance();
    auto src_view = alloc::byteBufferView(buf);
    size_t len = src_view.length;

    if (len == 0) {
        return alloc::just(alloc::boxed(alloc::emptyString()), true);
    }

    // Pass 1: validate + count UTF-16 code units.
    size_t units = 0;
    for (size_t i = 0; i < len; ) {
        u8 c = src_view.data[i];
        if ((c & 0x80) == 0) {
            ++units; ++i;
        } else if ((c & 0xE0) == 0xC0) {
            if (i + 1 >= len) return alloc::nothing();
            if ((src_view.data[i + 1] & 0xC0) != 0x80) return alloc::nothing();
            ++units; i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            if (i + 2 >= len) return alloc::nothing();
            if ((src_view.data[i + 1] & 0xC0) != 0x80 ||
                (src_view.data[i + 2] & 0xC0) != 0x80) return alloc::nothing();
            ++units; i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            if (i + 3 >= len) return alloc::nothing();
            if ((src_view.data[i + 1] & 0xC0) != 0x80 ||
                (src_view.data[i + 2] & 0xC0) != 0x80 ||
                (src_view.data[i + 3] & 0xC0) != 0x80) return alloc::nothing();
            // 4-byte sequence yields a surrogate pair in UTF-16.
            units += 2; i += 4;
        } else {
            return alloc::nothing();
        }
    }

    // Pass 2: root the source ByteBuffer across the allocate, then write
    // UTF-16 code units directly into the heap chars[]. Single copy
    // bytes[] → chars[]; no intermediate vector or u16 string.
    HPointer srcHP = allocator.wrap(buf);
    alloc::BlankString bs;
    {
        StackRootRangeGuard guard(&srcHP, 1, 0x1);
        bs = alloc::allocStringBlank(units);
    }

    // Re-resolve source through the rooted handle; second pass writes
    // straight into bs.chars[]. No allocation in this loop, so both the
    // re-resolved data pointer and bs.chars remain stable.
    auto src2 = alloc::byteBufferView(allocator.resolve(srcHP));
    size_t dst = 0;
    for (size_t i = 0; i < len; ) {
        u8 c = src2.data[i];
        u32 codepoint;
        if ((c & 0x80) == 0) {
            codepoint = c; i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            codepoint = ((c & 0x1F) << 6) | (src2.data[i + 1] & 0x3F);
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            codepoint = ((c & 0x0F) << 12) |
                        ((src2.data[i + 1] & 0x3F) << 6) |
                        (src2.data[i + 2] & 0x3F);
            i += 3;
        } else {
            codepoint = ((c & 0x07) << 18) |
                        ((src2.data[i + 1] & 0x3F) << 12) |
                        ((src2.data[i + 2] & 0x3F) << 6) |
                        (src2.data[i + 3] & 0x3F);
            i += 4;
        }
        if (codepoint <= 0xFFFF) {
            bs.chars[dst++] = static_cast<u16>(codepoint);
        } else {
            codepoint -= 0x10000;
            bs.chars[dst++] = static_cast<u16>(0xD800 | (codepoint >> 10));
            bs.chars[dst++] = static_cast<u16>(0xDC00 | (codepoint & 0x3FF));
        }
    }
    return alloc::just(alloc::boxed(bs.hp), true);
}

// Encodes a String (any form: leaf or slice) as UTF-8 into a ByteBuffer.
//
// Two-pass: materialise the source UTF-16 once (toStdU16String handles
// rope/slice flattening), count the UTF-8 byte width, then allocate a
// ByteBuffer of exact size and emit bytes directly into its payload.
// One copy out of the C++ std::u16string into the heap; no vector growth.
HPointer encodeUtf8(void* str) {
    if (!str) return empty();
    auto src = Elm::StringOps::toStdU16String(str);
    size_t len = src.size();
    if (len == 0) return empty();

    // Pass 1: count UTF-8 byte width.
    size_t out_bytes = 0;
    for (size_t i = 0; i < len; ++i) {
        u32 codepoint;
        u16 c = src[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len &&
            src[i + 1] >= 0xDC00 && src[i + 1] <= 0xDFFF) {
            codepoint = 0x10000 + ((c - 0xD800) << 10) + (src[i + 1] - 0xDC00);
            ++i;
        } else {
            codepoint = c;
        }
        if (codepoint < 0x80) out_bytes += 1;
        else if (codepoint < 0x800) out_bytes += 2;
        else if (codepoint < 0x10000) out_bytes += 3;
        else out_bytes += 4;
    }

    // Pass 2: allocate exact-size buffer and emit. No allocation between
    // allocByteBufferBlank and finishing the write — bytes pointer is
    // stable. `src` lives on the C++ stack/heap (not Elm GC heap), so
    // it survives the allocate unconditionally.
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(out_bytes);
    size_t off = 0;
    for (size_t i = 0; i < len; ++i) {
        u32 codepoint;
        u16 c = src[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len &&
            src[i + 1] >= 0xDC00 && src[i + 1] <= 0xDFFF) {
            codepoint = 0x10000 + ((c - 0xD800) << 10) + (src[i + 1] - 0xDC00);
            ++i;
        } else {
            codepoint = c;
        }
        if (codepoint < 0x80) {
            bb.bytes[off++] = static_cast<u8>(codepoint);
        } else if (codepoint < 0x800) {
            bb.bytes[off++] = static_cast<u8>(0xC0 | (codepoint >> 6));
            bb.bytes[off++] = static_cast<u8>(0x80 | (codepoint & 0x3F));
        } else if (codepoint < 0x10000) {
            bb.bytes[off++] = static_cast<u8>(0xE0 | (codepoint >> 12));
            bb.bytes[off++] = static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F));
            bb.bytes[off++] = static_cast<u8>(0x80 | (codepoint & 0x3F));
        } else {
            bb.bytes[off++] = static_cast<u8>(0xF0 | (codepoint >> 18));
            bb.bytes[off++] = static_cast<u8>(0x80 | ((codepoint >> 12) & 0x3F));
            bb.bytes[off++] = static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F));
            bb.bytes[off++] = static_cast<u8>(0x80 | (codepoint & 0x3F));
        }
    }
    return bb.hp;
}

// Converts a ByteBuffer to a list of integers (0-255).
HPointer toList(void* buf) {
    // Snapshot bytes onto the C++ stack first: `alloc::cons` may GC and
    // move/free the source ByteBuffer between cons iterations. Once the
    // bytes are stashed on the C++ stack/heap (outside Elm's GC heap),
    // building the list reverse-order is safe.
    auto v = alloc::byteBufferView(buf);
    std::vector<u8> snap(v.data, v.data + v.length);

    HPointer result = alloc::listNil();
    for (size_t i = snap.size(); i > 0; --i) {
        result = alloc::cons(alloc::unboxedInt(snap[i - 1]), result, false);
    }
    return result;
}

// Concatenates a list of ByteBuffers into a single ByteBuffer.
HPointer concat(HPointer bufferList) {
    auto& allocator = Allocator::instance();

    // First pass: calculate total length (no allocation, pointers stable)
    size_t total_len = 0;
    HPointer current = bufferList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* bufObj = allocator.resolve(c->head.p);
        if (bufObj) {
            total_len += alloc::byteBufferLength(bufObj);
        }
        current = c->tail;
    }

    if (total_len == 0) return empty();

    // Allocate via the LOT-aware blank helper so large concat results
    // land in pinned old-gen via the split-header path instead of being
    // evacuated as oversize nursery objects (Pattern B around the
    // allocate keeps bufferList alive across any internal GC).
    alloc::BlankByteBuffer dst;
    {
        StackRootRangeGuard guard(&bufferList, 1, 0x1);
        dst = alloc::allocByteBufferBlank(total_len);
    }

    // Second pass: copy buffers (bufferList updated by GC if needed)
    size_t offset = 0;
    current = bufferList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* bufObj = allocator.resolve(c->head.p);
        if (bufObj) {
            auto vbuf = alloc::byteBufferView(bufObj);
            std::memcpy(dst.bytes + offset, vbuf.data, vbuf.length);
            offset += vbuf.length;
        }
        current = c->tail;
    }

    return dst.hp;
}

// Base64 encoding table.
static const char base64_chars[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";

// Encodes a ByteBuffer as Base64, returning an ElmString.
HPointer toBase64(void* buf) {
    auto v = alloc::byteBufferView(buf);
    size_t len = v.length;

    if (len == 0) return alloc::emptyString();

    // Calculate output length
    size_t output_len = ((len + 2) / 3) * 4;

    std::u16string result;
    result.reserve(output_len);

    size_t i = 0;
    while (i < len) {
        // Track how many bytes we have in this group
        size_t bytes_in_group = std::min(size_t(3), len - i);

        u32 octet_a = v.data[i++];
        u32 octet_b = (bytes_in_group > 1) ? v.data[i++] : 0;
        u32 octet_c = (bytes_in_group > 2) ? v.data[i++] : 0;

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

// Decodes a Base64 String (any form) into a ByteBuffer.
HPointer fromBase64(void* str) {
    if (!str) return alloc::just(alloc::boxed(empty()), true);
    auto buf = Elm::StringOps::toStdU16String(str);
    size_t len = buf.size();

    if (len == 0) return alloc::just(alloc::boxed(empty()), true);
    if (len % 4 != 0) return alloc::nothing();

    size_t output_len = (len / 4) * 3;
    if (len >= 1 && buf[len - 1] == '=') output_len--;
    if (len >= 2 && buf[len - 2] == '=') output_len--;

    std::vector<u8> result;
    result.reserve(output_len);

    for (size_t i = 0; i < len; i += 4) {
        int a = base64_decode_char(buf[i]);
        int b = base64_decode_char(buf[i + 1]);
        int c = base64_decode_char(buf[i + 2]);
        int d = base64_decode_char(buf[i + 3]);

        if (a == -2 || b == -2 || (c == -2 && c != -1) || (d == -2 && d != -1)) {
            return alloc::nothing();
        }
        if (a < 0 || b < 0) return alloc::nothing();

        u32 triple = (a << 18) | (b << 12);
        if (c >= 0) triple |= (c << 6);
        if (d >= 0) triple |= d;

        result.push_back(static_cast<u8>((triple >> 16) & 0xFF));
        if (c >= 0) result.push_back(static_cast<u8>((triple >> 8) & 0xFF));
        if (d >= 0) result.push_back(static_cast<u8>(triple & 0xFF));
    }

    HPointer hpResult = fromVector(result);
    return alloc::just(alloc::boxed(hpResult), true);
}

// Hex encoding table (lowercase).
static const char hex_chars[] = "0123456789abcdef";

// Encodes a ByteBuffer as lowercase hexadecimal.
HPointer toHex(void* buf) {
    auto v = alloc::byteBufferView(buf);
    size_t len = v.length;

    if (len == 0) return alloc::emptyString();

    std::u16string result;
    result.reserve(len * 2);

    for (size_t i = 0; i < len; ++i) {
        u8 byte = v.data[i];
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

// Decodes a hexadecimal String (any form) into a ByteBuffer.
HPointer fromHex(void* str) {
    if (!str) return alloc::just(alloc::boxed(empty()), true);
    auto buf = Elm::StringOps::toStdU16String(str);
    size_t len = buf.size();

    if (len == 0) return alloc::just(alloc::boxed(empty()), true);
    if (len % 2 != 0) return alloc::nothing();

    std::vector<u8> result;
    result.reserve(len / 2);

    for (size_t i = 0; i < len; i += 2) {
        int hi = hex_decode_char(buf[i]);
        int lo = hex_decode_char(buf[i + 1]);

        if (hi < 0 || lo < 0) return alloc::nothing();

        result.push_back(static_cast<u8>((hi << 4) | lo));
    }

    HPointer hpResult = fromVector(result);
    return alloc::just(alloc::boxed(hpResult), true);
}

} // namespace BytesOps
} // namespace Elm
