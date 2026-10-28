// Operations on Elm `List` values for runtime and kernel C++: building, reading, transforming,
// combining, folding and sorting lists on the garbage-collected heap.
//
// Two facts shape every function here.
//
// First, a list's spine is not a plain chain of cons cells. It may mix cons cells (`Tag_Cons`, one
// element each) with chunk views (`Tag_ConsChunk`, a run of elements stored in a backing array), and
// it ends at `[]`, the Empty constant. `alloc::ListCursor` and `alloc::RootedListCursor` walk both kinds
// of node, and the chunked layout and its rules are stated with those cursors and with
// `alloc::listChunkChain` in `HeapHelpers.hpp`. Each element carries a 2-bit slot kind: 0 boxed (an
// HPointer), 1 Int, 2 Float, 3 Char. Functions that copy elements keep each element's kind. A new value
// described only as boxed or not (`bool is_boxed`), such as a `map` callback's result or a `singleton`
// argument, gets the kind Int if unboxed, so those functions cannot produce a Float or Char element.
//
// Second, almost any allocation may run a collection that moves nursery objects, and a callback passed
// to a function here may allocate. The rules for holding values across that are owned by
// `HeapHelpers.hpp` (Patterns 1 to 3). Here they mean that a function taking a callback keeps every
// value it has collected so far rooted while the callback runs, so the callback may allocate. Collected
// values are held in an `alloc::RootedElems` until the result list is built with
// `alloc::listFromUnboxables`. The exception is a fold's accumulator, which is not rooted here. A
// callback receives its arguments by value; a boxed value it keeps across its own allocations is its own
// to root.
//
// Lists are immutable, so a result may share structure with an argument: `append` shares its second
// list, `drop` returns a suffix of its argument, and several functions return their argument itself in
// a trivial case, as each says. Every function uses the calling thread's heap.
//
// Several functions are narrower than the Elm function they are named after: `sum`, `product`,
// `maximum`, `minimum` and `sort` read element bits as an Int, and the sorts are not stable.

#ifndef ECO_LIST_OPS_H
#define ECO_LIST_OPS_H

#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include <vector>
#include <functional>

