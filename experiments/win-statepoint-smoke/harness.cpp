// E-W1 statepoint smoke — harness (Windows / x86_64-pc-windows-msvc).
//
// Links against gcfun.o (statepoint-rewritten IR compiled by llc to COFF)
// and verifies, at a safepoint reached from inside the GC'd function, that
// the live root passed in can be recovered by:
//   1. locating the `.llvm_stackmaps` section via a PE-header walk over the
//      image returned by GetModuleHandle(NULL),
//   2. parsing the StackMap v3 records (identical wire format to Mach-O / ELF),
//   3. walking the stack with RtlCaptureContext + RtlLookupFunctionEntry +
//      RtlVirtualUnwind (the build-on-windows plan's chosen GC-walk primitive,
//      item 15),
//   4. matching frame IPs against (function address + record offset), with
//      a raw-match-first / slide-adjusted-fallback strategy so we can tell
//      whether ASLR rebases the recorded function addresses,
//   5. resolving each record location (Register / Direct / Indirect) against
//      the unwound CONTEXT for that frame, using a DWARF-reg → CONTEXT-field
//      map (x86_64: rax=0..rip=16).
//
// Exit codes: 0 = all PASS, 1 = FAIL, 3 = stackmap section missing,
//             42 = section missing but STACKMAP_ALLOW_MISSING=1 was set
//                  (used by run.ps1 for the /OPT:REF variant, where "missing"
//                  is a finding rather than a failure).
//
// Findings printed for the build-on-windows plan:
//   - whether the OS applies base relocations to recorded function addresses,
//     or the harness must apply (actual base - preferred base) itself,
//   - which DWARF registers anchor the locations (rbp=6 / rsp=7 vs others),
//     since the Eco StackMap consumer must understand the same encoding.

#include <windows.h>

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// ---- StackMap v3 parsing ---------------------------------------------------
//
// Wire format is identical across ELF / Mach-O / COFF: this block is a
// near-verbatim port of experiments/mac-statepoint-smoke/harness.cpp.

struct Location {
    uint8_t type;     // 1=Register 2=Direct 3=Indirect 4=Constant 5=ConstIndex
    uint16_t size;
    uint16_t dwarfReg;
    int32_t offset;
};

struct Record {
    uint64_t id;
    uint64_t fnAddress;   // resolved from the owning StkSizeRecord
    uint32_t instrOffset; // bytes from function start to the return address
    std::vector<Location> locations;
};

static std::vector<Record> g_records;
static intptr_t g_slide = 0;
static bool g_slideNeeded = false; // finding: raw vs slide-adjusted match
static bool g_thunkFollowed = false; // finding: did we have to dereference an e9 jmp thunk?

// lld-link emits a "guard/thunk table" at the start of .text where each
// address-taken function gets a 5-byte e9-jmp slot that hops to the real
// function body. The function's *symbol* address resolves to its slot in
// this table, NOT to its real entry point — so &consume_root and the
// stackmap's fnAddress both point inside this slot, while the actual call
// path passes THROUGH the slot and the safepoint return address lands in
// the real function. This routine follows the jmp to recover the real
// entry, returning addr unchanged if no thunk is present. Idempotent.
static uintptr_t followThunk(uintptr_t addr) {
    if (!addr) return addr;
    const uint8_t* p = reinterpret_cast<const uint8_t*>(addr);
    if (p[0] == 0xE9) {
        int32_t off;
        std::memcpy(&off, p + 1, 4);
        g_thunkFollowed = true;
        return addr + 5 + (intptr_t)off;
    }
    return addr;
}

template <typename T> static T rd(const uint8_t*& p) {
    T v;
    std::memcpy(&v, p, sizeof(T));
    p += sizeof(T);
    return v;
}

