// threaded-gc-04: the P1 census (detectors O and W, modes, reporting).
// See P1Census.hpp and plans/threaded-gc-04-frozen-published-heap.md P§3.

#include "P1Census.hpp"

#if P1_CENSUS_COMPILED

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <utility>

#include <dlfcn.h>

#include "Allocator.hpp"
#include "GCStats.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"
#include "RuntimeExports.h"
#include "ThreadLocalHeap.hpp"

namespace Elm {
namespace p1 {

// Befriended by OldGenSpace: the only way the census reads mark bits.
struct P1CensusAccess {
    static bool markedNow(const OldGenSpace& og, const void* obj) {
        const BlockId id = og.blockIdFor(obj);
        if (!id.valid()) return false;
        return og.isMarkedInBlock(id, obj);
    }
};

namespace {

[[noreturn]] void censusAbort() {
    std::fflush(stderr);
    std::abort();
}

struct OEntry {
    char*    obj;
    uint32_t size;
    uint32_t hash;     // low 32 bits of hashObject
    uint64_t sig;      // wordSignature
};

struct WKey {
    const char* helper;
    uintptr_t   ret;
    bool operator==(const WKey& o) const { return helper == o.helper && ret == o.ret; }
};
struct WKeyHash {
    size_t operator()(const WKey& k) const {
        return std::hash<uintptr_t>()(k.ret) ^ (reinterpret_cast<uintptr_t>(k.helper) << 1);
    }
};

struct Census {
    std::mutex mu;
    int env_mode = -1;
    int forced_mode = -1;
    uint32_t env_sample = 16;
    uint32_t forced_sample = 0;
    uint32_t every = 64;
    bool report_registered = false;

    std::unordered_map<const OldGenSpace*, std::vector<OEntry>> tables;
    uint64_t o_recorded = 0, o_checked = 0, o_mismatched = 0, o_dropped = 0;
    uint64_t o_invalidations = 0;
    std::unordered_map<uint64_t, uint64_t> o_hits;       // censusKey -> count

    uint64_t w_calls = 0, w_violations = 0;
    std::unordered_map<WKey, uint64_t, WKeyHash> w_hits;
    std::unordered_map<WKey, uint8_t, WKeyHash> w_old;    // 1 = old-gen target seen

