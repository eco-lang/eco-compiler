# E-W3 from plans/build-on-windows.md: LLVM 21.1.8 + MLIR source build for
# x86_64-pc-windows-msvc, Release, X86 backend only, no examples/tests/docs.
# The one-off enabler — produces the install tree the rest of the Windows
# port consumes (cached at the workflow layer so subsequent jobs restore in
# seconds rather than rebuilding).
#
# Inputs (env): none required.
# Outputs:
#   - $env:LLVM_INSTALL_DIR (default: out/llvm-install)  — the install tree
#     CMake will point ECO_LLVM_DIR at downstream.
#   - logs in out/

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$LlvmVersion = '21.1.8'
$Tag         = "llvmorg-$LlvmVersion"
$OutDir      = Join-Path $PSScriptRoot 'out'
$SrcRoot     = Join-Path $OutDir "llvm-project-$LlvmVersion.src"
$BuildDir    = Join-Path $OutDir 'build'
$InstallDir  = if ($env:LLVM_INSTALL_DIR) { $env:LLVM_INSTALL_DIR } else { Join-Path $OutDir 'llvm-install' }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Source: prefer the bundled umbrella tarball (~150 MB compressed, 1.6 GB
# expanded) over `git clone` so the download is deterministic and small.
if (-not (Test-Path (Join-Path $SrcRoot 'llvm\CMakeLists.txt'))) {
    $tarball = Join-Path $OutDir "llvm-project-$LlvmVersion.src.tar.xz"
    if (-not (Test-Path $tarball)) {
        Write-Host "=== downloading $tarball ==="
        $url = "https://github.com/llvm/llvm-project/releases/download/$Tag/llvm-project-$LlvmVersion.src.tar.xz"
        Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing
    }
    Write-Host "=== extracting LLVM source (bsdtar handles .tar.xz) ==="
    & tar -xf $tarball -C $OutDir
    if ($LASTEXITCODE -ne 0) { throw "tar extract failed: $LASTEXITCODE" }
}

Write-Host "=== source at $SrcRoot ==="
Write-Host "=== build dir $BuildDir, install prefix $InstallDir ==="

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# Configure. clang-cl is preinstalled on windows-latest (LLVM 20.1.8) and is
# the supported host compiler for an LLVM 21 build. Ninja is also preinstalled.
# Flags follow upstream's recommended Windows minimum: Release, no
# examples/tests/docs/benchmarks, X86-only, MLIR, no PDB (saves ~1 GB of
# build artefacts). Static MSVC runtime so the install tree is binary-stable
# across host VC++ updates.
Write-Host "=== configure ==="
& cmake -G Ninja -S (Join-Path $SrcRoot 'llvm') -B $BuildDir `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_INSTALL_PREFIX="$InstallDir" `
    -DCMAKE_C_COMPILER=clang-cl `
    -DCMAKE_CXX_COMPILER=clang-cl `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded `
    -DLLVM_ENABLE_PROJECTS=mlir `
    -DLLVM_TARGETS_TO_BUILD=X86 `
    -DLLVM_INCLUDE_EXAMPLES=OFF `
    -DLLVM_INCLUDE_TESTS=OFF `
    -DLLVM_INCLUDE_DOCS=OFF `
    -DLLVM_INCLUDE_BENCHMARKS=OFF `
    -DLLVM_BUILD_EXAMPLES=OFF `
    -DLLVM_BUILD_TESTS=OFF `
    -DLLVM_BUILD_DOCS=OFF `
    -DLLVM_BUILD_BENCHMARKS=OFF `
    -DLLVM_ENABLE_ASSERTIONS=OFF `
    -DLLVM_ENABLE_PDB=OFF `
    -DLLVM_ENABLE_LIBXML2=OFF `
    -DLLVM_ENABLE_ZSTD=OFF `
    -DLLVM_ENABLE_TERMINFO=OFF `
    -DMLIR_INCLUDE_TESTS=OFF `
    -DMLIR_INCLUDE_INTEGRATION_TESTS=OFF
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed: $LASTEXITCODE" }

Write-Host "=== build + install ==="
$startTime = Get-Date
& cmake --build $BuildDir --target install
if ($LASTEXITCODE -ne 0) { throw "cmake build failed: $LASTEXITCODE" }
$elapsed = (Get-Date) - $startTime
Write-Host "=== build+install elapsed: $($elapsed.TotalMinutes) min ==="

Write-Host "=== install tree size ==="
$sz = (Get-ChildItem $InstallDir -Recurse -ErrorAction SilentlyContinue |
       Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host "install size: $([math]::Round($sz, 1)) MB"

Write-Host "=== sanity: llc + opt + mlir-opt versions ==="
foreach ($t in @('llc.exe','opt.exe','mlir-opt.exe','lld-link.exe','clang-cl.exe')) {
    $p = Join-Path $InstallDir "bin\$t"
    if (Test-Path $p) {
        $v = (& $p --version 2>&1 | Select-Object -First 1)
        Write-Host "  ok: $t -> $v"
    } else {
        Write-Host "  MISSING: $t" -ForegroundColor Yellow
    }
}

Write-Host "=== E-W3 COMPLETE ==="
