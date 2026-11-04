// TLS unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/Tls/).
//
// TLS-04: with SSL_CERT_FILE naming a file that does not load and SSL_CERT_DIR naming a good hashed
//   directory, the mode-0 (SystemCertificates) context still trusts the directory's CA.
//   `makeSystemContext` (S/Tls/TlsContext.cpp) used to pass both to one `SSL_CTX_load_verify_locations`,
//   which returns before adding the directory when the file fails; it now loads each on its own. Each
//   variant runs in a child scenario, because the mode-0 context is built once per process; a
//   control (directory only) checks the fixture.
// TLS-05: mode 1 (TrustedCertificates) with PEM text holding no certificate fails with
//   ERR_SSL_NO_CERTIFICATES (as the JS backend does and the docs say); native used to report the PEM
//   parser's ERR_SSL_NO_START_LINE, because `makeTrustedContext` kept the queued error.
// TLS-08: a failed send's errno is what a later write reports. TlsTransport kept one error slot, so
//   the best-effort `sendOut` at the start of `read` recorded EPIPE and the `recv` that followed
//   overwrote it with ECONNRESET; the send's error is now kept apart. Linux only (AF_UNIX error
//   ordering): the send fails with EPIPE because our end is shut for writing, the recv with
//   ECONNRESET because the peer closed with our ClientHello bytes unread.
// TLS-10: a TLS connect used to run as two Tasks, the second (a binding built from a table entry)
//   started by the first's completion, so a kill between them left the entry until the heap
//   generation changed. The configuration job now hands off to the socket connect under the same
//   resume token. The child scenario drives `tlsConnectBody` to a refused port: completing normally,
//   killed after the hand-off (the old window: the connect is already registered, no table entry
//   is left) and killed while the configuration job is in flight; each leaves no table entry, no
//   pending connect and no hold, and a killed Task is never resumed.

#include "EcoSystemCoreTest.hpp"

#include "platform/TestHooks.hpp"

#ifndef _WIN32
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/Socket/SocketEvents.hpp"
#include "eco-system/Socket/SocketTables.hpp"
#include "eco-system/Tls/Tls.hpp"
#include "eco-system/Tls/TlsContext.hpp"
#include "eco-system/Tls/TlsTransport.hpp"

#include <openssl/bio.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <thread>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>
#endif

#include <cstdio>
#include <cstdlib>
#include <string>

namespace {

#ifndef _WIN32

using namespace Eco::System;

// The test CA and the localhost leaf it signed: test/eco-system/src/TlsFixtures.elm (caPem, serverCertPem).
const char* const kCaPem = R"(-----BEGIN CERTIFICATE-----
MIIBoTCCAUegAwIBAgIUTfp76fEYVXUrhc588JfbF+nX9wgwCgYIKoZIzj0EAwIw
HTEbMBkGA1UEAwwSZWNvLXN5c3RlbSB0ZXN0IENBMCAXDTI2MTAwNzIzNTU1N1oY
DzIxMjYwOTEzMjM1NTU3WjAdMRswGQYDVQQDDBJlY28tc3lzdGVtIHRlc3QgQ0Ew
WTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARwSJ3pjU/irAQ6NPeC+LYB0QMec7RJ
oCRLFAJQ07vNkg7cQW8Pm3SAdMfv1Va9NVjLLXV7NnA348wHXYeE2XB8o2MwYTAd
BgNVHQ4EFgQUOyZvUfYM0oX1urRNYnr4wQy8Lb4wHwYDVR0jBBgwFoAUOyZvUfYM
0oX1urRNYnr4wQy8Lb4wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwIDSAAwRQIhAM+vEoS9d/nwa7XauPgy8maHFmdjyTNxukhtMRNt
8uCRAiBcr2CnwsvIBIydLLCVXLyIbeFyxBfpnnEz0G/mswSneQ==
-----END CERTIFICATE-----
)";

