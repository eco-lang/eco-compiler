// W5: claim -> copy -> publish on a header word (phase 6) and on a shadow word
// (7c) (plans/threaded-gc-tla-W-weak-memory.md §9). One case per compile:
//   -DW5_CASE='a'  phase 6: two workers evacuate one from-space object
//   -DW5_CASE='b'  7c: the REAL exact engine (SerialEngine::tenure, no claim)
//                  on the collector, then the gang join, then help (the claim
//                  protocol) on the mutator, over STALE shadow entries
//   -DW5_CASE='p'  7c L3: two members run the claim protocol on one object
//                  concurrently; after their join, help runs it too
//                  (w5_parallel_tenure)
//
// Real code: mw::loadHeader / claim / publish / waitPublished / fwdWord /
// fwdAddr (MinorWork.hpp) and tw::ref / fwdOf / make / claim / publish /
// waitPublished (TenureWork.hpp), SerialEngine<Env>::tenure. Copies (canary
// regions, §11): evac = evacuateP's claim loop (NurseryParallel.cpp:332-341)
// with copyClaimed's copy-then-publish (:250-311); helpTenure =
// TenureParEnv::tenure (NurseryTenure.cpp:969-1003); the join (a WMutex in
// place of GCBackgroundGang's std::mutex and condition variable,
// GCHelperPool.cpp:590-595, 622-625).
//
// The copied claim loops are written with their bound (three iterations cover
// claim, BUSY wait, read-through), and these rows run with -disable-spin-assume.
// With the code's own `for (;;)` and GenMC's spin-assume on, GenMC cuts the
// iteration after a failed claim (it has no side effect) before the retry reads
// through the forward, and W5_RELAXED_CLAIM_FAIL passes silently (checked
// 2026-09-28, test/genmc/AUDIT.md).
#include <atomic>
#include "MinorWork.hpp"
#include "TenureWork.hpp"
#include "wdriver.hpp"               // last: it redefines assert

namespace mw = Elm::minorwork;
namespace tw = Elm::tenurework;

#ifndef W5_CASE
#define W5_CASE 'a'
#endif

