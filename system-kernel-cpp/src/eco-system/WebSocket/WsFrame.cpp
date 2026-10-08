//===- WsFrame.cpp - RFC 6455 frame codec (pure) --------------------------===//
//
// See WsFrame.hpp (plans/eco-system-websockets.md Appendix D.1, D.4, D.5,
// D.8). No IO, no heap access (G1).
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#include "eco-system/WebSocket/WsFrame.hpp"

#include <algorithm>
#include <cstring>

namespace Eco::System {

namespace ws {

bool closeCodeValidOnReceipt(int code) {
    return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) ||
           (code >= 3000 && code <= 4999);
}

// --- UTF-8 -------------------------------------------------------------------------

bool Utf8Validator::feed(const unsigned char* p, size_t n) {
    if (failed_) return false;
    for (size_t i = 0; i < n; ++i) {
        unsigned char b = p[i];
        if (need_ == 0) {
            if (b < 0x80) continue;
            if (b >= 0xC2 && b <= 0xDF) {
                need_ = 1; lo_ = 0x80; hi_ = 0xBF;
            } else if (b == 0xE0) {
                need_ = 2; lo_ = 0xA0; hi_ = 0xBF;
            } else if ((b >= 0xE1 && b <= 0xEC) || b == 0xEE || b == 0xEF) {
                need_ = 2; lo_ = 0x80; hi_ = 0xBF;
            } else if (b == 0xED) {
                need_ = 2; lo_ = 0x80; hi_ = 0x9F;   // no surrogates
            } else if (b == 0xF0) {
                need_ = 3; lo_ = 0x90; hi_ = 0xBF;   // no overlongs
            } else if (b >= 0xF1 && b <= 0xF3) {
                need_ = 3; lo_ = 0x80; hi_ = 0xBF;
            } else if (b == 0xF4) {
                need_ = 3; lo_ = 0x80; hi_ = 0x8F;   // <= U+10FFFF
            } else {
                failed_ = true;
                return false;
            }
            continue;
        }
        if (b < lo_ || b > hi_) {
            failed_ = true;
            return false;
        }
        --need_;
        lo_ = 0x80;
        hi_ = 0xBF;
    }
    return true;
}

bool validUtf8(const std::string& s) {
    Utf8Validator v;
    return v.feed(reinterpret_cast<const unsigned char*>(s.data()), s.size()) && v.complete();
}

std::string truncateUtf8(const std::string& s, size_t limit) {
    if (s.size() <= limit) return s;
    size_t cut = limit;
    while (cut > 0 && (static_cast<unsigned char>(s[cut]) & 0xC0) == 0x80) --cut;
    return s.substr(0, cut);
}

size_t utf8CompletePrefix(const char* s, size_t n) {
    // Look back at most 3 bytes for the lead byte of an unfinished character.
    size_t i = n;
    for (size_t back = 0; back < 4 && i > 0; ++back) {
        unsigned char c = static_cast<unsigned char>(s[i - 1]);
        if ((c & 0xC0) == 0x80) {   // a continuation byte: keep looking
            --i;
            continue;
        }
        size_t len = c < 0x80 ? 1 : (c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : 2));
        size_t have = n - (i - 1);
        return have >= len ? n : i - 1;
    }
    return n;
}

// --- Serializer ----------------------------------------------------------------------