const char* const kLeafPem = R"(-----BEGIN CERTIFICATE-----
MIIByDCCAW6gAwIBAgIUBzpMJoPw+wvGAu8RiGTHuVT3pSYwCgYIKoZIzj0EAwIw
HTEbMBkGA1UEAwwSZWNvLXN5c3RlbSB0ZXN0IENBMCAXDTI2MTAwNzIzNTU1N1oY
DzIxMjYwOTEzMjM1NTU3WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjO
PQIBBggqhkjOPQMBBwNCAAQIcLyEBdP+p630VfQnX95ZHcUrVR7QtoaSgZ4st8v9
EDZE1bEudPBndJbNqH+TwYd0BVCExvyDFTuGah3DKKlro4GSMIGPMAwGA1UdEwEB
/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBoGA1Ud
EQQTMBGCCWxvY2FsaG9zdIcEfwAAATAdBgNVHQ4EFgQU8kQpATHt3N+DzbByEGmG
7Nl2Y2IwHwYDVR0jBBgwFoAUOyZvUfYM0oX1urRNYnr4wQy8Lb4wCgYIKoZIzj0E
AwIDSAAwRQIhANpsib3PIteKYCG79bbnxNom3MJMIMcTlOQsATYhqvBPAiBa+Wfu
eGp1s+BJr+jAywDQE+iiry+8B3RN41W82gY1xQ==
-----END CERTIFICATE-----
)";

X509* parsePem(const char* pem) {
    BIO* bio = BIO_new_mem_buf(pem, -1);
    X509* x = bio ? PEM_read_bio_X509(bio, nullptr, nullptr, nullptr) : nullptr;
    if (bio) BIO_free(bio);
    return x;
}

bool writeFile(const std::string& path, const std::string& text) {
    FILE* f = std::fopen(path.c_str(), "w");
    if (!f) return false;
    bool ok = std::fwrite(text.data(), 1, text.size(), f) == text.size();
    return std::fclose(f) == 0 && ok;
}

// ---- TLS-04 ---------------------------------------------------------------------------------

// The scratch directory of this test run (the parent's pid), shared with its child scenarios.
std::string tls04Root() {
    const char* r = std::getenv("ECO_TLS04_ROOT");
    return r ? r : "/tmp/eco-tls04-" + std::to_string(::getpid());
}

// Child: builds the mode-0 context from the environment the parent set, and exits 0 when the
// fixture leaf's issuer (the test CA) is found in its store, 3 when it is not, other values on
// setup failures.
int scenarioTls04IssuerFound() {
    initCoreRuntime();
    ensureTlsInit();
    TlsError err;
    auto cfg = buildTlsClientConfig(0, "", "localhost", {}, err);
    if (!cfg) {
        std::fprintf(stderr, "TLS-04 child: buildTlsClientConfig failed: %s %s\n", err.code.c_str(),
                     err.message.c_str());
        return 4;
    }
    X509* leaf = parsePem(kLeafPem);
    if (!leaf) return 5;
    X509_STORE* store = SSL_CTX_get_cert_store(cfg->ctx.get());
    X509_STORE_CTX* sctx = X509_STORE_CTX_new();
    if (!store || !sctx || X509_STORE_CTX_init(sctx, store, leaf, nullptr) != 1) return 6;
    X509* issuer = nullptr;
    int rc = X509_STORE_CTX_get1_issuer(&issuer, sctx, leaf);
    std::printf("TLS-04 child: get1_issuer = %d\n", rc);
    if (issuer) X509_free(issuer);
    X509_STORE_CTX_free(sctx);
    X509_free(leaf);
    return rc == 1 ? 0 : 3;
}

// Writes the hashed CA directory and a garbage PEM file under the scratch root.
bool tls04Fixture(std::string& dir, std::string& garbage) {
    const std::string root = tls04Root();
    dir = root + "/dir";
    garbage = root + "/garbage.pem";
    ::mkdir(root.c_str(), 0700);
    ::mkdir(dir.c_str(), 0700);
    X509* ca = parsePem(kCaPem);
    if (!ca) return false;
    char name[32];
    std::snprintf(name, sizeof name, "%08lx.0", X509_subject_name_hash(ca));
    X509_free(ca);
    return writeFile(dir + "/" + name, kCaPem) && writeFile(garbage, "not a certificate\n");
}

