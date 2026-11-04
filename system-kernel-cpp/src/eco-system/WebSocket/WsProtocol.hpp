//===- WsProtocol.hpp - The WebSocket codec as a connection protocol ------===//
//
// An open WebSocket is a long conversation of frames, and this component is the endpoint that conducts it once the
// opening handshake is over: it turns the bytes that arrive into messages, turns the messages written into frames,
// answers pings, watches the peer's liveness, and runs the closing handshake.
//
// The component rests on one separation. What a WebSocket means does not depend on what carries its bytes, so the
// state machine, `WsCore`, talks to its transport only through `WsPort`. `WsProtocol` is the port for a TCP or TLS
// `Conn`: it is the `ConnProtocol` installed on the connection, forwarding the `Conn`'s callbacks to the core and the
// core's writes, deadlines and closes to the `Conn`. Another `WsPort` can carry the same core over something else.
//
// Everything here must run on the reactor thread, the IO thread of `IoReactor`, since the core's own state is not
// locked; another thread must reach a core through an `IoReactor::submit` lambda holding a `shared_ptr` to it. Results
// leave as POD: a `ChannelResult` (see `ChannelResult` in `Core/ByteChannel.hpp`) for each completed channel request,
// posted with `postChannelResult`, and a `WsEvent` for each completed close or ping, each streamed body to be created
// or discarded, and the end of the WebSocket, posted with `postWsEvent`. Every `WsEvent` carries the `wsId` and `gen`
// of the core's `WsConfig`.
//
// Four terms are used throughout.
//
//   * The *readable* is the channel source of incoming messages. One read request receives one message: tag 1 for
//     text, 2 for binary. In streamed mode it receives instead tag 3 (text) or 4 (binary) with the decimal id of
//     the message's *body*, a separate channel source whose reads give the message's payload as it arrives.
//   * The *writable* is the channel sink of outgoing messages. Each write is one data message.
//   * *Failing the connection* is the response to a protocol error, invalid data, an oversized message or an
//     internal failure: a Close frame with the code (1002, 1007, 1009 or 1011) is sent unless ours has been handed
//     to the port already, input stops being processed, the readable fails, and the transport is closed.
//   * The *CloseInfo* is the code, reason and cleanness reported in the `Closed` event. The first one set is kept.
//
// Input. Bytes go to a `ws::WsDecoder`. A message is queued for the readable until a read request takes it. While
// queued messages hold `kReadHighBytes` bytes or number `kReadHighCount`, or a streamed body holds `kReadHighBytes`,
// reading is paused, and pausing cancels the heartbeat and ping deadlines. A ping received is
// answered at once with a pong carrying its payload, unless our Close is already queued.
//
// Output. Pings, pongs, the Close echo and the failure Close go to the port at once. Data messages wait in the
// core's queue and go out in fragments of at most `kFragment` bytes, a fragment at a time, while the port holds
// fewer than `kWriteHighBytes` unsent bytes. A client masks every frame it
// sends with a key taken from a per-thread pool refilled by `wsRandomBytes`.
//
// Closing. A Close received sets the CloseInfo from its code and reason, clean, and ends the readable after the
// messages already queued. Unless our Close is already queued, it also fails the data not yet given to the port and is
// echoed with its code and no reason, or with an empty payload if it had none. A Close of our own is queued behind the
// data, after which incoming data frames are discarded and later writes fail ECANCELED "socket closed". When both Close
// frames are through, the `Closed` event is posted and a server closes the transport; a client waits for the server to
// end it. Both waits are bounded by `WsConfig::closeTimeout`, counted from when the first Close was queued, after which
// the transport is aborted. A Close of ours whose write fails completes nothing: the CloseInfo becomes 1006, an empty
// reason, not clean, and its waiting requests complete when the transport ends, as below. When the connection fails, except as Liveness says, the CloseInfo is our code and text, not
// clean, and the readable fails with errno EMSGSIZE for 1009 and EPROTO otherwise, and the reason "ERR_WS_PROTOCOL:
// <text>", "ERR_WS_INVALID_DATA: <text>", "ERR_WS_MESSAGE_TOO_BIG" or "ERR_WS_INTERNAL_ERROR: <text>"; 1002 and any
// code other than 1007, 1009 and 1011 give the first. A transport that ends without a Close frame gives the CloseInfo
// 1006, an empty reason, not clean.
//
// Liveness. An explicit ping sends an 8-byte counter whose top bit is clear; the pong that echoes it completes it
// and every ping sent before it, with the round-trip time. A ping can fail ETIMEDOUT when its deadline passes, and
// fails ECANCELED when the WebSocket ends first. The heartbeat, when `heartbeatInterval` is
// set, sends a ping with the top bit set once nothing has been received for that interval. If no byte at all has
// arrived when its deadline passes, a Close 1001 is sent and the
// connection fails with the CloseInfo 1006, an empty reason, not clean, and the readable's error ETIMEDOUT
// "heartbeat ETIMEDOUT".
//
// Streamed receive (`WsConfig::streamed`). Each data message is announced on the readable when it starts, and its
// body's channel pair is made on the eco thread: the core posts a `BodyNeeded` event, and the announcement waits
// until `bodyReady` hands back the pair's id. The body's reads receive the payload, inflated if compressed, with text
// checked as UTF-8 and cut only at character boundaries; queued pieces are joined while the result stays within
// `kBodyChunk`. After a message's last frame the input is *held*: nothing more is decoded until the body has been
// read to its end or cancelled, so bodies never overlap. A cancelled body's remaining payload is still inflated and
// checked, then dropped. A Close received, our own Close, or a failure in the middle of a message fails its body; a
// complete but unread body stays readable. `maxMessage` does not apply.
//
// Streamed send. `openOutgoing` puts an outgoing stream in the data queue. When it reaches the head, its chunks go
// out as non-FIN fragments and everything behind it waits; `outClose` sends the FIN frame. That frame is an empty
// continuation, or one byte 0x00 when the stream is compressed and has sent a fragment (the header of an empty
// stored deflate block, which the receiver's appended 00 00 ff ff completes, so that the next message under context
// takeover starts cleanly), or, for a stream that sent nothing, one empty uncompressed frame with the stream's
// opcode. Aborting a stream after its first fragment fails the connection with 1011; before it, the stream is
// dropped and its pending requests fail.
//
// permessage-deflate (`WsConfig::deflate`). The decoder runs in raw data mode and accepts RSV1 on a message's first
// frame. Compressed messages are inflated in steps of at most `ws::kInflateStep` bytes; a Whole-mode message whose
// inflated size passes `maxMessage` fails the connection with 1009, and in streamed mode inflating pauses while the
// body is full. Invalid compressed data fails the connection with 1007. Outgoing data messages of at least
// `threshold` bytes are compressed, and outgoing streams always are.
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

