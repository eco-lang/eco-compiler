//===- TlsTransport.cpp - The TLS Transport of a connection ---------------===//
//
// See TlsTransport.hpp (plans/eco-system-sockets.md §3.6, §D.5, N6, N7).
// Reactor thread only: the OpenSSL error queue used here is the reactor
// thread's own, cleared before every operation.
//
// Templates used: none (POD and OpenSSL only, G1).
//
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
#include <utility>

namespace Eco::System {

namespace {

constexpr size_t kMaxPlain = 64 * 1024;    // plaintext per SSL_write (bounds pending output)
constexpr size_t kRecvChunk = 32 * 1024;   // ciphertext per recv into the read BIO
constexpr const char* kDisconnected =
    "Client network socket disconnected before secure TLS connection was established";

// A transport whose handshake fails at once (SSL_new failed): a TLS
// connection must never fall back to plain bytes.
class FailedTransport final : public Transport {
public:
    FailedTransport(std::string code, std::string message) {
        errCode = std::move(code);
        errMessage = std::move(message);
    }
    int handshake() override { return -1; }
    ssize_t read(char*, size_t) override { return -2; }
    ssize_t write(const char*, size_t) override { return -2; }
    int shutdownWrite() override { return -1; }
};

class TlsTransport final : public Transport {
public:
    TlsTransport(int fd, SSL* ssl, std::shared_ptr<void> cfg, bool isServer, bool verify,
                 std::string serverName, bool ipLiteral)
        : fd_(fd), ssl_(ssl), cfg_(std::move(cfg)), isServer_(isServer), verify_(verify),
          serverName_(std::move(serverName)), ipLiteral_(ipLiteral) {
        rbio_ = SSL_get_rbio(ssl_);
        wbio_ = SSL_get_wbio(ssl_);
    }

    ~TlsTransport() override { SSL_free(ssl_); }   // frees both BIOs

    int handshake() override {
        wantRead = wantWrite = false;
        ERR_clear_error();
        for (;;) {
            int f = sendOut();
            if (f < 0) return -1;   // errCode set (the peer is gone)
            if (f == 1) {
                wantWrite = true;
                return 1;
            }
            if (hsDone_) return 0;   // and the final flight is on the socket
            int rc = SSL_do_handshake(ssl_);
            if (rc == 1) {
                hsDone_ = true;
                continue;   // send the last flight first
            }
            int err = SSL_get_error(ssl_, rc);
            if (err == SSL_ERROR_WANT_READ && !sockEof_) {
                f = sendOut();   // what this step produced goes out before we wait
                if (f < 0) return -1;
                if (f == 1) {
                    wantWrite = true;
                    return 1;
                }
                ssize_t g = fill();
                if (g >= 0) continue;   // data, or EOF (OpenSSL reports it next)
                if (g == -1) {
                    wantRead = true;
                    return 1;
                }
                return -1;   // socket error (errCode set)
            }
            if (err == SSL_ERROR_WANT_WRITE) {   // not with memory BIOs; never spin inline
                if (sendOut() < 0) return -1;
                wantWrite = true;
                return 1;
            }
            handshakeFailed(err);
            return -1;
        }
    }

    ssize_t read(char* buf, size_t n) override {
        wantRead = wantWrite = false;
        if (readEof_) return 0;
        ERR_clear_error();
        (void)sendOut();   // best effort: pending records first (errors show up on writes)
        for (;;) {
            size_t got = 0;
            int rc = SSL_read_ex(ssl_, buf, n, &got);
            if (rc == 1) {
                (void)sendOut();   // reading may produce output (a KeyUpdate answer)
                return static_cast<ssize_t>(got);
            }
            int err = SSL_get_error(ssl_, rc);
            if (err == SSL_ERROR_WANT_READ) {
                if (sockEof_) {   // should not happen (IGNORE_UNEXPECTED_EOF): treat as EOF
                    readEof_ = true;
                    return 0;
                }
                ssize_t g = fill();
                if (g >= 0) continue;
                if (g == -1) {
                    wantRead = true;
                    return -1;
                }
                return -2;   // socket error: "read ECONNRESET"
            }
            if (err == SSL_ERROR_ZERO_RETURN) {   // close_notify, or FIN (unexpected EOF ignored)
                readEof_ = true;
                return 0;
            }
            if (err == SSL_ERROR_WANT_WRITE) {   // not with memory BIOs; never spin inline
                (void)sendOut();
                wantWrite = true;
                return -1;
            }
            protocolFailed(err);
            return -2;
        }
    }

