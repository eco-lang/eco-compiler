/**
 * List Operations Implementation.
 */

#include "ListOps.hpp"
#include <algorithm>
#include <numeric>

namespace Elm {
namespace ListOps {

namespace {

// Length + element-kind uniformity of a hybrid spine, in one non-allocating
// walk. `kind` is meaningful only when `uniform` and n > 0.
struct SpineShape {
    u32 n = 0;
    bool uniform = true;
    u8 kind = 0;
};

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

// A kind-uniform batch of n elements is worth ONE dense backing when chunks
// are enabled, the batch is non-tiny, and the backing stays under the
// large-object threshold so it is nursery-born (plan §2.2 cap — an over-LOT
// backing would land in pinned old gen and hold unrecorded old→young edges).
bool chunkEligible(const SpineShape& s) {
    return eco_g_list_chunks && s.uniform && s.n >= 4
        && sizeof(ListBacking) + s.n * sizeof(Unboxable)
               < Allocator::instance().getLargeObjectThreshold();
}

// Backing pointer of a freshly built view, re-resolved AFTER the view
// allocation (the caller's raw backing pointer may be stale by then).
ListBacking* resolveViewBacking(HPointer view) {
    auto& allocator = Allocator::instance();
    return static_cast<ListBacking*>(allocator.resolve(
        static_cast<ConsChunk*>(allocator.resolve(view))->backing));
}

} // namespace

HPointer head(HPointer list) {
    // Hybrid spines: the first element may live in a chunk view's backing.
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

    // Hybrid spines: listTailOf handles both Cons cells (pure load) and
    // chunk views (materializes the successor view — allocating).
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

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();

    // Collect mapped values. The spine pointer `current`, each iteration's
    // `next`/`head` snapshots, AND the boxed mapper results accumulated in
    // `mapped` all cross later mapper callbacks (which can GC), so all of
    // them must be registered as stack roots. `mapped` is reserved up front
    // so entry addresses stay stable for the incremental registration below
    // (a std::vector reallocation would invalidate registered roots); the
    // accumulated roots are released by spine_guard's destructor.
    std::vector<std::pair<Unboxable, bool>> mapped;
    mapped.reserve(static_cast<size_t>(length(list)));
    // RootedListCursor walks hybrid spines (cells + chunk views) and
    // re-resolves after every callback, so the mapper may GC freely.
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
        mapped.push_back(result);
        if (result.second) {
            rs.pushStackRootRange(&mapped.back().first.p, 1, 1);
        }
        cursor.advance();
    }

    return alloc::listFromUnboxables(mapped);
}

HPointer indexedMap(IndexedMapper mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();

    // Collect mapped values. See `map` for the rooting rationale (incl. the
    // incremental rooting of accumulated boxed results).
    std::vector<std::pair<Unboxable, bool>> mapped;
    mapped.reserve(static_cast<size_t>(length(list)));
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
        mapped.push_back(result);
        if (result.second) {
            rs.pushStackRootRange(&mapped.back().first.p, 1, 1);
        }
        ++index;
        cursor.advance();
    }

    return alloc::listFromUnboxables(mapped);
}

HPointer filter(Predicate pred, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();

    // Collect passing elements. Spine, per-iteration tail/head, AND the
    // accumulated boxed heads in `passing` must be rooted across pred()
    // (which can run user code that allocates). `passing` is reserved up
    // front so entry addresses stay stable for the incremental rooting.
    std::vector<std::pair<Unboxable, bool>> passing;
    passing.reserve(static_cast<size_t>(length(list)));
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
            passing.emplace_back(head, is_boxed);
            if (is_boxed) {
                rs.pushStackRootRange(&passing.back().first.p, 1, 1);
            }
        }
        cursor.advance();
    }

    return alloc::listFromUnboxables(passing);
}

