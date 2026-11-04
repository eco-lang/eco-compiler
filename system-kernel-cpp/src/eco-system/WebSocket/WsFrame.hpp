//===- WsFrame.hpp - RFC 6455 frame codec (pure) --------------------------===//
//
// A WebSocket connection carries a stream of frames, and this component is the part of the protocol that
// works on bytes alone: turning received bytes into messages, and messages into bytes to send. It does no
// IO and touches no Elm heap, so it can be driven and tested with plain strings.
//
// The wire format (RFC 6455) is a sequence of frames. Each frame has a 2- to 14-byte header (FIN bit, three
// RSV bits, a 4-bit opcode, a mask bit, a 7-, 16- or 64-bit payload length and, if masked, a 4-byte mask
// key) followed by its payload. A *data message* (text or binary) is one frame, or a first frame followed by
// continuation frames, the last of which has FIN set. *Control frames* (Close, Ping, Pong) are never
// fragmented, carry at most 125 bytes, and may arrive between the fragments of a data message. Frames sent
// by a client are masked: each payload byte is XORed with the mask key, cycling through its four bytes.
// Frames sent by a server are not.
//
// The component holds:
//
//   * `WsDecoder`, an incremental frame parser. Bytes are fed in as they arrive, split anywhere, and a
//     `WsDecoder::Sink` is called for each control frame and each data message. Every header rule is
//     checked as soon as the header is complete, before any of its payload is taken: reserved opcodes,
//     RSV bits, the masking direction, the length and FIN of control frames, a 64-bit length with its top
//     bit set, a continuation with no message in progress, a new data frame inside a message, and the
//     message size limit. The first violation stops the decoder for good; its *fail code* is the close
//     code to send (1002 protocol error, 1007 invalid data, 1009 message too big). Non-minimal length
//     encodings are accepted.
//   * The serializer: `frameHeader`, `applyMask` and `encodeFrame`.
//   * Strict UTF-8 checking (`Utf8Validator`, `validUtf8`) and cutting at character boundaries
//     (`truncateUtf8`, `utf8CompletePrefix`).
//   * Close frame payloads: `closePayload`, `parseClose`, and the close code rules.
//
// The decoder has three ways of handling data frames. In *Whole mode*, the default, it reassembles each
// message, checks a text message's UTF-8 as the bytes arrive (failing at the first bad byte, even before
// the frame is complete), and delivers it with `onMessage`. In *raw data mode* (`setRawData`) it neither
// assembles nor checks UTF-8: it reports the start of each message, its unmasked payload bytes as they
// arrive, and its end. Raw mode is what a caller needs for streamed messages and for compressed ones
// (permessage-deflate, RFC 7692, which marks the first frame of a compressed message with RSV1). In
// *discarding* (`setDiscardData`) data frame headers are still checked, so the stream stays in step, but
// their payload is skipped and nothing about data messages reaches the sink. Control frames are delivered
// in every mode.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_FRAME_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_FRAME_HPP

#include <cstddef>
#include <cstdint>
#include <string>

