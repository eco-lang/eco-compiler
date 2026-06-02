# syntax=docker/dockerfile:1
# ============================================================================
# Stage B — fully-static `eco` binary (MUSL + libc++).
# See plans/static-link-eco-binary.md (Stage B).
#
# Produces a single `eco` executable with ZERO shared-library dependencies
# (verified below with `readelf -d`). Three stages:
#
#   1. llvm          — FROM eco-llvm-alpine:21.1.4 (built once by
#                      docker/llvm-alpine.Dockerfile). LLVM 21.1.4 + MLIR
#                      from source, MUSL + libc++.
#   2. eco-builder   — build the static `eco` against that LLVM, using the
#                      release preset.
#   3. eco-static    — FROM scratch; ships just the binary.
#
# Build (one-off, slow — only when LLVM_VERSION changes):
#   docker build -f docker/llvm-alpine.Dockerfile -t eco-llvm-alpine:21.1.4 .
# Build the static eco (fast — pulls /opt/llvm-mlir from the image above):
#   docker build -f docker/static-build.Dockerfile -t eco-static .
# Extract:
#   id=$(docker create eco-static); docker cp "$id:/eco" ./eco; docker rm "$id"
#
# Toolchain facts (eco-builder stage only — LLVM-stage facts live in
# docker/llvm-alpine.Dockerfile):
#   - libcurl and libzip are vendored by CMake via FetchContent under
#     ECO_STATIC (Alpine ships no `libzip-static`), so they are NOT installed
#     as packages — the vendored builds need only openssl + zlib statics.
# ============================================================================

# alpine:3.21 pinned by digest for reproducibility (risk register: "pin the
# base image SHA, not just alpine:edge"). Captured 2026-05-25. Kept in lockstep
# with docker/llvm-alpine.Dockerfile / docker/static-dev.Dockerfile.
ARG ALPINE_DIGEST=sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

# ============================================================================
# Stage 1: pre-built LLVM + MLIR (Alpine / MUSL + libc++)
# Produced by docker/llvm-alpine.Dockerfile. Override with --build-arg
# LLVM_IMAGE=... if tagged differently.
# ============================================================================
ARG LLVM_IMAGE=eco-llvm-alpine:21.1.4
FROM ${LLVM_IMAGE} AS llvm

# ============================================================================
# Stage 2: build the static eco against the MUSL LLVM
# ============================================================================
FROM alpine@${ALPINE_DIGEST} AS eco-builder

# Toolchain + the static system archives the eco link consumes:
#   libc++ / -dev / -static, compiler-rt  -> C++ runtime, libc++abi, builtins
#   llvm-libunwind                        -> shared unwinder for the copied
#                                            /opt/llvm-mlir tools (mlir-tblgen)
#   llvm-libunwind-static                 -> libunwind.a for eco's -static
#                                            link (-unwindlib=libunwind)
#   openssl-dev / openssl-libs-static     -> TLS backend for vendored libcurl
#   zlib-dev / zlib-static                -> deflate for vendored libcurl/libzip
#   binutils                              -> /usr/bin/ld for AOT (Gate-B) and
#                                            the bfd fallback (ECO_LINK_WITH_BFD)
#   nodejs / npm (+ pnpm)                 -> the Elm/Guida compiler self-build
# libcurl and libzip are intentionally absent — vendored via FetchContent.
RUN apk add --no-cache \
      git build-base cmake samurai python3 \
      clang lld \
      musl-dev linux-headers \
      libc++ libc++-dev libc++-static compiler-rt \
      llvm-libunwind llvm-libunwind-static \
      openssl-dev openssl-libs-static \
      zlib-dev zlib-static \
      binutils \
      zip \
      nodejs npm \
 && npm install -g pnpm

# RapidCheck: the top-level CMakeLists.txt does find_package(rapidcheck
# REQUIRED) for the `ecor` allocator-test binary. We only build `--target
# eco` (which does not depend on ecor or the test/ tree), but CMake evaluates
# that find_package at configure time regardless, so it must resolve. Install
# it from source exactly as the main Dockerfile does — this stage is
# throwaway, so it does not bloat the final scratch artifact.
RUN git clone --depth=1 https://github.com/emil-e/rapidcheck.git /tmp/rapidcheck \
 && cmake -S /tmp/rapidcheck -B /tmp/rapidcheck/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
 && cmake --build /tmp/rapidcheck/build \
 && cmake --install /tmp/rapidcheck/build \
 && rm -rf /tmp/rapidcheck

