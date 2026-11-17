# E-W3 from plans/build-on-windows.md: LLVM + MLIR source build, at the
# llvm-project commit deps/versions.env pins (LLVM_COMMIT), for
# x86_64-pc-windows-msvc, Release, X86 backend only, no examples/tests/docs.
# The one-off enabler — produces the install tree the rest of the Windows
# port consumes (cached at the workflow layer so subsequent jobs restore in
# seconds rather than rebuilding).
#
# Inputs (env): none required.
# Outputs:
#   - $env:LLVM_INSTALL_DIR (default: out/llvm-install)  — the install tree
#     CMake will point ECO_LLVM_DIR at downstream. It records the commit in
#     ECO_LLVM_COMMIT, which eco's CMake checks against the pin. CI builds it
#     once per commit and recipe and publishes it (the llvm-build workflow;
#     scripts/deps.sh artifact windows names it).
#   - logs in out/

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$Versions    = Join-Path $PSScriptRoot '..\..\deps\versions.env'
$LlvmCommit  = (Get-Content $Versions | Where-Object { $_ -match '^LLVM_COMMIT=' } |
                ForEach-Object { $_.Substring('LLVM_COMMIT='.Length).Trim() })
if ($LlvmCommit -notmatch '^[0-9a-f]{40}$') { throw "LLVM_COMMIT in deps/versions.env is not a 40-hex commit: '$LlvmCommit'" }
$OutDir      = Join-Path $PSScriptRoot 'out'
$SrcRoot     = Join-Path $OutDir 'llvm-project'   # short: Windows paths are tight
$BuildDir    = Join-Path $OutDir 'build'
$InstallDir  = if ($env:LLVM_INSTALL_DIR) { $env:LLVM_INSTALL_DIR } else { Join-Path $OutDir 'llvm-install' }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Source: a shallow fetch of the one commit (GitHub serves any reachable commit
# by hash); the rev-parse check makes the checkout prove it is that commit.
$Have = if (Test-Path (Join-Path $SrcRoot '.git')) { (& git -C $SrcRoot rev-parse HEAD 2>$null) } else { '' }
if ("$Have".Trim() -ne $LlvmCommit) {
    Write-Host "=== fetching llvm-project $LlvmCommit ==="
    if (Test-Path $SrcRoot) { Remove-Item -Recurse -Force $SrcRoot }
    & git init -q $SrcRoot
    # LLVM's tree has paths past MAX_PATH, and its sources build as committed (LF).
    & git -C $SrcRoot config core.longpaths true
    & git -C $SrcRoot config core.autocrlf false
    & git -C $SrcRoot remote add origin https://github.com/llvm/llvm-project.git
    & git -C $SrcRoot fetch -q --depth=1 origin $LlvmCommit
    if ($LASTEXITCODE -ne 0) { throw "git fetch of $LlvmCommit failed: $LASTEXITCODE" }
    & git -C $SrcRoot checkout -q FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "git checkout failed: $LASTEXITCODE" }
}
$Head = (& git -C $SrcRoot rev-parse HEAD).Trim()
if ($Head -ne $LlvmCommit) { throw "checkout is $Head, not $LlvmCommit" }

Write-Host "=== source at $SrcRoot ==="
Write-Host "=== build dir $BuildDir, install prefix $InstallDir ==="

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# Configure. clang-cl is preinstalled on windows-latest and builds LLVM trunk. Ninja is also preinstalled.
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

[System.IO.File]::WriteAllText((Join-Path $InstallDir 'ECO_LLVM_COMMIT'), "$LlvmCommit`n")

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
