//===- TlsTransport.cpp - The TLS Transport of a connection ---------------===//
//===----------------------------------------------------------------------===//

#include "eco-system/Tls/TlsTransport.hpp"

#ifndef _WIN32

#include "eco-system/Core/SocketUtil.hpp"

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#include <cerrno>
#include <cstring>
#include <string>
#include <sys/socket.h>
#include <type_traits>
#include <utility>

namespace Eco::System {

namespace {

/// The most plaintext bytes one `write` passes to OpenSSL, which bounds the ciphertext one write leaves pending.
constexpr size_t kMaxPlain = 64 * 1024;
/// The most ciphertext bytes one `recv` moves into the read BIO.
constexpr size_t kRecvChunk = 32 * 1024;
/// The message of a failed handshake whose peer went away with no TLS error to report.
constexpr const char* kDisconnected =
    "Client network socket disconnected before secure TLS connection was established";

/// A transport that stands for a TLS session that could not be set up: its handshake, reads, writes and shutdown all
/// fail, with the error it was made with. A factory returns one instead of null so that the connection fails rather
/// than falling back to plain bytes.
class FailedTransport final : public Transport {
public:
    /// Creates a transport that fails with `code` and `message`.
    FailedTransport(std::string code, std::string message) {
        errCode = std::move(code);
        errMessage = std::move(message);
    }
    int handshake() override { return -1; }
    ssize_t read(char*, size_t) override { return -2; }
    ssize_t write(const char*, size_t) override { return -2; }
    int shutdownWrite() override { return -1; }
};

/// The TLS session of one connection, over memory BIOs that it fills from and drains to the socket, as the header's
/// file comment describes.
///
/// It owns the `SSL` object, and with it both BIOs, and frees them when destroyed. It does not own the fd. It is held
/// by `std::unique_ptr` and must not be copied or moved: either would free the `SSL` object twice.
class TlsTransport final : public Transport {
public:
    /// Creates the transport for `ssl`, whose memory BIOs must already be attached, over the socket `fd`, and takes
    /// ownership of `ssl`. `cfg` is kept alive as long as the transport. `verify`, `serverName` and `ipLiteral` are
    /// used only to report a failed certificate verification on a client.
    TlsTransport(int fd, SSL* ssl, std::shared_ptr<void> cfg, bool isServer, bool verify,
                 std::string serverName, bool ipLiteral)
        : fd_(fd), ssl_(ssl), cfg_(std::move(cfg)), isServer_(isServer), verify_(verify),
          serverName_(std::move(serverName)), ipLiteral_(ipLiteral) {
        rbio_ = SSL_get_rbio(ssl_);
        wbio_ = SSL_get_wbio(ssl_);
    }

    ~TlsTransport() override { SSL_free(ssl_); }

    /// Returns 1 with exactly one of `wantRead` and `wantWrite` set when it must wait for the socket, and 0 only once
    /// the final flight has been sent. On failure it sends what OpenSSL queued (usually an alert), best effort.
    int handshake() override {
        wantRead = wantWrite = false;
        ERR_clear_error();
        for (;;) {
            int f = sendOut();
            if (f < 0) return -1;
            if (f == 1) {
                wantWrite = true;
                return 1;
            }
            if (hsDone_) return 0;
            int rc = SSL_do_handshake(ssl_);
            if (rc == 1) {
                hsDone_ = true;
                continue;   // the final flight goes out before 0 is returned
            }
            int err = SSL_get_error(ssl_, rc);
            if (err == SSL_ERROR_WANT_READ && !sockEof_) {
                f = sendOut();   // this step's flight goes out before waiting for the peer
                if (f < 0) return -1;
                if (f == 1) {
                    wantWrite = true;
                    return 1;
                }
                ssize_t g = fill();
                if (g >= 0) continue;   // on EOF, the next step reports the failure
                if (g == -1) {
                    wantRead = true;
                    return 1;
                }
                return -1;   // socket error (errCode set)
            }
            if (err == SSL_ERROR_WANT_WRITE) {   // not expected with memory BIOs; wait rather than retry at once
                if (sendOut() < 0) return -1;
                wantWrite = true;
                return 1;
            }
            handshakeFailed(err);
            return -1;
        }
    }

