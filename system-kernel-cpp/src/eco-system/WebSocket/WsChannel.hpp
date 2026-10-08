//===- WsChannel.hpp - The two stream faces of a WebSocket ----------------===//
//
// plans/eco-system-websockets.md §3.3, §3.6 (W16). A WebSocket is a stream
// pair: its readable is a MAPPED SOURCE (Stream.hpp createMappedSource)
// over a WsReadChannel, whose chunks are whole messages tagged 1 (text) /
// 2 (binary) and become `WebSocket.Message` values through fromWire; its
// writable is a MAPPED SINK over a WsWriteChannel, which receives the
// ( tag, String, Bytes ) of toWire. Both faces are ByteChannels constructed
// on the main thread over one shared_ptr<WsCore>; every request is
// submitted to the IoReactor as a lambda holding the shared_ptr and POD
// only (G1), and the core posts exactly one ChannelResult per request.
//
//   * read face:  requestRead → WsCore::reqRead; close (after the end) →
//     readClose; shutdown (cancelReadable) → readShutdown: later data
//     messages are discarded, control frames are still handled (D.5).
//   * write face: requestWriteTagged / requestWrite (binary) → reqWrite;
//     close (closeWritable) → writeClose: Close 1000 after the queued
//     messages; shutdown (cancelWritable) → writeShutdown: the connection
//     fails with 1011 (only while the writable was open: a stream that
//     failed because the WebSocket closed does not fail it again).
//   * every face tells the WebSocket tables it is gone (a Closed WebSocket
//     is erased with its second face).
//
// Streamed messages (WS6) add two channels per message, which are not faces
// (they do not count for the tables):
//   * WsBodyChannel: under a plain channel source, the body of one received
//     streamed message (WsCore::bodyReqRead / bodyCancel by its sequence
//     number); text bodies post String chunks (ChannelResult::text).
//   * WsOutChannel: under a plain channel sink (a text sink for sendText),
//     one outgoing stream (openOutgoing): writes are its fragments, close
//     its FIN frame, shutdown aborts it (WsCore::outAbort).
//
// Templates used: T9 (requests; the completion side is the stream table).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_CHANNEL_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_CHANNEL_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/WebSocket/WsProtocol.hpp"

#include <cstdint>
#include <memory>

namespace Eco::System {

class WsReadChannel final : public ByteChannel {
public:
    WsReadChannel(std::shared_ptr<WsCore> core, int64_t wsId);
    ~WsReadChannel() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

private:
    std::shared_ptr<WsCore> core_;
    int64_t wsId_;
    bool done_ = false;
};

class WsWriteChannel final : public ByteChannel {
public:
    WsWriteChannel(std::shared_ptr<WsCore> core, int64_t wsId);
    ~WsWriteChannel() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void requestWriteTagged(uint64_t token, int64_t tag, bool text, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

private:
    std::shared_ptr<WsCore> core_;
    int64_t wsId_;
    bool done_ = false;
};

class WsBodyChannel final : public ByteChannel {
public:
    WsBodyChannel(std::shared_ptr<WsCore> core, uint64_t seq);

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

private:
    std::shared_ptr<WsCore> core_;
    uint64_t seq_;
    bool done_ = false;
};

class WsOutChannel final : public ByteChannel {
public:
    WsOutChannel(std::shared_ptr<WsCore> core, uint64_t seq);
    ~WsOutChannel() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

private:
    std::shared_ptr<WsCore> core_;
    uint64_t seq_;
    bool done_ = false;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_CHANNEL_HPP
