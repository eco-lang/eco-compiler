# Plan: macOS Keychain certificate trust (SecTrust) for TLS sockets and HTTP

## Goal

On macOS, eco programs and `eco` itself trust exactly the certificates the
Mac trusts: the system roots, CAs that an admin or user added to the Keychain,
CAs pushed by MDM (Mobile Device Management) configuration profiles, and the
user's "never trust" settings. A Mac behind a corporate TLS-inspecting proxy,
whose root CA lives only in the Keychain, then works for:

- `Socket.Tls` client connections (eco/system), and
- `Http` (elm/http in user programs, the compiler's package downloads from
  `package.elm-lang.org`, eco/system `HttpStream`),

with no `SSL_CERT_FILE` / `CURL_CA_BUNDLE` workaround.

Both paths share **one verifier**: Apple's `SecTrustEvaluateWithError` on the
peer's certificate chain, with an SSL policy for the hostname. OpenSSL still
does the TLS protocol; only the trust decision moves to macOS.

## Decisions

- **Option A for TLS sockets: let macOS verify the chain.** Install an
  OpenSSL certificate-verify callback that hands the peer's chain to SecTrust.
  Rejected: copying the Keychain's certificates into OpenSSL's `X509_STORE`
  (option B). That flattens trust settings (distrusted / use-constrained
  certificates), skips revocation and Certificate Transparency, and is a
  snapshot frozen in the process-wide cached context.
- **Option 2 for HTTP: ship our own static libcurl on macOS, built on the
  same OpenSSL 3 as the sockets,** and install the same verify callback
  through `CURLOPT_SSL_CTX_FUNCTION`. Apple's system libcurl can't take the
  callback: its TLS library is Apple's LibreSSL, whose `SSL_CTX` is not ours
  (mixing them would crash). Rejected: feeding a Keychain PEM export to the
  system curl with `CURLOPT_CAINFO_BLOB` (option B's weaknesses again), and
  leaving curl alone with a documented `CURL_CA_BUNDLE` workaround.
- **Mode 0 only, and only with no environment override.** SecTrust replaces
  verification only for `SystemCertificates` (TLS mode 0) and for curl with
  `verifyPeer = true`, and only when the user has not named a bundle with
  `SSL_CERT_FILE` / `SSL_CERT_DIR` (sockets) or `CURL_CA_BUNDLE` / a
  per-request `caInfo` (curl). An explicit bundle keeps today's
  OpenSSL-only semantics on every platform. `TrustedCertificates` (mode 1) and
  `NoVerification` (mode 2) are unchanged.
- **The macOS curl is built with HTTP/2 (vendored nghttp2).** Apple's curl
  negotiates HTTP/2 over TLS (ALPN), so the replacement must too; shipping a
  HTTP/1.1-only curl would be a regression. libcurl's default
  (`CURL_HTTP_VERSION_2TLS`) is kept: HTTP/2 when the server offers it over
  TLS, HTTP/1.1 otherwise and for plain `http://`. Linux and Windows keep
  `USE_NGHTTP2 OFF` in this plan (Linux gates stay byte-identical); turning
  it on there reuses the same vendoring and is a follow-up.
- **macOS only.** Linux and the musl bundle keep the current file-based trust
  store. Windows (schannel curl; no native TLS sockets) is out of scope.
- **Hostname checking stays in OpenSSL/curl as well.** `SecPolicyCreateSSL`
  also checks the name; keeping `SSL_set1_host` / the IP-SAN check
  (`TlsTransport.cpp:416`) and curl's `VERIFYHOST=2` means a SecTrust bug
  cannot silently skip the hostname check.
- **The Elm-facing API does not change.** Error codes stay Node's (§D.5 of
  plans/eco-system-sockets.md); SecTrust failures are mapped onto them.

## Current state

