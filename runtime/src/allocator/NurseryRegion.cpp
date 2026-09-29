// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md, HEAP_069 /
// HEAP_070): the region nursery. An eden plus k + 2 survivor extents per heap
// (k = the tenure age, threaded-gc-07b); a minor evacuates eden (and the
// previous fill's builder area) into the Free extent, RECORDS references into
// the extent filled k minors ago (the hand-over) and into the ageing extents
// in between, RESOLVES references into the extent tenured during the last
// epoch, and retires that one. The tenure job (NurseryTenure.cpp) marks the
// ageing extents and promotes the hand-over extent's live objects off-header.
//
//   minor m:  Free -> Fill (G_m), Young(a < k) -> Age, Young(k) -> Hand (G_{m-k}),
//             Tenuring -> Retire (G_{m-k-1})
//   end:      Fill -> Young(1), Age: a + 1, Hand -> Tenuring (job m), Retire -> Free
//
// The drain runs on phase 6's engine (markwork::runMarkerLoop, LABs,
// Tag_Free fillers, the header claim/publish protocol) at any worker count,
// with its own child classification (P§3.4's rule table). The pause never
// promotes.

#include "NurserySpace.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Allocator.hpp"
#include "GCHelperPool.hpp"
#include "HeapChildWalk.hpp"
#include "NurseryChildWalk.hpp"
#include "OldGenSpace.hpp"
#include "PermanentSpace.hpp"
#include "StackMapRoots.hpp"

bool nursery_poison_enabled();   // NurserySpace.cpp