// Find the `.llvm_stackmaps` section in the current executable by walking
// the PE headers of the loaded image. GetModuleHandle(NULL) returns the
// image base (HMODULE doubles as the load address). Section names in COFF
// are 8 bytes, padded with NUL — `.llvm_stackmaps` is 15 chars so it does
// not require the string-table fallback path used for longer names.
static const uint8_t* findStackMapsSection(unsigned long* outSize, intptr_t* outSlide) {
    HMODULE hmod = GetModuleHandleW(nullptr);
    if (!hmod) return nullptr;
    const uint8_t* base = reinterpret_cast<const uint8_t*>(hmod);
    auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return nullptr;
    auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return nullptr;

    *outSlide = (intptr_t)((uintptr_t)base - (uintptr_t)nt->OptionalHeader.ImageBase);

    const auto* sec = IMAGE_FIRST_SECTION(nt);
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec) {
        char name[9] = {};
        std::memcpy(name, sec->Name, 8);
        if (std::strncmp(name, ".llvm_stackmaps", 8) == 0) {
            *outSize = sec->Misc.VirtualSize ? sec->Misc.VirtualSize : sec->SizeOfRawData;
            return base + sec->VirtualAddress;
        }
    }
    return nullptr;
}

static bool parseStackMap() {
    unsigned long size = 0;
    const uint8_t* base = findStackMapsSection(&size, &g_slide);
    if (!base || size == 0) return false;

    const uint8_t* p = base;
    uint8_t version = rd<uint8_t>(p);
    rd<uint8_t>(p);
    rd<uint16_t>(p);
    uint32_t numFunctions = rd<uint32_t>(p);
    uint32_t numConstants = rd<uint32_t>(p);
    uint32_t numRecords = rd<uint32_t>(p);
    std::printf("stackmap: version=%u functions=%u constants=%u records=%u size=%lu\n",
                version, numFunctions, numConstants, numRecords, size);

    struct FnEntry { uint64_t addr, stackSize, recordCount; };
    std::vector<FnEntry> fns(numFunctions);
    for (auto& f : fns) {
        f.addr = rd<uint64_t>(p);
        f.stackSize = rd<uint64_t>(p);
        f.recordCount = rd<uint64_t>(p);
        std::printf("  fn addr=0x%" PRIx64 " stackSize=%" PRIu64 " records=%" PRIu64 "\n",
                    f.addr, f.stackSize, f.recordCount);
    }
    for (uint32_t i = 0; i < numConstants; ++i) rd<uint64_t>(p);

    size_t fnIdx = 0;
    uint64_t consumedInFn = 0;
    for (uint32_t r = 0; r < numRecords; ++r) {
        while (fnIdx < fns.size() && consumedInFn >= fns[fnIdx].recordCount) {
            ++fnIdx;
            consumedInFn = 0;
        }
        Record rec;
        rec.fnAddress = fnIdx < fns.size() ? fns[fnIdx].addr : 0;
        ++consumedInFn;

        rec.id = rd<uint64_t>(p);
        rec.instrOffset = rd<uint32_t>(p);
        rd<uint16_t>(p);
        uint16_t numLoc = rd<uint16_t>(p);
        for (uint16_t l = 0; l < numLoc; ++l) {
            Location loc;
            loc.type = rd<uint8_t>(p);
            rd<uint8_t>(p);
            loc.size = rd<uint16_t>(p);
            loc.dwarfReg = rd<uint16_t>(p);
            rd<uint16_t>(p);
            loc.offset = rd<int32_t>(p);
            rec.locations.push_back(loc);
        }
        if (numLoc % 2) rd<uint32_t>(p); // realign to 8 after 12-byte locations
        rd<uint16_t>(p);                 // padding
        uint16_t numLiveOuts = rd<uint16_t>(p);
        for (uint16_t l = 0; l < numLiveOuts; ++l) { rd<uint16_t>(p); rd<uint8_t>(p); rd<uint8_t>(p); }
        if ((numLiveOuts * 4 + 4) % 8) rd<uint32_t>(p); // realign to 8

        std::printf("  record id=%" PRIu64 " fn=0x%" PRIx64 " +%u locations=%zu\n",
                    rec.id, rec.fnAddress, rec.instrOffset, rec.locations.size());
        g_records.push_back(std::move(rec));
    }
    // Resolve thunked fnAddresses to their real targets. Done once after the
    // table is built so matchFrame() can compare against the real function
    // entries that RtlVirtualUnwind will surface.
    for (Record& rec : g_records) {
        uintptr_t real = followThunk((uintptr_t)rec.fnAddress);
        if (real != (uintptr_t)rec.fnAddress) {
            std::printf("  thunk: fn=0x%" PRIx64 " -> real=0x%" PRIxPTR "\n",
                        rec.fnAddress, real);
            rec.fnAddress = (uint64_t)real;
        }
    }
    return true;
}

