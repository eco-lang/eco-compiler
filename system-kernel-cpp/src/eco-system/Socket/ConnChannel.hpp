//===- ConnChannel.hpp - The two stream faces of a connection -------------===//
//
// plans/eco-system-sockets.md §3.3.3 "Faces" (SF2, SF3, N4). A Connection
// is a Stream pair: its readable is a ChannelSource over a ConnReadFace and
// its writable a ChannelSink over a ConnWriteFace. Both faces are
// ByteChannels CONSTRUCTED ON THE MAIN THREAD (ByteChannel's constructor
// registers the channel drain) over one shared_ptr<Conn>; the stream table
// owns each face (unique_ptr in its StreamPair) and destroys it when the
// pair is erased.
//
// Every request is submitted to the IoReactor as a lambda holding the
// shared_ptr<Conn> and POD only (G1); the Conn posts exactly one
// ChannelResult per request (ByteChannel contract).
//
//   * read face:  requestRead → Conn::reqRead; close (after EOF) →
//     reqCloseRead; shutdown (cancelReadable) → readFaceShutdown: reading is
//     abandoned (no SHUT_RD; the final close discard-drains, N8).
//     requestWrite fails ENOTSUP.
//   * write face: requestWrite → reqWrite; close (closeWritable) →
//     reqCloseWrite (FIN after the queued writes); shutdown
//     (cancelWritable) → writeFaceShutdown. requestRead fails ENOTSUP.
//   * a face destroyed without close/shutdown calls shutdown() (its pair
//     was erased, or the heap was reset), and every face tells the socket
//     tables it is gone, so the ConnEntry is erased with its second face.
//
// Templates used: T9 (requests; the completion side is the stream table).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_CONN_CHANNEL_HPP
#define ECO_SYSTEM_SOCKET_CONN_CHANNEL_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <cstdint>
#include <memory>

namespace Eco::System {

class ConnReadFace final : public ByteChannel {
public:
    ConnReadFace(std::shared_ptr<Conn> conn, int64_t connId);
    ~ConnReadFace() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

private:
    std::shared_ptr<Conn> conn_;
    int64_t connId_;
    bool done_ = false;   // close or shutdown was requested (main thread)
};

class ConnWriteFace final : public ByteChannel {
public:
    ConnWriteFace(std::shared_ptr<Conn> conn, int64_t connId);
    ~ConnWriteFace() override;

    void requestRead(uint64_t token, size_t maxBytes) override;
    void requestWrite(uint64_t token, std::string bytes) override;
    void close(uint64_t token) override;
    void shutdown() override;

private:
    std::shared_ptr<Conn> conn_;
    int64_t connId_;
    bool done_ = false;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_CONN_CHANNEL_HPP