    /// Reads from the socket, one chunk each time OpenSSL needs input, until a record yields plaintext or the socket
    /// would block. A close_notify is the end of input, and so is a TCP FIN without one where the context set
    /// `SSL_OP_IGNORE_UNEXPECTED_EOF`; every later call returns 0. A failed `recv` reports the errno's name.
    ssize_t read(char* buf, size_t n) override {
        wantRead = wantWrite = false;
        if (readEof_) return 0;
        ERR_clear_error();
        (void)sendOut();   // best effort: a failed send is reported by the next write or flush
        for (;;) {
            size_t got = 0;
            int rc = SSL_read_ex(ssl_, buf, n, &got);
            if (rc == 1) {
                (void)sendOut();   // reading may produce output, such as a key update answer
                return static_cast<ssize_t>(got);
            }
            int err = SSL_get_error(ssl_, rc);
            if (err == SSL_ERROR_WANT_READ) {
                if (sockEof_) {   // not expected once the read BIO reports EOF; taken as the end of input
                    readEof_ = true;
                    return 0;
                }
                ssize_t g = fill();
                if (g >= 0) continue;
                if (g == -1) {
                    wantRead = true;
                    return -1;
                }
                return -2;
            }
            if (err == SSL_ERROR_ZERO_RETURN) {   // close_notify, or a FIN under SSL_OP_IGNORE_UNEXPECTED_EOF
                readEof_ = true;
                return 0;
            }
            if (err == SSL_ERROR_WANT_WRITE) {   // not expected with memory BIOs; wait rather than retry at once
                (void)sendOut();
                wantWrite = true;
                return -1;
            }
            protocolFailed(err);
            return -2;
        }
    }

    /// Accepts at most `kMaxPlain` bytes, and none (returning -1 with `wantWrite` set) while earlier output is still
    /// pending. Accepted bytes are encrypted at once; records the socket does not take stay pending.
    /// Once the transport is broken, every call returns -2, with the error of the send that broke it.
    ssize_t write(const char* buf, size_t n) override {
        wantRead = wantWrite = false;
        if (broken_) return sendFailure();
        ERR_clear_error();
        int f = sendOut();
        if (f < 0) return sendFailure();
        if (f == 1) {
            wantWrite = true;
            return -1;
        }
        size_t chunk = n > kMaxPlain ? kMaxPlain : n;
        for (;;) {
            size_t put = 0;
            int rc = SSL_write_ex(ssl_, buf, chunk, &put);
            if (rc == 1) {
                if (sendOut() < 0) return sendFailure();
                return static_cast<ssize_t>(put);
            }
            int err = SSL_get_error(ssl_, rc);
            if (err == SSL_ERROR_WANT_WRITE) {   // not expected with memory BIOs; wait rather than retry at once
                if (sendOut() < 0) return sendFailure();
                wantWrite = true;
                return -1;
            }
            if (err == SSL_ERROR_WANT_READ && !sockEof_) {
                ssize_t g = fill();
                if (g >= 0) continue;
                if (g == -1) {
                    wantRead = true;
                    return -1;
                }
                return -2;
            }
            protocolFailed(err);
            return -2;
        }
    }

    /// Queues a close_notify, unless the handshake has not completed or the session has failed or is broken, and
    /// then shuts down the socket's write side once everything pending has been sent, unless a send fails or the
    /// transport is broken. Returns 1 while that waits for the socket.
    int shutdownWrite() override {
        wantRead = wantWrite = false;
        if (shut_ == Shut::Done) return 0;
        if (shut_ == Shut::None) {
            shut_ = Shut::Pending;
            if (hsDone_ && !fatal_ && !broken_) {
                ERR_clear_error();
                (void)SSL_shutdown(ssl_);   // 0 only means the peer's close_notify has not arrived
                ERR_clear_error();
            }
        }
        int rc = flush();
        if (rc == 1) return 1;
        return rc < 0 ? -1 : 0;
    }

