---
status: not-started
updated: 2026-10-27
---

# Plan: Native HTTP client (llhttp + nghttp2 + nghttp3/ngtcp2 on the IoReactor)

## Goal

Replace libcurl on Linux and macOS with eco's own HTTP client, built from the
pieces the HTTP server and the WebSocket client already use: the `IoReactor`,
`Conn`/`Transport`, `Socket.Tls` (OpenSSL 3), llhttp and nghttp2. HTTP/3
follows on ngtcp2 + nghttp3. Every native HTTP user moves to it:

- elm/http in user programs (`elm-kernel-cpp/src/http/HttpExports.cpp` via
  `HttpService`),
- `Eco.Http`, which the compiler uses for package downloads from
  `package.elm-lang.org` (`eco-kernel-cpp/src/eco-kernel/Http.cpp`, the
  "eco lane" of `HttpService`),
- eco/system `Http.Stream` (`HttpTransfer`).

What this buys (none of it needs an Elm API change):

- **One HTTP stack.** One event loop (no per-request threads), one TLS
  library, one nghttp2, the same code for client and server. TLS trust,
  including the macOS Keychain from plans/mac-keychain-trust.md, then
  applies to HTTP automatically.
- **Connection reuse and real concurrency.** Today native elm/http runs
  requests one at a time on a single worker thread
  (`runtime/src/platform/HttpService.cpp:30-31, 318-347`), and every request
  opens and closes its own connection (`:195`, `:314`). The client keeps
  connections alive, runs requests in parallel, and multiplexes concurrent
  requests to one origin over a single HTTP/2 or HTTP/3 connection.
- **HTTP/2 everywhere and HTTP/3.** The static bundles' curl has HTTP/2
  off (`CMakeLists.txt:427`, `USE_NGHTTP2 OFF`).
- **No libcurl on POSIX**: no curl vendoring (`CMakeLists.txt:332-460`), no
  Apple-curl versus vendored-curl behaviour split, no `CURL_CA_BUNDLE`
  versus `SSL_CERT_FILE` split.

## Decisions

- **Engines:** llhttp (HTTP/1.x responses; already vendored, v9.2.1,
  `system-kernel-cpp/CMakeLists.txt:153-156`), nghttp2 1.70.0 (HTTP/2;
  already vendored, `:173-217`), ngtcp2 + nghttp3 (QUIC + HTTP/3, new). All
  are C, do no I/O of their own and are driven from the reactor, as the
  server and the WebSocket client already drive llhttp and nghttp2.
- **TLS: OpenSSL ≥ 3.5 everywhere**, the version whose QUIC TLS API ngtcp2's
  `libngtcp2_crypto_ossl` backend needs. That backend is marked
  *experimental* upstream and has lifetime rules (phase 7). No second TLS
  library.
- **Docker images upgraded (phase 1):** Alpine 3.21 → **3.24** (OpenSSL
  3.5.9; 3.22 is the minimum) and Debian bookworm → **trixie** (OpenSSL
  3.5.7) for every Debian image. **Accepted consequence: the glibc floor of
  the glibc-output profile (`.so` / `.node` outputs) rises from bookworm's
  to trixie's glibc**, so those outputs no longer load on older distros
  (for example bookworm, RHEL 9, and Ubuntu releases older than trixie's
  glibc). The musl bundle is fully static and unaffected.
- **macOS:** Homebrew's `openssl@3` (3.5.9 today) stays, with a CI check
  that fails below 3.5.
- **Windows keeps libcurl** (schannel) for now: eco's sockets, TLS and
  reactor are POSIX-only (`IoReactor.hpp:10-12`, `TlsTransport.cpp`
  `#ifndef _WIN32`, nghttp2 inside `if(NOT WIN32)`). `HttpService` and
  `HttpTransfer` keep a curl backend compiled only on Windows. Dropping it
  there waits for a Windows port of the socket layer.