void testTls04BadFileDisablesDir() {
    std::printf("tls/bad-ssl-cert-file-does-not-stop-a-good-ssl-cert-dir\n");
    std::string dir, garbage;
    CHECK(tls04Fixture(dir, garbage));
    const std::string root = tls04Root();

    // Control: the directory alone, so the fixture and the lookup are sound.
    auto control = ChildScenario::runChildScenario(
        "tls/issuer-found", {{"ECO_TLS04_ROOT", root}, {"SSL_CERT_FILE", ""}, {"SSL_CERT_DIR", dir}}, 30000);
    CHECK_MSG(control.ok(), "control (SSL_CERT_DIR only): " + control.describe() + "; stderr: " + control.err);
    if (!control.ok()) return;

    auto missing = ChildScenario::runChildScenario(
        "tls/issuer-found",
        {{"ECO_TLS04_ROOT", root}, {"SSL_CERT_FILE", root + "/missing.pem"}, {"SSL_CERT_DIR", dir}}, 30000);
    auto bad = ChildScenario::runChildScenario(
        "tls/issuer-found", {{"ECO_TLS04_ROOT", root}, {"SSL_CERT_FILE", garbage}, {"SSL_CERT_DIR", dir}},
        30000);
    // Exit 3 is "issuer not found"; anything else but 0 is a setup failure, not the defect.
    CHECK_MSG(missing.ok() || (missing.exited && missing.exitCode == 3), "missing file: " + missing.describe());
    CHECK_MSG(bad.ok() || (bad.exited && bad.exitCode == 3), "garbage file: " + bad.describe());
    CHECK_MSG(missing.ok() && bad.ok(), "TLS-04: missing SSL_CERT_FILE: " + missing.describe() +
                                            "; garbage SSL_CERT_FILE: " + bad.describe() +
                                            " (exit 3 = CA in SSL_CERT_DIR not found)");
}

// ---- TLS-05 ---------------------------------------------------------------------------------

void testTls05NoCertificatesCode() {
    std::printf("tls/trusted-certificates-with-no-certificate-gives-err-ssl-no-certificates\n");
    ensureTlsInit();
    for (const char* pem : {"", "not a certificate", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"}) {
        TlsError err;
        auto cfg = buildTlsClientConfig(1, pem, "localhost", {}, err);
        CHECK(!cfg);
        CHECK_MSG(err.code == "ERR_SSL_NO_CERTIFICATES" && err.message.rfind("trusted certificates", 0) == 0,
                  std::string("TLS-05: \"") + pem + "\" -> " + err.code + " (" + err.message + ")");
    }
}

// ---- TLS-08 ---------------------------------------------------------------------------------

#ifdef __linux__
void testTls08SendErrorOverwritten() {
    std::printf("tls/failed-send-errno-is-what-the-next-write-reports\n");
    ensureTlsInit();
    int sv[2];
    CHECK(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0);
    for (int fd : sv) ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) | O_NONBLOCK);
    // Fill our end until the peer's queue is full, so the ClientHello stays pending in the transport
    // and the peer closes with unread data (which gives our end ECONNRESET).
    char junk[4096] = {};
    size_t queued = 0;
    for (;;) {
        ssize_t n = ::send(sv[0], junk, sizeof junk, MSG_NOSIGNAL);
        if (n <= 0) break;
        queued += static_cast<size_t>(n);
    }
    CHECK(queued > 0);

    TlsError err;
    auto cfg = buildTlsClientConfig(2, "", "localhost", {}, err);
    CHECK(cfg != nullptr);
    if (!cfg) return;
    auto t = makeTlsClientFactory(cfg)(sv[0], false);
    CHECK(t != nullptr);
    if (!t) return;
    int hs = t->handshake();
    const bool pendingBefore = hs == 1 && t->wantWrite && t->hasPendingWrite();
    CHECK_MSG(pendingBefore, "handshake rc " + std::to_string(hs) + ", the ClientHello did not stay pending");

    ::shutdown(sv[0], SHUT_WR);   // the next send fails with EPIPE
    ::close(sv[1]);               // the next recv fails with ECONNRESET (unread data in the peer)

    char buf[256];
    ssize_t r = t->read(buf, sizeof buf);
    const std::string afterRead = t->errCode;
    // Precondition: the read's best-effort send failed (the transport is broken, nothing pending)
    // and its recv failed too.
    const bool sendFailed = !t->hasPendingWrite();
    CHECK_MSG(sendFailed, "the send at the start of read did not fail");
    CHECK_MSG(r == -2, "read returned " + std::to_string(r));
    ssize_t w = t->write("x", 1);
    CHECK_MSG(w == -2, "write returned " + std::to_string(w));
    const std::string code = t->errCode;
    t.reset();
    ::close(sv[0]);

    if (!pendingBefore || !sendFailed || r != -2 || w != -2) return;   // could not reach the defect
    CHECK_MSG(code == "EPIPE",
              "TLS-08: write after a failed send reports " + code + " (read left " + afterRead + "); expected EPIPE");
}
#endif