/// The settings of one open WebSocket, fixed when its `WsCore` is made.
///
/// Durations are in milliseconds. Nothing checks the values here; the comments say what each value does.
struct WsConfig {
    bool server = false;                     ///< True on the server side: incoming frames must be masked, ours are not.
    /// The largest payload of a Whole-mode message, in bytes; a larger one fails the connection with 1009. It is
    /// not "no limit" at 0: then every non-empty message fails. Streamed mode ignores it.
    uint64_t maxMessage = 16 * 1024 * 1024;
    int64_t heartbeatInterval = 0;           ///< Silence before a heartbeat ping is sent; 0 or less: no heartbeat.
    int64_t heartbeatTimeout = 0;            ///< How long a ping waits for its pong.
    int64_t closeTimeout = 30000;            ///< How long the closing handshake may take before an abort.
    int64_t wsId = 0;                        ///< The id copied into every `WsEvent` this core posts.
    uint64_t gen = 0;                        ///< The heap generation copied into every `WsEvent` this core posts.
    bool streamed = false;                   ///< Messages arrive as bodies, not whole (see the file comment).
    // permessage-deflate: the `our*` settings are how we compress, the `peer*` settings how the peer does.
    bool deflate = false;
    int64_t threshold = 0;                   ///< Messages sent by `reqWrite` shorter than this go uncompressed.
    bool ourNoContext = false;
    int ourBits = 15;                        ///< Our window bits, given to `ws::Deflater`, which clamps them to 9..15.
    bool peerNoContext = false;
    int peerBits = 15;                       ///< Not read by `WsCore`; its inflater always uses a 15-bit window.
};