struct Obj { uint64_t header; uint64_t f1, f2; };   // header = the 8-byte header word
// Word-wise plain copies: the code's memcpy is a plain bulk write, the same for
// happens-before and races (§7.6).
static void copyObj(Obj* d, const Obj* s) { d->header = s->header; d->f1 = s->f1; d->f2 = s->f2; }
static void setObj(Obj* d, uint64_t h, uint64_t a, uint64_t b) { d->header = h; d->f1 = a; d->f2 = b; }
// Heap objects (forward words and shadow entries keep address bits 3..42, so
// statics, which GenMC places at 2^63 and above, cannot be forwarding targets).
#if defined(WDRIVER_GENMC)
static void* lowAlloc(size_t bytes) { return ::operator new(bytes); }   // GenMC: heap < 2^40
#else
// Native smoke runs: glibc's heap of a PIE binary lies near 2^46, so take the
// objects from an arena mapped below 2^43, as the runtime's heap is.
#include <sys/mman.h>
static void* lowAlloc(size_t bytes) {
    static char* arena = nullptr;
    static size_t used = 0;
    if (arena == nullptr) {
        void* p = mmap(reinterpret_cast<void*>(uintptr_t{1} << 36), 1 << 16, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
        assert(p != MAP_FAILED);
        arena = static_cast<char*>(p);
    }
    void* r = arena + used;
    used += (bytes + 15) & ~size_t{15};
    return r;
}
#endif
static Obj* objs(size_t n) {
    Obj* o = static_cast<Obj*>(lowAlloc(n * sizeof(Obj)));
    for (size_t i = 0; i < n; ++i) setObj(&o[i], 0, 0, 0);
    return o;
}

// ---- (a) phase 6: two workers evacuate one from-space object ----
static Obj* from;
static Obj* copies;
static int copied[2];

static void* evac(void* arg) {                       // evacuateP (NurseryParallel.cpp:332-341)
    const int me = intOf(arg);
    uint64_t hw = mw::loadHeader(from);
    for (int it = 0;; ++it) {
        assert(it < 3);                              // claim, BUSY wait, read-through
        if (mw::isForwardWord(hw)) {
            if (hw == mw::kBusy) { hw = mw::waitPublished(from, prunePause); continue; }
            const Obj* d = reinterpret_cast<const Obj*>(mw::fwdAddr(hw));
            assert(d->f1 == 11 && d->f2 == 22);      // the documented contract: read through
            return nullptr;
        }
        if (mw::claim(from, hw)) break;
    }
    Obj& dst = copies[me];                           // copyClaimed (:250-311): plain body,
    dst.f1 = from->f1;                               // then the header from the SAVED word
    dst.f2 = from->f2;
    dst.header = hw;
    copied[me] = 1;
    mw::publish(from, &dst, mw::colorOf(hw));
    return nullptr;
}

// ---- (b), (p) 7c ----
static const uint32_t kGen = 2;
static Obj *tA, *tB;                                 // tenuring objects
static Obj *gA, *gB;                                 // grant cells ([0] collector / member 0, [1] help / member 1)
static uint64_t sh[2];                               // shadow words, set in main
static WMutex gang_m;                                // GCBackgroundGang::m_
static int finished;                                 // GCBackgroundGang::finished_ (under gang_m)
static std::atomic<int> finished_pub{0};             // GCBackgroundGang::finished_pub_
static int copiesCol, copiesHelpA, copiesHelpB;      // one writer each
static int copiesMember[2];

struct CollectorEnv {                                // the Env SerialEngine::tenure needs
    uint64_t* shadow(const void* o) const { return &sh[o == tA ? 0 : 1]; }
    uint32_t gen() const { return kGen; }
    size_t sizeOf(const void*) const { return sizeof(Obj); }
    void* copy(const void* o, size_t) {
        Obj* d = (o == tA) ? &gA[0] : &gB[0];
        copyObj(d, static_cast<const Obj*>(o));
        ++copiesCol;
        return d;
    }
};

static void* collector(void*) {                      // tenureEntry -> runJobExact, one item
    tw::SerialState st;
    CollectorEnv env;
    tw::SerialEngine<CollectorEnv> eng(st, env);
    (void)eng.tenure(tA, /*push=*/false);            // TenureWork.hpp:248-268
    gang_m.lock();                                   // memberLoop's finish, GCHelperPool.cpp:590-595
    ++finished;
    finished_pub.store(finished, std::memory_order_release);
    gang_m.unlock();
    return nullptr;
}

// TenureParEnv::tenure (NurseryTenure.cpp:969-1003): acquire load, BUSY wait,
// claim from the OBSERVED word, copy, release publish. Returns 1 if it copied.
static int helpTenure(uint64_t* w, const Obj* src, Obj* dst) {
    uint64_t e = tw::ref(w).load(std::memory_order_acquire);
    for (int it = 0;; ++it) {
        assert(it < 3);                              // claim, BUSY wait, read-through
        if (const char* d = tw::fwdOf(e, kGen)) {
            const Obj* o = reinterpret_cast<const Obj*>(d);
            assert(o->f1 == src->f1 && o->f2 == src->f2);   // read through (post-join readers do)
            return 0;
        }
        if (tw::genOf(e) == kGen && tw::stateOf(e) == tw::kStateBusy) {
            e = tw::waitPublished(w, kGen, prunePause);
            continue;
        }
        if (tw::claim(w, e, kGen)) break;            // CAS from the OBSERVED (stale) word: trap 11
    }
    copyObj(dst, src);
    tw::publish(w, dst, kGen);
    return 1;
}

static void* mutator(void*) {                        // tenureJoin: join, then help
#ifdef MUTANT_W5_HELP_WITHOUT_JOIN
    VERIFIER_ASSUME(finished_pub.load(std::memory_order_relaxed) == 1);   // no mutex, no acquire
#else
    gang_m.lock();                                   // joinLocked: cv_done_.wait(finished_ >= members)
    gang_m.await([] { return finished == 1; });
    gang_m.unlock();
#endif
    copiesHelpA = helpTenure(&sh[0], tA, &gA[1]);
    copiesHelpB = helpTenure(&sh[1], tB, &gB[1]);
    return nullptr;
}

static void* member(void* arg) {                     // an L3 member (TenureParEnv::tenure)
    const int me = intOf(arg);
    copiesMember[me] = helpTenure(&sh[0], tA, &gA[me]);
    return nullptr;
}

int main() {
    from = objs(1);
    copies = objs(2);
    tA = objs(1);
    tB = objs(1);
    gA = objs(2);
    gB = objs(2);
    // The encodings keep address bits 3..42 only: fail loudly, not spuriously,
    // if the tool's heap addresses do not fit (§4.2 step 2).
    assert(mw::fwdAddr(mw::fwdWord(copies, 0)) == reinterpret_cast<char*>(copies));
    assert(mw::fwdAddr(mw::fwdWord(&copies[1], 0)) == reinterpret_cast<char*>(&copies[1]));
    assert(tw::addrOf(tw::make(gA, tw::kStateFwd, kGen)) == reinterpret_cast<char*>(gA));
    assert(tw::addrOf(tw::make(&gB[1], tw::kStateFwd, kGen)) == reinterpret_cast<char*>(&gB[1]));

    if (W5_CASE == 'a') {
        setObj(from, /*tag Cons=*/3, 11, 22);
        wthread a = spawn(evac, argOf(0)), b = spawn(evac, argOf(1));
        join(a);
        join(b);
        assert(copied[0] + copied[1] == 1);          // exactly one copy
    } else if (W5_CASE == 'b') {
        setObj(tA, 3, 1, 2);
        setObj(tB, 3, 3, 4);
        sh[0] = tw::make(&gA[1], tw::kStateFwd, /*stale gen*/ 1);
        sh[1] = tw::make(&gB[0], tw::kStateFwd, /*stale gen*/ 1);
        wthread c = spawn(collector), m = spawn(mutator);
        join(c);
        join(m);
        assert(copiesCol + copiesHelpA == 1);        // A tenured once (no double tenure)
        assert(copiesHelpB == 1);                    // B claimed from its stale entry
    } else {
        setObj(tA, 3, 5, 6);
        sh[0] = tw::make(&gB[1], tw::kStateFwd, /*stale gen*/ 1);
        wthread x = spawn(member, argOf(0)), y = spawn(member, argOf(1));
        join(x);                                     // tenureJoin: stopAndJoin, then help
        join(y);
        const int help = helpTenure(&sh[0], tA, &gB[0]);
        assert(copiesMember[0] + copiesMember[1] == 1 && help == 0);
    }
    return 0;
}
