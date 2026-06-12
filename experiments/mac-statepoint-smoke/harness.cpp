// E-M1 statepoint smoke — harness.
//
// Links against gcfun.o (statepoint-rewritten IR compiled by llc) and
// verifies, at a safepoint reached from inside the GC'd function, that the
// live root passed in can be recovered by:
//   1. locating __LLVM_STACKMAPS,__llvm_stackmaps via getsectiondata,
//   2. parsing the StackMap v3 records,
//   3. walking the stack with the system libunwind (which IS LLVM
//      libunwind on macOS),
//   4. matching frame IPs against (function address + record offset),
//   5. resolving each record location (Register / Direct / Indirect)
//      against the matched frame's registers and reading the root back.
//
// Exit codes: 0 = all PASS, 1 = FAIL, 3 = stackmap section missing,
//             42 = section missing but STACKMAP_ALLOW_MISSING=1 was set
//                  (used by run.sh for the -dead_strip variant, where
//                  "missing" is a finding rather than a failure).
//
// Findings this prints for the build-on-mac plan:
//   - whether dyld rebases the recorded function addresses (raw match) or
//     the image slide must be applied manually,
//   - which DWARF registers anchor the locations (fp=29 / sp=31 / x19=19).

#define UNW_LOCAL_ONLY
#include <libunwind.h>

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>  // declares _mh_execute_header
#endif

// ---- StackMap v3 parsing ---------------------------------------------------

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

template <typename T> static T rd(const uint8_t*& p) {
    T v;
    std::memcpy(&v, p, sizeof(T));
    p += sizeof(T);
    return v;
}

static bool parseStackMap() {
#if defined(__APPLE__)
    unsigned long size = 0;
    const uint8_t* base = getsectiondata(&_mh_execute_header, "__LLVM_STACKMAPS",
                                         "__llvm_stackmaps", &size);
    g_slide = _dyld_get_image_vmaddr_slide(0);
#else
    const uint8_t* base = nullptr;
    unsigned long size = 0;
#endif
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
    return true;
}

// ---- Stack walking + root recovery -----------------------------------------

// DWARF register numbers are an identity map onto Apple libunwind's register
// enums for everything we need: arm64 x0..x30 = 0..30, sp = 31 (UNW_ARM64_SP);
// x86_64 rbp = 6, rsp = 7 likewise. So unw_get_reg(cursor, dwarfReg) works.
static bool readFrameReg(unw_cursor_t* cur, uint16_t dwarfReg, uint64_t* out) {
    unw_word_t v = 0;
    if (unw_get_reg(cur, (unw_regnum_t)dwarfReg, &v) != 0) return false;
    *out = (uint64_t)v;
    return true;
}

static void* g_expectedRoot = nullptr;
static int g_phase = 0;          // 1 = consume_root, 2 = consume_root_dynalloca
static bool g_matched[3] = {};   // per-phase: record matched at safepoint
static bool g_recovered[3] = {}; // per-phase: root value recovered from a location
static bool g_sawX19[3] = {};    // per-phase: any location anchored on reg 19

extern "C" void do_safepoint() {
    unw_context_t ctx;
    unw_cursor_t cur;
    unw_getcontext(&ctx);
    unw_init_local(&cur, &ctx);

    while (unw_step(&cur) > 0) {
        unw_word_t ip = 0;
        unw_get_reg(&cur, UNW_REG_IP, &ip);
        for (const Record& rec : g_records) {
            for (int pass = 0; pass < 2; ++pass) {
                uint64_t target = rec.fnAddress + rec.instrOffset + (pass ? (uint64_t)g_slide : 0);
                if ((uint64_t)ip != target) continue;
                if (pass) g_slideNeeded = true;
                g_matched[g_phase] = true;
                std::printf("phase %d: matched record id=%" PRIu64 " at ip=0x%" PRIx64
                            " (%s match)\n",
                            g_phase, rec.id, (uint64_t)ip, pass ? "slide-adjusted" : "raw");
                for (const Location& loc : rec.locations) {
                    uint64_t regv = 0;
                    bool haveReg = loc.type >= 1 && loc.type <= 3 &&
                                   readFrameReg(&cur, loc.dwarfReg, &regv);
                    uint64_t value = 0;
                    const char* kind = "?";
                    switch (loc.type) {
                    case 1: kind = "Register"; value = regv; break;
                    case 2: kind = "Direct";   value = regv + (int64_t)loc.offset; break;
                    case 3: kind = "Indirect";
                        if (haveReg) std::memcpy(&value, (void*)(regv + (int64_t)loc.offset), 8);
                        break;
                    case 4: kind = "Constant"; value = (uint64_t)loc.offset; break;
                    case 5: kind = "ConstIndex"; break;
                    }
                    if (loc.type >= 1 && loc.type <= 3 && loc.dwarfReg == 19)
                        g_sawX19[g_phase] = true;
                    std::printf("    loc %-9s reg=%u off=%d size=%u%s value=0x%" PRIx64 "\n",
                                kind, loc.dwarfReg, loc.offset, loc.size,
                                haveReg ? "" : " (reg unavailable)", value);
                    if ((loc.type == 1 || loc.type == 3) &&
                        value == (uint64_t)(uintptr_t)g_expectedRoot)
                        g_recovered[g_phase] = true;
                }
            }
        }
    }
}

// ---- Driver -----------------------------------------------------------------

extern "C" void* consume_root(void* obj);
extern "C" void* consume_root_dynalloca(void* obj, long n);
extern "C" void use_buffer(char* p) { p[0] = 42; }
extern "C" void use_byte(char) {}

int main() {
    if (!parseStackMap()) {
        std::printf("__LLVM_STACKMAPS section NOT FOUND\n");
        return std::getenv("STACKMAP_ALLOW_MISSING") ? 42 : 3;
    }

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
                g_slideNeeded ? "YES (section not rebased by dyld)" : "no (rebased)");
    std::printf("FINDING: x19 (base pointer) anchored locations: plain=%s dynalloca=%s\n",
                g_sawX19[1] ? "yes" : "no", g_sawX19[2] ? "yes" : "no");

    std::printf(pass ? "ALL PASS\n" : "FAILURES PRESENT\n");
    return pass ? 0 : 1;
}
