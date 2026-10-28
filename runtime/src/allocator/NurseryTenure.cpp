// The region nursery's tenure job: how it is launched, run, joined and merged.
//
// A region minor collection that hands an extent over (the hand-over pause) ends by building one tenure job, in
// `tenureLaunch`. The job copies into the old generation every object of the Tenuring extent reached from its
// inputs: the start objects the pause recorded, and the targets of the heal slots, which are slots of other
// objects that point into the extent. Where each object went is recorded off the object, in the extent's shadow
// (TenureWork.hpp). The job's results reach the heap only at the merge, `mergeJob`, at the next `tenureJoin`.
//
// Three engines run a job, over the same state:
//   - the exact engine (`runJobExact`): TenureWork's serial engine on one thread, allocating only from the
//     job's grant, the old-generation space reserved for it at launch. It can be stopped and resumed;
//   - the pause-only parallel engine (`runJobParallel`): the minor's gang, allocating through the old
//     generation's promotion context, which is legal only while the mutator is stopped. Any unused grant is
//     returned first, and copies the exact engine already made stay where they are. Where each copy lands
//     depends on the schedule; which objects are promoted does not;
//   - the concurrent parallel engine (`tenureConcLaunch`, `tenureConcEntry`, `tenureConcFinish`): several
//     members of the tenure collector sharing the grant while the mutator runs. A stop leaves the unscanned work
//     in the members' deques, and the join drains it in the pause.
// The two parallel engines claim objects through the shadow (`claim`, `waitPublished`, `publish`), so two
// copiers never copy one object.
//
// `tenureLaunch` picks the engine. With `tenure_mode` 1 the job finishes in the hand-over pause: in parallel when
// it has more than one pause thread (`tenure_sync_threads`, or the minor's thread count when that is 0) or the
// grant fails, and otherwise exactly. With mode 2 it runs on the collector: the exact engine on member 0, or the
// concurrent engine when the collector has more than one member, the extent holds at least
// `minor_parallel_min_bytes` of objects and there is no ageing mark. A failed grant runs it in the pause instead,
// on up to `minorThreads()` threads. `tenureJoin` waits for a running job, or stops it and finishes it in the pause,
// and then merges it.
//
// When survivors age for more than one minor, the job also marks the ageing extents and sweeps the unmarked
// memory into zap spans (TenureWork.hpp), which the merge covers with fillers. `finishJobMarkPhases` runs that mark
// and sweep on the gang.

#include "NurserySpace.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Allocator.hpp"
#include "GCHelperPool.hpp"
#include "NurseryChildWalk.hpp"
#include "OldGenSpace.hpp"
#include "TlaTrace.hpp"   // trace hooks; they compile to nothing outside a trace build

namespace Elm {

namespace tw = tenurework;
namespace mk = markwork;
using region::TenureJob;

namespace {

/// Prints `what` with two addresses and two numbers that identify the failure to stderr, and aborts.
[[noreturn]] void tenureFatal(const char* what, const void* a = nullptr, const void* b = nullptr,
                              uint64_t x = 0, uint64_t y = 0) {
    std::fprintf(stderr, "[gc] FATAL: tenure: %s (%p %p %llu %llu)\n", what, a, b,
                 (unsigned long long)x, (unsigned long long)y);
    std::fflush(stderr);
    std::abort();
}

/// Returns the steady clock's time in nanoseconds.
inline uint64_t nowNs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

}  // namespace

// TLA-REGION(NT.TenureHeapEnv) begin
/// The heap side of the exact engine: the `Env` that `tenurework::SerialEngine` requires, over the job `J` and the
/// old generation `og`.
///
/// Each member function is the operation of the same name that `SerialEngine` describes; only what is particular
/// here is commented. The ranges it tests are the job's own copies, taken at launch. It allocates only from the
/// job's grant. Both references must outlive the Env.
struct NurserySpace::TenureHeapEnv {
    TenureJob& J;
    OldGenSpace& og;
    std::vector<uintptr_t>* layout;   ///< If not null, receives the address of every copy, for tests.

    void* target(uint64_t w) const {
        HPointer hp;
        std::memcpy(&hp, &w, sizeof(hp));
        if (hp.ptr_ind != 0 || hp.ptr == 0) return nullptr;
        return Allocator::fromPointerRaw(hp);
    }
    uint64_t word(const void* obj) const {
        const HPointer hp = Allocator::toPointerRaw(const_cast<void*>(obj));
        uint64_t w;
        std::memcpy(&w, &hp, sizeof(w));
        return w;
    }
    bool inTenuring(const void* p) const {
        const char* q = static_cast<const char*>(p);
        return q >= J.base && q < J.surv_top;
    }
    bool ylosMaybe(const void* p) const {
        const char* q = static_cast<const char*>(p);
        return q >= J.ylos_lo && q < J.ylos_hi;
    }
    bool youngElsewhere(const void* p) const {
        const char* q = static_cast<const char*>(p);
        return q >= J.slot_lo && q < J.slot_hi;
    }
    uint64_t* shadow(const void* obj) const {
        return J.shadow + (static_cast<size_t>(static_cast<const char*>(obj) - J.base) >> J.shadow_shift);
    }
    uint32_t gen() const { return J.gen; }
    size_t sizeOf(const void* obj) const { return getObjectSize(const_cast<void*>(obj)); }
    void* copy(const void* obj, size_t size) {
        const size_t cls = OldGenSpace::sizeClass(size);
        char* dst = static_cast<char*>(og.grantAllocate(J.grant, cls, size));
        std::memcpy(dst, obj, size);
        Header* h = getHeader(dst);
        // As in any promotion, only the age and colour of the copy change.
        h->age = 0;
        h->color = static_cast<u32>(Color::White);
        if (h->tag == Tag_LargeStringHeader || h->tag == Tag_LargeByteHeader) {
            J.lb_promoted.push_back(static_cast<LargeStringHeader*>(static_cast<void*>(dst))->body);
        }
#if ENABLE_GC_STATS
        J.copies.promotion(static_cast<Tag>(h->tag), size, h->size);
#endif
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        J.promoted_log.push_back(dst);
#endif
        if (layout) layout->push_back(reinterpret_cast<uintptr_t>(dst));
        return dst;
    }
    template <class F> void forEachChildSlot(void* obj, F&& f) {
        Elm::forEachChildSlot(obj, [&](HPointer& hp) { f(reinterpret_cast<uint64_t*>(&hp)); });
    }
    uint64_t* consTail(void* obj) const {
        Header* h = getHeader(obj);
        if (h->tag != Tag_Cons) return nullptr;
        return reinterpret_cast<uint64_t*>(&static_cast<Cons*>(obj)->tail);
    }
    uint64_t* consHead(void* obj) const {
        Header* h = getHeader(obj);
        if (h->tag != Tag_Cons || Elm::tupleFieldKind(h->unboxed, 0) != 0) return nullptr;
        return reinterpret_cast<uint64_t*>(&static_cast<Cons*>(obj)->head.p);
    }
    [[noreturn]] void abortYoungChild(const void* parent, const void* child) const {
        // Checked in every build: the child is in a part of the nursery that neither the job nor the ageing mark
        // covers.
        tenureFatal("TV6: a promoted or live ageing object has a young child outside the tenuring "
                    "and ageing extents (HEAP_005 / HEAP_BUILDER_003)", parent, child);
    }
    int ageIndex(const void* p) const {
        const char* q = static_cast<const char*>(p);
        for (int i = 0; i < J.n_age; ++i)
            if (q >= J.age[i].base && q < J.age[i].top) return i;
        return -1;
    }
    bool markAge(int i, const void* obj) const {
        const size_t g = static_cast<size_t>(static_cast<const char*>(obj) - J.age[i].base) >> 3;
        uint64_t& w = J.age[i].bits[g >> 6];
        const uint64_t m = uint64_t{1} << (g & 63);
        if (w & m) return false;
        w |= m;
        return true;
    }
    bool isMarkedAge(int i, const void* obj) const {
        const size_t g = static_cast<size_t>(static_cast<const char*>(obj) - J.age[i].base) >> 3;
        return (J.age[i].bits[g >> 6] >> (g & 63)) & 1;
    }
    char* ageBase(unsigned i) const { return J.age[i].base; }
    char* ageTop(unsigned i) const { return J.age[i].top; }
    bool ageYlosMaybe(const void* p) const {
        const char* q = static_cast<const char*>(p);
        return q >= J.age_ylos_lo && q < J.age_ylos_hi;
    }
    const uint64_t* ageBits(unsigned i) const { return J.age[i].bits; }
};
// TLA-REGION(NT.TenureHeapEnv) end

// The ageing mark run in parallel, on the old generation's gang in a pause. Mark bits are set with an atomic OR,
// and heal slots and reached hand-over YLOS objects go to per-worker lists that are appended in worker order. The
// marked set and the heal set are those of the exact engine, as sets: the heal list's order may differ.
namespace {
/// The entry kind of a marked object whose children are still to be marked.
constexpr uint32_t kAgeScan = 0;
/// The entry kind of a source recorded by the pause, not yet marked.
constexpr uint32_t kAgeStart = 1;
/// One worker's results from the parallel ageing mark: the heal slots it found, the indices of the hand-over YLOS
/// objects it reached first, and its counts.
struct AgeOut {
    std::vector<uint64_t*> heal;
    std::vector<uint32_t> ylos;
    uint64_t marked = 0, marked_bytes = 0, heal_n = 0, ylos_reached = 0;
};
}  // namespace

// TLA-REGION(NT.AgeParEnv) begin
/// The `Env` of `markwork::runMarkerLoop` for the parallel ageing mark, over the worker slots `ws[0, n)`.
///
/// The functions the marker loop requires are as `runMarkerLoop` describes. `out` holds one `AgeOut` per slot.
/// The nursery, the job, the slots and `out` must outlive the run.
struct NurserySpace::AgeParEnv {
    static constexpr bool kParallel = true;
    NurserySpace& ns;
    TenureJob& J;
    std::unique_ptr<MinorWorker>* ws;
    unsigned n;
    std::vector<AgeOut>* out;

