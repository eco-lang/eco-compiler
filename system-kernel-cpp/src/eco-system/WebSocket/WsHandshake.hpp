//===- WsHandshake.hpp - The kernel side of the opening handshake ---------===//
//
// A WebSocket connection starts as an HTTP exchange, the opening handshake, and this component does the parts of it
// that need bytes and sockets, so that the rules of the handshake can stay in Elm.
//
// The Elm side decides everything a handshake means: which headers a request carries, whether a response or a
// request is acceptable, and what is negotiated. This component never judges a head. It provides three things.
//
//   * The key and the accept value. A client sends a random `Sec-WebSocket-Key`, and a server proves it understood
//     the request by answering with `Sec-WebSocket-Accept`, the base64 SHA-1 of the key followed by the fixed GUID of
//     RFC 6455. Both are computed with OpenSSL.
//   * HTTP heads. A *head* is the request line or status line and the header fields, up to and including the blank
//     line that ends them. Functions here find where a head ends, parse one into an `HttpHead`, and write a request
//     or a response head. A head may be at most `kMaxHead` bytes.
//   * Connection protocols, the `ConnProtocol`s that drive a `Conn` on the reactor thread during the handshake.
//     `DialJob` connects to a server, sends the request and reads the response head. `UpgradeReadProtocol` reads a
//     request head from a server-side connection. Each reports its result as one `WsEvent` (`postWsEvent`). After an
//     HTTP/1.1 dial or an `UpgradeReadProtocol` has read a head, the connection is *parked* in a `HoldProtocol`: it
//     stays open, doing nothing, until the Elm side has decided what to do with it, and the bytes read past the head
//     (a frame sent right behind it) are kept for whoever takes the connection next.
//
// A dial and a kill of the dialling task can happen at once on different threads. `DialJob::resolved` decides which
// one wins: exactly one of them moves it away from 0.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_HANDSHAKE_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_HANDSHAKE_HPP

#include "eco-system/Socket/Conn.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace Eco::System {

/// The header fields of an HTTP head as name and value pairs, in the order they appear. Names keep their case, and a
/// name may appear more than once.
using HeaderList = std::vector<std::pair<std::string, std::string>>;

// --- Key / accept -----------------------------------------------------------------

/// Returns the `Sec-WebSocket-Accept` value that answers `key`: the base64 SHA-1 of `key` followed by the RFC 6455
/// GUID. Returns an empty string on Windows, where the build has no OpenSSL.
std::string wsAcceptFor(const std::string& key);
/// Returns a fresh `Sec-WebSocket-Key`: 16 bytes from `wsRandomBytes`, in base64. Returns an empty string on
/// Windows.
std::string wsNewKey();
/// Fills the `n` bytes at `out` with random bytes from the system's cryptographic generator: OpenSSL's `RAND_bytes`,
/// or `BCryptGenRandom` on Windows. If the generator fails, prints a message to stderr and aborts the process; there
/// is no weaker fallback.
void wsRandomBytes(unsigned char* out, size_t n);

// --- HTTP heads (pure) --------------------------------------------------------------

/// The largest HTTP head, in bytes, that a handshake protocol accepts, blank line included.
constexpr size_t kMaxHead = 64 * 1024;

/// One parsed HTTP head, of a request or of a response.
///
/// A request fills `method`, `target` and `version`; a response fills `version`, `status` and `reasonPhrase`. Both
/// append to `headers`.
struct HttpHead {
    // `version` is the digits only, such as "1.1", without "HTTP/".
    std::string method, target, version;
    int status = 0;
    std::string reasonPhrase;
    HeaderList headers;   ///< Values have surrounding spaces and tabs removed.
};

/// Returns the length of the head at the start of `buf`, through the blank line that ends it, or 0 if `buf` does not
/// yet hold a whole head. A blank line is CR LF CR LF or LF LF, whichever ends first.
size_t httpHeadLength(std::string_view buf);

