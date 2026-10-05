// threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md, HEAP_067/HEAP_068):
// the parallel minor GC. NurserySpace::minorGC keeps its prologue and
// epilogue; with gc_minor_threads > 1 (or the forced one-worker engine) the
// root phase and the drain run here instead of the serial Cheney core.
//
//   roots (serial, worker 0) -> distribute -> drain on N workers
//   (markwork::runMarkerLoop, 5b's deques and termination) -> close LABs ->
//   merge counters, return promotion cursors, apply deferred large-body ops.
//
// A from-space object is copied exactly once: CLAIM (CAS header -> BUSY),
// copy, PUBLISH (release store of the forward word). See MinorWork.hpp.

#include "NurserySpace.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Allocator.hpp"
#include "GCHelperPool.hpp"
#include "HeapChildWalk.hpp"
#include "OldGenSpace.hpp"
#include "StackMapRoots.hpp"

#if ECO_HEAP_VALIDATE
// NurserySpace.cpp's per-thread scan-parent diagnostics (thread_local).
extern thread_local void* g_scan_parent;
extern thread_local int g_scan_tag;
extern thread_local Elm::u32 g_scan_size;
#endif

namespace Elm {

namespace mw = minorwork;
namespace mk = markwork;

static_assert(mw::kTagForward == static_cast<uint64_t>(Tag_Forward),
              "MinorWork.hpp's Tag_Forward must match Heap.hpp");

namespace {

// Tags whose copies have children to scan (scanEntryP's arms). Large
// headers are handled at copy time (their body bookkeeping is deferred).
inline bool tagHasChildren(uint32_t tag) {
    switch (tag) {
        case Tag_Tuple2: case Tag_Tuple3: case Tag_Custom: case Tag_Record:
        case Tag_DynRecord: case Tag_Closure: case Tag_Cons: case Tag_ConsChunk:
        case Tag_ListBacking: case Tag_Task: case Tag_Process: case Tag_Array:
        case Tag_StringSlice: case Tag_StringUtf8View: case Tag_ByteBufferSlice:
        case Tag_StringRope:
            return true;
        default:
            return false;
    }
}

inline Header headerOf(uint64_t w) {
    Header h;
    std::memcpy(&h, &w, sizeof(h));
    return h;
}
inline uint64_t wordOf(const Header& h) {
    uint64_t w;
    std::memcpy(&w, &h, sizeof(w));
    return w;
}

#if ECO_HEAP_VALIDATE
[[noreturn]] void pmFail(const char* what, const void* a, const void* b = nullptr,
                         uint64_t x = 0, uint64_t y = 0) {
    std::fprintf(stderr, "[heap-validate] %s: %p %p (%llu, %llu)\n", what, a, b,
                 (unsigned long long)x, (unsigned long long)y);
    std::fflush(stderr);
    std::abort();
}
#endif

}  // namespace

void NurserySpace::MinorWorker::resetRun() {
    stack.clear();
    head = 0;
    priv.store(0, std::memory_order_relaxed);
    pops = 0;
    lab = minorwork::Lab{};
    lc = minorwork::LabCounters{};
    copies.reset();
    n_surv = b_surv = n_prom = n_ylos_prom = 0;
    claim_races = busy_waits = spine_splits = chunks = 0;
    ylos_reach_calls = ylos_scans = 0;
    busy_ns = 0;
    claims_won = 0;
    lb_seen.clear();
    lb_promoted.clear();
    ylos_young.clear();
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
    promoted_log.clear();
#endif
}

void NurserySpace::writeFiller(char* p, size_t bytes) {
    Header* h = reinterpret_cast<Header*>(p);
    std::memset(h, 0, sizeof(Header));
    h->tag = Tag_Free;
    h->size = static_cast<u32>(bytes);
}

// ---------------------------------------------------------------------------
// Grey entries (5b's policy: private stack, oldest half published)
// ---------------------------------------------------------------------------

void NurserySpace::pushGreyP(MinorWorker& w, uint64_t e) {
    w.stack.push_back(e);
    const size_t n = w.stack.size() - w.head;
    w.priv.store(n, std::memory_order_relaxed);
    if ((n & 31) == 0) publishHalfP(w);
}

// Publishes half of the private work when the deque is empty. LIFO keeps the
// newest (it pops from the back) and gives away the oldest; FIFO keeps the
// oldest (it pops at head) and gives away the newest.
void NurserySpace::publishHalfP(MinorWorker& w) {
    const size_t n = w.stack.size() - w.head;
    if (n < 64 || !w.deque.emptyApprox()) return;
    const size_t half = n / 2;
    if (fifo_order_) {
        const size_t from = w.stack.size() - half;
        for (size_t i = from; i < w.stack.size(); ++i) w.deque.push(w.stack[i]);
        w.stack.resize(from);
    } else {
        for (size_t i = 0; i < half; ++i) w.deque.push(w.stack[w.head + i]);
        w.stack.erase(w.stack.begin() + static_cast<std::ptrdiff_t>(w.head),
                      w.stack.begin() + static_cast<std::ptrdiff_t>(w.head + half));
    }
    w.priv.store(w.stack.size() - w.head, std::memory_order_relaxed);
}

void NurserySpace::publishAllP(MinorWorker& w) {
    if (w.stack.size() == w.head) return;
    for (size_t i = w.head; i < w.stack.size(); ++i) w.deque.push(w.stack[i]);
    w.stack.clear();
    w.head = 0;
    w.priv.store(0, std::memory_order_relaxed);
}

// TLA-REGION(NP.MinorEnv) begin
struct NurserySpace::MinorEnv {
    static constexpr bool kParallel = true;
    NurserySpace& ns;
    mk::MarkerCounters& counters(unsigned i) { return ns.minor_workers_[i]->ctr; }
    uint64_t takeOwn(unsigned i) {
        MinorWorker& w = *ns.minor_workers_[i];
        if (w.stack.size() != w.head) {
            uint64_t e;
            if (ns.fifo_order_) {
                e = w.stack[w.head++];
                if (w.head == w.stack.size()) {
                    w.stack.clear();
                    w.head = 0;
                } else if (w.head >= 4096 && w.head * 2 >= w.stack.size()) {
                    w.stack.erase(w.stack.begin(), w.stack.begin() + static_cast<std::ptrdiff_t>(w.head));
                    w.head = 0;
                }
            } else {
                e = w.stack.back();
                w.stack.pop_back();
            }
            w.priv.store(w.stack.size() - w.head, std::memory_order_relaxed);
            if ((++w.pops & 63) == 0) ns.publishHalfP(w);
            return e;
        }
        return w.deque.take();
    }
    uint64_t stealFrom(unsigned v) { return ns.minor_workers_[v]->deque.steal(); }
    // Only STEALABLE work wakes an idle worker (as built, P§10.1): a private
    // stack is the owner's alone, and an owner publishes everything before it
    // goes idle, so termination never needs it. Counting it (5b's marker does)
    // made every idle worker wake, fail to steal and re-idle in a tight loop
    // while one worker walked a long serial chain -- bouncing that worker's
    // `priv` line and the ticket/state words, 5-40x slower than serial on
    // such minors, growing with N (E2).
    bool anyWork() {
        for (unsigned i = 0; i < ns.par_n_; ++i) {
            if (!ns.minor_workers_[i]->deque.emptyApprox()) return true;
        }
        return false;
    }
    // P§3.6: the entry is a copy we just wrote (hot); the cold loads are its
    // children's from-space headers. With minor_prefetch_children, issue them
    // while the entry waits in the 16-deep ring.
    void prefetch(uint64_t e) {
        if (!ns.prefetch_children_ || mk::isChunk(e)) return;
        void* obj = mk::entryAddr(e);
        const Header* h = getHeader(obj);
        auto pf = [&](const HPointer& hp) {
            if (hp.ptr_ind != 0 || hp.ptr == 0) return;
            void* c = Allocator::fromPointerRaw(hp);
            if (ns.isInFromSpace(c)) __builtin_prefetch(c, 1, 3);
        };
        switch (h->tag) {
            case Tag_Cons: {
                const Cons* c = static_cast<const Cons*>(obj);
                if (Elm::tupleFieldKind(h->unboxed, 0) == 0) pf(c->head.p);
                pf(c->tail);
                break;
            }
            case Tag_Tuple2: {
                const Tuple2* t = static_cast<const Tuple2*>(obj);
                if (Elm::tupleFieldKind(h->unboxed, 0) == 0) pf(t->a.p);
                if (Elm::tupleFieldKind(h->unboxed, 1) == 0) pf(t->b.p);
                break;
            }
            case Tag_Custom: {
                const Custom* c = static_cast<const Custom*>(obj);
                for (u32 i = 0; i < h->size && i < 4; ++i)
                    if (Elm::fieldKind(c->unboxed, i) == 0) pf(c->values[i].p);
                break;
            }
            default:
                break;
        }
    }
    void scan(unsigned self, uint64_t e) { ns.scanEntryP(*ns.minor_workers_[self], e); }
    void publishAll(unsigned self) { ns.publishAllP(*ns.minor_workers_[self]); }
};
// TLA-REGION(NP.MinorEnv) end

namespace {
struct MinorRunArgs {
    NurserySpace* ns;
    mk::SliceControl* ctl;
};
}  // namespace

void NurserySpace::minorWorkerEntry(void* ctx, unsigned member) {
    MinorRunArgs* a = static_cast<MinorRunArgs*>(ctx);
    MinorEnv env{*a->ns};
    mk::runMarkerLoop(env, member, *a->ctl);
}

// ---------------------------------------------------------------------------
// Claim, copy, publish (P§3.3)
// ---------------------------------------------------------------------------

uint64_t NurserySpace::waitPublishedP(MinorWorker& w, void* obj) {
    ++w.busy_waits;
    return mw::waitPublished(obj, [&](unsigned round) { mk::backoff(round, w.ctr); });
}

// TLA-REGION(NP.copyClaimed) begin
void* NurserySpace::copyClaimed(MinorWorker& w, void* obj, uint64_t hw, bool parent_old) {
    Header hd = headerOf(hw);
#if ECO_HEAP_VALIDATE
    if (hd.tag > Tag_Forward) pmFail("parallel minor: invalid tag in a claimed object", obj, nullptr, hd.tag);
#endif
    const size_t size = getObjectSizeFromHeader(&hd);   // never getObjectSize(obj): it reads BUSY
    void* dst;
    const bool promote = shouldPromote(&hd);
    if (promote) {
        dst = par_oldgen_->allocatePromotion(par_ctx_->w[w.index], size, /*per_alloc_sweep=*/false);
        if (dst == nullptr) {
            std::fprintf(stderr, "[gc] FATAL: old-gen allocation failed during a parallel "
                         "promotion (%zu bytes)\n", size);
            std::fflush(stderr);
            std::abort();
        }
        hd.age = 0;
        hd.color = static_cast<u32>(Color::White);
        ++w.n_prom;
#if ENABLE_GC_STATS
        w.copies.promotion(static_cast<Tag>(hd.tag), size, hd.size);
#endif
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        w.promoted_log.push_back(dst);
#endif
    } else {
#if ECO_HEAP_VALIDATE
        // PM5 (the serial in_phase3_ assertion): a promoted parent's child is
        // at least as old as the parent, so it promotes too.
        if (parent_old) {
            pmFail(hd.builder ? "PM5: builder reached as child of a promoted parent (HEAP_BUILDER_003)"
                              : "PM5: child of a promoted object has age < promotion_age",
                   obj, nullptr, hd.tag, hd.age);
        }
#else
        (void)parent_old;
#endif
        dst = mw::labAllocate(tospace_, w.lab, w.lc, size, &NurserySpace::writeFiller);
        if (!hd.builder) hd.age++;
        hd.color = static_cast<u32>(Color::White);
        ++w.n_surv;
        w.b_surv += size;
#if ENABLE_GC_STATS
        w.copies.survival(static_cast<Tag>(hd.tag), size, hd.size);
#endif
    }
    if (hd.tag == Tag_LargeStringHeader || hd.tag == Tag_LargeByteHeader) {
        // Deferred to worker 0 after the join (P§3.9): promote-all, then seen.
        const HPointer body = static_cast<LargeStringHeader*>(obj)->body;
        (promote ? w.lb_promoted : w.lb_seen).push_back(body);
    }
    std::memcpy(static_cast<char*>(dst) + sizeof(Header), static_cast<char*>(obj) + sizeof(Header),
                size - sizeof(Header));
    const uint64_t nw = wordOf(hd);
    std::memcpy(dst, &nw, sizeof(nw));
    if (__builtin_expect(test_minor_double_copy_every_ != 0, 0) && !promote &&
        (++w.claims_won % test_minor_double_copy_every_) == 0) {
        // Negative control: an uncounted second copy (PM1 must fire).
        void* d2 = mw::labAllocate(tospace_, w.lab, w.lc, size, &NurserySpace::writeFiller);
        std::memcpy(d2, dst, size);
    }
    mw::publish(obj, dst, mw::colorOf(hw));
    return dst;
}
// TLA-REGION(NP.copyClaimed) end

// TLA-REGION(NP.evacuateP) begin
void NurserySpace::evacuateP(MinorWorker& w, HPointer& slot, bool parent_old) {
#if ECO_HEAP_VALIDATE
    {
        uint64_t raw;
        std::memcpy(&raw, &slot, sizeof(raw));
        if (raw == 0xD8D8D8D8D8D8D8D8ull) pmFail("POISON READ AS A BOXED SLOT (parallel minor)", &slot);
    }
#endif
    if (slot.ptr_ind != 0 || slot.ptr == 0) return;
    void* obj = Allocator::fromPointerRaw(slot);
    if (obj == nullptr) return;
    char* p = static_cast<char*>(obj);
    if (p < heap_base_ || p >= heap_base_ + heap_reserved_) return;   // permanent space
    if (__builtin_expect(!isInFromSpace(obj), 1)) {
        if (__builtin_expect(par_oldgen_->mayBeYoungLarge(obj), 0)) reachYoungLargeP(w, obj, parent_old);
        return;
    }
    uint64_t hw = mw::loadHeader(obj);
    for (;;) {
        if (mw::isForwardWord(hw)) {
            if (hw == mw::kBusy) { hw = waitPublishedP(w, obj); continue; }
            slot = Allocator::toPointerRaw(mw::fwdAddr(hw));
            return;
        }
        if (mw::claim(obj, hw)) break;
        ++w.claim_races;
    }
    void* dst = copyClaimed(w, obj, hw, parent_old);
    slot = Allocator::toPointerRaw(dst);
    if (tagHasChildren(headerOf(hw).tag)) pushGreyP(w, mk::objEntry(dst, 0));
}
// TLA-REGION(NP.evacuateP) end

// JIT roots: raw 64-bit addresses (roots only: worker 0, before the gang).
void NurserySpace::evacuateRawP(MinorWorker& w, uint64_t& raw) {
    if (isConstantBits(raw)) return;
    void* obj = reinterpret_cast<void*>(raw);
    if (obj == nullptr) return;
    char* p = static_cast<char*>(obj);
    if (p < heap_base_ || p >= heap_base_ + heap_reserved_) return;
    HPointer hp = Allocator::toPointerRaw(obj);
    evacuateP(w, hp, /*parent_old=*/false);
    raw = reinterpret_cast<uint64_t>(Allocator::fromPointerRaw(hp));
}

// TLA-REGION(NP.reachYoungLargeP) begin
void NurserySpace::reachYoungLargeP(MinorWorker& w, void* obj, bool parent_old) {
    bool promoted = false;
    {
        std::lock_guard<std::mutex> g(ylos_mu_);
        OldGenSpace::LargeBodyMeta* m = par_oldgen_->youngLargeMeta(obj);
        if (m == nullptr) return;   // an old object inside the bounding box
        ++w.ylos_reach_calls;
        if (m->color == minor_color_) return;   // already reached this minor
        m->color = minor_color_;
        // CR-019: a sweep slice under promo_mu_ may read this header word:
        // relaxed atomic whole-word load/store (HEAP_062).
        Header hv = loadHeaderRelaxed(obj);
        if (!hv.builder && hv.age >= promotion_age_) {
            par_oldgen_->promoteYoungLarge(obj);   // invalidates m
            promoted = true;
        } else {
#if ECO_HEAP_VALIDATE
            if (parent_old) pmFail("PM5: young large object reached from a promoted parent", obj);
#else
            (void)parent_old;
#endif
            if (!hv.builder) { ++hv.age; storeHeaderRelaxed(obj, hv); }
            w.ylos_young.push_back(obj);
        }
    }
    if (promoted) {
        ++w.n_ylos_prom;
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        w.promoted_log.push_back(obj);
#endif
        pushGreyP(w, mk::objEntry(obj, 0));   // scanned as a promoted (old) parent
    } else {
        pushGreyP(w, mk::objEntry(obj, 1));   // scanned in place as a young parent
    }
}
// TLA-REGION(NP.reachYoungLargeP) end

// ---------------------------------------------------------------------------
// Scanning an entry (P§3.7)
// ---------------------------------------------------------------------------

// TLA-REGION(NP.spineRunP) begin
void NurserySpace::spineRunP(MinorWorker& w, Cons* prev) {
    Cons* first = nullptr;
    size_t k = 0;
    bool truncated = false, needs_heads = false;
    for (;;) {
        const HPointer t = prev->tail;
        if (t.ptr_ind != 0 || t.ptr == 0) break;
        void* obj = Allocator::fromPointerRaw(t);
        if (obj == nullptr) break;
        const bool prev_old = !contains(prev);
        if (!isInFromSpace(obj)) { evacuateP(w, prev->tail, prev_old); break; }
        uint64_t hw = mw::loadHeader(obj);
        if (mw::isForwardWord(hw)) {
            if (hw == mw::kBusy) hw = waitPublishedP(w, obj);
            prev->tail = Allocator::toPointerRaw(mw::fwdAddr(hw));
            break;
        }
        if (headerOf(hw).tag != Tag_Cons) { evacuateP(w, prev->tail, prev_old); break; }
        if (k == MINOR_SPINE_RUN) {
            // Bounded run: the last copy is pushed; its scan continues the spine.
            pushGreyP(w, mk::objEntry(prev, 0));
            ++w.spine_splits;
            truncated = true;
            break;
        }
        if (!mw::claim(obj, hw)) { ++w.claim_races; continue; }
        Cons* cc = static_cast<Cons*>(copyClaimed(w, obj, hw, prev_old));
        if (Elm::tupleFieldKind(cc->header.unboxed, 0) == 0 && cc->head.p.ptr_ind == 0)
            needs_heads = true;
        prev->tail = Allocator::toPointerRaw(cc);
        if (k == 0) first = cc;
        prev = cc;
        ++k;
    }
    if (needs_heads && k > 0) {
        // The heads pass COUNTS cells (never "still in to-space": the next
        // cell may be another worker's copy). A truncated run's last cell is
        // not in it: that cell was pushed and its scan does its head.
        const size_t m = truncated ? k - 1 : k;
        Cons* c = first;
        for (size_t i = 0; i < m; ++i) {
            if (Elm::tupleFieldKind(c->header.unboxed, 0) == 0) evacuateP(w, c->head.p, !contains(c));
            if (i + 1 < m) c = static_cast<Cons*>(Allocator::fromPointerRaw(c->tail));   // the last tail may be Nil
        }
    }
}
// TLA-REGION(NP.spineRunP) end

// TLA-REGION(NP.scanEntryP) begin
void NurserySpace::scanEntryP(MinorWorker& w, uint64_t e) {
    void* obj = mk::entryAddr(e);
    Header* hdr = getHeader(obj);
#if ECO_HEAP_VALIDATE
    g_scan_parent = obj;
    g_scan_tag = hdr->tag;
    g_scan_size = hdr->size;
#endif
    if (mk::isChunk(e)) {
        // Chunk k >= 1 of a boxed Array / ListBacking. A young YLOS array is
        // treated as young (the PM5 check is conservative for chunks).
        const bool parent_old = !contains(obj) && !par_oldgen_->mayBeYoungLarge(obj);
        const uint64_t k = mk::entryField(e);
        if (hdr->tag == Tag_Array) {
            ElmArray* arr = static_cast<ElmArray*>(obj);
            const uint64_t lo = k * MINOR_CHUNK_ELEMS;
            const uint64_t hi = std::min<uint64_t>(arr->length, lo + MINOR_CHUNK_ELEMS);
            for (uint64_t i = lo; i < hi; ++i) evacuateP(w, arr->elements[i].p, parent_old);
        } else {
            ListBacking* lb = static_cast<ListBacking*>(obj);
            const uint64_t lo = lb->hd + k * MINOR_CHUNK_ELEMS;
            const uint64_t hi = std::min<uint64_t>(hdr->size, lo + MINOR_CHUNK_ELEMS);
            for (uint64_t i = lo; i < hi; ++i) evacuateP(w, lb->elems[i].p, parent_old);
        }
        return;
    }
    const bool parent_old = !contains(obj) && mk::entryField(e) == 0;
    if (mk::entryField(e) == 1) ++w.ylos_scans;
    auto unbox = [&](Unboxable& v, bool boxed) { if (boxed) evacuateP(w, v.p, parent_old); };
    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2* t = static_cast<Tuple2*>(obj);
            unbox(t->a, Elm::tupleFieldKind(hdr->unboxed, 0) == 0);
            unbox(t->b, Elm::tupleFieldKind(hdr->unboxed, 1) == 0);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* t = static_cast<Tuple3*>(obj);
            unbox(t->a, Elm::tupleFieldKind(hdr->unboxed, 0) == 0);
            unbox(t->b, Elm::tupleFieldKind(hdr->unboxed, 1) == 0);
            unbox(t->c, Elm::tupleFieldKind(hdr->unboxed, 2) == 0);
            break;
        }
        case Tag_Custom: {
            Custom* c = static_cast<Custom*>(obj);   // header slots, then the tail (boxed: D semantics)
            const u32 n = hdr->size, h = n < Elm::CUSTOM_HDR_SLOTS ? n : Elm::CUSTOM_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) unbox(c->values[i], Elm::kindInWord(c->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) unbox(c->values[i], Elm::customSlotKind(c, i) == 0);
            break;
        }
        case Tag_Record: {
            Record* r = static_cast<Record*>(obj);
            const u32 n = hdr->size, h = n < Elm::RECORD_HDR_SLOTS ? n : Elm::RECORD_HDR_SLOTS;
            for (u32 i = 0; i < h; i++) unbox(r->values[i], Elm::kindInWord(r->unboxed, i) == 0);
            for (u32 i = h; i < n; i++) unbox(r->values[i], Elm::recordSlotKind(r, i) == 0);
            break;
        }
        case Tag_DynRecord: {
            DynRecord* dr = static_cast<DynRecord*>(obj);
            evacuateP(w, dr->fieldgroup, parent_old);
            for (u32 i = 0; i < hdr->size; i++) evacuateP(w, dr->values[i], parent_old);
            break;
        }
        case Tag_Closure: {
            Closure* cl = static_cast<Closure*>(obj);   // APPLIED slots only (n_values)
            for (u32 i = 0; i < cl->n_values; i++) unbox(cl->values[i], Elm::closureSlotKind(cl, i) == 0);
            break;
        }
        case Tag_Cons: {
            Cons* c = static_cast<Cons*>(obj);
            unbox(c->head, Elm::tupleFieldKind(hdr->unboxed, 0) == 0);
            if (use_hybrid_dfs_) spineRunP(w, c);
            else evacuateP(w, c->tail, parent_old);
            break;
        }
        case Tag_ConsChunk: {
            ConsChunk* cv = static_cast<ConsChunk*>(obj);
            evacuateP(w, cv->backing, parent_old);
            evacuateP(w, cv->next, parent_old);
            break;
        }
        case Tag_ListBacking: {
            if ((hdr->unboxed & 0x3) != 0) break;
            ListBacking* lb = static_cast<ListBacking*>(obj);
            u32 hi = hdr->size;
            if (hdr->size - lb->hd > MINOR_CHUNK_ELEMS) {
                for (uint64_t k = 1; lb->hd + k * MINOR_CHUNK_ELEMS < hdr->size; ++k) {
                    pushGreyP(w, mk::chunkEntry(obj, static_cast<uint32_t>(k)));
                    ++w.chunks;
                }
                hi = lb->hd + MINOR_CHUNK_ELEMS;
            }
            for (u32 i = lb->hd; i < hi; i++) evacuateP(w, lb->elems[i].p, parent_old);
            break;
        }
        case Tag_Task: {
            Task* t = static_cast<Task*>(obj);
            if ((t->header.unboxed & 0x3) == 0) evacuateP(w, t->value.p, parent_old);
            evacuateP(w, t->callback, parent_old);
            evacuateP(w, t->kill, parent_old);
            evacuateP(w, t->task, parent_old);
            break;
        }
        case Tag_Process: {
            Process* pr = static_cast<Process*>(obj);
            evacuateP(w, pr->root, parent_old);
            evacuateP(w, pr->stack, parent_old);
            evacuateP(w, pr->mailbox, parent_old);
            break;
        }
        case Tag_Array: {
            ElmArray* arr = static_cast<ElmArray*>(obj);
            if ((arr->header.unboxed & 0x3) != 0) break;   // unboxed elements: no children
            u32 hi = arr->length;
            if (arr->length > MINOR_CHUNK_ELEMS) {
                for (uint64_t k = 1; k * MINOR_CHUNK_ELEMS < arr->length; ++k) {
                    pushGreyP(w, mk::chunkEntry(obj, static_cast<uint32_t>(k)));
                    ++w.chunks;
                }
                hi = MINOR_CHUNK_ELEMS;
            }
            for (u32 i = 0; i < hi; i++) evacuateP(w, arr->elements[i].p, parent_old);
            break;
        }
        case Tag_StringSlice:
            evacuateP(w, static_cast<ElmStringSlice*>(obj)->base, parent_old);
            break;
        case Tag_StringUtf8View:
            evacuateP(w, static_cast<ElmStringUtf8View*>(obj)->base, parent_old);
            break;
        case Tag_ByteBufferSlice:
            evacuateP(w, static_cast<ElmByteBufferSlice*>(obj)->base, parent_old);
            break;
        case Tag_StringRope: {
            ElmStringRope* r = static_cast<ElmStringRope*>(obj);
            evacuateP(w, r->left, parent_old);
            evacuateP(w, r->right, parent_old);
            break;
        }
        case Tag_LargeStringHeader:
        case Tag_LargeByteHeader:
            // Only a YLOS object can be an entry of such a tag; none exist
            // (large headers are fixed 16-byte nursery objects).
            break;
        default:
            break;
    }
}
// TLA-REGION(NP.scanEntryP) end