namespace Elm {
namespace ListOps {

// ============================================================================
// Construction
// ============================================================================

/// Returns the one-element list `[value]`, where `value` is boxed when `is_boxed` is true and an Int when
/// it is false. A GC point.
inline HPointer singleton(Unboxable value, bool is_boxed) {
    return alloc::cons(value, alloc::listNil(), is_boxed);
}

/// Returns the Ints from `low` to `high` inclusive, as cons cells, or `[]` when `low` is greater than
/// `high`. A GC point.
inline HPointer range(i64 low, i64 high) {
    if (low > high) return alloc::listNil();

    HPointer result = alloc::listNil();
    for (i64 i = high; i >= low; --i) {
        result = alloc::cons(alloc::unboxedInt(i), result, false);
    }
    return result;
}

/// Returns a list of `n` copies of `value`, as cons cells, or `[]` when `n` is not positive. `value` is
/// boxed when `is_boxed` is true and an Int when it is false; a boxed `value` must be current and is
/// rooted across the allocations. A GC point.
inline HPointer repeat(i64 n, Unboxable value, bool is_boxed) {
    if (n <= 0) return alloc::listNil();

    HPointer result = alloc::listNil();
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    if (is_boxed) rs.pushStackRootRange(&value.p, 1, 1);
    for (i64 i = 0; i < n; ++i) {
        result = alloc::cons(value, result, is_boxed);
    }
    rs.restoreStackRangePoint(saved);
    return result;
}

// ============================================================================
// Access
// ============================================================================

/// Returns whether `list` is `[]`.
inline bool isEmpty(HPointer list) {
    return alloc::isNil(list);
}

/// Returns the number of elements in `list`, counting up to the first node that is neither a cons cell
/// nor a chunk view. Walks cons cells one at a time and takes the rest from the first chunk view's
/// length. Does not allocate.
inline i64 length(HPointer list) {
    auto& allocator = Allocator::instance();
    i64 count = 0;
    HPointer current = list;

    while (!alloc::isNil(current) && current.ptr_ind == 0) {
        void* node = allocator.resolve(current);
        if (!node) break;
        Header* hdr = getHeader(node);
        if (hdr->tag == Tag_ConsChunk) {
            // A view's `len` counts every element from it to the end of the list, so the walk stops here.
            count += static_cast<ConsChunk*>(node)->len;
            break;
        }
        if (hdr->tag != Tag_Cons) break;
        ++count;
        current = static_cast<Cons*>(node)->tail;
    }

    return count;
}

/// Returns `Just` the first element of `list`, with its slot kind, or `Nothing` when `list` is empty. A GC
/// point.
HPointer head(HPointer list);

/// Returns `Just` the list after the first element of `list`, or `Nothing` when `list` is `[]`. Taking the
/// tail of a chunk view may allocate a new view. A GC point.
HPointer tail(HPointer list);

/// Returns `Just` the element at zero-based position `index` in `list`, with its slot kind, or `Nothing`
/// when `index` is negative or not less than the length. A GC point.
HPointer getAt(i64 index, HPointer list);

/// Returns `Just` the last element of `list`, with its slot kind, or `Nothing` when `list` is `[]`. A GC
/// point.
HPointer last(HPointer list);

// ============================================================================
// Transform
// ============================================================================

/// A function from one element, given with whether it is boxed, to a new element. Nothing in this
/// component takes one.
using Mapper = std::function<Unboxable(Unboxable, bool)>;
/// A function from one element, given with whether it is boxed, to a new element and whether that is
/// boxed. A result that is not boxed is stored as an Int.
using MapperWithBoxed = std::function<std::pair<Unboxable, bool>(Unboxable, bool)>;

/// Returns the list of `mapper`'s results for the elements of `list`, in order. Each result is boxed or an
/// Int, as `mapper` says; a Float or Char result is stored with kind Int. `mapper` is called once per
/// element, from first to last, and may allocate. Returns `[]` for `[]`. A GC point.
HPointer map(MapperWithBoxed mapper, HPointer list);

/// A function from an element's zero-based position, the element and whether it is boxed, to a new
/// element and whether that is boxed. A result that is not boxed is stored as an Int.
using IndexedMapper = std::function<std::pair<Unboxable, bool>(i64, Unboxable, bool)>;

/// Returns what `map` returns, with each element's zero-based position also passed to `mapper`. A GC
/// point.
HPointer indexedMap(IndexedMapper mapper, HPointer list);

/// A test of one element, given with whether it is boxed. It may allocate.
using Predicate = std::function<bool(Unboxable, bool)>;

/// Returns the elements of `list` for which `pred` returns true, in order and with their slot kinds.
/// `pred` is called once per element, from first to last. Returns `[]` for `[]`. A GC point.
HPointer filter(Predicate pred, HPointer list);

/// A function from one element, given with whether it is boxed, to a `Maybe`: `Nothing`, or a `Just`
/// holding the value to keep. It may allocate.
using FilterMapper = std::function<HPointer(Unboxable, bool)>;

/// Returns the values inside the `Just` results of `mapper` over `list`, in order, each with the slot kind
/// its `Just` holds it with. A result that is a constant, such as `Nothing`, is dropped, and so is any
/// heap result that is not a Custom with constructor 0. `mapper` is called once per element, from first
/// to last. Returns `[]` for `[]`. A GC point.
HPointer filterMap(FilterMapper mapper, HPointer list);

// ============================================================================
// Combine
// ============================================================================

/// Returns `a ++ b`. The elements of `a` are copied with their slot kinds and `b` is shared, not copied.
/// Returns `b` itself when `a` is `[]`, and `a` itself when `b` is `[]`. A GC point.
HPointer append(HPointer a, HPointer b);

/// Returns the elements of every list in `listOfLists`, in order, as one new list. Every element of
/// `listOfLists` must be a list. A GC point.
HPointer concat(HPointer listOfLists);

/// Returns `list` with `sep` between each pair of adjacent elements, or `list` itself when it has fewer
/// than two elements. `sep` is boxed when `sep_is_boxed` is true and an Int when it is false, and must be
/// current when boxed. A GC point.
HPointer intersperse(Unboxable sep, bool sep_is_boxed, HPointer list);

/// Returns the list of pairs `(a, b)` taking one element from each of `listA` and `listB` in step, as long
/// as the shorter list. Each pair keeps its elements' slot kinds, and the list is cons cells. Despite the
/// name, no function is applied. A GC point.
HPointer map2(HPointer listA, HPointer listB);

/// Returns the list of triples `(a, b, c)` taking one element from each of `listA`, `listB` and `listC` in
/// step, as long as the shortest. As with `map2`, the slot kinds are kept, the list is cons cells, and no
/// function is applied. A GC point.
HPointer map3(HPointer listA, HPointer listB, HPointer listC);

// ============================================================================
// Sub-lists
// ============================================================================

/// Returns a new list of the first `n` elements of `list`, or all of them when it has fewer, with their
/// slot kinds. Returns `[]` when `n` is not positive. A GC point.
HPointer take(i64 n, HPointer list);

/// Returns `list` without its first `n` elements, or `[]` when it has no more than `n`. The result is
/// `list` itself when `n` is not positive, and otherwise a suffix of it, shared, except when `n` ends
/// inside a chunk view's run: then one new view is allocated for the rest of that run. Returns `[]` on
/// reaching a node that is neither a cons cell nor a chunk view. Visits each spine node once rather than
/// each element. A GC point.
HPointer drop(i64 n, HPointer list);

/// Returns the pair `(passing, failing)` of the elements of `list` for which `pred` returns true and
/// false, each in order and with their slot kinds. `pred` is called once per element, from first to last.
/// A GC point.
HPointer partition(Predicate pred, HPointer list);

/// Returns the pair `(firsts, seconds)` of the first and second fields of the pairs in `listOfPairs`, in
/// order and with the slot kinds the pairs hold them with. Every element must be a boxed `Tuple2`; its tag
/// is not checked. A GC point.
HPointer unzip(HPointer listOfPairs);

// ============================================================================
// Fold
// ============================================================================

/// A step of a fold: from one element, whether it is boxed, and the accumulator, to the next accumulator.
/// It may allocate.
using Folder = std::function<Unboxable(Unboxable, bool, Unboxable)>;

/// Returns the result of applying `fold` to each element of `list` from first to last, starting from
/// `acc`. The accumulator is not rooted here; a caller whose accumulator is a heap pointer must keep it
/// valid across `fold`'s allocations itself. A GC point if `fold` allocates.
Unboxable foldl(Folder fold, Unboxable acc, HPointer list);

/// Returns the result of applying `fold` to each element of `list` from last to first, starting from
/// `acc`. As with `foldl`, the accumulator is not rooted here. A GC point if `fold` allocates.
Unboxable foldr(Folder fold, Unboxable acc, HPointer list);

/// Returns the sum of the unboxed elements of `list`, each read as an Int; boxed elements are skipped. A
/// Float or Char element's bits are added as if they were an Int. Does not allocate.
inline i64 sum(HPointer list) {
    i64 total = 0;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        if (c.currentKind() != 0) total += c.current().i;
    }
    return total;
}

/// Returns the product of the unboxed elements of `list`, each read as an Int, or 1 when there are none;
/// boxed elements are skipped. A Float or Char element's bits are multiplied as if they were an Int. Does
/// not allocate.
inline i64 product(HPointer list) {
    i64 total = 1;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        if (c.currentKind() != 0) total *= c.current().i;
    }
    return total;
}

