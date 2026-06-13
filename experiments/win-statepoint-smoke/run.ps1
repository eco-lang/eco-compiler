# E-W1 statepoint smoke — driver (Windows / x86_64-pc-windows-msvc).
#
# Pipeline: gcfun.ll → opt(rewrite-statepoints-for-gc) → llc(COFF) →
# llvm-readobj sanity check on `.llvm_stackmaps` → clang-cl link with
# harness.cpp against the preinstalled MSVC CRT + Windows SDK → run.
# Then the two link-time variants the build-on-windows plan calls out
# (parallels the mac dead_strip / codesign variants):
#   * /OPT:REF survival of `.llvm_stackmaps` (does lld-link's default
#     dead-strip remove it?),
#   * /INCLUDE:__LLVM_StackMaps rescue (force-keep symbol).
#
# Toolchain: LLVM 21.1.8 prebuilt downloaded into out/llvm/ — this carries
# opt, llc, llvm-readobj, clang-cl, lld-link. The runner's preinstalled VS
# Build Tools + Windows SDK supply the MSVC CRT and import libs (kernel32 etc).

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$LlvmVersion = '21.1.8'
$LlvmAsset   = "clang+llvm-$LlvmVersion-x86_64-pc-windows-msvc.tar.xz"
$LlvmUrl     = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/$LlvmAsset"
$OutDir      = Join-Path $PSScriptRoot 'out'
$LlvmRoot    = Join-Path $OutDir 'llvm'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not (Test-Path (Join-Path $LlvmRoot 'bin\llc.exe'))) {
    Write-Host "=== downloading $LlvmAsset ==="
    $tarball = Join-Path $OutDir $LlvmAsset
    if (-not (Test-Path $tarball)) {
        Invoke-WebRequest -Uri $LlvmUrl -OutFile $tarball -UseBasicParsing
    }
    Write-Host "=== extracting to $LlvmRoot ==="
    New-Item -ItemType Directory -Force -Path $LlvmRoot | Out-Null
    # bsdtar (Windows 10+ system tar) auto-detects .tar.xz.
    & tar -xf $tarball -C $LlvmRoot --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw "tar extract failed: $LASTEXITCODE" }
}

$Opt        = Join-Path $LlvmRoot 'bin\opt.exe'
$Llc        = Join-Path $LlvmRoot 'bin\llc.exe'
$ReadObj    = Join-Path $LlvmRoot 'bin\llvm-readobj.exe'
$ClangCl    = Join-Path $LlvmRoot 'bin\clang-cl.exe'

Write-Host "=== using LLVM at $LlvmRoot ==="
& $Llc --version | Select-Object -First 4

Write-Host "=== 1. RewriteStatepointsForGC ==="
& $Opt -passes=rewrite-statepoints-for-gc -S gcfun.ll -o (Join-Path $OutDir 'gcfun.rs4gc.ll')
if ($LASTEXITCODE -ne 0) { throw "opt failed: $LASTEXITCODE" }
$rs4gc = Get-Content (Join-Path $OutDir 'gcfun.rs4gc.ll') -Raw
if ($rs4gc -notmatch 'gc\.statepoint') {
    throw "FAIL: no statepoints emitted by RS4GC"
}
Write-Host "ok: gc.statepoint intrinsics present in rewritten IR"

Write-Host "=== 2. llc -> COFF object ==="
# -function-sections puts each function in its own COMDAT .text/.pdata/.xdata,
# which is what clang-cl does by default and what lld-link's pdata-merging
# pass expects: the previous run proved that without -function-sections,
# llc's single aggregated non-COMDAT .pdata got dropped from the final
# exception directory while clang-cl's per-function COMDAT .pdata was kept.
& $Llc -O2 -function-sections -mtriple=x86_64-pc-windows-msvc -filetype=obj `
    (Join-Path $OutDir 'gcfun.rs4gc.ll') `
    -o (Join-Path $OutDir 'gcfun.o')
if ($LASTEXITCODE -ne 0) { throw "llc failed: $LASTEXITCODE" }