COPY --from=llvm /opt/llvm-mlir /opt/llvm-mlir

ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir
ENV PATH=/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The Elm/Guida bootstrap is memory-hungry; match the main dev image.
ENV NODE_OPTIONS=--max-old-space-size=12000

WORKDIR /eco
COPY . .

# Configure + build only the eco binary. The musl preset sets ECO_STATIC,
# ECO_STATIC_MUSL, ECO_LINK_WITH_BFD=OFF and the -static libc++ link flags.
RUN cmake --preset release
RUN cmake --build build-static --target eco

# Strip, then HARD-FAIL the build if the binary still has any dynamic NEEDED
# entries — the whole point of Stage B is a zero-deps executable.
RUN strip -s build-static/compiler/build-kernel/bin/eco \
 && if readelf -d build-static/compiler/build-kernel/bin/eco 2>/dev/null | grep -q NEEDED; then \
        echo "FATAL: eco has dynamic NEEDED entries — not fully static:" >&2; \
        readelf -d build-static/compiler/build-kernel/bin/eco >&2; \
        exit 1; \
    fi \
 && echo "OK: eco is fully static (no NEEDED entries)" \
 && ls -lh build-static/compiler/build-kernel/bin/eco

# Build the Stage C distribution bundles (.tar.gz + .zip). CPack stages
# the eco binary + lib/eco-runtime/{crt,project,ld.lld,libc.a,…} tree
# defined by the install() rules, then produces both archives.
RUN cmake --build build-static --target package \
 && ls -lh build-static/eco-0.1.0-x86_64-linux-musl.tar.gz \
           build-static/eco-0.1.0-x86_64-linux-musl.zip

# Smoke test the bundle in-container: extract into /tmp/eco-smoke, scaffold a
# minimal project (elm.json + src/Hello.elm — eco refuses to build without
# elm.json), build Hello.elm against the extracted tree, then verify the
# produced binary is fully static and runs to completion.
#
# Hello.elm is `text "Hello!"` (browser-style Html); on a headless runtime
# it exits non-zero, so the smoke test does not check ./hello's exit code —
# only that it runs without crashing and yields a fully-static ELF.
RUN mkdir -p /tmp/eco-smoke \
 && tar -xzf build-static/eco-0.1.0-x86_64-linux-musl.tar.gz -C /tmp/eco-smoke \
 && cp compiler/examples/elm.json      /tmp/eco-smoke/elm.json \
 && mkdir -p /tmp/eco-smoke/src \
 && cp compiler/examples/src/Hello.elm /tmp/eco-smoke/src/Hello.elm \
 && cd /tmp/eco-smoke \
 && ./bin/eco make src/Hello.elm --output=hello \
 && test -x ./hello \
 && hello_rc=0; ./hello >/dev/null 2>&1 || hello_rc=$? \
 && if [ "$hello_rc" -eq 139 ] || [ "$hello_rc" -eq 134 ]; then \
        echo "FATAL: hello crashed (rc=$hello_rc — SIGSEGV/SIGABRT)" >&2; exit 1; \
    fi \
 && if readelf -d ./hello 2>/dev/null | grep -q NEEDED; then \
        echo "FATAL: hello produced by bundled eco is not static" >&2; \
        exit 1; \
    fi \
 && echo "OK: bundle smoke test passed — eco produced a static hello binary (rc=$hello_rc)"

# ============================================================================
# Stage 3: ship just the binary (back-compat, slim image)
# ============================================================================
FROM scratch AS eco-static
COPY --from=eco-builder /eco/build/compiler/build-kernel/bin/eco /eco
ENTRYPOINT ["/eco"]

# ============================================================================
# Stage 4: ship the distribution bundles (.tar.gz + .zip).
# `docker build --target eco-bundle -o ./dist .` drops both archives in ./dist.
# ============================================================================
FROM scratch AS eco-bundle
COPY --from=eco-builder /eco/build/eco-0.1.0-x86_64-linux-musl.tar.gz /
COPY --from=eco-builder /eco/build/eco-0.1.0-x86_64-linux-musl.zip    /
