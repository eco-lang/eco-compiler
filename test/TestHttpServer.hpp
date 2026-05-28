#pragma once
//===- TestHttpServer.hpp - in-process HTTP server for elm/http E2E --------===//
//
// A tiny HTTP/1.1 reflector used by the elm-http E2E suite. It runs in the
// PARENT test process (started before the suite forks per-test children); the
// forked children issue real requests to 127.0.0.1:<port> and the parent
// serves them. Per-connection detached threads so a /slow request never blocks
// others. POD-only, no Eco heap interaction.
//
// Routes:
//   /anything        -> 200 JSON reflecting {method, contentType, body, headers}
//   /status/{code}   -> responds with HTTP status {code}
//   /echo-headers    -> 200 JSON of request headers; sets X-Test-Server: eco
//   /bytes/{n}       -> 200 application/octet-stream, n bytes (i & 0xff)
//   /slow            -> sleeps ~3s then 200 (drives Timeout)
//   /redirect        -> 302 Location: /anything
//   /package.zip     -> 200 application/zip, a canned 2-entry STORED zip
//                       (for the Eco.Http.getArchive E2E test)
//===----------------------------------------------------------------------===//

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace ElmHttpTestServer {

// A minimal STORED (uncompressed) ZIP with two entries:
//   pkg-1.0.0/elm.json     -> {"name":"dummy","version":"1.0.0"}
//   pkg-1.0.0/src/Main.elm -> module Main exposing (..)
// Served at /package.zip for Eco.Http.getArchive. getArchive strips the leading
// directory, so entries appear as elm.json / src/Main.elm.
static const unsigned char kDummyPackageZip[] = {
    0x50,0x4b,0x03,0x04,0x14,0x00,0x00,0x00,0x00,0x00,0x4e,0x73,0xbc,0x5c,0xe1,0x9f,
    0x7c,0x15,0x22,0x00,0x00,0x00,0x22,0x00,0x00,0x00,0x12,0x00,0x00,0x00,0x70,0x6b,
    0x67,0x2d,0x31,0x2e,0x30,0x2e,0x30,0x2f,0x65,0x6c,0x6d,0x2e,0x6a,0x73,0x6f,0x6e,
    0x7b,0x22,0x6e,0x61,0x6d,0x65,0x22,0x3a,0x22,0x64,0x75,0x6d,0x6d,0x79,0x22,0x2c,
    0x22,0x76,0x65,0x72,0x73,0x69,0x6f,0x6e,0x22,0x3a,0x22,0x31,0x2e,0x30,0x2e,0x30,
    0x22,0x7d,0x50,0x4b,0x03,0x04,0x14,0x00,0x00,0x00,0x00,0x00,0x4e,0x73,0xbc,0x5c,
    0x58,0x63,0xde,0x52,0x1a,0x00,0x00,0x00,0x1a,0x00,0x00,0x00,0x16,0x00,0x00,0x00,
    0x70,0x6b,0x67,0x2d,0x31,0x2e,0x30,0x2e,0x30,0x2f,0x73,0x72,0x63,0x2f,0x4d,0x61,
    0x69,0x6e,0x2e,0x65,0x6c,0x6d,0x6d,0x6f,0x64,0x75,0x6c,0x65,0x20,0x4d,0x61,0x69,
    0x6e,0x20,0x65,0x78,0x70,0x6f,0x73,0x69,0x6e,0x67,0x20,0x28,0x2e,0x2e,0x29,0x0a,
    0x50,0x4b,0x01,0x02,0x14,0x03,0x14,0x00,0x00,0x00,0x00,0x00,0x4e,0x73,0xbc,0x5c,
    0xe1,0x9f,0x7c,0x15,0x22,0x00,0x00,0x00,0x22,0x00,0x00,0x00,0x12,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x80,0x01,0x00,0x00,0x00,0x00,0x70,0x6b,
    0x67,0x2d,0x31,0x2e,0x30,0x2e,0x30,0x2f,0x65,0x6c,0x6d,0x2e,0x6a,0x73,0x6f,0x6e,
    0x50,0x4b,0x01,0x02,0x14,0x03,0x14,0x00,0x00,0x00,0x00,0x00,0x4e,0x73,0xbc,0x5c,
    0x58,0x63,0xde,0x52,0x1a,0x00,0x00,0x00,0x1a,0x00,0x00,0x00,0x16,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x80,0x01,0x52,0x00,0x00,0x00,0x70,0x6b,
    0x67,0x2d,0x31,0x2e,0x30,0x2e,0x30,0x2f,0x73,0x72,0x63,0x2f,0x4d,0x61,0x69,0x6e,
    0x2e,0x65,0x6c,0x6d,0x50,0x4b,0x05,0x06,0x00,0x00,0x00,0x00,0x02,0x00,0x02,0x00,
    0x84,0x00,0x00,0x00,0xa0,0x00,0x00,0x00,0x00,0x00,
};

// Extract a long-valued query parameter (e.g. "bytes=2048"), or `def` if absent.
inline long queryLong(const std::string& query, const std::string& key, long def) {
    std::string pat = key + "=";
    size_t pos = query.find(pat);
    if (pos == std::string::npos) return def;
    return std::atol(query.c_str() + pos + pat.size());
}

inline std::string jsonEscape(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '"' || c == '\\') { out.push_back('\\'); out.push_back(c); }
        else if (c == '\n') { out += "\\n"; }
        else if (c == '\r') { out += "\\r"; }
        else { out.push_back(c); }
    }
    return out;
}