HPointer filterMap(FilterMapper mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();

    // Collect non-Nothing results. mapper() may GC; spine, head, tail and
    // the returned `maybeResult` must all be rooted across it — and so must
    // the boxed just-values already accumulated in `results` (rooted
    // incrementally below; reserve keeps their addresses stable).
    std::vector<std::pair<Unboxable, bool>> results;
    results.reserve(static_cast<size_t>(length(list)));
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

        // Check if it's Just (not Nothing). maybeResult is fresh from mapper
        // and not held across any further allocation in this branch.
        if (!alloc::isConstant(maybeResult)) {
            void* justCell = allocator.resolve(maybeResult);
            if (justCell) {
                Custom* just = static_cast<Custom*>(justCell);
                if (just->header.tag == Tag_Custom && just->ctor == 0) {
                    // It's Just - extract the value; slot 0 kind 0 means boxed.
                    bool val_boxed = fieldKind(just->unboxed, 0) == 0;
                    results.emplace_back(just->values[0], val_boxed);
                    if (val_boxed) {
                        rs.pushStackRootRange(&results.back().first.p, 1, 1);
                    }
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

    // The probe walk is chunks-only so flag-off `++` keeps its single pass.
    if (eco_g_list_chunks) {
        SpineShape s = probeShape(a);
        if (chunkEligible(s)) {
            // Count-first direct fill (see reverse). The view's len must be
            // the TOTAL logical length (len-consistency invariant), so b's
            // length is probed too — the vector path paid the same walk
            // inside listFromUnboxables.
            StackRootGuard guard(&a, &b);
            HPointer backing = alloc::listBacking(s.n, s.kind);
            u32 totalLen = s.n + alloc::listLogicalLen(b);
            HPointer view =
                alloc::consChunkView(backing, 0, totalLen, b, s.kind);
            ListBacking* lb = resolveViewBacking(view);
            u32 i = 0;
            for (alloc::ListCursor c(a); !c.done(); c.next()) {
                lb->elems[i++] = c.current();
            }
            return view;
        }
    }

    // Small, mixed-kind, or chunks-off: collect a's prefix and build cells
    // back-to-front (n cells — a reverse-then-recons pass would pay 2n).
    std::vector<std::pair<Unboxable, bool>> elements;
    for (alloc::ListCursor c(a); !c.done(); c.next()) {
        elements.emplace_back(c.current(), c.currentKind() == 0);
    }

    return alloc::listFromUnboxables(elements, b);
}

HPointer concat(HPointer listOfLists) {
    if (alloc::isNil(listOfLists)) return alloc::listNil();

    // Chunks: probe every inner list in one non-allocating nested walk, then
    // fill an exact-size backing directly (no vector, no per-element roots).
    // The probe is chunks-only so the flag-off path keeps its single pass.
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
            HPointer backing = alloc::listBacking(s.n, s.kind);
            HPointer view = alloc::consChunkView(backing, 0, s.n,
                                                 alloc::listNil(), s.kind);
            ListBacking* lb = resolveViewBacking(view);
            u32 i = 0;
            for (alloc::ListCursor outer(listOfLists); !outer.done();
                 outer.next()) {
                for (alloc::ListCursor inner(outer.current().p);
                     !inner.done(); inner.next()) {
                    lb->elems[i++] = inner.current();
                }
            }
            return view;
        }
    }

    // Flatten all elements (non-allocating nested walks over hybrid spines;
    // outer elements are lists, i.e. always boxed).
    std::vector<std::pair<Unboxable, bool>> allElements;
    for (alloc::ListCursor outer(listOfLists); !outer.done(); outer.next()) {
        for (alloc::ListCursor inner(outer.current().p); !inner.done();
             inner.next()) {
            allElements.emplace_back(inner.current(), inner.currentKind() == 0);
        }
    }

    return alloc::listFromUnboxables(allElements);
}

HPointer intersperse(Unboxable sep, bool sep_is_boxed, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect elements (non-allocating walk over hybrid spines).
    std::vector<std::pair<Unboxable, bool>> elements;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        elements.emplace_back(c.current(), c.currentKind() == 0);
    }

    if (elements.size() <= 1) {
        return list;  // Nothing to intersperse
    }

    // Expand with separators interleaved
    std::vector<std::pair<Unboxable, bool>> expanded;
    expanded.reserve(elements.size() * 2 - 1);
    for (size_t i = 0; i < elements.size(); ++i) {
        if (i > 0) expanded.emplace_back(sep, sep_is_boxed);
        expanded.push_back(elements[i]);
    }

    return alloc::listFromUnboxables(expanded);
}