namespace Eco::System {

namespace ws {

/// The opcode of a frame that continues the data message in progress.
constexpr uint8_t kOpContinuation = 0x0;
/// The opcode of the first frame of a text message, whose payload must be UTF-8.
constexpr uint8_t kOpText = 0x1;
/// The opcode of the first frame of a binary message.
constexpr uint8_t kOpBinary = 0x2;
/// The opcode of a Close frame. Opcodes 0x8 and above are control frames.
constexpr uint8_t kOpClose = 0x8;
/// The opcode of a Ping frame.
constexpr uint8_t kOpPing = 0x9;
/// The opcode of a Pong frame.
constexpr uint8_t kOpPong = 0xA;

/// The largest payload, in bytes, a control frame may carry.
constexpr size_t kMaxControlPayload = 125;

// Close codes.

/// The close code for a normal closure.
constexpr int kCloseNormal = 1000;
/// The close code for an endpoint going away.
constexpr int kCloseGoingAway = 1001;
/// The close code for a protocol violation.
constexpr int kCloseProtocolError = 1002;
/// The code that stands for a Close frame with no code. `closeCodeSendable` rejects it.
constexpr int kCloseNoStatus = 1005;
/// The code that stands for a connection ended without a Close frame. `closeCodeSendable` rejects it.
constexpr int kCloseAbnormal = 1006;
/// The close code for data inconsistent with its type, such as a text message that is not UTF-8.
constexpr int kCloseInvalidData = 1007;
/// The close code for a message larger than the receiver accepts.
constexpr int kCloseMessageTooBig = 1009;
/// The close code for an unexpected condition in the endpoint.
constexpr int kCloseInternalError = 1011;

/// Returns whether `code` may appear in a received Close frame: 1000-1003, 1007-1014 or 3000-4999.
bool closeCodeValidOnReceipt(int code);
/// Returns whether `code` may be sent in a Close frame. The set is the one `closeCodeValidOnReceipt` accepts.
inline bool closeCodeSendable(int code) { return closeCodeValidOnReceipt(code); }

/// A strict UTF-8 check over input that arrives in pieces.
///
/// Strict means overlong encodings, surrogates (U+D800 to U+DFFF) and code points above U+10FFFF are
/// rejected. The validator remembers how much of an unfinished character it has seen, so a character may be
/// split across calls to `feed`. Once it has seen an invalid byte it stays failed until `reset`. A
/// default-constructed validator is at the start of the input.
class Utf8Validator {
public:
    /// Checks the next `n` bytes at `p`, and returns false if they, or any earlier input, contain an invalid
    /// byte. Checking stops at the first invalid byte. A true result does not mean the input is complete.
    bool feed(const unsigned char* p, size_t n);
    /// Returns whether the input so far is valid and ends on a character boundary.
    bool complete() const { return need_ == 0 && !failed_; }
    /// Returns whether an invalid byte has been seen since construction or the last `reset`.
    bool failed() const { return failed_; }
    /// Returns the validator to the start of a new input.
    void reset() { need_ = 0; lo_ = 0x80; hi_ = 0xBF; failed_ = false; }

private:
    int need_ = 0;                          ///< Continuation bytes still expected.
    unsigned char lo_ = 0x80, hi_ = 0xBF;   ///< Range allowed for the next continuation byte.
    bool failed_ = false;
};

/// Returns whether `s` is valid, strict UTF-8 that does not end inside a character.
bool validUtf8(const std::string& s);

/// Returns the longest prefix of `s` that is at most `limit` bytes and ends on a UTF-8 character boundary.
///
/// `s` must be valid UTF-8; the cut is found by stepping back over continuation bytes only.
std::string truncateUtf8(const std::string& s, size_t limit);

/// Returns the header of a frame with the given FIN bit, opcode and RSV1 bit and a payload of `payloadLen`
/// bytes, using the shortest length encoding.
///
/// `mask` is null for an unmasked frame, or points to the 4-byte mask key, which is written into the header
/// and must be applied to the payload with `applyMask` from offset 0.
std::string frameHeader(bool fin, uint8_t opcode, bool rsv1, uint64_t payloadLen,
                        const unsigned char* mask);

/// XORs the `n` bytes at `data` in place with the mask key `mask`, as if `data` began `offset` bytes into
/// the payload. Applying the same mask twice restores the bytes.
void applyMask(char* data, size_t n, const unsigned char mask[4], size_t offset);

/// Returns a complete frame with RSV1 clear: the header and the `n` bytes at `payload`, masked with the
/// 4-byte key at `mask` unless `mask` is null.
std::string encodeFrame(bool fin, uint8_t opcode, const char* payload, size_t n,
                        const unsigned char* mask);
/// Returns a complete frame as the overload without `rsv1` does, with RSV1 set when `rsv1` is true. RSV1
/// marks the first frame of a compressed message.
std::string encodeFrame(bool fin, uint8_t opcode, bool rsv1, const char* payload, size_t n,
                        const unsigned char* mask);

/// Returns the length of the longest prefix of the `n` bytes at `s` that does not end inside a UTF-8
/// character.
///
/// The bytes must be valid UTF-8 apart from possibly ending inside a character; only the last character is
/// examined.
size_t utf8CompletePrefix(const char* s, size_t n);

/// Returns the payload of a Close frame: empty if `code` is 0, and otherwise `code` as two big-endian bytes
/// followed by `reason`, cut at a character boundary to fit in 125 bytes. `code` is not checked.
std::string closePayload(int code, const std::string& reason);

/// Parses the payload of a received Close frame, and returns whether it is valid.
///
/// On success `code` and `reason` are written (an empty payload gives `kCloseNoStatus` and an empty reason)
/// and the fail outputs are untouched. On failure `failCode` is `kCloseProtocolError` for a one-byte payload
/// or a code `closeCodeValidOnReceipt` rejects, or `kCloseInvalidData` for a reason that is not UTF-8;
/// `failText` says which, and `code` and `reason` are untouched.
bool parseClose(const std::string& payload, int& code, std::string& reason, int& failCode,
                std::string& failText);

// --- The decoder ---------------------------------------------------------------

/// An incremental parser of a received WebSocket byte stream, in one direction of one connection.
///
/// Bytes go in through `feed` in pieces of any size, and the sink is called for each complete control frame
/// and, depending on the mode, for each data message or its pieces. The modes (Whole, raw data, discarding)
/// are described at the top of this file. The decoder checks every header rule there before taking a
/// frame's payload. Its first violation, or invalid UTF-8 in a Whole-mode text message, fails it: `failed`
/// becomes true, `failCode` and `failText` say why, and every later `feed` consumes nothing.
class WsDecoder {
public:
    /// The receiver of what a `WsDecoder` decodes.
    ///
    /// The decoder calls it from inside `feed`. An implementation may call `stop` on the decoder to make
    /// `feed` return early.
    struct Sink {
        virtual ~Sink() = default;
        /// Receives a complete data message in Whole mode. `opcode` is `kOpText` or `kOpBinary`, and a text
        /// payload has been checked to be UTF-8.
        virtual void onMessage(uint8_t opcode, std::string&& payload) = 0;
        /// Receives a control frame: `opcode` is `kOpClose`, `kOpPing` or `kOpPong`, and `payload` is unmasked
        /// and at most 125 bytes. A Close payload has not been parsed. Called in every mode.
        virtual void onControl(uint8_t opcode, std::string&& payload) = 0;
        /// Receives, in raw data mode, the start of a data message whose first frame header has been checked.
        /// `compressed` is whether that frame had RSV1 set. The default does nothing.
        virtual void onDataStart(uint8_t /*opcode*/, bool /*compressed*/) {}
        /// Receives, in raw data mode, the next `n` unmasked payload bytes of the current message. `data` is
        /// valid only during the call. The default does nothing.
        virtual void onDataChunk(const char* /*data*/, size_t /*n*/) {}
        /// Receives, in raw data mode, the end of the current message, after the last payload byte of its FIN
        /// frame. The default does nothing.
        virtual void onDataEnd() {}
    };