    /// Returns false once the transport is broken, whatever was queued.
    bool hasPendingWrite() const override {
        if (broken_) return false;
        return outOff_ < out_.size() || BIO_ctrl_pending(wbio_) > 0 || shut_ == Shut::Pending;
    }

    /// Also completes a pending `shutdownWrite`: once everything has been sent, it shuts down the socket's write side.
    /// A failure, or a broken transport, ends the shutdown too; a broken transport reports the error of the send that
    /// broke it.
    int flush() override {
        wantRead = wantWrite = false;
        if (broken_) {
            shut_ = Shut::Done;
            return static_cast<int>(sendFailure());
        }
        int f = sendOut();
        if (f == 1) {
            wantWrite = true;
            return 1;
        }
        if (f < 0) {
            shut_ = Shut::Done;
            return static_cast<int>(sendFailure());
        }
        if (shut_ == Shut::Pending) {
            shut_ = Shut::Done;
            if (::shutdown(fd_, SHUT_WR) < 0) {
                failErrno(errno);
                return -2;
            }
        }
        return 0;
    }

    /// Reports the protocol version and cipher by OpenSSL's names, and the ALPN protocol selected, empty when none
    /// was. Returns false until the handshake has completed.
    bool info(TlsInfo& out) const override {
        if (!hsDone_) return false;
        const char* v = SSL_get_version(ssl_);
        out.protocol = v ? v : "";
        const unsigned char* p = nullptr;
        unsigned int len = 0;
        SSL_get0_alpn_selected(ssl_, &p, &len);
        out.alpn = (p && len > 0) ? std::string(reinterpret_cast<const char*>(p), len) : std::string();
        const SSL_CIPHER* c = SSL_get_current_cipher(ssl_);
        const char* name = c ? SSL_CIPHER_get_name(c) : nullptr;
        out.cipher = name ? name : "";
        return true;
    }

private:
    /// How far `shutdownWrite` has got: not asked for, waiting for pending output to be sent before the FIN, or
    /// finished.
    enum class Shut : uint8_t { None, Pending, Done };

    /// Sends the pending ciphertext, taking more from the write BIO as it goes. Returns 0 when nothing is left, 1 when
    /// the socket would block, or -2 when the transport is broken, either already or by a failed send, which drops
    /// everything pending and sets the errno error.
    int sendOut() {
        if (broken_) return -2;
        for (;;) {
            if (outOff_ >= out_.size()) {
                out_.clear();
                outOff_ = 0;
                size_t pending = BIO_ctrl_pending(wbio_);
                if (pending == 0) return 0;
                out_.resize(pending);
                int got = BIO_read(wbio_, out_.data(), static_cast<int>(pending));
                if (got <= 0) {
                    out_.clear();
                    return 0;
                }
                out_.resize(static_cast<size_t>(got));
            }
            ssize_t put = ::send(fd_, out_.data() + outOff_, out_.size() - outOff_, kSendFlags);
            if (put >= 0) {
                outOff_ += static_cast<size_t>(put);
                continue;
            }
            int e = errno;
            if (e == EINTR) continue;
            if (e == EAGAIN || e == EWOULDBLOCK) return 1;
            broken_ = true;   // nothing more can be sent: drop what is queued
            out_.clear();
            outOff_ = 0;
            (void)BIO_reset(wbio_);
            failErrno(e);
            sendErrNo_ = errNo;   // kept apart: a later failed recv overwrites the shared fields (TLS-08)
            sendErrCode_ = errCode;
            sendErrMessage_ = errMessage;
            return -2;
        }
    }

    /// Receives one chunk of up to `kRecvChunk` bytes from the socket into the read BIO. Returns the number of bytes,
    /// 0 at the socket's end of input, after which the read BIO reports end of input to OpenSSL, -1 when the socket
    /// would block, or -2 when `recv` failed, with the errno error set.
    ssize_t fill() {
        char buf[kRecvChunk];
        for (;;) {
            ssize_t got = ::recv(fd_, buf, sizeof(buf), 0);
            if (got > 0) {
                (void)BIO_write(rbio_, buf, static_cast<int>(got));
                return got;
            }
            if (got == 0) {
                sockEof_ = true;
                BIO_set_mem_eof_return(rbio_, 0);
                return 0;
            }
            int e = errno;
            if (e == EINTR) continue;
            if (e == EAGAIN || e == EWOULDBLOCK) return -1;
            failErrno(e);
            return -2;
        }
    }

