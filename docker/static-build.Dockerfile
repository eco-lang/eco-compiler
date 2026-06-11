# syntax=docker/dockerfile:1
# ============================================================================
# Stage B — fully-static `eco` binary (MUSL + libc++) — plus Stage D hybrid
# link profiles: the bundle also carries a glibc-ABI link-input tree
# (lib/eco-runtime/glibc/) so the installed eco can link `.so`/`.node`
# outputs that load into stock (glibc) hosts. See
# plans/static-link-eco-binary.md (Stage B) and
# plans/stage-d-hybrid-link-profiles.md (Stage D).
#
# Produces a single `eco` executable with ZERO shared-library dependencies
# (verified below with `readelf -d`). Stages:
#
#   1. llvm          — FROM eco-llvm-alpine:21.1.4 (built once by
#                      docker/llvm-alpine.Dockerfile). LLVM 21.1.4 + MLIR
#                      from source, MUSL + libc++.
#   2. glibc-runtime — FROM debian:bookworm, self-contained: apt toolchain +
#                      LLVM runtime statics from apt (libc++-14-dev etc. —
#                      mirroring how the musl side takes libc++ from Alpine
#                      apk). Compiles the glibc-ABI, verified-PIC archive set
#                      (project archives + dep statics + CRT objects) that
#                      the bundle's `.so`/`.node` links consume; staged at
#                      /out/glibc-runtime-tree. No MLIR/LLVM source image:
#                      the archive-only configure gates MLIR off entirely.
#   3. eco-builder   — build the static `eco` against the MUSL LLVM using the
#                      release preset; merge the glibc tree into the bundle;
#                      package + Alpine smoke tests.
#   4. eco-static    — FROM scratch; ships just the binary.
#   5. eco-bundle    — FROM scratch; ships the .tar.gz/.zip/.deb bundles.
#   6. glibc-smoke   — FROM debian:bookworm-slim; builds and runs `.node` and
#                      `.so` outputs from the packaged bundle under stock
#                      glibc Node 22 / gcc, plus the ELF contract assertions.
#                      LAST stage on purpose: a plain `docker build` (no
#                      --target) runs every smoke gate.
#
# PREREQUISITE IMAGE — one, as before Stage D (eco-llvm-debian remains
# dev-environment-only). One-off, slow; rebuild only when LLVM_VERSION
# changes:
#   docker build -f docker/llvm-alpine.Dockerfile -t eco-llvm-alpine:21.1.4 .
# Build + run all smoke gates (fast — pulls /opt/llvm-mlir from the images):
#   docker build -f docker/static-build.Dockerfile .
# Extract the bundles (cached if the smoke build above already ran):
#   docker build -f docker/static-build.Dockerfile --target eco-bundle -o ./dist .
# Extract just the binary:
#   docker build -f docker/static-build.Dockerfile --target eco-static -t eco-static .
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

# Base image for the Stage D glibc-runtime stage (used at the FROM below).
# Declared HERE, in the global scope before the first FROM, because Docker
# only resolves ARGs in a FROM line when they are declared ahead of the
# first FROM — an ARG declared between stages is "undeclared" for FROM
# purposes and expands to empty ("base name should not be blank"). Same
# reason ALPINE_DIGEST lives up here though it's first used much later.
# debian:bookworm; bump deliberately, in lockstep with eco-dev if desired.
ARG DEBIAN_IMAGE=debian:bookworm

FROM ${LLVM_IMAGE} AS llvm

# ============================================================================
# Stage 2: compile the glibc-ABI link-input set (Stage D, step 2 of
# plans/stage-d-hybrid-link-profiles.md).
#
# SELF-CONTAINED: plain debian:bookworm + apt. No LLVM/MLIR source image —
# the archive-only configure (ECO_GLIBC_OUTPUT_RUNTIME) gates off
# find_package(MLIR) and every MLIR target, and the LLVM runtime statics
# (libc++/libc++abi/libunwind/compiler-rt builtins) come from apt packages,
# mirroring exactly how the musl side takes them from Alpine apk
# (`libc++-static compiler-rt`). The archives this stage compiles are built
# with apt clang either way; nothing from an LLVM source build ever shipped.
#
# Version notes:
#   - bookworm's LLVM is 14: libc++-14 statics differ from the musl side's
#     LLVM-21 libc++ — harmless, the two profiles never cross-link and the
#     archives are self-contained inside produced .so/.node files.
#   - libunwind-14-dev is the LLVM unwinder; plain `libunwind-dev` is the
#     nongnu implementation and must NOT be used (cmake/LLVMLibunwind.cmake
#     hard-rejects it via the __libunwind_config.h marker).
#   - PIC-ness of the distro archives is NOT assumed: the staging target's
#     trial-link audit (cmake/GlibcRuntimeAudit.cmake) gates every archive.
# ============================================================================
# DEBIAN_IMAGE is declared in the global scope near the top (next to
# LLVM_IMAGE) — Docker requires FROM-arg declarations ahead of the first
# FROM. Override with --build-arg DEBIAN_IMAGE=... (e.g. a digest pin).
FROM ${DEBIAN_IMAGE} AS glibc-runtime
ARG DEBIAN_FRONTEND=noninteractive

