#!/bin/sh
# ============================================================
# GenMC, the stateless model checker for the C11 / RC11 memory model, for the
# weak-memory companions W1-W5 of the threaded-GC TLA+ work
# (plans/threaded-gc-tla-W-weak-memory.md §4.2, test/genmc/).
#
# One script, three modes, so the image and a hand-run install are the same:
#
#   install-genmc.sh build    install the build dependencies, build a private
#                             GCC 14 (temporary), build GenMC with it, install
#                             GenMC into $GENMC_PREFIX (default /opt/genmc),
#                             then run the smoke test. Used by
#                             docker/genmc.Dockerfile, and by hand in a running
#                             dev container (with sudo).
#   install-genmc.sh runtime  install only what an existing $GENMC_PREFIX needs
#                             at run time (clang-19 compiles the input to LLVM
#                             IR; libllvm19), link /usr/local/bin/genmc, and run
#                             the smoke test. Used by docker/eco-dev-genmc.Dockerfile
#                             after it copies /opt/genmc out of the GenMC image.
#   install-genmc.sh smoke    the smoke test only.
#
# Why these pins:
#   - GenMC v0.19.0 is the first release with the FAILURE memory order of a
#     CAS modelled (0.18.0) and with mixed-size access detection fixed; W4b and
#     W5 each have a mutant that weakens only a CAS failure order. Pinned by
#     its git commit (a content hash), fetched from the upstream repository.
#   - LLVM 19 is the oldest LLVM GenMC 0.19 supports, and the newest one in
#     Debian bookworm's own archive (llvm-toolchain-19, a security backport).
#     Pinned by exact Debian version. Our own LLVM 21 (/opt/llvm-mlir) is not
#     touched: GenMC needs a clang binary of its LLVM version, and
#     /opt/llvm-mlir has none. When Debian replaces this version in a point
#     release the pin fails the build: re-pin deliberately and re-run
#     `cmake --build build --target genmc-check`.
#   - GCC 14 because GenMC is C++23 (<format>, <print>), and bookworm's
#     libstdc++ is 12. Built from the GNU release tarball (SHA256-pinned; the
#     signature was checked with gpgv against gnu-keyring.gpg on 2026-09-28)
#     into a temporary prefix, used only to compile GenMC, then deleted. Its
#     libstdc++.so.6 (a superset of bookworm's) ships in $GENMC_PREFIX/lib and
#     genmc carries a DT_RPATH to it, so the process loads ONE libstdc++, which
#     libLLVM-19 also uses.
#
# Environment: GENMC_PREFIX (default /opt/genmc), GENMC_JOBS (default: nproc),
# GENMC_WORKDIR (default /tmp/genmc-build, deleted afterwards). Run as root
# (the image) or with passwordless sudo (a dev container).
# ============================================================
set -eu

GENMC_VERSION=0.19.0
GENMC_COMMIT=9f6c4c0772d0c42b325681581acc6a0f3eb9b5f7
GENMC_REPO=https://github.com/MPI-SWS/genmc.git
LLVM_MAJOR=19
LLVM_DEB_VERSION=1:19.1.7-3~deb12u1
GCC_VERSION=14.4.0
GCC_SHA256=752b6f567beac83159c77a7680b1316bdd784738bff9a9d070112c09da90f6d9

PREFIX=${GENMC_PREFIX:-/opt/genmc}
JOBS=${GENMC_JOBS:-$(nproc)}
WORK=${GENMC_WORKDIR:-/tmp/genmc-build}
MODE=${1:-build}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

log() { printf '[install-genmc] %s\n' "$*"; }
die() { printf '[install-genmc] ERROR: %s\n' "$*" >&2; exit 1; }