struct ParsedRequest {
    std::string method;
    std::string path;
    std::map<std::string, std::string> headers;  // lowercased keys
    std::string body;
};

// A connection that is either plaintext (ssl == nullptr) or TLS.
struct Conn {
    int fd = -1;
    SSL* ssl = nullptr;
    ssize_t read(void* buf, size_t n) {
        return ssl ? SSL_read(ssl, buf, static_cast<int>(n)) : ::read(fd, buf, n);
    }
    ssize_t write(const void* buf, size_t n) {
        return ssl ? SSL_write(ssl, buf, static_cast<int>(n)) : ::write(fd, buf, n);
    }
    void close() {
        if (ssl) { SSL_shutdown(ssl); SSL_free(ssl); }
        ::close(fd);
    }
};

inline bool readRequest(Conn& conn, ParsedRequest& req) {
    std::string buf;
    char tmp[4096];
    // Read until end of headers.
    size_t headerEnd = std::string::npos;
    while (headerEnd == std::string::npos) {
        ssize_t n = conn.read(tmp, sizeof(tmp));
        if (n <= 0) return false;
        buf.append(tmp, static_cast<size_t>(n));
        headerEnd = buf.find("\r\n\r\n");
        if (buf.size() > (1u << 20)) return false;  // 1MB header cap
    }
    std::string head = buf.substr(0, headerEnd);
    std::string rest = buf.substr(headerEnd + 4);

    std::istringstream hs(head);
    std::string line;
    std::getline(hs, line);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    {
        std::istringstream ls(line);
        std::string version;
        ls >> req.method >> req.path >> version;
    }
    while (std::getline(hs, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        size_t colon = line.find(':');
        if (colon == std::string::npos) continue;
        std::string key = line.substr(0, colon);
        std::string val = line.substr(colon + 1);
        while (!val.empty() && (val.front() == ' ' || val.front() == '\t')) val.erase(0, 1);
        for (auto& c : key) c = static_cast<char>(std::tolower(c));
        req.headers[key] = val;
    }

    size_t contentLength = 0;
    auto it = req.headers.find("content-length");
    if (it != req.headers.end()) contentLength = std::strtoul(it->second.c_str(), nullptr, 10);

    req.body = rest;
    while (req.body.size() < contentLength) {
        ssize_t n = conn.read(tmp, sizeof(tmp));
        if (n <= 0) break;
        req.body.append(tmp, static_cast<size_t>(n));
    }
    return !req.method.empty();
}

inline void writeAll(Conn& conn, const std::string& s) {
    size_t off = 0;
    while (off < s.size()) {
        ssize_t n = conn.write(s.data() + off, s.size() - off);
        if (n <= 0) break;
        off += static_cast<size_t>(n);
    }
}

inline void sendResponse(Conn& conn, int status, const std::string& reason,
                         const std::string& contentType, const std::string& body,
                         const std::string& extraHeaders = "") {
    std::ostringstream os;
    os << "HTTP/1.1 " << status << " " << reason << "\r\n"
       << "Content-Type: " << contentType << "\r\n"
       << "Content-Length: " << body.size() << "\r\n"
       << "Connection: close\r\n"
       << extraHeaders
       << "\r\n"
       << body;
    writeAll(conn, os.str());
}

inline void handleConnection(Conn conn) {
    ParsedRequest req;
    if (readRequest(conn, req)) {
        // Strip query string for routing.
        std::string route = req.path;
        size_t q = route.find('?');
        std::string query = (q == std::string::npos) ? "" : route.substr(q + 1);
        if (q != std::string::npos) route = route.substr(0, q);

        if (route == "/anything") {
            std::string ct;
            auto it = req.headers.find("content-type");
            if (it != req.headers.end()) ct = it->second;
            std::ostringstream hs;
            hs << "{";
            bool first = true;
            for (auto& kv : req.headers) {
                if (!first) hs << ",";
                hs << "\"" << jsonEscape(kv.first) << "\":\"" << jsonEscape(kv.second) << "\"";
                first = false;
            }
            hs << "}";
            std::ostringstream os;
            os << "{\"method\":\"" << jsonEscape(req.method) << "\","
               << "\"contentType\":\"" << jsonEscape(ct) << "\","
               << "\"body\":\"" << jsonEscape(req.body) << "\","
               << "\"headers\":" << hs.str() << "}";
            sendResponse(conn, 200, "OK", "application/json", os.str());
        } else if (route.rfind("/status/", 0) == 0) {
            int code = std::atoi(route.substr(8).c_str());
            if (code <= 0) code = 200;
            sendResponse(conn, code, "Status", "text/plain",
                         "status " + std::to_string(code));
        } else if (route == "/echo-headers") {
            std::ostringstream os;
            os << "{";
            bool first = true;
            for (auto& kv : req.headers) {
                if (!first) os << ",";
                os << "\"" << jsonEscape(kv.first) << "\":\"" << jsonEscape(kv.second) << "\"";
                first = false;
            }
            os << "}";
            sendResponse(conn, 200, "OK", "application/json", os.str(),
                         "X-Test-Server: eco\r\n");
        } else if (route.rfind("/bytes/", 0) == 0) {
            int n = std::atoi(route.substr(7).c_str());
            if (n < 0) n = 0;
            std::string body;
            body.reserve(static_cast<size_t>(n));
            for (int i = 0; i < n; ++i) body.push_back(static_cast<char>(i & 0xff));
            sendResponse(conn, 200, "OK", "application/octet-stream", body);
        } else if (route == "/slow") {
            long ms = 3000;
            size_t pos = query.find("ms=");
            if (pos != std::string::npos) ms = std::atol(query.c_str() + pos + 3);
            std::this_thread::sleep_for(std::chrono::milliseconds(ms));
            sendResponse(conn, 200, "OK", "text/plain", "slow");
        } else if (route == "/drip") {
            // Known-length streamed body: Content-Length set, then `bytes` bytes
            // written over ~`ms` ms in small chunks with per-chunk sleeps, so
            // curl reports incremental Receiving progress with size = Just bytes.
            long bytes = queryLong(query, "bytes", 1024);
            long ms = queryLong(query, "ms", 500);
            if (bytes < 0) bytes = 0;
            const long kChunks = 8;
            std::ostringstream hdr;
            hdr << "HTTP/1.1 200 OK\r\n"
                << "Content-Type: application/octet-stream\r\n"
                << "Content-Length: " << bytes << "\r\n"
                << "Connection: close\r\n\r\n";
            writeAll(conn, hdr.str());
            long written = 0;
            long perChunk = (bytes + kChunks - 1) / kChunks;
            if (perChunk < 1) perChunk = 1;
            while (written < bytes) {
                long n = bytes - written;
                if (n > perChunk) n = perChunk;
                writeAll(conn, std::string(static_cast<size_t>(n), 'x'));
                written += n;
                if (written < bytes) {
                    std::this_thread::sleep_for(
                        std::chrono::milliseconds(ms / kChunks));
                }
            }
        } else if (route == "/drip-chunked") {
            // Unknown-length streamed body: Transfer-Encoding: chunked (no
            // Content-Length), so curl reports Receiving progress with
            // size = Nothing. `bytes` total payload spread over ~`ms` ms.
            long bytes = queryLong(query, "bytes", 1024);
            long ms = queryLong(query, "ms", 500);
            if (bytes < 0) bytes = 0;
            const long kChunks = 8;
            std::ostringstream hdr;
            hdr << "HTTP/1.1 200 OK\r\n"
                << "Content-Type: application/octet-stream\r\n"
                << "Transfer-Encoding: chunked\r\n"
                << "Connection: close\r\n\r\n";
            writeAll(conn, hdr.str());
            long written = 0;
            long perChunk = (bytes + kChunks - 1) / kChunks;
            if (perChunk < 1) perChunk = 1;
            while (written < bytes) {
                long n = bytes - written;
                if (n > perChunk) n = perChunk;
                std::ostringstream c;
                c << std::hex << n << std::dec << "\r\n"
                  << std::string(static_cast<size_t>(n), 'x') << "\r\n";
                writeAll(conn, c.str());
                written += n;
                if (written < bytes) {
                    std::this_thread::sleep_for(
                        std::chrono::milliseconds(ms / kChunks));
                }
            }
            writeAll(conn, "0\r\n\r\n");  // terminating chunk
        } else if (route == "/redirect") {
            sendResponse(conn, 302, "Found", "text/plain", "", "Location: /anything\r\n");
        } else if (route == "/package.zip") {
            std::string zip(reinterpret_cast<const char*>(kDummyPackageZip),
                            sizeof(kDummyPackageZip));
            sendResponse(conn, 200, "OK", "application/zip", zip);
        } else {
            sendResponse(conn, 404, "Not Found", "text/plain", "not found");
        }
    }
    conn.close();
}

// Open a loopback listening socket on an ephemeral port; returns {fd, port}.
inline std::pair<int, int> openLoopbackListener() {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    listen(fd, 64);
    socklen_t len = sizeof(addr);
    getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len);
    return {fd, ntohs(addr.sin_port)};
}