    /// Creates a decoder in Whole mode at the start of a stream.
    ///
    /// `expectMasked` is true on the server side, where every received frame must be masked, and false on the
    /// client side, where none may be. `maxMessage` is the largest total payload, in bytes, of a data message;
    /// it is checked in Whole mode and for uncompressed messages in raw data mode. A `maxMessage` of 0 fails
    /// every checked data frame with a non-empty payload; it is not "no limit".
    WsDecoder(bool expectMasked, uint64_t maxMessage)
        : expectMasked_(expectMasked), maxMessage_(maxMessage) {}

    /// Parses the `n` bytes at `data`, calling `sink` as frames and messages complete, and returns how many
    /// bytes were consumed.
    ///
    /// That is all `n` unless the decoder fails or the sink calls `stop`; after a stop the unconsumed bytes
    /// must be fed again to continue. A partial header or payload at the end of the input is kept and
    /// continued by the next call. `sink` is used only during the call.
    size_t feed(const char* data, size_t n, Sink& sink);

    /// Asks the `feed` in progress to return once the current frame is finished or the input runs out. Meant
    /// to be called from a sink callback; each `feed` starts unstopped.
    void stop() { stopped_ = true; }

    /// Turns raw data mode on or off. It must be set before the first `feed`.
    void setRawData(bool on) { raw_ = on; }
    /// Allows RSV1 on the first frame of a data message, marking it compressed. RSV1 on a continuation or
    /// control frame, or on any frame while this is off, fails the decoder with `kCloseProtocolError`.
    void setAllowRsv1(bool on) { allowRsv1_ = on; }

    /// Turns discarding on or off. While on, data frame headers are checked but their payload is skipped,
    /// without size or UTF-8 checks, and no data message callback is made; control frames are still
    /// delivered. Turning it on frees the bytes of a Whole-mode message being assembled.
    void setDiscardData(bool on);
    /// Returns whether discarding is on.
    bool discardingData() const { return discard_; }

    /// Returns whether the decoder has failed.
    bool failed() const { return failCode_ != 0; }
    /// Returns the close code of the failure, or 0 if the decoder has not failed.
    int failCode() const { return failCode_; }
    /// Returns a description of the failure, or an empty string. The reference lasts as long as the decoder.
    const std::string& failText() const { return failText_; }

    /// Returns the payload length so far, summed from the frame headers received, of the data message in
    /// progress, or 0 between messages.
    uint64_t messageBytes() const { return msgSize_; }
    /// Returns whether a data message has started and its FIN frame has not yet been completed.
    bool inMessage() const { return inMessage_; }

private:
    /// Records `code` and `text` as the failure unless one is already recorded, and returns false.
    bool fail(int code, const char* text);
    /// Decodes and checks the complete header in `hdr_` and sets up the frame and message state; returns
    /// false after recording a failure.
    bool startFrame();

    // Configuration.
    bool expectMasked_;
    uint64_t maxMessage_;
    bool raw_ = false;
    bool allowRsv1_ = false;

    // Header accumulation (2 to 14 bytes).
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
    std::string control_;           ///< Unmasked control payload so far.

    // The data message.
    bool inMessage_ = false;
    bool msgCompressed_ = false;    ///< RSV1 was set on the message's first frame.
    std::string scratch_;           ///< Raw mode: the unmasked copy of a masked chunk passed to `onDataChunk`.
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