HPointer take(i64 n, HPointer list) {
    if (n <= 0 || alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect first n elements (non-allocating walk over hybrid spines).
    std::vector<std::pair<Unboxable, bool>> elements;
    i64 count = 0;
    for (alloc::ListCursor c(list); !c.done() && count < n; c.next(), ++count) {
        elements.emplace_back(c.current(), c.currentKind() == 0);
    }

    return alloc::listFromUnboxables(elements);
}

HPointer drop(i64 n, HPointer list) {
    if (n <= 0) return list;
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    HPointer current = list;
    i64 remaining = n;

    // O(spine-nodes) rather than O(n): a chunk view skips its whole run at
    // once; a mid-run drop materializes ONE successor view (plan §9.3).
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
                // Fields are copied by value before the allocation and
                // consChunkView roots its HPointer args — GC-safe.
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

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();

    // Accumulated boxed heads in passing/failing cross later pred() GC
    // points, so they are rooted incrementally as they are appended
    // (reserve keeps entry addresses stable; see `map`).
    std::vector<std::pair<Unboxable, bool>> passing;
    std::vector<std::pair<Unboxable, bool>> failing;
    const size_t listLen = static_cast<size_t>(length(list));
    passing.reserve(listLen);
    failing.reserve(listLen);
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
            passing.emplace_back(head, is_boxed);
            if (is_boxed) {
                rs.pushStackRootRange(&passing.back().first.p, 1, 1);
            }
        } else {
            failing.emplace_back(head, is_boxed);
            if (is_boxed) {
                rs.pushStackRootRange(&failing.back().first.p, 1, 1);
            }
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
    // RootedListCursor keeps the spine rooted and re-resolves across fold
    // callbacks (hybrid spines). The accumulator type is erased through
    // Unboxable so we can't tell here whether result.p is a real pointer —
    // leave it to callers that need it (foldl over a boxed accumulator
    // should root the slot at the caller).
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
    // Collect elements first (need to process in reverse). The boxed head
    // snapshots are read across each fold callback (user code that can GC),
    // so root them for the duration — mirroring foldl's per-iteration
    // rooting. The accumulator is type-erased and consumed/overwritten at
    // each call, so it needs no root here (see foldl's rationale).
    auto elements = toVector(list);

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& [val, is_boxed] : elements) {
        if (is_boxed) rs.pushStackRootRange(&val.p, 1, 1);
    }

    Unboxable result = acc;
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = fold(it->first, it->second, result);
    }

    rs.restoreStackRangePoint(saved);
    return result;
}

HPointer reverse(HPointer list) {
    if (alloc::isNil(list)) return list;

    SpineShape s = probeShape(list);
    if (s.n <= 1) return list;  // lists are immutable; sharing is safe

    if (chunkEligible(s)) {
        // Count-first: exact-size backing, then fill straight from a source
        // walk — no vector, no per-element rooting. Both allocations happen
        // before the fill, so the raw pointers below cannot go stale.
        StackRootGuard guard(&list);
        HPointer backing = alloc::listBacking(s.n, s.kind);
        HPointer view =
            alloc::consChunkView(backing, 0, s.n, alloc::listNil(), s.kind);
        ListBacking* lb = resolveViewBacking(view);
        u32 i = s.n;
        for (alloc::ListCursor c(list); !c.done(); c.next()) {
            lb->elems[--i] = c.current();
        }
        return view;
    }

    // Small or mixed-kind: plain cons accumulation (exactly what the
    // Elm-level `foldl cons []` compiled to).
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

bool member(Unboxable value, bool is_boxed, HPointer list) {
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        bool elem_is_boxed = (c.currentKind() == 0);

        // Simple equality check for unboxed primitives
        if (!is_boxed && !elem_is_boxed) {
            if (value.i == c.current().i) return true;
        } else if (is_boxed && elem_is_boxed) {
            // Identity equality for boxed values: same HPointer word (covers
            // heap pointers and embedded constants — Bool, empty, etc.).
            if (hpBits(value.p) == hpBits(c.current().p)) return true;
        }
    }

    return false;
}

HPointer sort(HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    // Collect elements (assumes integers for now)
    auto elements = toIntVector(list);

    // Sort
    std::sort(elements.begin(), elements.end());

    // Build result list
    return alloc::listFromInts(elements);
}

HPointer sortBy(KeyExtractor keyFn, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto elements = toVector(list);

    // Root every boxed head for the duration of the key extractions: keyFn
    // runs user code that can GC and move the snapshotted heads. Sort
    // indices (scalars) rather than the entries themselves so no boxed
    // value ever passes through std::sort's unrooted temporaries; the
    // rooted `elements` slots are re-read (post-GC-fixup) per comparison.
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& [val, is_boxed] : elements) {
        if (is_boxed) rs.pushStackRootRange(&val.p, 1, 1);
    }

    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::sort(indices.begin(), indices.end(),
              [&](size_t ia, size_t ib) {
                  i64 ka = keyFn(elements[ia].first, elements[ia].second);
                  // b's entry is read only after a's key extraction — a GC
                  // there updates the rooted slots in place.
                  i64 kb = keyFn(elements[ib].first, elements[ib].second);
                  return ka < kb;
              });

    std::vector<std::pair<Unboxable, bool>> sorted;
    sorted.reserve(elements.size());
    for (size_t idx : indices) sorted.push_back(elements[idx]);
    rs.restoreStackRangePoint(saved);
    return alloc::listFromUnboxables(sorted);
}

