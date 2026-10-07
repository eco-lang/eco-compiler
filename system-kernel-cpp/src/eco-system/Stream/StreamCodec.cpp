//===- StreamCodec.cpp - zlib and UTF-8 engines of Codec-kind streams -----===//
//
// plans/eco-system-library.md §3.5 (UTF-8 rules) and Phase 6 step 6.2. See
// StreamCodec.hpp for the contract. Pure C++: no heap access, no Elm calls,
// main thread only (the pair that owns the state is main-thread only).
//
// The z_stream lives behind a stable heap pointer: zlib's internal state
// points back at its z_stream (deflateStateCheck), so it must never move
// with the StreamPair that owns it.
//
// Templates used: none (no heap access).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Stream/StreamCodec.hpp"

#include <zlib.h>

#include <cstring>
#include <stdexcept>

namespace Eco::System {

namespace {

constexpr size_t kOutChunk = 64 * 1024;

enum class CodecKind : uint8_t { Deflate, Inflate, TextEncode, TextDecode };

} // namespace

struct CodecState {
    CodecKind kind;

    // Zlib.
    z_stream zs{};
    bool zInit = false;
    bool zEnded = false;     // inflate: Z_STREAM_END seen
    bool zFailed = false;

    // TextEncode: a high surrogate carried from the previous chunk (0: none).
    char16_t pendingHigh = 0;

    // TextDecode (WHATWG UTF-8 decoder state).
    uint32_t cp = 0;
    int seen = 0;
    int needed = 0;
    unsigned char lower = 0x80;
    unsigned char upper = 0xBF;
    bool bomChecked = false;

    explicit CodecState(CodecKind k) : kind(k) {}
    ~CodecState() {
        if (zInit) {
            if (kind == CodecKind::Deflate) deflateEnd(&zs);
            else inflateEnd(&zs);
        }
    }
};

void CodecDeleter::operator()(CodecState* c) const { delete c; }

namespace {

int windowBitsFor(int algorithm) {
    switch (algorithm) {
    case kCodecGzip: return 31;
    case kCodecDeflate: return 15;
    default: return -15;   // kCodecDeflateRaw
    }
}

// --- UTF-8 output helpers ---------------------------------------------------

void appendUtf8(std::string& out, uint32_t cp) {
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
}

constexpr uint32_t kReplacement = 0xFFFD;

// --- zlib ---------------------------------------------------------------------

std::string zlibMessage(const z_stream& zs, const char* fallback) {
    return zs.msg ? std::string(zs.msg) : std::string(fallback);
}

std::string deflateRun(CodecState& c, const std::string& in, bool finish,
                       std::vector<std::string>& out) {
    z_stream& zs = c.zs;
    zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(in.data()));
    zs.avail_in = static_cast<uInt>(in.size());
    std::string buf(kOutChunk, '\0');
    for (;;) {
        zs.next_out = reinterpret_cast<Bytef*>(buf.data());
        zs.avail_out = static_cast<uInt>(kOutChunk);
        int rc = deflate(&zs, finish ? Z_FINISH : Z_NO_FLUSH);
        if (rc == Z_STREAM_ERROR) return zlibMessage(zs, "deflate failed");
        size_t have = kOutChunk - zs.avail_out;
        if (have) out.emplace_back(buf.data(), have);
        if (finish) {
            if (rc == Z_STREAM_END) break;
            if (rc == Z_BUF_ERROR && have == 0) break;   // no progress possible
        } else if (zs.avail_out != 0) {
            break;   // all input consumed, nothing more pending
        }
    }
    return {};
}

std::string inflateRun(CodecState& c, const std::string& in, std::vector<std::string>& out) {
    z_stream& zs = c.zs;
    zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(in.data()));
    zs.avail_in = static_cast<uInt>(in.size());
    std::string buf(kOutChunk, '\0');
    for (;;) {
        if (c.zEnded) {
            if (zs.avail_in != 0) return "Junk found after end of compressed data.";
            break;
        }
        zs.next_out = reinterpret_cast<Bytef*>(buf.data());
        zs.avail_out = static_cast<uInt>(kOutChunk);
        int rc = inflate(&zs, Z_NO_FLUSH);
        size_t have = kOutChunk - zs.avail_out;
        switch (rc) {
        case Z_OK:
        case Z_BUF_ERROR:
            break;
        case Z_STREAM_END:
            c.zEnded = true;
            break;
        case Z_NEED_DICT:
            return "A preset dictionary is required to decompress this data.";
        case Z_MEM_ERROR:
            return "Out of memory while decompressing.";
        default:   // Z_DATA_ERROR, Z_STREAM_ERROR
            return zlibMessage(zs, "invalid compressed data");
        }
        if (have) out.emplace_back(buf.data(), have);
        if (c.zEnded) continue;                // check for trailing data
        if (zs.avail_out != 0) break;          // input exhausted; output drained
        // Output buffer full: inflate may hold more; go round again.
    }
    return {};
}

// --- TextEncode -----------------------------------------------------------------

void encodeUnits(CodecState& c, const std::u16string& units, std::string& out) {
    for (char16_t u : units) {
        if (c.pendingHigh) {
            char16_t hi = c.pendingHigh;
            c.pendingHigh = 0;
            if (u >= 0xDC00 && u <= 0xDFFF) {
                uint32_t cp = 0x10000 + ((static_cast<uint32_t>(hi) - 0xD800) << 10) +
                              (static_cast<uint32_t>(u) - 0xDC00);
                appendUtf8(out, cp);
                continue;
            }
            appendUtf8(out, kReplacement);   // lone high surrogate
        }
        if (u >= 0xD800 && u <= 0xDBFF) {
            c.pendingHigh = u;
        } else if (u >= 0xDC00 && u <= 0xDFFF) {
            appendUtf8(out, kReplacement);   // lone low surrogate
        } else {
            appendUtf8(out, u);
        }
    }
}