    /// Reports the failed send that broke the transport: copies its error back into the shared error fields, which a
    /// failed read may have overwritten since, and returns -2. Called only once `broken_` is set.
    ssize_t sendFailure() {
        errNo = sendErrNo_;
        errCode = sendErrCode_;
        errMessage = sendErrMessage_;
        return -2;
    }

    /// Records the errno `e` as the failure: its name as the code and its description as the message.
    void failErrno(int e) {
        errNo = e;
        errCode = errnoName(e);
        errMessage = std::strerror(e);
    }

    /// Records why the handshake failed with the `SSL_get_error` result `err`, as the header's file comment describes,
    /// marks the session failed, and sends what OpenSSL queued, best effort. A failed verification takes precedence
    /// over an OpenSSL error; an error code already set is kept when there is neither.
    void handshakeFailed(int err) {
        fatal_ = true;
        unsigned long e = ERR_peek_error();
        long v = (!isServer_ && verify_) ? SSL_get_verify_result(ssl_) : X509_V_OK;
        if (v != X509_V_OK) {
            errNo = 0;
            errCode = tlsVerifyCode(v);
            if (errCode == "ERR_TLS_CERT_ALTNAME_INVALID") {
                errMessage = std::string("Hostname/IP does not match certificate's altnames: ") +
                             (ipLiteral_ ? "IP: " : "Host: ") + serverName_ +
                             (ipLiteral_ ? " is not in the cert's list" : " is not in the cert's altnames");
            } else {
                const char* s = X509_verify_cert_error_string(v);
                errMessage = s ? s : errCode;
            }
        } else if (err == SSL_ERROR_SSL && e != 0) {
            errNo = 0;
            errCode = tlsErrorCode(e);
            errMessage = tlsErrorMessage(e);
        } else if (errCode.empty()) {
            errNo = ECONNRESET;
            errCode = "ECONNRESET";
            errMessage = kDisconnected;
        }
        ERR_clear_error();
        (void)sendOut();   // best effort: the alert OpenSSL queued
    }

    /// Records why a read or write failed with the `SSL_get_error` result `err`: the queued OpenSSL error, or else
    /// ECONNRESET. Marks the session failed, so that `shutdownWrite` sends no close_notify.
    void protocolFailed(int err) {
        fatal_ = true;
        unsigned long e = ERR_peek_error();
        if (err == SSL_ERROR_SSL && e != 0) {
            errNo = 0;
            errCode = tlsErrorCode(e);
            errMessage = tlsErrorMessage(e);
        } else {
            errNo = ECONNRESET;
            errCode = "ECONNRESET";
            errMessage = std::strerror(ECONNRESET);
        }
        ERR_clear_error();
    }

    int fd_;      ///< Not owned; the `Conn` closes it.
    SSL* ssl_;    ///< Owned; freed in the destructor; never null.
    BIO* rbio_ = nullptr;   ///< The read BIO, owned by `ssl_`.
    BIO* wbio_ = nullptr;   ///< The write BIO, owned by `ssl_`.
    std::shared_ptr<void> cfg_;   ///< Kept alive: a server context's ALPN callback points to it.
    const bool isServer_;
    const bool verify_;
    const std::string serverName_;
    const bool ipLiteral_;