/// A transport a `WsCore` runs over.
///
/// The core calls a port only from its own entry points, on the reactor thread. An implementation may call back
/// into the core from inside any of these functions, including re-entrantly into the entry point that called it. The
/// core keeps a raw pointer to its port from `WsCore::attach` on, so an implementation must call
/// `WsCore::detachPort` before it is destroyed.
class WsPort {
public:
    virtual ~WsPort() = default;
    /// Sends `bytes` after the bytes of earlier calls. An implementation calls `done`, which may be null, once:
    /// with 0 when the bytes have been taken, or with an errno when they cannot be sent. When the bytes count as
    /// taken is the implementation's to say. `done` may be called before this returns.
    virtual void portWrite(std::string bytes, std::function<void(int err)> done) = 0;
    /// Returns the number of bytes given to `portWrite` and not yet taken.
    virtual size_t portOutbound() const = 0;
    /// Arranges for `WsCore::portTimer(timerId)` at monotonic time `monoMs`, or cancels the deadline when `monoMs`
    /// is 0. The ids are `Conn::kTimerHeartbeat`, `Conn::kTimerPong` and `Conn::kTimerCloseHandshake`.
    virtual void portSetDeadline(int timerId, int64_t monoMs) = 0;
    /// Tells the port that `WsCore::wantsRead` may have changed.
    virtual void portUpdateInterest() = 0;
    /// Ends the transport in an orderly way after the bytes already written, waiting at most `drainMs` for it to
    /// finish.
    virtual void portCloseGraceful(int64_t drainMs) = 0;
    /// Ends the transport at once.
    virtual void portAbort() = 0;
};

/// The state machine of one open WebSocket, as the file comment describes, independent of its transport.
///
/// A core is made from its `WsConfig`, and must be owned by a `std::shared_ptr`: it hands `shared_from_this()` to
/// the write completions it gives its port. It does no IO until `attach`; data written before that is queued.
/// Every function must be called on the reactor thread. A core cannot be copied or moved: it is shared by address.
class WsCore : public ws::WsDecoder::Sink, public std::enable_shared_from_this<WsCore> {
public:
    /// The bytes, or a streamed body's queued bytes, at which reading pauses until the readable takes some.
    static constexpr size_t kReadHighBytes = 1024 * 1024;
    /// The number of queued messages at which reading pauses until the readable takes some.
    static constexpr size_t kReadHighCount = 1024;
    /// The port's unsent bytes at or above which no further data fragment is written.
    static constexpr size_t kWriteHighBytes = 64 * 1024;
    /// The largest payload, in bytes, of one outgoing data frame.
    static constexpr size_t kFragment = 256 * 1024;
    /// The size, in bytes, up to which queued pieces of a body are joined into one read.
    static constexpr size_t kBodyChunk = 256 * 1024;
    /// How long, in milliseconds, a graceful end of the transport may take.
    static constexpr int64_t kDrainMs = 2000;

    /// Creates a core with the settings `cfg`, not yet attached to a port.
    explicit WsCore(WsConfig cfg);
    ~WsCore() override;

    // --- Port side ------------------------------------------------------------
    /// Starts using `port`, which must stay valid until it calls `detachPort`. Starts the heartbeat, if there is
    /// one, and writes what was queued before.
    void attach(WsPort* port);
    /// Stops using `port`, if it is the attached port, and treats the transport as gone. Does not end the
    /// WebSocket; `portClosed` does that.
    void detachPort(WsPort* port);
    /// Decodes `n` received bytes at `data`, which need be valid only during the call. Bytes received after a Close
    /// or a failure are counted for the heartbeat and otherwise ignored.
    void portData(const char* data, size_t n);
    /// Handles the end of the incoming byte stream. After a Close was received or the connection failed, this
    /// closes the transport; otherwise the WebSocket ends with the CloseInfo 1006, the readable fails ECONNRESET
    /// "socket closed", and the transport is closed.
    void portEof();
    /// Ends the WebSocket after a transport error `err` (EIO if 0), failing the readable with `reason`, and aborts
    /// the transport.
    void portError(int err, const std::string& reason);
    /// Writes queued data now that the port has room.
    void portWritable();
    /// Handles the deadline `timerId` set through `WsPort::portSetDeadline`. The close-handshake deadline ends the
    /// WebSocket and aborts the transport.
    void portTimer(int timerId);
    /// Ends the WebSocket because the transport is gone: pending reads and writes fail ECANCELED "socket closed", and
    /// the CloseInfo becomes 1006, unclean, unless one was set. Calling it again has no further effect.
    void portClosed();
    /// Returns whether the port should read: after `attach`, before the transport is gone, and while reading is not
    /// paused or input is being ignored anyway.
    bool wantsRead() const;
    /// Returns whether `attach` has been called, whatever happened to the transport since.
    bool isAttached() const { return attached_; }