Write-Host "--- stackmaps section in the object: ---"
$sections = & $ReadObj --sections (Join-Path $OutDir 'gcfun.o') | Out-String
$sections | Write-Host
if ($sections -notmatch '\.llvm_stackmaps') {
    throw "FAIL: no .llvm_stackmaps section in COFF object"
}

Write-Host "--- symbols in the object: ---"
$symbols = & $ReadObj --symbols (Join-Path $OutDir 'gcfun.o') | Out-String
$symbols | Write-Host

Write-Host "--- llc-generated assembly (also writing .s alongside the .o): ---"
& $Llc -O2 -mtriple=x86_64-pc-windows-msvc -filetype=asm `
    (Join-Path $OutDir 'gcfun.rs4gc.ll') `
    -o (Join-Path $OutDir 'gcfun.s')
Get-Content (Join-Path $OutDir 'gcfun.s') | Write-Host

Write-Host "--- disassembly of consume_root + consume_root_dynalloca in the .o: ---"
$ObjDump = Join-Path $LlvmRoot 'bin\llvm-objdump.exe'
& $ObjDump -d --disassemble-symbols=consume_root,consume_root_dynalloca `
    (Join-Path $OutDir 'gcfun.o') | Write-Host

Write-Host "--- unwind info (.pdata/.xdata) in the .o: ---"
& $ObjDump --unwind-info (Join-Path $OutDir 'gcfun.o') | Write-Host

Write-Host "=== 3. link (default) + run: variants (a) plain frame, (b) dynamic alloca ==="
# Compile harness.cpp to .obj separately so we can inspect its sections.
# No /Zi — the thunk-table at the start of .text is a /Zi/DEBUG artefact
# that breaks &function resolution (it gives the thunk, not the real fn).
& $ClangCl /nologo /c /std:c++17 /EHsc /O2 /MD `
    harness.cpp /Fo:(Join-Path $OutDir 'harness.obj')
if ($LASTEXITCODE -ne 0) { throw "clang-cl compile harness failed: $LASTEXITCODE" }

Write-Host "--- harness.obj sections — count .text vs .pdata vs .xdata: ---"
$harnessSectionsRaw = & $ReadObj --section-headers (Join-Path $OutDir 'harness.obj') | Out-String
$counts = @{
    text  = ([regex]::Matches($harnessSectionsRaw, 'Name: \.text\b')).Count
    pdata = ([regex]::Matches($harnessSectionsRaw, 'Name: \.pdata\b')).Count
    xdata = ([regex]::Matches($harnessSectionsRaw, 'Name: \.xdata\b')).Count
}
Write-Host "harness.obj: .text=$($counts.text) .pdata=$($counts.pdata) .xdata=$($counts.xdata)"

Write-Host "--- BASELINE: trivial hello.cpp, no /Zi, does main get a .pdata entry? ---"
$helloCpp = Join-Path $OutDir 'hello.cpp'
Set-Content -Path $helloCpp -Value @'
#include <cstdio>
int main() {
    std::printf("hello from baseline\n");
    return 0;
}
'@
# No /Zi this time — the previous run proved &main resolves to a 5-byte e9-jmp
# thunk at the start of .text and the real main lives at the thunk's target,
# which DOES have a .pdata entry. The thunk table is a /Zi/DEBUG artefact.
& $ClangCl /nologo /std:c++17 /O2 /MD $helloCpp /Fe:(Join-Path $OutDir 'hello.exe') /Fo:(Join-Path $OutDir 'hello.obj') /link /SUBSYSTEM:CONSOLE | Out-String | Write-Host
& (Join-Path $OutDir 'hello.exe') | Write-Host