    MinorWorker& W(unsigned i) { return *ws[i]; }
    mk::MarkerCounters& counters(unsigned i) { return W(i).ctr; }
    uint64_t takeOwn(unsigned i) {
        MinorWorker& w = W(i);
        if (w.stack.size() != w.head) {
            const uint64_t e = w.stack.back();
            w.stack.pop_back();
            w.priv.store(w.stack.size() - w.head, std::memory_order_relaxed);
            if ((++w.pops & 63) == 0) ns.publishHalfP(w);
            return e;
        }
        return w.deque.take();
    }
    uint64_t stealFrom(unsigned v) { return W(v).deque.steal(); }
    bool anyWork() {
        for (unsigned i = 0; i < n; ++i) if (!W(i).deque.emptyApprox()) return true;
        return false;
    }
    void prefetch(uint64_t) {}
    void publishAll(unsigned self) { ns.publishAllP(W(self)); }

    /// Returns the index of the ageing extent holding `p`, or -1 if none does.
    int ageIndex(const void* p) const {
        const char* q = static_cast<const char*>(p);
        for (int i = 0; i < J.n_age; ++i)
            if (q >= J.age[i].base && q < J.age[i].top) return i;
        return -1;
    }
    /// Sets the mark bit of `o` in ageing extent `i`, and returns whether this call set it.
    bool markBit(int i, const void* o) const {
        const size_t g = static_cast<size_t>(static_cast<const char*>(o) - J.age[i].base) >> 3;
        std::atomic_ref<uint64_t> w(J.age[i].bits[g >> 6]);
        const uint64_t m = uint64_t{1} << (g & 63);
        if (w.load(std::memory_order_relaxed) & m) return false;
        return (w.fetch_or(m, std::memory_order_acq_rel) & m) == 0;
    }
    /// Handles a reference to `t`, from slot `s` of `parent`, or from the pause when `parent` is null.
    ///
    /// An ageing object or ageing-generation YLOS object marked here for the first time is queued for scanning. A
    /// slot into the Tenuring extent becomes a heal slot, and a hand-over YLOS object reached here first from a
    /// parent is recorded in `o`. Aborts for a pause source that is neither in the ageing extents nor an
    /// ageing-generation YLOS object, and for a child elsewhere in the nursery's extent slots.
    void mark(MinorWorker& w, AgeOut& o, void* t, void* parent, uint64_t* s) {
        tw::SerialState& st = J.st;
        const char* q = static_cast<const char*>(t);
        const int i = ageIndex(t);
        if (i >= 0) {
            if (markBit(i, t)) {
                ++o.marked;
                o.marked_bytes += getObjectSize(t);
                ns.pushGreyP(w, mk::objEntry(t, kAgeScan));
            }
            return;
        }
        if (parent != nullptr && q >= J.base && q < J.surv_top) {
            o.heal.push_back(s);
            ++o.heal_n;
            return;
        }
        if (parent != nullptr && q >= J.ylos_lo && q < J.ylos_hi) {
            const long k = tw::ylosFind(st.ylos, t);
            if (k >= 0) {
                std::atomic_ref<uint8_t> r(st.reached[static_cast<size_t>(k)]);
                if (r.load(std::memory_order_relaxed) == 0 && r.exchange(1, std::memory_order_acq_rel) == 0) {
                    o.ylos.push_back(static_cast<uint32_t>(k));
                    ++o.ylos_reached;
                }
                return;
            }
        }
        if (q >= J.age_ylos_lo && q < J.age_ylos_hi) {
            const long k = tw::ylosFind(st.age_ylos, t);
            if (k >= 0) {
                std::atomic_ref<uint8_t> r(st.age_ylos_marked[static_cast<size_t>(k)]);
                if (r.load(std::memory_order_relaxed) == 0 && r.exchange(1, std::memory_order_acq_rel) == 0) {
                    ++o.marked;
                    o.marked_bytes += getObjectSize(t);
                    ns.pushGreyP(w, mk::objEntry(t, kAgeScan));
                }
                return;
            }
        }
        if (parent == nullptr) tenureFatal("an age source outside the ageing extents", t);
        if (q >= J.slot_lo && q < J.slot_hi)
            tenureFatal("TV6: a live ageing object has a young child outside the tenuring and ageing extents",
                        parent, t);
    }
    void scan(unsigned self, uint64_t e) {
        MinorWorker& w = W(self);
        AgeOut& o = (*out)[self];
        void* obj = mk::entryAddr(e);
        if (mk::entryField(e) == kAgeStart) { mark(w, o, obj, nullptr, nullptr); return; }
        forEachChildSlot(obj, [&](HPointer& hp) {
            if (hp.ptr_ind != 0 || hp.ptr == 0) return;
            mark(w, o, Allocator::fromPointerRaw(hp), obj, reinterpret_cast<uint64_t*>(&hp));
        });
    }
};
// TLA-REGION(NT.AgeParEnv) end

void NurserySpace::ageParEntry(void* ctx, unsigned member) {
    struct Args { AgeParEnv* env; mk::SliceControl* ctl; };
    Args* a = static_cast<Args*>(ctx);
    mk::runMarkerLoop(*a->env, member, *a->ctl);
}

void NurserySpace::finishJobMarkPhases(OldGenSpace& oldgen, unsigned n) {
    TenureJob& J = rg_->job;
    tw::SerialState& st = J.st;
    if (st.markPhasesDone()) return;
    TenureHeapEnv env{J, oldgen, nullptr};
    const uint64_t t0 = nowNs();
    gc::GCMarkGang* gang = nullptr;
    if (n > 1) {
        gang = &oldgen.ensureGang();
        n = std::min<unsigned>({n, gang->members(), static_cast<unsigned>(OldGenSpace::kMaxMinorWorkers)});
    }
    if (n <= 1) {
        tw::finishMarkPhases(st, env);
        J.busy_ns += nowNs() - t0;
        return;
    }
    // The mark: the serial state's pending work is dealt round-robin into the workers' deques.
    if (!st.age_stack.empty() || st.next_age_start < st.age_starts.size()) {
        tenureParSetup(minor_workers_, n);
        size_t rr = 0;
        for (void* o : st.age_stack) minor_workers_[rr++ % n]->deque.push(mk::objEntry(o, kAgeScan));
        for (size_t i = st.next_age_start; i < st.age_starts.size(); ++i)
            minor_workers_[rr++ % n]->deque.push(mk::objEntry(st.age_starts[i], kAgeStart));
        st.age_stack.clear();
        st.next_age_start = st.age_starts.size();
        std::vector<AgeOut> outs(n);
        AgeParEnv penv{*this, J, minor_workers_, n, &outs};
        mk::SliceControl ctl(mk::kDrainBudget, n, gang->jitterUs(), n);
        struct Args { AgeParEnv* env; mk::SliceControl* ctl; } args{&penv, &ctl};
        par_n_ = n;
        gang->run(&NurserySpace::ageParEntry, &args, n);
        par_n_ = 0;
        for (unsigned i = 0; i < n; ++i) {
            MinorWorker& w = *minor_workers_[i];
            if (w.stack.size() != w.head || !w.deque.emptyApprox())
                tenureFatal("work left in an ageing-mark worker after termination", nullptr, nullptr, i);
            w.deque.reset();
            w.resetRun();
            const AgeOut& o = outs[i];
            st.heal.insert(st.heal.end(), o.heal.begin(), o.heal.end());
            st.ylos_pending.insert(st.ylos_pending.end(), o.ylos.begin(), o.ylos.end());
            st.age_marked += o.marked;
            st.age_marked_bytes += o.marked_bytes;
            st.age_heal += o.heal_n;
            st.ylos_reached += o.ylos_reached;
        }
    }
    // The sweep: a partly swept extent is finished serially, then each remaining extent is split into n runs of
    // bitmap words, one per member. A span that crosses a chunk boundary is rebuilt when the chunks are stitched
    // in address order, so the spans are the exact engine's.
    tw::finishSweepExtent(st, env);
    struct Chunk {
        std::vector<tw::Span> spans;
        char* first = nullptr;
        char* last_end = nullptr;
    };
    static const bool check_sweep = [] {
        const char* e = std::getenv("ECO_TEST_CHECK_AGE_SWEEP");
        return (e != nullptr && e[0] == '1') || ECO_HEAP_VALIDATE;
    }();
    for (unsigned x = st.sweep_x; x < st.n_age; ++x) {
        const size_t zap0 = st.zap.size();
        char* base = J.age[x].base;
        char* top = J.age[x].top;
        const size_t words = ((static_cast<size_t>(top - base) >> 3) + 63) / 64;
        std::vector<Chunk> chunks(n);
        struct SweepCtx { char* base; const uint64_t* bits; size_t words; unsigned n; std::vector<Chunk>* c; }
            sc{base, J.age[x].bits, words, n, &chunks};
        gang->run([](void* c, unsigned m) {
            SweepCtx& s = *static_cast<SweepCtx*>(c);
            Chunk& ch = (*s.c)[m];
            const size_t w0 = s.words * m / s.n, w1 = s.words * (m + 1) / s.n;
            char* gap = nullptr;
            for (size_t w = w0; w < w1; ++w) {
                uint64_t bits = s.bits[w];
                while (bits != 0) {
                    const unsigned b = static_cast<unsigned>(__builtin_ctzll(bits));
                    bits &= bits - 1;
                    char* p = s.base + ((w * 64 + b) << 3);
                    if (gap == nullptr) ch.first = p;
                    else if (p > gap) ch.spans.push_back(tw::Span{gap, static_cast<size_t>(p - gap)});
                    gap = p + getObjectSize(p);
                }
            }
            ch.last_end = gap;
        }, &sc, n);
        char* gap = base;
        auto emit = [&](char* p, size_t bytes) {
            st.zap.push_back(tw::Span{p, bytes});
            ++st.zapped;
            st.zapped_bytes += bytes;
        };
        for (const Chunk& ch : chunks) {
            if (ch.first == nullptr) continue;
            if (ch.first > gap) emit(gap, static_cast<size_t>(ch.first - gap));
            for (const tw::Span& sp : ch.spans) emit(sp.p, sp.bytes);
            gap = ch.last_end;
        }
        if (gap < top) emit(gap, static_cast<size_t>(top - gap));
        if (check_sweep) {
            // The stitched spans must equal a serial address-order scan of the same bitmap.
            std::vector<tw::Span> ref;
            char* g = base;
            for (size_t w = 0; w < words; ++w) {
                uint64_t bits = J.age[x].bits[w];
                while (bits != 0) {
                    const unsigned b = static_cast<unsigned>(__builtin_ctzll(bits));
                    bits &= bits - 1;
                    char* p = base + ((w * 64 + b) << 3);
                    if (p > g) ref.push_back(tw::Span{g, static_cast<size_t>(p - g)});
                    g = p + getObjectSize(p);
                }
            }
            if (g < top) ref.push_back(tw::Span{g, static_cast<size_t>(top - g)});
            bool same = ref.size() == st.zap.size() - zap0;
            for (size_t i = 0; same && i < ref.size(); ++i)
                same = ref[i].p == st.zap[zap0 + i].p && ref[i].bytes == st.zap[zap0 + i].bytes;
            if (!same) tenureFatal("TVZ: the parallel ageing sweep differs from the exact scan", base, top,
                                   ref.size(), st.zap.size() - zap0);
        }
    }
    st.sweep_x = st.n_age;
    st.sweep_gap = nullptr;
    st.sweep_w = 0;
    J.busy_ns += nowNs() - t0;
    ++rg_->rs.age_par_marks;
}

// TLA-REGION(NT.runJobExact) begin
void NurserySpace::runJobExact(OldGenSpace& oldgen, const std::atomic<bool>* stop) {
    TenureJob& J = rg_->job;
    if (!J.grant.active) tenureFatal("the exact engine ran without a grant");
    J.grant_used = true;
    TenureHeapEnv env{J, oldgen, test_record_layout_ ? &J_layout_ : nullptr};
    const uint64_t t0 = nowNs();
    const tw::DrainResult r = tw::tenureDrainSerial(J.st, env, stop);
    J.busy_ns += nowNs() - t0;
    if (r == tw::DrainResult::Stopped) ++J.stops;
}
// TLA-REGION(NT.runJobExact) end

// TLA-REGION(NT.tenureEntry) begin
void NurserySpace::tenureEntry(void* ctx, unsigned member) {
    if (member != 0) return;   // a collector with several members, running a job on the exact engine
    NurserySpace* ns = static_cast<NurserySpace*>(ctx);
    TenureJob& J = ns->rg_->job;
    const uint64_t c0 = gc::GCHelperPool::threadCpuNs();
    ns->runJobExact(*ns->rg_->tenure_og, &J.stop);
    J.cpu_ns += gc::GCHelperPool::threadCpuNs() - c0;
}
// TLA-REGION(NT.tenureEntry) end

// TLA-REGION(NT.tenureLaunch) begin
void NurserySpace::tenureLaunch(OldGenSpace& oldgen) {
    if (!rg_) return;
    RegionState& R = *rg_;
    TenureJob& J = R.job;
    int t = -1;
    for (unsigned i = 0; i < R.n_surv; ++i)
        if (R.x[i].state == region::XState::Tenuring) t = static_cast<int>(i);
    if (J.state != TenureJob::State::None && J.state != TenureJob::State::Merged) {
        tenureFatal("tenureLaunch over an unmerged job", nullptr, nullptr, static_cast<uint64_t>(J.state));
    }
    if (t < 0) {                       // nothing was handed over: the pause's inputs are dropped
        R.pend_S.clear();
        R.pend_H.clear();
        R.pend_SA.clear();
        return;
    }
    if (J.x == t && J.hand_minor == R.minor_seq) return;   // already launched for this minor
    region::Extent& X = R.x[t];
#if ECO_HEAP_VALIDATE
    if (oldgen.compact_phase_ != CompactionPhase::Idle) tenureFatal("TV9: compaction in flight at a hand-over");
#endif
    // A new shadow generation makes every older entry read as unvisited. When the generation number wraps, the
    // whole shadow is cleared instead.
    X.gen = (X.gen + 1) & tw::kGenMask;
    if (X.gen == 0) {
        R.shadow[t].discard(0, R.shadow[t].committed());
        X.gen = 1;
        ++R.rs.shadow_wraps;
    }
    J.state = TenureJob::State::Built;
    J.x = t;
    J.base = X.base;
    J.surv_top = X.surv_top;
    J.gen = X.gen;
    J.shadow = R.shadow[t].data();
    J.shadow_shift = R.shadow_shift;
    J.hand_minor = R.minor_seq;
    J.slot_lo = R.set.slot_base;
    J.slot_hi = R.set.slot_base + (static_cast<size_t>(R.n_ext) << R.stride_log2);
    J.st.clearProgress();
    J.st.starts.swap(R.pend_S);
    J.st.heal.swap(R.pend_H);
    R.pend_S.clear();
    R.pend_H.clear();
    J.st.ylos = R.hand_ylos;
    J.st.reached = R.hand_ylos_reached;
    // The ageing extents are the Young extents of age 2 or more. Each gets a cleared mark bitmap.
    J.n_age = 0;
    for (unsigned i = 0; i < R.n_surv; ++i) {
        region::Extent& A = R.x[i];
        if (A.state != region::XState::Young || A.age < 2) continue;
        const size_t granules = static_cast<size_t>(A.surv_top - A.base) >> 3;
        const size_t words = (granules + 63) / 64;
        const size_t cap_words = ((R.set.capacity >> 3) + 63) / 64;
        if (A.mark_bits.size() < cap_words) A.mark_bits.resize(cap_words);
        std::fill(A.mark_bits.begin(), A.mark_bits.begin() + static_cast<std::ptrdiff_t>(words), 0);
        J.age[J.n_age++] = TenureJob::AgeRange{A.base, A.surv_top, A.mark_bits.data()};
    }
    J.st.n_age = static_cast<unsigned>(J.n_age);
    J.st.age_starts.swap(R.pend_SA);
    R.pend_SA.clear();
    J.st.age_ylos = R.age_ylos;
    J.st.age_ylos_marked.assign(J.st.age_ylos.size(), 0);
    J.age_ylos_lo = J.st.age_ylos.empty() ? nullptr : J.st.age_ylos.front().obj;
    J.age_ylos_hi = nullptr;
    for (const tw::YlosEntry& e : J.st.age_ylos) if (e.end > J.age_ylos_hi) J.age_ylos_hi = e.end;
    // The job scans only the hand-over YLOS objects it reaches itself; those the pause reached were scanned by
    // the pause, which put what they point to among the starts.
    J.ylos_lo = J.st.ylos.empty() ? nullptr : J.st.ylos.front().obj;
    J.ylos_hi = nullptr;
    for (const tw::YlosEntry& e : J.st.ylos) if (e.end > J.ylos_hi) J.ylos_hi = e.end;
    J.st.fifo = config_->tenure_fifo_order;
    J.st.test_skip_start_every = test_tenure_skip_start_every_;
    J.st.test_stop_after = test_tenure_force_stop_after_;
    J.st.test_sleep_us_per_item = test_tenure_sleep_us_;
    J.lb_promoted.clear();
#if ENABLE_GC_STATS
    J.copies.reset();
#endif
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    J.promoted_log.clear();
#endif
    J.busy_ns = J.cpu_ns = 0;
    J.stops = 0;
    J.grant_used = J.parallel_used = false;
    J.stop.store(false, std::memory_order_relaxed);
    J_layout_.clear();
    R.tenure_og = &oldgen;
    ++R.rs.jobs;
#if ECO_TLA_TRACE_ENABLED
    // Trace event: the job's extent, generation, number of distinct starts and of heal slots, and its engine.
    auto tla_launch = [&](const char* path) {
        std::vector<void*> ds(J.st.starts.begin(), J.st.starts.end());
        std::sort(ds.begin(), ds.end());
        ds.erase(std::unique(ds.begin(), ds.end()), ds.end());
        ECO_TLA_TRACE("tj.launch", "x", t, "gen", X.gen, "starts", ds.size(), "heal", J.st.heal.size(),
                      "path", path);
    };
#endif

    const bool mode2 = config_->tenure_mode == 2;
    const unsigned sync_n = config_->tenure_sync_threads == 0 ? oldgen.minorThreads()
                                                             : config_->tenure_sync_threads;
    if (!mode2 && sync_n > 1) {
        ECO_TLA_TRACE_ONLY(tla_launch("syncpar");)
        runJobParallel(oldgen, sync_n);
        J.state = TenureJob::State::Done;
        ++R.rs.sync_parallel_jobs;
        return;
    }
    // The concurrent engine is used only for an extent of at least `minor_parallel_min_bytes`; for a smaller one,
    // waking B threads costs more than the work.
    const unsigned B = config_->tenure_collector_threads;
    // A job that has an ageing mark runs on the exact engine, never on the concurrent one.
    const bool aged = R.tenure_age > 1;
    if (aged && mode2 && B > 1) ++R.rs.age_forced_exact;
    const bool conc_par = !aged && mode2 && B > 1 && X.obj_bytes >= config_->minor_parallel_min_bytes;
    // The concurrent engine's grant has slack for one chunk per size class for each participant that may hold a
    // partly used one: the B members, and the helpers that may finish the job in the pause.
    const unsigned help_w = std::max<unsigned>(
        B, std::max<unsigned>(oldgen.minorThreads(), config_->tenure_help_threads));
    const bool granted = oldgen.grantTenure(X.class_count, J.grant, conc_par ? help_w : 0);
    R.rs.grant_blocks += J.grant.block_count;
    R.rs.grant_cells += J.grant.granted_cells;
    R.rs.grant_virgin += J.grant.virgin_blocks;
    if (!granted) {
        // The old generation cannot reserve enough for the whole extent, so the job runs now, in the pause, on the
        // parallel engine, which allocates through the promotion context instead. The partial grant is returned there.
        ++R.rs.grant_fallbacks;
        ECO_TLA_TRACE_ONLY(tla_launch("fallback");)
        runJobParallel(oldgen, std::max(1u, oldgen.minorThreads()));
        J.state = TenureJob::State::Done;
        return;
    }
    if (!mode2) {
        ECO_TLA_TRACE_ONLY(tla_launch("sync");)
        runJobExact(oldgen, nullptr);
        if (!J.st.done()) runJobExact(oldgen, nullptr);   // a forced test stop: finish it
        J.state = TenureJob::State::Done;
        return;
    }
    if (!R.collector) {
        gc::GCBackgroundGang::Options o;
        o.members = B;
        o.name = "eco-tenure";
        o.priority = config_->tenure_priority;
        o.jitter_us = allocator_ ? allocator_->helperJitterUs() : 0;
        R.collector = std::make_unique<gc::GCBackgroundGang>(o);
    }
    if (conc_par) {
        ECO_TLA_TRACE_ONLY(tla_launch("l3");)
        tenureConcLaunch(oldgen, B);
        return;
    }
    J.state = TenureJob::State::Running;
    ECO_TLA_TRACE_ONLY(tla_launch("exact");)
    // The collector refuses the launch while a fork's prepare handler holds it. The job then stays Running with
    // no member running it, and `tenureJoin` finishes it.
    if (!R.collector->launch(&NurserySpace::tenureEntry, this, &J.stop)) ++R.rs.fork_refusals;
}
// TLA-REGION(NT.tenureLaunch) end

// TLA-REGION(NT.tenureJoin) begin
void NurserySpace::tenureJoin(OldGenSpace& oldgen, int why, MinorGCRecord* rec) {
    if (!rg_) return;
    RegionState& R = *rg_;
    TenureJob& J = R.job;
    if (J.state == TenureJob::State::None || J.state == TenureJob::State::Merged) return;
    const uint64_t tj0 = nowNs();
    if (J.state == TenureJob::State::Running && J.conc_parallel) {
        // The concurrent engine: wait for its members, or stop them and drain what is left in their deques in the
        // pause.
        gc::GCBackgroundGang* g = R.collector.get();
        if (g != nullptr && g->running()) {
            const uint64_t t0 = nowNs();
            if (config_->tenure_help == 0 || g->finishedApprox()) {
                g->join();
            } else {
                g->stopAndJoin();
                ++R.rs.late;
                if (rec) rec->rg_late = 1;
            }
            R.rs.wait_ns += nowNs() - t0;
            if (rec) rec->rg_wait_ns += nowNs() - t0;
        }
        if (!tenure_ctl_->done()) {
            ECO_TLA_TRACE("tj.help", "engine", "l3", "why", why);   // trace event: help in the pause
            const uint64_t t0 = nowNs();
            const unsigned hn = config_->tenure_help_threads == 0 ? oldgen.minorThreads()
                                                                 : config_->tenure_help_threads;
            tenureConcFinish(oldgen, hn, /*on_this_thread=*/why == 2 || hn <= 1);
            ++R.rs.stops;
            R.rs.help_workers_sum += hn;
            R.rs.help_ns += nowNs() - t0;
            if (rec) { rec->rg_help_workers = hn; rec->rg_help_ns += nowNs() - t0; }
        } else {
            tenureConcFinish(oldgen, 1, true);
        }
        J.state = TenureJob::State::Done;
    }
    if (J.state == TenureJob::State::Running) {
        gc::GCBackgroundGang* g = R.collector.get();
        bool finish_here = false;
        if (g == nullptr || !g->running()) {
            finish_here = !J.st.done();       // the launch was refused, or no member is running: as if stopped
        } else if (config_->tenure_help == 0) {
            const uint64_t t0 = nowNs();
            g->join();
            R.rs.wait_ns += nowNs() - t0;
            if (rec) rec->rg_wait_ns += nowNs() - t0;
        } else if (g->finishedApprox()) {
            g->join();
        } else {
            const uint64_t t0 = nowNs();
            g->stopAndJoin();
            R.rs.wait_ns += nowNs() - t0;
            ++R.rs.late;
            if (rec) { rec->rg_late = 1; rec->rg_wait_ns += nowNs() - t0; }
            finish_here = !J.st.done();
        }
        if (!finish_here && !J.st.done()) finish_here = true;   // stopped by a fork hook
        if (finish_here) {
            const uint64_t t0 = nowNs();
            unsigned hn = config_->tenure_help_threads == 0 ? oldgen.minorThreads()
                                                           : config_->tenure_help_threads;
            // Unless help threads are configured, a tenuring extent below `minor_parallel_min_bytes` is finished by
            // the exact engine: waking the gang costs more than the work.
            if (config_->tenure_help_threads == 0 && J.x >= 0 &&
                R.x[J.x].obj_bytes < config_->minor_parallel_min_bytes) {
                hn = 1;
            }
            ECO_TLA_TRACE("tj.help", "engine", hn > 1 && why != 2 ? "parallel" : "exact",
                          "why", why);   // trace event: help in the pause
            if (hn > 1 && why != 2) {
                runJobParallel(oldgen, hn);
                R.rs.help_workers_sum += hn;
                if (rec) rec->rg_help_workers = hn;
            } else {
                runJobExact(oldgen, nullptr);
                if (!J.st.done()) runJobExact(oldgen, nullptr);
                R.rs.help_workers_sum += 1;
                if (rec) rec->rg_help_workers = 1;
            }
            R.rs.help_ns += nowNs() - t0;
            if (rec) rec->rg_help_ns += nowNs() - t0;
        }
        J.state = TenureJob::State::Done;
    }
#if P1_CENSUS_COMPILED
    // The census check must run before the heal rewrites any slot.
    if (why != 2 && censusEnabled()) censusCheckRegion(oldgen);
#endif
    mergeJob(oldgen, /*heal=*/why != 2, rec);
    if (rec) rec->rg_merge_ns += nowNs() - tj0;
    R.rs.merge_ns += nowNs() - tj0;
}
// TLA-REGION(NT.tenureJoin) end

// TLA-REGION(NT.mergeJob) begin
void NurserySpace::mergeJob(OldGenSpace& oldgen, bool heal, MinorGCRecord* rec) {
    RegionState& R = *rg_;
    TenureJob& J = R.job;
    const tw::SerialState& st = J.st;
    // Return the grant, and record the copies for the promotion checker.
    if (J.grant.active) {
        R.rs.grant_used += J.grant.used_cells;
        if (rec) {
            rec->rg_grant_blocks = J.grant.block_count;
            rec->rg_grant_cells = J.grant.granted_cells;
            rec->rg_grant_used = J.grant.used_cells;
        }
        oldgen.returnTenureGrant(J.grant);
    }
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    p1::recordPromoted(&oldgen, J.promoted_log);
#endif
#if ECO_HEAP_VALIDATE
    // TV3 / TV4: no BUSY entry of this generation is left, and the objects with an FWD entry match the job's
    // tenured count and bytes.
    if (heal) {
        uint64_t fwd = 0, bytes = 0;
        for (char* p = J.base; p < J.surv_top;) {
            const size_t sz = getObjectSize(p);
            if (getHeader(p)->tag != Tag_Free) {
                const uint64_t e = tw::ref(J.shadow + (static_cast<size_t>(p - J.base) >> J.shadow_shift))
                                       .load(std::memory_order_relaxed);
                if (tw::genOf(e) == J.gen) {
                    if (tw::stateOf(e) == tw::kStateBusy) tenureFatal("TV3: a BUSY shadow entry at the merge", p);
                    if (tw::stateOf(e) == tw::kStateFwd) { ++fwd; bytes += sz; }
                }
            }
            p += sz;
        }
        if (fwd != st.tenured || bytes != st.tenured_bytes) {
            tenureFatal("TV3/TV4: forwarded objects != tenured (a lost or double promotion)",
                        J.base, J.surv_top, fwd, st.tenured);
        }
    }
#endif
    // Each promoted large header takes over its body. Two headers may share a body, so the body-index check is
    // made only at a body's first appearance.
    std::vector<void*> transferred;
    for (const HPointer& b : J.lb_promoted) {
        void* body = Allocator::fromPointerRaw(b);
        const bool shared = std::find(transferred.begin(), transferred.end(), body) != transferred.end();
        if (body != nullptr) transferred.push_back(body);
        if (body != nullptr && !shared && oldgen.largeBodyIndexed(body) == false) {
            tenureFatal("a promoted large header's body is no longer in the body index (its "
                        "hand-over re-mark was skipped: trap 14)", body);
        }
        oldgen.promoteLargeHeader(b);
    }
    R.rs.lb_promoted += J.lb_promoted.size();
    if (rec) rec->rg_lb_promoted = J.lb_promoted.size();
    // The hand-over YLOS objects the job reached are promoted in place, with their slots into the tenuring extent
    // rewritten to the copies. Those it did not reach are only counted here.
    auto resolveT = [&](void* t) -> char* {
        char* d = tw::lookup(J.shadow + (static_cast<size_t>(static_cast<char*>(t) - J.base) >> J.shadow_shift), J.gen);
        if (d == nullptr) tenureFatal("TV1: resolve found no forwarding at the merge", t, nullptr, J.gen);
        return d;
    };
    uint64_t ylos_prom = 0, ylos_freed = 0;
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    std::vector<void*> ylos_prom_log;
#endif
    if (heal) {
        for (size_t k = 0; k < st.ylos.size(); ++k) {
            void* y = const_cast<char*>(st.ylos[k].obj);
            if (!st.reached[k]) { ++ylos_freed; continue; }
            if (oldgen.youngLargeMeta(y) == nullptr) tenureFatal("a reached generation YLOS object left the index", y);
            oldgen.promoteYoungLarge(y);
            ++ylos_prom;
            forEachChildSlot(y, [&](HPointer& hp) {
                if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                char* c = static_cast<char*>(Allocator::fromPointerRaw(hp));
                if (c >= J.base && c < J.surv_top) hp = Allocator::toPointerRaw(resolveT(c));
            });
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
            ylos_prom_log.push_back(y);
#endif
        }
    }
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    // In-place YLOS promotions are recorded too, after their slots are rewritten, since the checker hashes the
    // contents.
    p1::recordPromoted(&oldgen, ylos_prom_log);
#endif
    // The heal: every heal slot that still points into the tenuring extent is rewritten to the copy. A slot
    // pointing elsewhere is skipped (it aborts in validate builds on the serial path).
    uint64_t healed = 0;
    const unsigned heal_n = std::min<unsigned>(oldgen.minorThreads(), OldGenSpace::kMaxMinorWorkers);
    if (heal && heal_n > 1 && st.heal.size() > config_->heal_parallel_min && !test_heal_skip_one_) {
        // A long heal list is split into n contiguous ranges on the gang.
        const uint64_t th = nowNs();
        struct HealCtx {
            const std::vector<uint64_t*>* heal;
            TenureJob* J;
            unsigned n;
        } hc{&st.heal, &J, heal_n};
        gc::GCMarkGang& gang = oldgen.ensureGang();
        const unsigned n = std::min(heal_n, gang.members());
        hc.n = n;
        gang.run([](void* c, unsigned m) {
            HealCtx& h = *static_cast<HealCtx*>(c);
            const size_t len = h.heal->size();
            const size_t lo = len * m / h.n, hi = len * (m + 1) / h.n;
            TenureJob& J = *h.J;
            for (size_t i = lo; i < hi; ++i) {
                HPointer& hp = *reinterpret_cast<HPointer*>((*h.heal)[i]);
                if (hp.ptr_ind != 0 || hp.ptr == 0) continue;
                char* c2 = static_cast<char*>(Allocator::fromPointerRaw(hp));
                if (c2 < J.base || c2 >= J.surv_top) continue;
                char* d = tw::lookup(J.shadow + (static_cast<size_t>(c2 - J.base) >> J.shadow_shift), J.gen);
                if (d == nullptr) tenureFatal("TV1: resolve found no forwarding in the parallel heal", c2);
                hp = Allocator::toPointerRaw(d);
            }
        }, &hc, n);
        healed = st.heal.size();
        ++R.rs.heals_parallel;
        const uint64_t dh = nowNs() - th;
        R.rs.heal_ns += dh;
        if (rec) { rec->rg_heal_ns = dh; rec->rg_heal_slots = st.heal.size(); }
    } else if (heal) {
        const uint64_t th = nowNs();
        bool skip_one = test_heal_skip_one_;
        for (uint64_t* s : st.heal) {
            HPointer& hp = *reinterpret_cast<HPointer*>(s);
            if (hp.ptr_ind != 0 || hp.ptr == 0) continue;
            char* c = static_cast<char*>(Allocator::fromPointerRaw(hp));
            if (c < J.base || c >= J.surv_top) {
#if ECO_HEAP_VALIDATE
                tenureFatal("a heal slot no longer points into the tenured extent (P1 violated)", s, c);
#endif
                continue;
            }
            if (skip_one) { skip_one = false; continue; }   // negative control
            hp = Allocator::toPointerRaw(resolveT(c));
            ++healed;
        }
        const uint64_t dh = nowNs() - th;
        R.rs.heal_ns += dh;
        if (rec) { rec->rg_heal_ns = dh; rec->rg_heal_slots = st.heal.size(); }
    }
#if ECO_HEAP_VALIDATE
    // TV6 (merge): no promoted object has a young child.
    if (heal) {
        auto young = [&](void* c) {
            return R.contains(c) || oldgen.isYoungLarge(c);
        };
        for (void* p : J.promoted_log) {
            forEachChildSlot(p, [&](HPointer& hp) {
                if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                void* c = Allocator::fromPointerRaw(hp);
                if (young(c)) tenureFatal("TV6: a tenured copy has a young child after the merge", p, c);
            });
        }
    }
#endif
    // The zap: memory in the ageing extents that the mark did not reach is dead, and becomes filler objects so
    // that nothing walking the extents reads slots that may point to freed objects. It runs after the census
    // check and the heal.
    if (heal && !st.zap.empty()) {
        const uint64_t tz = nowNs();
        if (!test_skip_zap_) {
            for (const tw::Span& z : st.zap) writeFiller(z.p, z.bytes);
        }
        const uint64_t dz = nowNs() - tz;
        R.rs.zap_ns += dz;
        if (rec) rec->rg_zap_ns = dz;
    }
    // An ageing-generation YLOS object the mark did not reach is dead but stays in the YLOS index, where the
    // old generation's snapshot of young large objects still walks it. Its slots may name objects freed before
    // it is, so each pointer slot is set to the Empty constant.
    if (heal && !test_skip_zap_ && !st.age_ylos.empty()) {
        const uint64_t tz = nowNs();
        HPointer nil{};
        nil.ptr_ind = 1;
        nil.constant = Const_Empty;
        uint64_t cleared = 0;
        for (size_t k = 0; k < st.age_ylos.size(); ++k) {
            if (st.age_ylos_marked[k]) continue;
            void* y = const_cast<char*>(st.age_ylos[k].obj);
            if (oldgen.youngLargeMeta(y) == nullptr) tenureFatal("an ageing YLOS left the index before the merge", y);
            forEachChildSlot(y, [&](HPointer& hp) {
                if (hp.ptr_ind == 0 && hp.ptr != 0) hp = nil;
            });
            ++cleared;
        }
        R.rs.zapped_ylos += cleared;
        const uint64_t dz = nowNs() - tz;
        R.rs.zap_ns += dz;
        if (rec) rec->rg_zap_ns += dz;
    }
    // Stats. The tenured objects are reported as this minor's promoted ones, one minor after they were handed over.
#if ENABLE_GC_STATS
    stats.mergeCopyCounts(J.copies);
#endif
    last_minor_promoted_ = st.tenured + ylos_prom;
    R.rs.tenured += st.tenured;
    R.rs.tenured_bytes += st.tenured_bytes;
    R.rs.ylos_gen_promoted += ylos_prom;
    R.rs.ylos_gen_freed += ylos_freed;
    R.rs.busy_ns += J.busy_ns;
    R.rs.stops += J.stops;
    R.rs.age_marked += st.age_marked;
    R.rs.age_marked_bytes += st.age_marked_bytes;
    R.rs.age_heal += st.age_heal;
    R.rs.zapped += st.zapped;
    R.rs.zapped_bytes += st.zapped_bytes;
    if (rec) rec->rg_zapped = st.zapped;
    R.rs.merges++;
    {
        const uint64_t now = GCStats::nowSinceProcessStartNs();
        const uint64_t epoch = R.last_minor_end_ns != 0 && now > R.last_minor_end_ns
                                   ? now - R.last_minor_end_ns : 0;
        R.rs.epoch_ns += epoch;
        if (epoch > 0) {
            const uint64_t ppm = std::min<uint64_t>(J.busy_ns * 1000000 / epoch, 100000000);
#if ENABLE_GC_STATS
            stats.rg.util_ppm.push_back(static_cast<uint32_t>(ppm));
#else
            (void)ppm;
#endif
        }
        if (rec) rec->rg_epoch_ns = epoch;
    }
    if (rec) {
        rec->rg_tenured = st.tenured;
        rec->rg_tenured_bytes = st.tenured_bytes;
        rec->rg_busy_ns = J.busy_ns;
        rec->rg_ylos_promoted = ylos_prom;
        rec->rg_ylos_freed = ylos_freed;
        rec->promoted = st.tenured;
        rec->promoted_bytes = st.tenured_bytes;
    }
    if (test_record_layout_) {
        test_layout_.push_back(0x1000000000000000ull | R.minor_seq);   // marks a job boundary
        test_layout_.insert(test_layout_.end(), J_layout_.begin(), J_layout_.end());
    }
    J_layout_.clear();
    (void)healed;
    R.rs.collector_cpu_ns += J.cpu_ns;
    ECO_TLA_TRACE("tj.merge", "heal", heal, "tenured", st.tenured, "healed", healed,
                  "ylos", ylos_prom);   // trace event: the merge's outcome
    J.state = TenureJob::State::Merged;
    syncRegionStats();
}
// TLA-REGION(NT.mergeJob) end

void NurserySpace::syncRegionStats() {
#if ENABLE_GC_STATS
    RegionState& R = *rg_;
    std::vector<uint32_t> u = std::move(stats.rg.util_ppm);
    stats.rg = R.rs;
    stats.rg.util_ppm = std::move(u);
    size_t hw = 0, sh = 0;
    stats.rg.tenure_age = R.tenure_age;
    for (unsigned i = 0; i < R.n_surv; ++i) {
        hw += R.x[i].hw;
        sh += R.shadow[i].committedBytes();
    }
    stats.rg.survivor_hw_bytes = hw;
    stats.rg.shadow_committed_bytes = sh;
    stats.rg.eden_capacity_bytes = (R.flip ? 2 : 1) * R.set.capacity;
#endif
}

// TLA-REGION(NT.tenureTeardown) begin
void NurserySpace::tenureTeardown(OldGenSpace& oldgen) {
    if (!rg_) return;
    RegionState& R = *rg_;
    TenureJob& J = R.job;
    if (R.collector) R.collector->stopAndJoin();
    if (J.state == TenureJob::State::Running && J.conc_parallel) {
        tenureConcFinish(oldgen, 1, /*on_this_thread=*/true);
        J.state = TenureJob::State::Done;
    }
    if (J.state == TenureJob::State::Running || J.state == TenureJob::State::Built) {
        if (!J.st.done() && J.grant.active) runJobExact(oldgen, nullptr);
        J.state = TenureJob::State::Done;
    }
    if (J.state == TenureJob::State::Done) mergeJob(oldgen, /*heal=*/false, nullptr);
    R.collector.reset();
}
// TLA-REGION(NT.tenureTeardown) end

// The two parallel engines. Both run `markwork::runMarkerLoop` over `TenureParEnv`; they differ only in how a copy
// is allocated.
namespace {
/// The entry kind of a copy whose slots are still to be followed.
constexpr uint32_t kEntScan = 0;
/// The entry kind of a tenuring object to copy: a start, or the target of a heal slot.
constexpr uint32_t kEntTenure = 2;
/// The entry kind of a hand-over YLOS object whose slots are to be followed without being written.
constexpr uint32_t kEntYlos = 3;
}  // namespace

// TLA-REGION(NT.TenureParEnv) begin
/// The `Env` of `markwork::runMarkerLoop` for the parallel tenure engines, over the worker slots `ws[0, n)`.
///
/// The functions the marker loop requires are as `runMarkerLoop` describes. Objects are claimed through the
/// shadow, so each is copied once whichever worker reaches it first. Each worker counts its copies in its own slot,
/// for `tenureParCollect`. Everything the Env refers to must outlive the run.
struct NurserySpace::TenureParEnv {
    static constexpr bool kParallel = true;
    NurserySpace& ns;
    TenureJob& J;
    OldGenSpace& og;
    OldGenSpace::PromoCtx* ctx;                   ///< The pause engine's promotion context; else null.
    OldGenSpace::TenureMemberCursor* mcs;         ///< The concurrent engine's grant cursors, one per slot.
    std::unique_ptr<MinorWorker>* ws;             ///< The worker slots.
    unsigned n;                                   ///< The number of slots, all of which may be stolen from.