    // --- Channel requests (from the faces' submits) ----------------------------
    /// Asks for the next message on the readable channel `chan`, answered with a `ChannelResult` carrying `token`.
    /// After `readShutdown` it fails ECANCELED at once.
    void reqRead(uint64_t chan, uint64_t token);
    /// Completes a close of the readable channel `chan` at once. It does not affect the WebSocket.
    void readClose(uint64_t chan, uint64_t token);
    /// Cancels the readable: pending and later reads fail ECANCELED, queued messages are dropped, and later data
    /// messages are discarded. In streamed mode a body being received continues to its end, and bodies already
    /// announced are disposed of with `BodyDispose`.
    void readShutdown();
    /// Queues one data message `bytes` from the writable channel `chan`, text when `tag` is 1 and binary otherwise,
    /// and reports its completion with `token`; the boolean is not read. A successful result reports the size of
    /// `bytes`, compressed or not. The write fails ECANCELED "socket closed" once the writable is closed or the
    /// transport is gone, and "write <ERRNO>" when the port reports another error.
    void reqWrite(uint64_t chan, uint64_t token, int64_t tag, bool text, std::string bytes);
    /// Closes the writable channel `chan` by sending Close 1000 behind the queued data, completing `token` when the
    /// write of our Close frame (this one or one already queued) finishes. If a Close has already been written, or the
    /// WebSocket has ended or the transport is gone, it completes at once.
    void writeClose(uint64_t chan, uint64_t token);
    /// Cancels the writable, failing the connection with 1011, unless the writable is already closed, the
    /// connection has failed, or the WebSocket has ended.
    void writeShutdown();

    // --- Streamed receive: a body's channel (WsBodyChannel) -------------------
    /// Records that body `seq` has the channel pair `pairId`, which lets its announcement reach the readable. If
    /// the announcement is no longer queued, because the readable was cancelled, the pair is disposed of instead.
    void bodyReady(uint64_t seq, int64_t pairId);
    /// Asks for the next piece of body `seq` on its channel `chan`. Fails ECANCELED at once if `seq` is not the
    /// current body or it was cancelled.
    void bodyReqRead(uint64_t seq, uint64_t chan, uint64_t token);
    /// Completes a close of a body's channel `chan` at once; a `token` of 0 posts nothing.
    void bodyClose(uint64_t chan, uint64_t token);
    /// Cancels body `seq`: its pending reads fail ECANCELED and the rest of its message is dropped. Does nothing if
    /// `seq` is not the current body.
    void bodyCancel(uint64_t seq);

    // --- Streamed send: an outgoing stream (openOutgoing, WsOutChannel) --------
    /// Opens outgoing stream `seq`, a message with `opcode` sent in pieces, behind the data already queued. If the
    /// writable is closed or the transport is gone, the stream is made dead: its writes and its close fail.
    void openOutgoing(uint64_t seq, uint8_t opcode);
    /// Queues `bytes` as the next piece of stream `seq`, completing `token` on channel `chan` when its last fragment
    /// has been written. An empty piece completes at once and sends nothing. Fails ECANCELED "socket closed" if the
    /// stream is unknown, dead or closing, or the transport is gone.
    void outWrite(uint64_t seq, uint64_t chan, uint64_t token, std::string bytes);
    /// Ends stream `seq` with its FIN frame, completing `token` on `chan` when that frame has been written. Fails
    /// ECANCELED "socket closed" in the cases `outWrite` does, and forgets a dead stream.
    void outClose(uint64_t seq, uint64_t chan, uint64_t token);
    /// Abandons stream `seq`. After its first fragment this fails the connection with 1011, unless the WebSocket
    /// has already failed or ended or the transport is gone; otherwise its pending writes and close fail ECANCELED
    /// and the stream is forgotten.
    void outAbort(uint64_t seq);

