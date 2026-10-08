//===- WsDeflate.hpp - permessage-deflate engine (RFC 7692) ---------------===//
//
// plans/eco-system-websockets.md §3.7, Appendix D.7 (phase WS7). The
// compression half of permessage-deflate: raw DEFLATE with zlib directly
// (the stream codecs of StreamCodec.cpp cannot do it: fixed window, no
// sync flush, no reset; §2 WF6). Pure (no IO, no heap access, G1): the
// WsCore drives one Deflater and one Inflater per connection on the reactor
// thread, and the core test checks the RFC 7692 §7.2.3 vectors directly.
//
//   * Deflater: deflateInit2(Z_DEFAULT_COMPRESSION, Z_DEFLATED,
//     -max(9, bits), 8, Z_DEFAULT_STRATEGY) (zlib refuses a raw window of
//     8; a 9-bit window never produces a distance an 8-bit peer cannot
//     resolve, §2 WF6). chunk() compresses with Z_SYNC_FLUSH (the output
//     ends on a byte boundary with 00 00 ff ff); message() compresses a
//     whole message, strips the trailing 00 00 ff ff, and gives "\0" for
//     an empty message (§7.2.3.6). endMessage(): without context takeover
//     the stream is reset (deflateReset) after every message.
//   * Inflater: inflateInit2(-15) whatever the peer's window. push() the
//     compressed bytes of a message as they arrive, finish() at its end
//     (appends 00 00 ff ff, §7.2.2), and step() out at most `maxOut` bytes
//     at a time (≤ 64 KiB), so the caller checks sizes (compression bombs)
//     and backpressure between steps. A block with BFINAL inside a message
//     is accepted (§7.2.3.4): the stream is re-initialised with its window
//     kept as the dictionary, and the bytes after it are inflated as a new
//     stream. Without context takeover the stream is reset after every
//     message. The zlib streams are created on first use (an uncompressed
//     connection allocates nothing).
//
// Templates used: none (POD only).
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

constexpr size_t kInflateStep = 64 * 1024;

class Deflater {
public:
    // `windowBits` 8..15 (8 deflates with 9); `noContextTakeover`: reset
    // after every message.
    Deflater(int windowBits, bool noContextTakeover);
    ~Deflater();
    Deflater(const Deflater&) = delete;
    Deflater& operator=(const Deflater&) = delete;

    // Compresses `n` bytes with Z_SYNC_FLUSH, appending to `out` (the output
    // ends with 00 00 ff ff). False on a zlib failure (out of memory).
    bool chunk(const char* p, size_t n, std::string& out);
    // A whole message's payload: chunk(), then the trailing 00 00 ff ff
    // stripped ("\0" for an empty message), then endMessage().
    bool message(const char* p, size_t n, std::string& out);
    // The message ended: without context takeover, reset the stream.
    void endMessage();

private:
    struct Z;
    std::unique_ptr<Z> z_;
    int bits_;
    bool noContext_;
};

class Inflater {
public:
    enum class Step : uint8_t { Output, NeedInput, Done, Error };

    explicit Inflater(bool noContextTakeover);
    ~Inflater();
    Inflater(const Inflater&) = delete;
    Inflater& operator=(const Inflater&) = delete;

    // The compressed payload of the current message, in pieces.
    void push(const char* p, size_t n);
    // The message's payload is complete (appends 00 00 ff ff).
    void finish();
    // Inflates: appends at most `maxOut` (≤ kInflateStep) bytes to `out`.
    //   Output    some bytes were produced (call again);
    //   NeedInput all pushed input is used and the message is not finished;
    //   Done      the message is complete (the stream is ready for the next);
    //   Error     invalid compressed data (error() says why).
    Step step(std::string& out, size_t maxOut);
    // True while pushed input is waiting to be inflated.
    bool hasInput() const { return inOff_ < in_.size(); }
    // Drops the current message (the connection failed or discards it).
    void abandonMessage();
    const std::string& error() const { return err_; }

private:
    struct Z;
    bool ensure();
    void resetStream(bool keepWindow);
    std::unique_ptr<Z> z_;
    bool noContext_;
    std::string in_;
    size_t inOff_ = 0;
    bool finished_ = false;
    bool sawFinal_ = false;
    std::string err_;
};

} // namespace ws

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_DEFLATE_HPP
