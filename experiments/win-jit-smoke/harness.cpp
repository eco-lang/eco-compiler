// E-W2 from plans/build-on-windows.md: Win64 JIT-frame registration and
// the VirtualAlloc-based heap-model micro-tests. No eco code, no llc — both
// halves stand alone on Windows primitives + 28 hand-crafted bytes of x86_64.
//
// Phase 1 (heap-model): exercise the reserve-once / commit-at-fixed-address
// / decommit / release pattern that the eco runtime's Allocator.cpp uses
// on Linux/macOS. Confirms VirtualAlloc supports MEM_RESERVE of a large
// region with subsequent MEM_COMMIT at arbitrary offsets within it — the
// build-on-windows plan item 6 claims the mmap model maps 1:1 with no
// placeholders / VirtualAlloc2 needed.
//
// Phase 2 (JIT frame): VirtualAlloc an RX page, copy a hand-crafted 28-byte
// function plus its UNWIND_INFO, register a RUNTIME_FUNCTION via
// RtlAddFunctionTable, call the function, and inside its callback do a
// one-step unwind. Confirms RtlLookupFunctionEntry sees the registered
// table entry and RtlVirtualUnwind can step from the registered frame into
// its caller — the mechanism eco's GC stack walk must lean on for JIT'd
// code (build-on-windows plan items 15 & 16, confidence risk 2).
//
// Exit codes: 0 = all PASS, 1 = any FAIL.

#include <windows.h>

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>

// ----- Phase 1: heap model -------------------------------------------------

static bool testHeapModel() {
    constexpr SIZE_T RESERVE_SIZE = 64ULL * 1024 * 1024 * 1024; // 64 GiB
    constexpr SIZE_T PAGE = 4096;

    uint8_t* base = (uint8_t*)VirtualAlloc(nullptr, RESERVE_SIZE,
                                            MEM_RESERVE, PAGE_NOACCESS);
    if (!base) {
        std::printf("heap: FAIL — VirtualAlloc(MEM_RESERVE, 64 GiB) failed: %lu\n",
                    GetLastError());
        return false;
    }
    std::printf("heap: reserved 64 GiB at 0x%p\n", base);

    // Commit a page at offset 8 MiB.
    uint8_t* p1 = base + 8ULL * 1024 * 1024;
    if (!VirtualAlloc(p1, PAGE, MEM_COMMIT, PAGE_READWRITE)) {
        std::printf("heap: FAIL — commit #1 at +8 MiB: %lu\n", GetLastError());
        return false;
    }
    *(uint32_t*)p1 = 0xDEADBEEF;
    std::printf("heap: committed page at +8 MiB, wrote DEADBEEF\n");

    // Commit a page 1 GiB away — far jump, deliberately exercising the
    // sparse-commit pattern eco's heap uses.
    uint8_t* p2 = base + 1ULL * 1024 * 1024 * 1024;
    if (!VirtualAlloc(p2, PAGE, MEM_COMMIT, PAGE_READWRITE)) {
        std::printf("heap: FAIL — commit #2 at +1 GiB: %lu\n", GetLastError());
        return false;
    }
    *(uint32_t*)p2 = 0xCAFEBABE;
    std::printf("heap: committed page at +1 GiB, wrote CAFEBABE\n");

    if (*(uint32_t*)p1 != 0xDEADBEEF) {
        std::printf("heap: FAIL — readback p1\n"); return false;
    }
    if (*(uint32_t*)p2 != 0xCAFEBABE) {
        std::printf("heap: FAIL — readback p2\n"); return false;
    }

    // Decommit p1 — the page should fault on next access.
    if (!VirtualFree(p1, PAGE, MEM_DECOMMIT)) {
        std::printf("heap: FAIL — decommit p1: %lu\n", GetLastError());
        return false;
    }

    bool faulted = false;
    __try {
        volatile uint32_t v = *(volatile uint32_t*)p1;
        (void)v;
    } __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
                ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        faulted = true;
    }
    if (!faulted) {
        std::printf("heap: FAIL — decommitted page did not fault on read\n");
        return false;
    }
    std::printf("heap: decommitted page faults as expected\n");

    // p2 still readable.
    if (*(uint32_t*)p2 != 0xCAFEBABE) {
        std::printf("heap: FAIL — p2 corrupted after p1 decommit\n");
        return false;
    }

    if (!VirtualFree(base, 0, MEM_RELEASE)) {
        std::printf("heap: FAIL — MEM_RELEASE: %lu\n", GetLastError());
        return false;
    }
    std::printf("heap: PASS — reserve(64 GiB) / commit-sparsely / decommit / release\n");
    return true;
}