# Now read hello.exe's exception directory and check whether main is in it.
$probeCpp = Join-Path $OutDir 'probe.cpp'
Set-Content -Path $probeCpp -Value @'
#include <windows.h>
#include <cstdio>
int main() {
    HMODULE h = GetModuleHandleW(nullptr);
    auto* base = (const unsigned char*)h;
    auto* dos = (const IMAGE_DOS_HEADER*)base;
    auto* nt  = (const IMAGE_NT_HEADERS64*)(base + dos->e_lfanew);
    auto& d   = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
    std::printf("exDir VA=0x%lx Size=%lu (%lu entries)\n",
                (unsigned long)d.VirtualAddress, (unsigned long)d.Size,
                (unsigned long)(d.Size / sizeof(RUNTIME_FUNCTION)));
    DWORD64 ib=0; auto rf=RtlLookupFunctionEntry((DWORD64)(uintptr_t)&main, &ib, nullptr);
    std::printf("&main=0x%llx, RVA=0x%llx -> %s\n",
                (unsigned long long)(uintptr_t)&main,
                (unsigned long long)((uintptr_t)&main - (uintptr_t)base),
                rf ? "ENTRY FOUND" : "NULL");
    // Dump first 16 bytes at &main — a 5-byte e9-relative-jmp signals a thunk;
    // a 48 83 ec XX sub-rsp shows the real prologue.
    auto* mb = (const unsigned char*)&main;
    std::printf("bytes at &main:");
    for (int i = 0; i < 16; ++i) std::printf(" %02x", mb[i]);
    std::printf("\n");
    // Dump first 8 entries of the runtime function table.
    auto* tab = (const RUNTIME_FUNCTION*)(base + d.VirtualAddress);
    unsigned n = d.Size / sizeof(RUNTIME_FUNCTION);
    std::printf("first %u entries:\n", n < 8 ? n : 8u);
    for (unsigned i = 0; i < (n < 8 ? n : 8u); ++i) {
        std::printf("  [%u] Begin=0x%lx End=0x%lx Unwind=0x%lx\n", i,
                    (unsigned long)tab[i].BeginAddress,
                    (unsigned long)tab[i].EndAddress,
                    (unsigned long)tab[i].UnwindData);
    }
    // Try addresses near &main to find the nearest entry.
    DWORD64 offsets[] = {0, 4, 8, 12, 16, 24, 32, (DWORD64)-4, (DWORD64)-8, (DWORD64)-16};
    for (DWORD64 off : offsets) {
        DWORD64 ib2=0;
        DWORD64 addr = (DWORD64)(uintptr_t)&main + off;
        auto rf2 = RtlLookupFunctionEntry(addr, &ib2, nullptr);
        std::printf("  probe addr=0x%llx (offset %+lld): %s\n",
                    (unsigned long long)addr, (long long)off,
                    rf2 ? "FOUND" : "null");
    }
    return 0;
}
'@
& $ClangCl /nologo /std:c++17 /Zi /O2 /MD $probeCpp /Fe:(Join-Path $OutDir 'probe.exe') /Fo:(Join-Path $OutDir 'probe.obj') /link /SUBSYSTEM:CONSOLE | Out-String | Write-Host
& (Join-Path $OutDir 'probe.exe') | Write-Host

# Link both .objs. lld-link emits a 5-byte e9-jmp thunk table at the start
# of .text for address-taken functions regardless of /Zi or /INCREMENTAL:NO,
# so the harness now follows the thunk at runtime — see followThunk() in
# harness.cpp. Linker flags are kept release-style for clarity.
$mapArg = '/MAP:' + (Join-Path $OutDir 'smoke.map')
& $ClangCl /nologo /MD `
    (Join-Path $OutDir 'harness.obj') (Join-Path $OutDir 'gcfun.o') `
    /Fe:(Join-Path $OutDir 'smoke.exe') `
    /link /SUBSYSTEM:CONSOLE /INCREMENTAL:NO $mapArg
if ($LASTEXITCODE -ne 0) { throw "clang-cl link (default) failed: $LASTEXITCODE" }

Write-Host "--- map: addresses of consume_root, do_safepoint, main: ---"
Get-Content (Join-Path $OutDir 'smoke.map') -ErrorAction SilentlyContinue | `
    Select-String -Pattern 'consume_root|do_safepoint|\smain\b|consume_root_dynalloca' | Write-Host

Write-Host "--- section layout in the linked binary (default link): ---"
$linkedSections = & $ReadObj --sections (Join-Path $OutDir 'smoke.exe') | Out-String
$linkedSections | Tee-Object -FilePath (Join-Path $OutDir 'sections-default.log') | Write-Host

Write-Host "--- llvm-readobj raw section headers (look for .pdata Characteristics): ---"
& $ReadObj --section-headers (Join-Path $OutDir 'gcfun.o') | Out-String | Write-Host