// ---------------------------------------------------------------------------
// The per-minor choice (P§3.2) and the parallel minor (P§3.1)
// ---------------------------------------------------------------------------

unsigned NurserySpace::chooseMinorWorkers(OldGenSpace& oldgen) {
    const bool force = test_force_parallel_engine_ && oldgen.config_->old_gen_bitmap_alloc;
    const unsigned n = oldgen.minorThreads();
    if (n <= 1 && !force) return 0;
    const size_t s = objectBytesAllocated();
    if (!force && s < config_->minor_parallel_min_bytes) {
#if ENABLE_GC_STATS
        stats.pmin.serial_small++;
#endif
        return 0;
    }
    // The to-space bound (P§3.2, as built): survivors <= s; a LAB is retired
    // only with at most lab/64 left and after at least lab - lab/64 bytes of
    // it were used, so retirements <= s / (lab - lab/64) + n (the + n covers a
    // short last LAB per worker), each wasting <= lab/64; plus one open tail
    // per worker at the end. Exact, so to-space cannot overflow.
    const size_t lab = config_->minor_lab_bytes;
    const size_t rmax = lab / 64;
    const size_t waste = (s / (lab - rmax) + n) * rmax + static_cast<size_t>(n) * lab;
    if (s + waste > slice_.capacity) {
#if ENABLE_GC_STATS
        stats.pmin.serial_space++;
#endif
        return 0;
    }
    return n;
}

