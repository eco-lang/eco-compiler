# E-W2 driver: compile harness.cpp with the preinstalled clang-cl 20 and run.
#
# No llc, no MLIR, no eco code — the JIT'd function is hand-crafted 28 bytes
# of x86_64 + 8 bytes of UNWIND_INFO inside harness.cpp.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$OutDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# clang-cl 20.x is preinstalled on windows-latest under Chocolatey LLVM.
$ClangCl = (Get-Command clang-cl.exe -ErrorAction Stop).Source
Write-Host "=== using $ClangCl ==="
& $ClangCl --version | Select-Object -First 4

# /MD because the static MSVC runtime adds a thunk shim that confused E-W1;
# /MD gets us msvcrt.dll and clean direct calls. /INCREMENTAL:NO for the
# same reason — see E-W1's findings in plans/build-on-windows.md.
& $ClangCl /nologo /std:c++17 /EHa /O2 /MD `
    harness.cpp `
    /Fe:(Join-Path $OutDir 'smoke.exe') `
    /Fo:(Join-Path $OutDir '\') `
    /link /SUBSYSTEM:CONSOLE /INCREMENTAL:NO
if ($LASTEXITCODE -ne 0) { throw "compile/link failed: $LASTEXITCODE" }

Write-Host "=== running smoke ==="
$log = Join-Path $OutDir 'smoke.log'
& (Join-Path $OutDir 'smoke.exe') 2>&1 | Tee-Object -FilePath $log
$rc = $LASTEXITCODE
Write-Host "smoke exit code = $rc"
if ($rc -ne 0) { exit $rc }
Write-Host "=== E-W2 COMPLETE ==="