/// Parses `head` as a request head into `out`, and returns whether it is one.
///
/// The request line must be a token method, a target with no spaces or control characters, and `HTTP/d.d`,
/// separated by single spaces. Lines may end in CR LF or LF, and parsing stops at the first blank line. A header line
/// is rejected if it is folded (starts with a space or tab), has no colon, has a name that is not a token (so also a
/// space before the colon), or has a control character other than a tab in its value. On failure `err` says why,
/// and `out` may have been partly filled.
bool parseRequestHead(std::string_view head, HttpHead& out, std::string& err);
/// Parses `head` as a response head into `out`, and returns whether it is one.
///
/// The status line must be `HTTP/d.d`, a space and three digits, then either nothing or a space and the reason
/// phrase. The header lines follow the rules of `parseRequestHead`. On failure `err` says why, and `out` may have been
/// partly filled.
bool parseResponseHead(std::string_view head, HttpHead& out, std::string& err);

/// Returns whether a header may be written into a head: `name` is a token, as RFC 9110 defines one, and `value`
/// contains no CR, LF or NUL.
bool httpHeaderValid(const std::string& name, const std::string& value);

/// Returns a `GET` request head for `target` over HTTP/1.1, with `headers` in order, ending in its blank line.
/// Headers that fail `httpHeaderValid` are left out. `target` is written as given.
std::string serializeRequest(const std::string& target, const HeaderList& headers);
/// Returns an HTTP/1.1 response head with `status`, the reason `httpStatusReason` gives for it, and `headers` in
/// order. Headers that fail `httpHeaderValid` are left out.
///
/// With `withBody`, the response is complete and asks for the connection to close: any `Content-Length`,
/// `Transfer-Encoding` or `Connection` header in `headers` is dropped, whatever its case, and `Content-Length` for
/// `body`, `Connection: close`, the blank line and `body` follow. Without it, the result ends at the blank line and
/// `body` is ignored.
std::string serializeResponse(int status, const HeaderList& headers, bool withBody,
                              const std::string& body);
/// Returns the reason phrase for `status`: the standard one for a set of common statuses, otherwise a phrase naming
/// its class ("Informational", "Success", "Redirection", "Client Error"), and "Server Error" for anything below 100
/// or from 500 up.
const char* httpStatusReason(int status);

// --- Connection protocols (reactor thread) ------------------------------------------

/// The protocol of a parked connection: one whose handshake head has been read and which waits for a decision.
///
/// A `HoldProtocol` keeps every byte delivered to it, which includes the leftover handed over by `Conn::setProtocol`,
/// until `takeLeftover` collects them.
///
/// Made with no argument, it never asks to read, and ignores the end of input and errors, which are left to
/// whatever protocol takes the connection next.
///
/// Made with a `gone` callback, it is in *watch mode*: it reads, keeping what arrives, so that the peer's end is
/// noticed while the connection waits. It stops asking to read once `kWatchCap` bytes are kept (one delivery may take
/// it past). On the end of input or a read or write error it runs `gone` and aborts the connection. `gone` also runs
/// when the connection is aborted otherwise. It runs at most once, on the reactor thread.
class HoldProtocol final : public ConnProtocol {
public:
    /// The number of kept bytes, in watch mode, at which the protocol stops reading.
    static constexpr size_t kWatchCap = 1 << 20;

    /// Creates a protocol that does not watch the connection.
    HoldProtocol() = default;
    /// Creates a protocol in watch mode, which calls `gone` when the connection ends.
    explicit HoldProtocol(std::function<void()> gone) : gone_(std::move(gone)) {}

    /// Returns the bytes kept so far, and empties the store.
    std::string takeLeftover() { return std::exchange(leftover_, std::string()); }
    void onData(Conn&, std::string_view bytes) override { leftover_.append(bytes.data(), bytes.size()); }
    void onEof(Conn& c) override { goneNow(c); }
    void onError(Conn& c, int, const std::string&) override { goneNow(c); }
    void onCloseAll(Conn&) override { fireGone(); }
    bool wantsRead() const override { return gone_ != nullptr && leftover_.size() < kWatchCap; }

private:
    /// Runs `gone` if it has not run yet, and leaves the protocol out of watch mode.
    void fireGone() {
        if (!gone_) return;
        std::function<void()> g = std::move(gone_);
        gone_ = nullptr;
        g();
    }
    /// In watch mode, runs `gone` and aborts `c` unless it is already aborted. Out of watch mode, does nothing.
    void goneNow(Conn& c) {
        if (!gone_) return;   // not watching: left to the next protocol
        fireGone();
        if (!c.aborted()) c.abort(false);
    }