| Area | Today | Problem |
|---|---|---|
| TLS socket trust | `makeSystemContext` (`system-kernel-cpp/src/eco-system/Tls/TlsContext.cpp:83-115`): `SSL_CERT_FILE`/`SSL_CERT_DIR`, else `SSL_CTX_set_default_verify_paths`, else the first existing probe file (`/etc/ssl/cert.pem` on macOS). Static OpenSSL 3 from brew's keg. | Keychain-only roots (MDM, corporate proxy, user-added) are not trusted; Keychain distrust is ignored. |
| TLS handshake thread | `TlsTransport::handshake()` (`TlsTransport.cpp:63-100`), driven by `Conn::runHandshake()` (`Conn.cpp:320-341`) on the **reactor thread**; returns 1 with `wantRead`/`wantWrite` to wait for the socket. | A blocking SecTrust evaluation (it may fetch OCSP/CRL or missing intermediates over the network) would stall every socket. |
| HTTP (elm/http, package downloads) | `HttpService::perform` (`runtime/src/platform/HttpService.cpp:195-244`), libcurl easy interface on worker threads; `CURLOPT_CAINFO` only from `req.caInfo` / `CURL_CA_BUNDLE`. | On macOS this is Apple's `/usr/lib/libcurl.dylib`; eco cannot install a verifier into it. |
| HTTP streaming (eco/system) | `HttpTransfer.cpp:448-456, 529-583`, one transfer thread per transfer, curl multi. Same `CURL_CA_BUNDLE` handling. | Same. |
| curl on macOS | `-lcurl` from the SDK in `linkExecutableDarwin` (`runtime/src/codegen/EcoNativeDriver.cpp:682`) and `CURL::libcurl` for `eco` itself (`runtime/src/codegen/CMakeLists.txt:582-585, 673-675, 734-740`; `system-kernel-cpp/CMakeLists.txt:227-237`). | The vendored curl (`CMakeLists.txt:456`, `curl-8_11_0`, OpenSSL backend) is only built under `ECO_STATIC OR WIN32` (`CMakeLists.txt:332`). |
| Vendored curl features | `USE_NGHTTP2 OFF`, LDAP/FTP/… disabled. No nghttp2 is vendored. | Apple's curl has HTTP/2; switching without nghttp2 would lose it (step 3.2 adds it). |
| Response status text | elm/http: an empty reason phrase is replaced by the standard phrase for the code (`elm-kernel-cpp/src/http/HttpExports.cpp:259-260`). eco/system `HttpStream`: `statusText` is whatever follows the code on the status line (`HttpTransfer.cpp:300-315`). Header names are lower-cased on both paths (`HttpService.cpp:160`, `HttpTransfer.cpp:243`). | HTTP/2 has no reason phrase (status line `HTTP/2 200`), so `HttpStream`'s `statusText` becomes `""` (step 3.2). |

## Step 1 — Shared Apple trust verifier

New `runtime/src/platform/AppleTrust.{hpp,cpp}` (compiled only
`if(APPLE)`), in the runtime library because every AOT program and
`eco` link it, and both `HttpService` (runtime) and the eco/system kernels
(which already include `platform/` headers, `Core/Core.hpp:26-28`) need it.

1. **`evaluateChain(STACK_OF(X509)* chain, const std::string& host,
   bool hostIsIp) -> AppleTrustResult`** (synchronous):
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
2. **`installVerifyCallback(SSL_CTX*, VerifyHook)`**: wraps
   `SSL_CTX_set_cert_verify_callback`. The callback reads the chain from
   `X509_STORE_CTX_get0_untrusted`, the host from app data on the `SSL`
   (`SSL_get_ex_data` with an index allocated once), and either
   evaluates synchronously (curl, step 3) or defers (sockets, step 2).
   On failure it sets `X509_STORE_CTX_set_error` to the closest
   `X509_V_ERR_*` so `SSL_get_verify_result` and the existing
   `handshakeFailed` path (`TlsTransport.cpp:174`) still produce the right
   Node code, and stores Apple's message for `errMessage`.
3. **Link:** `-framework Security -framework CoreFoundation` on the runtime
   library's interface (CMake) and in `linkExecutableDarwin` after the
   archives (`EcoNativeDriver.cpp:679-684`). Both frameworks are in the SDK,
   so users need nothing new.
4. **Unit test** (`test/` C++ unit suite, Apple only): evaluate a chain for
   a public host fixture (DER files checked in, with `SecTrustSetVerifyDate`
   pinned so expiry never breaks it) → ok; the same chain with a wrong
   hostname → `ERR_TLS_CERT_ALTNAME_INVALID`; a self-signed leaf → the
   untrusted code.

## Step 2 — TLS sockets: asynchronous SecTrust in the handshake

1. **Context.** In `makeSystemContext`, on Apple and only when neither
   `SSL_CERT_FILE` nor `SSL_CERT_DIR` is set: keep
   `SSL_VERIFY_PEER`, install the step 1 callback in deferred mode, and skip
   `set_default_verify_paths` and the probe (OpenSSL's own store is no longer
   consulted on this path). The context stays built once and cached (R3).
