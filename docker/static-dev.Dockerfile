# syntax=docker/dockerfile:1
# ============================================================================
# Stage B — INTERACTIVE dev environment for the static MUSL/libc++ eco build.
#
# Same Alpine/musl toolchain as docker/static-build.Dockerfile's `eco-builder`
# (so `cmake --preset release && cmake --build build-static
# --target eco` behaves identically here), PLUS the dev tools from the root
# Dockerfile (gdb / lldb / strace / ltrace / bpftrace / perf / ripgrep / …),
# Claude Code, and uv + serena. Meant to be run INTERACTIVELY with the repo
# bind-mounted, to step through and debug the build — notably the open musl
# bootstrap `Map.!` (see /work/musl-bug.md; `strace -e getdents64` on the
# failing node process is the quickest way to test the readdir-ordering
# hypothesis).
#
# Reuses the expensive LLVM build instead of recompiling it: COPYs
# /opt/llvm-mlir from the pre-built eco-llvm-alpine image (produced by
# docker/llvm-alpine.Dockerfile, shared with docker/static-build.Dockerfile).
#
# ---- Build (LLVM image built once, then shared) ----------------------------
#   docker build -f docker/llvm-alpine.Dockerfile \
#       -t eco-llvm-alpine:21.1.4 .             # ~30-60 min the first time
#   docker build -f docker/static-dev.Dockerfile -t eco-static-dev:local .
#
# ---- Run interactively -----------------------------------------------------
# The named volume shadows ./build-static inside the container, so the
# container's musl build tree never collides with a host glibc build/ in
# the bind mount:
#
#   docker run -it --rm \
#       -v "$PWD:/work" -v eco-musl-build:/work/build-static \
#       eco-static-dev:local
#
# Then, inside the container:
#   cmake --preset release
#   cmake --build build-static --target eco
#   claude                                  # launch Claude Code if useful
#
# (For backtrace/perf/bpftrace to work you may need `--privileged` or
#  `--cap-add=SYS_PTRACE`.)
# ============================================================================

ARG ALPINE_DIGEST=sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d
# Image holding the MUSL /opt/llvm-mlir (produced by docker/llvm-alpine.Dockerfile).
# Override with --build-arg LLVM_IMAGE=... if tagged differently.
ARG LLVM_IMAGE=eco-llvm-alpine:21.1.4

# Stage alias for the pre-built LLVM image; only /opt/llvm-mlir is copied below.
FROM ${LLVM_IMAGE} AS llvm

FROM alpine@${ALPINE_DIGEST} AS dev

# --- Build toolchain --------------------------------------------------------
# MUST stay in sync with docker/static-build.Dockerfile's `eco-builder` apk
# list so the static build behaves identically here. libcurl/libzip are
# vendored by CMake under ECO_STATIC; only the openssl/zlib statics are needed.
RUN apk add --no-cache \
      git build-base cmake samurai python3 \
      clang lld \
      musl-dev linux-headers \
      libc++ libc++-dev libc++-static compiler-rt \
      llvm-libunwind llvm-libunwind-static \
      openssl-dev openssl-libs-static \
      zlib-dev zlib-static \
      binutils \
      nodejs npm \
 && npm install -g pnpm

# --- Dev / debug tools (root Dockerfile parity, translated to apk) ----------
# `shadow` provides useradd/groupadd (used by the entrypoint to materialise a
# host-matching user); `su-exec` is the Alpine analogue of gosu, used to drop
# privileges before exec.
RUN apk add --no-cache \
      bash bash-completion sudo shadow su-exec \
      gdb lldb strace ltrace bpftrace perf \
      ripgrep fd vim tmux less jq file wget curl \
      util-linux py3-pip

# RapidCheck: find_package(rapidcheck REQUIRED) is evaluated at configure time
# (for the `ecor` test target). Same source install as the root Dockerfile /
# static-build.Dockerfile's eco-builder.
RUN git clone --depth=1 https://github.com/emil-e/rapidcheck.git /tmp/rapidcheck \
 && cmake -S /tmp/rapidcheck -B /tmp/rapidcheck/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
 && cmake --build /tmp/rapidcheck/build \
 && cmake --install /tmp/rapidcheck/build \
 && rm -rf /tmp/rapidcheck

# uv (Astral) — provides uvx, used to run serena (Claude Code's MCP server).
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Claude Code. install_claude.sh already detects musl and fetches the
# linux-x64-musl build (see its platform-detection block). Non-fatal so a
# transient download/`claude install` hiccup doesn't sink the whole image —
# it can be re-run by hand inside the container.
COPY install_claude.sh /tmp/install_claude.sh
RUN bash /tmp/install_claude.sh || echo "WARN: claude install failed; run /tmp/install_claude.sh inside the container" ; \
    rm -f /tmp/install_claude.sh

# The MUSL LLVM+MLIR install, reused from docker/llvm-alpine.Dockerfile.
COPY --from=llvm /opt/llvm-mlir /opt/llvm-mlir

# --- Non-root dev user ------------------------------------------------------
# Created at runtime by docker/static-dev-entrypoint.sh, matching the uid/gid
# that owns the bind-mounted /work (or HOST_UID/HOST_GID if set). This avoids
# the "host uid ≠ 1000 → permission friction" failure mode of a baked-in user.
# Mirrors the pattern in docker/eco-dev-entrypoint.sh.

ENV CMAKE_PREFIX_PATH=/opt/llvm-mlir \
    LD_LIBRARY_PATH=/opt/llvm-mlir/lib \
    PATH=/opt/llvm-mlir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CC=clang \
    CXX=clang++ \
    NODE_OPTIONS=--max-old-space-size=12000

COPY docker/static-dev-entrypoint.sh /usr/local/bin/static-dev-entrypoint.sh
RUN chmod +x /usr/local/bin/static-dev-entrypoint.sh

EXPOSE 24282
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/static-dev-entrypoint.sh"]
CMD ["bash"]