/// Returns `Just` the element of `list` whose 64-bit slot, read as a signed Int, is largest, with its slot
/// kind, or `Nothing` when `list` is `[]`. The comparison is correct only for a list of Ints: boxed
/// elements are compared by their HPointer bits, and Floats by their bits. A GC point.
HPointer maximum(HPointer list);

/// Returns `Just` the element of `list` whose 64-bit slot, read as a signed Int, is smallest, as `maximum`
/// does for the largest, or `Nothing` when `list` is `[]`. A GC point.
HPointer minimum(HPointer list);

// ============================================================================
// Membership
// ============================================================================

/// Returns whether `pred` returns true for every element of `list`; true for `[]`. Stops at the first
/// element for which it returns false. `pred` may allocate.
inline bool all(Predicate pred, HPointer list) {
    // The cursor roots the spine; the guard roots a boxed element while `pred` runs.
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 kind;
    while (cursor.read(head, kind)) {
        bool ok;
        {
            HPointer* head_root = (kind == 0) ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            ok = pred(head, kind == 0);
        }
        if (!ok) return false;
        cursor.advance();
    }
    return true;
}

/// Returns whether `pred` returns true for some element of `list`; false for `[]`. Stops at the first
/// element for which it returns true. `pred` may allocate.
inline bool any(Predicate pred, HPointer list) {
    // Rooted as in `all`.
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 kind;
    while (cursor.read(head, kind)) {
        bool hit;
        {
            HPointer* head_root = (kind == 0) ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            hit = pred(head, kind == 0);
        }
        if (hit) return true;
        cursor.advance();
    }
    return false;
}