    MinorWorker& W(unsigned i) { return *ws[i]; }
    mk::MarkerCounters& counters(unsigned i) { return W(i).ctr; }
    uint64_t takeOwn(unsigned i) {
        MinorWorker& w = W(i);
        if (w.stack.size() != w.head) {
            const uint64_t e = w.stack.back();
            w.stack.pop_back();
            w.priv.store(w.stack.size() - w.head, std::memory_order_relaxed);
            if ((++w.pops & 63) == 0) ns.publishHalfP(w);
            return e;
        }
        return w.deque.take();
    }
    uint64_t stealFrom(unsigned v) { return W(v).deque.steal(); }
    bool anyWork() {
        for (unsigned i = 0; i < n; ++i) if (!W(i).deque.emptyApprox()) return true;
        return false;
    }
    void prefetch(uint64_t) {}
    void publishAll(unsigned self) { ns.publishAllP(W(self)); }

    /// Returns whether `p` is in the tenuring extent's survivor part.
    bool inT(const void* p) const {
        const char* q = static_cast<const char*>(p);
        return q >= J.base && q < J.surv_top;
    }
    /// Returns the shadow entry of `obj`, an object of the tenuring extent.
    uint64_t* sw(const void* obj) const {
        return J.shadow + (static_cast<size_t>(static_cast<const char*>(obj) - J.base) >> J.shadow_shift);
    }
    /// Returns the copy of `obj`, a tenuring object, making it if no other worker has: claims the shadow entry,
    /// copies, and publishes the copy's address. Waits while another worker holds the claim. A new copy with
    /// children is queued for scanning if `push`. Aborts if the old generation cannot allocate the copy.
    char* tenure(MinorWorker& w, void* obj, bool push) {
        uint64_t* s = sw(obj);
        uint64_t e = tw::ref(s).load(std::memory_order_acquire);
        for (;;) {
            if (char* d = tw::fwdOf(e, J.gen)) return d;
            if (tw::genOf(e) == (J.gen & tw::kGenMask) && tw::stateOf(e) == tw::kStateBusy) {
                ++w.busy_waits;
                e = tw::waitPublished(s, J.gen, [&](unsigned r) { mk::backoff(r, w.ctr); });
                continue;
            }
            if (tw::claim(s, e, J.gen)) break;
            ++w.claim_races;
        }
        ECO_TLA_TRACE_ONLY(if (tw::tla_probes) ::Elm::tlatrace::probe("m5.l3.claimed");)   // BUSY, uncopied
        const size_t size = getObjectSize(obj);
        char* dst = ctx != nullptr
            ? static_cast<char*>(og.allocatePromotion(ctx->w[w.index], size, /*per_alloc_sweep=*/false))
            : static_cast<char*>(og.grantAllocateShared(J.grant, mcs[w.index], OldGenSpace::sizeClass(size), size));
        if (dst == nullptr) tenureFatal("old-gen allocation failed in the parallel tenure engine", obj, nullptr, size);
        std::memcpy(dst, obj, size);
        Header* h = getHeader(dst);
        h->age = 0;
        h->color = static_cast<u32>(Color::White);
        if (h->tag == Tag_LargeStringHeader || h->tag == Tag_LargeByteHeader)
            w.lb_promoted.push_back(static_cast<LargeStringHeader*>(static_cast<void*>(dst))->body);
        ++w.n_prom;
        w.b_surv += size;   // here, the bytes this worker tenured
#if ENABLE_GC_STATS
        w.copies.promotion(static_cast<Tag>(h->tag), size, h->size);
#endif
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        w.promoted_log.push_back(dst);
#endif
        tw::publish(s, dst, J.gen);
        if (push && nurseryTagHasChildren(h->tag)) ns.pushGreyP(w, mk::objEntry(dst, kEntScan));
        return dst;
    }
    /// Marks `t` reached if it is a hand-over YLOS object not reached before, and then queues it for a read-only
    /// scan.
    void reachYlos(MinorWorker& w, const void* t) {
        const long k = tw::ylosFind(J.st.ylos, t);
        if (k < 0) return;
        std::atomic_ref<uint8_t> r(J.st.reached[static_cast<size_t>(k)]);
        if (r.load(std::memory_order_relaxed) != 0 || r.exchange(1, std::memory_order_acq_rel) != 0) return;
        ++w.ylos_scans;
        ns.pushGreyP(w, mk::objEntry(J.st.ylos[static_cast<size_t>(k)].obj, kEntYlos));
    }
    /// Handles slot `hp` of `parent`, a copy: a reference into the tenuring extent is rewritten to the target's
    /// copy, and a hand-over YLOS target is reached. Aborts for a target elsewhere in the nursery's extent slots.
    void childOfCopy(MinorWorker& w, void* parent, HPointer& hp) {
        if (hp.ptr_ind != 0 || hp.ptr == 0) return;
        void* t = Allocator::fromPointerRaw(hp);
        const char* q = static_cast<const char*>(t);
        if (inT(t)) { hp = Allocator::toPointerRaw(tenure(w, t, true)); return; }
        if (q >= J.ylos_lo && q < J.ylos_hi) { reachYlos(w, t); return; }
        if (q >= J.slot_lo && q < J.slot_hi)
            tenureFatal("TV6: a promoted object has a young child outside the tenuring extent", parent, t);
    }
    /// Copies the tail chain of the copied cons cell `prev`, up to `tw::kSpineRun` cells, rewriting each tail to
    /// its copy, and then handles the heads of the cells copied.
    ///
    /// The run ends at a tail that is not a tenuring cons cell, at a cell already claimed by any worker, or at the
    /// limit. At the limit the last copied cell is queued for scanning, and its head is left to that scan.
    void spineRun(MinorWorker& w, Cons* prev) {
        Cons* run[tw::kSpineRun];
        size_t k = 0;
        bool truncated = false;
        for (;;) {
            HPointer& tail = prev->tail;
            if (tail.ptr_ind != 0 || tail.ptr == 0) break;
            void* t = Allocator::fromPointerRaw(tail);
            if (!inT(t) || getHeader(t)->tag != Tag_Cons) { childOfCopy(w, prev, tail); break; }
            if (k == tw::kSpineRun) {
                ns.pushGreyP(w, mk::objEntry(prev, kEntScan));
                ++w.spine_splits;
                truncated = true;
                break;
            }
            // A cell someone else already forwarded (or is copying) ends the run.
            const uint64_t e = tw::ref(sw(t)).load(std::memory_order_acquire);
            if (tw::genOf(e) == (J.gen & tw::kGenMask) && tw::stateOf(e) != 0) {
                tail = Allocator::toPointerRaw(tenure(w, t, true));
                break;
            }
            Cons* d = reinterpret_cast<Cons*>(tenure(w, t, false));
            tail = Allocator::toPointerRaw(d);
            run[k++] = d;
            prev = d;
        }
        const size_t m = truncated ? k - 1 : k;
        for (size_t i = 0; i < m; ++i) {
            Cons* c = run[i];
            if (Elm::tupleFieldKind(c->header.unboxed, 0) == 0) childOfCopy(w, c, c->head.p);
        }
    }
    void scan(unsigned self, uint64_t e) {
        MinorWorker& w = W(self);
        void* obj = mk::entryAddr(e);
        const uint32_t kind = mk::entryField(e);
        if (kind == kEntTenure) { (void)tenure(w, obj, true); return; }
        if (kind == kEntYlos) {   // read-only
            forEachChildSlot(obj, [&](HPointer& hp) {
                if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                void* t = Allocator::fromPointerRaw(hp);
                const char* q = static_cast<const char*>(t);
                if (inT(t)) (void)tenure(w, t, true);
                else if (q >= J.ylos_lo && q < J.ylos_hi) reachYlos(w, t);
            });
            return;
        }
        Header* h = getHeader(obj);
        if (h->tag == Tag_Cons) {
            Cons* c = static_cast<Cons*>(obj);
            if (Elm::tupleFieldKind(h->unboxed, 0) == 0) childOfCopy(w, c, c->head.p);
            spineRun(w, c);
            return;
        }
        forEachChildSlot(obj, [&](HPointer& hp) { childOfCopy(w, obj, hp); });
    }
};
// TLA-REGION(NT.TenureParEnv) end

namespace {
struct TenureParArgs {
    void* env;
    mk::SliceControl* ctl;
};
}  // namespace

void NurserySpace::tenureParEntry(void* ctx, unsigned member) {
    TenureParArgs* a = static_cast<TenureParArgs*>(ctx);
    mk::runMarkerLoop(*static_cast<TenureParEnv*>(a->env), member, *a->ctl);
}

void NurserySpace::tenureParSetup(std::unique_ptr<MinorWorker>* ws, unsigned n) {
    for (unsigned i = 0; i < n; ++i) {
        if (!ws[i]) ws[i] = std::make_unique<MinorWorker>();
        ws[i]->resetRun();
        ws[i]->index = i;
        ws[i]->ctr.resetRun(i);
    }
}

// The deques are filled before any worker runs; starting the run publishes them to the workers. Pending heal slots
// contribute their targets in the tenuring extent, and pending YLOS objects are queued for a read-only scan.
// TLA-REGION(NT.tenureParDistribute) begin
void NurserySpace::tenureParDistribute(std::unique_ptr<MinorWorker>* ws, unsigned n) {
    TenureJob& J = rg_->job;
    tw::SerialState& st = J.st;
    size_t rr = 0;
    auto give = [&](uint64_t e) { ws[rr++ % n]->deque.push(e); };
    auto inT = [&](const void* p) {
        const char* q = static_cast<const char*>(p);
        return q >= J.base && q < J.surv_top;
    };
    for (size_t i = st.stack_head; i < st.stack.size(); ++i) give(mk::objEntry(st.stack[i], kEntScan));
    st.stack.clear();
    st.stack_head = 0;
    for (size_t i = st.next_start; i < st.starts.size(); ++i) {
        if (st.test_skip_start_every != 0 && (i + 1) % st.test_skip_start_every == 0) continue;
        give(mk::objEntry(st.starts[i], kEntTenure));
    }
    st.next_start = st.starts.size();
    for (size_t i = st.next_heal; i < st.heal.size(); ++i) {
        HPointer hp;
        std::memcpy(&hp, st.heal[i], sizeof(hp));
        if (hp.ptr_ind != 0 || hp.ptr == 0) continue;
        void* t = Allocator::fromPointerRaw(hp);
        if (inT(t)) give(mk::objEntry(t, kEntTenure));
    }
    st.next_heal = st.heal.size();
    for (size_t i = st.ylos_next; i < st.ylos_pending.size(); ++i)
        give(mk::objEntry(st.ylos[st.ylos_pending[i]].obj, kEntYlos));
    st.ylos_next = st.ylos_pending.size();
}
// TLA-REGION(NT.tenureParDistribute) end

// TLA-REGION(NT.tenureParCollect) begin
void NurserySpace::tenureParCollect(std::unique_ptr<MinorWorker>* ws, unsigned n) {
    TenureJob& J = rg_->job;
    tw::SerialState& st = J.st;
    region::RegionStats& rs = rg_->rs;
    uint64_t umax = 0;
    ++rs.par_runs;
    for (unsigned i = 0; i < n; ++i) {
        MinorWorker& w = *ws[i];
        rs.par_units += w.ctr.units;
        umax = std::max(umax, w.ctr.units);
        rs.par_steals += w.ctr.steals;
        rs.par_idle_spins += w.ctr.idle_spins;
        rs.par_idle_yields += w.ctr.idle_yields;
        rs.par_idle_sleeps += w.ctr.idle_sleeps;
        if (w.stack.size() != w.head || !w.deque.emptyApprox())
            tenureFatal("work left in a tenure worker after termination", nullptr, nullptr, i);
        w.deque.reset();
        st.tenured += w.n_prom;
        st.tenured_bytes += w.b_surv;
        st.ylos_reached += w.ylos_scans;
        J.lb_promoted.insert(J.lb_promoted.end(), w.lb_promoted.begin(), w.lb_promoted.end());
#if ENABLE_GC_STATS
        J.copies.add(w.copies);
#endif
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        J.promoted_log.insert(J.promoted_log.end(), w.promoted_log.begin(), w.promoted_log.end());
#endif
        w.resetRun();
    }
    rs.par_units_max_sum += umax;
}
// TLA-REGION(NT.tenureParCollect) end

// TLA-REGION(NT.runJobParallel) begin
void NurserySpace::runJobParallel(OldGenSpace& oldgen, unsigned n) {
    RegionState& R = *rg_;
    TenureJob& J = R.job;
    finishJobMarkPhases(oldgen, n);   // the ageing mark adds heal slots the tenure work needs
    const uint64_t t0 = nowNs();
    // Any unused grant goes back first; the exact engine's copies stay.
    if (J.grant.active) {
        R.rs.grant_used += J.grant.used_cells;
        oldgen.returnTenureGrant(J.grant);
    }
    gc::GCMarkGang& gang = oldgen.ensureGang();
    if (n > gang.members()) n = gang.members();
    if (n > OldGenSpace::kMaxMinorWorkers) n = OldGenSpace::kMaxMinorWorkers;
    if (n < 1) n = 1;
    tenureParSetup(minor_workers_, n);
    OldGenSpace::PromoCtx& ctx = oldgen.promoCtx();
    oldgen.beginParallelPromotion(ctx, n);
    TenureParEnv env{*this, J, oldgen, &ctx, nullptr, minor_workers_, n};
    tenureParDistribute(minor_workers_, n);
    par_n_ = n;
    mk::SliceControl ctl(mk::kDrainBudget, n, gang.jitterUs(), n);
    if (n == 1) {
        mk::runMarkerLoop(env, 0, ctl);
    } else {
        TenureParArgs args{&env, &ctl};
        gang.run(&NurserySpace::tenureParEntry, &args, n);
    }
    tenureParCollect(minor_workers_, n);
    oldgen.endParallelPromotion(ctx);
    par_n_ = 0;
    J.parallel_used = true;
    J.busy_ns += nowNs() - t0;
}
// TLA-REGION(NT.runJobParallel) end

// The concurrent engine. The job's inputs are dealt into the B members' slots in the hand-over pause, and the
// members run the marker loop over those slots, allocating from the shared grant. A stop leaves the unscanned
// work in the deques, and `tenureConcFinish` drains it in the next pause.
// TLA-REGION(NT.tenureConcEntry) begin
void NurserySpace::tenureConcEntry(void* ctx, unsigned member) {
    NurserySpace* ns = static_cast<NurserySpace*>(ctx);
    TenureJob& J = ns->rg_->job;
    const uint64_t c0 = gc::GCHelperPool::threadCpuNs();
    const uint64_t t0 = nowNs();
    TenureParEnv env{*ns, J, *ns->rg_->tenure_og, nullptr, ns->tenure_mcs_.data(),
                     ns->tenure_workers_, ns->tenure_par_n_};
    mk::runMarkerLoop(env, member, *ns->tenure_ctl_);
    const uint64_t dt = nowNs() - t0;
    std::atomic_ref<uint64_t>(J.cpu_ns).fetch_add(gc::GCHelperPool::threadCpuNs() - c0, std::memory_order_relaxed);
    if (member == 0) J.busy_ns += dt;   // only member 0's wall time counts as the job's busy time
}
// TLA-REGION(NT.tenureConcEntry) end

// TLA-REGION(NT.tenureConcLaunch) begin
void NurserySpace::tenureConcLaunch(OldGenSpace& oldgen, unsigned B) {
    RegionState& R = *rg_;
    TenureJob& J = R.job;
    tenure_par_n_ = B;
    if (tenure_mcs_.size() < OldGenSpace::kMaxMinorWorkers) tenure_mcs_.resize(OldGenSpace::kMaxMinorWorkers);
    for (auto& m : tenure_mcs_) m.reset();
    tenureParSetup(tenure_workers_, B);
    tenureParDistribute(tenure_workers_, B);
    const unsigned jitter = allocator_ ? allocator_->helperJitterUs() : 0;
    tenure_ctl_ = std::make_unique<mk::SliceControl>(mk::kDrainBudget, B, jitter, B);
    J.state = TenureJob::State::Running;
    J.conc_parallel = true;
    // If a fork's prepare handler refuses the launch, no member runs and `tenureJoin` finishes the job in the
    // pause through `tenureConcFinish`.
    if (!R.collector->launch(&NurserySpace::tenureConcEntry, this, &tenure_ctl_->stop)) ++R.rs.fork_refusals;
}
// TLA-REGION(NT.tenureConcLaunch) end

// When work is left, the helpers use V = max(B, p) slots: the B members' slots, whose deques hold the work, and
// empty ones for helpers beyond B, which steal.
// TLA-REGION(NT.tenureConcFinish) begin
void NurserySpace::tenureConcFinish(OldGenSpace& oldgen, unsigned help_n, bool on_this_thread) {
    TenureJob& J = rg_->job;
    const unsigned B = tenure_par_n_;
    if (!tenure_ctl_->done()) {
        unsigned p = help_n;
        gc::GCMarkGang* gang = nullptr;
        if (!on_this_thread) {
            gang = &oldgen.ensureGang();
            if (p > gang->members()) p = gang->members();
        }
        if (p < 1 || on_this_thread) p = 1;
        const unsigned V = std::max(B, p);
        tenureParSetupExtra(B, V);
        TenureParEnv env{*this, J, oldgen, nullptr, tenure_mcs_.data(), tenure_workers_, V};
        mk::SliceControl ctl(mk::kDrainBudget, V, gang ? gang->jitterUs() : 0, p);
        par_n_ = V;
        if (p == 1) {
            mk::runMarkerLoop(env, 0, ctl);
        } else {
            TenureParArgs args{&env, &ctl};
            gang->run(&NurserySpace::tenureParEntry, &args, p);
        }
        par_n_ = 0;
        tenure_par_n_ = V;
    }
    tenureParCollect(tenure_workers_, tenure_par_n_);
    for (unsigned i = 0; i < tenure_par_n_; ++i) oldgen.grantFoldMember(J.grant, tenure_mcs_[i]);
    tenure_ctl_.reset();
    J.conc_parallel = false;
    J.parallel_used = true;
}
// TLA-REGION(NT.tenureConcFinish) end

void NurserySpace::tenureParSetupExtra(unsigned B, unsigned V) {
    for (unsigned i = B; i < V; ++i) {
        if (!tenure_workers_[i]) tenure_workers_[i] = std::make_unique<MinorWorker>();
        tenure_workers_[i]->resetRun();
        tenure_workers_[i]->index = i;
    }
    region::RegionStats& rs = rg_->rs;
    uint64_t umax = 0;
    ++rs.par_runs;
    for (unsigned i = 0; i < B; ++i) {   // the counters of the members' stopped run
        const markwork::MarkerCounters& c = tenure_workers_[i]->ctr;
        rs.par_units += c.units;
        umax = std::max(umax, c.units);
        rs.par_steals += c.steals;
        rs.par_idle_spins += c.idle_spins;
        rs.par_idle_yields += c.idle_yields;
        rs.par_idle_sleeps += c.idle_sleeps;
    }
    rs.par_units_max_sum += umax;
    for (unsigned i = 0; i < V; ++i) tenure_workers_[i]->ctr.resetRun(i);
}

}  // namespace Elm
