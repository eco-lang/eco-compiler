---
status: not-started
updated: 2026-10-27
---

# Plan: macOS Keychain certificate trust (SecTrust) for TLS

## Goal

On macOS, eco's TLS client connections trust exactly the certificates the
Mac trusts: the system roots, CAs that an admin or user added to the Keychain,
CAs pushed by MDM (Mobile Device Management) configuration profiles, and the
user's "never trust" settings. A Mac behind a corporate TLS-inspecting proxy,
whose root CA lives only in the Keychain, then works with no `SSL_CERT_FILE`
workaround.

The verifier is Apple's `SecTrustEvaluateWithError` on the peer's certificate
chain, with an SSL policy for the hostname. OpenSSL still does the TLS
protocol; only the trust decision moves to macOS.

**Scope: `Socket.Tls` (eco's own TLS layer), and so everything built on it.**
Today that is eco/system's TLS sockets, `wss` WebSockets and the HTTPS server.
HTTP clients (elm/http, `Http.Stream`, the compiler's package downloads) still
go through libcurl; [`plans/native-http-client.md`](native-http-client.md)
moves them onto `Socket.Tls`, and they then get this verifier with no further
work. Until then they keep Apple's system libcurl unchanged (see "HTTP in the
meantime").

## Decisions

- **Let macOS verify the chain (option A).** Install an OpenSSL
  certificate-verify callback that hands the peer's chain to SecTrust.
  Rejected: copying the Keychain's certificates into OpenSSL's `X509_STORE`
  (option B). That flattens trust settings (distrusted / use-constrained
  certificates), skips revocation and Certificate Transparency, and is a
  snapshot frozen in the process-wide cached context.
- **No static libcurl on macOS.** An earlier version of this plan shipped a
  vendored libcurl (with HTTP/2 on eco's nghttp2) so the same callback could
  be installed through `CURLOPT_SSL_CTX_FUNCTION`. Dropped: the native HTTP
  client replaces curl on POSIX, so that work would be thrown away. Apple's
  system curl stays until the native client lands.
- **Mode 0 only, and only with no environment override.** SecTrust replaces
  verification only for `SystemCertificates` (TLS mode 0), and only when the
  user has not named a bundle with `SSL_CERT_FILE` / `SSL_CERT_DIR`. An
  explicit bundle keeps today's OpenSSL-only semantics on every platform.
  `TrustedCertificates` (mode 1) and `NoVerification` (mode 2) are unchanged.
- **macOS only.** Linux and the musl bundle keep the current file-based trust
  store. Windows (no native TLS sockets) is out of scope.
- **Hostname checking stays in OpenSSL as well.** `SecPolicyCreateSSL` also
  checks the name; keeping `SSL_set1_host` / the IP-SAN check
  (`TlsTransport.cpp:416`) means a SecTrust bug cannot silently skip it.
- **Never block the reactor.** The handshake runs on the reactor thread and
  SecTrust may go to the network, so evaluation is asynchronous (step 2).
- **The Elm-facing API does not change.** Error codes stay Node's (§D.5 of
  plans/eco-system-sockets.md); SecTrust failures are mapped onto them.

## Current state

| Area | Today | Problem |
|---|---|---|
| TLS socket trust | `makeSystemContext` (`system-kernel-cpp/src/eco-system/Tls/TlsContext.cpp:83-115`): `SSL_CERT_FILE`/`SSL_CERT_DIR`, else `SSL_CTX_set_default_verify_paths`, else the first existing probe file (`/etc/ssl/cert.pem` on macOS). Static OpenSSL 3 from brew's keg. | Keychain-only roots (MDM, corporate proxy, user-added) are not trusted; Keychain distrust is ignored. |
| TLS handshake thread | `TlsTransport::handshake()` (`TlsTransport.cpp:63-100`), driven by `Conn::runHandshake()` (`Conn.cpp:320-341`) on the **reactor thread**; returns 1 with `wantRead`/`wantWrite` to wait for the socket. | A blocking SecTrust evaluation (it may fetch OCSP/CRL or missing intermediates) would stall every socket. |
| HTTP clients | elm/http and `Eco.Http` through `HttpService` (`runtime/src/platform/HttpService.cpp`), `Http.Stream` through `HttpTransfer`; on macOS both are Apple's `/usr/lib/libcurl.dylib` (`-lcurl`, `EcoNativeDriver.cpp:682`). | Out of this plan's reach (Apple's LibreSSL inside curl); handled by plans/native-http-client.md. |

## Step 1 — Apple trust verifier

New `system-kernel-cpp/src/eco-system/Tls/AppleTrust.{hpp,cpp}`, compiled
only `if(APPLE)`, next to `TlsContext`.

1. **`evaluateChain(STACK_OF(X509)* chain, const std::string& host,
   bool hostIsIp) -> AppleTrustResult`** (synchronous; called off the
   reactor, step 2):
   - DER-encode each certificate (`i2d_X509`) and wrap it in
     `SecCertificateCreateWithData`; leaf first, as received.
   - `SecPolicyCreateSSL(true, host)`. For an IP literal pass the IP
     string (SecPolicy matches IP SANs); for an empty host (no SNI, no name)
     pass `nullptr`, which checks the chain but not the name.
   - `SecTrustCreateWithCertificates`, then `SecTrustEvaluateWithError`.
     Network fetches (revocation, missing intermediates) are allowed:
     that is the point of using the platform verifier.
   - Result: `ok`, plus on failure the `CFError` code and description,
     mapped to Node's verification codes by `appleTrustToNodeCode`:
     `errSecCertificateExpired` → `CERT_HAS_EXPIRED`,
     `errSecNotTrusted` / untrusted root → `SELF_SIGNED_CERT_IN_CHAIN` or
     `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` (match what OpenSSL reports for the
     same chain today, so existing tests keep their codes),
     `errSecHostNameMismatch` → `ERR_TLS_CERT_ALTNAME_INVALID`,
     `errSecCertificateRevoked` → `CERT_REVOKED`, anything else →
     `UNABLE_TO_VERIFY_LEAF_SIGNATURE` with Apple's description kept in
     the message. Build the table from the codes `tlsVerifyCode` already
     produces (`TlsTransport.cpp:174-196`).
   - All CF objects released on every path (`CFRelease` RAII holder).
2. **`installVerifyCallback(SSL_CTX*)`**: wraps
   `SSL_CTX_set_cert_verify_callback`. The callback reads the chain from
   `X509_STORE_CTX_get0_untrusted`, the host and the per-connection verdict
   slot from app data on the `SSL` (`SSL_get_ex_data`, index allocated
   once), and runs the deferred protocol of step 2.3. On failure it sets
   `X509_STORE_CTX_set_error` to the closest `X509_V_ERR_*` so
   `SSL_get_verify_result` and the existing `handshakeFailed` path
   (`TlsTransport.cpp:174`) still produce the right Node code, and stores
   Apple's message for `errMessage`.
3. **Link:** `-framework Security -framework CoreFoundation` on the
   `EcoSystem_Tls` target's interface (CMake, so `eco` gets them) and in
   `linkExecutableDarwin` after the archives (`EcoNativeDriver.cpp:679-684`).
   Both frameworks are in the SDK, so users need nothing new.
4. **Unit test** (`test/` C++ unit suite, Apple only): evaluate a chain for
   a public host fixture (DER files checked in, with `SecTrustSetVerifyDate`
   pinned so expiry never breaks it) → ok; the same chain with a wrong
   hostname → `ERR_TLS_CERT_ALTNAME_INVALID`; a self-signed leaf → the
   untrusted code.

## Step 2 — Asynchronous SecTrust in the handshake

1. **Context.** In `makeSystemContext`, on Apple and only when neither
   `SSL_CERT_FILE` nor `SSL_CERT_DIR` is set: keep `SSL_VERIFY_PEER`,
   install the step 1 callback, and skip `set_default_verify_paths` and the
   probe (OpenSSL's own store is no longer consulted on this path). The
   context stays built once and cached (R3).
2. **Per connection.** The client transport factory
   (`TlsTransport.cpp:~400-420`) stores the server name and the IP-literal
   flag on the `SSL` (ex data) for the callback.
3. **Deferred evaluation (OpenSSL 3 retry-verify).** The first time the
   callback runs for an `SSL` it copies the chain (`X509_up_ref` /
   `sk_X509_dup`), submits `evaluateChain` to the **SysWorkPool**, records
   "pending" in the verdict slot and returns **-1**. OpenSSL then returns
   from `SSL_do_handshake` with `SSL_ERROR_WANT_RETRY_VERIFY`.
   - `TlsTransport::handshake()` gains that case: set a new `wantRetry`
     flag, clear `wantRead`/`wantWrite`, return 1.
   - `Conn::runHandshake()` (`Conn.cpp:320-331`): when `wantRetry` is set,
     drop socket interest (`setInterest(key(), false, false)`) and wait. The
     connect deadline (`kTimerConnect`) keeps running, so a hung OCSP fetch
     ends as the existing connect timeout.
   - The SysWorkPool job stores the verdict and `submit()`s a reactor command
     carrying the Conn's key and generation; the command drops the result if
     the generation no longer matches (the Conn was closed or reset
     meanwhile; IoReactor rule 2), otherwise calls `runHandshake()` again.
   - The second callback call finds the verdict and returns 1, or 0 with the
     error set (step 1.2). No second evaluation.
   - Check `Transport` (`Conn.hpp`) for other users of `wantRead`/`wantWrite`
     (`Conn.cpp:670-710` reads them after read/write); `wantRetry` only
     occurs during the handshake, so assert it is clear there.
   - The WebSocket dial (`DialJob`, `WsHandshake.cpp`) drives its own TLS
     connection through the same `Conn`/`Transport` path; confirm it goes
     through `runHandshake()` and so gets the retry for free.
4. **Exit / quiesce (N13).** A job still running at `std::exit` must not
   touch a freed `SSL`: the job owns its chain copy and only posts a command;
   the transport owns the verdict slot. Confirm the TLS atexit hook's
   `quiesce()` ordering covers an in-flight SysWorkPool job (it posts nothing
   once the reactor is quiesced).
5. **Server side unchanged** (servers don't verify clients in v1).
6. **JS backend.** No change: Node's `tls.getCACertificates('system')`
   (`system-kernel-cpp/src/Eco/Kernel/Tls.js:19-20`) is Node's business.

## Step 3 — Tests and CI

1. **E2E (macOS JIT + AOT suites):** all existing Tls*/WebSocket*/HttpServer*
   tests pass unchanged, including the ones that expect `CERT_HAS_EXPIRED`,
   `ERR_TLS_CERT_ALTNAME_INVALID` and self-signed rejections (these use
   local test servers with generated certificates; they must still fail for
   the same codes under SecTrust).
2. **Keychain-only root (the case this plan exists for)**, a CI-only test in
   `mac-aot` (it changes the runner's trust settings):
   - generate a CA plus a leaf for `localhost`; start the existing test TLS
     server with the leaf;
   - with the CA **not** in the Keychain, a `Socket.Tls` client and a `wss`
     WebSocket fail with the untrusted code;
   - `sudo security add-trusted-cert -d -r trustRoot -k
     /Library/Keychains/System.keychain ca.pem` (admin domain, non-interactive
     with sudo on the runner); both now succeed with no environment variables;
   - with `SSL_CERT_FILE` pointing at an unrelated bundle, both fail again
     (the explicit-bundle override is honoured);
   - remove the trust setting afterwards (`security remove-trusted-cert -d`).
   - Record (not gate) what Apple's system curl does in the same two states,
     with `Http.get`: this answers the open question in "HTTP in the
     meantime".
3. **Distrust:** mark the test CA "never trust" for SSL
   (`security add-trusted-cert -r deny …`); the connection fails.
4. **Non-blocking proof:** a test that opens a TLS connection while
   evaluation is slow (a stubbed slow evaluation behind a test-only env
   hook) while another socket keeps exchanging data; the second socket's
   latency must not include the evaluation time.

## Step 4 — Docs

- `docs/building-macos.md`: TLS trust comes from the Keychain (system,
  admin, user, MDM); `SSL_CERT_FILE` overrides it; HTTP uses macOS's libcurl
  until the native client lands.
- The eco/system `Socket.Tls` docs for `SystemCertificates`: "the operating
  system's trust store; on macOS, the Keychain".

## HTTP in the meantime

Until plans/native-http-client.md ships, HTTP on macOS uses Apple's system
libcurl exactly as today: it has HTTP/2 and Apple's own trust configuration.
Whether that curl honours Keychain-only roots depends on how Apple builds it
and is not verified; step 3.2 records the answer. If it does not, the
documented workaround for a corporate Mac is `CURL_CA_BUNDLE=<bundle.pem>`
(honoured by `HttpService.cpp:238-244` and `HttpTransfer.cpp:455-456`).

## Order and gates

Step 1 → step 2 → step 3 → step 4. Each step lands with: elm-tests, the
macOS JIT and AOT E2E suites, the bootstrap, and `bundle-smoke` green on the
`mac-aot` workflow. Linux gates must be unaffected (all new code is
`#if __APPLE__` / `if(APPLE)`).

## Risks

- **Error-code drift.** SecTrust's failure categories are coarser or
  different from OpenSSL's; tests pinning a specific Node code may need
  the mapping table extended, never the tests weakened.
- **Evaluation latency.** SecTrust may do network fetches for revocation and
  intermediates. That is bounded by the connect timeout; measure a cold first
  connection on CI.
- **Retry-verify is new to the transport.** `SSL_ERROR_WANT_RETRY_VERIFY`
  adds a third waiting state to `Transport`; every caller of `handshake()`
  must handle it, or a connection hangs until its deadline.

## Follow-ups (not in this plan)

- plans/native-http-client.md: HTTP clients on `Socket.Tls`, which brings
  them under this verifier and retires curl on POSIX.
- Windows: native TLS sockets on Windows would want the equivalent
  (`CertGetCertificateChain`); schannel curl already uses the Windows store.
- Replace OpenSSL entirely on macOS (Network.framework) if Apple-only TLS
  behaviour, such as following system proxy settings, becomes a requirement.