    std::string leftover_;
    std::function<void()> gone_;   ///< Null when not watching, and once it has run.
};

/// Everything a `DialJob` needs to make one client handshake.
///
/// The `token` is copied into the `WsEvent` the dial posts; `gen` is copied into it and given to each `Conn`.
struct DialSpec {
    std::vector<std::string> addresses;   ///< Tried in order.
    int64_t port = 0;
    /// Monotonic time (`IoReactor::nowMs`) by which the whole dial must end; 0 or less for none.
    int64_t deadlineMs = 0;
    TransportFactory factory;             ///< Null: plain.
    bool isTls = false;
    std::string request;                  ///< The serialized request head.
    uint64_t token = 0;                   ///< The dial task's resume token.
    uint64_t gen = 0;                     ///< Its heap generation.
    // HTTP/2 (RFC 8441). With `http2`, a connection whose TLS handshake chose ALPN "h2" carries the handshake as an
    // extended CONNECT built from `target`, `authority` and `h2Headers`, instead of `request`. If the server does not
    // allow extended CONNECT, the same address is dialled again with `h1Factory`.
    bool http2 = false;
    TransportFactory h1Factory;
    std::string target, authority;        // :path, :authority
    HeaderList h2Headers;
};

/// One client opening handshake, from the first connect to the response head, or its failure.
///
/// A `DialJob` must be owned by a `std::shared_ptr`, because it hands shared references to itself to the
/// connection's callbacks and protocols. It tries `DialSpec::addresses` in order, moving to the next when a connect
/// fails, all under the one `DialSpec::deadlineMs`: each connect is given what remains of it, and the HTTP/1.1
/// exchange ends at it. On the first connection that opens, it writes the request and reads the response head;
/// with `DialSpec::http2`, a connection that chose h2 is handed instead to the protocol `makeHttp2ClientProtocol`
/// makes, when it makes one.
///
/// The outcome is one `WsEvent` of kind `Dialed`, posted at most once: the status, headers and connection, or a
/// failure's code and message. After the last address fails, the failure is that of its connect, or ENOTFOUND when
/// there were no addresses. A deadline that passes before a connect starts fails with ETIMEDOUT
/// `connect ETIMEDOUT <address>:<port>`, and one that passes while the response head is awaited fails with ETIMEDOUT
/// `WebSocket handshake ETIMEDOUT <address>:<port>`. A response that is not HTTP, a head over `kMaxHead` or a server
/// that closes first fails with ERR_WS_HANDSHAKE, a read or write error keeps its errno name as the code, and a
/// connection aborted from elsewhere during the HTTP/1.1 exchange fails with ECANCELED.
///
/// `start`, `headDone`, `failed`, `h2HeadDone` and `redialHttp1` touch the attempt in progress unguarded and must be
/// called on the reactor thread.
class DialJob : public std::enable_shared_from_this<DialJob> {
public:
    /// Creates a dial for `spec`. Nothing happens until `start`.
    explicit DialJob(DialSpec spec) : spec_(std::move(spec)) {}

    /// Starts connecting to the first address.
    void start();
    /// Cancels the dial if it has not resolved yet, and returns whether it did. When it returns true no event will be
    /// posted, and an abort of the connection in progress, if any, is submitted to the reactor. May be called from any
    /// thread.
    bool cancel();

