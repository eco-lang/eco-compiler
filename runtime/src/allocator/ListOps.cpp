#include "ListOps.hpp"
#include <algorithm>
#include <numeric>

namespace Elm {
namespace ListOps {

namespace {

// The element count of a list and whether every element has the same slot kind. `kind` is that kind,
// meaningful only when `uniform` is true and `n` is not 0.
struct SpineShape {
    u32 n = 0;
    bool uniform = true;
    u8 kind = 0;
};

// Returns the shape of `list`, in one walk that does not allocate.
SpineShape probeShape(HPointer list) {
    SpineShape s;
    bool first = true;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        u8 k = c.currentKind();
        if (first) {
            s.kind = k;
            first = false;
        } else if (k != s.kind) {
            s.uniform = false;
        }
        ++s.n;
    }
    return s;
}

// Returns whether a result of shape `s` is built as a chunk chain: chunked lists are enabled, the
// elements share one kind, there are at least 4 of them, and `alloc::chunkChainFits` allows. This is the
// rule `alloc::listFromUnboxables` applies.
bool chunkEligible(const SpineShape& s) {
    return eco_g_list_chunks && s.uniform && s.n >= 4 && alloc::chunkChainFits(s.n);
}

// Returns the backing of the chunk view `view`, resolved now. A raw backing pointer taken before the view
// was allocated may be stale. Nothing in this file calls it.
ListBacking* resolveViewBacking(HPointer view) {
    auto& allocator = Allocator::instance();
    return static_cast<ListBacking*>(allocator.resolve(
        static_cast<ConsChunk*>(allocator.resolve(view))->backing));
}

} // namespace

HPointer head(HPointer list) {
    alloc::ListCursor c(list);
    if (c.done()) {
        return alloc::nothing();
    }
    return alloc::justKind(c.current(), c.currentKind());
}

HPointer tail(HPointer list) {
    if (alloc::isNil(list)) {
        return alloc::nothing();
    }

    auto& allocator = Allocator::instance();
    void* cell = allocator.resolve(list);
    if (!cell) return alloc::nothing();

    return alloc::just(alloc::boxed(alloc::listTailOf(list)), true);
}

HPointer getAt(i64 index, HPointer list) {
    if (index < 0) return alloc::nothing();

    i64 i = 0;
    for (alloc::ListCursor c(list); !c.done(); c.next(), ++i) {
        if (i == index) {
            return alloc::justKind(c.current(), c.currentKind());
        }
    }
    return alloc::nothing();
}

HPointer last(HPointer list) {
    if (alloc::isNil(list)) {
        return alloc::nothing();
    }

    Unboxable lastVal;
    lastVal.i = 0;
    u8 lastKind = 0;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        lastVal = c.current();
        lastKind = c.currentKind();
    }
    return alloc::justKind(lastVal, lastKind);
}

HPointer map(MapperWithBoxed mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    // The spine, the current element and the results collected so far all cross later mapper calls, which
    // may collect. `mapped` roots its boxed results with one shadow-stack record however long the list.
    alloc::RootedElems mapped(static_cast<size_t>(length(list)));
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 head_kind;

    while (cursor.read(head, head_kind)) {
        bool is_boxed = (head_kind == 0);
        std::pair<Unboxable, bool> result;
        {
            HPointer* head_root = is_boxed ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            result = mapper(head, is_boxed);
        }
        mapped.push(result.first, alloc::kindFromBoxedFlag(result.second));
        cursor.advance();
    }

    return alloc::listFromUnboxables(mapped);
}

HPointer indexedMap(IndexedMapper mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    // Rooted as in `map`.
    alloc::RootedElems mapped(static_cast<size_t>(length(list)));
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 head_kind;
    i64 index = 0;

    while (cursor.read(head, head_kind)) {
        bool is_boxed = (head_kind == 0);
        std::pair<Unboxable, bool> result;
        {
            HPointer* head_root = is_boxed ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            result = mapper(index, head, is_boxed);
        }
        mapped.push(result.first, alloc::kindFromBoxedFlag(result.second));
        ++index;
        cursor.advance();
    }

    return alloc::listFromUnboxables(mapped);
}