    // --- Kernels -------------------------------------------------------------------
    /// Sends Close with `code` and `reason` behind the queued data, and posts `OpDone(token)` once our Close frame
    /// has been written. If a Close of ours is already queued, `code` and `reason` are not used and `token` waits for
    /// that one. If a Close has been written, the WebSocket has ended or the transport is gone, `OpDone` is
    /// posted at once.
    void startClose(int code, const std::string& reason, uint64_t token);
    /// Sends a ping, and posts `PingDone(token)` with the round-trip time when its pong arrives, or failed with
    /// ETIMEDOUT or ECANCELED. Fails ECANCELED at once if our Close is queued, the WebSocket has ended, or the
    /// transport is gone.
    void startPing(uint64_t token);
    /// Abandons the WebSocket at once: aborts the transport if it is still there, which ends the WebSocket as
    /// `portClosed` does, and otherwise calls `portClosed` itself.
    void abortNow();

private:
    /// One entry of the data queue: a data message, a graceful Close frame, or the place of an outgoing stream. An
    /// outgoing stream's pieces are entries too, held in its `OutStream`.
    struct OutItem {
        std::string frame;         ///< A data message's payload, or a whole encoded Close frame.
        size_t offset = 0;         ///< How much of `frame` earlier fragments have sent.
        uint8_t opcode = 0;        ///< A data message's `ws::kOpText` or `ws::kOpBinary`.
        // The write to complete after the last fragment.
        uint64_t chan = 0, token = 0;
        bool isClose = false;
        uint64_t streamSeq = 0;    ///< Nonzero for the place of outgoing stream `streamSeq`.
        bool prepared = false;     ///< The payload has been compressed, or chosen to go uncompressed.
        bool compressed = false;   ///< RSV1 goes on the first fragment.
        size_t size = 0;           ///< The size reported to the write: the payload's size before compression.
    };
    /// The state of one outgoing stream.
    struct OutStream {
        uint8_t opcode = 0;
        bool started = false;      ///< A fragment has gone out, so later fragments are continuations.
        bool compress = false;
        bool closing = false;      ///< The FIN has been requested.
        bool dead = false;         ///< Writes and the close fail; set when opened too late or failed.
        // The close request to complete when the FIN frame is written.
        uint64_t closeChan = 0, closeToken = 0;
        std::deque<OutItem> chunks;
    };
    /// One entry for the readable: a whole message, or the announcement of a body.
    struct InMsg {
        int64_t tag = 0;           ///< 1 text, 2 binary, 3 a text body, 4 a binary body.
        std::string data;          ///< The message, or the body's pair id in decimal.
        bool ready = true;         ///< False for a body whose pair has not been made yet.
        uint64_t bodySeq = 0;
    };
    /// A ping waiting for its pong.
    struct Ping {
        std::string payload;
        uint64_t token;
        int64_t sentMs;
        int64_t deadline;   ///< 0: none.
    };
    /// How a readable or body ended: not yet, at its end, or with an error.
    enum class ReadEnd : uint8_t { None, Eof, Error };

    /// A pending read request on a channel.
    struct ReadReq { uint64_t chan, token; };
    /// The body of the streamed message being received, or received and not yet finished.
    struct Body {
        uint64_t seq = 0;
        bool text = false;
        int64_t pairId = 0;                  ///< 0 until `bodyReady`.
        std::deque<std::string> q;           ///< Pieces not yet read.
        size_t qBytes = 0;
        std::string partial;                 ///< Text bytes ending in an unfinished character.
        std::deque<ReadReq> reads;
        ReadEnd end = ReadEnd::None;
        int err = 0;
        std::string reason;
        bool cancelled = false;
        bool endDelivered = false;
        bool messageDone = false;            ///< No more payload will arrive for it.
    };

    // Sink.
    /// Queues a whole message for the readable, unless input is ignored or the readable was cancelled.
    void onMessage(uint8_t opcode, std::string&& payload) override;
    /// Answers a ping, completes pings a pong answers, and handles a Close received, as the file comment describes.
    /// A Close payload that does not parse fails the connection.
    void onControl(uint8_t opcode, std::string&& payload) override;
    /// Starts receiving a message in raw data mode, and in streamed mode announces its body.
    void onDataStart(uint8_t opcode, bool compressed) override;
    /// Passes payload bytes of the current message on, through the inflater if it is compressed.
    void onDataChunk(const char* data, size_t n) override;
    /// Handles the end of the current message's frames. In streamed mode it holds the input, unless the readable
    /// was cancelled during the message.
    void onDataEnd() override;

