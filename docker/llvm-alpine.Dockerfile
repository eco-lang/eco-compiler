# syntax=docker/dockerfile:1
# ============================================================================
# Builder image for LLVM + MLIR (Alpine / MUSL + libc++ variant).
# ============================================================================
# Built once, then consumed by:
#   - docker/static-build.Dockerfile (the static eco binary)
#   - docker/static-dev.Dockerfile   (interactive dev image for Stage B)
# Both COPY /opt/llvm-mlir from this image. Bump the tag in lockstep with
# LLVM_VERSION.
#
# Build with:
#   docker build -f docker/llvm-alpine.Dockerfile -t eco-llvm-alpine:21.1.4 .
#
# Toolchain facts (verified against alpine:3.21 / clang 19.1.4):
#   - libc++ is packaged as libc++ / libc++-dev / libc++-static (NOT the
#     `libcxx-*` names an earlier draft of the plan assumed). libc++abi is
#     bundled inside those packages — there is no separate libc++abi package.
#   - compiler-rt and llvm-libunwind-static are available, so the LLVM link
#     uses the clean `-rtlib=compiler-rt -unwindlib=libunwind` path and does
#     NOT need the Stage-A `--allow-multiple-definition` workaround.
#   - The verified static link recipe is:
#       clang++ -static -stdlib=libc++ -rtlib=compiler-rt \
#               -unwindlib=libunwind -lc++abi -fuse-ld=lld
#     It needs `-lc++abi` explicitly; omitting it leaves libc++ vtables
#     undefined.
# ============================================================================

# alpine:3.21 pinned by digest for reproducibility (risk register: "pin the
# base image SHA, not just alpine:edge"). Captured 2026-05-25. Kept in lockstep
# with docker/static-build.Dockerfile / docker/static-dev.Dockerfile.
ARG ALPINE_DIGEST=sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

FROM alpine@${ALPINE_DIGEST}
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

# Mirrors the main (debian) LLVM configuration, with the MUSL deltas:
#   - compile with -stdlib=libc++ (+ -lc++abi so the LLVM tools link),
#   - default target triple x86_64-alpine-linux-musl,
#   - X86 backend only (Stage B is x86_64-only — plan scope).
# LLVM_ENABLE_RUNTIMES stays "libunwind" (same as the debian variant) so that
# libunwind.a installs under /opt/llvm-mlir where cmake/LLVMLibunwind.cmake
# looks for it. libc++/libc++abi come from Alpine's packages, used
# consistently for both this build and the downstream eco build (so there is
# no libc++ ABI skew).
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
      -DCMAKE_C_FLAGS="-march=x86-64-v3 -mtune=generic" \
      -DCMAKE_CXX_FLAGS="-stdlib=libc++ -march=x86-64-v3 -mtune=generic" \
      -DCMAKE_EXE_LINKER_FLAGS="-static -stdlib=libc++ -rtlib=compiler-rt -unwindlib=libunwind -lc++abi -fuse-ld=lld" \
      -DCMAKE_INSTALL_PREFIX=/opt/llvm-mlir \
 && cmake --build build \
 && cmake --install build \
 && mkdir -p /opt/llvm-mlir/libexec/eco-bundle \
 && cp -L /opt/llvm-mlir/bin/ld.lld /opt/llvm-mlir/libexec/eco-bundle/ld.lld \
 && if readelf -d /opt/llvm-mlir/libexec/eco-bundle/ld.lld 2>/dev/null | grep -q NEEDED \
       || readelf -l /opt/llvm-mlir/libexec/eco-bundle/ld.lld 2>/dev/null | grep -q 'program interpreter'; then \
        echo "FATAL: bundled ld.lld is not fully static (NEEDED or interpreter present):" >&2; \
        readelf -dl /opt/llvm-mlir/libexec/eco-bundle/ld.lld >&2; \
        exit 1; \
    fi \
 && echo "OK: /opt/llvm-mlir/libexec/eco-bundle/ld.lld is fully static (no NEEDED, no interpreter)" \
 && rm -f /opt/llvm-mlir/bin/ld.lld \
 && echo "Bundled the resolved static lld and dropped the bin/ld.lld symlink so a downstream" \
 && echo "clang -fuse-ld=lld picks the zlib-capable system /usr/bin/ld.lld for the eco link."
