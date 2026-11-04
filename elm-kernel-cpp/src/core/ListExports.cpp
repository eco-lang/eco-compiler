// The `extern "C"` exports of elm/core's `List` kernel, declared in `KernelExports.h`, and the helpers
// they share.
//
// Most of the file serves one concern: calling an Elm closure on list elements without breaking either
// the GC or the elements' representation. A list element is stored boxed, as an HPointer, or unboxed, as
// a raw Int, Float or Char, and the slot kind (0 boxed, 1 Int, 2 Float, 3 Char) recorded in its spine node
// says which. A spine node is a cons cell or a chunk view, as `alloc::ListCursor` in
// `allocator/HeapHelpers.hpp` describes; such a mixed spine is called hybrid here. Three facts follow.
//
// - Every closure call and every boxing allocation is a GC point that may move any heap object. So the
//   walks here copy what they need out of the spine with no allocation first, and keep every HPointer
//   they hold across a GC point in a stack root range, re-pushed whenever the vector holding them may
//   have reallocated.
// - A closure may expect an argument boxed or unboxed, and publishes which, with its result's kind, in
//   its header. `kernelListMapN` boxes an unboxed element only when the closure expects that argument
//   boxed, and keeps each result in the kind the closure returns, so `List.map2` to `map5` box no
//   element or result that the closure takes or returns unboxed. The kind an element is passed in is
//   its delivery kind.
// - Sorting only permutes, so a sorted list keeps its input's slot kinds. `sortBy` and `sortWith` take a
//   kinded snapshot of the input: the boxed form of each element, for the closure, and its kind and
//   original bits, from which `listFromPermutation` rebuilds the result.
//
// `List.fromArray` and `List.toArray` return a list they are given unchanged, so a list that Elm code
// wraps in either conversion passes through.

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "List.hpp"
#include "Utils.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/ListOps.hpp"
#include "allocator/RuntimeExports.h"
#include <vector>
#include <algorithm>
#include <numeric>
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

//===----------------------------------------------------------------------===//
// Closure-calling helpers.
//
// A closure given to a kernel may take its arguments in one stage or be curried over several, and the
// kernel cannot tell which. `eco_apply_closure` reads the closure's header and applies the arguments
// across as many stages as it has, so these helpers call through it rather than an entry that requires
// the arguments to fill the closure exactly.
//===----------------------------------------------------------------------===//

/// Returns `closure_hptr` applied to the encoded boxed value `arg`, as an encoded boxed result. A GC point.
inline uint64_t callUnaryClosure(HPtr closure_hptr, uint64_t arg) {
    uint64_t args[1] = { arg };
    return eco_apply_closure(closure_hptr, args, 1).toBits();
}

/// Returns `closure_hptr` applied to the encoded boxed values `arg1` and `arg2`, as an encoded boxed
/// result. A GC point.
inline uint64_t callBinaryClosure(HPtr closure_hptr, uint64_t arg1, uint64_t arg2) {
    uint64_t args[2] = { arg1, arg2 };
    return eco_apply_closure(closure_hptr, args, 2).toBits();
}

//===----------------------------------------------------------------------===//
// List conversion helpers
//===----------------------------------------------------------------------===//

/// Returns the elements of `list`, first to last, each as an encoded boxed value: a boxed element as it
/// is, an unboxed one boxed at its slot kind. A GC point.
///
/// The returned values are not rooted and are stale after the next allocation unless the caller roots
/// them first.
std::vector<uint64_t> listToVectorU64(HPointer list) {
    Allocator& allocator = Allocator::instance();

    // The spine walk allocates nothing, so the cursor stays valid; boxing starts only afterwards.
    struct Entry { Unboxable head; uint8_t kind; };
    std::vector<Entry> entries;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        entries.push_back(Entry{c.current(), c.currentKind()});
    }

    // Each boxing may move the boxed heads and the values boxed before it, so the whole buffer is one root
    // range. Slots for unboxed elements hold a null HPointer until they are boxed.
    std::vector<HPointer> hps(entries.size(), HPointer{});
    for (size_t i = 0; i < entries.size(); ++i) {
        if (entries[i].kind == 0) hps[i] = entries[i].head.p;
    }
    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRangePoint();
    if (!hps.empty()) {
        rs.pushStackRootRange(hps.data(), hps.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }
    for (size_t i = 0; i < entries.size(); ++i) {
        if (entries[i].kind != 0) {
            hps[i] = alloc::boxElement(entries[i].head, entries[i].kind);
        }
    }
    rs.restoreStackRangePoint(saved);

    std::vector<uint64_t> result;
    result.reserve(hps.size());
    for (HPointer hp : hps) result.push_back(Export::encode(hp));
    return result;
}