- **The JavaScript backend is unchanged** (Node's `http`/`https`). Where
  native behaviour has to choose, it follows Node/WHATWG fetch so the two
  backends agree (redirects, URL parsing, header handling).
- **URL parsing: WHATWG, via ada** (C API, `ada_c.h`), the parser Node itself
  uses, so native and JS backends parse URLs identically. The alternative,
  our own RFC 3986 parser, risks exactly the parity bugs ada avoids.
- **No Elm API change in this plan.** elm/http, `Eco.Http` and `Http.Stream`
  keep their APIs; the client sits behind them. A configurable
  `Http.Client` (pools, per-client TLS, HTTP version choice, response info)
  is a separate API plan on top of this pool (follow-ups).
- **A temporary backend switch** `ECO_HTTP_BACKEND=curl|native` during
  phases 4-6 for A/B testing; deleted with curl in phase 8.

## Current state

| Area | Today |
|---|---|
| elm/http, `Eco.Http` | `HttpService` (runtime): one detached worker thread, requests run one at a time with `curl_easy_perform`; fresh easy handle per request; results on two queues (elm lane, eco lane); progress events for `Http.track`; abort through `RequestControl`. Options used: method, URL, headers, body, timeout, redirects, `ACCEPT_ENCODING`, progress, `CAINFO`/`VERIFYPEER`. |
| `Http.Stream` | `HttpTransfer` (eco/system): one thread and one private curl multi handle per transfer; 4×64 KiB bounded upload/download channels; one Headers event, then a body stream; redirects (max 20, `http`/`https` only); timeout until headers. |
| WebSocket client | `DialJob` (`WsHandshake.hpp:160`): addresses tried **in order** under one deadline (no Happy Eyeballs), TLS with ALPN `h2,http/1.1`, HTTP/1.1 head parsed by hand (`parseResponseHead`, `WsHandshake.cpp:234`), HTTP/2 via `Http2ClientProtocol` (one stream, "no pool", `Http2Client.hpp`). |
| HTTP server | llhttp request mode (`Http1.cpp:250`), nghttp2 server sessions (`Http2.cpp`), on the reactor. |
| DNS | `getaddrinfo` on the SysWorkPool (`Socket.cpp:6-8, 130`). |
| UDP | `Socket.Udp` on the reactor (`Udp.cpp`), Elm-facing. |
| Layering | `IoReactor`, `Conn`, `Socket.Tls`, llhttp and nghttp2 live in the eco/system kernels (`system-kernel-cpp/`). **`eco` itself does not link the eco/system kernels** (`compiler/CMakeLists.txt:827-829`); it links `EcoRuntimeStatic` and the elm/eco kernels. |
| OpenSSL | musl bundle: Alpine 3.21, 3.3.7. glibc-output runtime: bookworm, 3.0.x. macOS: brew 3.5.9 (unpinned). |
| Tests | elm/http E2E: `test/elm-http/src/Http*Test.elm` (redirects, timeouts, cancel, track, chunked, HTTPS…). eco/system: `Http.Stream` tests and the HTTP/2 server tests (`test/eco-system/src/HttpServerHttp2*`). |

## Phase 0 — Layering: a networking library both `eco` and programs link

The client must be usable from `HttpService` (runtime, linked by `eco` and by
every program) without making `eco` link the eco/system kernels.

1. New static library **`EcoNet`** (new directory, e.g. `net/`, POD only,
   G1 rules as in eco/system), below both the runtime's kernels and
   eco/system. It takes, unchanged in behaviour:
   - `IoReactor`, `Conn`/`Transport`/`ConnProtocol`, the TLS layer
     (`TlsContext`, `TlsTransport`, later `AppleTrust`), DNS lookup, and the
     vendored llhttp, nghttp2 (and later ngtcp2/nghttp3, ada);
   - their threading glue to the `Scheduler` and `SysWorkPool`. Inventory
     first: list every include and symbol those files take from
     `eco-system/Core` (`Core.hpp` pulls in `platform/PlatformRuntime.hpp`,
     `Scheduler.hpp`, `TaskBinding.hpp`) and decide per item whether it
     moves to `EcoNet` or becomes a callback interface. The SysWorkPool
     likely moves too.
2. eco/system kernels link `EcoNet` (they use the same reactor instance:
   one reactor per process, never two). `EcoRuntimeStatic` (for
   `HttpService`) links `EcoNet`; `eco` gets it through the runtime.
3. AOT link lines (`EcoNativeDriver.cpp` musl / glibc / Darwin) and the
   bundle file lists (`runtime/src/codegen/CMakeLists.txt` `EcoBootConfig.h`
   emission) gain `libEcoNet.a`; nghttp2 becomes one archive owned by
   `EcoNet` instead of objects merged into `libEcoSystem_WebSocket.a`
   (`system-kernel-cpp/CMakeLists.txt:305-308`).
4. **Pure move, no behaviour change**: the full Linux and macOS E2E suites,
   the bootstrap and both bundle smoke tests pass unchanged before anything
   else lands. Lazy start: the reactor thread must still only start when
   something uses it (a program that never does networking starts no
   thread).

Open question for this phase: whether the reactor's exit handling (N13
`quiesce`, the TLS atexit hook) behaves the same inside `eco` (the compiler)
as in user programs; `eco` has not run the reactor before.