// ---- Stack walking + root recovery -----------------------------------------

// DWARF register numbers on x86_64 → fields of Win64 CONTEXT.
// Source: System V x86_64 ABI § "DWARF Register Number Mapping"; Win64 uses
// the same numbering since it is a property of the architecture, not the OS.
static const uint64_t* dwarfRegInContext(const CONTEXT* ctx, uint16_t r) {
    switch (r) {
    case 0: return &ctx->Rax;
    case 1: return &ctx->Rdx;
    case 2: return &ctx->Rcx;
    case 3: return &ctx->Rbx;
    case 4: return &ctx->Rsi;
    case 5: return &ctx->Rdi;
    case 6: return &ctx->Rbp;
    case 7: return &ctx->Rsp;
    case 8: return &ctx->R8;
    case 9: return &ctx->R9;
    case 10: return &ctx->R10;
    case 11: return &ctx->R11;
    case 12: return &ctx->R12;
    case 13: return &ctx->R13;
    case 14: return &ctx->R14;
    case 15: return &ctx->R15;
    case 16: return &ctx->Rip;
    default: return nullptr;
    }
}

static void* g_expectedRoot = nullptr;
static int g_phase = 0;          // 1 = consume_root, 2 = consume_root_dynalloca
static bool g_matched[3] = {};   // per-phase: record matched at safepoint
static bool g_recovered[3] = {}; // per-phase: root value recovered from a location
static bool g_sawRbp[3] = {};    // per-phase: any location anchored on rbp (reg 6)
static bool g_sawRsp[3] = {};    // per-phase: any location anchored on rsp (reg 7)

static void matchFrame(const CONTEXT* ctx) {
    uint64_t ip = ctx->Rip;
    for (const Record& rec : g_records) {
        for (int pass = 0; pass < 2; ++pass) {
            uint64_t target = rec.fnAddress + rec.instrOffset + (pass ? (uint64_t)g_slide : 0);
            if (ip != target) continue;
            if (pass) g_slideNeeded = true;
            g_matched[g_phase] = true;
            std::printf("phase %d: matched record id=%" PRIu64 " at ip=0x%" PRIx64
                        " (%s match)\n",
                        g_phase, rec.id, ip, pass ? "slide-adjusted" : "raw");
            for (const Location& loc : rec.locations) {
                const uint64_t* regPtr = (loc.type >= 1 && loc.type <= 3)
                                             ? dwarfRegInContext(ctx, loc.dwarfReg)
                                             : nullptr;
                uint64_t value = 0;
                const char* kind = "?";
                switch (loc.type) {
                case 1: kind = "Register"; if (regPtr) value = *regPtr; break;
                case 2: kind = "Direct";
                    if (regPtr) value = *regPtr + (int64_t)loc.offset; break;
                case 3: kind = "Indirect";
                    if (regPtr) std::memcpy(&value, (void*)(*regPtr + (int64_t)loc.offset), 8);
                    break;
                case 4: kind = "Constant"; value = (uint64_t)loc.offset; break;
                case 5: kind = "ConstIndex"; break;
                }
                if (loc.type >= 1 && loc.type <= 3) {
                    if (loc.dwarfReg == 6) g_sawRbp[g_phase] = true;
                    if (loc.dwarfReg == 7) g_sawRsp[g_phase] = true;
                }
                std::printf("    loc %-9s reg=%u off=%d size=%u%s value=0x%" PRIx64 "\n",
                            kind, loc.dwarfReg, loc.offset, loc.size,
                            regPtr ? "" : " (reg unavailable)", value);
                if ((loc.type == 1 || loc.type == 3) &&
                    value == (uint64_t)(uintptr_t)g_expectedRoot)
                    g_recovered[g_phase] = true;
            }
        }
    }
}