// Leaky singleton server: started once, runs for the test process lifetime.
// Serves both plaintext HTTP (port()) and TLS HTTPS (httpsPort()) with a
// throwaway self-signed cert (CN/SAN 127.0.0.1) written to certPath() so curl
// can verify it via CURL_CA_BUNDLE.
class TestHttpServer {
public:
    static TestHttpServer& instance() {
        static TestHttpServer* inst = new TestHttpServer();
        return *inst;
    }

    int port() const { return port_; }
    int httpsPort() const { return httpsPort_; }
    const std::string& certPath() const { return certPath_; }

private:
    TestHttpServer() {
        auto [pfd, pport] = openLoopbackListener();
        listenFd_ = pfd;
        port_ = pport;
        std::thread([this] { acceptLoop(); }).detach();

        if (setupTls()) {
            auto [sfd, sport] = openLoopbackListener();
            tlsFd_ = sfd;
            httpsPort_ = sport;
            std::thread([this] { tlsAcceptLoop(); }).detach();
        }
    }

    void acceptLoop() {
        while (true) {
            int fd = accept(listenFd_, nullptr, nullptr);
            if (fd < 0) continue;
            std::thread(handleConnection, Conn{fd, nullptr}).detach();
        }
    }

    void tlsAcceptLoop() {
        while (true) {
            int fd = accept(tlsFd_, nullptr, nullptr);
            if (fd < 0) continue;
            std::thread([this, fd] {
                SSL* ssl = SSL_new(sslCtx_);
                SSL_set_fd(ssl, fd);
                if (SSL_accept(ssl) <= 0) {
                    SSL_free(ssl);
                    ::close(fd);
                    return;
                }
                handleConnection(Conn{fd, ssl});
            }).detach();
        }
    }

