//===- FaceProtocol.hpp - The stream faces as a Conn protocol -------------===//
//
// A `Socket.Connection` is read and written through two byte channels, its faces: the read face and the write
// face (see `ConnReadFace` and `ConnWriteFace`). Each face request reaches the connection's `Conn` on the reactor
// thread and must be answered with exactly one `ChannelResult`. `FaceProtocol` is the `ConnProtocol` that does
// this: it is the protocol every `Conn` starts with, and it keeps the requests that are waiting and the rules that
// turn connection events into their results.
//
// The read face. A read request is queued until data, the end of input or a read error arrives. Reading is
// demand-driven: `wantsRead` is true only while reads are queued and reading has not ended, so input nobody asked
// for is not read from the socket. Data answers the oldest queued read. When one chunk of data is longer
// than that read's `maxBytes`, the rest is buffered and served to the following reads, in order, before anything
// newer. The end of input answers every queued read with `eof`; a read error fails them all with the Conn's
// "read <CODE>" reason. Reading ends at the end of input, at a read error, or when the read face is closed or
// shut down. A face that ends reading before the end of input abandons it: no SHUT_RD is sent, and the unread
// input is left for the final close to discard.
//
// The write face. Each write request becomes one `Conn::write`, and is answered when the Conn reports it done.
// Closing the write face is `Conn::shutdownWrite`: a FIN after the queued writes (for TLS, a close_notify first).
// Shutting the write face down fails its queued writes with ECANCELED and then requests the FIN, best effort,
// if the connection is still open.
//
// A late request is one made after its direction has ended. It is answered at once. A late read gets `eof` after
// the end of input, otherwise the read error, otherwise ECANCELED with "socket closed". A late write or close gets
// the recorded write error, unless the connection was aborted, otherwise ECANCELED with "socket closed".
//
// When both directions have ended and no read, write or close is outstanding, the protocol closes the connection
// with `Conn::closeGraceful(Conn::kFaceDrainMs)`. When the Conn is aborted instead (`ConnProtocol::onCloseAll`),
// queued reads and writes fail with ECANCELED and "socket closed", and a pending close completes with no error.
//
// Another protocol can take the connection over (a hand-off, `Conn::setProtocol`). `idle` says whether any face
// request is outstanding, and `takeBuffered` hands over the bytes read but not yet delivered.
//
// Everything here runs on the reactor thread. Results leave it through the channel-results queue
// (`postChannelResult`), and hold no Elm heap values.
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

/// The protocol that serves the two faces of a `Socket.Connection`.
///
/// It is owned by its `Conn`, and every member must be called on the reactor thread. It cannot be copied. The
/// write and close requests it hands to the `Conn` keep a pointer to it and to the `Conn` in their `done`
/// callbacks; this is safe because the `Conn` owns it and, after a hand-off, keeps it until those callbacks have
/// run.
class FaceProtocol final : public ConnProtocol {
public:
    /// Creates a protocol with no requests queued and both directions open.
    FaceProtocol() = default;

    // Face requests, forwarded by `Conn`'s methods of the same names. Each `req*` request is answered with one
    // `ChannelResult` for `channelId` and `token`, posted to the channel-results queue, possibly before the call
    // returns. The two shutdowns post no result of their own; they answer only the requests already queued.