Write-Host "--- llvm-readobj relocations on gcfun.o (do the .pdata relocs look sane?): ---"
& $ReadObj --relocations (Join-Path $OutDir 'gcfun.o') | Out-String | Write-Host

Write-Host "--- dumpbin /headers smoke.exe (data directories): ---"
& cmd.exe /c "dumpbin.exe /headers `"$(Join-Path $OutDir 'smoke.exe')`"" 2>&1 | Select-String -Pattern 'Directory|exception|pdata|text|xdata|directories' | Write-Host

Write-Host "--- dumpbin /unwindinfo smoke.exe (first ~30 lines): ---"
& cmd.exe /c "dumpbin.exe /unwindinfo `"$(Join-Path $OutDir 'smoke.exe')`"" 2>&1 | Select-Object -First 40 | Write-Host

Write-Host "--- compare .pdata characteristics: gcfun.o (llc) vs clang-cl-emitted .o ---"
$consumeC = Join-Path $OutDir 'consume_clang.c'
Set-Content -Path $consumeC -Value @'
extern void do_safepoint(void);
void* consume_root_clang(void* obj) {
    do_safepoint();
    return obj;
}
'@
& $ClangCl /nologo /c /O2 $consumeC /Fo:(Join-Path $OutDir 'consume_clang.o') | Out-String | Write-Host
Write-Host "--- consume_clang.o sections (look at .pdata Characteristics & COMDAT): ---"
& $ReadObj --section-headers (Join-Path $OutDir 'consume_clang.o') | Out-String | Write-Host

$logDefault = Join-Path $OutDir 'smoke-default.log'
& (Join-Path $OutDir 'smoke.exe') 2>&1 | Tee-Object -FilePath $logDefault
$rcDefault = $LASTEXITCODE
Write-Host "default link: exit code = $rcDefault"

if ($rcDefault -ne 0 -and $rcDefault -ne 3) {
    throw "FAIL: default smoke run returned unexpected exit code $rcDefault"
}

Write-Host "=== 4. variant (c): explicit /OPT:REF (dead-strip analogue) ==="
& $ClangCl /nologo /std:c++17 /EHsc /O2 /MD `
    harness.cpp (Join-Path $OutDir 'gcfun.o') `
    /Fe:(Join-Path $OutDir 'smoke-optref.exe') `
    /Fo:(Join-Path $OutDir '\') `
    /link /SUBSYSTEM:CONSOLE /INCREMENTAL:NO /OPT:REF
if ($LASTEXITCODE -ne 0) { throw "clang-cl link (/OPT:REF) failed: $LASTEXITCODE" }

$logOptRef = Join-Path $OutDir 'smoke-optref.log'
$env:STACKMAP_ALLOW_MISSING = '1'
& (Join-Path $OutDir 'smoke-optref.exe') 2>&1 | Tee-Object -FilePath $logOptRef
$rcOptRef = $LASTEXITCODE
Remove-Item Env:STACKMAP_ALLOW_MISSING
if ($rcOptRef -eq 0) {
    Write-Host "FINDING: .llvm_stackmaps SURVIVES /OPT:REF and still matches"
} elseif ($rcOptRef -eq 42) {
    Write-Host "FINDING: /OPT:REF REMOVES .llvm_stackmaps (keep-alive needed in eco's link driver)"
} else {
    throw "FAIL: /OPT:REF variant failed with unexpected rc=$rcOptRef"
}

Write-Host "=== 5. summary ==="
Write-Host "default link rc      = $rcDefault $(if ($rcDefault -eq 0) {'(PASS)'} else {'(see log)'})"
Write-Host "/OPT:REF rc          = $rcOptRef"
# variant (d) /INCLUDE:__LLVM_StackMaps was removed: variant (c) above
# proved the section already survives /OPT:REF without any rescue, and
# __LLVM_StackMaps is emitted as a local (non-external) symbol so /INCLUDE
# cannot reference it anyway — see commit history for the unresolved-external
# diagnostic.

if ($rcDefault -ne 0) {
    Write-Host "E-W1 OUTCOME: smoke FAILED on default link — see $logDefault"
    exit 1
}

Write-Host "=== E-W1 COMPLETE ==="
