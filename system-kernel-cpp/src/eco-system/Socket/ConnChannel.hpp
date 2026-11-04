//===- ConnChannel.hpp - The two stream faces of a connection -------------===//
//
// The stream machinery reads and writes through `ByteChannel`s, one per stream; a connection is one socket with
// two directions. This component gives a `Conn` two channels, its faces: the read face, behind the Connection's
// readable stream, and the write face, behind its writable stream. Each face serves one direction and answers a
// request for the other with `ENOTSUP`.
//
// A face does no I/O. Each request is passed to the `Conn` by `IoReactor::submit`, in a lambda that holds the
// face's `shared_ptr<Conn>` and plain values only, so the `Conn` outlives every request still queued and the
// lambda holds nothing from the Elm heap. The `Conn` answers each read,
// write and close request with one `ChannelResult`; `shutdown` gets none.
//
// A face ends in one of two ways. `close` ends its direction in an orderly way (for the write face, a half close
// after the queued writes); `shutdown` abandons it. A face destroyed before either calls `shutdown`. Every face,
// when destroyed, calls `socketTablesFaceGone`, so the connection's `ConnEntry` is erased with its second face.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_CONN_CHANNEL_HPP
#define ECO_SYSTEM_SOCKET_CONN_CHANNEL_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <cstdint>
#include <memory>

namespace Eco::System {

/// The read face of a connection: a `ByteChannel` that reads from one `Conn` and cannot write.
///
/// Eco thread only. `requestWrite` is answered at once with a Write result whose `err` is `ENOTSUP`. Destroying
/// the face without `close` or `shutdown` shuts it down; destroying it in any case tells the socket tables, by
/// `socketTablesFaceGone`, that one face of `connId` is gone. Not copyable.
class ConnReadFace final : public ByteChannel {
public:
    /// Creates the read face of `conn`, the connection the socket tables know as `connId`.
    ConnReadFace(std::shared_ptr<Conn> conn, int64_t connId);
    ~ConnReadFace() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    /// Tells the `Conn` that the reader is done with its input, by `Conn::reqCloseRead`.
    void close(uint64_t token) override;
    /// Abandons reading, by `Conn::readFaceShutdown`; no `SHUT_RD` is sent. Does nothing after `close` or an
    /// earlier `shutdown`.
    void shutdown() override;
    /// Returns `socketFailureReason(err, reason)`.
    std::string encodeFailure(int err, const std::string& reason) const override {
        return socketFailureReason(err, reason);
    }
    /// Returns `"socket"`.
    const char* failureOrigin() const override { return "socket"; }

private:
    std::shared_ptr<Conn> conn_;
    int64_t connId_;      ///< The connection's id in the socket tables, passed to `socketTablesFaceGone`.
    bool done_ = false;   ///< Set by `close` or `shutdown`; later `shutdown` calls do nothing.
};

/// The write face of a connection: a `ByteChannel` that writes to one `Conn` and cannot read.
///
/// Eco thread only. `requestRead` is answered at once with a Read result whose `err` is `ENOTSUP`. Destroying
/// the face without `close` or `shutdown` shuts it down; destroying it in any case tells the socket tables, by
/// `socketTablesFaceGone`, that one face of `connId` is gone. Not copyable.
class ConnWriteFace final : public ByteChannel {
public:
    /// Creates the write face of `conn`, the connection the socket tables know as `connId`.
    ConnWriteFace(std::shared_ptr<Conn> conn, int64_t connId);
    ~ConnWriteFace() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    /// Asks the `Conn` for a graceful half close after the writes already queued, by `Conn::reqCloseWrite`.
    void close(uint64_t token) override;
    /// Gives up writing, by `Conn::writeFaceShutdown`, which fails the queued writes and, if the
    /// connection is still open, sends the FIN. Does nothing after `close` or an earlier `shutdown`.
    void shutdown() override;
    /// Returns `socketFailureReason(err, reason)`.
    std::string encodeFailure(int err, const std::string& reason) const override {
        return socketFailureReason(err, reason);
    }
    /// Returns `"socket"`.
    const char* failureOrigin() const override { return "socket"; }

private:
    std::shared_ptr<Conn> conn_;
    int64_t connId_;      ///< The connection's id in the socket tables, passed to `socketTablesFaceGone`.
    bool done_ = false;   ///< Set by `close` or `shutdown`; later `shutdown` calls do nothing.
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_CONN_CHANNEL_HPP