# Toolchain + link-input sources:
#   - build-essential/clang/lld: compilers + ld.lld for the PIC audit; the
#     glibc/gcc CRT objects (crti.o/crtbeginS.o/...) are discovered from
#     this gcc install at configure time.
#   - libssl-dev: eco-kernel-cpp does find_package(OpenSSL REQUIRED) under
#     the vendored-statics path (Debian's OpenSSL 3 statics are PIC).
#   - zlib1g-dev: headers for the vendored curl/libzip builds (the libz.a
#     archive itself is vendored by CMake — Debian's is NOT PIC).
#   - libc++-14-dev libc++abi-14-dev libclang-rt-14-dev libunwind-14-dev:
#     the LLVM runtime statics the .so/.node links embed.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git build-essential python3 pkg-config \
      cmake ninja-build clang lld \
      libssl-dev zlib1g-dev \
      libc++-14-dev libc++abi-14-dev libclang-rt-14-dev libunwind-14-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /eco
COPY . .

# Archive-only configure: ECO_GLIBC_OUTPUT_RUNTIME=ON gates off compiler/,
# test/, rapidcheck AND the whole MLIR half of runtime/src/codegen (this
# image has no node/pnpm/rapidcheck/MLIR and must not need them);
# ECO_STATIC=ON is required because the vendored libcurl_static/zip targets
# only exist under it. LLVM_INSTALL_PREFIX points the libunwind + runtime-
# statics discovery at the apt layout. The eco-glibc-runtime-tree target
# compiles the link-relevant project archives (runtime, embed entry, node
# glue, 22 ElmKernel_* + 9 EcoKernel_*) plus the vendored curl/zip/zlib
# statics, harvests the configure-discovered glibc/gcc CRT objects and apt
# LLVM runtime statics, PIC-audits every staged archive, computes the glibc
# floor, and stages the result at ECO_GLIBC_RUNTIME_TREE_OUT (consumed by
# the eco-builder stage below via COPY --from).
RUN cmake --preset build -B build-glibc-runtime \
      -DECO_STATIC=ON \
      -DECO_GLIBC_OUTPUT_RUNTIME=ON \
      -DLLVM_INSTALL_PREFIX=/usr/lib/llvm-14 \
      -DECO_GLIBC_RUNTIME_TREE_OUT=/out/glibc-runtime-tree
RUN cmake --build build-glibc-runtime --target eco-glibc-runtime-tree \
 && ls -l /out/glibc-runtime-tree

# ============================================================================
# Stage 3: build the static eco against the MUSL LLVM
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
# REQUIRED) for the `ecor` allocator-test binary, and `cmake --build … --target
# package` builds `all` (including `test`, which links librapidcheck.a). Build
# rapidcheck with -stdlib=libc++ so its objects share the libc++ ABI used by
# the rest of the Stage B link — Alpine's clang otherwise picks up libstdc++
# headers via the gcc install from `build-base`, producing GCC-only ABI symbols
# (std::__cxx11::basic_string<...>, std::_Rb_tree_*, std::__exception_ptr::*)
# that don't resolve against libc++. This stage is throwaway, so the larger
# rapidcheck.a doesn't bloat the final scratch artifact.
RUN git clone --depth=1 https://github.com/emil-e/rapidcheck.git /tmp/rapidcheck \
 && cmake -S /tmp/rapidcheck -B /tmp/rapidcheck/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_CXX_FLAGS=-stdlib=libc++ \
 && cmake --build /tmp/rapidcheck/build \
 && cmake --install /tmp/rapidcheck/build \
 && rm -rf /tmp/rapidcheck