apt_install() {
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# What genmc needs at run time: clang-19 (with its resource headers) turns the
# input into LLVM IR; genmc itself links libLLVM-19 and libffi.
runtime_packages() {
    echo "clang-${LLVM_MAJOR}=${LLVM_DEB_VERSION}" \
         "libclang-common-${LLVM_MAJOR}-dev=${LLVM_DEB_VERSION}" \
         "libclang-cpp${LLVM_MAJOR}=${LLVM_DEB_VERSION}" \
         "libllvm${LLVM_MAJOR}=${LLVM_DEB_VERSION}" \
         libffi8 libedit2 libc6-dev libstdc++-12-dev
}

build_gcc() {
    GCC_PREFIX="$WORK/gcc"
    log "building GCC ${GCC_VERSION} into ${GCC_PREFIX} (temporary)"
    mkdir -p "$WORK"
    curl -fsSL -o "$WORK/gcc.tar.xz" \
        "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
    echo "${GCC_SHA256}  $WORK/gcc.tar.xz" | sha256sum -c -
    tar -xJf "$WORK/gcc.tar.xz" -C "$WORK"
    rm "$WORK/gcc.tar.xz"
    mkdir -p "$WORK/gcc-obj"
    # The system GCC 12 builds it, never ccache or the dev image's CC=clang.
    ( cd "$WORK/gcc-obj" && \
      env CC=/usr/bin/gcc CXX=/usr/bin/g++ CCACHE_DISABLE=1 \
      "$WORK/gcc-${GCC_VERSION}/configure" --prefix="$GCC_PREFIX" \
          --disable-bootstrap --enable-languages=c,c++ --disable-multilib \
          --disable-nls --disable-libsanitizer --disable-libgomp \
          --disable-libquadmath --disable-libitm --disable-libvtv --disable-libssp \
          --disable-lto --with-system-zlib > "$WORK/gcc-configure.log" 2>&1 \
      || { tail -40 "$WORK/gcc-configure.log" >&2; exit 1; } )
    env CCACHE_DISABLE=1 make -C "$WORK/gcc-obj" -j"$JOBS" > "$WORK/gcc-build.log" 2>&1 \
        || { tail -60 "$WORK/gcc-build.log" >&2; die "GCC build failed"; }
    make -C "$WORK/gcc-obj" install > "$WORK/gcc-install.log" 2>&1 \
        || { tail -40 "$WORK/gcc-install.log" >&2; die "GCC install failed"; }
    rm -rf "$WORK/gcc-obj" "$WORK/gcc-${GCC_VERSION}"
}

build_genmc() {
    log "fetching GenMC ${GENMC_VERSION} (${GENMC_COMMIT})"
    rm -rf "$WORK/genmc-src" "$WORK/genmc-obj"
    git init -q "$WORK/genmc-src"
    git -C "$WORK/genmc-src" fetch -q --depth=1 "$GENMC_REPO" "$GENMC_COMMIT"
    git -C "$WORK/genmc-src" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [ "$(git -C "$WORK/genmc-src" rev-parse HEAD)" = "$GENMC_COMMIT" ] \
        || die "GenMC checkout is not ${GENMC_COMMIT}"
    log "building GenMC with ${GCC_PREFIX}/bin/g++ against LLVM ${LLVM_MAJOR}"
    # CMAKE_PREFIX_PATH (the dev image points it at /opt/llvm-mlir) must not
    # steer find_package(LLVM) away from LLVM ${LLVM_MAJOR}.
    env -u CMAKE_PREFIX_PATH -u CC -u CXX \
    cmake -S "$WORK/genmc-src" -B "$WORK/genmc-obj" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="/usr/lib/llvm-${LLVM_MAJOR}" \
        -DCMAKE_C_COMPILER="$GCC_PREFIX/bin/gcc" \
        -DCMAKE_CXX_COMPILER="$GCC_PREFIX/bin/g++" \
        -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--disable-new-dtags" \
        -DGENMC_TCMALLOC=OFF -DBUILD_TESTS=OFF -DBUILD_DOC=OFF \
        > "$WORK/genmc-configure.log" 2>&1 \
        || { tail -40 "$WORK/genmc-configure.log" >&2; die "GenMC configure failed"; }
    cmake --build "$WORK/genmc-obj" -j "$JOBS" > "$WORK/genmc-build.log" 2>&1 \
        || { tail -60 "$WORK/genmc-build.log" >&2; die "GenMC build failed"; }
    $SUDO rm -rf "$PREFIX"
    $SUDO cmake --install "$WORK/genmc-obj" > "$WORK/genmc-install.log" 2>&1 \
        || { tail -40 "$WORK/genmc-install.log" >&2; die "GenMC install failed"; }
    # GCC 14's C++ runtime, found through genmc's DT_RPATH (see the header).
    $SUDO mkdir -p "$PREFIX/lib"
    for f in "$GCC_PREFIX"/lib64/libstdc++.so.6.* "$GCC_PREFIX"/lib64/libgcc_s.so.1; do
        case "$f" in *.py) continue ;; esac
        $SUDO cp -P "$f" "$PREFIX/lib/"
    done
    ( cd "$PREFIX/lib" && $SUDO ln -sf "$(ls libstdc++.so.6.0.* | grep -v '\.py$' | head -1)" libstdc++.so.6 )
    $SUDO strip --strip-unneeded "$PREFIX"/lib/libstdc++.so.6.0.* "$PREFIX/lib/libgcc_s.so.1"
    printf 'GenMC %s\ncommit %s\nLLVM %s (Debian %s)\nbuilt with GCC %s\n' \
        "$GENMC_VERSION" "$GENMC_COMMIT" "$LLVM_MAJOR" "$LLVM_DEB_VERSION" "$GCC_VERSION" \
        | $SUDO tee "$PREFIX/VERSION" > /dev/null
}