// ----- Phase 2: JIT-frame registration & unwind ----------------------------

static bool g_walkOk = false;
static uintptr_t g_jitRegionBase = 0;
static size_t g_jitRegionSize = 0;

extern "C" void jit_callback() {
    CONTEXT ctx;
    RtlCaptureContext(&ctx);

    // The captured context puts ctx.Rip somewhere inside jit_callback. First
    // step: unwind to our caller — which IS the JIT'd code. We do the
    // RtlLookupFunctionEntry inside the JIT region after that step.
    DWORD64 ib = 0;
    PRUNTIME_FUNCTION rfHere = RtlLookupFunctionEntry(ctx.Rip, &ib, nullptr);
    if (!rfHere) {
        std::printf("jit: FAIL — lookup of jit_callback's own Rip returned NULL\n");
        return;
    }

    PVOID handlerData = nullptr;
    DWORD64 estFrame = 0;
    RtlVirtualUnwind(UNW_FLAG_NHANDLER, ib, ctx.Rip, rfHere, &ctx,
                     &handlerData, &estFrame, nullptr);

    uintptr_t rip = (uintptr_t)ctx.Rip;
    bool inJit = (rip >= g_jitRegionBase && rip < g_jitRegionBase + g_jitRegionSize);
    std::printf("jit: post-unwind Rip=0x%" PRIxPTR " (in JIT region: %s)\n",
                rip, inJit ? "YES" : "no");
    if (!inJit) {
        std::printf("jit: FAIL — unwind did not land in the JIT region\n");
        return;
    }

    DWORD64 ib2 = 0;
    PRUNTIME_FUNCTION rfJit = RtlLookupFunctionEntry(rip, &ib2, nullptr);
    if (!rfJit) {
        std::printf("jit: FAIL — RtlLookupFunctionEntry inside JIT region returned NULL "
                    "(RtlAddFunctionTable did not register correctly)\n");
        return;
    }
    std::printf("jit: registered entry found: Begin=0x%lx End=0x%lx UnwindData=0x%lx "
                "imageBase=0x%" PRIx64 "\n",
                (unsigned long)rfJit->BeginAddress,
                (unsigned long)rfJit->EndAddress,
                (unsigned long)rfJit->UnwindData,
                (uint64_t)ib2);
    g_walkOk = true;
}