HPointer filter(Predicate pred, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    // Rooted as in `map`.
    alloc::RootedElems passing(static_cast<size_t>(length(list)));
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 head_kind;

    while (cursor.read(head, head_kind)) {
        bool is_boxed = (head_kind == 0);
        bool keep;
        {
            HPointer* head_root = is_boxed ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            keep = pred(head, is_boxed);
        }
        if (keep) {
            passing.push(head, head_kind);
        }
        cursor.advance();
    }

    return alloc::listFromUnboxables(passing);
}

HPointer filterMap(FilterMapper mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Rooted as in `map`.
    alloc::RootedElems results(static_cast<size_t>(length(list)));
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 head_kind;

    while (cursor.read(head, head_kind)) {
        bool is_boxed = (head_kind == 0);
        HPointer maybeResult;
        {
            HPointer* head_root = is_boxed ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            maybeResult = mapper(head, is_boxed);
        }

        // `maybeResult` is fresh from `mapper`, and nothing below allocates before its value is copied out.
        if (!alloc::isConstant(maybeResult)) {
            void* justCell = allocator.resolve(maybeResult);
            if (justCell) {
                Custom* just = static_cast<Custom*>(justCell);
                if (just->header.tag == Tag_Custom && just->ctor == 0) {
                    u8 val_kind = static_cast<u8>(fieldKind(just->unboxed, 0));
                    results.push(just->values[0], val_kind);
                }
            }
        }

        cursor.advance();
    }

    return alloc::listFromUnboxables(results);
}

HPointer append(HPointer a, HPointer b) {
    if (alloc::isNil(a)) return b;
    if (alloc::isNil(b)) return a;

    // The shape probe is an extra walk of `a`, made only when chunked lists are enabled.
    if (eco_g_list_chunks) {
        SpineShape s = probeShape(a);
        if (chunkEligible(s)) {
            // Allocate the whole chain first, then fill it without allocating, as in `reverse`.
            // `listChunkChain` walks `b` to give each view its length to the end of the list.
            StackRootGuard guard(&a, &b);
            HPointer head = alloc::listChunkChain(s.n, s.kind, b);
            alloc::ListChainWriter w(head);
            for (alloc::ListCursor c(a); !c.done(); c.next()) {
                w.put(c.current());
            }
            alloc::finishChunkChain(head, s.n);
            return head;
        }
    }

    // Otherwise copy `a`'s elements out and build cons cells back to front onto `b`.
    std::vector<std::pair<Unboxable, u8>> elements;
    for (alloc::ListCursor c(a); !c.done(); c.next()) {
        elements.emplace_back(c.current(), c.currentKind());
    }

    return alloc::listFromUnboxables(elements, b);
}

HPointer concat(HPointer listOfLists) {
    if (alloc::isNil(listOfLists)) return alloc::listNil();

    // With chunked lists enabled, probe every inner list without allocating, then allocate the whole
    // chain and fill it straight from the inner lists.
    if (eco_g_list_chunks) {
        SpineShape s;
        bool first = true;
        for (alloc::ListCursor outer(listOfLists); !outer.done();
             outer.next()) {
            for (alloc::ListCursor inner(outer.current().p); !inner.done();
                 inner.next()) {
                u8 k = inner.currentKind();
                if (first) {
                    s.kind = k;
                    first = false;
                } else if (k != s.kind) {
                    s.uniform = false;
                }
                ++s.n;
            }
        }
        if (s.n == 0) return alloc::listNil();
        if (chunkEligible(s)) {
            StackRootGuard guard(&listOfLists);
            HPointer head =
                alloc::listChunkChain(s.n, s.kind, alloc::listNil());
            alloc::ListChainWriter w(head);
            for (alloc::ListCursor outer(listOfLists); !outer.done();
                 outer.next()) {
                for (alloc::ListCursor inner(outer.current().p);
                     !inner.done(); inner.next()) {
                    w.put(inner.current());
                }
            }
            alloc::finishChunkChain(head, s.n);
            return head;
        }
    }

    std::vector<std::pair<Unboxable, u8>> allElements;
    for (alloc::ListCursor outer(listOfLists); !outer.done(); outer.next()) {
        for (alloc::ListCursor inner(outer.current().p); !inner.done();
             inner.next()) {
            allElements.emplace_back(inner.current(), inner.currentKind());
        }
    }

    return alloc::listFromUnboxables(allElements);
}