// ---- TLS-10 ---------------------------------------------------------------------------------

#if ECO_TEST_HOOKS
std::vector<std::string> g_tls10Resumed;

// The connect Task's resume closure: records whether it succeeded or failed.
void* tls10ResumeEval(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    g_tls10Resumed.push_back(t->ctor == Elm::alloc::Task_Succeed ? "ok" : "fail");
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// Returns a loopback TCP port nothing listens on (bound once, then closed), or 0.
int64_t tls10RefusedPort() {
    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t len = sizeof sa;
    int64_t port = 0;
    if (::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof sa) == 0 &&
        ::getsockname(fd, reinterpret_cast<sockaddr*>(&sa), &len) == 0) {
        port = ntohs(sa.sin_port);
    }
    ::close(fd);
    return port;
}

// Builds tlsConnectBody's payload for 127.0.0.1:`port`, mode 2 (NoVerification), no timeout, no ALPN.
HPointer tls10Payload(int64_t port) {
    HPointer addr = alloc::listNil(), name = alloc::listNil(), pem = alloc::listNil();
    HPointer target = alloc::listNil(), settings = alloc::listNil(), verification = alloc::listNil();
    HPointer tls = alloc::listNil();
    Elm::StackRootGuard g({&addr, &name, &pem, &target, &settings, &verification, &tls});
    addr = alloc::allocStringFromUTF8("127.0.0.1");
    name = alloc::allocStringFromUTF8("localhost");
    pem = alloc::allocStringFromUTF8("");
    target = alloc::tuple3(alloc::boxed(addr), alloc::unboxedInt(port), alloc::unboxedInt(0), 0x14);
    settings = alloc::tuple2(alloc::boxed(alloc::elmFalse()), alloc::unboxedInt(0), 0x4);
    verification = alloc::tuple2(alloc::unboxedInt(2), alloc::boxed(pem), 0x1);
    tls = alloc::tuple3(alloc::boxed(name), alloc::boxed(verification), alloc::boxed(alloc::listNil()), 0);
    return alloc::tuple3(alloc::boxed(target), alloc::boxed(settings), alloc::boxed(tls), 0);
}