static bool testJitFrames() {
    // Hand-crafted 28-byte Win64 function. Layout matches the UNWIND_INFO
    // emitted below — prologue is the 4-byte `sub rsp, 0x28` (which doubles
    // as Win64 shadow space for the call), then a 10-byte mov-imm64 to
    // load the callback address, then call rax, mov eax,42, restore rsp,
    // ret. Hand-crafting it sidesteps any COFF-section / linker thunk
    // ambiguity from E-W1 — we know exactly which bytes are at each offset.
    static const uint8_t code[] = {
        0x48, 0x83, 0xec, 0x28,                          // sub rsp, 0x28      (off 0, 4 bytes)
        0x48, 0xb8, 0,0,0,0, 0,0,0,0,                    // mov rax, imm64     (off 4, 10 bytes)
        0xff, 0xd0,                                      // call rax           (off 14, 2 bytes)
        0xb8, 0x2a, 0x00, 0x00, 0x00,                    // mov eax, 42        (off 16, 5 bytes)
        0x48, 0x83, 0xc4, 0x28,                          // add rsp, 0x28      (off 21, 4 bytes)
        0xc3                                             // ret                (off 25, 1 byte)
    };
    static_assert(sizeof(code) == 26, "code size mismatch");
    constexpr size_t CALLBACK_PATCH_OFFSET = 6;

    // UNWIND_INFO for the one operation in the prologue: UWOP_ALLOC_SMALL 40
    // (size = 8*(OpInfo+1), OpInfo=4 → 40 bytes). Padded to 8-byte aligned.
    static const uint8_t unwindInfo[] = {
        0x01,    // Version=1, Flags=0
        0x04,    // SizeOfProlog = 4 bytes (end of sub rsp,0x28)
        0x01,    // CountOfCodes = 1
        0x00,    // FrameRegister=0, FrameOffset=0
        0x04,    // UnwindCode[0]: CodeOffset = 4 (end of prologue)
        0x42,    // UnwindCode[0]: OpInfo=4, UnwindOp=UWOP_ALLOC_SMALL(2)
        0x00, 0x00
    };

    constexpr size_t REGION_SIZE = 4096;
    constexpr size_t XDATA_OFFSET = 64; // 64-byte boundary, easy to align unwind info

    uint8_t* region = (uint8_t*)VirtualAlloc(nullptr, REGION_SIZE,
                                              MEM_COMMIT | MEM_RESERVE,
                                              PAGE_READWRITE);
    if (!region) {
        std::printf("jit: FAIL — VirtualAlloc RW page: %lu\n", GetLastError());
        return false;
    }
    g_jitRegionBase = (uintptr_t)region;
    g_jitRegionSize = REGION_SIZE;
    std::memset(region, 0xcc, REGION_SIZE);          // int3 fill — any control-flow drift faults loudly
    std::memcpy(region, code, sizeof(code));
    uintptr_t cbAddr = (uintptr_t)&jit_callback;
    std::memcpy(region + CALLBACK_PATCH_OFFSET, &cbAddr, sizeof(cbAddr));
    std::memcpy(region + XDATA_OFFSET, unwindInfo, sizeof(unwindInfo));

    static RUNTIME_FUNCTION rf{};
    rf.BeginAddress = 0;
    rf.EndAddress = (DWORD)sizeof(code);
    rf.UnwindInfoAddress = (DWORD)XDATA_OFFSET;

    DWORD oldProtect = 0;
    if (!VirtualProtect(region, REGION_SIZE, PAGE_EXECUTE_READ, &oldProtect)) {
        std::printf("jit: FAIL — VirtualProtect → RX: %lu\n", GetLastError());
        return false;
    }

    if (!RtlAddFunctionTable(&rf, 1, (DWORD64)region)) {
        std::printf("jit: FAIL — RtlAddFunctionTable returned FALSE\n");
        return false;
    }
    std::printf("jit: registered RUNTIME_FUNCTION at base=0x%" PRIxPTR
                " (Begin=0 End=%u UnwindData=0x%lx)\n",
                (uintptr_t)region, rf.EndAddress, (unsigned long)rf.UnwindInfoAddress);

    DWORD64 ibPre = 0;
    PRUNTIME_FUNCTION rfPre = RtlLookupFunctionEntry((DWORD64)(region + 4), &ibPre, nullptr);
    if (!rfPre) {
        std::printf("jit: FAIL — pre-call RtlLookupFunctionEntry returned NULL\n");
        return false;
    }
    std::printf("jit: pre-call lookup ok (Begin=0x%lx End=0x%lx imageBase=0x%" PRIx64 ")\n",
                (unsigned long)rfPre->BeginAddress,
                (unsigned long)rfPre->EndAddress,
                (uint64_t)ibPre);

    using JitFn = int (*)();
    JitFn fn = reinterpret_cast<JitFn>(region);
    int result = fn();
    if (result != 42) {
        std::printf("jit: FAIL — fn() returned %d, expected 42\n", result);
        return false;
    }
    if (!g_walkOk) {
        std::printf("jit: FAIL — jit_callback did not confirm the unwind\n");
        return false;
    }

    if (!RtlDeleteFunctionTable(&rf)) {
        std::printf("jit: WARN — RtlDeleteFunctionTable returned FALSE (continuing)\n");
    }
    VirtualFree(region, 0, MEM_RELEASE);
    std::printf("jit: PASS — RtlAddFunctionTable + RtlLookupFunctionEntry + RtlVirtualUnwind through JIT frame\n");
    return true;
}

int main() {
    bool ok = true;
    std::printf("=== Phase 1: heap model (Allocator.cpp pattern) ===\n");
    ok &= testHeapModel();
    std::printf("\n=== Phase 2: JIT frame registration + unwind (EcoJIT pattern) ===\n");
    ok &= testJitFrames();
    std::printf("\n=== E-W2 %s ===\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