/// Returns each element of `list`'s 64 bits as a pointer, without boxing or resolving anything. Has no
/// callers; an unboxed element's bits are not an address.
std::vector<void*> listToVector(HPointer list) {
    std::vector<void*> result;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        result.push_back(reinterpret_cast<void*>(c.current().i));
    }
    return result;
}


/// Returns the head of the cons cell `cons`, whose header is `hdr`, as an encoded boxed value, boxing an
/// unboxed head at its slot kind, which makes it a GC point. Has no callers.
inline uint64_t getConsHead(Cons* cons, Header* hdr) {
    uint32_t kind = Elm::tupleFieldKind(hdr->unboxed, 0);
    if (kind != 0) {
        return Export::encode(alloc::boxElement(cons->head, kind));
    } else {
        return Export::encode(cons->head.p);
    }
}

/// A copy of one list element, taken from its spine node.
///
/// An unboxed `head` stays correct after a GC; a boxed one is an unrooted HPointer and may be stale after
/// the next allocation. `tail` is meaningful only when the element came from a cons cell.
struct ConsBits {
    Unboxable head;
    HPointer  tail;
    uint8_t   kind;  ///< The element's slot kind: 0 boxed, 1 Int, 2 Float, 3 Char.
};

// A position in a hybrid spine for `kernelListMapN`, kept as a spine-node HPointer and an index into that
// node's run (always 0 for a cons cell). The two functions below allocate nothing and resolve the node
// afresh on each call, so a position whose node HPointer is rooted stays valid across a GC.

/// Copies the element at the position (`node`, `idx`) into `out`, and returns whether there is one.
///
/// A position past the end of a chunk view's run is first moved to the start of the next node, so `node`
/// and `idx` may change. Returns false, leaving `out` unchanged, at Nil, at any other constant, and at a
/// node that is neither a cons cell nor a chunk view. For a chunk view `out.tail` is set to Nil. Does not
/// allocate.
inline bool listCurrentAt(HPointer& node, uint32_t& idx, ConsBits& out) {
    auto& allocator = Elm::Allocator::instance();
    while (true) {
        if (alloc::isNil(node) || node.ptr_ind != 0) return false;
        void* obj = allocator.resolve(node);
        if (!obj) return false;
        Header* hdr = static_cast<Header*>(obj);
        if (hdr->tag == Tag_Cons) {
            Cons* c = static_cast<Cons*>(obj);
            out.head = c->head;
            out.tail = c->tail;
            out.kind = static_cast<uint8_t>(
                Elm::tupleFieldKind(hdr->unboxed, 0));
            return true;
        }
        if (hdr->tag == Tag_ConsChunk) {
            ConsChunk* cv = static_cast<ConsChunk*>(obj);
            ListBacking* lb = static_cast<ListBacking*>(
                allocator.resolve(cv->backing));
            uint32_t run = lb->header.size - cv->offset;
            if (cv->len < run) run = cv->len;
            if (idx >= run) {
                node = cv->next;
                idx = 0;
                continue;
            }
            out.head = lb->elems[cv->offset + idx];
            out.tail = alloc::listNil();  // unused by the driver
            out.kind = static_cast<uint8_t>(hdr->unboxed & 0x3);
            return true;
        }
        return false;
    }
}