COPY --from=llvm /opt/llvm-mlir /opt/llvm-mlir

# Stage D: the glibc link-input tree built by the glibc-runtime stage above.
# The release configure below points ECO_GLIBC_RUNTIME_TREE at it; the
# Bundle install rules merge it into the package as lib/eco-runtime/glibc/
# so the installed eco can link `.so`/`.node` outputs
# (plans/stage-d-hybrid-link-profiles.md, step 3).
COPY --from=glibc-runtime /out/glibc-runtime-tree /opt/eco-glibc-runtime

ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir
ENV PATH=/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The Elm/Guida bootstrap is memory-hungry; match the main dev image.
ENV NODE_OPTIONS=--max-old-space-size=12000

WORKDIR /eco
COPY . .

# Optional release version. When set (e.g. --build-arg ECO_VERSION=1.2.3) it
# stamps BOTH the bundle archive names and `eco --version` via the CMake
# ECO_VERSION_OVERRIDE knob. When empty, the build falls back to the baseline
# in version.txt (currently 0.1.0) — .git is excluded from the context, so the
# usual -dev-<git-describe> suffix cannot apply here.
ARG ECO_VERSION=

# Configure + build only the eco binary. The musl preset sets ECO_STATIC,
# ECO_STATIC_MUSL, ECO_LINK_WITH_BFD=OFF and the -static libc++ link flags.
# binaryDir is `build-static/` (see CMakePresets.json) so the in-container
# musl build doesn't collide with a host glibc `build/` in the bind mount.
# ECO_GLIBC_RUNTIME_TREE (Stage D) points the Bundle install rules at the
# glibc link-input tree copied from the glibc-runtime stage; without it the
# bundle still builds, but `.so`/`.node` outputs fail with the capability
# error (asserted by the Alpine smoke below).
RUN if [ -n "$ECO_VERSION" ]; then \
        cmake --preset release \
              -DECO_GLIBC_RUNTIME_TREE=/opt/eco-glibc-runtime \
              -DECO_VERSION_OVERRIDE="$ECO_VERSION"; \
    else \
        cmake --preset release \
              -DECO_GLIBC_RUNTIME_TREE=/opt/eco-glibc-runtime; \
    fi
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
 && ls -lh build-static/eco-*-x86_64-linux-musl.tar.gz \
           build-static/eco-*-x86_64-linux-musl.zip \
           build-static/eco_*_amd64.deb

# Smoke test the bundle in-container: extract into /tmp/eco-smoke, scaffold a
# minimal project (elm.json + src/Hello.elm — eco refuses to build without
# elm.json), build Hello.elm against the extracted tree, then verify the
# produced binary is fully static and runs to completion.
#
# Hello.elm is `text "Hello!"` (browser-style Html); on a headless runtime
# it exits non-zero, so the smoke test does not check ./hello's exit code —
# only that it runs without crashing and yields a fully-static ELF.
RUN mkdir -p /tmp/eco-smoke \
 && tar -xzf build-static/eco-*-x86_64-linux-musl.tar.gz -C /tmp/eco-smoke \
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

# Stage D negative check (plans/stage-d-hybrid-link-profiles.md, step 7.4):
# the extracted bundle must carry the glibc link-input tree, and with it
# deleted a `.node` link attempt must fail with the capability error from
# the driver (EcoNativeDriver.cpp's hasGlibcOutputProfile() gate), not a raw
# link failure. The POSITIVE `.node`/`.so` checks live in the glibc-smoke
# stage at the end of this file — Alpine's node is musl and must never load
# a glibc-ABI addon.
RUN cd /tmp/eco-smoke \
 && if [ ! -d lib/eco-runtime/glibc ]; then \
        echo "FATAL: bundle lacks lib/eco-runtime/glibc/ — the Stage D" >&2; \
        echo "       install(DIRECTORY …) Bundle rule did not fire" >&2; \
        exit 1; \
    fi \
 && rm -rf lib/eco-runtime/glibc \
 && mkdir -p build \
 && if ./bin/eco make src/Hello.elm --output=build/elm.node > /tmp/node-fail.log 2>&1; then \
        echo "FATAL: .node build succeeded without lib/eco-runtime/glibc/" >&2; \
        exit 1; \
    fi \
 && if ! grep -q "lacks the glibc output profile" /tmp/node-fail.log; then \
        echo "FATAL: .node failure does not name the missing glibc output profile:" >&2; \
        cat /tmp/node-fail.log >&2; \
        exit 1; \
    fi \
 && echo "OK: .node correctly refused without the glibc output profile"

