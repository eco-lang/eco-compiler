//===- WsFrame.hpp - RFC 6455 frame codec (pure) --------------------------===//
//
// plans/eco-system-websockets.md §3.6 "C++ codec", Appendix D.1, D.4, D.5,
// D.8. The byte-level part of the WebSocket codec, with no IO and no heap
// access (G1), so it is unit-tested directly (test/eco-system-core):
//
//   * WsDecoder: an incremental frame parser. Bytes go in as they arrive
//     (any split); out come whole data messages (Whole mode: reassembled
//     from fragments, at most maxMessage bytes, text validated as UTF-8
//     incrementally and failing at the first bad byte, even inside a frame
//     that has not fully arrived) and control frames (ping, pong, close;
//     payload <= 125, FIN set, may arrive between fragments). Every rule of
//     D.1 is checked from the frame header, before any payload is buffered:
//     reserved opcodes, RSV bits (RSV1 only on the first frame of a data
//     message when deflate is negotiated: WS7), masking direction, control
//     frame length and FIN, 64-bit lengths with the MSB set, continuation
//     without a message, a data frame inside a message, and the message size
//     (1009). A violation stops the decoder: failCode() (1002, 1007, 1009)
//     and failText() say why. Non-minimal length encodings are accepted.
//   * Raw data mode (setRawData, WS6/WS7: streamed messages, and every
//     message once permessage-deflate is negotiated): data messages are not
//     assembled or UTF-8-checked here; the sink gets onDataStart(opcode,
//     compressed), the unmasked payload bytes of each frame as they arrive
//     (onDataChunk, any split) and onDataEnd() after the FIN frame. The
//     message size is still checked from each frame header against
//     maxMessage, except for compressed messages (their size is the
//     inflated one, the sink's business).
//   * RSV1 (setAllowRsv1, WS7): allowed on the first frame of a data message
//     once permessage-deflate is negotiated (the message is compressed);
//     on a continuation or control frame, or without deflate, it is 1002.
//   * Discarding (cancelReadable, after our Close): data frames are still
//     parsed and their headers checked (so the stream stays in sync), but
//     their payload is skipped (no buffering, size or UTF-8 checks) and no
//     message is delivered; control frames are delivered as usual.
//   * frameHeader / applyMask: the serializer (client frames masked with a
//     4-byte key; server frames never).
//   * Utf8Validator: incremental strict UTF-8 (no overlongs, surrogates or
//     code points above U+10FFFF), which also reports whether the input
//     ended inside a sequence.
//   * parseClose / closeCodeValidOnReceipt / closeCodeSendable: D.5.
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_FRAME_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_FRAME_HPP

#include <cstddef>
#include <cstdint>
#include <string>