extern "C" void do_safepoint() {
    CONTEXT ctx;
    RtlCaptureContext(&ctx);

    std::printf("phase %d: do_safepoint walk begins, initial Rip=0x%" PRIx64 "\n",
                g_phase, (uint64_t)ctx.Rip);
    int step = 0;
    // Step-up-one-frame-then-check loop, mirroring the mac harness's
    // unw_step + unw_get_reg(IP) pattern. After each RtlVirtualUnwind,
    // ctx.Rip is the return address inside the caller — which is exactly
    // what the stackmap records for the safepoint.
    while (ctx.Rip) {
        DWORD64 imageBase = 0;
        PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry(ctx.Rip, &imageBase, nullptr);
        if (!rf) {
            std::printf("phase %d: step %d: no RUNTIME_FUNCTION for Rip=0x%" PRIx64
                        " — stop walking\n", g_phase, step, (uint64_t)ctx.Rip);
            break;
        }
        PVOID handlerData = nullptr;
        DWORD64 establisherFrame = 0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, ctx.Rip, rf, &ctx,
                         &handlerData, &establisherFrame, nullptr);
        if (!ctx.Rip) break;
        ++step;
        std::printf("phase %d: step %d: unwound Rip=0x%" PRIx64 " imageBase=0x%" PRIx64 "\n",
                    g_phase, step, (uint64_t)ctx.Rip, (uint64_t)imageBase);
        matchFrame(&ctx);
        if (step > 8) {
            std::printf("phase %d: step cap reached, stopping walk\n", g_phase);
            break;
        }
    }
}

// ---- Driver -----------------------------------------------------------------

extern "C" void* consume_root(void* obj);
extern "C" void* consume_root_dynalloca(void* obj, long long n);
extern "C" void use_buffer(char* p) { p[0] = 42; }
extern "C" void use_byte(char) {}

