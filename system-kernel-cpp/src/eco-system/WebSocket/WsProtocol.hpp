//===- WsProtocol.hpp - The WebSocket codec as a connection protocol ------===//
//
// plans/eco-system-websockets.md §3.6 "C++ codec", §3.7, Appendix D.1-D.9,
// W3-W5, W7, W8, W14 (phases WS4: Whole mode; WS6: streamed messages; WS7:
// permessage-deflate).
//
// Two layers, both REACTOR-THREAD ONLY (G1):
//
//   * WsCore: the codec state machine, independent of what carries the
//     bytes. It talks to its transport through the WsPort interface, so the
//     same core runs over a TCP/TLS Conn (WsProtocol, below) and, from WS9,
//     over an HTTP/2 extended-CONNECT stream (an H2StreamPort). The main
//     thread reaches it only through IoReactor::submit()ted lambdas holding
//     a shared_ptr<WsCore> (the faces, WsChannel.cpp; the kernel bodies,
//     WebSocket.cpp); results go out as POD ChannelResults (messages, on the
//     mapped readable; write completions) and WsEvents (Closed, PingDone,
//     OpDone).
//   * WsProtocol: a ConnProtocol that is also the WsPort of a Conn: it
//     forwards the Conn's callbacks to the core and the core's IO to the
//     Conn. Installed by `open` with Conn::setProtocol (the bytes read past
//     the handshake are its first onData).
//
// Reader (D.1, D.4): ws::WsDecoder; whole messages queue for the readable
// (one ChannelResult per read request: tag 1 text, 2 binary). Reading
// pauses (wantsRead false) while kReadHighBytes bytes or kReadHighCount
// messages wait for Elm; the heartbeat and the pong deadlines are suspended
// while paused (W5) and restarted when reading resumes.
//
// Writer: control frames (pong, ping, a failing Close) go to the port at
// once; data messages wait in the core's FIFO and go out in fragments of at
// most kFragment bytes while the port's outbound queue is below
// kWriteHighBytes (refilled on onWritable), so control frames never wait
// behind more than one fragment. A graceful Close (close, closeWritable)
// queues behind the data. A write completes when the port took its last
// fragment. Client frames are masked with keys from a pooled RAND_bytes
// buffer (D.8).
//
// Close (D.5, W4): the first Close received sets CloseInfo (clean) and ends
// the readable (Closed, after the queued messages); it is echoed once with
// its code. After our Close, data frames are discarded and later writes
// fail Cancelled "socket closed". Once both Close frames are through the
// WebSocket is Closed (the WsEvent Closed is posted); the server then closes
// TCP (Conn::closeGraceful), the client waits for the server's FIN, both
// bounded by the close timeout (30 s), after which the connection is
// aborted. Failing the connection (1002 / 1007 / 1009 / 1011): send Close
// with the code, stop processing input, the readable fails Cancelled with
// the D.9 reason ("ERR_WS_PROTOCOL: <text>", "ERR_WS_INVALID_DATA: <text>",
// "ERR_WS_MESSAGE_TOO_BIG", "ERR_WS_INTERNAL_ERROR: <text>"); CloseInfo is
// our code and text, clean = False. A transport end without a Close frame
// is Abnormal (1006, "", False): reads fail "socket closed" (EOF, abort)
// or "read <CODE>" (a transport error).
//
// Ping/pong (D.6, W5): every ping is answered with a pong carrying its
// payload, ahead of queued data. `ping` sends a unique 8-byte payload; a
// pong answers its ping and every earlier one (RTT in ms); a ping fails
// ETIMEDOUT after the heartbeat timeout (30 s without a heartbeat) and
// ECANCELED when the connection closes first. Heartbeat: liveness is
// counted in received bytes; when nothing arrived for `interval`, a ping is
// sent; when still nothing arrived `timeout` later the connection is closed
// with 1001 (best effort) and reported Abnormal ("heartbeat ETIMEDOUT").
//
// Streamed receive (WS6, W7; mode 2): every data message is announced on the
// readable as tag 3 (text) / 4 (binary) with the decimal id of its BODY, a
// plain channel source (WsBodyChannel) created on the main thread when the
// message starts (the WsEvent BodyNeeded; bodyReady() hands the id back; a
// body nobody can receive any more is disposed: BodyDispose). The body's
// chunks are the message's payload as it arrives (inflated, text validated
// as UTF-8 and split at code points, fail fast: 1007), coalesced up to
// kBodyChunk per read; reading pauses while kReadHighBytes wait in the body.
// After the message's last frame the input is HELD (nothing more is
// decoded, reading pauses) until the body was read to its end (Closed) or
// cancelled: messages never overlap. Cancelling a body discards the rest of
// its message (still inflated and validated, to keep the stream in sync).
// A Close received, our own Close, or a failure in the middle of a message
// fails its body (Cancelled "socket closed", or the readable's reason); a
// complete but unread body stays readable. maxMessage does not apply.
//
// Streamed send (WS6, W7): openOutgoing(seq, opcode) puts an outgoing-stream
// placeholder in the data FIFO; the stream's chunks (WsOutChannel writes)
// go out as non-FIN fragments when the placeholder reaches the head, data
// messages written meanwhile queue behind it, and its close sends the FIN
// frame (an empty continuation — 0x00 when compressed, RFC 7692 §7.2.3.6 —
// or one empty, uncompressed frame with the opcode for an empty stream). Aborting a stream after its first fragment fails the
// connection with 1011; before it, the stream is dropped silently.
//
// permessage-deflate (WS7, §3.7, Appendix D.7): with deflate negotiated the
// decoder runs in raw data mode and allows RSV1 on first frames; compressed
// messages are inflated in steps of at most 64 KiB (Whole: the inflated size
// is checked against maxMessage inside the loop, 1009; Streamed: inflating
// pauses while the body is full). Whole messages of at least `threshold`
// bytes are compressed (RSV1 on the first fragment), streamed ones always
// (each chunk with a sync flush). Invalid compressed data fails with 1007.
//
// Timers (Conn ids): kTimerHeartbeat, kTimerPong (heartbeat pong and the
// explicit pings' deadlines), kTimerCloseHandshake.
//
// Templates used: none (POD only, G1); T9 completion side (ChannelResult).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_PROTOCOL_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_PROTOCOL_HPP

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/WebSocket/WsDeflate.hpp"
#include "eco-system/WebSocket/WsFrame.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace Eco::System {