# ============================================================================
# Stage 4: ship just the binary (back-compat, slim image)
# ============================================================================
FROM scratch AS eco-static
COPY --from=eco-builder /eco/build-static/compiler/build-kernel/bin/eco /eco
ENTRYPOINT ["/eco"]

# ============================================================================
# Stage 5: ship the distribution bundles (.tar.gz + .zip + .deb).
# `docker build --target eco-bundle -o ./dist .` drops all three archives in
# ./dist. Wildcards keep this stage version-agnostic: the actual names are
# derived from version.txt / --build-arg ECO_VERSION by CPack (see the
# top-level CMakeLists.txt), so they carry whatever version was built.
# ============================================================================
FROM scratch AS eco-bundle
COPY --from=eco-builder /eco/build-static/eco-*-x86_64-linux-musl.tar.gz /
COPY --from=eco-builder /eco/build-static/eco-*-x86_64-linux-musl.zip    /
COPY --from=eco-builder /eco/build-static/eco_*_amd64.deb                /

# ============================================================================
# Stage 6: glibc smoke test — Stage D step 7
# (plans/stage-d-hybrid-link-profiles.md). Exercises the packaged bundle's
# hybrid output profile on a stock glibc host: `.node` under NodeSource
# Node 22 and `.so` under host gcc, plus the ELF contract assertions.
# Deliberately the LAST stage: a plain `docker build` (no --target) gates a
# release on it, while `--target eco-bundle` still exports without
# re-running it (cached layers).
# ============================================================================
FROM debian:bookworm-slim AS glibc-smoke
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_VERSION=22

