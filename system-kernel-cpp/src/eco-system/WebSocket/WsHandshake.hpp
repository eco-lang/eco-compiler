//===- WsHandshake.hpp - The kernel side of the opening handshake ---------===//
//
// plans/eco-system-websockets.md §3.6 "Handshake execution", Appendix B.1
// (dial, readUpgrade), D.2, D.3. Elm owns the handshake's rules
// (WebSocket.Internal.Handshake: the request headers, the checks of a
// response and of a request, the negotiation); this side only moves bytes:
//
//   * key / accept: Sec-WebSocket-Key (16 random bytes, base64) and
//     Sec-WebSocket-Accept (base64 SHA-1 of key ++ the RFC 6455 GUID),
//     OpenSSL natively (WF5).
//   * HTTP heads: finding the end of a head (CRLF CRLF, or LF LF), at most
//     kMaxHead (64 KiB); parsing a request line or a status line and the
//     header fields (names kept in their original case, duplicates and
//     order kept; obs-fold, a space before the colon, an invalid name or a
//     control character in a value are errors); serializing a request and
//     a response (101, a reject's status + body).
//   * Connection protocols (Conn.hpp §3.2, reactor thread):
//       - DialJob + DialProtocol (client, `dial`): tries each address in
//         order under ONE deadline (connect, TLS handshake and the HTTP
//         exchange), writes the request, reads the response head, then
//         parks the connection in a HoldProtocol and posts one WsEvent
//         Dialed (the status and headers, or the failure). A kill races the
//         result through DialJob::resolved (exactly one side wins, as
//         Conn::cancelConnect).
//       - UpgradeReadProtocol (server, `readUpgrade`): reads a request head
//         from a Socket.Connection taken over from its stream faces, then
//         parks the connection in a HoldProtocol and posts one WsEvent
//         UpgradeRead. A request that is not HTTP is answered 400 and the
//         connection closed.
//       - HoldProtocol: reads nothing and keeps the bytes read past the
//         head (a frame sent right behind it) for `open` (or until
//         `reject` / `abandon`).
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WS_HANDSHAKE_HPP
#define ECO_SYSTEM_WEBSOCKET_WS_HANDSHAKE_HPP

#include "eco-system/Socket/Conn.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace Eco::System {

using HeaderList = std::vector<std::pair<std::string, std::string>>;

// --- Key / accept (any thread) ----------------------------------------------------

// Sec-WebSocket-Accept for a key: base64(SHA-1(key ++ RFC 6455 GUID)).
std::string wsAcceptFor(const std::string& key);
// A fresh Sec-WebSocket-Key: base64 of 16 random bytes.
std::string wsNewKey();
// Fills `n` bytes with unpredictable bytes (masking keys, ping payloads; D.8).
void wsRandomBytes(unsigned char* out, size_t n);

// --- HTTP heads (pure) --------------------------------------------------------------

constexpr size_t kMaxHead = 64 * 1024;

struct HttpHead {
    // Request: method, target, version ("1.1"). Response: version, status, reason.
    std::string method, target, version;
    int status = 0;
    std::string reasonPhrase;
    HeaderList headers;   // in order, original case, values trimmed
};

// The length of the head (through its blank line) at the start of `buf`, or
// 0 if it is not complete yet.
size_t httpHeadLength(std::string_view buf);

bool parseRequestHead(std::string_view head, HttpHead& out, std::string& err);
bool parseResponseHead(std::string_view head, HttpHead& out, std::string& err);

// A header a peer may be sent: the name an RFC 9110 token, the value without
// CR, LF or NUL.
bool httpHeaderValid(const std::string& name, const std::string& value);

// "GET <target> HTTP/1.1" and the headers (invalid ones are skipped).
std::string serializeRequest(const std::string& target, const HeaderList& headers);
// "HTTP/1.1 <status> <reason>", the headers (invalid ones skipped) and, when
// `withBody`, Content-Length + Connection: close + the body (a reject).
std::string serializeResponse(int status, const HeaderList& headers, bool withBody,
                              const std::string& body);
const char* httpStatusReason(int status);

// --- Connection protocols (reactor thread) ------------------------------------------

// Parks a handshaken connection: no reading; keeps what was read past the
// head (setProtocol's leftover) for the codec.
class HoldProtocol final : public ConnProtocol {
public:
    std::string takeLeftover() { return std::exchange(leftover_, std::string()); }
    void onData(Conn&, std::string_view bytes) override { leftover_.append(bytes.data(), bytes.size()); }
    void onEof(Conn&) override {}
    void onError(Conn&, int, const std::string&) override {}
    void onCloseAll(Conn&) override {}
    bool wantsRead() const override { return false; }

private:
    std::string leftover_;
};

struct DialSpec {
    std::vector<std::string> addresses;   // tried in order
    int64_t port = 0;
    int64_t deadlineMs = 0;               // monotonic (IoReactor::nowMs); 0: none
    TransportFactory factory;             // null: plain
    bool isTls = false;
    std::string request;                  // the serialized request head
    uint64_t token = 0;                   // the dial task's resume token
    uint64_t gen = 0;                     // its heap generation
    // WS9 (RFC 8441, `http2 = True` on wss): `factory` offers ALPN h2 and
    // http/1.1; when the server chose h2 the request is an extended CONNECT
    // (Http2Client.hpp) with these fields; a server without
    // ENABLE_CONNECT_PROTOCOL is redialed with `h1Factory` (ALPN http/1.1).
    bool http2 = false;
    TransportFactory h1Factory;
    std::string target, authority;        // :path, :authority
    HeaderList h2Headers;                 // lower-case names; no Host, Upgrade, Connection or key
};

class DialJob : public std::enable_shared_from_this<DialJob> {
public:
    explicit DialJob(DialSpec spec) : spec_(std::move(spec)) {}

    // Reactor thread: connect to the first address.
    void start();
    // Main thread (the kill handle): true iff the dial had not resolved yet;
    // then nothing will be posted (the caller releases the count) and the
    // attempt in progress is aborted.
    bool cancel();

    // Reactor thread (DialProtocol).
    void headDone(Conn& c, HttpHead head, bool ok, const std::string& err);
    void failed(const std::string& code, const std::string& message);
    int64_t deadline() const { return spec_.deadlineMs; }
    const std::string& request() const { return spec_.request; }
    std::string target() const;

    // Reactor thread (Http2ClientProtocol, WS9).
    const DialSpec& spec() const { return spec_; }
    // The extended CONNECT was answered: posts Dialed with isH2 (the
    // connection stays in its Http2ClientProtocol until open / abandon).
    void h2HeadDone(Conn& c, int status, HeaderList headers);
    // The server's SETTINGS do not allow extended CONNECT: the same address
    // again over HTTP/1.1 (ALPN http/1.1), within the same deadline.
    void redialHttp1();

    std::atomic<int> resolved{0};   // 0 pending, 1 posted, 2 cancelled

private:
    void tryNext();
    void onConnect(Conn& c, bool ok, const std::string& code, const std::string& message);

    DialSpec spec_;
    size_t next_ = 0;
    std::shared_ptr<Conn> current_;
    std::string lastCode_, lastMessage_;
};

// Server: reads a request head (readUpgrade). `timeoutMs` bounds it.
class UpgradeReadProtocol final : public ConnProtocol {
public:
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
    void fail(Conn& c, const std::string& code, const std::string& message, bool answer400);

    uint64_t token_, gen_;
    int64_t timeoutMs_;
    std::string buf_;
    bool done_ = false;
};

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WS_HANDSHAKE_HPP
