//===- FaceProtocol.hpp - The stream faces as a Conn protocol -------------===//
//
// plans/eco-system-websockets.md §3.2 (W17, phase WS1): the protocol of a
// Socket.Connection. It holds what Conn held before the refactor
// (plans/eco-system-sockets.md §3.3.3): the queued read requests of the
// read face, the write face's in-flight writes and its pending close, and
// the rules that turn them into ChannelResults (exactly one per request):
//
//   * read face: a request is served from what the Conn reads while
//     requests are queued (demand-driven: wantsRead() only then; nothing is
//     prefetched, so unread data stays in the kernel). EOF answers every
//     queued read with eof; a read error fails them with "read <CODE>".
//     close (after EOF) / shutdown (cancelReadable) end reading; ending
//     before EOF abandons it (no SHUT_RD): the final close discards input
//     for up to 2 s so Linux does not turn our FIN into RST (N8).
//   * write face: each write is one Conn::write; close is
//     Conn::shutdownWrite (FIN after the queued writes; TLS close_notify
//     first, S5); shutdown (cancelWritable) fails the queued writes
//     ECANCELED and sends the FIN best effort.
//   * requests after a direction ended complete at once: a read with eof,
//     the read error, or ECANCELED "socket closed"; a write or close with
//     the write error (unless aborted) or ECANCELED "socket closed".
//   * when both faces are done and nothing is in flight the connection is
//     closed with Conn::closeGraceful(kFaceDrainMs).
//   * onCloseAll (Socket.close / reset, embed stop): queued reads and writes
//     fail ECANCELED "socket closed"; a pending close completes with err 0
//     (§D.2).
//
// A read larger than a request's maxBytes is split; the rest is kept and
// served to the next request (in practice every request asks for 64 KiB,
// the Conn's read size, so nothing is kept). takeBuffered() hands such bytes
// to the next protocol on a hand-off.
//
// Reactor thread only (G1); results are POD ChannelResults.
//
// Templates used: none (POD only, G1); T9 completion side (ChannelResult).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_FACE_PROTOCOL_HPP
#define ECO_SYSTEM_SOCKET_FACE_PROTOCOL_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Socket/Conn.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>
#include <string_view>

namespace Eco::System {

class FaceProtocol final : public ConnProtocol {
public:
    FaceProtocol() = default;

    // Face requests (Conn::req*, from the faces' reactor submits).
    void reqRead(Conn& c, uint64_t channelId, uint64_t token, size_t maxBytes);
    void reqWrite(Conn& c, uint64_t channelId, uint64_t token, std::string bytes);
    void reqCloseWrite(Conn& c, uint64_t channelId, uint64_t token);
    void reqCloseRead(Conn& c, uint64_t channelId, uint64_t token);
    void readFaceShutdown(Conn& c);
    void writeFaceShutdown(Conn& c);

    // Hand-off support: no read, write or close in flight (else the caller
    // fails EBUSY, §3.2), and the bytes read but not delivered yet.
    bool idle() const { return readReqs_.empty() && writesInFlight_ == 0 && !closePending_; }
    std::string takeBuffered();

    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onCloseAll(Conn& c) override;
    bool wantsRead() const override { return !readDone_ && !readReqs_.empty(); }

    FaceProtocol(const FaceProtocol&) = delete;
    FaceProtocol& operator=(const FaceProtocol&) = delete;

private:
    struct ReadReq {
        uint64_t channelId;
        uint64_t token;
        size_t max;
    };

    void serveBuffered();
    void failReads(int err, const std::string& reason);
    void writeDone(Conn& c, uint64_t channelId, uint64_t token, size_t size, int err);
    void closeDone(Conn& c, int err);
    bool writeOver(const Conn& c) const { return writeFaceDone_ || c.writeEnded(); }
    void checkDone(Conn& c);

    std::deque<ReadReq> readReqs_;
    std::string buffered_;          // read past a request's maxBytes (rare)
    bool readDone_ = false;         // EOF, read error, or the read face is done
    bool writeFaceDone_ = false;    // the write face closed or shut down
    size_t writesInFlight_ = 0;
    bool closePending_ = false;
    uint64_t closeChannel_ = 0, closeToken_ = 0;
    bool cancelling_ = false;       // inside writeFaceShutdown / onCloseAll
    std::string cancelReason_;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_FACE_PROTOCOL_HPP