namespace Elm {

namespace mw = minorwork;
namespace mk = markwork;
namespace tw = tenurework;
using region::Role;

namespace {

inline Header headerOfWord(uint64_t w) {
    Header h;
    std::memcpy(&h, &w, sizeof(h));
    return h;
}
inline uint64_t wordOfHeader(const Header& h) {
    uint64_t w;
    std::memcpy(&w, &h, sizeof(w));
    return w;
}

[[noreturn]] void regionFatal(const char* what, const void* a = nullptr, const void* b = nullptr,
                              uint64_t x = 0, uint64_t y = 0) {
    std::fprintf(stderr, "[gc] FATAL: region nursery: %s (%p %p %llu %llu)\n", what, a, b,
                 (unsigned long long)x, (unsigned long long)y);
    std::fflush(stderr);
    std::abort();
}

// Largest size class the old gen has for this config (HEAP_069's region cap,
// P§3.13): classes cover 8..256 B, then 512 B << k up to the largest power of
// two <= large_object_threshold (OldGenSpace's computeNumSizeClasses).
size_t largestClassBytes(const HeapConfig& c, size_t* n_classes) {
    size_t n = NUM_SMALL_CLASSES;
    size_t cap = MAX_SMALL_SIZE;
    size_t cell = MEDIUM_CLASS_BASE;
    for (size_t i = 0; i < NUM_MEDIUM_CLASSES_MAX; ++i) {
        if (cell > c.large_object_threshold) break;
        cap = cell;
        ++n;
        cell <<= 1;
    }
    if (n_classes) *n_classes = n;
    return cap;
}

}  // namespace

// ---------------------------------------------------------------------------
// The ring (P§3.3)
// ---------------------------------------------------------------------------

void RegionState::rebuildRoles(bool in_minor_roles) {
    for (auto& r : role_of_k) r = static_cast<uint8_t>(Role::Stale);
    role_of_k[eden_k[eden_cur]] = static_cast<uint8_t>(Role::Eden);
    for (unsigned u = 0; u < n_surv; ++u) {
        const int i = static_cast<int>(u);
        const region::Extent& X = x[u];
        Role r = Role::Stale;
        if (in_minor_roles) {
            if (i == fill) r = Role::Fill;
            else if (i == hand) r = Role::Hand;
            else if (i == retire) r = Role::Retire;
            else if (X.state == region::XState::Young) r = Role::Age;
        } else {
            if (X.state == region::XState::Young) r = X.age == 1 ? Role::Fresh : Role::Aged;
            else if (X.state == region::XState::Tenuring) r = Role::Tenuring;
        }
        role_of_k[X.k] = static_cast<uint8_t>(r);
    }
    // In a minor the previous fill's builder area is PrevBuilders (evacuated
    // like eden); every other builder area but the Fresh one is stale.
    prev_k = ~0u;
    prev_bld_off = SIZE_MAX;
    if (in_minor_roles && prev >= 0) {
        prev_k = x[prev].k;
        prev_bld_off = static_cast<size_t>(x[prev].bld_lo - x[prev].base);
    }
}

void NurserySpace::initRegions() {
    rg_ = std::make_unique<RegionState>();
    RegionState& R = *rg_;
    size_t initial = config_->nurseryInitialPerSideBytes();
    if (initial > growth_ceiling_bytes_) initial = growth_ceiling_bytes_;
    R.set = allocator_->acquireNurserySliceSet(initial);
    if (R.set.capacity == 0) regionFatal("failed to commit the region slice set", nullptr, nullptr, initial);
    R.n_ext = R.set.n;
    R.tenure_age = config_->regionTenureAge();
    R.n_surv = config_->regionSurvivorExtents();
    if (R.n_surv > static_cast<unsigned>(region::kMaxSurv) || R.n_ext < R.n_surv + 1)
        regionFatal("bad region geometry", nullptr, nullptr, R.n_ext, R.n_surv);
    R.flip = R.n_ext == R.n_surv + 2;
    R.eden_k[0] = 0;
    R.eden_k[1] = R.flip ? 1 : 0;
    R.eden_cur = 0;
    R.stride_log2 = R.set.stride_log2;
    R.stride_mask = (size_t{1} << R.stride_log2) - 1;
    R.shadow_shift = config_->shadow_granule_log2;
    for (unsigned i = 0; i < R.n_surv; ++i) {
        region::Extent& X = R.x[i];
        X.k = R.n_ext - R.n_surv + i;
        X.base = R.set.extent(X.k);
        X.state = region::XState::Free;
        X.gen = 0;
        X.clearContents();
        const size_t entries = (size_t{1} << R.stride_log2) >> R.shadow_shift;
        if (!R.shadow[i].reserve(entries)) regionFatal("shadow reservation failed", nullptr, nullptr, entries);
        R.shadow[i].ensureCommitted(R.set.capacity >> R.shadow_shift);
    }
    R.eden_base = R.set.extent(R.eden_k[0]);
    R.eden_dirty[0] = R.set.extent(R.eden_k[0]);
    R.eden_dirty[1] = R.set.extent(R.eden_k[1]);
    R.rw.resize(OldGenSpace::kMaxMinorWorkers);
    R.rebuildRoles(false);

    // contains() covers the whole slot block (roleOf != NotMine); the high
    // range is empty.
    low_base_ = R.set.slot_base;
    low_end_ = R.set.slot_base + (static_cast<size_t>(R.n_ext) << R.stride_log2);
    high_base_ = high_end_ = nullptr;
    from_is_low_ = true;
    refreshCapacityCaches();
    size_t n_classes = 0;
    region_large_cap_ = largestClassBytes(*config_, &n_classes);
    bump_.ptr = R.eden_base;
    survivor_end_ = R.eden_base;
    filler_bytes_ = filler_bytes_to_ = 0;
    R.S_m = 0;
    bump_.end = computeAllocEnd();
#if ENABLE_GC_STATS
    stats.nursery_size_bytes = 2 * R.set.capacity;
    // E2 determinism probe (stats builds only; never a shipped setting): every
    // tenure job stops after this many items and is finished by help.
    {
        static const uint64_t stop_after = [] {
            const char* e = std::getenv("ECO_TEST_TENURE_STOP_AFTER");
            return e ? std::strtoull(e, nullptr, 10) : 0ull;
        }();
        test_tenure_force_stop_after_ = stop_after;
    }
#endif
}

void NurserySpace::releaseRegions() {
    if (!rg_) return;
    if (allocator_ && rg_->set.capacity != 0) allocator_->releaseNurserySliceSet(rg_->set);
    rg_.reset();
}

void NurserySpace::regionCheckAndGrow() {
    RegionState& R = *rg_;
    const size_t cap = R.set.capacity;
    if (cap == 0) return;
    // The same float comparison as legacy checkAndGrow on the same object
    // bytes (P§3.8): growth events and the final capacity are object class.
    const float occupancy = static_cast<float>(R.S_m) / static_cast<float>(cap);
    if (occupancy <= growth_threshold_) return;
    if (cap >= growth_ceiling_bytes_) return;
    const size_t quantum = config_->alloc_buffer_size;
    size_t delta = cap / 2;
    delta -= delta % quantum;
    if (delta < quantum) delta = quantum;
    const size_t room = growth_ceiling_bytes_ - cap;
    if (delta > room) delta = room;
    if (delta == 0) return;
    if (!allocator_->growNurserySliceSet(R.set, delta)) {
        if (Allocator::heapTraceEnabled()) {
            std::fprintf(stderr, "[heap-trace] region nursery grow declined: +%zu KB refused "
                         "(capacity %zu KB/extent)\n", delta / 1024, cap / 1024);
        }
        return;
    }
    for (unsigned i = 0; i < R.n_surv; ++i) R.shadow[i].ensureCommitted(R.set.capacity >> R.shadow_shift);
    refreshCapacityCaches();
#if ENABLE_GC_STATS
    stats.nursery_grow_events++;
    stats.nursery_size_bytes = 2 * R.set.capacity;
#endif
}

void* NurserySpace::majorRedirect(void* obj) const {
    RegionState& R = *rg_;
    const region::TenureJob& J = R.job;
    if (J.state != region::TenureJob::State::Merged || J.x < 0) return obj;
    const region::Extent& X = R.x[J.x];
    if (X.state != region::XState::Tenuring) return obj;
    char* p = static_cast<char*>(obj);
    if (p < X.base || p >= X.surv_top) return obj;
    char* d = tw::lookup(R.shadowWord(J.x, obj), X.gen);
    if (d == nullptr) regionFatal("TV1: a STW major reached an untenured object of the tenured extent", obj);
    return d;
}

// ---------------------------------------------------------------------------
// TV7: the region form of the stale-pointer detector
// ---------------------------------------------------------------------------
#if ECO_HEAP_VALIDATE
void NurserySpace::regionAssertValidPointer(void* ptr) const {
    const RegionState& R = *rg_;
    const char* p = static_cast<const char*>(ptr);
    const Role r = R.roleOf(p);
    bool ok = false;
    auto inSurv = [&](int i) { return i >= 0 && p >= R.x[i].base && p < R.x[i].surv_top; };
    auto inBld = [&](int i) { return i >= 0 && p >= R.x[i].bld_lo && p < R.x[i].bld_hi; };
    switch (r) {
        case Role::Eden: ok = p >= R.eden_base && p < bump_.ptr; break;
        case Role::Fresh:
        case Role::Aged:
        case Role::Tenuring: {
            const int i = R.extentOf(p);
            ok = inSurv(i) || (r == Role::Fresh && inBld(i));
            break;
        }
        case Role::Hand: ok = R.in_minor && inSurv(R.hand); break;
        case Role::PrevBuilders: ok = R.in_minor && inBld(R.prev); break;
        case Role::Age: ok = R.in_minor && inSurv(R.extentOf(p)); break;
        case Role::Retire: ok = R.in_minor && inSurv(R.retire); break;
        case Role::Fill:
            ok = R.in_minor && ((p >= R.fill_base && p < tospace_.top.load(std::memory_order_relaxed)) ||
                                (p >= R.bld_bottom.load(std::memory_order_relaxed) && p < R.fill_end));
            break;
        case Role::NotMine: ok = true; break;
        case Role::Stale: ok = false; break;
    }
    if (!ok) {
        std::fprintf(stderr, "[heap-validate] TV7: stale nursery pointer %p (role %s, in_minor %d, "
                     "eden [%p, %p))\n", ptr, region::roleName(r), (int)R.in_minor,
                     (void*)R.eden_base, (void*)bump_.ptr);
        for (unsigned i = 0; i < R.n_surv; ++i) {
            std::fprintf(stderr, "  extent %u k=%u state=%d age=%u [%p, %p) bld [%p, %p) gen %u\n", i,
                         R.x[i].k, (int)R.x[i].state, R.x[i].age, (void*)R.x[i].base, (void*)R.x[i].surv_top,
                         (void*)R.x[i].bld_lo, (void*)R.x[i].bld_hi, R.x[i].gen);
        }
        std::fflush(stderr);
        std::abort();
    }
}
#endif

// ---------------------------------------------------------------------------
// The region drain (P§3.5 steps 3-6)
// ---------------------------------------------------------------------------

struct NurserySpace::RegionEnv {
    static constexpr bool kParallel = true;
    NurserySpace& ns;
    mk::MarkerCounters& counters(unsigned i) { return ns.minor_workers_[i]->ctr; }
    uint64_t takeOwn(unsigned i) {
        MinorWorker& w = *ns.minor_workers_[i];
        if (w.stack.size() != w.head) {
            const uint64_t e = w.stack.back();
            w.stack.pop_back();
            w.priv.store(w.stack.size() - w.head, std::memory_order_relaxed);
            if ((++w.pops & 63) == 0) ns.publishHalfP(w);
            return e;
        }
        return w.deque.take();
    }
    uint64_t stealFrom(unsigned v) { return ns.minor_workers_[v]->deque.steal(); }
    bool anyWork() {   // only stealable work wakes an idle worker (6-P§10.1)
        for (unsigned i = 0; i < ns.par_n_; ++i)
            if (!ns.minor_workers_[i]->deque.emptyApprox()) return true;
        return false;
    }
    void prefetch(uint64_t e) {
        if (!ns.prefetch_children_ || mk::isChunk(e)) return;
        void* obj = mk::entryAddr(e);
        const Header* h = getHeader(obj);
        const RegionState& R = *ns.rg_;
        auto pf = [&](const HPointer& hp) {
            if (hp.ptr_ind != 0 || hp.ptr == 0) return;
            void* c = Allocator::fromPointerRaw(hp);
            const Role r = R.roleOf(c);
            if (r == Role::Eden || r == Role::PrevBuilders) __builtin_prefetch(c, 1, 3);
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
    void scan(unsigned self, uint64_t e) { ns.scanEntryR(*ns.minor_workers_[self], e); }
    void publishAll(unsigned self) { ns.publishAllP(*ns.minor_workers_[self]); }
};

namespace {
struct RegionRunArgs {
    NurserySpace* ns;
    mk::SliceControl* ctl;
};
}  // namespace

void NurserySpace::regionWorkerEntry(void* ctx, unsigned member) {
    RegionRunArgs* a = static_cast<RegionRunArgs*>(ctx);
    RegionEnv env{*a->ns};
    mk::runMarkerLoop(env, member, *a->ctl);
}

void* NurserySpace::resolveRetire(void* t, region::RegionWorker* rw) {
    RegionState& R = *rg_;
    const int xi = R.retire;
    const region::Extent& X = R.x[xi];
    const char* p = static_cast<const char*>(t);
    if (p < X.base || p >= X.surv_top) {
        regionFatal("a reference into the retiring extent outside its survivor part "
                    "(a stale builder-area pointer)", t, X.surv_top);
    }
    char* d = tw::lookup(R.shadowWord(xi, t), X.gen);
    if (d == nullptr) {
        // TV1 (every build): the target was not tenured; after retirement it
        // would dangle.
        regionFatal("TV1: resolve found no forwarding for a tenured-extent object "
                    "(its tenure job missed it)", t, nullptr, X.gen);
    }
    if (rw) ++rw->resolved;
    return d;
}

void* NurserySpace::copyClaimedR(MinorWorker& w, region::RegionWorker& rw, void* obj, uint64_t hw) {
    RegionState& R = *rg_;
    Header hd = headerOfWord(hw);
#if ECO_HEAP_VALIDATE
    if (hd.tag > Tag_Forward) regionFatal("invalid tag in a claimed object", obj, nullptr, hd.tag);
#endif
    const size_t size = getObjectSizeFromHeader(&hd);
    // TV9 (every build): nothing in eden or a builder area has survived as a
    // non-builder, so the pause never promotes (P§3.5).
    if (__builtin_expect(hd.age != 0, 0)) regionFatal("TV9: an eden / builder-area object with age != 0", obj, nullptr, hd.age, hd.tag);
    char* dst;
    uint32_t col;
    if (hd.builder) {
        char* b = R.bld_bottom.fetch_sub(size, std::memory_order_relaxed) - size;
        if (b < R.fill_base) regionFatal("the fill's builder area overflowed", b, R.fill_base, size);
        dst = b;
        ++rw.n_bld;
        rw.b_bld += size;
        col = kColBuilder;   // age stays 0 (HEAP_BUILDER_002)
    } else {
        const size_t cls = OldGenSpace::sizeClass(size);
        if (__builtin_expect(size > region_large_cap_ || cls >= NUM_SIZE_CLASSES, 0)) {
            // TV9 (every build): the region cap makes this unreachable (P§3.13).
            regionFatal("TV9: a nursery object without an old-gen size class", obj, nullptr, size, hd.tag);
        }
        dst = mw::labAllocate(tospace_, w.lab, w.lc, size, &NurserySpace::writeFiller);
        hd.age = 1;
        if (size < 16) {
            ++rw.under16;
            // A 16-byte shadow granule (lever L6) needs every survivor >= 16 B.
            // HEAP_071 makes that hold for every heap: validate builds abort at
            // any granule so a new header-only layout fails the validate gate.
            if (ECO_HEAP_VALIDATE || R.shadow_shift > 3) regionFatal("a survivor under 16 B with a 16-byte shadow granule", obj, nullptr, size, hd.tag);
        }
        ++rw.class_count[cls];
        ++rw.n_fill;
        rw.b_fill += size;
        col = kColSurv;
    }
    hd.color = static_cast<u32>(Color::White);
    ++w.n_surv;
    w.b_surv += size;
#if ENABLE_GC_STATS
    w.copies.survival(static_cast<Tag>(hd.tag), size, hd.size);
#endif
    if (hd.tag == Tag_LargeStringHeader || hd.tag == Tag_LargeByteHeader) {
        const HPointer body = static_cast<LargeStringHeader*>(obj)->body;
        w.lb_seen.push_back(body);
        if (!hd.builder) rw.lb_bodies.push_back(body);
    }
    std::memcpy(static_cast<char*>(dst) + sizeof(Header), static_cast<char*>(obj) + sizeof(Header),
                size - sizeof(Header));
    const uint64_t nw = wordOfHeader(hd);
    std::memcpy(dst, &nw, sizeof(nw));
    mw::publish(obj, dst, mw::colorOf(hw));
    (void)col;
    return dst;
}

void NurserySpace::evacuateR(MinorWorker& w, region::RegionWorker& rw, HPointer& slot, uint32_t col) {
#if ECO_HEAP_VALIDATE
    {
        uint64_t raw;
        std::memcpy(&raw, &slot, sizeof(raw));
        if (raw == 0xD8D8D8D8D8D8D8D8ull) regionFatal("POISON READ AS A BOXED SLOT (region minor)", &slot);
    }
#endif
    if (slot.ptr_ind != 0 || slot.ptr == 0) return;
    void* obj = Allocator::fromPointerRaw(slot);
    if (obj == nullptr) return;
    RegionState& R = *rg_;
    switch (R.roleOf(obj)) {
        case Role::NotMine: {
            char* p = static_cast<char*>(obj);
            if (p < heap_base_ || p >= heap_base_ + heap_reserved_) return;   // permanent space
            if (__builtin_expect(par_oldgen_->mayBeYoungLarge(obj), 0)) reachYoungLargeR(w, rw, obj);
            return;
        }
        case Role::Eden:
        case Role::PrevBuilders: {
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
            void* dst = copyClaimedR(w, rw, obj, hw);
            slot = Allocator::toPointerRaw(dst);
            const Header* dh = getHeader(dst);
            if (nurseryTagHasChildren(dh->tag))
                pushGreyP(w, mk::objEntry(dst, dh->builder ? kColBuilder : kColSurv));
            return;
        }
        case Role::Hand:
            // P§3.6: heap slots the pause will not rescan -> H; roots and
            // builder slots (rescanned at the next minor) -> S (trap 8).
            if (col == kColSurv || col == kColYoungYlos) rw.H.push_back(reinterpret_cast<uint64_t*>(&slot));
            else rw.S.push_back(obj);
            return;
        case Role::Age:
            // threaded-gc-07b: an ageing object stays; it is a mark source of
            // this minor's job (never a heal slot: a fill-copy holder is found
            // by the mark of its own target's hand-over).
            rw.SA.push_back(obj);
            return;
        case Role::Retire:
            slot = Allocator::toPointerRaw(resolveRetire(obj, &rw));
            return;
        case Role::Fill:
            // Already a copy. A root slot can be listed twice (two root sets,
            // duplicate stack-map slots): its second visit lands here.
            return;
        default:
            regionFatal("TV7: a stale nursery pointer met by the region minor", obj, &slot,
                        static_cast<uint64_t>(R.roleOf(obj)), col);
    }
}

void NurserySpace::reachYoungLargeR(MinorWorker& w, region::RegionWorker& rw, void* obj) {
    RegionState& R = *rg_;
    uint64_t e = 0;
    {
        std::lock_guard<std::mutex> g(ylos_mu_);
        OldGenSpace::LargeBodyMeta* m = par_oldgen_->youngLargeMeta(obj);
        if (m == nullptr) return;   // an old object inside the bounding box
        ++w.ylos_reach_calls;
        // A hand-over member (generation m-1): reached, scanned read-only
        // (its Hand targets go to S); promoted at the next merge (P§3.14).
        const long k = tw::ylosFind(R.hand_ylos, obj);
        if (k >= 0) {
            if (R.hand_ylos_reached[static_cast<size_t>(k)]) return;
            R.hand_ylos_reached[static_cast<size_t>(k)] = 1;
            ++rw.ylos_handover_reached;
            e = mk::objEntry(obj, kColHandYlos);
        } else if (!R.age_ylos.empty() && tw::ylosFind(R.age_ylos, obj) >= 0) {
            // threaded-gc-07b: an ageing generation's member (coloured by the
            // hand-over preparation, so this test comes first): the job's mark
            // scans it; the pause only records it.
            rw.SA.push_back(obj);
            return;
        } else {
            if (m->color == minor_color_) return;   // already reached this minor
            m->color = minor_color_;
            Header* h = getHeader(obj);
            if (h->builder) {
                e = mk::objEntry(obj, kColBuilder);   // scanned in place every reach
            } else {
#if ECO_HEAP_VALIDATE
                if (h->age != 0) regionFatal("a young large object reached first with age != 0", obj, nullptr, h->age);
#endif
                h->age = 1;
                rw.ylos_gen.push_back(obj);           // joins generation m
                w.ylos_young.push_back(obj);
                e = mk::objEntry(obj, kColYoungYlos);
            }
        }
    }
    pushGreyP(w, e);
}

void NurserySpace::spineRunR(MinorWorker& w, region::RegionWorker& rw, Cons* prev, uint32_t col) {
    RegionState& R = *rg_;
    Cons* first = nullptr;
    size_t k = 0;
    bool truncated = false, needs_heads = false;
    uint32_t pcol = col;
    for (;;) {
        const HPointer t = prev->tail;
        if (t.ptr_ind != 0 || t.ptr == 0) break;
        void* obj = Allocator::fromPointerRaw(t);
        if (obj == nullptr) break;
        const Role r = R.roleOf(obj);
        if (r != Role::Eden && r != Role::PrevBuilders) { evacuateR(w, rw, prev->tail, pcol); break; }
        uint64_t hw = mw::loadHeader(obj);
        if (mw::isForwardWord(hw)) {
            if (hw == mw::kBusy) hw = waitPublishedP(w, obj);
            prev->tail = Allocator::toPointerRaw(mw::fwdAddr(hw));
            break;
        }
        const Header hd = headerOfWord(hw);
        if (hd.tag != Tag_Cons || hd.builder) { evacuateR(w, rw, prev->tail, pcol); break; }
        if (k == MINOR_SPINE_RUN) {
            pushGreyP(w, mk::objEntry(prev, pcol));   // its scan continues the spine
            ++w.spine_splits;
            truncated = true;
            break;
        }
        if (!mw::claim(obj, hw)) { ++w.claim_races; continue; }
        Cons* cc = static_cast<Cons*>(copyClaimedR(w, rw, obj, hw));
        if (Elm::tupleFieldKind(cc->header.unboxed, 0) == 0 && cc->head.p.ptr_ind == 0) needs_heads = true;
        prev->tail = Allocator::toPointerRaw(cc);
        if (k == 0) first = cc;
        prev = cc;
        pcol = kColSurv;
        ++k;
    }
    if (needs_heads && k > 0) {
        const size_t m = truncated ? k - 1 : k;
        Cons* c = first;
        for (size_t i = 0; i < m; ++i) {
            if (Elm::tupleFieldKind(c->header.unboxed, 0) == 0) evacuateR(w, rw, c->head.p, kColSurv);
            if (i + 1 < m) c = static_cast<Cons*>(Allocator::fromPointerRaw(c->tail));
        }
    }
}

void NurserySpace::scanEntryR(MinorWorker& w, uint64_t e) {
    region::RegionWorker& rw = rg_->rw[w.index];
    void* obj = mk::entryAddr(e);
    Header* hdr = getHeader(obj);
    if (mk::isChunk(e)) {
        const uint32_t f = mk::entryField(e);
        const uint64_t k = f >> 3;
        const uint32_t col = f & 7;
        if (hdr->tag == Tag_Array) {
            ElmArray* arr = static_cast<ElmArray*>(obj);
            const uint64_t lo = k * MINOR_CHUNK_ELEMS;
            const uint64_t hi = std::min<uint64_t>(arr->length, lo + MINOR_CHUNK_ELEMS);
            for (uint64_t i = lo; i < hi; ++i) evacuateR(w, rw, arr->elements[i].p, col);
        } else {
            ListBacking* lb = static_cast<ListBacking*>(obj);
            const uint64_t lo = lb->hd + k * MINOR_CHUNK_ELEMS;
            const uint64_t hi = std::min<uint64_t>(hdr->size, lo + MINOR_CHUNK_ELEMS);
            for (uint64_t i = lo; i < hi; ++i) evacuateR(w, rw, lb->elems[i].p, col);
        }
        return;
    }
    const uint32_t col = mk::entryField(e);
    if (col == kColYoungYlos || col == kColHandYlos) ++w.ylos_scans;
    auto ev = [&](HPointer& hp) { evacuateR(w, rw, hp, col); };
    switch (hdr->tag) {
        case Tag_Cons: {
            Cons* c = static_cast<Cons*>(obj);
            if (Elm::tupleFieldKind(hdr->unboxed, 0) == 0) ev(c->head.p);
            if (use_hybrid_dfs_) spineRunR(w, rw, c, col);
            else ev(c->tail);
            break;
        }
        case Tag_ListBacking: {
            if ((hdr->unboxed & 0x3) != 0) break;
            ListBacking* lb = static_cast<ListBacking*>(obj);
            u32 hi = hdr->size;
            if (hdr->size - lb->hd > MINOR_CHUNK_ELEMS) {
                for (uint64_t k = 1; lb->hd + k * MINOR_CHUNK_ELEMS < hdr->size; ++k) {
                    pushGreyP(w, mk::chunkEntry(obj, static_cast<uint32_t>((k << 3) | col)));
                    ++w.chunks;
                }
                hi = lb->hd + MINOR_CHUNK_ELEMS;
            }
            for (u32 i = lb->hd; i < hi; i++) ev(lb->elems[i].p);
            break;
        }
        case Tag_Array: {
            ElmArray* arr = static_cast<ElmArray*>(obj);
            if ((arr->header.unboxed & 0x3) != 0) break;
            u32 hi = arr->length;
            if (arr->length > MINOR_CHUNK_ELEMS) {
                for (uint64_t k = 1; k * MINOR_CHUNK_ELEMS < arr->length; ++k) {
                    pushGreyP(w, mk::chunkEntry(obj, static_cast<uint32_t>((k << 3) | col)));
                    ++w.chunks;
                }
                hi = MINOR_CHUNK_ELEMS;
            }
            for (u32 i = 0; i < hi; i++) ev(arr->elements[i].p);
            break;
        }
        default:
            forEachChildSlot(obj, ev);
            break;
    }
}

// ---------------------------------------------------------------------------
// The region minor (P§3.5)
// ---------------------------------------------------------------------------

void NurserySpace::minorGCRegion(OldGenSpace& oldgen, const StackMapRoots& stackmap_roots,
                                 MinorGCRecord* rec) {
#if !ENABLE_GC_PHASE_TIMERS
    (void)rec;
#endif
    RegionState& R = *rg_;
    minor_gc_running_ = true;
    oldgen.setInMinorGC(true);
    minor_color_ = !minor_color_;
    young_large_scan_.clear();
    R.in_minor = true;
#if ECO_HEAP_VALIDATE
    in_minor_gc_ = true;
    // Class 3 pre-walk of eden (region form of preEvacuationFromSpaceWalk).
    for (char* p = R.eden_base; p < bump_.ptr;) {
        const Header* h = getHeader(p);
        const size_t sz = getObjectSize(p);
        if (h->tag > Tag_Forward || sz == 0 || p + sz > bump_.ptr) {
            std::fprintf(stderr, "[heap-validate] eden pre-walk: bad object at %p (tag %u size %zu)\n",
                         (void*)p, (unsigned)h->tag, sz);
            std::fflush(stderr);
            std::abort();
        }
        p += sz;
    }
#endif
#if P1_CENSUS_COMPILED
    p1::onMinorStart(oldgen, ++census_minor_seq_);
#endif
#if ENABLE_GC_STATS
    const size_t from_space_used = objectBytesAllocated();
    auto gc_start = GC_STATS_TIMER_START();
#endif
#if ENABLE_GC_PHASE_TIMERS
    const bool T = rec != nullptr;
    uint64_t tp = T ? GCStats::nowSinceProcessStartNs() : 0;
    auto lap = [&]() -> uint64_t {
        const uint64_t now = GCStats::nowSinceProcessStartNs();
        const uint64_t d = now - tp;
        tp = now;
        return d;
    };
    const uint64_t surv0 = stats.objects_survived;
    uint64_t survb0 = 0;
    if (T) for (int i = 0; i < GCStats::NUM_ALLOC_TAGS; ++i) survb0 += stats.survived_bytes_by_tag[i];
#endif
    ++R.minor_seq;
    ++R.rs.minors;

    // ---- beginMinor (P§3.3) ----
    R.fill = R.hand = R.retire = R.prev = -1;
    unsigned nonfree = 0;
    for (unsigned u = 0; u < R.n_surv; ++u) {
        const int i = static_cast<int>(u);
        switch (R.x[u].state) {
            case region::XState::Young:
                if (R.x[u].age == R.tenure_age) R.hand = i;   // G_{m-k}
                if (R.x[u].age == 1) R.prev = i;              // G_{m-1}: its builders
                ++nonfree;
                break;
            case region::XState::Tenuring: R.retire = i; ++nonfree; break;
            case region::XState::Free: if (R.fill < 0) R.fill = i; break;
        }
    }
    if (R.fill < 0 || nonfree > R.tenure_age + 1)
        regionFatal("TV10: no Free survivor extent at minor start", nullptr, nullptr, nonfree);
    if (R.retire >= 0 && R.job.state != region::TenureJob::State::Merged)
        regionFatal("TV1: the retiring extent's tenure job was not merged", nullptr, nullptr,
                    static_cast<uint64_t>(R.job.state));
    region::Extent& F = R.x[R.fill];
    F.clearContents();
    R.fill_base = F.base;
    R.fill_end = F.base + R.set.capacity;
    R.bld_bottom.store(R.fill_end, std::memory_order_relaxed);
    R.rebuildRoles(true);

    // ---- hand-over preparation (P§3.5 step 4, P§3.14) ----
    R.hand_ylos.clear();
    R.hand_ylos_reached.clear();
    if (R.hand >= 0) {
        region::Extent& Hx = R.x[R.hand];
        if (!test_no_body_remark_) {
            for (const HPointer& b : Hx.lb_bodies) oldgen.markLargeBodySeen(b, minor_color_);
        }
        for (void* y : Hx.ylos_gen) {
            OldGenSpace::LargeBodyMeta* m = oldgen.youngLargeMeta(y);
            if (m == nullptr) continue;   // retired by a major in between (dead)
            m->color = minor_color_;
            R.hand_ylos.push_back(tw::YlosEntry{static_cast<const char*>(y),
                                                static_cast<const char*>(y) + getObjectSize(y)});
        }
        std::sort(R.hand_ylos.begin(), R.hand_ylos.end(),
                  [](const tw::YlosEntry& a, const tw::YlosEntry& b) { return a.obj < b.obj; });
        R.hand_ylos_reached.assign(R.hand_ylos.size(), 0);
    }
    // threaded-gc-07b: the ageing generations keep their large bodies and YLOS
    // objects until their own hand-over (re-coloured every minor; the sweep
    // frees neither), and their YLOS members form this minor's age snapshot.
    R.age_ylos.clear();
    for (unsigned u = 0; u < R.n_surv; ++u) {
        const int i = static_cast<int>(u);
        region::Extent& Ax = R.x[u];
        if (Ax.state != region::XState::Young || i == R.hand) continue;
        if (!test_no_body_remark_) {
            for (const HPointer& b : Ax.lb_bodies) oldgen.markLargeBodySeen(b, minor_color_);
        }
        for (void* y : Ax.ylos_gen) {
            OldGenSpace::LargeBodyMeta* m = oldgen.youngLargeMeta(y);
            if (m == nullptr) continue;
            m->color = minor_color_;
            R.age_ylos.push_back(tw::YlosEntry{static_cast<const char*>(y),
                                               static_cast<const char*>(y) + getObjectSize(y)});
        }
    }
    std::sort(R.age_ylos.begin(), R.age_ylos.end(),
              [](const tw::YlosEntry& a, const tw::YlosEntry& b) { return a.obj < b.obj; });

    // ---- worker count (6-P§3.2's space test on eden + PrevBuilders bytes) ----
    const size_t eden_bytes = static_cast<size_t>(bump_.ptr - R.eden_base);
    const size_t hb_bytes = R.prev >= 0 ? R.x[R.prev].bld_bytes : 0;
    const size_t s_in = eden_bytes + hb_bytes;
    unsigned n = oldgen.minorThreads();
    if (n < 1) n = 1;
    if (n > 1 && s_in < config_->minor_parallel_min_bytes) n = 1;
    const size_t lab = config_->minor_lab_bytes;
    if (n > 1) {
        const size_t rmax = lab / 64;
        const size_t waste = (s_in / (lab - rmax) + n) * rmax + static_cast<size_t>(n) * lab;
        if (s_in + waste > R.set.capacity) n = 1;
    }
#if ENABLE_GC_STATS
    if (n == 1 && oldgen.minorThreads() > 1) stats.pmin.serial_small++;
#endif

    par_oldgen_ = &oldgen;
    par_n_ = n;
    prefetch_children_ = config_->minor_prefetch_children;
    for (unsigned i = 0; i < n; ++i) {
        if (!minor_workers_[i]) minor_workers_[i] = std::make_unique<MinorWorker>();
        minor_workers_[i]->resetRun();
        minor_workers_[i]->index = i;
        R.rw[i].reset();
    }

    // The pre-drain sweep slice (6-P§3.8.5): the same budget per promotion,
    // times the objects the job merged at this minor tenured (= legacy's
    // promotions at the previous minor).
    if (oldgen.gc_phase_ == GCPhase::Sweeping) {
        const size_t d = oldgen.config_->minor_sweep_divisor;
        const size_t per = (d == 0) ? 0 : oldgen.config_->sweep_work_budget / d;
        const size_t budget = per * last_minor_promoted_;
        if (budget > 0) oldgen.lazySweep(NUM_SIZE_CLASSES, budget);
    }

    // The fill: LABs at the base; with one worker a single LAB of the whole
    // extent and no direct claims (no fillers: exact).
    if (n == 1) {
        tospace_.reset(R.fill_base, R.fill_end, R.set.capacity);
        tospace_.direct_min = SIZE_MAX;
        tospace_.retire_max = 0;
    } else {
        tospace_.reset(R.fill_base, R.fill_end, lab);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->par_sweep_ns = lap();
#endif

    // ---- roots, serial on worker 0, in the legacy order ----
    MinorWorker& w0 = *minor_workers_[0];
    region::RegionWorker& rw0 = R.rw[0];
    for (HPointer* root : root_set.getRoots()) evacuateR(w0, rw0, *root, kColRoot);
    for (HPointer* root : stackmap_roots.get()) evacuateR(w0, rw0, *root, kColRoot);
    for (uint64_t* root : root_set.getJitRoots()) {
        const uint64_t raw = *root;
        if (isConstantBits(raw) || raw == 0) continue;
        char* p = reinterpret_cast<char*>(raw);
        if (p < heap_base_ || p >= heap_base_ + heap_reserved_) continue;
        HPointer hp = Allocator::toPointerRaw(p);
        evacuateR(w0, rw0, hp, kColRoot);   // a Hand target stays (S holds it)
        *root = reinterpret_cast<uint64_t>(Allocator::fromPointerRaw(hp));
    }
    for (const auto& range : root_set.getStackRootRanges()) {
        for (size_t i = 0; i < range.count; ++i)
            if (stackRangeSlotIsRoot(range.hpointer_mask, i)) evacuateR(w0, rw0, range.base[i], kColRoot);
    }
    for (HPointer* slot : root_set.getSingleRoots()) evacuateR(w0, rw0, *slot, kColRoot);
    {
        const auto& scanners = root_set.getExternalRootScanners();
        for (size_t i = 0; i < scanners.size(); ++i) {
            scanners[i]([&](uint64_t& ref) {
                HPointer& hp = reinterpret_cast<HPointer&>(ref);
                if (hp.ptr_ind != 0) return;
                evacuateR(w0, rw0, hp, kColRoot);
            });
        }
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) {
        rec->par_roots_ns = lap();
        rec->roots_longlived_jit_ns = rec->par_roots_ns;
    }
#endif

    // ---- distribute + drain ----
    {
        std::vector<uint64_t> greys;
        greys.swap(w0.stack);
        const size_t h0 = w0.head;
        w0.head = 0;
        w0.priv.store(0, std::memory_order_relaxed);
        for (size_t i = h0; i < greys.size(); ++i) minor_workers_[(i - h0) % n]->deque.push(greys[i]);
    }
    gc::GCMarkGang* gang = n > 1 ? &oldgen.ensureGang() : nullptr;
    const unsigned jitter = gang ? gang->jitterUs() : 0;
    mk::SliceControl ctl(mk::kDrainBudget, n, jitter, n);
    for (unsigned i = 0; i < n; ++i) minor_workers_[i]->ctr.resetRun(i);
#if ENABLE_GC_STATS
    const uint64_t cpu0 = gang ? gang->stats().member_cpu_ns.load(std::memory_order_relaxed) : 0;
#endif
    if (n == 1) {
        RegionEnv env{*this};
        mk::runMarkerLoop(env, 0, ctl);
    } else {
        RegionRunArgs args{this, &ctl};
        gang->run(&NurserySpace::regionWorkerEntry, &args, n);
    }
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->par_drain_ns = lap();
#endif
    for (unsigned i = 0; i < n; ++i) {
        MinorWorker& w = *minor_workers_[i];
        if (w.stack.size() != w.head || !w.deque.emptyApprox())
            regionFatal("work left in a region minor worker after termination", nullptr, nullptr, i);
        w.deque.reset();
    }

    // ---- close the LABs ----
    uint64_t filler = 0;
    {
        minorwork::Lab labs[OldGenSpace::kMaxMinorWorkers];
        for (unsigned i = 0; i < n; ++i) labs[i] = minor_workers_[i]->lab;
        filler = mw::closeLabs(tospace_, labs, n, [&](char* p, size_t bytes) { writeFiller(p, bytes); });
        for (unsigned i = 0; i < n; ++i) filler += minor_workers_[i]->lc.filler_bytes;
    }
    char* const top = tospace_.top.load(std::memory_order_relaxed);
    char* const bld_lo = R.bld_bottom.load(std::memory_order_relaxed);
    if (top > bld_lo) regionFatal("the fill overflowed: survivors collided with the builder area", top, bld_lo);
    copy_ptr_ = top;

    // ---- merge, in worker order (P§3.5 step 6) ----
    std::vector<void*> S_all;
    std::vector<uint64_t*> H_all;
    std::vector<void*> SA_all;
    uint64_t n_surv = 0, b_fill = 0, b_bld = 0, resolved = 0;
    for (unsigned i = 0; i < n; ++i) {
        MinorWorker& w = *minor_workers_[i];
        region::RegionWorker& rw = R.rw[i];
        S_all.insert(S_all.end(), rw.S.begin(), rw.S.end());
        H_all.insert(H_all.end(), rw.H.begin(), rw.H.end());
        SA_all.insert(SA_all.end(), rw.SA.begin(), rw.SA.end());
        for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) F.class_count[c] += rw.class_count[c];
        F.lb_bodies.insert(F.lb_bodies.end(), rw.lb_bodies.begin(), rw.lb_bodies.end());
        F.ylos_gen.insert(F.ylos_gen.end(), rw.ylos_gen.begin(), rw.ylos_gen.end());
        n_surv += w.n_surv;
        b_fill += rw.b_fill;
        b_bld += rw.b_bld;
        resolved += rw.resolved;
        R.rs.copies_under16 += rw.under16;
        young_large_scan_.insert(young_large_scan_.end(), w.ylos_young.begin(), w.ylos_young.end());
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
    for (unsigned i = 0; i < n; ++i)
        for (const HPointer& b : minor_workers_[i]->lb_seen) oldgen.markLargeBodySeen(b, minor_color_);
    F.surv_top = top;
    F.bld_lo = bld_lo;
    F.bld_hi = R.fill_end;
    F.obj_bytes = b_fill;
    F.bld_bytes = b_bld;
    F.gen_minor = R.minor_seq;
    if (static_cast<size_t>(top - F.base) > F.hw) F.hw = static_cast<size_t>(top - F.base);
    R.S_m = b_fill + b_bld;
    R.rs.starts += S_all.size();
    R.rs.heal_slots += H_all.size();
    R.rs.resolved += resolved;
    R.rs.age_starts += SA_all.size();
    R.pend_S.swap(S_all);
    R.pend_H.swap(H_all);
    R.pend_SA.swap(SA_all);
#if ENABLE_GC_STATS
    {
        ParMinorStats& p = stats.pmin;
        if (n > 1) {
            p.minors_parallel++;
            p.workers_sum += n;
        }
        p.filler_bytes_total += filler;
        if (filler > p.filler_bytes_max) p.filler_bytes_max = filler;
        if (gang) p.member_cpu_ns += gang->stats().member_cpu_ns.load(std::memory_order_relaxed) - cpu0;
    }
#endif
#if ECO_HEAP_VALIDATE
    // PM1/PM3 over the fill; the region rule table: no copy points into eden,
    // a builder area of the hand-over extent, the retiring extent or stale.
    {
        uint64_t objs = 0, fill_seen = 0;
        auto checkChildren = [&](char* p) {
            forEachChildSlot(p, [&](HPointer& hp) {
                if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                void* c = Allocator::fromPointerRaw(hp);
                const Role r = R.roleOf(c);
                if (r == Role::Eden || r == Role::PrevBuilders || r == Role::Retire || r == Role::Stale) {
                    std::fprintf(stderr, "[heap-validate] region PM2: fill copy %p (tag %u) points into "
                                 "%s (%p)\n", (void*)p, (unsigned)getHeader(p)->tag, region::roleName(r), c);
                    std::fflush(stderr);
                    std::abort();
                }
            });
        };
        for (char* p = F.base; p < top;) {
            const Header* h = getHeader(p);
            const size_t sz = getObjectSize(p);
            if (h->tag > Tag_Forward || sz == 0 || p + sz > top) regionFatal("PM3: the fill does not parse", p, top, h->tag, sz);
            if (h->tag == Tag_Free) { fill_seen += sz; p += sz; continue; }
            if (h->builder) regionFatal("a builder in the fill's survivor part (trap 13)", p);
            if (h->age != 1) regionFatal("a fill survivor with age != 1", p, nullptr, h->age);
            ++objs;
            checkChildren(p);
            p += sz;
        }
        for (char* p = bld_lo; p < R.fill_end;) {
            const size_t sz = getObjectSize(p);
            const Header* h = getHeader(p);
            if (!h->builder || h->age != 0) regionFatal("a non-builder in the builder area", p, nullptr, h->builder, h->age);
            ++objs;
            checkChildren(p);
            p += sz;
        }
        if (fill_seen != filler) regionFatal("PM3: filler bytes found != closed", F.base, top, fill_seen, filler);
        if (objs != n_surv) regionFatal("PM1: fill objects != copies counted", F.base, top, objs, n_surv);
    }
#endif
#if ENABLE_GC_PHASE_TIMERS
    auto t_loop_exit = GC_STATS_TIMER_START();
    if (T) {
        rec->workers = n;
        rec->filler_bytes = filler;
        rec->par_close_ns = lap();
        rec->rg_starts = R.pend_S.size();
        rec->rg_heal_recorded = R.pend_H.size();
        rec->rg_resolved = resolved;
        rec->rg_fill_obj_bytes = b_fill;
        rec->rg_bld_bytes = b_bld;
    }
#endif

    // ---- epilogue (P§3.5 step 7) ----
    checkAndGrow();   // -> regionCheckAndGrow (S_m / capacity)

    // Retire G_{m-2}: nothing points into it (P§3.7). Resolve before
    // retiring (trap 10): this is the last reader of its shadow.
    if (R.retire >= 0) {
        region::Extent& Xr = R.x[R.retire];
#if ECO_HEAP_VALIDATE
        if (Xr.surv_top > Xr.base) std::memset(Xr.base, 0xDD, static_cast<size_t>(Xr.surv_top - Xr.base));
        if (Xr.bld_hi > Xr.bld_lo) std::memset(Xr.bld_lo, 0xDD, static_cast<size_t>(Xr.bld_hi - Xr.bld_lo));
#endif
        Xr.clearContents();
        Xr.state = region::XState::Free;
    }

    // Eden: flip (quarantine for an epoch) or reuse in place (P§3.8).
    {
#if ENABLE_GC_STATS
        const uint64_t tz = GCStats::nowSinceProcessStartNs();
#endif
        static const bool bulk_clear = [] {
            const char* e = std::getenv("ECO_NURSERY_BULK_CLEAR");
            return e != nullptr && e[0] == '1';
        }();
#if ECO_HEAP_VALIDATE
        const bool poison = nursery_poison_enabled();
#else
        const bool poison = false;
#endif
        char* old_eden = R.eden_base;
        char* old_top = bump_.ptr;
        if (old_top > R.eden_dirty[R.eden_cur]) R.eden_dirty[R.eden_cur] = old_top;
        if (R.flip) {
#if ECO_HEAP_VALIDATE
            if (old_top > old_eden) std::memset(old_eden, 0xDD, static_cast<size_t>(old_top - old_eden));
#endif
            R.eden_cur ^= 1u;
            R.eden_base = R.set.extent(R.eden_k[R.eden_cur]);
        }
        char* ne = R.eden_base;
        if (poison) {
            std::memset(ne, 0xD8, R.set.capacity);
            R.eden_dirty[R.eden_cur] = ne;
        } else if (bulk_clear) {
            char* hw = R.eden_dirty[R.eden_cur];
            if (hw > ne) std::memset(ne, 0, static_cast<size_t>(hw - ne));
            R.eden_dirty[R.eden_cur] = ne;
        }
        (void)old_eden;
#if ENABLE_GC_STATS
        R.rs.eden_clear_ns += GCStats::nowSinceProcessStartNs() - tz;
#endif
    }

    // endMinor: Fill -> Young(1), Age: age + 1, Hand -> Tenuring, Retire -> Free.
    for (unsigned u = 0; u < R.n_surv; ++u) {
        const int i = static_cast<int>(u);
        region::Extent& X = R.x[u];
        if (i == R.fill || X.state != region::XState::Young) continue;
        if (i == R.hand) {
            X.state = region::XState::Tenuring;
            X.age = 0;
        } else {
            ++X.age;
        }
    }
    F.state = region::XState::Young;
    F.age = 1;
    R.fill = R.hand = R.retire = R.prev = -1;
    R.rebuildRoles(false);
    R.in_minor = false;
    {
        unsigned nf = 0;
        for (unsigned i = 0; i < R.n_surv; ++i) if (R.x[i].state != region::XState::Free) ++nf;
        if (nf > R.rs.max_nonfree) R.rs.max_nonfree = nf;
        if (nf > R.tenure_age + 1)
            regionFatal("TV10: more than k + 1 survivor extents in use between minors", nullptr, nullptr, nf);
    }
    refreshCapacityCaches();
    filler_bytes_ = filler_bytes_to_ = 0;
    bump_.ptr = R.eden_base;
    survivor_end_ = R.eden_base;
    bump_.end = computeAllocEnd();
#if ECO_HEAP_VALIDATE
    in_minor_gc_ = false;
    regionEndMinorValidate(oldgen);   // TV2 on the new Tenuring extent, old-gen walk
#endif
#if P1_CENSUS_COMPILED
    if (censusEnabled()) censusRecordRegion(oldgen);
#endif
#if ENABLE_GC_STATS
    {
        const size_t to_space_used = objectBytesAllocated();
        const size_t bytes_freed = from_space_used > to_space_used ? from_space_used - to_space_used : 0;
        const uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
#if ENABLE_GC_PHASE_TIMERS
        if (T) {
            rec->tail_ns = static_cast<uint64_t>(GC_STATS_TIMER_ELAPSED_NS(t_loop_exit));
            rec->nursery_pause_ns = elapsed_ns;
            rec->survived = stats.objects_survived - surv0;
            uint64_t survb1 = 0;
            for (int i = 0; i < GCStats::NUM_ALLOC_TAGS; ++i) survb1 += stats.survived_bytes_by_tag[i];
            rec->survived_bytes = survb1 - survb0;
        }
#endif
        GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
    }
#endif
#if ENABLE_GC_PHASE_TIMERS
    const uint64_t t_lb = T ? GCStats::nowSinceProcessStartNs() : 0;
#endif
    oldgen.sweepNurseryLargeBodies(minor_color_);
#if ECO_HEAP_VALIDATE
    validateYoungLarge(oldgen);
#endif
#if ENABLE_GC_PHASE_TIMERS
    if (T) rec->large_body_sweep_ns = GCStats::nowSinceProcessStartNs() - t_lb;
#endif
    par_oldgen_ = nullptr;
    minor_gc_running_ = false;
    oldgen.setInMinorGC(false);
#if ECO_HEAP_VALIDATE
    oldgen.validateEveryNthMinor();
#endif
    R.last_minor_end_ns = GCStats::nowSinceProcessStartNs();
    syncRegionStats();
}

#if ECO_HEAP_VALIDATE
// TV2: hand-over closure. Every child of every object in the new Tenuring
// extent's survivor part is in that part, old, permanent, a constant, or a
// young large object; never another nursery extent. And HEAP_005: no old
// object points into the region nursery.
void NurserySpace::regionEndMinorValidate(OldGenSpace& oldgen) {
    RegionState& R = *rg_;
    // TV2Y (threaded-gc-07b): every non-free object of a Young extent points,
    // inside the slot block, only into a Young or Tenuring survivor part or the
    // Fresh builder area: a dead ageing object is zapped at the merge after
    // the hand-over that found it dead, before it can hold a retired address.
    auto youngOk = [&](const char* c) {
        const int j = R.extentOf(c);
        if (j < 0) return false;
        const region::Extent& Y = R.x[j];
        if (Y.state == region::XState::Free) return false;
        if (c >= Y.base && c < Y.surv_top) return true;
        return Y.state == region::XState::Young && Y.age == 1 && c >= Y.bld_lo && c < Y.bld_hi;
    };
    for (unsigned i = 0; i < R.n_surv; ++i) {
        region::Extent& X = R.x[i];
        if (X.state != region::XState::Young) continue;
        auto check = [&](char* lo, char* hi) {
            for (char* p = lo; p < hi;) {
                const size_t sz = getObjectSize(p);
                if (getHeader(p)->tag != Tag_Free) {
                    forEachChildSlot(p, [&](HPointer& hp) {
                        if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                        char* c = static_cast<char*>(Allocator::fromPointerRaw(hp));
                        if (!R.contains(c) || youngOk(c)) return;
                        std::fprintf(stderr, "[heap-validate] TV2Y: young object %p (tag %u, extent age %u) "
                                     "has a child %p in %s\n", (void*)p, (unsigned)getHeader(p)->tag, X.age,
                                     (void*)c, region::roleName(R.roleOf(c)));
                        std::fflush(stderr);
                        std::abort();
                    });
                }
                p += sz;
            }
        };
        check(X.base, X.surv_top);
        if (X.age == 1) check(X.bld_lo, X.bld_hi);
    }
    for (unsigned i = 0; i < R.n_surv; ++i) {
        region::Extent& X = R.x[i];
        if (X.state != region::XState::Tenuring) continue;
        for (char* p = X.base; p < X.surv_top;) {
            const size_t sz = getObjectSize(p);
            if (getHeader(p)->tag != Tag_Free) {
                forEachChildSlot(p, [&](HPointer& hp) {
                    if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                    char* c = static_cast<char*>(Allocator::fromPointerRaw(hp));
                    if (!R.contains(c)) return;
                    if (c >= X.base && c < X.surv_top) return;
                    std::fprintf(stderr, "[heap-validate] TV2: tenuring object %p (tag %u) has a "
                                 "child %p in %s\n", (void*)p, (unsigned)getHeader(p)->tag, (void*)c,
                                 region::roleName(R.roleOf(c)));
                    std::fflush(stderr);
                    std::abort();
                });
            }
            p += sz;
        }
    }
    // HEAP_005 over the old gen (every 64th minor: the walk is O(old gen)).
    static uint64_t tick = 0;
    if ((++tick & 63) != 0) return;
    oldgen.syncCursorLiveBytes();
    for (size_t pos = 0; pos < oldgen.blocks_.size(); ++pos) {
        const BlockId id = oldgen.blocks_.idAt(pos);
        const BlockInfo& blk = oldgen.blocks_.info(id);
        if (blk.alloc_state == OldGenSpace::kAllocTenure) continue;   // a running job's copies
        const bool uniform = !blk.is_large && blk.size_class < oldgen.num_size_classes_;
        if (!uniform) continue;   // mixed blocks: header parse is unsafe mid-sweep
        const size_t cell = OldGenSpace::classToSize(blk.size_class);
        for (char* p = blk.start; p + cell <= blk.end_of_objects; p += cell) {
            if (!oldgen.isMarkedInBlockRelaxed(id, p)) continue;
            uint64_t raw;
            std::memcpy(&raw, p, sizeof(raw));
            if (raw == 0 || getHeader(p)->tag >= Tag_Forward) continue;
            if (oldgen.youngLargeMeta(p) != nullptr) continue;   // young (YLOS)
            forEachChildSlot(p, [&](HPointer& hp) {
                if (hp.ptr_ind != 0 || hp.ptr == 0) return;
                char* c = static_cast<char*>(Allocator::fromPointerRaw(hp));
                if (!R.contains(c)) return;
                std::fprintf(stderr, "[heap-validate] HEAP_005 (region): old object %p (tag %u) "
                             "points into the nursery %p (%s)\n", (void*)p, (unsigned)getHeader(p)->tag,
                             (void*)c, region::roleName(R.roleOf(c)));
                std::fflush(stderr);
                std::abort();
            });
        }
    }
}
#endif

}  // namespace Elm