    /// Decodes the input queued in `pendingIn_` until it is used up, the input is held, or input stops being
    /// processed, and fails the connection if the decoder failed. Does nothing when called while decoding.
    void processInput();
    /// Takes `n` payload bytes of the current message, inflated if it was compressed: checks text as UTF-8 and, in
    /// Whole mode, the size against `maxMessage`, failing the connection with 1007 or 1009, and appends them to the
    /// message or its body, unless the readable or the body was cancelled or the body has ended.
    void deliverData(const char* p, size_t n);
    /// Inflates the current compressed message, a step at a time, until it needs input, is done, fails with 1007,
    /// or, in streamed mode, its body holds `kReadHighBytes`. Does nothing when called while inflating.
    void pumpInflate();
    /// Finishes the current message: fails the connection with 1007 if its text ends mid-character, and otherwise
    /// queues it for the readable or ends its body.
    void messageComplete();
    /// Forgets the message being received, which will not complete.
    void abandonRx();
    /// Makes the body of a streamed message starting with `opcode`, queues its announcement, and posts
    /// `BodyNeeded`.
    void startBody(uint8_t opcode);
    /// Answers the body's pending reads from what it holds, and resumes inflating when there is room.
    void deliverBody();
    /// Ends the body with the error `err` and `reason`, after the pieces it already holds, unless it has ended.
    void bodyFail(int err, const std::string& reason);
    /// Drops the body once its end has been read, or once it was cancelled and its message is over, and releases
    /// the held input.
    void maybeFinishBody();
    /// Releases held input, if it is held, and decodes what was waiting.
    void releaseHold();
    /// Fails the pending writes and close of `s` with ECANCELED and `reason`, and makes it dead.
    void failStream(OutStream& s, const std::string& reason);
    /// Answers pending readable reads from the queued messages and then the readable's end. A body announcement
    /// whose pair has not been made stops it.
    void deliverReads();
    /// Ends the readable after the queued messages, with `how` and, for an error, `err` and `reason`. Only the
    /// first call has an effect.
    void endReadable(ReadEnd how, int err, const std::string& reason);
    /// Writes a control frame with `payload` straight to the port. `done`, which may be null, receives ECANCELED at
    /// once if there is no port or the transport is gone.
    void writeControl(uint8_t opcode, const std::string& payload, std::function<void(int)> done);
    /// Returns a frame with `fin`, `opcode`, `rsv1` and the `n` payload bytes at `p`, masked on the client side.
    std::string buildFrame(bool fin, uint8_t opcode, const char* p, size_t n, bool rsv1 = false);
    /// Appends data message `bytes` with `opcode` to the data queue, to complete `token` on `chan`.
    void queueMessage(uint8_t opcode, std::string bytes, uint64_t chan, uint64_t token);
    /// Writes fragments from the head of the data queue while the port has room, compressing each message or
    /// stream piece when it first reaches the head. A compression failure fails the connection with 1011. Does
    /// nothing when called while writing.
    void pumpWrites();
    /// Queues our Close with `code` and `reason` behind the data, unless one is queued already. From then on the
    /// writable is closed, incoming data is discarded, a body still receiving frames fails, the held input is released,
    /// and the close-handshake deadline runs.
    void queueGracefulClose(int code, const std::string& reason);
    /// Handles the end of the write of our Close frame. Written (`err` 0): completes the waiting `startClose` and
    /// `writeClose` requests, and ends the WebSocket if the peer's Close is in too and the connection has not failed.
    /// Failed: the close handshake cannot complete, so the CloseInfo becomes 1006, unclean, unless `Closed` has been
    /// posted, and the waiting requests stay for `ended`, which the transport's end that follows any failed write
    /// calls.
    void closeFrameWritten(int err);
    /// Fails every queued data message, and every outgoing stream's pending requests, with ECANCELED and `reason`,
    /// and drops a queued graceful Close.
    void failQueued(const std::string& reason);
    /// Fails the connection with `code`, sending `text` as the Close reason and reporting it in the CloseInfo and
    /// the readable's reason.
    void failConnection(int code, const std::string& text);
    /// Fails the connection, as the file comment describes, with separate values for each place they go: Close
    /// frame `frameCode` and `frameText`, the CloseInfo `infoCode` and `infoReason` (cut to 123 bytes), and the
    /// readable's and body's `readErr` and `readReason`. Posts `Closed` at once. Does nothing once the connection
    /// has failed or the WebSocket has ended.
    void failWith(int frameCode, const std::string& frameText, int infoCode,
                  const std::string& infoReason, int readErr, const std::string& readReason);
    /// Ends the WebSocket once our Close has been written and the peer's received, unless the connection failed,
    /// and then closes the transport on the server side.
    void finishIfDone();
    /// Sets the CloseInfo, unless it has been set already.
    void setCloseInfo(int code, const std::string& reason, bool clean);
    /// Posts `Closed` with the CloseInfo (1006, unclean, if none was set), once, and fails the pending pings
    /// ECANCELED.
    void postClosed();
    /// Ends the WebSocket: the CloseInfo becomes 1006, unclean, unless one was set, a body
    /// whose message is not done and the readable fail with `err` and `reason`, queued data fails, waiting close
    /// requests complete (a `writeClose` one with ECANCELED), and `Closed` is posted. The boolean is not read.
    void ended(int err, const std::string& reason, bool abort);
    /// Posts the result of a write on `chan` with `token`: `n` bytes written, or the error `err` and `reason`.
    void postWriteResult(uint64_t chan, uint64_t token, int err, const std::string& reason, size_t n);
    /// Posts `OpDone(token)`, unless `token` is 0.
    void postOpDone(uint64_t token);
    /// Posts `PingDone(token)`: succeeded with `rtt` milliseconds, or failed with the errno name `code` and `msg`.
    void postPing(uint64_t token, bool ok, int64_t rtt, const std::string& code, const std::string& msg);
    /// Pauses or resumes reading as the queued input requires. Pausing cancels the heartbeat and ping deadlines;
    /// resuming restarts them and tells the port.
    void checkPause();
    /// Sets the heartbeat deadline to `at`, when there is a heartbeat and a live port.
    void armHeartbeat(int64_t at);
    /// Sets the ping deadline to the earliest of the heartbeat ping's and the pending pings' deadlines, or cancels
    /// it when there is none.
    void armPongTimer();
    /// Fails the connection after the heartbeat ping went unanswered, as the file comment describes.
    void heartbeatTimeout();
    /// Returns how long a ping, the heartbeat's included, waits for its pong: `heartbeatTimeout`, or 30 s when that
    /// is 0 or less.
    int64_t pingTimeoutMs() const;
    /// Tells a live port that `wantsRead` may have changed.
    void updateInterest();

