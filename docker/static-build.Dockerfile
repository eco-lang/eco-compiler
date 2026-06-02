# syntax=docker/dockerfile:1
# ============================================================================
# Stage B — fully-static `eco` binary (MUSL + libc++).
# See plans/static-link-eco-binary.md (Stage B).
#
# Produces a single `eco` executable with ZERO shared-library dependencies
# (verified below with `readelf -d`). Three stages:
#
#   1. llvm-builder  — build LLVM 21.1.4 + MLIR from source, against MUSL,
#                      compiled with -stdlib=libc++.
#   2. eco-builder   — build the static `eco` against that LLVM, using the
#                      ninja-clang-lld-linux-musl preset.
#   3. eco-static    — FROM scratch; ships just the binary.
#
# Build:   docker build -f docker/static-build.Dockerfile -t eco-static .
# Extract: id=$(docker create eco-static); docker cp "$id:/eco" ./eco; docker rm "$id"
#
# Toolchain facts (verified against alpine:3.21 / clang 19.1.4 before this
# file was written):
#   - libc++ is packaged as libc++ / libc++-dev / libc++-static (NOT the
#     `libcxx-*` names an earlier draft of the plan assumed). libc++abi is
#     bundled inside those packages — there is no separate libc++abi package.
#   - compiler-rt and llvm-libunwind-static are available, so the eco link
#     uses the clean `-rtlib=compiler-rt -unwindlib=libunwind` path and does
#     NOT need the Stage-A `--allow-multiple-definition` workaround.
#   - The verified static link recipe is:
#       clang++ -static -stdlib=libc++ -rtlib=compiler-rt \
#               -unwindlib=libunwind -lc++abi -fuse-ld=lld
#     (encoded in the musl preset's CMAKE_EXE_LINKER_FLAGS_INIT). It needs
#     `-lc++abi` explicitly; omitting it leaves libc++ vtables undefined.
#   - libcurl and libzip are vendored by CMake via FetchContent under
#     ECO_STATIC (Alpine ships no `libzip-static`), so they are NOT installed
#     as packages — the vendored builds need only openssl + zlib statics.
# ============================================================================

# alpine:3.21 pinned by digest for reproducibility (risk register: "pin the
# base image SHA, not just alpine:edge"). Captured 2026-05-25.
ARG ALPINE_DIGEST=sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

# ============================================================================
# Stage 1: build LLVM + MLIR from source, against MUSL + libc++
# ============================================================================
FROM alpine@${ALPINE_DIGEST} AS llvm-builder
ARG LLVM_VERSION=21.1.4
ARG CMAKE_BUILD_PARALLEL_LEVEL=24

# build-base provides make + musl-dev; libc++-dev / libc++-static are the
# bootstrap libc++ used to compile LLVM with -stdlib=libc++. compiler-rt +
# llvm-libunwind(-static) are required because linking against libc++abi
# pulls in the unwinder (`-lunwind`) — without them the very first CMake
# compiler-detection try-compile fails with "cannot find -lunwind".
RUN apk add --no-cache \
      git build-base cmake samurai python3 \
      clang lld \
      musl-dev linux-headers \
      libc++ libc++-dev libc++-static \
      compiler-rt llvm-libunwind llvm-libunwind-static

WORKDIR /src
RUN git clone --depth=1 --single-branch \
      --branch "llvmorg-${LLVM_VERSION}" \
      https://github.com/llvm/llvm-project.git