// ============================================================================
// Sorting
// ============================================================================

/// Returns the elements of `list` in reverse order, with their slot kinds, or `list` itself when it has
/// fewer than two elements. A GC point.
HPointer reverse(HPointer list);

/// Returns the elements of `list` sorted in ascending order of their 64-bit slots read as signed Ints, as
/// a list of Ints. The result is correct only for a list of Ints: every element, whatever its kind, is
/// read and stored back as an Int. A GC point.
HPointer sort(HPointer list);

/// A function from one element, given with whether it is boxed, to the Int key it is sorted by. It may
/// allocate.
using KeyExtractor = std::function<i64(Unboxable, bool)>;

/// Returns the elements of `list`, with their slot kinds, sorted in ascending order of `keyFn`'s key. The
/// sort is not stable: elements with equal keys may change order. `keyFn` is called twice per comparison,
/// not once per element. A GC point.
HPointer sortBy(KeyExtractor keyFn, HPointer list);

/// A comparison of two elements, each given with whether it is boxed, returning a negative number when the
/// first sorts before the second, zero when they are equal, and a positive number otherwise. It may
/// allocate.
using Comparator = std::function<int(Unboxable, bool, Unboxable, bool)>;

/// Returns the elements of `list`, with their slot kinds, sorted in the order `cmp` defines, which must be
/// a strict weak ordering. The sort is not stable: elements `cmp` finds equal may change order. A GC
/// point.
HPointer sortWith(Comparator cmp, HPointer list);

// ============================================================================
// Utilities
// ============================================================================

/// Returns the elements of `list`, first to last, each paired with its 2-bit slot kind (0 boxed, not a
/// boolean), so that a list built from the vector can keep every element's kind.
///
/// Does not allocate on the heap. The boxed values are not rooted and are stale after the next GC point.
inline std::vector<std::pair<Unboxable, u8>> toVector(HPointer list) {
    std::vector<std::pair<Unboxable, u8>> result;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        result.emplace_back(c.current(), c.currentKind());
    }
    return result;
}

/// Returns every element of `list`, first to last, read as an Int whatever its slot kind. Meaningful only
/// for a list of Ints. Does not allocate on the heap.
inline std::vector<i64> toIntVector(HPointer list) {
    std::vector<i64> result;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        result.push_back(c.current().i);
    }
    return result;
}

// A list is built from a vector with alloc::listFromUnboxables, alloc::listFromPointers or
// alloc::listFromInts.

} // namespace ListOps
} // namespace Elm

#endif // ECO_LIST_OPS_H