    ssize_t write(const char* buf, size_t n) override {
        wantRead = wantWrite = false;
        if (broken_) return -2;   // errCode kept from the failed send
        ERR_clear_error();
        int f = sendOut();
        if (f < 0) return -2;
        if (f == 1) {   // the previous records first: bounds what we hold (64 KiB + overhead)
            wantWrite = true;
            return -1;
        }
        size_t chunk = n > kMaxPlain ? kMaxPlain : n;
        for (;;) {
            size_t put = 0;
            int rc = SSL_write_ex(ssl_, buf, chunk, &put);
            if (rc == 1) {
                if (sendOut() < 0) return -2;
                return static_cast<ssize_t>(put);   // records the socket did not take stay pending
            }
            int err = SSL_get_error(ssl_, rc);
            if (err == SSL_ERROR_WANT_WRITE) {   // not with memory BIOs; never spin inline
                if (sendOut() < 0) return -2;
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

    int shutdownWrite() override {
        wantRead = wantWrite = false;
        if (shut_ == Shut::Done) return 0;
        if (shut_ == Shut::None) {
            shut_ = Shut::Pending;
            if (hsDone_ && !fatal_ && !broken_) {
                ERR_clear_error();
                (void)SSL_shutdown(ssl_);   // queues close_notify (0: the peer's is not here yet)
                ERR_clear_error();
            }
        }
        int rc = flush();
        if (rc == 1) return 1;   // the Conn keeps flushing (hasPendingWrite)
        return rc < 0 ? -1 : 0;
    }

    bool hasBufferedRead() const override {
        return !readEof_ && (SSL_has_pending(ssl_) == 1 || BIO_ctrl_pending(rbio_) > 0);
    }

    bool hasPendingWrite() const override {
        if (broken_) return false;
        return outOff_ < out_.size() || BIO_ctrl_pending(wbio_) > 0 || shut_ == Shut::Pending;
    }

    int flush() override {
        wantRead = wantWrite = false;
        if (broken_) {
            shut_ = Shut::Done;
            return -2;
        }
        int f = sendOut();
        if (f == 1) {
            wantWrite = true;
            return 1;
        }
        if (f < 0) {
            shut_ = Shut::Done;
            return -2;
        }
        if (shut_ == Shut::Pending) {   // close_notify is on the socket: now the FIN
            shut_ = Shut::Done;
            if (::shutdown(fd_, SHUT_WR) < 0) {
                failErrno(errno);
                return -2;
            }
        }
        return 0;
    }

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
    enum class Shut : uint8_t { None, Pending, Done };

    // Sends the queued ciphertext: 0 all sent, 1 the socket is full, -2 error.
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
            return -2;
        }
    }

    // One recv into the read BIO: >0 bytes, 0 EOF (the BIO then reports EOF
    // to OpenSSL), -1 would block, -2 error (errCode set).
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

    void failErrno(int e) {
        errNo = e;
        errCode = errnoName(e);
        errMessage = std::strerror(e);
    }

    // §D.5 for a failed handshake.
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
        } else if (errCode.empty()) {   // EOF / reset during the handshake (as Node)
            errNo = ECONNRESET;
            errCode = "ECONNRESET";
            errMessage = kDisconnected;
        }
        ERR_clear_error();
        (void)sendOut();   // best effort: the alert OpenSSL queued
    }

    // §D.5 for a failed read/write after the handshake.
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

    int fd_;
    SSL* ssl_;
    BIO* rbio_ = nullptr;   // network → OpenSSL
    BIO* wbio_ = nullptr;   // OpenSSL → network
    std::shared_ptr<void> cfg_;   // keeps the context configuration (ALPN callback arg) alive
    const bool isServer_;
    const bool verify_;
    const std::string serverName_;
    const bool ipLiteral_;

    std::string out_;          // ciphertext taken from wbio_, not yet sent
    size_t outOff_ = 0;
    bool hsDone_ = false;
    bool sockEof_ = false;     // recv returned 0
    bool readEof_ = false;     // SSL_read reported the end
    bool broken_ = false;      // a send failed: nothing more goes out
    bool fatal_ = false;       // OpenSSL reported a fatal error
    Shut shut_ = Shut::None;
};

// Memory BIOs for `ssl` (owned by it). False on allocation failure.
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
            // An IP literal: no SNI (RFC 6066), an IP SAN check instead (J11).
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

#else // _WIN32: no OpenSSL; never reached (the kernels fail ENOTSUP first, §1)

namespace Eco::System {

TransportFactory makeTlsClientFactory(std::shared_ptr<TlsClientConfig>) { return nullptr; }
TransportFactory makeTlsServerFactory(std::shared_ptr<TlsServerConfig>) { return nullptr; }

} // namespace Eco::System

#endif