2. **Per connection.** The client transport factory
   (`TlsTransport.cpp:~400-420`) stores the server name and the IP-literal
   flag on the `SSL` (ex data) for the callback.
3. **Deferred evaluation (OpenSSL 3 retry-verify).** The first time the
   callback runs for an `SSL` it copies the chain (`X509_up_ref` /
   `sk_X509_dup`), submits `evaluateChain` to the **SysWorkPool**, records
   "pending" in the transport's state and returns **-1**. OpenSSL then
   returns from `SSL_do_handshake` with `SSL_ERROR_WANT_RETRY_VERIFY`.
   - `TlsTransport::handshake()` gains that case: set a new
     `wantRetry` flag, clear `wantRead`/`wantWrite`, return 1.
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
4. **Exit / quiesce (N13).** A job still running at `std::exit` must not
   touch a freed `SSL`: the job owns its chain copy and only posts a command;
   the transport owns the verdict slot. Confirm the TLS atexit hook's
   `quiesce()` ordering covers an in-flight SysWorkPool job (it posts nothing
   once the reactor is quiesced).
5. **Server side unchanged** (servers don't verify clients in v1).
6. **JS backend.** No change: Node's `tls.getCACertificates('system')`
   (`system-kernel-cpp/src/Eco/Kernel/Tls.js:19-20`) is Node's business.

## Step 3 — Static libcurl on macOS with the shared verifier

1. **Build the vendored curl on Apple.** Widen the vendoring condition at
   `CMakeLists.txt:332` (and the `libcurl_static` selections at
   `runtime/src/codegen/CMakeLists.txt:582-585, 673-675, 734-740` and
   `system-kernel-cpp/CMakeLists.txt:227-237`) to include `APPLE`.
   `CURL_USE_OPENSSL ON` against the same brew `openssl@3` static archives
   (`OPENSSL_USE_STATIC_LIBS`, `CMakeLists.txt:316-331`), so curl and the
   sockets share one OpenSSL. zlib stays the SDK's `libz`.
   - Configure curl with **no compiled-in CA bundle or path**
     (`CURL_CA_BUNDLE=none`, `CURL_CA_PATH=none`) so curl does not fail
     loading a build-host path on a user's Mac; trust comes from the
     callback. Confirm in curl 8.11's `CMakeLists.txt` that these are the
     option names and that an empty store plus our callback does not
     trip curl's "error setting certificate verify locations".
   - Add whatever frameworks curl's OpenSSL build needs on macOS to its
     link interface (curl links `SystemConfiguration` / `CoreFoundation` on
     Apple in some configurations; read the generated `libcurl.pc` /
     `CURLTargets.cmake`).
2. **HTTP/2: vendor nghttp2.**
   - `FetchContent_Declare(nghttp2_vendored …)` from
     `https://github.com/nghttp2/nghttp2.git`, pinned to a release tag, added
     **before** curl (as zlib is, `CMakeLists.txt:358-400`), with
     `ENABLE_LIB_ONLY ON`, `BUILD_STATIC_LIBS ON`, `BUILD_SHARED_LIBS OFF`,
     `BUILD_TESTING OFF`, the 15.0 deployment target, and the same
     export-set workaround zlib needs (`CMakeLists.txt:390-400`) if curl's
     `export(TARGETS …)` drags the target in.
   - curl: `USE_NGHTTP2 ON` on Apple only. curl 8.11 finds it with
     `find_package(NGHTTP2)` (`CMake/FindNGHTTP2.cmake`), so pre-set
     `NGHTTP2_INCLUDE_DIR` / `NGHTTP2_LIBRARY` to the vendored target's
     include dir and `$<TARGET_FILE:…>` (or an imported `NGHTTP2::NGHTTP2`
     alias), the same trick the vendored zlib uses for curl's
     `find_package(ZLIB)`. Confirm the variable names against the pinned
     curl's Find module; a generator expression may not be accepted there,
     in which case use the known output path.
   - Check the configure log says `HTTP2` is enabled and
     `curl_version_info()->features & CURL_VERSION_HTTP2` is set at run
     time (a unit test asserts it on Apple).
   - Bundle `libnghttp2.a` next to `libcurl.a` (a new `darwinLibnghttp2A`
     in `EcoBootConfig.h`) and link it **after** `libcurl.a` and before
     `libssl.a`/`libcrypto.a` in `linkExecutableDarwin`; `eco` itself gets
     it through `libcurl_static`'s link interface.
   - No request-side change: libcurl's default `CURL_HTTP_VERSION_2TLS`
     negotiates HTTP/2 over TLS through ALPN (OpenSSL 3 supports it).
     `HttpService` (easy interface, one handle per worker) gets HTTP/2 per
     connection but no multiplexing across workers; `HttpTransfer` uses one
     multi handle per transfer, so no cross-transfer multiplexing either.
     Sharing connections between requests (a shared multi handle or
     `CURLSH` connection cache) is out of scope.
   - **Response metadata under HTTP/2.** Header names already arrive and are
     stored lower-case. HTTP/2 has no reason phrase: elm/http already
     substitutes the standard phrase (`HttpExports.cpp:259-260`), so Elm's
     `statusText` is unchanged. For eco/system `HttpStream`, decide by its
     JS twin: Node's `fetch` reports `statusText` `""` over HTTP/2, so keep
     the empty string if parity with Node is the rule; otherwise apply the
     same `reasonPhrase` fallback. Write the decision into the
     `HttpStream` docs either way.
   - The status-line checks (`HttpService.cpp:147`, `HttpTransfer.cpp:300`)
     match `HTTP/` and so already accept `HTTP/2 200`; the `HttpTransfer`
     parser must take the code from `HTTP/2 200` (no minor version, no
     phrase). Add a parser unit test for that line.
3. **Bundle it.** Add `libcurl.a` to the Darwin bundle next to
   `libzip.a`/`libssl.a`/`libcrypto.a` (`EcoBootConfig.h` emission,
   `runtime/src/codegen/CMakeLists.txt:1558-1560`, a new
   `darwinLibcurlA`), and in `linkExecutableDarwin` replace `-lcurl` with
   `libcurl.a libnghttp2.a`, placed **before** `libssl.a`/`libcrypto.a`
   (both reference OpenSSL). Keep `-lz` and add the frameworks from step 1.3.
4. **Install the verifier.** In `HttpService::perform` and the
   `HttpTransfer` easy-handle setup, on Apple, when `verifyPeer` is true and
   no `caInfo`/`CURL_CA_BUNDLE` is set: `CURLOPT_SSL_CTX_FUNCTION` →
   a function that calls `installVerifyCallback(ctx, synchronous)`, with the
   request host available to the callback through `CURLOPT_SSL_CTX_DATA` (or
   `SSL_get_servername` on the `SSL`, which curl sets for SNI; fall back to
   the parsed URL host for IP literals, which get no SNI). Synchronous
   evaluation is fine: both run on their own threads (HttpService workers,
   one `HttpTransfer` thread per transfer), never on the reactor.
5. **Connection reuse.** curl caches connections and TLS sessions; a
   resumed session skips the callback, which is correct (the session was
   verified when created). Check that curl's session cache is keyed so a
   `verifyPeer = false` request cannot resume a session that a verified
   request will then reuse (curl keys on SSL config, which
   `CURLOPT_SSL_CTX_FUNCTION` does not change; confirm).
6. **Floor check.** The new `libcurl.a` and `libnghttp2.a` are built with the 15.0 deployment
   target; `test/scripts/check-macho-floor.sh` and the linked-library gate in
   `mac-aot` must now expect **no** `/usr/lib/libcurl.4.dylib` in `eco` or
   AOT outputs (update the gate's allow-list).

## Step 4 — Tests and CI

1. **E2E (macOS JIT + AOT suites):** all existing Tls*/Http* tests pass
   unchanged, including the ones that expect `CERT_HAS_EXPIRED`,
   `ERR_TLS_CERT_ALTNAME_INVALID` and self-signed rejections (these use
   local test servers with generated certificates; they must still fail for
   the same codes under SecTrust).
2. **Keychain-only root (the case this plan exists for)**, a CI-only test in
   `mac-aot` (it changes the runner's trust settings):
   - generate a CA plus a leaf for `localhost`; start the existing test
     HTTPS / TLS servers with the leaf;
   - with the CA **not** in the Keychain, both a `Socket.Tls` client and
     `Http.get` fail with the untrusted code;
   - `sudo security add-trusted-cert -d -r trustRoot -k
     /Library/Keychains/System.keychain ca.pem` (admin domain, non-interactive
     with sudo on the runner); both now succeed with no environment variables;
   - with `SSL_CERT_FILE` / `CURL_CA_BUNDLE` pointing at an unrelated bundle,
     both fail again (the explicit-bundle override is honoured);
   - remove the trust setting afterwards (`security remove-trusted-cert -d`).
3. **Distrust:** mark the test CA "never trust" for SSL
   (`security add-trusted-cert -r deny …`); the connection fails.
4. **Package download on a clean runner:** `bundle-smoke` runs `eco make` on a
   project with dependencies after moving `~/.eco` aside, so the download from
   `package.elm-lang.org` goes through the bundled curl and SecTrust.
5. **Non-blocking proof:** a test that opens a TLS connection to a server
   whose chain needs network work (or a stubbed slow evaluation behind a
   test-only env hook) while another socket keeps exchanging data; the second
   socket's latency must not include the evaluation time.
6. **HTTP/2 actually negotiated.** The E2E HTTPS test server gains an HTTP/2
   mode (Node's `http2.createSecureServer` with `allowHTTP1: true`); on macOS
   an `Http.get` and an `HttpStream` request against it succeed, and a
   debug/verbose hook (`CURLINFO_HTTP_VERSION`, surfaced in the existing
   verbose HTTP log) shows `CURL_HTTP_VERSION_2_0`. The same requests against
   an HTTP/1.1-only server still work (ALPN fallback). Response headers,
   status code, body and `statusText` (per the step 3.2 decision) match what
   the HTTP/1.1 run returns.

## Step 5 — Docs

- `docs/building-macos.md`: trust comes from the Keychain (system, admin,
  user, MDM); `SSL_CERT_FILE`/`CURL_CA_BUNDLE` override it; the bundle
  layout gains `libcurl.a` and `libnghttp2.a`; HTTPS requests use HTTP/2
  when the server offers it; the "dynamically links libcurl from macOS"
  sentence changes to "statically links libcurl".
- `docs/getting-started.md`: nothing for users to do behind a corporate proxy
  on macOS.
- The eco/system `Socket.Tls` docs for `SystemCertificates`: "the operating
  system's trust store; on macOS, the Keychain".

## Order and gates

Step 1 → step 2 and step 3 (independent; either can land first) → step 4 →
step 5. Each step lands with: elm-tests, the macOS JIT and AOT E2E suites,
the bootstrap, and `bundle-smoke` green on the `mac-aot` workflow. Linux
gates must be byte-for-byte unaffected (all new code is `#if __APPLE__` /
`if(APPLE)`).

## Risks

- **HTTP/2 differences.** HTTP/2 changes a few things Elm code can observe
  only through `HttpStream`: the missing reason phrase (step 3.2). Some
  servers and proxies also behave differently over HTTP/2 (stricter header
  validation, for example rejecting connection-specific headers such as
  `Connection` or `Transfer-Encoding` a program sets by hand; curl drops
  those itself for HTTP/2, so confirm with a test that sets one).
- **nghttp2 is a new dependency.** One more vendored library to pin, build,
  bundle and patch for CVEs, with its own export-set and floor checks.
- **Behaviour change versus Apple's curl.** Apple's curl may differ in
  details, such as which proxy environment variables it honours and its
  default timeouts. Run the Http E2E suite against both before switching.
- **Error-code drift.** SecTrust's failure categories are coarser or
  different from OpenSSL's; tests pinning a specific Node code may need
  the mapping table extended, never the tests weakened.
- **Evaluation latency.** SecTrust may do network fetches for revocation and
  intermediates. That is bounded by the connect timeout on sockets and the
  request timeout in curl; measure a cold first connection on CI.
- **OpenSSL security updates.** libcurl now also uses the bundled OpenSSL, so
  a curl or OpenSSL CVE means an eco release (already true for sockets).
- **Bundle size.** `libcurl.a` plus `libnghttp2.a` add a few MB to the
  tarball.

## Follow-ups (not in this plan)

- Turn on HTTP/2 (`USE_NGHTTP2 ON` with the step 3.2 vendored nghttp2) for
  the static curl on Linux (glibc and musl bundles) and Windows.
- Share connections between requests (a shared multi handle or `CURLSH`
  connection cache) to get HTTP/2 multiplexing across concurrent requests.
- Windows: schannel curl already uses the Windows certificate store; native
  TLS sockets on Windows would want the equivalent (`CertGetCertificateChain`).
- Replace OpenSSL entirely on macOS (Network.framework for sockets, the
  platform curl back) if Apple-only TLS behaviour, such as following system
  proxy settings, becomes a requirement.
