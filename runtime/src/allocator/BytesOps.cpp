#include "BytesOps.hpp"
#include "StringOps.hpp"

namespace Elm {
namespace BytesOps {

// The list is walked twice: once to count, with no allocation, and again after the buffer is allocated to fill
// it, from the list head as rooted across the allocation.
HPointer fromList(HPointer list) {
    auto& allocator = Allocator::instance();

    size_t count = 0;
    for (alloc::ListCursor lc(list); !lc.done(); lc.next()) {
        ++count;
    }

    if (count == 0) return empty();

    size_t total_size = sizeof(ByteBuffer) + count;
    total_size = (total_size + 7) & ~static_cast<size_t>(7);

    if (total_size >= allocator.getLargeObjectThreshold()) {
        // The header and the body are separate allocations, either of which may collect. The body is pinned, so
        // `dst` stays valid while the list is walked.
        HPointer hp;
        {
            StackRootRangeGuard guard(&list, 1, 0x1);
            hp = allocator.allocLargeByteBuffer(nullptr, count);
        }
        u8* dst = largeBytesData(static_cast<LargeByteHeader*>(allocator.resolve(hp)));
        size_t i = 0;
        for (alloc::ListCursor lc(list); !lc.done() && i < count; lc.next()) {
            dst[i++] = static_cast<u8>(lc.current().i & 0xFF);
        }
        return hp;
    }

    uint64_t roots[1];
    std::memcpy(&roots[0], &list, sizeof(list));
    ByteBuffer* dst = static_cast<ByteBuffer*>(
        eco_alloc_with_roots(Tag_ByteBuffer, total_size, roots, 1, 0x1));
    std::memcpy(&list, &roots[0], sizeof(list));
    dst->header.size = static_cast<u32>(count);

    size_t i = 0;
    for (alloc::ListCursor lc(list); !lc.done() && i < count; lc.next()) {
        dst->bytes[i++] = static_cast<u8>(lc.current().i & 0xFF);
    }
    return allocator.wrap(dst);
}

HPointer fromString(void* str) {
    return encodeUtf8(str);
}

// Pass 1 checks the bytes and counts the UTF-16 units they decode to, so that the String can be allocated at its
// exact size. Pass 2 decodes again, from the source re-resolved through its rooted handle, straight into the
// String's units.
HPointer decodeUtf8(void* buf) {
    auto& allocator = Allocator::instance();
    auto src_view = alloc::byteBufferView(buf);
    size_t len = src_view.length;

    if (len == 0) {
        return alloc::just(alloc::boxed(alloc::emptyString()), true);
    }

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
            // A four-byte sequence becomes a surrogate pair.
            units += 2; i += 4;
        } else {
            return alloc::nothing();
        }
    }

    HPointer srcHP = allocator.wrap(buf);
    alloc::BlankString bs;
    {
        StackRootRangeGuard guard(&srcHP, 1, 0x1);
        bs = alloc::allocStringBlank(units);
    }

    // Nothing allocates in this loop, so both src2.data and bs.chars stay valid. Pass 1 has checked every
    // sequence, so the continuation bytes read here exist.
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

// A UTF-16 String is copied into C++ memory, which no collection moves. Pass 1 counts the UTF-8 bytes, so the
// buffer can be allocated at its exact size, and pass 2 encodes straight into it.
HPointer encodeUtf8(void* str) {
    if (!str) return empty();

    // A UTF-8 form holds only ASCII, so its bytes are already the encoding. They are copied to C++ memory first
    // because `allocByteBuffer` copies after it may have collected.
    if (Elm::StringOps::isUtf8(str)) {
        auto pr = Elm::StringOps::utf8Bytes(str);
        if (pr.second == 0) return empty();
        std::vector<u8> snap(pr.first, pr.first + pr.second);
        return alloc::allocByteBuffer(snap.data(), snap.size());
    }

    auto src = Elm::StringOps::toStdU16String(str);
    size_t len = src.size();
    if (len == 0) return empty();

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

    // Nothing allocates after allocByteBufferBlank, so bb.bytes stays valid for the whole loop.
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

HPointer toList(void* buf) {
    // Each `alloc::cons` may collect and move `buf`, so its bytes are copied to C++ memory first, and the list is
    // built from the last byte back.
    auto v = alloc::byteBufferView(buf);
    std::vector<u8> snap(v.data, v.data + v.length);

    HPointer result = alloc::listNil();
    for (size_t i = snap.size(); i > 0; --i) {
        result = alloc::cons(alloc::unboxedInt(snap[i - 1]), result, false);
    }
    return result;
}

// The list is walked twice: once to total the lengths, with no allocation, and again after the result is
// allocated to copy, from the list head as rooted across the allocation.
HPointer concat(HPointer bufferList) {

    size_t total_len = 0;
    for (alloc::ListCursor lc(bufferList); !lc.done(); lc.next()) {
        void* bufObj = alloc::resolveBytesOrNull(lc.current().p);
        if (bufObj) {
            total_len += alloc::byteBufferLength(bufObj);
        }
    }

    if (total_len == 0) return empty();

    alloc::BlankByteBuffer dst;
    {
        StackRootRangeGuard guard(&bufferList, 1, 0x1);
        dst = alloc::allocByteBufferBlank(total_len);
    }

    size_t offset = 0;
    for (alloc::ListCursor lc(bufferList); !lc.done(); lc.next()) {
        void* bufObj = alloc::resolveBytesOrNull(lc.current().p);
        if (bufObj) {
            auto vbuf = alloc::byteBufferView(bufObj);
            std::memcpy(dst.bytes + offset, vbuf.data, vbuf.length);
            offset += vbuf.length;
        }
    }

    return dst.hp;
}

/// The 64 Base64 digits, indexed by the 6-bit value each stands for.
static const char base64_chars[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";

HPointer toBase64(void* buf) {
    auto v = alloc::byteBufferView(buf);
    size_t len = v.length;

    if (len == 0) return alloc::emptyString();

    size_t output_len = ((len + 2) / 3) * 4;

    std::u16string result;
    result.reserve(output_len);

    size_t i = 0;
    while (i < len) {
        // The last group may be short; its missing bytes count as zero and its missing digits are `=`.
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

/// Returns the 6-bit value of the Base64 digit `c`, -1 for the padding `=`, or -2 for any other unit.
static int base64_decode_char(char16_t c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    if (c == '=') return -1;
    return -2;
}

HPointer fromBase64(void* str) {
    if (!str) return alloc::just(alloc::boxed(empty()), true);
    if (Elm::StringOps::isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_B64HEX, static_cast<Header*>(str)->size);
    auto buf = Elm::StringOps::toStdU16String(str);
    size_t len = buf.size();

    if (len == 0) return alloc::just(alloc::boxed(empty()), true);
    if (len % 4 != 0) return alloc::nothing();

    // Only a capacity hint; the bytes pushed below decide the result's length.
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

        // `c` and `d` may be padding (-1); only an invalid unit (-2) fails here.
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

/// The 16 hexadecimal digits in lowercase, indexed by the 4-bit value each stands for.
static const char hex_chars[] = "0123456789abcdef";

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

/// Returns the 4-bit value of the hexadecimal digit `c`, in either case, or -1 for any other unit.
static int hex_decode_char(char16_t c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

HPointer fromHex(void* str) {
    if (!str) return alloc::just(alloc::boxed(empty()), true);
    if (Elm::StringOps::isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_B64HEX, static_cast<Header*>(str)->size);
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