HPointer sortWith(Comparator cmp, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto elements = toVector(list);

    // Same discipline as sortBy: root the boxed heads and sort indices so
    // no boxed value crosses the comparator's GC points via std::sort's
    // unrooted temporaries.
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& [val, is_boxed] : elements) {
        if (is_boxed) rs.pushStackRootRange(&val.p, 1, 1);
    }

    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::sort(indices.begin(), indices.end(),
              [&](size_t ia, size_t ib) {
                  return cmp(elements[ia].first, elements[ia].second,
                             elements[ib].first, elements[ib].second) < 0;
              });

    std::vector<std::pair<Unboxable, bool>> sorted;
    sorted.reserve(elements.size());
    for (size_t idx : indices) sorted.push_back(elements[idx]);
    rs.restoreStackRangePoint(saved);
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

    return alloc::just(maxIt->first, maxIt->second);
}

HPointer minimum(HPointer list) {
    if (alloc::isNil(list)) return alloc::nothing();

    auto elements = toVector(list);
    if (elements.empty()) return alloc::nothing();

    auto minIt = std::min_element(elements.begin(), elements.end(),
                                   [](const auto& a, const auto& b) {
                                       return a.first.i < b.first.i;
                                   });

    return alloc::just(minIt->first, minIt->second);
}

HPointer map2(HPointer listA, HPointer listB) {
    if (alloc::isNil(listA) || alloc::isNil(listB)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Phase 1: collect raw values (no allocation)
    // Store 2-bit kinds (0=boxed, 1=Int, 2=Float, 3=Char) from source cons headers.
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

    // Phase 2: build tuples and list with rooting
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.a_kind == 0) rs.pushStackRootRange(&r.a.p, 1, 1);
        if (r.b_kind == 0) rs.pushStackRootRange(&r.b.p, 1, 1);
    }
    HPointer result = alloc::listNil();
    rs.pushStackRootRange(&result, 1, 1);

    for (auto it = raw.rbegin(); it != raw.rend(); ++it) {
        // 2-bit-per-slot bitmap: set each field's kind in its 2-bit slot.
        u32 mask = static_cast<u32>(bitmapSetKind(0, 0, it->a_kind));
        mask = static_cast<u32>(bitmapSetKind(mask, 1, it->b_kind));
        HPointer tuple = alloc::tuple2(it->a, it->b, mask);
        result = alloc::cons(alloc::boxed(tuple), result, true);
    }

    rs.restoreStackRangePoint(saved);
    return result;
}

HPointer map3(HPointer listA, HPointer listB, HPointer listC) {
    if (alloc::isNil(listA) || alloc::isNil(listB) || alloc::isNil(listC)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();

    // Phase 1: collect raw values (no allocation)
    // Store 2-bit kinds (0=boxed, 1=Int, 2=Float, 3=Char) from source cons headers.
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

    // Phase 2: build tuples and list with rooting
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.a_kind == 0) rs.pushStackRootRange(&r.a.p, 1, 1);
        if (r.b_kind == 0) rs.pushStackRootRange(&r.b.p, 1, 1);
        if (r.c_kind == 0) rs.pushStackRootRange(&r.c.p, 1, 1);
    }
    HPointer result = alloc::listNil();
    rs.pushStackRootRange(&result, 1, 1);

    for (auto it = raw.rbegin(); it != raw.rend(); ++it) {
        // 2-bit-per-slot bitmap: set each field's kind in its 2-bit slot.
        u32 mask = static_cast<u32>(bitmapSetKind(0, 0, it->a_kind));
        mask = static_cast<u32>(bitmapSetKind(mask, 1, it->b_kind));
        mask = static_cast<u32>(bitmapSetKind(mask, 2, it->c_kind));
        HPointer tuple = alloc::tuple3(it->a, it->b, it->c, mask);
        result = alloc::cons(alloc::boxed(tuple), result, true);
    }

    rs.restoreStackRangePoint(saved);
    return result;
}

HPointer unzip(HPointer listOfPairs) {
    if (alloc::isNil(listOfPairs)) {
        return alloc::tuple2(alloc::boxed(alloc::listNil()),
                             alloc::boxed(alloc::listNil()), 0);
    }

    auto& allocator = Allocator::instance();
    std::vector<std::pair<Unboxable, bool>> firsts;
    std::vector<std::pair<Unboxable, bool>> seconds;

    for (alloc::ListCursor c(listOfPairs); !c.done(); c.next()) {
        void* tupleObj = allocator.resolve(c.current().p);
        if (tupleObj) {
            Tuple2* tuple = static_cast<Tuple2*>(tupleObj);
            Header* hdr = getHeader(tupleObj);

            bool aBoxed = tupleFieldKind(hdr->unboxed, 0) == 0;
            bool bBoxed = tupleFieldKind(hdr->unboxed, 1) == 0;

            firsts.emplace_back(tuple->a, aBoxed);
            seconds.emplace_back(tuple->b, bBoxed);
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