namespace Eco::System {

namespace ws {

constexpr uint8_t kOpContinuation = 0x0;
constexpr uint8_t kOpText = 0x1;
constexpr uint8_t kOpBinary = 0x2;
constexpr uint8_t kOpClose = 0x8;
constexpr uint8_t kOpPing = 0x9;
constexpr uint8_t kOpPong = 0xA;

constexpr size_t kMaxControlPayload = 125;

// Close codes (W14).
constexpr int kCloseNormal = 1000;
constexpr int kCloseGoingAway = 1001;
constexpr int kCloseProtocolError = 1002;
constexpr int kCloseNoStatus = 1005;
constexpr int kCloseAbnormal = 1006;
constexpr int kCloseInvalidData = 1007;
constexpr int kCloseMessageTooBig = 1009;
constexpr int kCloseInternalError = 1011;

// D.5: valid in a received Close frame: 1000-1003, 1007-1014, 3000-4999.
bool closeCodeValidOnReceipt(int code);
// W14: what `close` may send (the same set).
inline bool closeCodeSendable(int code) { return closeCodeValidOnReceipt(code); }

// Incremental strict UTF-8 validation (fail fast).
class Utf8Validator {
public:
    // False at the first invalid byte (the validator then stays failed).
    bool feed(const unsigned char* p, size_t n);
    // True if the input so far ends on a character boundary.
    bool complete() const { return need_ == 0 && !failed_; }
    bool failed() const { return failed_; }
    void reset() { need_ = 0; lo_ = 0x80; hi_ = 0xBF; failed_ = false; }

private:
    int need_ = 0;                  // continuation bytes still expected
    unsigned char lo_ = 0x80, hi_ = 0xBF;   // range of the next continuation byte
    bool failed_ = false;
};

// True iff `s` is complete, strict UTF-8.
bool validUtf8(const std::string& s);

// The longest prefix of `s` that ends on a UTF-8 character boundary and is at
// most `limit` bytes (`s` is assumed valid).
std::string truncateUtf8(const std::string& s, size_t limit);

// A frame header for `payloadLen` bytes. `mask` (4 bytes) or null; the
// payload that follows must then be masked with applyMask.
std::string frameHeader(bool fin, uint8_t opcode, bool rsv1, uint64_t payloadLen,
                        const unsigned char* mask);

// XORs `n` bytes with `mask`, starting at mask offset `offset` (mod 4).
void applyMask(char* data, size_t n, const unsigned char mask[4], size_t offset);

// A whole frame (header + masked payload when `mask` is non-null).
std::string encodeFrame(bool fin, uint8_t opcode, const char* payload, size_t n,
                        const unsigned char* mask);
// The same with RSV1 (the first frame of a compressed message, WS7).
std::string encodeFrame(bool fin, uint8_t opcode, bool rsv1, const char* payload, size_t n,
                        const unsigned char* mask);

// The length of the longest prefix of `s` that ends on a UTF-8 character
// boundary (`s` is valid UTF-8 so far, possibly cut inside a character).
size_t utf8CompletePrefix(const char* s, size_t n);

// The payload of a Close frame: empty (code 0) or code + reason.
std::string closePayload(int code, const std::string& reason);

// D.5: parses a received Close payload. On success `code` is the code (1005
// for an empty payload) and `reason` the reason; on failure `failCode` is
// 1002 (one byte, invalid code) or 1007 (reason not UTF-8) and `failText`
// says why.
bool parseClose(const std::string& payload, int& code, std::string& reason, int& failCode,
                std::string& failText);

// --- The decoder ---------------------------------------------------------------

class WsDecoder {
public:
    struct Sink {
        virtual ~Sink() = default;
        // A whole data message (opcode kOpText / kOpBinary).
        virtual void onMessage(uint8_t opcode, std::string&& payload) = 0;
        // A control frame (kOpClose / kOpPing / kOpPong), FIN set, <= 125 bytes.
        virtual void onControl(uint8_t opcode, std::string&& payload) = 0;
        // Raw data mode only (setRawData): a data message starts (its first
        // frame header was checked; `compressed`: RSV1 was set), its unmasked
        // payload bytes in order, and its end (after the FIN frame).
        virtual void onDataStart(uint8_t /*opcode*/, bool /*compressed*/) {}
        virtual void onDataChunk(const char* /*data*/, size_t /*n*/) {}
        virtual void onDataEnd() {}
    };

    // `expectMasked`: the server side (client frames must be masked; server
    // frames must not). `maxMessage`: the largest message (Whole mode).
    WsDecoder(bool expectMasked, uint64_t maxMessage)
        : expectMasked_(expectMasked), maxMessage_(maxMessage) {}

    // Parses `n` bytes, calling the sink for every complete message and
    // control frame. Returns the number of bytes consumed: all of them, or
    // fewer when the decoder failed or a sink callback asked it to stop
    // (stop()). Bytes after a stop are the caller's to feed again.
    size_t feed(const char* data, size_t n, Sink& sink);

    // Called from a sink callback: feed() returns after the current frame.
    void stop() { stopped_ = true; }

    // Raw data mode (see the header comment). Set before the first feed.
    void setRawData(bool on) { raw_ = on; }
    // RSV1 allowed on the first frame of a data message (permessage-deflate).
    void setAllowRsv1(bool on) { allowRsv1_ = on; }

    // Data frames are parsed (headers checked) but their payload is skipped
    // and no message reaches the sink (control frames still do). Drops a
    // message in progress.
    void setDiscardData(bool on);
    bool discardingData() const { return discard_; }

    bool failed() const { return failCode_ != 0; }
    int failCode() const { return failCode_; }
    const std::string& failText() const { return failText_; }

    // Bytes of the data message being assembled (0 between messages).
    uint64_t messageBytes() const { return msgSize_; }
    bool inMessage() const { return inMessage_; }

private:
    bool fail(int code, const char* text);
    bool startFrame();

    // Configuration.
    bool expectMasked_;
    uint64_t maxMessage_;
    bool raw_ = false;
    bool allowRsv1_ = false;

    // Header accumulation (2..14 bytes).
    unsigned char hdr_[14] = {};
    size_t hdrHave_ = 0;
    bool inPayload_ = false;

    // The current frame.
    bool fin_ = false;
    uint8_t opcode_ = 0;
    bool masked_ = false;
    unsigned char mask_[4] = {};
    uint64_t remaining_ = 0;
    uint64_t maskOffset_ = 0;
    bool frameIsControl_ = false;
    std::string control_;           // control payload so far

    // The data message.
    bool inMessage_ = false;
    bool msgCompressed_ = false;    // raw mode: RSV1 on its first frame
    std::string scratch_;           // raw mode: an unmasked payload chunk
    uint8_t msgOpcode_ = 0;
    uint64_t msgSize_ = 0;
    std::string message_;
    Utf8Validator utf8_;

    bool discard_ = false;
    bool stopped_ = false;
    int failCode_ = 0;
    std::string failText_;
};

} // namespace ws

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_FRAME_HPP