std::string frameHeader(bool fin, uint8_t opcode, bool rsv1, uint64_t payloadLen,
                        const unsigned char* mask) {
    std::string h;
    h.reserve(14);
    h.push_back(static_cast<char>((fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | (opcode & 0x0F)));
    unsigned char maskBit = mask ? 0x80 : 0;
    if (payloadLen < 126) {
        h.push_back(static_cast<char>(maskBit | static_cast<unsigned char>(payloadLen)));
    } else if (payloadLen <= 0xFFFF) {
        h.push_back(static_cast<char>(maskBit | 126));
        h.push_back(static_cast<char>((payloadLen >> 8) & 0xFF));
        h.push_back(static_cast<char>(payloadLen & 0xFF));
    } else {
        h.push_back(static_cast<char>(maskBit | 127));
        for (int i = 7; i >= 0; --i) h.push_back(static_cast<char>((payloadLen >> (8 * i)) & 0xFF));
    }
    if (mask) h.append(reinterpret_cast<const char*>(mask), 4);
    return h;
}

void applyMask(char* data, size_t n, const unsigned char mask[4], size_t offset) {
    for (size_t i = 0; i < n; ++i) data[i] = static_cast<char>(data[i] ^ mask[(offset + i) & 3]);
}

std::string encodeFrame(bool fin, uint8_t opcode, const char* payload, size_t n,
                        const unsigned char* mask) {
    return encodeFrame(fin, opcode, false, payload, n, mask);
}

std::string encodeFrame(bool fin, uint8_t opcode, bool rsv1, const char* payload, size_t n,
                        const unsigned char* mask) {
    std::string f = frameHeader(fin, opcode, rsv1, n, mask);
    size_t start = f.size();
    f.append(payload, n);
    if (mask) applyMask(&f[start], n, mask, 0);
    return f;
}

std::string closePayload(int code, const std::string& reason) {
    std::string p;
    if (code == 0) return p;
    p.push_back(static_cast<char>((code >> 8) & 0xFF));
    p.push_back(static_cast<char>(code & 0xFF));
    p += truncateUtf8(reason, kMaxControlPayload - 2);
    return p;
}

bool parseClose(const std::string& payload, int& code, std::string& reason, int& failCode,
                std::string& failText) {
    if (payload.empty()) {
        code = kCloseNoStatus;
        reason.clear();
        return true;
    }
    if (payload.size() == 1) {
        failCode = kCloseProtocolError;
        failText = "a Close frame with a 1-byte payload";
        return false;
    }
    int c = (static_cast<unsigned char>(payload[0]) << 8) | static_cast<unsigned char>(payload[1]);
    if (!closeCodeValidOnReceipt(c)) {
        failCode = kCloseProtocolError;
        failText = "invalid close code " + std::to_string(c);
        return false;
    }
    std::string r = payload.substr(2);
    if (!validUtf8(r)) {
        failCode = kCloseInvalidData;
        failText = "the close reason is not valid UTF-8";
        return false;
    }
    code = c;
    reason = std::move(r);
    return true;
}

// --- Decoder ---------------------------------------------------------------------------

bool WsDecoder::fail(int code, const char* text) {
    if (failCode_ == 0) {
        failCode_ = code;
        failText_ = text;
    }
    return false;
}

void WsDecoder::setDiscardData(bool on) {
    discard_ = on;
    if (on) {
        message_.clear();
        message_.shrink_to_fit();
    }
}

// The header in hdr_ is complete: decode and check it (D.1).
bool WsDecoder::startFrame() {
    unsigned char b0 = hdr_[0], b1 = hdr_[1];
    fin_ = (b0 & 0x80) != 0;
    bool rsv1 = (b0 & 0x40) != 0, rsv2 = (b0 & 0x20) != 0, rsv3 = (b0 & 0x10) != 0;
    opcode_ = b0 & 0x0F;
    masked_ = (b1 & 0x80) != 0;
    uint64_t len = b1 & 0x7F;
    size_t at = 2;
    if (len == 126) {
        len = (static_cast<uint64_t>(hdr_[2]) << 8) | hdr_[3];
        at = 4;
    } else if (len == 127) {
        len = 0;
        for (int i = 0; i < 8; ++i) len = (len << 8) | hdr_[2 + i];
        at = 10;
        if (len & (1ULL << 63)) return fail(kCloseProtocolError, "a 64-bit length with the most significant bit set");
    }
    if (masked_) std::memcpy(mask_, hdr_ + at, 4);

    if (rsv2 || rsv3) return fail(kCloseProtocolError, "RSV2 or RSV3 is set");
    // RSV1 means "compressed" (permessage-deflate, RFC 7692 §6): only on the
    // first frame of a data message, and only once deflate is negotiated.
    if (rsv1 && !allowRsv1_) return fail(kCloseProtocolError, "RSV1 is set without a negotiated extension");
    bool known = opcode_ == kOpContinuation || opcode_ == kOpText || opcode_ == kOpBinary ||
                 opcode_ == kOpClose || opcode_ == kOpPing || opcode_ == kOpPong;
    if (!known) return fail(kCloseProtocolError, "a reserved opcode");
    if (masked_ != expectMasked_) {
        return fail(kCloseProtocolError,
                    expectMasked_ ? "an unmasked client frame" : "a masked server frame");
    }
    frameIsControl_ = opcode_ >= 0x8;
    if (rsv1 && (frameIsControl_ || opcode_ == kOpContinuation)) {
        return fail(kCloseProtocolError, frameIsControl_ ? "RSV1 is set on a control frame"
                                                         : "RSV1 is set on a continuation frame");
    }
    if (frameIsControl_) {
        if (!fin_) return fail(kCloseProtocolError, "a fragmented control frame");
        if (len > kMaxControlPayload) return fail(kCloseProtocolError, "a control frame longer than 125 bytes");
        control_.clear();
    } else if (opcode_ == kOpContinuation) {
        if (!inMessage_) return fail(kCloseProtocolError, "a continuation frame without a message in progress");
    } else {
        if (inMessage_) return fail(kCloseProtocolError, "a new data frame inside a fragmented message");
        inMessage_ = true;
        msgOpcode_ = opcode_;
        msgCompressed_ = rsv1;
        msgSize_ = 0;
        message_.clear();
        utf8_.reset();
    }
    if (!frameIsControl_) {
        // A compressed message's size is its inflated size (the sink checks it).
        bool checkSize = !discard_ && !(raw_ && msgCompressed_);
        if (checkSize && len > maxMessage_ - std::min(msgSize_, maxMessage_)) {
            return fail(kCloseMessageTooBig, "the message is larger than maxMessageSize");
        }
        msgSize_ += len;
        if (!discard_ && !raw_ && len > 0) message_.reserve(static_cast<size_t>(msgSize_));
    }
    remaining_ = len;
    maskOffset_ = 0;
    return true;
}

size_t WsDecoder::feed(const char* data, size_t n, Sink& sink) {
    stopped_ = false;
    size_t pos = 0;
    while (!failed() && !stopped_) {
        if (!inPayload_) {
            // Header: 2 bytes, then the extended length and the mask key.
            size_t need = 2;
            if (hdrHave_ >= 2) {
                unsigned char len7 = hdr_[1] & 0x7F;
                need = 2 + (len7 == 126 ? 2 : len7 == 127 ? 8 : 0) + ((hdr_[1] & 0x80) ? 4 : 0);
            }
            if (hdrHave_ < need) {
                if (pos >= n) break;
                size_t take = std::min(need - hdrHave_, n - pos);
                std::memcpy(hdr_ + hdrHave_, data + pos, take);
                hdrHave_ += take;
                pos += take;
                continue;   // recompute `need` once 2 bytes are in
            }
            hdrHave_ = 0;
            bool wasInMessage = inMessage_;
            if (!startFrame()) break;
            inPayload_ = true;
            if (raw_ && !discard_ && !frameIsControl_ && !wasInMessage) {
                sink.onDataStart(msgOpcode_, msgCompressed_);
                if (failed()) break;
            }
        }
        if (remaining_ > 0) {
            if (pos >= n) break;
            size_t take = static_cast<size_t>(std::min<uint64_t>(remaining_, n - pos));
            const char* rawChunk = nullptr;
            if (frameIsControl_) {
                size_t at = control_.size();
                control_.append(data + pos, take);
                if (masked_) applyMask(&control_[at], take, mask_, static_cast<size_t>(maskOffset_));
            } else if (!discard_ && raw_) {
                rawChunk = data + pos;
                if (masked_) {
                    scratch_.assign(data + pos, take);
                    applyMask(&scratch_[0], take, mask_, static_cast<size_t>(maskOffset_));
                    rawChunk = scratch_.data();
                }
            } else if (!discard_) {
                size_t at = message_.size();
                message_.append(data + pos, take);
                if (masked_) applyMask(&message_[at], take, mask_, static_cast<size_t>(maskOffset_));
                if (msgOpcode_ == kOpText &&
                    !utf8_.feed(reinterpret_cast<const unsigned char*>(message_.data() + at), take)) {
                    fail(kCloseInvalidData, "invalid UTF-8 in a text message");
                    pos += take;
                    break;
                }
            }
            pos += take;
            remaining_ -= take;
            maskOffset_ += take;
            if (rawChunk) {
                sink.onDataChunk(rawChunk, take);
                if (failed()) break;
            }
            if (remaining_ > 0) break;   // all input used
        }
        // The frame is complete.
        inPayload_ = false;
        if (frameIsControl_) {
            std::string payload;
            payload.swap(control_);
            sink.onControl(opcode_, std::move(payload));
            continue;
        }
        if (!fin_) continue;
        inMessage_ = false;
        uint8_t op = msgOpcode_;
        msgSize_ = 0;
        if (discard_) continue;
        if (raw_) {
            sink.onDataEnd();
            continue;
        }
        if (op == kOpText && !utf8_.complete()) {
            fail(kCloseInvalidData, "invalid UTF-8 in a text message");
            break;
        }
        std::string payload;
        payload.swap(message_);
        sink.onMessage(op, std::move(payload));
    }
    return pos;
}

} // namespace ws

} // namespace Eco::System