// TLA-REGION(NP.minorGCParallel) begin
void NurserySpace::minorGCParallel(OldGenSpace& oldgen, const StackMapRoots& stackmap_roots,
                                   MinorGCRecord* rec, unsigned n) {
#if ENABLE_GC_PHASE_TIMERS
    const bool T = rec != nullptr;
    uint64_t tp = T ? GCStats::nowSinceProcessStartNs() : 0;
    auto lap = [&]() -> uint64_t {
        const uint64_t now = GCStats::nowSinceProcessStartNs();
        const uint64_t d = now - tp;
        tp = now;
        return d;
    };
#else
    (void)rec;
#endif
    par_oldgen_ = &oldgen;
    par_n_ = n;
    prefetch_children_ = config_->minor_prefetch_children;
    for (unsigned i = 0; i < n; ++i) {
        if (!minor_workers_[i]) minor_workers_[i] = std::make_unique<MinorWorker>();
        minor_workers_[i]->resetRun();
        minor_workers_[i]->index = i;
    }

    // (2) The pre-drain sweep slice (P§3.8.5): the per-promotion budget of the
    // serial path, times the previous minor's promotions (an object count).
    fifo_order_ = config_->minor_fifo_order;
    if (oldgen.gc_phase_ == GCPhase::Sweeping) {
        const size_t d = oldgen.config_->minor_sweep_divisor;
        const size_t per = (d == 0) ? 0 : oldgen.config_->sweep_work_budget / d;
        const size_t budget = per * last_minor_promoted_;
#if ENABLE_GC_STATS
        const uint64_t ts = GCStats::nowSinceProcessStartNs();
#endif
        if (budget > 0) oldgen.lazySweep(NUM_SIZE_CLASSES, budget);
#if ENABLE_GC_STATS
        stats.pmin.sweep_ns_sum += GCStats::nowSinceProcessStartNs() - ts;
#endif
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->par_sweep_ns = lap();
#endif

    // (1) Set up to-space and the promotion context.
    tospace_.reset(toBase(), toBase() + slice_.capacity, config_->minor_lab_bytes);
    OldGenSpace::PromoCtx& ctx = oldgen.promoCtx();
    oldgen.beginParallelPromotion(ctx, n);
    par_ctx_ = &ctx;

    // (3) Roots, serial, on worker 0 -- the serial phases in the same order.
    MinorWorker& w0 = *minor_workers_[0];
    for (HPointer* root : root_set.getRoots()) evacuateP(w0, *root, false);
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_longlived_jit_ns += lap();
#endif
    for (HPointer* root : stackmap_roots.get()) evacuateP(w0, *root, false);
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_stackmap_ns = lap();
#endif
    for (uint64_t* root : root_set.getJitRoots()) evacuateRawP(w0, *root);
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_longlived_jit_ns += lap();
#endif
    for (const auto& range : root_set.getStackRootRanges()) {
        for (size_t i = 0; i < range.count; ++i) {
            if (stackRangeSlotIsRoot(range.hpointer_mask, i)) evacuateP(w0, range.base[i], false);
        }
    }
    for (HPointer* slot : root_set.getSingleRoots()) evacuateP(w0, *slot, false);
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->roots_ranges_ns = lap();
#endif
    {
        const auto& scanners = root_set.getExternalRootScanners();
        for (size_t i = 0; i < scanners.size(); ++i) {
#if ENABLE_GC_PHASE_TIMERS
            uint64_t slots = 0;
            const uint64_t ts = T ? GCStats::nowSinceProcessStartNs() : 0;
#endif
            scanners[i]([&](uint64_t& ref) {
#if ENABLE_GC_PHASE_TIMERS
                ++slots;
#endif
                HPointer& hp = reinterpret_cast<HPointer&>(ref);
                if (hp.ptr_ind != 0) return;
                evacuateP(w0, hp, false);
            });
#if ENABLE_GC_PHASE_TIMERS
            if (T) {
                const size_t k = i < static_cast<size_t>(GC_EXT_SCANNER_CAP)
                                     ? i : static_cast<size_t>(GC_EXT_SCANNER_CAP - 1);
                rec->ext_ns[k] += GCStats::nowSinceProcessStartNs() - ts;
                rec->ext_slots[k] += slots;
            }
#endif
        }
#if ENABLE_GC_PHASE_TIMERS
        if (T) {
            rec->ext_count = static_cast<int>(std::min(scanners.size(),
                                              static_cast<size_t>(GC_EXT_SCANNER_CAP)));
            rec->roots_external_ns = lap();
            rec->par_roots_ns = rec->roots_longlived_jit_ns + rec->roots_stackmap_ns +
                                rec->roots_ranges_ns + rec->roots_external_ns;
        }
#endif
    }

    // (4) Distribute worker 0's greys round-robin (no member runs yet; the
    // gang start is a mutex release/acquire).
    {
        std::vector<uint64_t> greys;
        greys.swap(w0.stack);
        const size_t h0 = w0.head;
        w0.head = 0;
        w0.priv.store(0, std::memory_order_relaxed);
        for (size_t i = h0; i < greys.size(); ++i) minor_workers_[(i - h0) % n]->deque.push(greys[i]);
    }

    // (5) The drain.
    gc::GCMarkGang* gang = n > 1 ? &oldgen.ensureGang() : nullptr;
    const unsigned jitter = gang ? gang->jitterUs() : 0;
    mk::SliceControl ctl(mk::kDrainBudget, n, jitter, n);
    for (unsigned i = 0; i < n; ++i) minor_workers_[i]->ctr.resetRun(i);
    const uint64_t cpu0 = gang ? gang->stats().member_cpu_ns.load(std::memory_order_relaxed) : 0;
    if (n == 1) {
        MinorEnv env{*this};
        mk::runMarkerLoop(env, 0, ctl);
    } else {
        MinorRunArgs args{this, &ctl};
        gang->run(&NurserySpace::minorWorkerEntry, &args, n);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->par_drain_ns = lap();
#endif
    for (unsigned i = 0; i < n; ++i) {
        MinorWorker& w = *minor_workers_[i];
        if (w.stack.size() != w.head || !w.deque.emptyApprox()) {
            std::fprintf(stderr, "[gc] FATAL: parallel minor: work left in worker %u after "
                         "termination\n", i);
            std::fflush(stderr);
            std::abort();
        }
        w.deque.reset();   // retires grown arrays: nothing runs any more
    }

    // (6) Close the LABs: trim the one at the top, fill the others' tails.
    uint64_t filler = 0;
    {
        minorwork::Lab labs[OldGenSpace::kMaxMinorWorkers];
        for (unsigned i = 0; i < n; ++i) labs[i] = minor_workers_[i]->lab;
        bool skip_once = test_minor_skip_filler_;
        filler = mw::closeLabs(tospace_, labs, n, [&](char* p, size_t bytes) {
            if (skip_once) { skip_once = false; return; }   // negative control (PM3)
            writeFiller(p, bytes);
        });
        for (unsigned i = 0; i < n; ++i) filler += minor_workers_[i]->lc.filler_bytes;
    }
    copy_ptr_ = tospace_.top.load(std::memory_order_relaxed);
    scan_ptr_ = copy_ptr_;
    filler_bytes_to_ = filler;

    // (7) Merge, in worker order.
    uint64_t n_prom = 0, n_surv = 0, b_surv = 0;
    uint64_t min_units = UINT64_MAX, max_units = 0;
    young_large_scan_.clear();
    promoted_buf_.clear();
    for (unsigned i = 0; i < n; ++i) {
        MinorWorker& w = *minor_workers_[i];
        n_prom += w.n_prom + w.n_ylos_prom;
        n_surv += w.n_surv;
        b_surv += w.b_surv;
        min_units = std::min(min_units, w.ctr.units);
        max_units = std::max(max_units, w.ctr.units);
        young_large_scan_.insert(young_large_scan_.end(), w.ylos_young.begin(), w.ylos_young.end());
#if ECO_HEAP_VALIDATE || P1_CENSUS_COMPILED
        promoted_buf_.insert(promoted_buf_.end(), w.promoted_log.begin(), w.promoted_log.end());
#endif
#if ENABLE_GC_STATS
        stats.mergeCopyCounts(w.copies);
        stats.lp.ylos_reach_calls += w.ylos_reach_calls;
        stats.lp.ylos_scans += w.ylos_scans;
        ParMinorStats& p = stats.pmin;
        p.lab_claims += w.lc.lab_claims;
        p.direct_claims += w.lc.direct_claims;
        p.claim_races += w.claim_races;
        p.busy_waits += w.busy_waits;
        p.spine_splits += w.spine_splits;
        p.chunks += w.chunks;
        p.steals += w.ctr.steals;
        p.steal_aborts += w.ctr.steal_aborts;
        p.idle_spins += w.ctr.idle_spins;
        p.idle_yields += w.ctr.idle_yields;
        p.idle_sleeps += w.ctr.idle_sleeps;
#endif
    }
    last_minor_promoted_ = n_prom;
    // Deferred large-body operations (P§3.9): promote-all, then mark-seen.
    for (unsigned i = 0; i < n; ++i)
        for (const HPointer& b : minor_workers_[i]->lb_promoted) oldgen.promoteLargeHeader(b);
    for (unsigned i = 0; i < n; ++i)
        for (const HPointer& b : minor_workers_[i]->lb_seen) oldgen.markLargeBodySeen(b, minor_color_);
    uint64_t mutex_wait = 0, mutex_acq = 0;
    for (unsigned i = 0; i < n; ++i) {
        mutex_wait += ctx.w[i].mutex_wait_ns;
        mutex_acq += ctx.w[i].mutex_acquires;
    }
    oldgen.endParallelPromotion(ctx);
    par_ctx_ = nullptr;
#if ENABLE_GC_STATS
    {
        ParMinorStats& p = stats.pmin;
        p.minors_parallel++;
        p.workers_sum += n;
        p.filler_bytes_total += filler;
        if (filler > p.filler_bytes_max) p.filler_bytes_max = filler;
        p.promo_mutex_acquires += mutex_acq;
        p.promo_mutex_wait_ns += mutex_wait;
        p.imbalance_units_sum += (max_units - min_units);
        if (gang) p.member_cpu_ns += gang->stats().member_cpu_ns.load(std::memory_order_relaxed) - cpu0;
    }
#else
    (void)cpu0; (void)mutex_wait; (void)mutex_acq;
#endif

#if ECO_HEAP_VALIDATE
    // (8) PM1 / PM2 / PM3 over the to-space prefix.
    {
        uint64_t objs = 0, bytes = 0, fill = 0;
        for (char* p = toBase(); p < copy_ptr_;) {
            const Header* h = getHeader(p);
            if (h->tag > Tag_Forward) pmFail("PM3: to-space does not parse", p, nullptr, h->tag);
            const size_t sz = getObjectSize(p);
            if (sz == 0 || p + sz > copy_ptr_) pmFail("PM3: to-space object overruns the top", p, copy_ptr_, sz);
            if (h->tag == Tag_Free) {
                if (sz < 8 || sz % 8 != 0) pmFail("PM3: bad filler size", p, nullptr, sz);
                fill += sz;
            } else {
                ++objs;
                bytes += sz;
                visitHeapChildren(p, [&](HPointer& hp) {   // PM2: every slot updated
                    if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                    void* c = Allocator::fromPointerRaw(hp);
                    if (c != nullptr && isInFromSpace(c))
                        pmFail("PM2: a to-space copy still points into from-space", p, c);
                });
            }
            p += sz;
        }
        if (fill != filler) pmFail("PM3: filler bytes found != filler_bytes_to_", toBase(), nullptr, fill, filler);
        if (objs != n_surv || bytes != b_surv)
            pmFail("PM1: to-space objects/bytes != copies counted (a lost or double copy)",
                   toBase(), copy_ptr_, objs, n_surv);
        uint64_t logged = promoted_buf_.size();
        if (logged != n_prom) pmFail("PM1: promoted log != promotions counted", nullptr, nullptr, logged, n_prom);
    }
#endif
#if ENABLE_GC_PHASE_TIMERS
    if (T) {
        rec->workers = n;
        rec->filler_bytes = filler;
        rec->mutex_wait_ns = mutex_wait;
        rec->imbalance_units = max_units - min_units;
        rec->par_close_ns = lap();
    }
#endif
#if ENABLE_GC_STATS
    stats.pmin.drain_ns_sum += 0;   // drain/sweep sums come from the phase timers (P§3.12)
#endif
    par_oldgen_ = nullptr;
}
// TLA-REGION(NP.minorGCParallel) end

}  // namespace Elm