    WsConfig cfg_;
    /// The attached port, or null before `attach` and after `detachPort`. Not owned.
    WsPort* port_ = nullptr;
    bool attached_ = false;
    bool transportGone_ = false;
    ws::WsDecoder decoder_;

    // Input.
    bool processing_ = false;
    std::string pendingIn_;        ///< Received bytes not yet decoded: they arrived while decoding, or are held.
    bool inputDone_ = false;       ///< A Close was received or the connection failed: input is ignored.
    uint64_t rxBytes_ = 0;
    int64_t lastRxMs_ = 0;

    // Raw data mode (streamed, or deflate): the message being received.
    bool rxActive_ = false;
    bool rxCompressed_ = false;
    bool rxEndPending_ = false;    ///< Its last frame arrived and inflating continues.
    uint8_t rxOpcode_ = 0;
    uint64_t rxSize_ = 0;          ///< Whole mode: the inflated bytes so far.
    std::string rxBuf_;            ///< Whole mode: the message so far.
    ws::Utf8Validator rxUtf8_;
    bool pumpingInflate_ = false;
    std::string inflateOut_;
    std::unique_ptr<ws::Inflater> inflater_;
    std::unique_ptr<ws::Deflater> deflater_;

    // Streamed receive.
    std::unique_ptr<Body> body_;
    uint64_t bodySeq_ = 0;
    bool held_ = false;            ///< The input is held until the body is finished.
    bool discardAfterMessage_ = false;