struct WsConfig {
    bool server = false;                     // role: frames in must be masked (server)
    uint64_t maxMessage = 16 * 1024 * 1024;  // Whole mode
    int64_t heartbeatInterval = 0;           // ms; 0: no heartbeat
    int64_t heartbeatTimeout = 0;            // ms
    int64_t closeTimeout = 30000;            // ms
    int64_t wsId = 0;                        // the main-thread table id (WsEvents)
    uint64_t gen = 0;                        // its heap generation
    bool streamed = false;                   // mode 2: messages arrive as bodies (WS6)
    // permessage-deflate (WS7): `ours` = how we compress, `peer` = how the
    // peer compresses (context takeover; window bits 8..15).
    bool deflate = false;
    int64_t threshold = 0;                   // smaller whole messages go uncompressed
    bool ourNoContext = false;
    int ourBits = 15;
    bool peerNoContext = false;
    int peerBits = 15;
};

// What a WebSocket runs over (reactor thread). The core calls these only
// from its own entry points; the port may call back into the core
// (re-entrantly) from any of them.
class WsPort {
public:
    virtual ~WsPort() = default;
    // Queues bytes behind earlier writes; done(0) once the transport took
    // all of them, done(errno) on failure (done may run inside the call).
    virtual void portWrite(std::string bytes, std::function<void(int err)> done) = 0;
    // Bytes queued and not yet taken by the transport.
    virtual size_t portOutbound() const = 0;
    // A deadline (Conn timer ids); 0 cancels.
    virtual void portSetDeadline(int timerId, int64_t monoMs) = 0;
    // The core's wantsRead() changed.
    virtual void portUpdateInterest() = 0;
    // Orderly end of the transport after the queued writes (TCP: FIN, then
    // discard input until EOF or `drainMs`).
    virtual void portCloseGraceful(int64_t drainMs) = 0;
    // Immediate end (no more IO).
    virtual void portAbort() = 0;
};

class WsCore : public ws::WsDecoder::Sink, public std::enable_shared_from_this<WsCore> {
public:
    static constexpr size_t kReadHighBytes = 1024 * 1024;
    static constexpr size_t kReadHighCount = 1024;
    static constexpr size_t kWriteHighBytes = 64 * 1024;
    static constexpr size_t kFragment = 256 * 1024;
    static constexpr size_t kBodyChunk = 256 * 1024;
    static constexpr int64_t kDrainMs = 2000;

    explicit WsCore(WsConfig cfg);
    ~WsCore() override;

    // --- Port side ------------------------------------------------------------
    void attach(WsPort* port);              // the port is live (WsProtocol::onOpen)
    void detachPort(WsPort* port);          // the port object is being destroyed
    void portData(const char* data, size_t n);
    void portEof();
    void portError(int err, const std::string& reason);
    void portWritable();
    void portTimer(int timerId);
    void portClosed();                      // the transport is gone (idempotent)
    bool wantsRead() const;