    /// Reports that the HTTP/1.1 response head `head` was read on `c`, and posts it as a `Dialed` event unless the
    /// dial has resolved, in which case `c` is aborted.
    void headDone(Conn& c, HttpHead head);
    /// Posts a failed `Dialed` event with `code` and `message`, unless the dial has resolved or been cancelled.
    void failed(const std::string& code, const std::string& message);
    /// Returns `DialSpec::deadlineMs`.
    int64_t deadline() const { return spec_.deadlineMs; }
    /// Returns the request head to write over HTTP/1.1. Valid as long as the job.
    const std::string& request() const { return spec_.request; }
    /// Returns `<address>:<port>` for the address tried last, or the first address if none has been tried. An address
    /// containing a colon is put in brackets.
    std::string target() const;

    /// Returns the dial's spec. Valid as long as the job; `redialHttp1` changes its factory and `http2`.
    const DialSpec& spec() const { return spec_; }
    /// Reports that the extended CONNECT on `c` was answered with `status` and `headers`, and posts them as a
    /// `Dialed` event over HTTP/2 unless the dial has resolved, in which case `c` is aborted. The connection keeps
    /// its current protocol.
    void h2HeadDone(Conn& c, int status, HeaderList headers);
    /// Dials the address tried last again, over HTTP/1.1 with `DialSpec::h1Factory`, within the same deadline.
    void redialHttp1();

    /// Who has settled the dial: 0 while nobody has, 1 once its result was posted, 2 once it was cancelled. Each side
    /// moves it from 0 with a compare-and-swap, so only one of them succeeds.
    std::atomic<int> resolved{0};

private:
    /// Connects to the next address, or posts the failure when no address or time is left. Does nothing once the
    /// dial has resolved.
    void tryNext();
    /// Handles the end of a connect on `c`: tries the next address after a failure, or installs the handshake
    /// protocol on an open connection. Aborts an open `c` if the dial was cancelled meanwhile.
    void onConnect(Conn& c, bool ok, const std::string& code, const std::string& message);

    DialSpec spec_;
    size_t next_ = 0;                  ///< Index of the next address to try.
    std::shared_ptr<Conn> current_;    ///< The connection of the attempt in progress, if any.
    std::string lastCode_, lastMessage_;   ///< The last connect failure, reported when no address is left.
};

/// The protocol that reads an opening request head from a server-side connection.
///
/// It reads until a whole head has arrived, then posts one `WsEvent` of kind `UpgradeRead` carrying the method,
/// target, version, headers, the connection, its endpoints and whether it is TLS, and parks the connection in a
/// `HoldProtocol` (not in watch mode) with the bytes read past the head.
///
/// A failure is posted as a failed `UpgradeRead`, once. A head over `kMaxHead` or one that does not parse fails with
/// ERR_WS_HANDSHAKE and is answered with 400 Bad Request before the connection is closed gracefully. Any other
/// failure aborts the connection: ERR_WS_HANDSHAKE when the client ends its input before a head, ETIMEDOUT
/// `upgradeRequest ETIMEDOUT` when the timeout passes, and a read or write error with its errno name as the code.
/// When the connection is aborted from elsewhere, the failure is ECANCELED `socket closed`.
class UpgradeReadProtocol final : public ConnProtocol {
public:
    /// Creates a protocol that reports with `token` and `gen` in its event, and fails if no head has arrived
    /// `timeoutMs` milliseconds after it is installed. A `timeoutMs` of 0 or less sets no limit.
    UpgradeReadProtocol(uint64_t token, uint64_t gen, int64_t timeoutMs)
        : token_(token), gen_(gen), timeoutMs_(timeoutMs) {}

    void onOpen(Conn& c) override;
    void onData(Conn& c, std::string_view bytes) override;
    void onEof(Conn& c) override;
    void onError(Conn& c, int err, const std::string& code) override;
    void onTimer(Conn& c, int timerId) override;
    void onCloseAll(Conn& c) override;
    bool wantsRead() const override { return !done_; }

private:
    /// Posts the failure with `code` and `message`, unless one result was posted already, then answers 400 and
    /// closes `c` gracefully if `answer400`, or aborts it otherwise.
    void fail(Conn& c, const std::string& code, const std::string& message, bool answer400);

    uint64_t token_, gen_;
    int64_t timeoutMs_;
    std::string buf_;
    bool done_ = false;   ///< Set once the result is posted; nothing is read or reported after it.
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_HANDSHAKE_HPP
