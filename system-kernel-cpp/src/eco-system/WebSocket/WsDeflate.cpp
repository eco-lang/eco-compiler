//===- WsDeflate.cpp - permessage-deflate engine (RFC 7692) ---------------===//
//
// See WsDeflate.hpp (plans/eco-system-websockets.md §3.7). zlib directly;
// no IO, no heap access (G1).
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsDeflate.hpp"

#include <zlib.h>

#include <algorithm>
#include <cstring>

namespace Eco::System {

namespace ws {

namespace {

constexpr size_t kDeflateStep = 64 * 1024;
constexpr unsigned char kTail[4] = {0x00, 0x00, 0xff, 0xff};

} // namespace

// --- Deflater ---------------------------------------------------------------------

struct Deflater::Z {
    z_stream s{};
    bool init = false;
};

Deflater::Deflater(int windowBits, bool noContextTakeover)
    : z_(std::make_unique<Z>()), bits_(std::clamp(windowBits, 9, 15)), noContext_(noContextTakeover) {}

Deflater::~Deflater() {
    if (z_ && z_->init) deflateEnd(&z_->s);
}

bool Deflater::chunk(const char* p, size_t n, std::string& out) {
    Z& z = *z_;
    if (!z.init) {
        if (deflateInit2(&z.s, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -bits_, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
            return false;
        }
        z.init = true;
    }
    z.s.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(p));
    z.s.avail_in = static_cast<uInt>(n);
    for (;;) {
        size_t old = out.size();
        out.resize(old + kDeflateStep);
        z.s.next_out = reinterpret_cast<Bytef*>(&out[old]);
        z.s.avail_out = static_cast<uInt>(kDeflateStep);
        int r = deflate(&z.s, Z_SYNC_FLUSH);
        out.resize(old + (kDeflateStep - z.s.avail_out));
        if (r == Z_BUF_ERROR) return true;   // nothing to do (a repeated flush with no input)
        if (r != Z_OK) return false;
        if (z.s.avail_out != 0 && z.s.avail_in == 0) return true;
    }
}

bool Deflater::message(const char* p, size_t n, std::string& out) {
    size_t start = out.size();
    if (!chunk(p, n, out)) return false;
    size_t len = out.size() - start;
    if (len >= 4 && std::memcmp(out.data() + out.size() - 4, kTail, 4) == 0) out.resize(out.size() - 4);
    if (out.size() == start) out.push_back('\0');   // an empty message (§7.2.3.6)
    endMessage();
    return true;
}

void Deflater::endMessage() {
    if (noContext_ && z_->init) deflateReset(&z_->s);
}

// --- Inflater ---------------------------------------------------------------------

struct Inflater::Z {
    z_stream s{};
    bool init = false;
};

Inflater::Inflater(bool noContextTakeover) : z_(std::make_unique<Z>()), noContext_(noContextTakeover) {}

Inflater::~Inflater() {
    if (z_ && z_->init) inflateEnd(&z_->s);
}

bool Inflater::ensure() {
    if (z_->init) return true;
    if (inflateInit2(&z_->s, -15) != Z_OK) return false;
    z_->init = true;
    return true;
}

void Inflater::push(const char* p, size_t n) {
    if (inOff_ > 0 && inOff_ >= in_.size()) {
        in_.clear();
        inOff_ = 0;
    } else if (inOff_ > 64 * 1024 && inOff_ * 2 > in_.size()) {
        in_.erase(0, inOff_);
        inOff_ = 0;
    }
    in_.append(p, n);
}

void Inflater::finish() {
    in_.append(reinterpret_cast<const char*>(kTail), 4);
    finished_ = true;
}

// A new raw stream; with `keepWindow` the last 32 KiB of output stay usable
// as back-references (BFINAL inside a message, or context takeover).
void Inflater::resetStream(bool keepWindow) {
    if (!z_->init) return;
    if (!keepWindow) {
        inflateReset(&z_->s);
        return;
    }
    unsigned char dict[32768];
    uInt len = sizeof dict;
    if (inflateGetDictionary(&z_->s, dict, &len) != Z_OK) len = 0;
    inflateReset(&z_->s);
    if (len > 0) inflateSetDictionary(&z_->s, dict, len);
}

void Inflater::abandonMessage() {
    in_.clear();
    inOff_ = 0;
    finished_ = false;
    sawFinal_ = false;
    if (z_->init) inflateReset(&z_->s);
}

Inflater::Step Inflater::step(std::string& out, size_t maxOut) {
    if (!ensure()) {
        err_ = "out of memory";
        return Step::Error;
    }
    if (maxOut == 0 || maxOut > kInflateStep) maxOut = kInflateStep;
    for (;;) {
        if (inOff_ >= in_.size()) {
            in_.clear();
            inOff_ = 0;
            if (!finished_) return Step::NeedInput;
            // The message is complete: the next one starts on a clean stream
            // (no context takeover), or after a final block with the window kept.
            if (noContext_) resetStream(false);
            else if (sawFinal_) resetStream(true);
            finished_ = false;
            sawFinal_ = false;
            return Step::Done;
        }
        size_t avail = in_.size() - inOff_;
        size_t old = out.size();
        out.resize(old + maxOut);
        z_stream& s = z_->s;
        s.next_in = reinterpret_cast<Bytef*>(&in_[inOff_]);
        s.avail_in = static_cast<uInt>(std::min<size_t>(avail, 1u << 30));
        uInt given = s.avail_in;
        s.next_out = reinterpret_cast<Bytef*>(&out[old]);
        s.avail_out = static_cast<uInt>(maxOut);
        int r = inflate(&s, Z_SYNC_FLUSH);
        size_t produced = maxOut - s.avail_out;
        size_t consumed = given - s.avail_in;
        out.resize(old + produced);
        inOff_ += consumed;
        if (r == Z_STREAM_END) {
            // A block with BFINAL (§7.2.3.4): what follows is a new stream
            // that may refer back into this one.
            sawFinal_ = true;
            resetStream(true);
            if (produced > 0) return Step::Output;
            continue;
        }
        if (r == Z_OK || (r == Z_BUF_ERROR && produced > 0)) {
            if (produced > 0) return Step::Output;
            if (consumed > 0) continue;
        }
        err_ = s.msg ? s.msg : "invalid compressed data";
        return Step::Error;
    }
}

} // namespace ws

} // namespace Eco::System