link_bin() {
    $SUDO ln -sf "$PREFIX/bin/genmc" /usr/local/bin/genmc
}

# The smoke test. A checker that passes everything proves nothing, so:
#   - C message passing (GenMC compiles it itself) must pass, and its
#     relaxed-flag mutant must be flagged;
#   - the route test/genmc uses (a C++20 program compiled by clang-19 with the
#     ORDINARY glibc/libstdc++ headers to LLVM IR, threads and asserts routed to
#     GenMC's __VERIFIER_* functions, the .ll handed to genmc; see
#     test/genmc/wdriver.hpp) must pass with std::atomic_ref, and its plain
#     mutant must be reported as a race. (GenMC's own C++ compile step puts its C
#     <pthread.h> first on the include path, which libstdc++'s C++20 <atomic>
#     cannot use.)
smoke() {
    [ -x "$PREFIX/bin/genmc" ] || die "$PREFIX/bin/genmc is missing"
    if ldd "$PREFIX/bin/genmc" | grep -q 'not found'; then
        ldd "$PREFIX/bin/genmc" >&2; die "genmc has unresolved libraries"
    fi
    ldd "$PREFIX/bin/genmc" | grep -q "$PREFIX/lib/libstdc++.so.6" \
        || die "genmc does not load $PREFIX/lib/libstdc++.so.6"
    CLANGXX="/usr/lib/llvm-${LLVM_MAJOR}/bin/clang++"
    [ -x "$CLANGXX" ] || die "$CLANGXX is missing"
    d=$(mktemp -d)
    cat > "$d/mp.c" <<'EOF'
#include <pthread.h>
#include <stdatomic.h>
#include <assert.h>
int data;
atomic_int flag;
void *w(void *a) { data = 42; atomic_store_explicit(&flag, 1, FLAG_ORDER); return 0; }
void *r(void *a) {
    if (atomic_load_explicit(&flag, memory_order_acquire)) assert(data == 42);
    return 0;
}
int main() { pthread_t a, b; pthread_create(&a, 0, w, 0); pthread_create(&b, 0, r, 0);
             pthread_join(a, 0); pthread_join(b, 0); return 0; }
EOF
    cat > "$d/ref.cpp" <<'EOF'
#include <atomic>
#include <cassert>
#include <cstdint>
#include <genmc_internal.h>
extern "C" void __assert_fail(const char* e, const char* f, unsigned l, const char*) noexcept {
    __VERIFIER_assert_fail(e, f, static_cast<int>(l));
    __builtin_unreachable();
}
static uint8_t byte;
static void* m(void*) { std::atomic_ref<uint8_t>(byte).fetch_or(1, std::memory_order_relaxed); return nullptr; }
static void* n(void*) {
#ifdef PLAIN
    byte = static_cast<uint8_t>(byte | 2);
#else
    std::atomic_ref<uint8_t>(byte).fetch_or(2, std::memory_order_relaxed);
#endif
    return nullptr;
}
int main() {
    auto a = __VERIFIER_thread_create(nullptr, m, nullptr);
    auto b = __VERIFIER_thread_create(nullptr, n, nullptr);
    __VERIFIER_thread_join(a);
    __VERIFIER_thread_join(b);
#ifndef PLAIN
    assert(std::atomic_ref<uint8_t>(byte).load(std::memory_order_relaxed) == 3);
#endif
    return 0;
}
EOF
    "$PREFIX/bin/genmc" -disable-estimation -- -DFLAG_ORDER=memory_order_release "$d/mp.c" > "$d/pass.log" 2>&1 \
        || { cat "$d/pass.log" >&2; die "smoke: message passing (release) must pass"; }
    grep -q 'No errors were detected' "$d/pass.log" || { cat "$d/pass.log" >&2; die "smoke: no verdict"; }
    if "$PREFIX/bin/genmc" -disable-estimation -- -DFLAG_ORDER=memory_order_relaxed "$d/mp.c" > "$d/fail.log" 2>&1; then
        cat "$d/fail.log" >&2; die "smoke: the relaxed mutant must be flagged"
    fi
    grep -qE 'Non-atomic race|Safety violation' "$d/fail.log" \
        || { cat "$d/fail.log" >&2; die "smoke: the mutant failed for another reason"; }
    for v in atomic plain; do
        flag=""; [ "$v" = plain ] && flag="-DPLAIN"
        "$CLANGXX" -std=c++20 -fno-exceptions -g -fno-discard-value-names \
            -Xclang -disable-O0-optnone $flag -idirafter "$PREFIX/include/genmc/runtime" \
            -S -emit-llvm -o "$d/ref-$v.ll" "$d/ref.cpp" \
            || die "smoke: $CLANGXX cannot compile the C++20 program"
        "$PREFIX/bin/genmc" -disable-estimation "$d/ref-$v.ll" > "$d/ref-$v.log" 2>&1 || true
    done
    grep -q 'No errors were detected' "$d/ref-atomic.log" \
        || { cat "$d/ref-atomic.log" >&2; die "smoke: the C++20 atomic_ref program must pass"; }
    grep -q 'Non-atomic race' "$d/ref-plain.log" \
        || { cat "$d/ref-plain.log" >&2; die "smoke: its plain mutant must be reported as a race"; }
    rm -rf "$d"
    log "smoke test passed: $("$PREFIX/bin/genmc" --version 2>&1 | grep -m1 'GenMC v')"
}

case "$MODE" in
build)
    apt_install ca-certificates curl xz-utils git build-essential cmake ninja-build \
        libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev libzstd-dev libffi-dev libedit-dev \
        "llvm-${LLVM_MAJOR}-dev=${LLVM_DEB_VERSION}" "llvm-${LLVM_MAJOR}=${LLVM_DEB_VERSION}" \
        "llvm-${LLVM_MAJOR}-tools=${LLVM_DEB_VERSION}" \
        $(runtime_packages)
    rm -rf "$WORK"
    build_gcc
    build_genmc
    rm -rf "$WORK"
    link_bin
    smoke
    ;;
runtime)
    apt_install $(runtime_packages)
    link_bin
    smoke
    ;;
smoke)
    smoke
    ;;
*)
    die "usage: install-genmc.sh build|runtime|smoke"
    ;;
esac