# Mirrors the main Dockerfile's LLVM configuration, with the MUSL deltas:
#   - compile with -stdlib=libc++ (+ -lc++abi so the LLVM tools link),
#   - default target triple x86_64-alpine-linux-musl,
#   - X86 backend only (Stage B is x86_64-only — plan scope).
# LLVM_ENABLE_RUNTIMES stays "libunwind" (same as the main Dockerfile) so that
# libunwind.a installs under /opt/llvm-mlir where cmake/LLVMLibunwind.cmake
# looks for it. libc++/libc++abi come from Alpine's packages, used
# consistently for both this build and the eco build (so there is no libc++
# ABI skew — the concern Decision Q5 raised, addressed here by using one
# libc++ everywhere rather than two).
WORKDIR /src/llvm-project
RUN cmake -S llvm -B build -G Ninja \
      -DLLVM_ENABLE_PROJECTS="mlir;lld" \
      -DLLVM_ENABLE_RUNTIMES="libunwind" \
      -DLLVM_TARGETS_TO_BUILD="X86" \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_ENABLE_RTTI=ON \
      -DMLIR_ENABLE_CMAKE_PACKAGE=ON \
      -DLLVM_ENABLE_ZLIB=OFF \
      -DLLVM_ENABLE_LIBXML2=OFF \
      -DLLVM_USE_LINKER=lld \
      -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-alpine-linux-musl \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_CXX_FLAGS="-stdlib=libc++" \
      -DCMAKE_EXE_LINKER_FLAGS="-static -stdlib=libc++ -rtlib=compiler-rt -unwindlib=libunwind -lc++abi -fuse-ld=lld" \
      -DCMAKE_INSTALL_PREFIX=/opt/llvm-mlir \
 && cmake --build build \
 && cmake --install build \
 && if readelf -d /opt/llvm-mlir/bin/ld.lld 2>/dev/null | grep -q NEEDED; then \
        echo "FATAL: bundled ld.lld is not static — NEEDED entries present:" >&2; \
        readelf -d /opt/llvm-mlir/bin/ld.lld >&2; \
        exit 1; \
    fi \
 && echo "OK: /opt/llvm-mlir/bin/ld.lld is fully static" \
 && mkdir -p /opt/llvm-mlir/libexec/eco-bundle \
 && mv /opt/llvm-mlir/bin/ld.lld /opt/llvm-mlir/libexec/eco-bundle/ld.lld \
 && echo "Moved static ld.lld out of /opt/llvm-mlir/bin/ so clang -fuse-ld=lld in" \
 && echo "Stage 2 picks /usr/bin/ld.lld (zlib-capable) for the eco/bootstrap link."

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

COPY --from=llvm-builder /opt/llvm-mlir /opt/llvm-mlir

ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir
ENV PATH=/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The Elm/Guida bootstrap is memory-hungry; match the main dev image.
ENV NODE_OPTIONS=--max-old-space-size=12000

WORKDIR /eco
COPY . .

# Configure + build only the eco binary. The musl preset sets ECO_STATIC,
# ECO_STATIC_MUSL, ECO_LINK_WITH_BFD=OFF and the -static libc++ link flags.
RUN cmake --preset ninja-clang-lld-linux-musl
RUN cmake --build build --target eco

# Strip, then HARD-FAIL the build if the binary still has any dynamic NEEDED
# entries — the whole point of Stage B is a zero-deps executable.
RUN strip -s build/compiler/build-kernel/bin/eco \
 && if readelf -d build/compiler/build-kernel/bin/eco 2>/dev/null | grep -q NEEDED; then \
        echo "FATAL: eco has dynamic NEEDED entries — not fully static:" >&2; \
        readelf -d build/compiler/build-kernel/bin/eco >&2; \
        exit 1; \
    fi \
 && echo "OK: eco is fully static (no NEEDED entries)" \
 && ls -lh build/compiler/build-kernel/bin/eco

# Build the Stage C distribution bundles (.tar.gz + .zip). CPack stages
# the eco binary + lib/eco-runtime/{crt,project,ld.lld,libc.a,…} tree
# defined by the install() rules, then produces both archives.
RUN cmake --build build --target package \
 && ls -lh build/eco-0.1.0-x86_64-linux-musl.tar.gz \
           build/eco-0.1.0-x86_64-linux-musl.zip

# Smoke test the bundle in-container: extract into /tmp/eco-smoke, scaffold a
# minimal project (elm.json + src/Hello.elm — eco refuses to build without
# elm.json), build Hello.elm against the extracted tree, then verify the
# produced binary is fully static and runs to completion.
#
# Hello.elm is `text "Hello!"` (browser-style Html); on a headless runtime
# it exits non-zero, so the smoke test does not check ./hello's exit code —
# only that it runs without crashing and yields a fully-static ELF.
RUN mkdir -p /tmp/eco-smoke \
 && tar -xzf build/eco-0.1.0-x86_64-linux-musl.tar.gz -C /tmp/eco-smoke \
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
