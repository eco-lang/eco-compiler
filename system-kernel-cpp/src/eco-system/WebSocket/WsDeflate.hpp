//===- WsDeflate.hpp - permessage-deflate engine (RFC 7692) ---------------===//
//
// A WebSocket connection that negotiates permessage-deflate (RFC 7692) sends
// each message's payload compressed, and this component is the compressor and
// decompressor for those payloads, written directly on zlib.
//
// The payload of a compressed message is raw DEFLATE data: no zlib or gzip
// wrapper. The sender compresses the message and flushes with a sync flush,
// which ends the output on a byte boundary with the four bytes 00 00 ff ff,
// and then drops those four bytes. The receiver puts them back before
// inflating. A connection may also negotiate "no context takeover" for either
// direction. With context takeover, a message may refer back into the bytes of
// earlier messages, so the stream carries on from one message to the next.
// Without it, every message starts on a fresh stream.
//
// `Deflater` is the sending half and `Inflater` the receiving half. Both are
// pure: they do no IO and do not touch the Elm heap. Each owns one zlib stream,
// created the first time it is needed.
//
// Two facts about zlib shape the details. zlib refuses a raw deflate window of
// 8 bits, so an 8-bit window is deflated with 9 bits. This relies on zlib's
// deflate never emitting a back-reference further than the window size less
// 262 bytes, which for 9 bits is 250, within reach of a peer with an 8-bit
// window. And the inflater always uses a 15-bit window whatever the peer
// negotiated, since a larger window decodes anything a smaller one produced.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_DEFLATE_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_DEFLATE_HPP

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace Eco::System {

namespace ws {

/// The most bytes of decompressed output one `Inflater::step` produces. Giving
/// out the output in bounded steps lets a caller check message size limits and
/// backpressure between steps, so a small compressed input that inflates to a
/// huge one is never inflated all at once.
constexpr size_t kInflateStep = 64 * 1024;

/// The compressing half of permessage-deflate for one direction of one
/// connection.
///
/// It owns a zlib deflate stream, created by the first `chunk` or `message`
/// and ended when the `Deflater` is destroyed. A `Deflater` can be neither
/// copied nor moved.
class Deflater {
public:
    /// Creates a deflater with a window of `windowBits` bits, clamped to 9..15,
    /// so 8 deflates with a 9-bit window. With `noContextTakeover`, the stream
    /// is reset at the end of every message.
    Deflater(int windowBits, bool noContextTakeover);
    ~Deflater();
    Deflater(const Deflater&) = delete;
    Deflater& operator=(const Deflater&) = delete;

    /// Compresses the `n` bytes at `p` as part of the current message, flushed
    /// with a sync flush, and appends the result to `out`. The appended bytes
    /// end with 00 00 ff ff whenever any are produced. A call with no input
    /// after a flush appends nothing and succeeds.
    ///
    /// Returns false if zlib fails to create the stream or to compress. A
    /// failure to create the stream leaves `out` unchanged; a failure while
    /// compressing leaves whatever was already appended.
    bool chunk(const char* p, size_t n, std::string& out);
    /// Compresses the `n` bytes at `p` as one whole message and appends the
    /// payload to send to `out`: the output of `chunk` with its trailing
    /// 00 00 ff ff removed, or a single 00 byte if nothing is left, as RFC 7692
    /// requires for an empty message. It then ends the message as `endMessage`
    /// does. Returns false, without ending the message, if `chunk` fails; any
    /// bytes `chunk` already appended stay in `out`.
    bool message(const char* p, size_t n, std::string& out);
    /// Ends the current message. Without context takeover this resets the
    /// stream, so the next message refers to nothing before it; with context
    /// takeover it does nothing.
    void endMessage();

private:
    /// The zlib stream and whether it has been created.
    struct Z;
    std::unique_ptr<Z> z_;
    int bits_; ///< The window size actually used, already clamped to 9..15.
    bool noContext_;
};

/// The decompressing half of permessage-deflate for one direction of one
/// connection.
///
/// A message's compressed payload is pushed in as it arrives, marked finished
/// when the message ends, and inflated a step at a time. The `Inflater` copies
/// pushed bytes, so the caller's buffers need not outlive `push`.
///
/// It owns a zlib inflate stream, created by the first `step` and ended when
/// the `Inflater` is destroyed. An `Inflater` can be neither copied nor moved.
///
/// A message may contain a final DEFLATE block (one with BFINAL set) before its
/// end, which RFC 7692 allows. The bytes after it are inflated as a new stream
/// that may still refer back to the output before it.
class Inflater {
public:
    /// What one call to `step` achieved. `Output`: some bytes were appended,
    /// and `step` should be called again. `NeedInput`: all pushed input is used
    /// and the message is not finished. `Done`: the message is finished and
    /// fully inflated. `Error`: inflating failed, and `error()` gives the reason.
    enum class Step : uint8_t { Output, NeedInput, Done, Error };

    /// Creates an inflater. With `noContextTakeover`, the stream is reset after
    /// every message, so a message that refers back to an earlier one fails.
    explicit Inflater(bool noContextTakeover);
    ~Inflater();
    Inflater(const Inflater&) = delete;
    Inflater& operator=(const Inflater&) = delete;

    /// Adds the `n` bytes at `p` to the compressed payload of the current
    /// message.
    void push(const char* p, size_t n);
    /// Marks the current message's payload complete, adding back the
    /// 00 00 ff ff tail that the sender removed.
    void finish();
    /// Inflates pushed input, appending at most `maxOut` bytes to `out`. A
    /// `maxOut` of 0 or above `kInflateStep` is treated as `kInflateStep`.
    ///
    /// `Done` is returned once the message is finished and all of its input has
    /// been used, and leaves the stream ready for the next message. `Error` is
    /// returned when inflating fails (for example, on invalid data) or when the
    /// zlib stream cannot be created; after it, `error()` gives the reason.
    Step step(std::string& out, size_t maxOut);
    /// Returns whether pushed input, including the tail added by `finish`, is
    /// still waiting to be inflated.
    bool hasInput() const { return inOff_ < in_.size(); }
    /// Drops the current message: its pushed input, its finished mark and the
    /// stream's state, including the window, so later messages cannot refer
    /// back to anything before this call.
    void abandonMessage();
    /// Returns the reason for the most recent `Error` from `step`, or an empty
    /// string if there has been none. The reference is valid while the
    /// `Inflater` lives, and its text changes at the next `Error`.
    const std::string& error() const { return err_; }

private:
    /// The zlib stream and whether it has been created.
    struct Z;
    /// Creates the zlib stream if it does not exist yet, and returns whether it
    /// exists.
    bool ensure();
    /// Starts a new raw stream. With `keepWindow`, the last 32 KiB of output
    /// stay available for back-references from the new stream, when zlib can
    /// read the window out.
    void resetStream(bool keepWindow);
    std::unique_ptr<Z> z_;
    bool noContext_;
    std::string in_;         ///< Pushed input; the bytes before `inOff_` are already used.
    size_t inOff_ = 0;
    bool finished_ = false;  ///< `finish` was called for the current message.
    bool sawFinal_ = false;  ///< The current message contained a final block.
    std::string err_;
};

} // namespace ws

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_DEFLATE_HPP