    std::string out_;          ///< Ciphertext taken from `wbio_`; the bytes before `outOff_` have been sent.
    size_t outOff_ = 0;
    bool hsDone_ = false;
    bool sockEof_ = false;     ///< `recv` returned 0.
    bool readEof_ = false;     ///< The session reported the end of input.
    bool broken_ = false;      ///< A send failed: nothing more goes out.
    int sendErrNo_ = 0;           ///< The error of the send that set `broken_`.
    std::string sendErrCode_;
    std::string sendErrMessage_;
    bool fatal_ = false;       ///< The handshake, a read or a write failed.
    Shut shut_ = Shut::None;
};

// TLS-01: copying or moving would free the `SSL` object twice; `Transport` deletes the copy operations, which also
// suppresses the implicit moves.
static_assert(!std::is_copy_constructible_v<TlsTransport> && !std::is_copy_assignable_v<TlsTransport> &&
              !std::is_move_constructible_v<TlsTransport> && !std::is_move_assignable_v<TlsTransport>);

/// Attaches a new read and write memory BIO to `ssl`, which then owns them, and returns true, or returns false,
/// with nothing attached, when one cannot be allocated.
bool attachBios(SSL* ssl) {
    BIO* r = BIO_new(BIO_s_mem());
    BIO* w = BIO_new(BIO_s_mem());
    if (!r || !w) {
        if (r) BIO_free(r);
        if (w) BIO_free(w);
        return false;
    }
    SSL_set_bio(ssl, r, w);
    return true;
}

/// Returns a `FailedTransport` for the first OpenSSL error queued on this thread, with a message prefixed by `what`,
/// and clears the queue.
std::unique_ptr<Transport> failed(const char* what) {
    unsigned long e = ERR_get_error();
    ERR_clear_error();
    return std::make_unique<FailedTransport>(tlsErrorCode(e),
                                             std::string(what) + ": " + tlsErrorMessage(e));
}

} // namespace

TransportFactory makeTlsClientFactory(std::shared_ptr<TlsClientConfig> cfg) {
    return [cfg](int fd, bool /*isServer*/) -> std::unique_ptr<Transport> {
        ERR_clear_error();
        SSL* ssl = SSL_new(cfg->ctx.get());
        if (!ssl) return failed("SSL_new");
        if (!attachBios(ssl)) {
            SSL_free(ssl);
            return failed("BIO_new");
        }
        SSL_set_connect_state(ssl);
        const std::string& name = cfg->serverName;
        bool ok = true;
        if (!name.empty() && !cfg->ipLiteral) {
            // A DNS name: SNI, and (verifying) the certificate must match it.
            ok = SSL_set_tlsext_host_name(ssl, name.c_str()) == 1;
            if (ok && cfg->verify) {
                SSL_set_hostflags(ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
                ok = SSL_set1_host(ssl, name.c_str()) == 1;
            }
        } else if (!name.empty() && cfg->verify) {
            // An IP literal: SNI may carry only a DNS name, so the certificate's IP addresses are checked instead.
            ok = X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), name.c_str()) == 1;
        }
        if (ok && !cfg->alpnWire.empty()) {
            ok = SSL_set_alpn_protos(ssl, reinterpret_cast<const unsigned char*>(cfg->alpnWire.data()),
                                     static_cast<unsigned int>(cfg->alpnWire.size())) == 0;
        }
        if (!ok) {
            SSL_free(ssl);
            return failed("TLS client setup");
        }
        return std::make_unique<TlsTransport>(fd, ssl, cfg, /*isServer=*/false, cfg->verify, name,
                                              cfg->ipLiteral);
    };
}

TransportFactory makeTlsServerFactory(std::shared_ptr<TlsServerConfig> cfg) {
    return [cfg](int fd, bool /*isServer*/) -> std::unique_ptr<Transport> {
        ERR_clear_error();
        SSL* ssl = SSL_new(cfg->ctx.get());
        if (!ssl) return failed("SSL_new");
        if (!attachBios(ssl)) {
            SSL_free(ssl);
            return failed("BIO_new");
        }
        SSL_set_accept_state(ssl);
        return std::make_unique<TlsTransport>(fd, ssl, cfg, /*isServer=*/true, /*verify=*/false,
                                              std::string(), false);
    };
}

} // namespace Eco::System

#else // _WIN32: no OpenSSL.

namespace Eco::System {

TransportFactory makeTlsClientFactory(std::shared_ptr<TlsClientConfig>) { return nullptr; }
TransportFactory makeTlsServerFactory(std::shared_ptr<TlsServerConfig>) { return nullptr; }

} // namespace Eco::System

#endif
