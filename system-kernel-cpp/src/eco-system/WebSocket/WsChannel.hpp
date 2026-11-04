//===- WsChannel.hpp - The channels of a WebSocket ------------------------===//
//
// Elm code reads and writes a WebSocket through streams, and a stream runs over a `ByteChannel`. This component is
// the four channels that connect those streams to a WebSocket's codec, `WsCore`.
//
// A WebSocket is a stream pair. Its readable is a mapped source over a `WsReadChannel`: each read is answered with one
// received message, tagged 1 for text or 2 for binary, which the source turns into a `WebSocket.Message`. In streamed
// mode (`WsConfig::streamed`) the answer is instead tagged 3 (text) or 4 (binary) and carries the decimal id of the
// message's `WsBodyChannel` pair. Its writable is a mapped sink over a `WsWriteChannel`, which receives each message as
// a tagged write. These two channels are the WebSocket's *faces*. Destroying a face reports it to the WebSocket tables
// (`wsTablesFaceGone`), which do not erase an ended WebSocket while either of its faces remains.
//
// A message can also be sent or received in pieces, as a stream of its own. Each such stream adds a channel that is
// not a face and is not counted by the tables:
//   * a `WsBodyChannel` carries the body of one received message, read piece by piece;
//   * a `WsOutChannel` carries one outgoing message: each write is a fragment, `close` sends the final fragment, and
//     `shutdown` abandons the message.
//
// None of the channels does any WebSocket work itself. A request that makes no sense for its direction (a write on
// a readable, a read on a writable) is answered at once with `ENOTSUP`. Every other request, and a `shutdown`, is
// handed to the IoReactor thread as a command that holds only a `shared_ptr<WsCore>` and plain values, and runs
// there as a call on the core, which answers a request through the channel-results queue as `WsCore` describes for
// that call. A failure is reported with origin "websocket", its reason encoded by `websocketFailureReason`.
//
// Every member function, destructors included, must be called on the eco thread (the thread that runs the Elm
// scheduler), as `ByteChannel` requires of requests and `wsTablesFaceGone` and `wsTablesCloseStarted` require.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_CHANNEL_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_CHANNEL_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/WebSocket/WsProtocol.hpp"

#include <cstdint>
#include <memory>

namespace Eco::System {

/// The readable face of WebSocket `wsId`: each read is answered with the next received message.
///
/// Cancelling it (`shutdown`) cancels the WebSocket's readable as `WsCore::readShutdown` describes; closing it does not
/// affect the WebSocket. Destroying it first cancels it if it was neither closed nor shut down, then reports the face
/// gone to the WebSocket tables.
class WsReadChannel final : public ByteChannel {
public:
    /// Creates the readable face of WebSocket `wsId`, served by `core`.
    WsReadChannel(std::shared_ptr<WsCore> core, int64_t wsId);
    ~WsReadChannel() override;

    /// Asks for the next received message, whatever `maxBytes` is.
    void requestRead(uint64_t token, size_t maxBytes) override;
    /// Answers at once with `ENOTSUP`: a readable cannot be written.
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;
    std::string encodeFailure(int err, const std::string& reason) const override {
        return websocketFailureReason(err, reason);
    }
    const char* failureOrigin() const override { return "websocket"; }

private:
    std::shared_ptr<WsCore> core_;
    int64_t wsId_;
    bool done_ = false; ///< Whether `close` or `shutdown` has been called; `shutdown` does nothing once it is set.
};

/// The writable face of WebSocket `wsId`: each write sends one message.
///
/// Closing it sends a Close with code 1000 behind the messages already queued (`WsCore::writeClose`), and cancelling
/// it (`shutdown`) fails the connection with code 1011 unless the writable is already closed or the WebSocket has
/// failed or ended (`WsCore::writeShutdown`). Both record in the WebSocket tables that a local close has started
/// (`wsTablesCloseStarted`). Unlike the readable face, destroying it does not cancel it: the destructor only reports
/// the face gone to the tables.
class WsWriteChannel final : public ByteChannel {
public:
    /// Creates the writable face of WebSocket `wsId`, served by `core`.
    WsWriteChannel(std::shared_ptr<WsCore> core, int64_t wsId);
    ~WsWriteChannel() override;

    /// Answers at once with `ENOTSUP`: a writable cannot be read.
    void requestRead(uint64_t token, size_t maxBytes) override;
    /// Sends `bytes` as one binary message, as a tagged write with tag 2 does.
    void requestWrite(uint64_t token, std::string bytes) override;
    /// Sends `bytes` as one message: text when `tag` is 1, binary for any other `tag`. `text` is not read.
    /// Unlike the default, no `tag` is refused.
    void requestWriteTagged(uint64_t token, int64_t tag, bool text, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;
    std::string encodeFailure(int err, const std::string& reason) const override {
        return websocketFailureReason(err, reason);
    }
    const char* failureOrigin() const override { return "websocket"; }

private:
    std::shared_ptr<WsCore> core_;
    int64_t wsId_;
    bool done_ = false; ///< Whether `close` or `shutdown` has been called; `shutdown` does nothing once it is set.
};

/// The body of the received streamed message numbered `seq` on a WebSocket, read piece by piece.
///
/// Reads ask the core for the next piece of body `seq`; cancelling (`shutdown`) drops the rest of the message. It is
/// not a face. Destroying it does nothing beyond dropping its reference to the core.
class WsBodyChannel final : public ByteChannel {
public:
    /// Creates the channel of body `seq`, served by `core`.
    WsBodyChannel(std::shared_ptr<WsCore> core, uint64_t seq);

    /// Asks for the next piece of the body, whatever `maxBytes` is.
    void requestRead(uint64_t token, size_t maxBytes) override;
    /// Answers at once with `ENOTSUP`: a received body cannot be written.
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;
    std::string encodeFailure(int err, const std::string& reason) const override {
        return websocketFailureReason(err, reason);
    }
    const char* failureOrigin() const override { return "websocket"; }

private:
    std::shared_ptr<WsCore> core_;
    uint64_t seq_;
    bool done_ = false; ///< Whether `close` or `shutdown` has been called; `shutdown` does nothing once it is set.
};

/// One outgoing streamed message, numbered `seq` on a WebSocket, written piece by piece.
///
/// Each write is sent as the message's next fragment, `close` sends its final fragment, and `shutdown` abandons it as
/// `WsCore::outAbort` describes. It is not a face. Destroying it abandons the message if it was neither closed nor
/// shut down, so that the messages queued behind it are not held up for ever.
class WsOutChannel final : public ByteChannel {
public:
    /// Creates the channel of outgoing stream `seq`, served by `core`.
    WsOutChannel(std::shared_ptr<WsCore> core, uint64_t seq);
    ~WsOutChannel() override;

    /// Answers at once with `ENOTSUP`: an outgoing message cannot be read.
    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;
    std::string encodeFailure(int err, const std::string& reason) const override {
        return websocketFailureReason(err, reason);
    }
    const char* failureOrigin() const override { return "websocket"; }

private:
    std::shared_ptr<WsCore> core_;
    uint64_t seq_;
    bool done_ = false; ///< Whether `close` or `shutdown` has been called; `shutdown` does nothing once it is set.
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_CHANNEL_HPP