    // The readable.
    std::deque<InMsg> msgQ_;
    size_t msgQBytes_ = 0;         ///< The bytes of the whole messages in `msgQ_`; announcements count 0.
    std::deque<ReadReq> readReqs_;
    ReadEnd readEnd_ = ReadEnd::None;
    int readErr_ = 0;
    std::string readReason_;
    bool readShut_ = false;
    bool paused_ = false;

    // The writable.
    std::deque<OutItem> outQ_;
    bool pumping_ = false;
    bool writeClosed_ = false;     ///< No more data may be queued: our Close is queued, or the WebSocket ended.
    std::vector<std::pair<uint64_t, uint64_t>> closeWaiters_;   ///< `writeClose` requests, as (chan, token).
    std::vector<uint64_t> closeOps_;                            ///< `startClose` tokens.
    std::map<uint64_t, OutStream> outStreams_;                  ///< Outgoing streams by sequence number.

    // Close state. Our Close goes through up to three steps, each with its flag: queued (`closeQueued_`, set when it
    // enters `outQ_`, or for the echo and the failure Close when it is written at once), handed to the port
    // (`closeSent_`), and written (`closeWritten_`, set only when the port reports the write done without error).
    // A queued Close can still be dropped from `outQ_` by `failQueued`, which is why `failWith` tests `closeSent_`:
    // it sends a Close of its own only when none has reached the port. The waiting requests (`closeOps_`,
    // `closeWaiters_`) are completed exactly once, by the successful write or, when there is none, by `ended`;
    // `ended` does not set `closeWritten_`, so a `writeClose` after an abnormal end fails as one with no history.
    bool closeQueued_ = false;
    bool closeSent_ = false;
    bool closeWritten_ = false;
    bool closeReceived_ = false;
    bool failed_ = false;
    bool infoSet_ = false;
    int closeCode_ = ws::kCloseAbnormal;
    std::string closeReason_;
    bool clean_ = false;
    bool closedPosted_ = false;
    bool tcpClosing_ = false;      ///< The port has been asked to close gracefully.

    // Ping / heartbeat.
    uint64_t pingCounter_ = 0;
    std::vector<Ping> pings_;
    bool hbPingSent_ = false;
    uint64_t rxAtPing_ = 0;        ///< `rxBytes_` when the heartbeat ping was sent.
    int64_t hbDeadline_ = 0;       ///< The heartbeat ping's deadline; 0: none.
};

/// The `WsPort` of a WebSocket over a `Conn`, TCP or TLS, installed on it as its `ConnProtocol`.
///
/// It forwards the `Conn`'s callbacks to its core and the core's port calls to the `Conn`. It shares ownership of the
/// core. It refers to its `Conn` from `onOpen` on; before that, its port calls do nothing, and a write completes
/// ECANCELED. When the `Conn` closes, a close hook tells the core, if the core still exists, that the transport is
/// gone. Destroying it detaches it from the core.
class WsProtocol final : public ConnProtocol, public WsPort {
public:
    /// Creates the port of `core`. `preamble`, when not empty, is written to the `Conn` in `onOpen` before the core
    /// is attached, ahead of every frame (a server's HTTP/1.1 101 response); if its write fails, the `Conn`'s error
    /// reaches the core through `onError`.
    explicit WsProtocol(std::shared_ptr<WsCore> core, std::string preamble = std::string())
        : core_(std::move(core)), preamble_(std::move(preamble)) {}
    ~WsProtocol() override;

    /// Records `c`, installs the close hook, writes the preamble, and attaches the port to the core.
    void onOpen(Conn& c) override;
    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onWritable(Conn& c) override;
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    bool wantsRead() const override;

    /// Queues the bytes with `Conn::write`, whose `done` reports 0 once the transport has accepted them.
    void portWrite(std::string bytes, std::function<void(int err)> done) override;
    size_t portOutbound() const override;
    void portSetDeadline(int timerId, int64_t monoMs) override;
    void portUpdateInterest() override;
    /// Calls `Conn::closeGraceful`.
    void portCloseGraceful(int64_t drainMs) override;
    /// Calls `Conn::abort` without a TCP reset.
    void portAbort() override;

private:
    std::shared_ptr<WsCore> core_;
    std::string preamble_;   ///< Written in `onOpen`, then emptied.
    /// The `Conn` from `onOpen` on, or null before. The `Conn` owns this protocol, so it outlives it.
    Conn* conn_ = nullptr;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_PROTOCOL_HPP