    /// Asks for the next bytes of input, at most `maxBytes` of them; a `maxBytes` of 0 is treated as 1. Buffered
    /// bytes are served first. A late read is answered at once, as is one made when the connection is not open.
    void reqRead(Conn& c, uint64_t channelId, uint64_t token, size_t maxBytes);
    /// Writes `bytes` after the earlier writes; the result reports their size once the transport has accepted
    /// them, or the error. Answered at once, with the late-write error, when the connection is not open, the write
    /// direction has ended, or a close of the write face is pending.
    void reqWrite(Conn& c, uint64_t channelId, uint64_t token, std::string bytes);
    /// Closes the write face: the FIN follows the queued writes, and the close is answered when it has been sent or
    /// has failed, with no error if the connection is aborted meanwhile. Answered at once, with the late-write
    /// error, in the cases `reqWrite` is.
    void reqCloseWrite(Conn& c, uint64_t channelId, uint64_t token);
    /// Closes the read face, answering with no error. Closed before the end of input, it ends reading, failing the
    /// queued reads with ECANCELED and an empty reason. Any buffered bytes are dropped.
    void reqCloseRead(Conn& c, uint64_t channelId, uint64_t token);
    /// Ends reading for a read face that is cancelled or dropped: the queued reads fail with ECANCELED, with the
    /// reason "socket closed" if the connection was aborted and an empty one otherwise, and buffered bytes are
    /// dropped. No SHUT_RD is sent.
    void readFaceShutdown(Conn& c);
    /// Ends writing for a write face that is cancelled or dropped: the queued writes fail with ECANCELED (reason
    /// "socket closed" if the connection was aborted, else empty), a pending close completes with no error if the
    /// connection was aborted and ECANCELED otherwise, and the FIN is requested, best effort, if the connection is
    /// still open.
    void writeFaceShutdown(Conn& c);

    /// Returns whether no face request is outstanding: no read queued, no write in flight and no close pending.
    /// A hand-off is safe only then.
    bool idle() const { return readReqs_.empty() && writesInFlight_ == 0 && !closePending_; }
    /// Returns the bytes read but not yet delivered to a read request, and forgets them.
    std::string takeBuffered();

    /// Answers the oldest queued read with `bytes`, buffering what exceeds its `maxBytes` for the following reads.
    /// Bytes arriving with no read queued, such as a hand-off's leftover, are buffered.
    void onData(Conn& c, std::string_view bytes) override;
    /// Ends reading and answers every queued read with `eof`. Buffered bytes are still served to later reads first.
    void onEof(Conn& c) override;
    /// For a read error, ends reading and fails every queued read with `err` and `code`. A write error needs nothing
    /// more here, since the Conn has already failed the writes through their callbacks.
    void onError(Conn& c, int err, const std::string& code) override;
    /// Fails the queued reads and writes with ECANCELED and "socket closed", completes a pending close with no
    /// error, drops buffered bytes, and ends both directions. It does not close the connection itself.
    void onCloseAll(Conn& c) override;
    /// Returns whether reads are queued and reading has not ended.
    bool wantsRead() const override { return !readDone_ && !readReqs_.empty(); }

    FaceProtocol(const FaceProtocol&) = delete;
    FaceProtocol& operator=(const FaceProtocol&) = delete;

private:
    /// A queued read request: who asked, and the most bytes it accepts (`max`, 0 meaning 1).
    struct ReadReq {
        uint64_t channelId;
        uint64_t token;
        size_t max;
    };

    /// Answers queued reads from `buffered_`, oldest first, until one of them runs out.
    void serveBuffered();
    /// Fails every queued read with `err` and `reason`.
    void failReads(int err, const std::string& reason);
    /// Answers a write of `size` bytes that the Conn reports done with `err`.
    void writeDone(Conn& c, uint64_t channelId, uint64_t token, size_t size, int err);
    /// Answers the pending close of the write face that the Conn reports done with `err`; does nothing if no close
    /// is pending.
    void closeDone(Conn& c, int err);
    /// Returns whether the write direction has ended, by this face or by the Conn.
    bool writeOver(const Conn& c) const { return writeFaceDone_ || c.writeEnded(); }
    /// Closes the connection gracefully once both directions have ended and nothing is outstanding.
    void checkDone(Conn& c);

    std::deque<ReadReq> readReqs_;
    std::string buffered_;          ///< read past a request's maxBytes, not yet delivered
    bool readDone_ = false;         ///< EOF, read error, or the read face is done
    bool writeFaceDone_ = false;    ///< the write face closed or shut down
    size_t writesInFlight_ = 0;
    bool closePending_ = false;
    uint64_t closeChannel_ = 0, closeToken_ = 0;
    bool cancelling_ = false;       ///< inside writeFaceShutdown / onCloseAll; holds off checkDone
    std::string cancelReason_;      ///< the reason writes fail with while cancelling_
};

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_FACE_PROTOCOL_HPP