    // --- Channel requests (from the faces' submits) ----------------------------
    void reqRead(uint64_t chan, uint64_t token);
    void readClose(uint64_t chan, uint64_t token);
    void readShutdown();                    // cancelReadable: discard data messages
    void reqWrite(uint64_t chan, uint64_t token, int64_t tag, bool text, std::string bytes);
    void writeClose(uint64_t chan, uint64_t token);   // closeWritable: Close 1000
    void writeShutdown();                   // cancelWritable: fail with 1011

    // --- Streamed receive: a body's channel (WsBodyChannel) -------------------
    void bodyReady(uint64_t seq, int64_t pairId);   // the main thread created the pair
    void bodyReqRead(uint64_t seq, uint64_t chan, uint64_t token);
    void bodyClose(uint64_t chan, uint64_t token);
    void bodyCancel(uint64_t seq);          // cancelReadable on the body

    // --- Streamed send: an outgoing stream (openOutgoing, WsOutChannel) --------
    void openOutgoing(uint64_t seq, uint8_t opcode);
    void outWrite(uint64_t seq, uint64_t chan, uint64_t token, std::string bytes);
    void outClose(uint64_t seq, uint64_t chan, uint64_t token);   // FIN
    void outAbort(uint64_t seq);            // cancelWritable / a failed pipe

    // --- Kernels -------------------------------------------------------------------
    // close: Close(code, reason) behind the queued data; OpDone(token) once it
    // is written (at once if a Close was sent already or the WebSocket ended).
    void startClose(int code, const std::string& reason, uint64_t token);
    // ping: PingDone(token) with the RTT, or a failure.
    void startPing(uint64_t token);
    // Abandon the connection now (heap reset, a failed open).
    void abortNow();

private:
    struct OutItem {
        std::string frame;         // a data message's payload, or a whole Close frame
        size_t offset = 0;         // data: bytes already sent in earlier fragments
        uint8_t opcode = 0;        // data: kOpText / kOpBinary
        uint64_t chan = 0, token = 0;   // data: the write to complete after the last fragment
        bool isClose = false;      // a graceful Close frame
        uint64_t streamSeq = 0;    // an outgoing-stream placeholder (WS6)
        bool prepared = false;     // the payload is final (compressed or not)
        bool compressed = false;   // RSV1 on the first fragment
        size_t size = 0;           // the write's size as Elm sees it
    };
    struct OutStream {
        uint8_t opcode = 0;
        bool started = false;      // a fragment went out (the opcode is spent)
        bool compress = false;
        bool closing = false;      // FIN requested
        bool dead = false;         // opened after the writable closed
        uint64_t closeChan = 0, closeToken = 0;
        std::deque<OutItem> chunks;
    };
    struct InMsg {
        int64_t tag = 0;           // 1 text, 2 binary, 3 / 4 streamed text / binary
        std::string data;          // the message, or the body's pair id (decimal)
        bool ready = true;         // streamed: the body's pair exists
        uint64_t bodySeq = 0;
    };
    struct Ping {
        std::string payload;
        uint64_t token;
        int64_t sentMs;
        int64_t deadline;
    };
    enum class ReadEnd : uint8_t { None, Eof, Error };

    struct ReadReq { uint64_t chan, token; };
    struct Body {
        uint64_t seq = 0;
        bool text = false;
        int64_t pairId = 0;                  // 0 until bodyReady
        std::deque<std::string> q;           // chunks not yet read
        size_t qBytes = 0;
        std::string partial;                 // text: an unfinished character
        std::deque<ReadReq> reads;
        ReadEnd end = ReadEnd::None;
        int err = 0;
        std::string reason;
        bool cancelled = false;
        bool endDelivered = false;
        bool messageDone = false;            // the message's input is complete
    };

    // Sink.
    void onMessage(uint8_t opcode, std::string&& payload) override;
    void onControl(uint8_t opcode, std::string&& payload) override;
    void onDataStart(uint8_t opcode, bool compressed) override;
    void onDataChunk(const char* data, size_t n) override;
    void onDataEnd() override;