// Drains the pool and the socket events until `done` holds or `ms` pass; returns whether it held.
template <typename P>
bool tls10DrainUntil(P done, int ms) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    for (;;) {
        poolDrain();
        socketEventsDrain();
        if (done()) return true;
        if (std::chrono::steady_clock::now() >= deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

// Drains only the pool (no socket events, so no connect completes on this thread) until `done` holds or `ms` pass.
template <typename P>
bool tls10DrainOnlyPool(P done, int ms) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    for (;;) {
        poolDrain();
        if (done()) return true;
        if (std::chrono::steady_clock::now() >= deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

// Child: three connects to a refused port, as the file comment describes. Exits 0 when all checks pass.
int scenarioTls10NoStage2() {
    initCoreRuntime();
    ensureTlsInit();
    auto& sched = Scheduler::instance();
    const int64_t port = tls10RefusedPort();
    CHECK_MSG(port != 0, "TLS-10: no free loopback port");
    const size_t holds0 = sched.liveHoldCount();
    const int async0 = sched.pendingAsync();
    auto settled = [&] {
        return TlsTesting::inflightConnectCount() == 0 && socketTables().pendingConnects.empty() &&
               sched.liveHoldCount() == holds0 && sched.pendingAsync() == async0;
    };
    auto state = [&] {
        return "inflight=" + std::to_string(TlsTesting::inflightConnectCount()) +
               " pendingConnects=" + std::to_string(socketTables().pendingConnects.size()) +
               " holds=" + std::to_string(sched.liveHoldCount()) + "/" + std::to_string(holds0) +
               " pendingAsync=" + std::to_string(sched.pendingAsync()) + "/" + std::to_string(async0);
    };

    HPointer resume = alloc::allocClosureK(&tls10ResumeEval, 1, PK_Boxed);
    HPointer payload = tls10Payload(port);
    HPointer kill = alloc::listNil();
    Elm::StackRootGuard g({&resume, &payload, &kill});

    // (a) Not killed: the Task fails once (connection refused), and nothing is left behind.
    g_tls10Resumed.clear();
    kill = tlsConnectBody(payload, resume);
    CHECK_MSG(tls10DrainUntil([&] { return !g_tls10Resumed.empty() && settled(); }, 10000),
              "TLS-10 (a): the connect did not complete cleanly: " + state());
    CHECK_MSG(g_tls10Resumed.size() == 1 && g_tls10Resumed[0] == "fail",
              "TLS-10 (a): resumed " + std::to_string(g_tls10Resumed.size()) + " times, want one failure");

    // (b) Killed after the configuration job was drained: the old window between the two stages. The socket connect
    // is already registered under the Task's token; the kill cancels it, and no table entry remains.
    const int n = 20;
    g_tls10Resumed.clear();
    for (int i = 0; i < n; ++i) {
        kill = tlsConnectBody(payload, resume);
        bool handedOff = tls10DrainOnlyPool([&] { return TlsTesting::inflightConnectCount() == 0; }, 10000);
        CHECK_MSG(handedOff, "TLS-10 (b): the configuration job was not drained: " + state());
        CHECK_MSG(socketTables().pendingConnects.size() == 1,
                  "TLS-10 (b): the hand-off did not start the connect at once: " + state());
        (void)Scheduler::callClosure1(kill, alloc::unit());
        CHECK_MSG(tls10DrainUntil(settled, 5000), "TLS-10 (b): a kill after the hand-off left " + state());
    }
    CHECK_MSG(g_tls10Resumed.empty(), "TLS-10 (b): a killed connect Task was resumed");

    // (c) Killed at once, while the configuration job is queued or running.
    for (int i = 0; i < n; ++i) {
        kill = tlsConnectBody(payload, resume);
        (void)Scheduler::callClosure1(kill, alloc::unit());
        CHECK_MSG(tls10DrainUntil(settled, 5000), "TLS-10 (c): a kill during the configuration job left " + state());
    }
    CHECK_MSG(g_tls10Resumed.empty(), "TLS-10 (c): a killed connect Task was resumed");
    std::printf("TLS-10 child: %s\n", state().c_str());
    return CoreTest::g_failures == 0 ? 0 : 1;
}

void testTls10NoStage2Entries() {
    std::printf("tls/killed-connect-leaves-no-pending-entry-connect-or-hold\n");
    auto r = ChildScenario::runChildScenario("tls/connect-no-stage-2", {}, 60000);
    CHECK_MSG(r.ok(), "TLS-10: " + r.describe() + "; stdout: " + r.out + "; stderr: " + r.err);
}
#endif

#endif  // !_WIN32

}  // namespace

void runTlsTests() {
#ifndef _WIN32
    testTls04BadFileDisablesDir();
    testTls05NoCertificatesCode();
#ifdef __linux__
    testTls08SendErrorOverwritten();
#endif
#if ECO_TEST_HOOKS
    testTls10NoStage2Entries();
#endif
#endif
}

void registerTlsScenarios() {
#ifndef _WIN32
    ChildScenario::add("tls/issuer-found", scenarioTls04IssuerFound);
#if ECO_TEST_HOOKS
    ChildScenario::add("tls/connect-no-stage-2", scenarioTls10NoStage2);
#endif
#endif
}