/// Moves the position (`node`, `idx`) past its element: for a cons cell to its tail, for a chunk view to
/// the next index, which `listCurrentAt` carries on into the next node when the run is exhausted. A node
/// that is neither ends the list by setting `node` to Nil. Does not allocate.
inline void listStepAt(HPointer& node, uint32_t& idx) {
    if (alloc::isNil(node) || node.ptr_ind != 0) return;
    void* obj = Elm::Allocator::instance().resolve(node);
    if (!obj) { node = alloc::listNil(); return; }
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_Cons) {
        node = static_cast<Cons*>(obj)->tail;
        idx = 0;
    } else if (hdr->tag == Tag_ConsChunk) {
        ++idx;
    } else {
        node = alloc::listNil();
    }
}

//===----------------------------------------------------------------------===//
// Calling a mapper closure with unboxed arguments.
//
// A closure's header records the kind of each argument it takes and of the result it returns. The
// helpers below let `kernelListMapN` describe the kinds it passes in an `EvalParamLayout` and call through
// `eco_apply_closure_eval`, which applies the arguments across a curried closure's stages and writes the
// result into a slot of the closure's result kind.
//===----------------------------------------------------------------------===//

/// A copy of the parts of a closure's header that describe how it is called.
///
/// A copy is used because the closure object may move at any GC point while these values stay the same.
struct ClosureMeta {
    Elm::ClosureKinds ks;  ///< The kind of every value slot, captured values first.
    uint8_t  result_kind;  ///< The kind the closure's evaluator returns its result in.
    uint32_t max_values;   ///< The stage arity: the arguments the evaluator takes, applied ones included.
    uint32_t n_values;     ///< The arguments already applied.
};

/// Returns the call metadata of the closure `closureHP` refers to, which must be a heap closure. Does not
/// allocate.
inline ClosureMeta readClosureMeta(HPointer closureHP) {
    auto* cl = static_cast<Closure*>(
        Elm::Allocator::instance().resolve(closureHP));
    ClosureMeta m;
    Elm::snapshotClosureKinds(cl, m.ks);
    m.result_kind = static_cast<uint8_t>(cl->result_kind);
    m.max_values  = static_cast<uint32_t>(cl->max_values);
    m.n_values    = static_cast<uint32_t>(cl->n_values);
    return m;
}

/// Returns the kind the closure described by `meta` expects for its `i`-th argument, counting from the
/// first one not yet captured.
inline uint8_t closureNewArgKind(const ClosureMeta& meta, uint32_t i) {
    return static_cast<uint8_t>(Elm::closureKindAt(meta.ks, meta.n_values + i));
}

/// Appends to `out` the closure result that `eco_apply_closure_eval` wrote to `result_storage` for
/// `result_kind`: an HPointer for 0, the raw Int, Float or Char for 1 to 3.
inline void appendClosureResult(std::vector<Unboxable>& out,
                                const void* result_storage,
                                uint8_t result_kind) {
    Unboxable v;
    switch (result_kind) {
        case 0: {
            HPtr hp;
            std::memcpy(&hp, result_storage, sizeof(HPtr));
            v.p = Elm::Kernel::Export::decode(hp.toBits());
            break;
        }
        case 1: std::memcpy(&v.i, result_storage, sizeof(int64_t)); break;
        case 2: std::memcpy(&v.f, result_storage, sizeof(double));  break;
        default: {
            // Char: the eval result slot holds a 32-bit code point.
            uint32_t c;
            std::memcpy(&c, result_storage, sizeof(uint32_t));
            v = alloc::unboxedChar(c);
            break;
        }
    }
    out.push_back(v);
}

/// Returns the list of the values in `vec`, first to last, as cons cells that all have slot kind
/// `result_kind` (low 2 bits). A GC point.
///
/// When `result_kind` is 0 the values are HPointers, and the caller must root `vec` across the call: each
/// cons may move them.
inline HPointer unboxableVectorToList(const std::vector<Unboxable>& vec,
                                       uint8_t result_kind) {
    HPointer result = alloc::listNil();
    for (auto it = vec.rbegin(); it != vec.rend(); ++it) {
        result = alloc::cons(*it, result, static_cast<u8>(result_kind & 0x3));
    }
    return result;
}

} // anonymous namespace

