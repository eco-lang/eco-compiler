/* PermanentSpace + eco_caf_promote — see PermanentSpace.hpp and
 * plans/caf-permanent-space.md.
 *
 * The deep copier mirrors OldGenSpace::markChildren's per-tag child
 * enumeration exactly (same masks, same caps, same decode via
 * fromPointerRaw). Two-phase for abort-safety:
 *
 *   phase 1  traverse + screen — ANY unsupported tag declines the whole
 *            promotion BEFORE anything is allocated (slot stays rooted,
 *            value stays heap-resident; soundness never depends on copier
 *            completeness).
 *   phase 2a allocate + memcpy every object, build the old→new map.
 *   phase 2b rewrite pointer fields in the copies through the map. The
 *            rewrite gate is identical to the traversal gate, so every
 *            lookup must hit; a miss (bug) or phase-2a OOM abandons the
 *            copied bytes (unreachable, counted) and returns the original.
 *
 * No managed-heap allocation, no Elm callbacks, no GC triggers anywhere in
 * promote — it runs between two straight-line points of the memo guard
 * with no safepoint, so raw traversal of the (rooted, completed, immutable)
 * result graph is safe.
 */

#include "PermanentSpace.hpp"
#include "HeapChildWalk.hpp"

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "Heap.hpp"
#include "PlatformVirtualMemory.hpp"
#include "RootSet.hpp"

#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace Elm {

static constexpr std::size_t kPermanentReserve = 8ull << 30;   // 8 GiB VA
static constexpr std::size_t kPermanentCommitStep = 16ull << 20; // 16 MiB

PermanentSpace &PermanentSpace::instance() {
    static PermanentSpace s;
    return s;
}

bool PermanentSpace::ensureReservedLocked() {
    if (base_.load(std::memory_order_relaxed) != nullptr)
        return true;
    // Below the HPointer address limit, like the heap itself (raw-address
    // HPointer words, bits [3,43)). A non-FIXED reservation cannot overlap
    // the existing heap mapping, so isInHeap stays false for every
    // permanent address by construction.
    void *p = Elm::platform::reserveAddressSpaceBelow(kPermanentReserve,
                                                      HPOINTER_ADDRESS_LIMIT);
    if (p == nullptr)
        return false;
    reserved_ = kPermanentReserve;
    base_.store(static_cast<char *>(p), std::memory_order_release);
    return true;
}

void *PermanentSpace::allocate(std::size_t bytes) {
    bytes = (bytes + 7) & ~static_cast<std::size_t>(7);
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ensureReservedLocked())
        return nullptr;
    std::size_t used = used_.load(std::memory_order_relaxed);
    if (used + bytes > reserved_)
        return nullptr;
    while (used + bytes > committed_) {
        std::size_t step = kPermanentCommitStep;
        if (committed_ + step > reserved_)
            step = reserved_ - committed_;
        if (step == 0 ||
            Elm::platform::commitAt(base_.load(std::memory_order_relaxed) +
                                        committed_,
                                    step) == nullptr)
            return nullptr;
        committed_ += step;
    }
    void *r = base_.load(std::memory_order_relaxed) + used;
    used_.store(used + bytes, std::memory_order_release);
    return r;
}

} // namespace Elm

extern "C" std::uint64_t eco_caf_promote(std::uint64_t bits,
                                         std::uint64_t *slot) {
    using namespace Elm;

    // DEFAULT-ON (Run Z: −5.0 % wall, majors 9→8); ECO_CAF_PERMANENT=0 is
    // the escape hatch, mirroring ECO_CAF_MEMO.
    static const bool enabled = [] {
        const char *e = std::getenv("ECO_CAF_PERMANENT");
        return e == nullptr || e[0] != '0';
    }();

    Allocator &alloc = Allocator::instance();
    PermanentSpace &perm = PermanentSpace::instance();

    // Slots are NOT pre-registered as GC roots (createGlobalRootInitFunction
    // skips __eco_caf$ globals). This hook is the sole registration point:
    // root exactly when the stored value stays heap-resident. The slot still
    // holds 0 at registration time — a registered-but-zero slot is scan-inert,
    // and the caller's store lands before any subsequent safepoint.
    const auto rootSlot = [&] {
        alloc.getRootSet().addJitRoot(slot);
        perm.stats.slots_rooted++;
    };

    // Constants and non-heap addresses (statics, already-permanent) are
    // GC-inert forever: no copy, no root, in EITHER mode.
    if (isConstantBits(bits)) {
        perm.stats.values_constant++;
        return bits;
    }

    if (!enabled) {
        rootSlot();
        return bits;
    }

    void *root = alloc.resolve(hpFromBits(bits));
    if (root == nullptr || !alloc.isInHeap(root)) {
        perm.stats.values_constant++;
        return bits;
    }

    // ---- phase 1: traverse + screen (allocates nothing) ----
    std::vector<void *> order;
    std::unordered_set<void *> visited;
    std::vector<void *> work;
    work.push_back(root);
    visited.insert(root);
    bool supported = true;
    while (!work.empty() && supported) {
        void *o = work.back();
        work.pop_back();
        order.push_back(o);
        supported = visitHeapChildren(o, [&](HPointer &hp) {
            if (hp.ptr_ind != 0 || hp.ptr == 0)
                return; // constant or null (e.g. unfilled capture slot)
            void *c = alloc.resolve(hp);
            if (c == nullptr || !alloc.isInHeap(c))
                return;
            if (visited.insert(c).second)
                work.push_back(c);
        });
    }
    if (!supported) {
        perm.stats.values_declined++;
        rootSlot(); // value stays heap-resident
        return bits;
    }

    // ---- phase 2a: allocate + copy, build the forwarding map ----
    std::unordered_map<void *, void *> map;
    map.reserve(order.size() * 2);
    std::size_t total = 0;
    for (void *o : order) {
        std::size_t sz = getObjectSize(o);
        void *c = perm.allocate(sz);
        if (c == nullptr) {
            perm.stats.values_declined++;
            perm.stats.bytes_abandoned += total;
            rootSlot(); // value stays heap-resident
            return bits;
        }
        std::memcpy(c, o, sz);
        map.emplace(o, c);
        total += sz;
    }

    // ---- phase 2b: rewrite pointer fields in the copies ----
    bool fixed = true;
    for (void *o : order) {
        void *c = map[o];
        bool r = visitHeapChildren(c, [&](HPointer &hp) {
            if (!fixed || hp.ptr_ind != 0 || hp.ptr == 0)
                return; // constant or null — copied verbatim
            void *t = alloc.resolve(hp);
            if (t == nullptr || !alloc.isInHeap(t))
                return;
            auto it = map.find(t);
            if (it == map.end()) {
                fixed = false; // gate mismatch — must not happen
                return;
            }
            hp = hpFromBits(reinterpret_cast<std::uint64_t>(it->second));
        });
        if (!r || !fixed) {
            fixed = false;
            break;
        }
    }
    if (!fixed) {
        perm.stats.values_declined++;
        perm.stats.bytes_abandoned += total;
        rootSlot(); // value stays heap-resident
        return bits;
    }

    perm.stats.values_promoted++;
    perm.stats.objects_copied += order.size();
    perm.stats.bytes_copied += total;
    return reinterpret_cast<std::uint64_t>(map[root]);
}