# ca-certificates -> TLS roots: the bundled eco's statically-linked
#                    curl/openssl fetch elm packages over https; the
#                    NodeSource script needs them too
# curl            -> fetches the NodeSource setup script
# gcc + libc6-dev -> host compiler for the `.so` embedding check
#                    (echo_host.c); libc6-dev is only a Recommends of gcc,
#                    so it must be spelled out under --no-install-recommends
# binutils        -> readelf for the ELF assertions
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gcc libc6-dev binutils \
 && rm -rf /var/lib/apt/lists/*

# Node 22 (glibc build) — the host process for the `.node` addon. Same
# NodeSource pattern as docker/eco-dev.Dockerfile (no corepack/pnpm here).
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# The bundle under test, installed the way a user would: extracted under
# /opt. The archive root carries bin/, lib/, share/ directly (same layout
# the Alpine smoke relies on). Assert the glibc tree shipped — it is the
# whole point of this stage.
COPY --from=eco-builder /eco/build-static/eco-*-x86_64-linux-musl.tar.gz /tmp/
RUN mkdir -p /opt/eco \
 && tar -xzf /tmp/eco-*-x86_64-linux-musl.tar.gz -C /opt/eco \
 && test -x /opt/eco/bin/eco \
 && test -d /opt/eco/lib/eco-runtime/glibc

# Port-echo project. test/embed/echo_host.c's header documents the pairing:
# it is the C host for the PortEchoTest program
# (test/elm/src/PortEchoTest.elm — init sends `echoOut 42`, the host bounces
# it back into `echoIn`, the program logs and finishes); test/elm/elm.json
# is that program's project scaffolding. echo_host.js is the node-side twin
# of echo_host.c (added with Stage D); it loads ./build/elm.js — the shim
# generated next to the .node (E2E output convention,
# plans/native-ports-and-embedding.md) — relative to itself, so it sits at
# the project root. echo_host.c #includes ../../runtime/src/embed/eco_embed.h
# relative to its own location, so the repo-relative layout is preserved
# for it.
WORKDIR /smoke
COPY test/elm/elm.json             /smoke/elm.json
COPY test/elm/src/PortEchoTest.elm /smoke/src/PortEchoTest.elm
COPY test/embed/echo_host.js       /smoke/echo_host.js
COPY test/embed/echo_host.c        /smoke/test/embed/echo_host.c
COPY runtime/src/embed/eco_embed.h /smoke/runtime/src/embed/eco_embed.h

# --- `.node`: build from the installed bundle, bounce through the shim ----
# The harness exits non-zero if the round-trip fails; the grep additionally
# pins the program-defined payload (PortEchoTest's init sends 42).
RUN mkdir -p build \
 && /opt/eco/bin/eco make src/PortEchoTest.elm --output=build/elm.node \
 && test -f build/elm.node \
 && test -f build/elm.js \
 && if ! node echo_host.js > /tmp/node-echo.log 2>&1; then \
        echo "FATAL: node echo round-trip failed:" >&2; \
        cat /tmp/node-echo.log >&2; \
        exit 1; \
    fi \
 && cat /tmp/node-echo.log \
 && grep -q "42" /tmp/node-echo.log \
 && echo "OK: .node echo round-trip under glibc node"

# --- `.node` ELF contract (plan step 7.2) ---------------------------------
# - empty NEEDED set + no RUNPATH/RPATH: libc/libm bind at load time from
#   the host process; everything else is statically linked from
#   lib/eco-runtime/glibc/
# - DT_TEXTREL present: the `-z notext` consequence (loader-applied
#   R_X86_64_64 relocs in .llvm_stackmaps) — pinned so a silent behavior
#   change is caught
# - .dynsym MUST export napi_register_module_v1 + eco_app_start (regression
#   test for the SCOPED --exclude-libs list: ALL would demote them to local
#   and the addon would not self-register)
# - .dynsym must NOT leak the statically-linked dep/runtime archives
RUN readelf -d build/elm.node > /tmp/dyn.txt \
 && cat /tmp/dyn.txt \
 && if grep -q 'NEEDED' /tmp/dyn.txt; then \
        echo "FATAL: elm.node has NEEDED entries (must be empty)" >&2; \
        exit 1; \
    fi \
 && if grep -Eq 'RUNPATH|RPATH' /tmp/dyn.txt; then \
        echo "FATAL: elm.node carries RUNPATH/RPATH" >&2; \
        exit 1; \
    fi \
 && if ! grep -q 'TEXTREL' /tmp/dyn.txt; then \
        echo "FATAL: DT_TEXTREL absent — the -z notext link contract changed" >&2; \
        exit 1; \
    fi \
 && readelf --wide --dyn-syms build/elm.node > /tmp/dynsym.txt \
 && for sym in napi_register_module_v1 eco_app_start; do \
        if ! grep -wq "$sym" /tmp/dynsym.txt; then \
            echo "FATAL: $sym missing from .dynsym (--exclude-libs scoping broke)" >&2; \
            exit 1; \
        fi; \
    done \
 && for sym in curl_easy_init zip_open __cxa_throw _Unwind_RaiseException; do \
        if grep -wq "$sym" /tmp/dynsym.txt; then \
            echo "FATAL: $sym leaked into .dynsym (hidden-runtime regression)" >&2; \
            exit 1; \
        fi; \
    done \
 && echo "OK: .node ELF contract holds"

# --- `.so`: host-gcc embedding check (plan step 7.3) -----------------------
# The .so deliberately carries UND libm symbols (ElmKernel_Basics' <cmath>
# use) and no NEEDED entry to pull libm in — the documented host contract
# is "link -lm". Assert it BOTH ways: the link MUST fail without -lm with
# an undefined-reference error, and must succeed + run the bounce with it.
# (-Wl,-rpath only matters if the .so ever grows a SONAME; with none, the
# literal build/elm.so path is recorded and resolves from /smoke.)
RUN /opt/eco/bin/eco make src/PortEchoTest.elm --output=build/elm.so \
 && test -f build/elm.so \
 && if gcc test/embed/echo_host.c build/elm.so -o /tmp/echo_host_nolm \
        > /tmp/nolm.log 2>&1; then \
        echo "FATAL: echo_host linked WITHOUT -lm — the .so host contract changed" >&2; \
        exit 1; \
    fi \
 && grep -q 'undefined reference' /tmp/nolm.log \
 && gcc test/embed/echo_host.c build/elm.so -lm \
        -Wl,-rpath,/smoke/build -o echo_host \
 && if ! ./echo_host > /tmp/c-echo.log 2>&1; then \
        echo "FATAL: .so echo host failed:" >&2; \
        cat /tmp/c-echo.log >&2; \
        exit 1; \
    fi \
 && cat /tmp/c-echo.log \
 && grep -q 'HOST echoOut: 42' /tmp/c-echo.log \
 && grep -q 'HOST done' /tmp/c-echo.log \
 && grep -q 'HOST exit: 0' /tmp/c-echo.log \
 && echo "OK: .so embedding round-trip; -lm contract verified both ways"