extern "C" {

// The head is stored boxed; the `_Int`, `_Float` and `_Char` variants below store theirs unboxed.
HPtr Elm_Kernel_List_cons(HPtr head, HPtr tail) {
    uint64_t head_bits = head.toBits();
    uint64_t tail_bits = tail.toBits();
    Unboxable headVal;
    headVal.p = Export::decode(head_bits);
    HPointer result = List::cons(headVal, Export::decode(tail_bits), true);
    return HPtr::fromBits(Export::encode(result));
}

// Each variant stores its head unboxed, with slot kind 1 (Int), 2 (Float) or 3 (Char) in the cell.
HPtr Elm_Kernel_List_cons_Int(int64_t head, HPtr tail) {
    HPointer result = alloc::cons(alloc::unboxedInt(head), Export::decode(tail.toBits()),
                                  /*head_kind=*/static_cast<uint8_t>(1));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_cons_Float(double head, HPtr tail) {
    HPointer result = alloc::cons(alloc::unboxedFloat(head), Export::decode(tail.toBits()),
                                  /*head_kind=*/static_cast<uint8_t>(2));
    return HPtr::fromBits(Export::encode(result));
}

// The code point is the low 32 bits of `head_raw`; the parameter is 64 bits wide and the upper bits are
// ignored.
HPtr Elm_Kernel_List_cons_Char(uint64_t head_raw, HPtr tail) {
    HPointer result = alloc::cons(alloc::unboxedChar(static_cast<u32>(head_raw & 0xFFFFFFFFu)), Export::decode(tail.toBits()),
                                  /*head_kind=*/static_cast<uint8_t>(3));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_fromArray(HPtr array) {
    uint64_t array_bits = array.toBits();
    HPointer hp = Export::decode(array_bits);
    if (hp.ptr_ind != 0) {
        return array;
    }

    void* arr_ptr = Export::toPtr(array_bits);
    if (!arr_ptr) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    Header* hdr = static_cast<Header*>(arr_ptr);

    // A list is returned as it is: kernels such as `String.split` already return lists here.
    if (hdr->tag == Tag_Cons || hdr->tag == Tag_ConsChunk) {
        return array;
    }

    if (hdr->tag != Tag_Array) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);
    u32 len = elmArr->length;
    bool isUnboxed = elmArr->header.unboxed != 0;

    // Each cons may move the array, so it is rooted and re-resolved after every cons; `alloc::cons` roots
    // its own head and tail. `List::cons` stores an unboxed element with slot kind Int, whatever the
    // array's element kind.
    HPointer arrHP = hp;
    Elm::StackRootGuard arrRoot(&arrHP);

    HPointer result = alloc::listNil();
    for (u32 i = len; i > 0; i--) {
        Unboxable head = elmArr->elements[i - 1];
        result = List::cons(head, result, !isUnboxed);
        elmArr = static_cast<ElmArray*>(Allocator::instance().resolve(arrHP));
    }

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_toArray(HPtr list) {
    uint64_t list_bits = list.toBits();
    // A list is returned as it is, for the same reason as in `List.fromArray`.
    HPointer hp = Export::decode(list_bits);
    if (hp.ptr_ind != 0) {
        return list;
    }
    void* ptr = Export::toPtr(list_bits);
    if (ptr) {
        Header* hdr = static_cast<Header*>(ptr);
        if (hdr->tag == Tag_Cons || hdr->tag == Tag_ConsChunk) {
            return list;
        }
    }

    // A heap object that is not a list node reaches here. `ListCursor` ends its walk at such a node,
    // so `vec` is empty and the result is an Array of length 0.
    std::vector<uint64_t> vec = listToVectorU64(Export::decode(list_bits));

    // The values are rooted across the array allocation as one range.
    std::vector<HPointer> rooted;
    rooted.reserve(vec.size());
    for (uint64_t e : vec) rooted.push_back(Export::decode(e));

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    if (!rooted.empty()) {
        rs.pushStackRootRange(rooted.data(), rooted.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }

    HPointer arr = alloc::allocArray(static_cast<u32>(rooted.size()));
    void* arr_ptr = Allocator::instance().resolve(arr);
    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);

    for (size_t i = 0; i < rooted.size(); i++) {
        elmArr->elements[i].p = rooted[i];
    }
    elmArr->length = static_cast<u32>(rooted.size());
    elmArr->header.unboxed = 0;  // Elements are boxed

#if ECO_HEAP_VALIDATE
    for (size_t i = 0; i < rooted.size(); i++)
        Elm::alloc::validateNurseryHPtr(elmArr->elements[i].p);
#endif

    rs.restoreStackRangePoint(saved);
    return HPtr::fromBits(Export::encode(arr));
}

//===----------------------------------------------------------------------===//
// Higher-order List functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

/// Returns the list of `closureHP` applied to the elements of the `n_args` lists in `lists` taken in step,
/// first to last, as long as the shortest of them. A GC point; the closure is called once per result, in
/// order.
///
/// `n_args` must be 2 to 5; nothing checks it. An unboxed element is boxed only when the closure expects
/// that argument boxed, and is otherwise passed in its own kind. The result's cells all have the slot kind
/// the closure returns, read once from its header.
///
/// `lists` and `closureHP` are rooted for the call and written to: each `lists[i]` is advanced along its
/// list, and both are updated by any GC.
HPointer kernelListMapN(int n_args, HPointer* lists, HPointer& closureHP) {
    static_assert(true, "n_args ∈ {2,3,4,5}");
    // The most input lists any `List.mapN` export passes.
    constexpr int kMaxArgs = 5;

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();

    // Read once: the closure may move at a GC point, but the kinds in its header do not change.
    ClosureMeta meta = readClosureMeta(closureHP);
    uint8_t closureSlotKinds[kMaxArgs] = {0};
    for (int i = 0; i < n_args; ++i) {
        closureSlotKinds[i] = closureNewArgKind(meta, static_cast<uint32_t>(i));
    }
    const uint8_t resultKind = meta.result_kind;

    std::vector<Unboxable> results;

    size_t outerSaved = rs.stackRangePoint();
    rs.pushStackRootRange(lists, n_args, /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    union ResultSlot {
        int64_t  i;
        double   f;
        uint32_t c;   // Char code point (32-bit eval result slot)
        HPtr     p;
        uint64_t bits;
    } resultSlot{};

    // The run index of each list's position; the node half is `lists[i]`, which is rooted.
    uint32_t idxs[kMaxArgs] = {0};
    ConsBits cb[kMaxArgs];

    auto readAll = [&]() -> bool {
        for (int i = 0; i < n_args; ++i) {
            if (!listCurrentAt(lists[i], idxs[i], cb[i])) return false;
        }
        return true;
    };

    while (readAll()) {

        // Box the unboxed elements the closure wants boxed. Before each boxing the root ranges are
        // pushed again so that they cover the elements boxed so far and, for a boxed result
        // kind, the results so far.
        //
        // Boxed elements are not taken from `cb` here: a boxing at a lower index could move a higher
        // index's element and leave its copy in `cb` stale, and rooting a stale value would corrupt the
        // root scan. Their `prebox` slots stay null until all the boxing is done.
        HPointer prebox[kMaxArgs] = {};
        uint8_t  deliveryKinds[kMaxArgs] = {0};
        for (int i = 0; i < n_args; ++i) {
            uint8_t closureKind = closureSlotKinds[i];
            if (cb[i].kind == closureKind && cb[i].kind != 0) {
                deliveryKinds[i] = cb[i].kind;
            } else if (cb[i].kind == 0) {
                deliveryKinds[i] = 0;
            } else if (closureKind == 0) {
                rs.restoreStackRangePoint(outerSaved);
                rs.pushStackRootRange(lists, n_args, /*hpointer_mask=*/~uint64_t(0));
                rs.pushStackRootRange(&closureHP, 1, 1);
                if (i > 0) {
                    rs.pushStackRootRange(prebox, i,
                                          /*hpointer_mask=*/~uint64_t(0));
                }
                if (resultKind == 0 && !results.empty()) {
                    rs.pushStackRootRange(
                        reinterpret_cast<HPointer*>(results.data()),
                        results.size(), /*hpointer_mask=*/~uint64_t(0));
                }
                prebox[i] = Elm::alloc::boxElement(cb[i].head, cb[i].kind);
                deliveryKinds[i] = 0;
            } else {
                deliveryKinds[i] = cb[i].kind;
            }
        }

        // `lists` is rooted and `listCurrentAt` does not allocate, so these elements are current, and
        // there is no GC point between here and the closure call.
        for (int i = 0; i < n_args; ++i) {
            if (deliveryKinds[i] == 0 && cb[i].kind == 0) {
                ConsBits fresh;
                listCurrentAt(lists[i], idxs[i], fresh);
                prebox[i] = fresh.head.p;
            }
        }

        // Each argument in its delivery kind: an encoded HPointer, or the raw Int, Float or Char bits.
        uint64_t typedArgs[kMaxArgs];
        for (int i = 0; i < n_args; ++i) {
            if (deliveryKinds[i] == 0) {
                typedArgs[i] = static_cast<uint64_t>(Export::encode(prebox[i]));
            } else if (deliveryKinds[i] == 1) {
                typedArgs[i] = static_cast<uint64_t>(cb[i].head.i);
            } else if (deliveryKinds[i] == 2) {
                double f = cb[i].head.f;
                std::memcpy(&typedArgs[i], &f, sizeof(uint64_t));
            } else {
                typedArgs[i] = static_cast<uint64_t>(cb[i].head.c);
            }
        }

        // Kinds past `n_args` are not read.
        Elm::EvalParamLayoutN<kMaxArgs> lb{};
        lb.num_params = static_cast<unsigned short>(n_args);
        lb.result_kind = resultKind;
        for (int i = 0; i < n_args; ++i) lb.kinds[i] = deliveryKinds[i];

        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, n_args, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        if (resultKind == 0 && !results.empty()) {
            rs.pushStackRootRange(reinterpret_cast<HPointer*>(results.data()),
                                  results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        const auto* layout = Elm::asLayout(&lb);
        // `eco_apply_closure_eval` applies the arguments across the closure's stages when it takes fewer
        // than `n_args` at this one; an entry requiring an exact fit would assert.
        eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(typedArgs),
                               static_cast<uint32_t>(n_args),
                               layout, &resultSlot, resultKind);
        appendClosureResult(results, &resultSlot, resultKind);

        // Step from the rooted positions, not from `cb[i].tail`, which the closure call may have left
        // stale.
        for (int i = 0; i < n_args; ++i) listStepAt(lists[i], idxs[i]);
    }

    rs.restoreStackRangePoint(outerSaved);
    if (resultKind == 0 && !results.empty()) {
        rs.pushStackRootRange(reinterpret_cast<HPointer*>(results.data()),
                              results.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }
    HPointer listResult = unboxableVectorToList(results, resultKind);
    rs.restoreStackRangePoint(outerSaved);
    return listResult;
}

HPtr Elm_Kernel_List_map2(HPtr closure, HPtr xs, HPtr ys) {
    HPointer lists[2] = {
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(2, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_map3(HPtr closure, HPtr xs, HPtr ys, HPtr zs) {
    HPointer lists[3] = {
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(3, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_map4(HPtr closure, HPtr ws, HPtr xs, HPtr ys, HPtr zs) {
    HPointer lists[4] = {
        Export::decode(ws.toBits()),
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(4, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_map5(HPtr closure, HPtr vs, HPtr ws,
                           HPtr xs, HPtr ys, HPtr zs) {
    HPointer lists[5] = {
        Export::decode(vs.toBits()),
        Export::decode(ws.toBits()),
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(5, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

// ============================================================================
// Closure-free combinators: `reverse`, `append`, `concat`, `take`, `drop`.
//
// Each forwards to the `ListOps` function of the same name, which gives its contract. The results keep
// their elements' slot kinds, and a list one of them builds may be chunk views when chunk production is
// enabled.
// ============================================================================

HPtr Elm_Kernel_List_reverse(HPtr list) {
    HPointer result = Elm::ListOps::reverse(Export::decode(list.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_append(HPtr a, HPtr b) {
    HPointer result = Elm::ListOps::append(Export::decode(a.toBits()),
                                           Export::decode(b.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_concat(HPtr listOfLists) {
    HPointer result = Elm::ListOps::concat(Export::decode(listOfLists.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_take(int64_t n, HPtr list) {
    HPointer result = Elm::ListOps::take(n, Export::decode(list.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_drop(int64_t n, HPtr list) {
    HPointer result = Elm::ListOps::drop(n, Export::decode(list.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

/// Fills `boxed`, `kinds` and `scalars` with the kinded snapshot of `list`, one entry per element, first
/// to last, replacing what they held. A GC point.
///
/// `boxed[i]` is element `i` as a boxed value, boxed at its slot kind if it is unboxed: what a closure is
/// given. `kinds[i]` is its slot kind and `scalars[i]` its original bits. A list whose cells were built
/// from `boxed` alone would have every element boxed, while code compiled for a `List Int` reads its
/// elements as Ints, so a sort rebuilds its result from `kinds` and `scalars`.
///
/// `scalars[i]` is meaningful only when `kinds[i]` is not 0: for a boxed element it is an unrooted copy
/// that may be stale after the next allocation, and `boxed[i]` is read instead. On return nothing is
/// rooted; the caller roots `boxed` across any later GC point, and needs root nothing else.
static void listToKindedVectors(HPointer list,
                                std::vector<HPointer>& boxed,
                                std::vector<uint8_t>& kinds,
                                std::vector<Unboxable>& scalars) {
    Allocator& allocator = Allocator::instance();

    // As in `listToVectorU64`, the walk finishes before anything is boxed.
    struct Entry { Unboxable head; uint8_t kind; };
    std::vector<Entry> entries;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        entries.push_back(Entry{c.current(), c.currentKind()});
    }

    boxed.assign(entries.size(), HPointer{});
    kinds.resize(entries.size());
    scalars.resize(entries.size());
    for (size_t i = 0; i < entries.size(); ++i) {
        kinds[i] = entries[i].kind;
        scalars[i] = entries[i].head;
        if (entries[i].kind == 0) boxed[i] = entries[i].head.p;
    }

    // Each boxing may move the values in `boxed`, so the whole buffer is one root range.
    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRangePoint();
    if (!boxed.empty()) {
        rs.pushStackRootRange(boxed.data(), boxed.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }
    for (size_t i = 0; i < entries.size(); ++i) {
        if (kinds[i] != 0) {
            boxed[i] = alloc::boxElement(scalars[i], kinds[i]);
        }
    }
    rs.restoreStackRangePoint(saved);
}

/// Returns the list of the elements of a kinded snapshot (`boxed`, `kinds`, `scalars`) in the order
/// `indices` gives, each with its original slot kind: element `indices[0]` first. A GC point.
///
/// The values in `boxed` must be current on entry, but need not be rooted: they are copied into a buffer
/// that `alloc::listFromUnboxables` roots, before anything allocates.
static HPointer listFromPermutation(const std::vector<size_t>& indices,
                                    const std::vector<HPointer>& boxed,
                                    const std::vector<uint8_t>& kinds,
                                    const std::vector<Unboxable>& scalars) {
    std::vector<std::pair<Unboxable, u8>> elems;
    elems.reserve(indices.size());
    for (size_t idx : indices) {
        if (kinds[idx] == 0) {
            Unboxable v;
            v.p = boxed[idx];
            elems.emplace_back(v, static_cast<u8>(0));
        } else {
            elems.emplace_back(scalars[idx], kinds[idx]);
        }
    }
    return alloc::listFromUnboxables(elems);
}

HPtr Elm_Kernel_List_sortBy(HPtr closure, HPtr list) {
    auto& allocator = Allocator::instance();

    // `elements` is the boxed view, rooted below across the key closure calls.
    std::vector<HPointer> elements;
    std::vector<uint8_t> kinds;
    std::vector<Unboxable> scalars;
    listToKindedVectors(Export::decode(list.toBits()), elements, kinds, scalars);
    if (elements.empty()) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    HPointer closureHP = Export::decode(closure.toBits());

    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(elements.data(), elements.size(),
                          /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    std::vector<HPointer> keys;
    keys.reserve(elements.size());
    for (size_t i = 0; i < elements.size(); ++i) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t k = callUnaryClosure(cl, Export::encode(elements[i]));
        keys.push_back(Export::decode(k));

        // Pushed again to cover the new key; `keys` may also have reallocated.
        rs.restoreStackRangePoint(saved);
        rs.pushStackRootRange(elements.data(), elements.size(),
                              /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        rs.pushStackRootRange(keys.data(), keys.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }

    // Indices are sorted rather than the elements, and stably, so elements with equal keys keep their
    // order. `Utils::compare` returns an embedded Order constant and does not allocate it.
    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::stable_sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
        // A key may be an embedded constant, such as the empty String or `[]`, which `Allocator::resolve`
        // must not be given, so a constant key is passed as null. `Utils::cmp3` orders a null below any
        // non-null value except a String of length 0, which it equals.
        void* keyA = alloc::isConstant(keys[a]) ? nullptr
                                                : allocator.resolve(keys[a]);
        void* keyB = alloc::isConstant(keys[b]) ? nullptr
                                                : allocator.resolve(keys[b]);
        HPointer orderHP = Utils::compare(keyA, keyB);
        // The Order is an embedded constant; its constructor is read from the word, not resolved.
        return eco_get_tag(HPtr::fromHPointer(orderHP)) == 0;  // LT
    });

    // Nothing allocates between here and `listFromPermutation` copying `elements` into a rooted buffer.
    rs.restoreStackRangePoint(saved);

    HPointer result = listFromPermutation(indices, elements, kinds, scalars);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_sortWith(HPtr closure, HPtr list) {
    auto& allocator = Allocator::instance();

    // `elements` is the boxed view the comparator is called with.
    std::vector<HPointer> elements;
    std::vector<uint8_t> kinds;
    std::vector<Unboxable> scalars;
    listToKindedVectors(Export::decode(list.toBits()), elements, kinds, scalars);
    if (elements.empty()) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    HPointer closureHP = Export::decode(closure.toBits());

    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(elements.data(), elements.size(),
                          /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    // Indices are sorted rather than the HPointers: `std::stable_sort` moves what it sorts through a
    // temporary buffer the root set cannot see, which a GC inside the comparator would leave stale.
    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::stable_sort(indices.begin(), indices.end(),
                     [&](size_t ia, size_t ib) {
        // The copies passed to the closure are rooted too, since the call may move them.
        HPointer aRoot = elements[ia];
        HPointer bRoot = elements[ib];
        size_t innerSaved = rs.stackRangePoint();
        rs.pushStackRootRange(&aRoot, 1, 1);
        rs.pushStackRootRange(&bRoot, 1, 1);

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t order = callBinaryClosure(cl, Export::encode(aRoot), Export::encode(bRoot));
        // The Order is an embedded constant; its constructor is read from the word, not resolved.
        bool lt = eco_get_tag(HPtr::fromBits(order)) == 0;  // LT means a < b
        rs.restoreStackRangePoint(innerSaved);
        return lt;
    });

    // As in `List.sortBy`, nothing allocates before `listFromPermutation` roots its copy.
    rs.restoreStackRangePoint(saved);

    HPointer result = listFromPermutation(indices, elements, kinds, scalars);
    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
