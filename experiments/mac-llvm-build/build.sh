#!/usr/bin/env bash
# mac-llvm-build (plans/mac-self-contained-bundle.md step 2): LLVM 21.1.8 + MLIR
# source build for arm64 macOS, Release, AArch64 backend only, static
# libraries only, minimum macOS 15.0. eco links these archives statically, so
# the installed eco loads nothing from Homebrew (brew's llvm@21 is built to use
# its shared libLLVM.dylib, which the Darwin bundle cannot rely on).
#
# Same LLVM pin and shape as experiments/win-llvm-build/build.ps1 (Windows) and
# docker/llvm-alpine.Dockerfile (Linux). RTTI is on and assertions off, as in
# the brew llvm@21 build eco used before, so eco's own compile flags are
# unchanged.
#
# Runnable on a developer Mac too (roughly an hour on an M-series machine).
# Needs Xcode or the Command Line Tools, cmake and ninja; ccache is used when
# present.
#
# Inputs (env, all optional):
#   LLVM_INSTALL_DIR  install prefix (default: out/llvm-install); point the
#                     mac-build preset's ECO_MAC_DEPS_DIR at it.
#   ECO_MACOS_MIN     minimum macOS version (default 15.0; keep in step with
#                     CMAKE_OSX_DEPLOYMENT_TARGET in the top-level CMakeLists).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
llvm_version=21.1.8
macos_min="${ECO_MACOS_MIN:-15.0}"
out_dir="$here/out"
src_root="$out_dir/llvm-project-$llvm_version.src"
build_dir="$out_dir/build"
install_dir="${LLVM_INSTALL_DIR:-$out_dir/llvm-install}"

mkdir -p "$out_dir"

# Source: the release umbrella tarball, as build.ps1 does — deterministic and
# much smaller than a git clone.
if [ ! -f "$src_root/llvm/CMakeLists.txt" ]; then
    tarball="$out_dir/llvm-project-$llvm_version.src.tar.xz"
    if [ ! -f "$tarball" ]; then
        echo "=== downloading $tarball ==="
        curl -fL --retry 3 -o "$tarball" \
            "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvm_version/llvm-project-$llvm_version.src.tar.xz"
    fi
    echo "=== extracting LLVM source ==="
    tar -xf "$tarball" -C "$out_dir"
fi

launcher=()
if command -v ccache >/dev/null 2>&1; then
    launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

# LLVM_PARALLEL_LINK_JOBS=2: the macos-15 runner has 3 vCPUs and 7 GB; static
# Release links without debug info are small, but MLIR tools link a lot.
# Optional host libraries are all off so the archives reference nothing
# beyond what macOS itself provides.
echo "=== configure (macOS $macos_min, arm64) ==="
cmake -G Ninja -S "$src_root/llvm" -B "$build_dir" \
    "${launcher[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$macos_min" \
    -DLLVM_ENABLE_PROJECTS=mlir \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_Z3_SOLVER=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_BUILD_EXAMPLES=OFF \
    -DLLVM_BUILD_TESTS=OFF \
    -DLLVM_BUILD_DOCS=OFF \
    -DLLVM_BUILD_BENCHMARKS=OFF \
    -DMLIR_INCLUDE_TESTS=OFF \
    -DMLIR_INCLUDE_INTEGRATION_TESTS=OFF \
    -DLLVM_PARALLEL_LINK_JOBS=2

echo "=== build + install ==="
start=$(date +%s)
cmake --build "$build_dir" --target install
echo "=== build+install elapsed: $(( ($(date +%s) - start) / 60 )) min ==="

echo "=== install tree size ==="
du -sh "$install_dir"

# Hard checks: the tools link nothing outside macOS, and nothing in the tree
# needs a newer macOS than the floor.
echo "=== check: no non-system dylibs ==="
otool -L "$install_dir/bin/mlir-opt" | tee /dev/stderr | tail -n +2 \
    | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)' && {
        echo "FATAL: mlir-opt links a library outside /usr/lib and /System/Library" >&2
        exit 1
    }
echo "=== check: minimum macOS $macos_min ==="
"$here/../../test/scripts/check-macho-floor.sh" "$macos_min" \
    "$install_dir/bin/mlir-opt" \
    "$install_dir/lib/libLLVMSupport.a" \
    "$install_dir/lib/libLLVMCore.a" \
    "$install_dir/lib/libMLIRIR.a"

echo "=== sanity: versions ==="
"$install_dir/bin/llc" --version | head -4
"$install_dir/bin/mlir-opt" --version | head -2
echo "=== mac-llvm-build COMPLETE ==="