    // Generate a self-signed RSA cert (CN + SAN IP:127.0.0.1), install it on a
    // server SSL_CTX, and write the cert PEM to a temp file for curl's CA.
    bool setupTls() {
        SSL_library_init();
        SSL_load_error_strings();
        OpenSSL_add_all_algorithms();

        EVP_PKEY* pkey = EVP_RSA_gen(2048);
        if (!pkey) return false;
        X509* x509 = X509_new();
        ASN1_INTEGER_set(X509_get_serialNumber(x509), 1);
        X509_gmtime_adj(X509_getm_notBefore(x509), 0);
        X509_gmtime_adj(X509_getm_notAfter(x509), 60L * 60L * 24L * 365L);
        X509_set_pubkey(x509, pkey);
        X509_NAME* name = X509_get_subject_name(x509);
        X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
            reinterpret_cast<const unsigned char*>("127.0.0.1"), -1, -1, 0);
        X509_set_issuer_name(x509, name);
        // SubjectAltName (iPAddress) so curl's host verification accepts the IP
        // literal — modern curl/OpenSSL will not match an IP against the CN.
        // Mark CA:TRUE so the self-signed cert is usable as its own trust anchor.
        {
            X509V3_CTX ctx;
            X509V3_set_ctx_nodb(&ctx);
            X509V3_set_ctx(&ctx, x509, x509, nullptr, nullptr, 0);
            if (X509_EXTENSION* san = X509V3_EXT_conf_nid(
                    nullptr, &ctx, NID_subject_alt_name,
                    const_cast<char*>("IP:127.0.0.1"))) {
                X509_add_ext(x509, san, -1);
                X509_EXTENSION_free(san);
            }
            if (X509_EXTENSION* bc = X509V3_EXT_conf_nid(
                    nullptr, &ctx, NID_basic_constraints,
                    const_cast<char*>("critical,CA:TRUE"))) {
                X509_add_ext(x509, bc, -1);
                X509_EXTENSION_free(bc);
            }
        }
        X509_sign(x509, pkey, EVP_sha256());

        sslCtx_ = SSL_CTX_new(TLS_server_method());
        if (!sslCtx_ || SSL_CTX_use_certificate(sslCtx_, x509) <= 0 ||
            SSL_CTX_use_PrivateKey(sslCtx_, pkey) <= 0) {
            return false;
        }

        // Write the cert to a temp file for curl's CURL_CA_BUNDLE.
        char tmpl[] = "/tmp/eco-test-ca-XXXXXX";
        int tfd = mkstemp(tmpl);
        if (tfd < 0) return false;
        certPath_ = tmpl;
        FILE* f = fdopen(tfd, "wb");
        PEM_write_X509(f, x509);
        fclose(f);

        X509_free(x509);
        EVP_PKEY_free(pkey);
        return true;
    }

    int listenFd_ = -1;
    int port_ = 0;
    int tlsFd_ = -1;
    int httpsPort_ = 0;
    SSL_CTX* sslCtx_ = nullptr;
    std::string certPath_;
};

} // namespace ElmHttpTestServer