HPointer intersperse(Unboxable sep, bool sep_is_boxed, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    std::vector<std::pair<Unboxable, u8>> elements;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        elements.emplace_back(c.current(), c.currentKind());
    }

    if (elements.size() <= 1) {
        return list;
    }

    std::vector<std::pair<Unboxable, u8>> expanded;
    expanded.reserve(elements.size() * 2 - 1);
    for (size_t i = 0; i < elements.size(); ++i) {
        if (i > 0) expanded.emplace_back(sep, alloc::kindFromBoxedFlag(sep_is_boxed));
        expanded.push_back(elements[i]);
    }

    return alloc::listFromUnboxables(expanded);
}

HPointer take(i64 n, HPointer list) {
    if (n <= 0 || alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    std::vector<std::pair<Unboxable, u8>> elements;
    i64 count = 0;
    for (alloc::ListCursor c(list); !c.done() && count < n; c.next(), ++count) {
        elements.emplace_back(c.current(), c.currentKind());
    }

    return alloc::listFromUnboxables(elements);
}

HPointer drop(i64 n, HPointer list) {
    if (n <= 0) return list;
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    HPointer current = list;
    i64 remaining = n;

    while (remaining > 0 && !alloc::isNil(current) && current.ptr_ind == 0) {
        void* node = allocator.resolve(current);
        if (!node) return alloc::listNil();
        Header* hdr = getHeader(node);
        if (hdr->tag == Tag_Cons) {
            current = static_cast<Cons*>(node)->tail;
            --remaining;
        } else if (hdr->tag == Tag_ConsChunk) {
            ConsChunk* cv = static_cast<ConsChunk*>(node);
            ListBacking* lb = static_cast<ListBacking*>(
                allocator.resolve(cv->backing));
            u32 run = lb->header.size - cv->offset;
            if (cv->len < run) run = cv->len;
            if (remaining >= static_cast<i64>(run)) {
                remaining -= static_cast<i64>(run);
                current = cv->next;
            } else {
                u32 k = static_cast<u32>(remaining);
                // The fields are passed by value, read before the allocation, and `consChunkView` roots
                // its HPointer arguments.
                return alloc::consChunkView(cv->backing, cv->offset + k,
                                            cv->len - k, cv->next,
                                            static_cast<u8>(hdr->unboxed & 0x3));
            }
        } else {
            return alloc::listNil();
        }
    }

    return current;
}

HPointer partition(Predicate pred, HPointer list) {
    if (alloc::isNil(list)) {
        return alloc::tuple2(alloc::boxed(alloc::listNil()),
                             alloc::boxed(alloc::listNil()), 0);
    }

    // Rooted as in `map`, with one record per buffer.
    const size_t listLen = static_cast<size_t>(length(list));
    alloc::RootedElems passing(listLen);
    alloc::RootedElems failing(listLen);
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 head_kind;

    while (cursor.read(head, head_kind)) {
        bool is_boxed = (head_kind == 0);
        bool pass;
        {
            HPointer* head_root = is_boxed ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            pass = pred(head, is_boxed);
        }
        if (pass) {
            passing.push(head, head_kind);
        } else {
            failing.push(head, head_kind);
        }
        cursor.advance();
    }

    HPointer passingList = alloc::listFromUnboxables(passing);
    HPointer failingList;
    {
        Elm::StackRootGuard guard(&passingList);
        failingList = alloc::listFromUnboxables(failing);
    }

    return alloc::tuple2(alloc::boxed(passingList), alloc::boxed(failingList), 0);
}

Unboxable foldl(Folder fold, Unboxable acc, HPointer list) {
    Unboxable result = acc;
    // The accumulator is not rooted: as an `Unboxable` with no kind, nothing here says whether it is a
    // pointer.
    alloc::RootedListCursor cursor(list);
    Unboxable head;
    u8 head_kind;

    while (cursor.read(head, head_kind)) {
        bool is_boxed = (head_kind == 0);
        {
            HPointer* head_root = is_boxed ? &head.p : nullptr;
            Elm::StackRootGuard iter_guard({head_root});
            result = fold(head, is_boxed, result);
        }
        cursor.advance();
    }

    return result;
}

Unboxable foldr(Folder fold, Unboxable acc, HPointer list) {
    // The cursor records the spine nodes, one per cons cell or chunk view, and they are rooted as one range,
    // so `fold` may allocate. Each element is read again just before its call. Unlike `foldl`, the element
    // itself is not rooted while `fold` runs. The accumulator is not rooted, as in `foldl`.
    alloc::ListBackwardCursor c(list);
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    c.rootNodes(rs);

    Unboxable result = acc;
    Unboxable v;
    u8 kind;
    while (c.prev(v, kind)) {
        result = fold(v, kind == 0, result);
    }

    rs.restoreStackRangePoint(saved);
    return result;
}

HPointer reverse(HPointer list) {
    if (alloc::isNil(list)) return list;

    SpineShape s = probeShape(list);
    if (s.n <= 1) return list;

    if (chunkEligible(s)) {
        // Allocate the whole chain, then fill it from a forward walk of `list`, last slot first. Nothing
        // allocates during the fill, so the writer's raw pointers stay valid.
        StackRootGuard guard(&list);
        HPointer head = alloc::listChunkChain(s.n, s.kind, alloc::listNil());
        alloc::ListChainReverseWriter w(head, s.n);
        for (alloc::ListCursor c(list); !c.done(); c.next()) {
            w.put(c.current());
        }
        alloc::finishChunkChain(head, s.n);
        return head;
    }

    // Otherwise cons each element onto the result, which reverses the order.
    HPointer result = alloc::listNil();
    StackRootGuard guard(&result);
    alloc::RootedListCursor c(list);
    Unboxable head;
    u8 kind;
    while (c.read(head, kind)) {
        result = alloc::cons(head, result, kind);
        c.advance();
    }
    return result;
}

HPointer sort(HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto elements = toIntVector(list);

    std::sort(elements.begin(), elements.end());

    return alloc::listFromInts(elements);
}

HPointer sortBy(KeyExtractor keyFn, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    // `keyFn` may collect, so the elements are held rooted in `elements` and the sort permutes indices
    // into it. Sorting the values themselves would leave boxed values in std::sort's temporaries, which
    // the collector cannot see. Each comparison reads the rooted slots afresh.
    alloc::RootedElems elements;
    for (const auto& [val, kind] : toVector(list)) elements.push(val, kind);

    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::sort(indices.begin(), indices.end(),
              [&](size_t ia, size_t ib) {
                  i64 ka = keyFn(elements.get(ia), elements.kind(ia) == 0);
                  // `ib`'s element is read after `ka` is computed, so it is current even if that call
                  // collected.
                  i64 kb = keyFn(elements.get(ib), elements.kind(ib) == 0);
                  return ka < kb;
              });

    alloc::RootedElems sorted(elements.size());
    for (size_t idx : indices) sorted.push(elements.get(idx), elements.kind(idx));
    return alloc::listFromUnboxables(sorted);
}

HPointer sortWith(Comparator cmp, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    // Rooted and sorted by index, as in `sortBy`.
    alloc::RootedElems elements;
    for (const auto& [val, kind] : toVector(list)) elements.push(val, kind);

    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::sort(indices.begin(), indices.end(),
              [&](size_t ia, size_t ib) {
                  return cmp(elements.get(ia), elements.kind(ia) == 0,
                             elements.get(ib), elements.kind(ib) == 0) < 0;
              });

    alloc::RootedElems sorted(elements.size());
    for (size_t idx : indices) sorted.push(elements.get(idx), elements.kind(idx));
    return alloc::listFromUnboxables(sorted);
}

HPointer maximum(HPointer list) {
    if (alloc::isNil(list)) return alloc::nothing();

    auto elements = toVector(list);
    if (elements.empty()) return alloc::nothing();

    auto maxIt = std::max_element(elements.begin(), elements.end(),
                                   [](const auto& a, const auto& b) {
                                       return a.first.i < b.first.i;
                                   });

    return alloc::justKind(maxIt->first, maxIt->second);
}

HPointer minimum(HPointer list) {
    if (alloc::isNil(list)) return alloc::nothing();

    auto elements = toVector(list);
    if (elements.empty()) return alloc::nothing();

    auto minIt = std::min_element(elements.begin(), elements.end(),
                                   [](const auto& a, const auto& b) {
                                       return a.first.i < b.first.i;
                                   });

    return alloc::justKind(minIt->first, minIt->second);
}

HPointer map2(HPointer listA, HPointer listB) {
    if (alloc::isNil(listA) || alloc::isNil(listB)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Copy the elements and their slot kinds out without allocating.
    struct RawPair { Unboxable a; u8 a_kind; Unboxable b; u8 b_kind; };
    std::vector<RawPair> raw;
    {
        alloc::ListCursor ca(listA);
        alloc::ListCursor cb(listB);
        while (!ca.done() && !cb.done()) {
            raw.push_back({ca.current(), ca.currentKind(),
                           cb.current(), cb.currentKind()});
            ca.next();
            cb.next();
        }
    }

    if (raw.empty()) return alloc::listNil();

    // Root each column with one record, and read each value back after the allocations before it.
    alloc::RootedElems as(raw.size());
    alloc::RootedElems bs(raw.size());
    for (const auto& r : raw) {
        as.push(r.a, r.a_kind);
        bs.push(r.b, r.b_kind);
    }
    HPointer result = alloc::listNil();
    Elm::StackRootGuard result_guard(&result);

    for (size_t i = raw.size(); i > 0; --i) {
        u32 mask = static_cast<u32>(bitmapSetKind(0, 0, as.kind(i - 1)));
        mask = static_cast<u32>(bitmapSetKind(mask, 1, bs.kind(i - 1)));
        HPointer tuple = alloc::tuple2(as.get(i - 1), bs.get(i - 1), mask);
        result = alloc::cons(alloc::boxed(tuple), result, true);
    }

    return result;
}

HPointer map3(HPointer listA, HPointer listB, HPointer listC) {
    if (alloc::isNil(listA) || alloc::isNil(listB) || alloc::isNil(listC)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();

    // Copy the elements and their slot kinds out without allocating.
    struct RawTriple {
        Unboxable a; u8 a_kind;
        Unboxable b; u8 b_kind;
        Unboxable c; u8 c_kind;
    };
    std::vector<RawTriple> raw;
    {
        alloc::ListCursor ca(listA);
        alloc::ListCursor cb(listB);
        alloc::ListCursor cc(listC);
        while (!ca.done() && !cb.done() && !cc.done()) {
            raw.push_back({ca.current(), ca.currentKind(),
                           cb.current(), cb.currentKind(),
                           cc.current(), cc.currentKind()});
            ca.next();
            cb.next();
            cc.next();
        }
    }

    if (raw.empty()) return alloc::listNil();

    // Rooted as in `map2`.
    alloc::RootedElems as(raw.size());
    alloc::RootedElems bs(raw.size());
    alloc::RootedElems cs(raw.size());
    for (const auto& r : raw) {
        as.push(r.a, r.a_kind);
        bs.push(r.b, r.b_kind);
        cs.push(r.c, r.c_kind);
    }
    HPointer result = alloc::listNil();
    Elm::StackRootGuard result_guard(&result);

    for (size_t i = raw.size(); i > 0; --i) {
        u32 mask = static_cast<u32>(bitmapSetKind(0, 0, as.kind(i - 1)));
        mask = static_cast<u32>(bitmapSetKind(mask, 1, bs.kind(i - 1)));
        mask = static_cast<u32>(bitmapSetKind(mask, 2, cs.kind(i - 1)));
        HPointer tuple = alloc::tuple3(as.get(i - 1), bs.get(i - 1), cs.get(i - 1), mask);
        result = alloc::cons(alloc::boxed(tuple), result, true);
    }

    return result;
}

HPointer unzip(HPointer listOfPairs) {
    if (alloc::isNil(listOfPairs)) {
        return alloc::tuple2(alloc::boxed(alloc::listNil()),
                             alloc::boxed(alloc::listNil()), 0);
    }

    auto& allocator = Allocator::instance();
    // Both columns are rooted before either list is built, because building the first allocates.
    alloc::RootedElems firsts;
    alloc::RootedElems seconds;

    for (alloc::ListCursor c(listOfPairs); !c.done(); c.next()) {
        void* tupleObj = allocator.resolve(c.current().p);
        if (tupleObj) {
            Tuple2* tuple = static_cast<Tuple2*>(tupleObj);
            Header* hdr = getHeader(tupleObj);

            u8 aKind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
            u8 bKind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 1));

            firsts.push(tuple->a, aKind);
            seconds.push(tuple->b, bKind);
        }
    }

    HPointer firstList = alloc::listFromUnboxables(firsts);
    HPointer secondList;
    {
        Elm::StackRootGuard guard(&firstList);
        secondList = alloc::listFromUnboxables(seconds);
    }

    return alloc::tuple2(alloc::boxed(firstList), alloc::boxed(secondList), 0);
}

} // namespace ListOps
} // namespace Elm