int main() {
    if (!parseStackMap()) {
        std::printf(".llvm_stackmaps section NOT FOUND\n");
        return std::getenv("STACKMAP_ALLOW_MISSING") ? 42 : 3;
    }

    std::printf("image slide = 0x%" PRIxPTR "\n", (uintptr_t)g_slide);
    std::printf("target IPs (raw):\n");
    for (const Record& rec : g_records) {
        std::printf("  fn=0x%" PRIx64 " +%u  raw=0x%" PRIx64 "  slid=0x%" PRIx64 "\n",
                    rec.fnAddress, rec.instrOffset,
                    rec.fnAddress + rec.instrOffset,
                    rec.fnAddress + rec.instrOffset + (uint64_t)g_slide);
    }
    std::printf("&consume_root = 0x%" PRIx64 "  &consume_root_dynalloca = 0x%" PRIx64 "\n",
                (uint64_t)(uintptr_t)&consume_root,
                (uint64_t)(uintptr_t)&consume_root_dynalloca);

    // Dump the PE exception data directory and the head of the runtime
    // function table directly — RtlLookupFunctionEntry depends on this table
    // being populated by the loader; if it isn't, ALL lookups return NULL.
    HMODULE hmod = GetModuleHandleW(nullptr);
    auto* exeBase = reinterpret_cast<const uint8_t*>(hmod);
    auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(exeBase);
    auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(exeBase + dos->e_lfanew);
    const auto& exDir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
    std::printf("PE exception directory: VA=0x%lx Size=%lu bytes (%lu entries)\n",
                (unsigned long)exDir.VirtualAddress,
                (unsigned long)exDir.Size,
                (unsigned long)(exDir.Size / sizeof(RUNTIME_FUNCTION)));
    if (exDir.VirtualAddress && exDir.Size) {
        auto* table = reinterpret_cast<const RUNTIME_FUNCTION*>(exeBase + exDir.VirtualAddress);
        unsigned count = exDir.Size / sizeof(RUNTIME_FUNCTION);
        std::printf("first/last few RUNTIME_FUNCTION entries (RVAs, not absolute):\n");
        for (unsigned i = 0; i < count; ++i) {
            if (i >= 4 && i + 4 < count) { if (i == 4) std::printf("  ...\n"); continue; }
            std::printf("  [%u] Begin=0x%lx End=0x%lx UnwindData=0x%lx\n", i,
                        (unsigned long)table[i].BeginAddress,
                        (unsigned long)table[i].EndAddress,
                        (unsigned long)table[i].UnwindData);
        }
    }

    auto dumpRf = [&](const char* what, void* fn) {
        uintptr_t real = followThunk((uintptr_t)fn);
        bool thunked = real != (uintptr_t)fn;
        DWORD64 fnRVA = (DWORD64)(real - (uintptr_t)exeBase);
        DWORD64 ib = 0;
        PRUNTIME_FUNCTION rf = RtlLookupFunctionEntry((DWORD64)real, &ib, nullptr);
        std::printf("RtlLookupFunctionEntry(%s @ 0x%" PRIxPTR "%s, RVA=0x%" PRIx64 ") -> %s\n",
                    what, real, thunked ? " (thunk-deref'd)" : "",
                    (uint64_t)fnRVA, rf ? "ENTRY FOUND" : "NULL");
        if (rf) {
            std::printf("    Begin=0x%lx End=0x%lx UnwindData=0x%lx (imageBase=0x%" PRIx64 ")\n",
                        (unsigned long)rf->BeginAddress,
                        (unsigned long)rf->EndAddress,
                        (unsigned long)rf->UnwindData,
                        (uint64_t)ib);
        }
    };
    dumpRf("consume_root", (void*)&consume_root);
    dumpRf("consume_root_dynalloca", (void*)&consume_root_dynalloca);
    dumpRf("do_safepoint", (void*)&do_safepoint);
    dumpRf("main", (void*)&main);

    g_expectedRoot = std::malloc(64);

    g_phase = 1;
    void* r1 = consume_root(g_expectedRoot);
    g_phase = 2;
    void* r2 = consume_root_dynalloca(g_expectedRoot, 64);
    g_phase = 0;

    bool pass = true;
    auto check = [&](bool ok, const char* what) {
        std::printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) pass = false;
    };
    check(r1 == g_expectedRoot, "consume_root returned the root unchanged");
    check(g_matched[1], "safepoint record matched in consume_root frame");
    check(g_recovered[1], "root recovered from stackmap location (plain frame)");
    check(r2 == g_expectedRoot, "consume_root_dynalloca returned the root unchanged");
    check(g_matched[2], "safepoint record matched in consume_root_dynalloca frame");
    check(g_recovered[2], "root recovered from stackmap location (dynamic alloca frame)");

    std::printf("FINDING: function addresses required slide adjustment: %s\n",
                g_slideNeeded ? "YES (image base reloc not applied to .llvm_stackmaps)"
                              : "no (rebased by loader)");
    std::printf("FINDING: thunk dereference needed: %s (lld-link emits a 5-byte e9-jmp\n"
                "         table for address-taken functions; stackmap fnAddresses point\n"
                "         at the thunk slot, not the real entry — eco's runtime stackmap\n"
                "         consumer must do the same dereference)\n",
                g_thunkFollowed ? "YES" : "no");
    std::printf("FINDING: rbp-anchored locations: plain=%s dynalloca=%s\n",
                g_sawRbp[1] ? "yes" : "no", g_sawRbp[2] ? "yes" : "no");
    std::printf("FINDING: rsp-anchored locations: plain=%s dynalloca=%s\n",
                g_sawRsp[1] ? "yes" : "no", g_sawRsp[2] ? "yes" : "no");

    std::printf(pass ? "ALL PASS\n" : "FAILURES PRESENT\n");
    return pass ? 0 : 1;
}