// --- TextDecode (WHATWG Encoding §4.1 UTF-8 decoder) ------------------------

void emitDecoded(CodecState& c, uint32_t cp, std::string& out) {
    if (!c.bomChecked) {
        c.bomChecked = true;
        if (cp == 0xFEFF) return;   // leading BOM stripped
    }
    appendUtf8(out, cp);
}

void decodeBytes(CodecState& c, const std::string& in, std::string& out) {
    size_t i = 0;
    const size_t n = in.size();
    while (i < n) {
        unsigned char b = static_cast<unsigned char>(in[i]);
        if (c.needed == 0) {
            ++i;
            if (b <= 0x7F) {
                emitDecoded(c, b, out);
            } else if (b >= 0xC2 && b <= 0xDF) {
                c.needed = 1;
                c.cp = b & 0x1F;
            } else if (b >= 0xE0 && b <= 0xEF) {
                if (b == 0xE0) c.lower = 0xA0;
                if (b == 0xED) c.upper = 0x9F;
                c.needed = 2;
                c.cp = b & 0x0F;
            } else if (b >= 0xF0 && b <= 0xF4) {
                if (b == 0xF0) c.lower = 0x90;
                if (b == 0xF4) c.upper = 0x8F;
                c.needed = 3;
                c.cp = b & 0x07;
            } else {
                emitDecoded(c, kReplacement, out);
            }
            continue;
        }
        if (b < c.lower || b > c.upper) {
            // Invalid continuation: replace the maximal subpart and
            // reprocess this byte (do not advance).
            c.cp = 0;
            c.needed = 0;
            c.seen = 0;
            c.lower = 0x80;
            c.upper = 0xBF;
            emitDecoded(c, kReplacement, out);
            continue;
        }
        ++i;
        c.lower = 0x80;
        c.upper = 0xBF;
        c.cp = (c.cp << 6) | (b & 0x3F);
        if (++c.seen == c.needed) {
            uint32_t cp = c.cp;
            c.cp = 0;
            c.needed = 0;
            c.seen = 0;
            emitDecoded(c, cp, out);
        }
    }
}

} // namespace

CodecPtr newZlibCodec(bool compress, int algorithm) {
    CodecPtr c(new CodecState(compress ? CodecKind::Deflate : CodecKind::Inflate));
    int wb = windowBitsFor(algorithm);
    int rc = compress
        ? deflateInit2(&c->zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, wb, 8, Z_DEFAULT_STRATEGY)
        : inflateInit2(&c->zs, wb);
    if (rc != Z_OK) throw std::runtime_error("zlib initialisation failed");
    c->zInit = true;
    return c;
}

CodecPtr newTextEncoder() { return CodecPtr(new CodecState(CodecKind::TextEncode)); }
CodecPtr newTextDecoder() { return CodecPtr(new CodecState(CodecKind::TextDecode)); }

bool codecTakesString(const CodecState& c) { return c.kind == CodecKind::TextEncode; }
bool codecMakesString(const CodecState& c) { return c.kind == CodecKind::TextDecode; }

std::string codecTransform(CodecState& c, const std::string& bytes,
                           const std::u16string& units,
                           std::vector<std::string>& out) {
    switch (c.kind) {
    case CodecKind::Deflate:
    case CodecKind::Inflate: {
        if (c.zFailed) return "The compression stream has failed.";
        if (bytes.empty()) return {};
        std::string err = c.kind == CodecKind::Deflate ? deflateRun(c, bytes, false, out)
                                                       : inflateRun(c, bytes, out);
        if (!err.empty()) c.zFailed = true;
        return err;
    }
    case CodecKind::TextEncode: {
        std::string s;
        encodeUnits(c, units, s);
        if (!s.empty()) out.push_back(std::move(s));
        return {};
    }
    case CodecKind::TextDecode: {
        std::string s;
        decodeBytes(c, bytes, s);
        if (!s.empty()) out.push_back(std::move(s));
        return {};
    }
    }
    return {};
}

std::string codecFlush(CodecState& c, std::vector<std::string>& out) {
    switch (c.kind) {
    case CodecKind::Deflate: {
        if (c.zFailed) return "The compression stream has failed.";
        std::string err = deflateRun(c, std::string(), true, out);
        if (!err.empty()) c.zFailed = true;
        return err;
    }
    case CodecKind::Inflate:
        if (c.zFailed) return "The compression stream has failed.";
        if (!c.zEnded) {
            c.zFailed = true;
            return "Unexpected end of compressed data.";
        }
        return {};
    case CodecKind::TextEncode:
        if (c.pendingHigh) {
            c.pendingHigh = 0;
            std::string s;
            appendUtf8(s, kReplacement);
            out.push_back(std::move(s));
        }
        return {};
    case CodecKind::TextDecode:
        if (c.needed != 0) {
            c.cp = 0;
            c.needed = 0;
            c.seen = 0;
            c.lower = 0x80;
            c.upper = 0xBF;
            std::string s;
            emitDecoded(c, kReplacement, s);
            if (!s.empty()) out.push_back(std::move(s));
        }
        return {};
    }
    return {};
}

} // namespace Eco::System