## Phase 1 — OpenSSL ≥ 3.5: Alpine 3.24, Debian trixie, macOS pin

1. **Alpine 3.21 → 3.24**, by digest, in lockstep (comment at
   `docker/static-build.Dockerfile:54-56`):
   `docker/static-build.Dockerfile:57`, `docker/llvm-alpine.Dockerfile:31`
   (and its "verified against alpine:3.21 / clang 19.1.4" notes, `:14`),
   `docker/static-dev.Dockerfile:43`. Rebuild `eco-llvm-alpine:21.1.8` on
   the new base. Check the packages the builder stage installs still exist
   under the same names (`static-build.Dockerfile:182-190`), and that the
   unhardened-flags check (`CMakeLists.txt` `ECO_MUSL_NO_HARDENING_FLAGS`)
   still passes with 3.24's clang defaults.
2. **Debian bookworm → trixie** everywhere:
   - `docker/static-build.Dockerfile:73` (`DEBIAN_IMAGE`), the
     `apt.llvm.org` source (`:118`, `llvm-toolchain-trixie-${LLVM_APT_MAJOR}`),
     the comments at `:16, :29, :81-94`, and `glibc-smoke`
     (`:391`, `debian:trixie-slim`);
   - `docker/llvm-debian.Dockerfile:13`, `docker/eco-dev.Dockerfile:13`
     (re-check the Temurin 21 note at `:86`: trixie has its own OpenJDK 21,
     so the Temurin step may go);
   - GenMC images: `docker/genmc.Dockerfile:22`,
     `docker/eco-dev-genmc.Dockerfile:14`, `docker/install-genmc.sh:28-38`
     (they pin bookworm's clang-19 and build GCC 14; trixie ships GCC 14 and
     LLVM 19, so the temporary GCC build may be unnecessary; verify GenMC
     still builds);
   - the zlib note at `CMakeLists.txt:470` (bookworm's zlib 1.2.13 →
     trixie's).
   - **glibc floor:** write the new minimum glibc (trixie's) into the docs
     that describe the `.so` / `.node` outputs and the release notes; update
     any glibc-version check in the `glibc-smoke` stage or the Stage D plan
     (`plans/stage-d-hybrid-link-profiles.md`).
3. **macOS:** in `mac-aot.yml` after `brew install openssl@3` (`:96`), fail
   unless `openssl@3` is ≥ 3.5.0 (read `opensslv.h` from the keg). The
   floor check (`test/scripts/check-macho-floor.sh`) already covers the
   static archives' minimum macOS.
4. **CMake:** `find_package(OpenSSL 3.5 REQUIRED)` on non-Windows builds, so
   an old OpenSSL fails at configure time, not in a QUIC test.
5. Gate: the full E2E suites, bootstrap, musl bundle smoke, `glibc-smoke`
   and `bundle-smoke` (macOS) green on the new images, with no code change.
   Record the bundle size and the bootstrap time against the old images.

## Phase 2 — Client core: connections, HTTP/1.1, the pool

All on the reactor thread, in `EcoNet` (`net/http/`).

1. **URL handling (ada, C API).** Vendor ada (FetchContent, pinned, URL hash,
   as llhttp). Parse, validate the scheme (`http`, `https`; anything else is
   `BadUrl`, as today), get host (IDNA to ASCII, as WHATWG), port, path and
   query. Resolve redirect `Location` against the request URL.
2. **Dialer with Happy Eyeballs v2 (RFC 8305).** Resolve with `getaddrinfo`
   (SysWorkPool), interleave IPv6/IPv4 addresses, start the next attempt
   250 ms after the previous one unless it has already failed, keep the first
   connection that completes TCP (and TLS), close the rest. One deadline for
   the whole dial (the request's connect budget). A small per-pool DNS cache
   (60 s, as curl's default) keyed on host. The WebSocket `DialJob` switches
   to this dialer later (follow-ups); it keeps its in-order dial for now.
3. **TLS** through `Socket.Tls` client contexts: SNI, `SSL_set1_host` / IP
   SAN check, ALPN `h2,http/1.1` (plain `http://` gets no ALPN and HTTP/1.1).
   Trust: mode 0 (system), the same `SSL_CERT_FILE` / `SSL_CERT_DIR`
   handling, so macOS gets the Keychain verifier from
   plans/mac-keychain-trust.md. `CURL_CA_BUNDLE` and the per-request
   `caInfo` (`HttpService.hpp:65`) map to a trusted-certificates context
   (mode 1) built from that file; `verifyPeer = false` to mode 2. Keep
   honouring `CURL_CA_BUNDLE` for compatibility, documented as an alias of
   `SSL_CERT_FILE` for HTTP.
4. **HTTP/1.1 protocol** (`ConnProtocol`):
   - request serialization: request line (origin form; absolute form through
     an HTTP proxy, phase 5), `Host`, the user's headers (same filtering as
     today: an empty name or CR/LF in name or value is not sent),
     `Content-Length` for a known body, `Transfer-Encoding: chunked` for a
     stream body, `Accept-Encoding: gzip, deflate` (phase 2.7), no
     `Expect: 100-continue`;
   - response parsing with llhttp in `HTTP_RESPONSE` mode, strict (no
     lenient flags, as the server); 1xx skipped (101 is not expected); no
     body for HEAD, 204, 304; chunked and content-length bodies; read-to-EOF
     bodies (connection then not reused);
   - header names lower-cased, repeated headers joined with `", "` in
     arrival order (as both paths do today), status text from the reason
     phrase.
5. **Pool.** Keyed on (scheme, host, port, proxy, TLS-context identity), so
   different trust settings never share a connection.
   - HTTP/1.1: up to 6 connections per key (browser default), idle ones
     kept 60 s, one request at a time per connection, no pipelining.
   - A reused HTTP/1.1 connection that fails before any response byte (the
     server closed it while idle) retries the request once on a new
     connection if it is idempotent or its body has not been sent (curl
     does the same).
   - `maxConnections` per process as a safety cap (e.g. 256) with a queue.
6. **Requests:** one `HttpExchange` per request with the states
   connecting → sending → awaiting head → body → done; timeouts on reactor
   timers (elm/http: whole request; `Http.Stream`: until the final headers);
   cancellation from any thread through a reactor command (generation
   checked, as `Conn`).
7. **Content decoding:** `gzip` and `deflate` with zlib (already linked),
   streaming, on the response body; `Content-Encoding` other than those is
   passed through undecoded with its header intact (as curl with only
   gzip/deflate built in). Check what elm/http expects for
   `Content-Length` after decoding (curl reports the encoded header
   unchanged; keep that).
8. **Redirects:** at most 20 (as `Http.Stream` documents), only to `http`/
   `https` (else `BadUrl` with the request's URL, as documented). Method
   rules as WHATWG fetch: 303 → GET (except HEAD); 301/302 with POST → GET;
   307/308 keep method and body (a stream body that has already been
   consumed cannot be replayed: fail with `NetworkError`, and document it).
   On a cross-origin redirect drop `Authorization`, `Cookie` and
   `Proxy-Authorization`. **Behaviour change to check:** today
   `CURLOPT_CUSTOMREQUEST` makes curl keep the original method on every
   redirect; `HttpRedirectTest` and the JS twins decide what is right, and
   the result is written into the docs.
9. **Unit tests** (C++ suite) for each piece with in-memory transports:
   parser edge cases (split heads, chunk extensions, trailers ignored,
   oversized heads → `NetworkError`), redirect method table, URL resolution,
   pool reuse and the stale-connection retry, Happy Eyeballs timing with fake
   connect results.

## Phase 3 — HTTP/2 client

1. Generalize `Http2ClientProtocol` (today one WebSocket stream per session,
   `Http2Client.hpp`) into a **multi-stream client session** that the pool
   owns per key when ALPN chooses `h2`. Keep the WebSocket's use as one
   kind of stream on it (the extended CONNECT), so `wss` over HTTP/2 can
   later share pooled connections too (follow-ups).
2. Session settings as the server's where they apply: ENABLE_PUSH 0, manual
   flow control (64 KiB initial stream window, connection window sized so
   N concurrent downloads do not starve), consuming the window as the body
   channel takes the bytes (backpressure from `Http.Stream`'s 4×64 KiB
   channel reaches the server).
3. Concurrency: new streams up to the server's MAX_CONCURRENT_STREAMS;
   further requests wait for a free stream or open a second connection only
   when the first is saturated (one connection per key is the normal case).
4. Request mapping: pseudo headers from the parsed URL, header names
   lower-cased, connection-specific headers (`Connection`, `Keep-Alive`,
   `Proxy-Connection`, `Transfer-Encoding`, `Upgrade`, `TE` other than
   `trailers`) dropped, as the server's `toH2Nv` does.
5. Response mapping: no reason phrase. elm/http substitutes the standard
   phrase already (`HttpExports.cpp:259-260`); for `Http.Stream` decide by
   its JS twin (Node reports `""` over HTTP/2) and document it.
6. GOAWAY: streams above last-stream-id are retried on a new connection
   (they were not processed); RST_STREAM(REFUSED_STREAM) likewise.
   Connection loss mid-response is a `NetworkError` (before headers) or a
   body-stream failure (after, as today).
7. Trailers are received and ignored (kept in the exchange for the future
   `Http.Client` API).

## Phase 4 — Switch `Http.Stream` and elm/http (behind the backend switch)

1. **`Http.Stream`:** `HttpTransfer` drives an `HttpExchange` instead of a
   thread with a curl multi handle. The upload channel feeds the request
   body (chunked over HTTP/1.1, DATA frames over HTTP/2); the download
   channel receives the body with the same 4×64 KiB bound, now enforced by
   not reading the socket (HTTP/1.1) or not consuming the stream window
   (HTTP/2) instead of a blocked thread. Events stay exactly as today (one
   Headers or one failure event per transfer, `HttpTransfer.hpp:19-24`).
2. **elm/http and `Eco.Http`:** `HttpService` keeps its interface
   (`submit`, the two result lanes, progress, `RequestControl` abort,
   `HttpService.hpp:34-108`) so `HttpExports.cpp` and `eco-kernel/Http.cpp`
   do not change; its worker thread is replaced by submitting an exchange to
   the reactor. Requests now run concurrently.
   - Progress for `Http.track`: emit `Progress` from the exchange as body
     bytes are sent and received (`isUpload`, `now`, `total` from
     `Content-Length` when known), at most every 50 ms per request, matching
     the frequency curl's progress callback gave (measure the current rate
     first; `HttpTrackProgressTest`/`HttpTrackChunkedTest` pin it).
   - The `Content-Type` behaviour of an empty MIME type changes: libcurl
     added `application/x-www-form-urlencoded` for a POST body
     (documented in `ecosyskernel/src/Http/Stream.elm` under `Body`); the
     native client adds nothing, as the JS backend. Update those docs.
3. `ECO_HTTP_BACKEND=curl` keeps the old path for A/B runs; default stays
   `curl` until phase 6's gate passes, then flips to `native`.

## Phase 5 — Proxies

libcurl honours proxy environment variables by default, and users behind
corporate proxies depend on it without knowing. The native client must do
the same before it becomes the default.

1. Variables, as curl reads them: `http_proxy` (lower-case only for http, as
   curl, to avoid the httpoxy CGI problem), `HTTPS_PROXY`/`https_proxy`,
   `ALL_PROXY`/`all_proxy`, `NO_PROXY`/`no_proxy` (comma-separated hosts,
   domain suffixes, `*`, IP addresses; CIDR ranges as newer curl does).
2. `http://` through an HTTP proxy: absolute-form request line on a
   connection to the proxy; `https://`: `CONNECT host:port` to the proxy,
   then TLS to the origin through the tunnel (ALPN as usual, so HTTP/2 works
   through the tunnel). An `https://` proxy URL (TLS to the proxy itself) is
   supported if curl's default build supported it on that platform; check
   the vendored build's features before deciding.
3. Proxy credentials from the proxy URL's userinfo, sent as
   `Proxy-Authorization: Basic`. A 407 is a `NetworkError` (curl: same
   without auth configured).
4. SOCKS proxies (`socks5://` in `ALL_PROXY`): curl supported them. Decide
   from usage; if dropped, a configured SOCKS proxy must fail loudly
   (`NetworkError` with a message naming the unsupported scheme), never be
   silently bypassed.
5. HTTP/3 is never used through a proxy (phase 7).
6. Not covered: system proxy settings and PAC files (macOS System Settings,
   Windows), which neither curl nor this client reads. Document it.

## Phase 6 — Gate, default flip

1. **Existing suites with `ECO_HTTP_BACKEND=native`:** all elm/http E2E tests
   (`test/elm-http/src/`), the `Http.Stream` tests, the eco/system suite, the
   package-download path (bootstrap, and `bundle-smoke` with `~/.eco` moved
   aside), on Linux (dev, musl bundle, glibc-output) and macOS.
2. **New E2E tests:**
   - keep-alive: N sequential requests to a test server that counts
     connections → 1 connection;
   - concurrency: `Cmd.batch` of 10 requests to a server that delays each
     response 500 ms → total well under 5 s (today ≥ 5 s);
   - HTTP/2 multiplexing: eco's own `Http.Server` with `http2 = True` as the
     test server, 10 concurrent requests → 1 connection, all
     `HttpVersion` `Http2` on the server side;
   - HTTP/1.1 fallback: server without `http2` → requests succeed;
   - redirects: the full method/status matrix, cross-origin header
     stripping, the 20-redirect limit, non-HTTP target;
   - gzip/deflate bodies, chunked bodies, HEAD/204/304;
   - proxies: a small test proxy (CONNECT + absolute-form, counting
     requests) with `HTTPS_PROXY`/`http_proxy`/`NO_PROXY` combinations;
   - Happy Eyeballs: a host resolving to an unreachable IPv6 address plus a
     working IPv4 one (via a test-only resolver override) connects within
     ~300 ms;
   - stale keep-alive connection closed by the server between requests →
     the next request still succeeds;
   - TLS: the existing `HttpsGetTest` plus `CURL_CA_BUNDLE`/`SSL_CERT_FILE`
     overrides, and on macOS the Keychain-only root test from
     plans/mac-keychain-trust.md step 3.2, now over `Http.get` too.
3. **Fuzzing:** libFuzzer targets for the response path (llhttp callbacks
   into our head/body handling, decoded bodies), redirect `Location`
   handling, proxy environment parsing and `NO_PROXY` matching. llhttp,
   nghttp2 and ada are fuzzed upstream; our glue is not.
4. **Performance gate** (measure, then decide; not a blocker for
   correctness): bootstrap wall time with a cold package cache, and a
   microbenchmark of 100 parallel GETs to a local server, native versus
   curl, N=3 medians.
5. Flip the default to `native`.

## Phase 7 — HTTP/3 (ngtcp2 + nghttp3)

1. **Vendor** ngtcp2 (with `libngtcp2_crypto_ossl`) and nghttp3 into
   `EcoNet` the same way as nghttp2 (FetchContent download only, sources
   built as our own static library, generated version headers, pinned
   versions and hashes), non-Windows only. Configure-time check of OpenSSL
   ≥ 3.5 (phase 1.4).
2. **The OpenSSL backend's rules** (ngtcp2 README: experimental; OpenSSL's
   QUIC TLS API needs crypto data and the transport-parameter buffer kept
   until OpenSSL releases them; the `ngtcp2_conn` must outlive the `SSL` or
   the app data must be cleared before `SSL_free`). Encode them in one
   owner object per QUIC connection, with an ASan/TSan unit test that frees
   in every order. Track upstream: if the backend is still experimental when
   this phase starts, record that and decide whether to ship HTTP/3
   default-off.
3. **UDP on the reactor:** a QUIC connection owns a connected UDP socket
   (not an Elm-facing `Socket.Udp` entry) registered with the reactor;
   `recvmsg`/`sendmsg`, ECN off at first; GSO/GRO and `recvmmsg` batching as
   a later optimization; path MTU from ngtcp2's PMTUD.
4. **Session:** an ngtcp2 client connection plus an nghttp3 connection,
   timers from `ngtcp2_conn_get_expiry` on reactor timers, streams mapped
   to `HttpExchange` like HTTP/2 streams (same request/response mapping,
   QPACK instead of HPACK, no reason phrase).
5. **Discovery: `Alt-Svc`.** Parse `Alt-Svc` response headers (`h3`, `ma`,
   `clear`) into a per-process cache keyed on origin. HTTPS DNS records
   (RFC 9460) need a resolver beyond `getaddrinfo`: follow-up.
6. **Racing and fallback:** for an origin with a cached `h3` alternative,
   start QUIC and, 300 ms later unless QUIC has completed its handshake,
   TCP+TLS in parallel; use the first that completes. A QUIC failure
   (handshake timeout, UDP blocked) marks `h3` broken for that origin for
   5 minutes (doubling on repeat failures) and falls back to TCP with no
   error to the program. Never HTTP/3 through a proxy or when
   `ECO_HTTP3=0` (a kill switch kept permanently for networks that
   misbehave).
7. **Pool:** a QUIC connection is one more connection kind per key, shared
   by concurrent requests as HTTP/2 is; connection migration is off.
8. **Tests:** an HTTP/3 test server (the ngtcp2 example server built
   against the same OpenSSL, or `Http.Server` HTTP/3 if that follow-up
   lands first) advertising `Alt-Svc`; first request over TCP, the next over
   HTTP/3 (verified on the server); UDP blocked (firewall rule or a dead
   port in `Alt-Svc`) → TCP fallback within the race delay and the broken
   mark; `ECO_HTTP3=0` → never HTTP/3; interop run against a public HTTP/3
   endpoint in a non-gating CI job.

## Phase 8 — Remove libcurl on POSIX

1. Delete the curl backend from `HttpService` and `HttpTransfer` on
   non-Windows builds, and `ECO_HTTP_BACKEND`.
2. CMake: the vendored curl (`CMakeLists.txt:332-460`) only for `WIN32`;
   zlib stays (libzip, content decoding). Remove `libcurl_static` /
   `CURL::libcurl` from the POSIX targets
   (`runtime/src/codegen/CMakeLists.txt:578-585, 673-675, 734-740`,
   `system-kernel-cpp/CMakeLists.txt:227-237`), `libcurlStaticA` /
   `glibcCurlA` from the bundle lists (`:1391-1430, 1515`), `-lcurl` from
   `linkExecutableDarwin` (`EcoNativeDriver.cpp:683`) and the Linux link
   lines.
3. macOS: the `mac-aot` linked-library gate must now show no
   `/usr/lib/libcurl.4.dylib` in `eco` or AOT outputs; update its
   allow-list. The Darwin bundle no longer depends on Apple's curl.
4. Docs: `docs/building-macos.md` and `docs/building.md` (bundle contents,
   libcurl no longer linked; trust; proxies; HTTP/2 and HTTP/3), the
   `Http.Stream` docs (redirect methods, `statusText` over HTTP/2, empty
   MIME type), the elm/http native-behaviour notes, plans/mac-keychain-trust.md
   ("HTTP in the meantime" is over).
5. The `Eco.Http` comment about `curl_easy_perform`
   (`eco-kernel-cpp/src/eco-kernel/Http.cpp:5`) and similar comments updated.

## Order and gates

Phase 0 → phase 1 (independent of 0; either first) → 2 → 3 → 4 → 5 → 6 →
7 → 8. Phase 8 may land before phase 7 once phase 6 passes (HTTP/3 is an
addition, not a prerequisite for dropping curl). Every phase lands with:
elm-tests, the Linux and macOS JIT and AOT E2E suites, the bootstrap, the
musl bundle smoke, `glibc-smoke` and `bundle-smoke` green. Phases 0 and 1
are pure moves and upgrades: their gate is "no test result changes".

## Risks

- **Owned code replaces curl's hardening.** Redirects, URL handling,
  proxies, the pool and decoding become our code. Mitigation: ada, llhttp,
  nghttp2/3 and ngtcp2 do the parsing; fuzz our glue (phase 6.3).
- **Silent behaviour changes** for users of curl's defaults: proxy
  variables (phase 5), redirect methods (phase 2.8), empty MIME type
  (phase 4.2), `statusText` over HTTP/2 (phase 3.5), progress-event rate
  (phase 4.2). Each is listed, tested and documented; none is left to
  chance.
- **glibc floor rises** with trixie (accepted): `.so`/`.node` outputs stop
  loading on older distros. Say so in the release notes.
- **Image upgrades ripple:** Alpine 3.24 and trixie bring new compilers and
  libraries for every docker build (LLVM image, GenMC, dev images);
  phase 1 is gated on unchanged test results to catch that early.
- **`libngtcp2_crypto_ossl` is experimental** and has lifetime rules that
  are easy to get wrong (use-after-free). Mitigation: one owner object,
  sanitizer tests, ship HTTP/3 default-off if upstream still calls it
  experimental.
- **UDP-hostile networks:** corporate firewalls often block UDP 443. The
  race-and-fallback design (phase 7.6) must make HTTP/3 never slower than
  TCP; the `ECO_HTTP3=0` kill switch stays.
- **Reactor inside `eco`:** the compiler starts using the reactor for
  package downloads (phase 0). Its exit and fork/spawn behaviour
  (`spawnChild`, `pthread_atfork` in the GC helper pool) must be checked.
- **Windows stays on curl**, so Windows behaviour (proxies, redirects,
  HTTP/2 off) diverges from POSIX until the socket layer is ported.

## Follow-ups (not in this plan)

- **`Http.Client` API** in eco/system: client handles over this pool
  (per-client TLS options, HTTP version choice, connection limits, idle
  timeout), `request`/`task` through a client, response info (HTTP version,
  connection reuse), later trailers.
- **WebSocket client on the shared dialer and pool:** Happy Eyeballs for
  `WebSocket.connect`, and `wss` over HTTP/2 sharing pooled connections.
- **`Http.Server` HTTP/3** on the same ngtcp2/nghttp3 vendoring, advertised
  with `Alt-Svc`.
- **HTTPS DNS records (RFC 9460)** for HTTP/3 discovery without a first TCP
  request.
- **Windows:** port the socket layer and TLS (with the Windows certificate
  store), then drop curl there too.
- **System proxy settings / PAC** on macOS and Windows.