    void processInput();
    void deliverData(const char* p, size_t n);
    void pumpInflate();
    void messageComplete();
    void abandonRx();
    void startBody(uint8_t opcode);
    void deliverBody();
    void bodyFail(int err, const std::string& reason);
    void maybeFinishBody();
    void releaseHold();
    void failStream(OutStream& s, const std::string& reason);
    void deliverReads();
    void endReadable(ReadEnd how, int err, const std::string& reason);
    void writeControl(uint8_t opcode, const std::string& payload, std::function<void(int)> done);
    std::string buildFrame(bool fin, uint8_t opcode, const char* p, size_t n, bool rsv1 = false);
    void queueMessage(uint8_t opcode, std::string bytes, uint64_t chan, uint64_t token);
    void pumpWrites();
    void queueGracefulClose(int code, const std::string& reason);
    void closeFrameWritten(int err);
    void failQueued(const std::string& reason);
    void failConnection(int code, const std::string& text);
    void failWith(int frameCode, const std::string& frameText, int infoCode,
                  const std::string& infoReason, int readErr, const std::string& readReason);
    void finishIfDone();
    void setCloseInfo(int code, const std::string& reason, bool clean);
    void postClosed();
    void ended(int err, const std::string& reason, bool abort);
    void postWriteResult(uint64_t chan, uint64_t token, int err, const std::string& reason, size_t n);
    void postOpDone(uint64_t token);
    void postPing(uint64_t token, bool ok, int64_t rtt, const std::string& code, const std::string& msg);
    void checkPause();
    void armHeartbeat(int64_t at);
    void armPongTimer();
    void heartbeatTimeout();
    void updateInterest();

    WsConfig cfg_;
    WsPort* port_ = nullptr;
    bool attached_ = false;
    bool transportGone_ = false;
    ws::WsDecoder decoder_;

    // Input.
    bool processing_ = false;
    std::string pendingIn_;
    bool inputDone_ = false;       // a Close received, or the connection failed: ignore input
    uint64_t rxBytes_ = 0;
    int64_t lastRxMs_ = 0;

    // Raw data mode (streamed, or deflate): the message being received.
    bool rxActive_ = false;
    bool rxCompressed_ = false;
    bool rxEndPending_ = false;    // its last frame arrived; inflating continues
    uint8_t rxOpcode_ = 0;
    uint64_t rxSize_ = 0;          // Whole: inflated bytes so far
    std::string rxBuf_;            // Whole: the message so far
    ws::Utf8Validator rxUtf8_;
    bool pumpingInflate_ = false;
    std::string inflateOut_;
    std::unique_ptr<ws::Inflater> inflater_;
    std::unique_ptr<ws::Deflater> deflater_;

    // Streamed receive.
    std::unique_ptr<Body> body_;
    uint64_t bodySeq_ = 0;
    bool held_ = false;            // input held until the body is finished
    bool discardAfterMessage_ = false;

    // The readable.
    std::deque<InMsg> msgQ_;
    size_t msgQBytes_ = 0;
    std::deque<ReadReq> readReqs_;
    ReadEnd readEnd_ = ReadEnd::None;
    int readErr_ = 0;
    std::string readReason_;
    bool readShut_ = false;
    bool paused_ = false;

    // The writable.
    std::deque<OutItem> outQ_;
    bool pumping_ = false;
    bool writeClosed_ = false;     // no more data (our Close is queued / sent, or ended)
    std::vector<std::pair<uint64_t, uint64_t>> closeWaiters_;   // writeClose (chan, token)
    std::vector<uint64_t> closeOps_;                            // startClose tokens
    std::map<uint64_t, OutStream> outStreams_;                  // by seq (WS6)

    // Close state.
    bool closeQueued_ = false;     // our Close is queued or written
    bool closeWritten_ = false;
    bool closeReceived_ = false;
    bool failed_ = false;
    bool infoSet_ = false;
    int closeCode_ = ws::kCloseAbnormal;
    std::string closeReason_;
    bool clean_ = false;
    bool closedPosted_ = false;
    bool tcpClosing_ = false;

    // Ping / heartbeat.
    uint64_t pingCounter_ = 0;
    std::vector<Ping> pings_;
    bool hbPingSent_ = false;
    uint64_t rxAtPing_ = 0;
    int64_t hbDeadline_ = 0;       // the heartbeat pong deadline (0: none)
};

// The ConnProtocol of an open WebSocket over a Conn (TCP or TLS).
class WsProtocol final : public ConnProtocol, public WsPort {
public:
    explicit WsProtocol(std::shared_ptr<WsCore> core) : core_(std::move(core)) {}
    ~WsProtocol() override;

    void onOpen(Conn& c) override;
    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onWritable(Conn& c) override;
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    bool wantsRead() const override;

    void portWrite(std::string bytes, std::function<void(int err)> done) override;
    size_t portOutbound() const override;
    void portSetDeadline(int timerId, int64_t monoMs) override;
    void portUpdateInterest() override;
    void portCloseGraceful(int64_t drainMs) override;
    void portAbort() override;

private:
    std::shared_ptr<WsCore> core_;
    Conn* conn_ = nullptr;   // the Conn owns this protocol
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_PROTOCOL_HPP
