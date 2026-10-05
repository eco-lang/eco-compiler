#pragma once

// threaded-gc-06 test workload: a deterministic mutator that churns a rooted
// working set of mixed objects (Ints, tuples, records, customs, strings, long
// and shared lists, boxed arrays) so minor GCs copy, age and promote every
// shape the parallel copier handles. `checksum` re-reads the whole working set
// through the heap, so a lost or mis-forwarded object changes it (or crashes).

#include <cstdint>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "TestHelpers.hpp"

namespace Elm::minortest {

struct Workload {
    Allocator& a;
    std::vector<HPointer> slots;
    HPointer tmp = alloc::listNil();   // rooted: a list under construction
    std::mt19937_64 rng;

    Workload(Allocator& alloc, size_t n_slots, uint64_t seed)
        : a(alloc), slots(n_slots, alloc::listNil()), rng(seed) {
        for (auto& s : slots) a.getRootSet().addRoot(&s);
        a.getRootSet().addRoot(&tmp);
    }
    ~Workload() {
        for (auto& s : slots) a.getRootSet().removeRoot(&s);
        a.getRootSet().removeRoot(&tmp);
    }
    Workload(const Workload&) = delete;
    Workload& operator=(const Workload&) = delete;

    uint64_t rnd(uint64_t n) { return n ? rng() % n : 0; }
    HPointer pick() { return slots[rnd(slots.size())]; }

    // One mutator step: allocate one new value (possibly referencing old
    // ones) into a random slot.
    void step() {
        const size_t dst = rnd(slots.size());
        HPointer v;
        switch (rnd(12)) {
            case 0: v = alloc::allocInt(static_cast<i64>(rng() & 0xFFFFFF)); break;
            case 1: v = alloc::tuple2(alloc::boxed(pick()), alloc::boxed(pick()), 0); break;
            case 2: {
                std::vector<Unboxable> f;
                for (int i = 0; i < 5; ++i) f.push_back(alloc::boxed(pick()));
                v = alloc::custom(static_cast<u16>(rnd(7)), f, 0);
                break;
            }
            case 3: {
                std::vector<Unboxable> f;
                for (int i = 0; i < 3; ++i) f.push_back(alloc::boxed(pick()));
                v = alloc::record(f, 0);
                break;
            }
            case 4: {   // a short list of boxed values
                tmp = alloc::listNil();
                const size_t n = 1 + rnd(40);
                for (size_t i = 0; i < n; ++i) tmp = alloc::cons(alloc::boxed(pick()), tmp, true);
                v = tmp;
                break;
            }
            case 5: {   // a long list of fresh boxed Ints (spine runs)
                if (rnd(20) != 0) { v = alloc::allocInt(7); break; }
                tmp = alloc::listNil();
                const size_t n = 1000 + rnd(3000);
                for (size_t i = 0; i < n; ++i) {
                    const HPointer x = alloc::allocInt(static_cast<i64>(i));   // may GC: tmp is rooted
                    tmp = alloc::cons(alloc::boxed(x), tmp, true);
                }
                v = tmp;
                break;
            }
            case 6: {   // an unboxed Int list
                std::vector<i64> xs(1 + rnd(200));
                for (auto& x : xs) x = static_cast<i64>(rnd(1000));
                v = alloc::listFromInts(xs);
                break;
            }
            case 7: {   // a list sharing another slot's list as its tail
                tmp = pick();
                const size_t n = 1 + rnd(10);
                for (size_t i = 0; i < n; ++i) {
                    const HPointer x = alloc::allocInt(3);
                    tmp = alloc::cons(alloc::boxed(x), tmp, true);
                }
                v = tmp;
                break;
            }
            case 8: {
                const std::string s = "s" + std::to_string(rng() % 100000);
                v = alloc::allocStringFromUTF8(s);
                break;
            }
            case 9: {   // a boxed array (sometimes over a chunk)
                std::vector<HPointer> e(rnd(10) == 0 ? 1500 + rnd(1000) : rnd(50));
                for (auto& x : e) x = pick();
                v = alloc::arrayFromPointers(e);
                break;
            }
            case 10: v = alloc::just(alloc::boxed(pick()), true); break;
            default: v = alloc::allocFloat(static_cast<double>(rnd(1000)) / 7.0); break;
        }
        slots[dst] = v;
    }

    void run(size_t steps) {
        for (size_t i = 0; i < steps; ++i) step();
    }

    // Structural hash of everything reachable from the slots (bounded walk:
    // shared structure is hashed each time it is reached, depth-limited).
    uint64_t hashValue(HPointer hp, int depth) {
        uint64_t h = 1469598103934665603ull;
        auto mix = [&](uint64_t x) { h ^= x; h *= 1099511628211ull; };
        if (hp.ptr_ind != 0) { mix(0xC0 | hp.constant); mix(hp.null_cons_idx); return h; }
        if (hp.ptr == 0) return 17;
        void* obj = AllocatorTestAccess::fromPointer(hp);
        Header* hd = getHeader(obj);
        mix(hd->tag);
        if (depth > 6) return h;
        switch (hd->tag) {
            case Tag_Int: mix(static_cast<uint64_t>(static_cast<ElmInt*>(obj)->value)); break;
            case Tag_Float: {
                const double d = static_cast<ElmFloat*>(obj)->value;
                uint64_t b; std::memcpy(&b, &d, 8); mix(b); break;
            }
            case Tag_Tuple2: {
                Tuple2* t = static_cast<Tuple2*>(obj);
                mix(hashValue(t->a.p, depth + 1)); mix(hashValue(t->b.p, depth + 1)); break;
            }
            case Tag_Custom: {
                Custom* c = static_cast<Custom*>(obj);
                mix(c->ctor);
                for (u32 i = 0; i < hd->size; ++i)
                    if (Elm::customSlotKind(c, i) == 0) mix(hashValue(c->values[i].p, depth + 1));
                    else mix(c->values[i].i);
                break;
            }
            case Tag_Record: {
                Record* r = static_cast<Record*>(obj);
                for (u32 i = 0; i < hd->size; ++i)
                    if (Elm::recordSlotKind(r, i) == 0) mix(hashValue(r->values[i].p, depth + 1));
                    else mix(r->values[i].i);
                break;
            }
            case Tag_Cons: {
                size_t n = 0;
                HPointer cur = hp;
                while (cur.ptr_ind == 0 && cur.ptr != 0) {
                    void* o = AllocatorTestAccess::fromPointer(cur);
                    if (getHeader(o)->tag != Tag_Cons) { mix(hashValue(cur, depth + 1)); break; }
                    Cons* c = static_cast<Cons*>(o);
                    if (Elm::tupleFieldKind(getHeader(o)->unboxed, 0) == 0) {
                        if (n < 64) mix(hashValue(c->head.p, depth + 1));
                    } else {
                        mix(c->head.i);
                    }
                    cur = c->tail;
                    ++n;
                }
                mix(n);
                break;
            }
            case Tag_Array: {
                ElmArray* ar = static_cast<ElmArray*>(obj);
                mix(ar->length);
                for (u32 i = 0; i < ar->length; ++i)
                    if (i < 8 || i + 8 > ar->length) mix(hashValue(ar->elements[i].p, depth + 1));
                break;
            }
            default:
                mix(getObjectSize(obj));
                break;
        }
        return h;
    }

    uint64_t checksum() {
        uint64_t h = 0;
        for (size_t i = 0; i < slots.size(); ++i) h = h * 31 + hashValue(slots[i], 0);
        return h;
    }
};

}  // namespace Elm::minortest