    std::unordered_map<uintptr_t, uint32_t> eval_id;      // EvaluatorDesc* -> id
    std::vector<uintptr_t> eval_fn;                       // id -> generic fn
};

Census& census() {
    // Leaked on purpose: must outlive every heap and still exist at atexit.
    static Census* g = [] {
        auto* c = new Census;
        const char* m = std::getenv("ECO_P1_CENSUS");
        if (m != nullptr && m[0] != '\0') {
            if (m[1] != '\0' || m[0] < '0' || m[0] > '2') {
                std::fprintf(stderr, "[p1-census] ECO_P1_CENSUS must be 0, 1 or 2\n");
                censusAbort();
            }
            c->env_mode = m[0] - '0';
        } else {
            const char* alias = std::getenv("ECO_SURVIVOR_WRITE_CENSUS");
            if (alias != nullptr && alias[0] == '1') {
                c->env_mode = 1;
            } else {
                c->env_mode = ECO_HEAP_VALIDATE ? 2 : 1;   // the tripwire in validate builds
            }
        }
        if (const char* s = std::getenv("ECO_P1_CENSUS_SAMPLE"); s && *s) {
            const unsigned long v = std::strtoul(s, nullptr, 10);
            if (v == 0 || v > 65536 || (v & (v - 1)) != 0) {
                std::fprintf(stderr, "[p1-census] ECO_P1_CENSUS_SAMPLE must be a power of two in [1, 65536]\n");
                censusAbort();
            }
            c->env_sample = static_cast<uint32_t>(v);
        }
        if (const char* e = std::getenv("ECO_P1_CENSUS_EVERY"); e && *e) {
            const unsigned long v = std::strtoul(e, nullptr, 10);
            if (v == 0) {
                std::fprintf(stderr, "[p1-census] ECO_P1_CENSUS_EVERY must be >= 1\n");
                censusAbort();
            }
            c->every = static_cast<uint32_t>(v);
        }
        return c;
    }();
    return *g;
}

inline uint64_t mix(uint64_t h, uint64_t w) {
    h = (h ^ w) * 0x9E3779B97F4A7C15ull;
    return h ^ (h >> 29);
}

// Header bits owned by the GC / the builder protocol (P§3.3).
uint64_t gcHeaderMask() {
    static const uint64_t mask = [] {
        Header h;
        std::memset(&h, 0, sizeof h);
        h.color = 3;
        h.age = 3;
        h.builder = 1;
        uint64_t m;
        std::memcpy(&m, &h, 8);
        return m;
    }();
    return mask;
}

inline uint64_t loadWord(const char* obj, size_t i) {
    uint64_t w;
    std::memcpy(&w, obj + 8 * i, 8);
    if (i == 0) w &= ~gcHeaderMask();
    return w;
}

inline bool sampled(const void* p, uint32_t s) {
    if (s <= 1) return true;
    const uint64_t a = reinterpret_cast<uintptr_t>(p) >> 3;
    return ((a * 0x9E3779B97F4A7C15ull) >> 40 & (s - 1)) == 0;
}

inline uint64_t censusKey(int tag, uint32_t sub, uint16_t word) {
    return (static_cast<uint64_t>(tag & 0xFF) << 48) |
           (static_cast<uint64_t>(sub) << 16) | word;
}

uint32_t subKeyLocked(Census& g, const char* obj) {
    const Header* h = reinterpret_cast<const Header*>(obj);
    if (h->tag == Tag_Custom) {
        return static_cast<uint32_t>(reinterpret_cast<const Custom*>(obj)->ctor);
    }
    if (h->tag == Tag_Closure) {
        const Closure* c = reinterpret_cast<const Closure*>(obj);
        const uintptr_t desc = reinterpret_cast<uintptr_t>(c->evaluator);
        auto it = g.eval_id.find(desc);
        if (it == g.eval_id.end()) {
            const uint32_t id = static_cast<uint32_t>(g.eval_fn.size());
            g.eval_fn.push_back(c->evaluator
                ? reinterpret_cast<uintptr_t>(c->evaluator->generic) : 0);
            it = g.eval_id.emplace(desc, id).first;
        }
        return it->second;
    }
    return 0;
}

const char* symbolFor(uintptr_t addr, char* buf, size_t n) {
    Dl_info info{};
    if (addr && dladdr(reinterpret_cast<void*>(addr), &info) && info.dli_sname) {
        std::snprintf(buf, n, "%s+0x%lx", info.dli_sname,
                      (unsigned long)(addr - reinterpret_cast<uintptr_t>(info.dli_saddr)));
    } else {
        std::snprintf(buf, n, "?");
    }
    return buf;
}

void verifyTableLocked(Census& g, std::vector<OEntry>& t, const char* where) {
    const int m = mode();
    for (OEntry& e : t) {
        g.o_checked++;
        const uint64_t h = hashObject(e.obj, e.size);
        if (static_cast<uint32_t>(h) == e.hash) continue;
        g.o_mismatched++;
        const uint64_t sig = wordSignature(e.obj, e.size);
        uint16_t word = 0xFFFF;
        for (uint16_t i = 0; i < 8 && 8u * i < e.size; ++i) {
            if (((sig ^ e.sig) >> (8 * i)) & 0xFF) { word = i; break; }
        }
        const Header* hdr = reinterpret_cast<const Header*>(e.obj);
        const int tag = static_cast<int>(hdr->tag);
        g.o_hits[censusKey(tag, subKeyLocked(g, e.obj), word)]++;
        if (m == 2) {
            std::fprintf(stderr,
                "[p1-census] VIOLATION (old gen, %s): object %p tag=%s size=%u "
                "first-differing-word=%d was written after promotion (HEAP_SNAPSHOT_001)\n",
                where, static_cast<void*>(e.obj), gcTagName(tag), e.size,
                word == 0xFFFF ? -1 : static_cast<int>(word));
            censusAbort();
        }
        e.hash = static_cast<uint32_t>(h);   // count one write once
        e.sig = sig;
    }
}

void printSummaryLocked(Census& g, FILE* f, uint64_t minors) {
    size_t entries = 0;
    for (auto& kv : g.tables) entries += kv.second.size();
    std::fprintf(f,
        "[p1-census] minors=%llu O: entries=%zu recorded=%llu checked=%llu mismatched=%llu "
        "dropped=%llu invalidations=%llu W: calls=%llu violations=%llu\n",
        (unsigned long long)minors, entries, (unsigned long long)g.o_recorded,
        (unsigned long long)g.o_checked, (unsigned long long)g.o_mismatched,
        (unsigned long long)g.o_dropped, (unsigned long long)g.o_invalidations,
        (unsigned long long)g.w_calls, (unsigned long long)g.w_violations);
}

void printTablesLocked(Census& g, FILE* f) {
    printSummaryLocked(g, f, 0);
    std::vector<std::pair<uint64_t, uint64_t>> rows(g.o_hits.begin(), g.o_hits.end());
    std::sort(rows.begin(), rows.end(),
              [](const auto& a, const auto& b) { return a.second > b.second; });
    for (size_t i = 0; i < rows.size() && i < 50; ++i) {
        const uint64_t key = rows[i].first;
        const int tag = static_cast<int>(key >> 48);
        const uint32_t sub = static_cast<uint32_t>((key >> 16) & 0xFFFFFFFFu);
        const uint16_t word = static_cast<uint16_t>(key & 0xFFFF);
        char sym[256] = "-";
        if (tag == Tag_Closure && sub < g.eval_fn.size()) symbolFor(g.eval_fn[sub], sym, sizeof sym);
        std::fprintf(f, "[p1-census]   O tag=%s sub=%u %s word=%d count=%llu\n",
                     gcTagName(tag), (unsigned)sub, sym,
                     word == 0xFFFF ? -1 : static_cast<int>(word),
                     (unsigned long long)rows[i].second);
    }
    for (const auto& kv : g.w_hits) {
        char sym[256];
        std::fprintf(f, "[p1-census]   W helper=%s site=%s%s count=%llu\n", kv.first.helper,
                     symbolFor(kv.first.ret, sym, sizeof sym),
                     g.w_old.count(kv.first) ? " (old-gen target)" : "",
                     (unsigned long long)kv.second);
    }
    std::fprintf(f, "[p1-census] anchor eco_alloc_custom=0x%lx\n",
                 (unsigned long)reinterpret_cast<uintptr_t>(&eco_alloc_custom));
}

void atexitReport() {
    Census& g = census();
    {
        std::lock_guard<std::mutex> lk(g.mu);
        for (auto& kv : g.tables) verifyTableLocked(g, kv.second, "exit");
        if (mode() != 0) printTablesLocked(g, stderr);
    }
    std::fflush(stderr);
}

void registerReportLocked(Census& g) {
    if (!g.report_registered) {
        g.report_registered = true;
        std::atexit(atexitReport);
    }
}

}  // namespace

int mode() {
    Census& g = census();
    return g.forced_mode >= 0 ? g.forced_mode : g.env_mode;
}

void setModeForTesting(int m) { census().forced_mode = m; }

uint32_t sample() {
    Census& g = census();
    return g.forced_sample ? g.forced_sample : g.env_sample;
}

void setSampleForTesting(uint32_t s) { census().forced_sample = s; }

uint32_t every() { return census().every; }

uint64_t hashObject(const char* obj, size_t size) {
    uint64_t h = 0xcbf29ce484222325ull ^ size;
    const size_t n = size / 8;
    for (size_t i = 0; i < n; ++i) h = mix(h, loadWord(obj, i));
    return h;
}

uint64_t wordSignature(const char* obj, size_t size) {
    // One byte per word for the first 8 words (a collision hides a changed
    // word 1 time in 256; typical objects are 2-4 words).
    uint64_t sig = 0;
    const size_t n = std::min<size_t>(size / 8, 8);
    for (size_t i = 0; i < n; ++i) {
        const uint64_t hw = mix(0x51ED270B27B1A3C5ull + i, loadWord(obj, i));
        sig |= (hw & 0xFF) << (8 * i);
    }
    return sig;
}

void recordPromoted(const OldGenSpace* og, const std::vector<void*>& promoted) {
    if (mode() == 0 || promoted.empty()) return;
    Census& g = census();
    const uint32_t s = sample();
    std::lock_guard<std::mutex> lk(g.mu);
    registerReportLocked(g);
    std::vector<OEntry>& t = g.tables[og];
    for (void* p : promoted) {
        if (!sampled(p, s)) continue;
        const char* obj = static_cast<const char*>(p);
        if (reinterpret_cast<const Header*>(obj)->builder) continue;   // never promoted anyway
        const size_t size = getObjectSize(p);
        if (size == 0 || size > UINT32_MAX) continue;
        t.push_back(OEntry{static_cast<char*>(p), static_cast<uint32_t>(size),
                           static_cast<uint32_t>(hashObject(obj, size)),
                           wordSignature(obj, size)});
        g.o_recorded++;
    }
}

void onMarkEnd(const OldGenSpace& og) {
    if (mode() == 0) return;
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    auto it = g.tables.find(&og);
    if (it == g.tables.end()) return;
    std::vector<OEntry>& t = it->second;
    size_t w = 0;
    for (size_t r = 0; r < t.size(); ++r) {
        if (P1CensusAccess::markedNow(og, t[r].obj)) t[w++] = t[r];
        else g.o_dropped++;
    }
    t.resize(w);
}

void verifyOldGen(const OldGenSpace& og, const char* where) {
    if (mode() == 0) return;
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    auto it = g.tables.find(&og);
    if (it == g.tables.end()) return;
    verifyTableLocked(g, it->second, where);
}

void onMinorStart(const OldGenSpace& og, uint64_t minor_count) {
    if (mode() == 0) return;
    Census& g = census();
    if (minor_count == 0 || minor_count % g.every != 0) return;
    std::lock_guard<std::mutex> lk(g.mu);
    auto it = g.tables.find(&og);
    if (it != g.tables.end()) verifyTableLocked(g, it->second, "periodic");
    if (mode() == 1) printSummaryLocked(g, stderr, minor_count);
}

void invalidate(const OldGenSpace& og) {
    if (mode() == 0) return;
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    auto it = g.tables.find(&og);
    if (it == g.tables.end()) return;
    if (!it->second.empty()) g.o_invalidations++;
    it->second.clear();
}

void forget(const OldGenSpace& og) {
    if (mode() == 0) return;
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    auto it = g.tables.find(&og);
    if (it == g.tables.end()) return;
    verifyTableLocked(g, it->second, "heap-destroyed");
    g.tables.erase(it);
}

__attribute__((noinline)) void noteWrite(void* obj, const char* helper) {
    if (obj == nullptr || mode() == 0) return;
    const uintptr_t ret = reinterpret_cast<uintptr_t>(__builtin_return_address(0));
    const Header* h = reinterpret_cast<const Header*>(obj);
    if (h->builder) {
        census().w_calls++;   // racy only across mutator threads; stats
        return;
    }
    Allocator& A = Allocator::instance();
    const bool in_nursery = A.isInNursery(obj);
    // threaded-gc-04b HEAP_062: a young large object is judged like a
    // nursery object — a write is a violation once it has survived a minor.
    // Any other old-gen target is a violation.
    ThreadLocalHeap* tlh = A.getCurrentThreadHeap();
    const bool young_large =
        !in_nursery && tlh != nullptr && tlh->getOldGen().isYoungLarge(obj);
    const bool violation = (in_nursery || young_large) ? h->age >= 1 : true;
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    g.w_calls++;
    if (!violation) return;
    registerReportLocked(g);
    g.w_violations++;
    const WKey k{helper, ret};
    g.w_hits[k]++;
    if (!in_nursery) g.w_old[k] = 1;
    if (mode() == 2) {
        char sym[256];
        std::fprintf(stderr,
            "[p1-census] VIOLATION (write site): %s at %s wrote into %s object %p "
            "tag=%s age=%u (HEAP_SNAPSHOT_001)\n",
            helper, symbolFor(ret, sym, sizeof sym),
            in_nursery ? "an aged nursery" : young_large ? "an aged young large" : "an old-gen",
            obj, gcTagName(static_cast<int>(h->tag)), static_cast<unsigned>(h->age));
        censusAbort();
    }
}

void reportNow() {
    if (mode() == 0) return;
    Census& g = census();
    if (!g.mu.try_lock()) {
        std::fprintf(stderr, "[p1-census] report skipped: census busy\n");
        return;
    }
    printTablesLocked(g, stderr);
    g.mu.unlock();
    nurseryCensusReport(/*from_signal=*/true);
    std::fflush(stderr);
}

Counts countsForTesting() {
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    Counts c{};
    c.o_recorded = g.o_recorded;
    c.o_checked = g.o_checked;
    c.o_mismatched = g.o_mismatched;
    c.o_dropped = g.o_dropped;
    c.o_invalidations = g.o_invalidations;
    for (auto& kv : g.tables) c.o_entries += kv.second.size();
    c.w_calls = g.w_calls;
    c.w_violations = g.w_violations;
    return c;
}

uint64_t oHitsForTesting(int tag, uint32_t sub, uint16_t word) {
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    auto it = g.o_hits.find(censusKey(tag, sub, word));
    return it == g.o_hits.end() ? 0 : it->second;
}

uint64_t wViolationsForTesting(const char* helper) {
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    uint64_t n = 0;
    for (const auto& kv : g.w_hits) {
        if (std::strcmp(kv.first.helper, helper) == 0) n += kv.second;
    }
    return n;
}

void resetForTesting() {
    Census& g = census();
    std::lock_guard<std::mutex> lk(g.mu);
    g.tables.clear();
    g.o_recorded = g.o_checked = g.o_mismatched = g.o_dropped = g.o_invalidations = 0;
    g.o_hits.clear();
    g.w_calls = g.w_violations = 0;
    g.w_hits.clear();
    g.w_old.clear();
}

} // namespace p1
} // namespace Elm

#endif  // P1_CENSUS_COMPILED
