/**
 * String Operations Implementation.
 */

#include "StringOps.hpp"
#include <vector>

namespace Elm {
namespace StringOps {

// ============================================================================
// Constructors and Flatten Helpers (Phase 1)
// ============================================================================

HPointer makeLeafFromBuffer(const u16* data, u32 len) {
    if (len == 0) return alloc::emptyString();
    return alloc::allocString(data, len);
}

HPointer makeSlice(HPointer base, u32 offset, u32 len) {
    if (len == 0) return alloc::emptyString();

    size_t total_size = sizeof(ElmStringSlice);
    total_size = (total_size + 7) & ~7;

    // base is the only HPointer needing rooting; pack it as the single
    // root. Helper roots only on slow path.
    uint64_t roots[1];
    std::memcpy(&roots[0], &base, sizeof(base));

    void* obj = eco_alloc_with_roots(Tag_StringSlice, total_size, roots, 1, 0x1);
    ElmStringSlice* slc = static_cast<ElmStringSlice*>(obj);
    slc->header.size = len;
    std::memcpy(&slc->base, &roots[0], sizeof(slc->base));
    slc->offset = offset;
    slc->_padding = 0;
    return Allocator::instance().wrap(slc);
}

HPointer makeRope(HPointer left, HPointer right) {
    auto& allocator = Allocator::instance();

    // Empty-canonicalisation: if either side is empty, return the other.
    auto sizeOf = [&](HPointer hp) -> u32 {
        if (alloc::isEmptyString(hp)) return 0;
        if (alloc::isEmbeddedConstant(hp)) return 0;
        void* obj = allocator.resolve(hp);
        return obj ? static_cast<Header*>(obj)->size : 0;
    };

    u32 leftLen = sizeOf(left);
    u32 rightLen = sizeOf(right);
    if (leftLen == 0 && rightLen == 0) return alloc::emptyString();
    if (leftLen == 0) return right;
    if (rightLen == 0) return left;

    // Pre-compute height + leafCount before we allocate (resolved pointers
    // become invalid after a GC, but the integers we read are scalars).
    auto heightLeafOf = [&](HPointer hp) -> std::pair<u32, u32> {
        if (alloc::isEmbeddedConstant(hp)) return {0, 0};
        void* obj = allocator.resolve(hp);
        if (!obj) return {0, 0};
        Tag t = alloc::getTag(obj);
        if (t == Tag_StringRope) {
            ElmStringRope* r = static_cast<ElmStringRope*>(obj);
            return {r->height, r->leafCount};
        }
        return {0, 1};
    };

    auto [lh, lc] = heightLeafOf(left);
    auto [rh, rc] = heightLeafOf(right);
    u32 newHeight = 1 + std::max(lh, rh);
    u32 newLeafCount = lc + rc;

    size_t total_size = sizeof(ElmStringRope);
    total_size = (total_size + 7) & ~7;

    // Pack left/right as roots; helper handles slow-path rooting.
    uint64_t roots[2];
    std::memcpy(&roots[0], &left,  sizeof(left));
    std::memcpy(&roots[1], &right, sizeof(right));

    void* obj = eco_alloc_with_roots(Tag_StringRope, total_size, roots, 2, 0x3);
    ElmStringRope* rope = static_cast<ElmStringRope*>(obj);
    rope->header.size = leftLen + rightLen;
    std::memcpy(&rope->left,  &roots[0], sizeof(rope->left));
    std::memcpy(&rope->right, &roots[1], sizeof(rope->right));
    rope->height = newHeight;
    rope->leafCount = newLeafCount;
    return allocator.wrap(rope);
}

HPointer makeUtf8View(HPointer base, u32 byteOffset, u32 len) {
    if (len == 0) return alloc::emptyString();
    auto& allocator = Allocator::instance();

    // Collapse view-of-slice / view-of-view so `base` is a leaf / buffer /
    // large-header, never itself a slice or view (mirrors makeByteBufferSlice).
    void* base_obj = allocator.resolve(base);
    if (base_obj) {
        Header* h = static_cast<Header*>(base_obj);
        if (h->tag == Tag_ByteBufferSlice) {
            ElmByteBufferSlice* inner = static_cast<ElmByteBufferSlice*>(base_obj);
            base = inner->base;
            byteOffset += inner->offset;
        } else if (h->tag == Tag_StringUtf8View) {
            ElmStringUtf8View* inner = static_cast<ElmStringUtf8View*>(base_obj);
            base = inner->base;
            byteOffset += inner->offset;
        }
    }

    size_t total_size = (sizeof(ElmStringUtf8View) + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &base, sizeof(base));
    ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(
        eco_alloc_with_roots(Tag_StringUtf8View, total_size, roots, 1, 0x1));
    std::memcpy(&base, &roots[0], sizeof(base));
    v->header.size = len;
    std::memcpy(&v->base, &roots[0], sizeof(v->base));
    v->offset = byteOffset;
    v->byteLen = len;
    return allocator.wrap(v);
}

HPointer makeUtf8LeafFromBytes(const u8* bytes, u32 len) {
    if (len == 0) return alloc::emptyString();
    auto& allocator = Allocator::instance();

    // Master switch: when UTF-8 strings are disabled, widen to a UTF-16 leaf.
    // This is the single "from raw bytes" chokepoint (fromInt/fromFloat, the
    // slice tiny path, read_string's short path), so gating it here — plus the
    // read_string view gate — means no UTF-8 form is ever created when off.
    if (!allocator.getConfig().utf8_strings_enabled) {
        std::vector<u16> wide(len);
        Utf8::widenAscii(bytes, len, wide.data());
        return alloc::allocString(wide.data(), len);
    }

    size_t total_size = (sizeof(ElmStringUtf8Leaf) + len + 7) & ~7;
    if (total_size >= allocator.getLargeObjectThreshold()) {
        // No large UTF-8 form in v1: widen to a UTF-16 leaf (which routes to
        // the split-header path). `bytes` is read into `wide` before any Elm
        // allocation, so a GC in allocString cannot invalidate it.
        std::vector<u16> wide(len);
        Utf8::widenAscii(bytes, len, wide.data());
        return alloc::allocString(wide.data(), len);
    }

    // `bytes` may point into a movable heap object (a ByteBuffer payload or a
    // UTF-8 leaf); the allocation below can trigger a minor GC that relocates
    // it. Snapshot to the C stack first.
    std::vector<u8> snapshot(bytes, bytes + len);
    void* obj = eco_alloc_with_roots(Tag_StringUtf8Leaf, total_size, nullptr, 0, 0);
    ElmStringUtf8Leaf* leaf = static_cast<ElmStringUtf8Leaf*>(obj);
    leaf->header.size = len;
    std::memcpy(leaf->bytes, snapshot.data(), len);
#if ECO_HEAP_VALIDATE
    for (u32 i = 0; i < len; ++i)
        assert(!(leaf->bytes[i] & 0x80) && "UTF-8 leaf must be all-ASCII");
#endif
    return allocator.wrap(leaf);
}

HPointer flattenToLeaf(HPointer s) {
    if (alloc::isEmbeddedConstant(s)) return s;  // Const_EmptyString stays embedded

    auto& allocator = Allocator::instance();
    void* obj = allocator.resolve(s);
    if (!obj) return alloc::emptyString();

    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_String) return s;  // already a leaf
    // Split-header forms are conceptually leaves: their body is a flat
    // Tag_String. Returning the header preserves the split optimisation
    // (flatten consumers should not need to materialise an inline copy).
    if (hdr->tag == Tag_LargeStringHeader) return s;
    if (hdr->size == 0) return alloc::emptyString();

    // Materialise the bytes BEFORE allocation (the resolved void* is invalid
    // after a GC). Read with offset for slice; full chars[] for leaf.
    std::u16string buf = toStdU16String(obj);

    // No need to root `s` here: we never read `obj` again after the alloc,
    // and `buf` lives on the C stack (not the Elm heap).
    return alloc::allocString(reinterpret_cast<const u16*>(buf.data()),
                              buf.size());
}

HPointer maybeFlattenOrRebalance(HPointer s, FlattenReason reason) {
    if (alloc::isEmbeddedConstant(s)) return s;
    auto& allocator = Allocator::instance();
    void* obj = allocator.resolve(s);
    if (!obj) return s;
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_String) return s;  // already flat
    if (hdr->tag == Tag_LargeStringHeader) return s;  // split-header is leaf-like
    if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
        // ensureFlat consumers (e.g. the parser) cast the result to
        // ElmString* and index chars[], so a UTF-8 form must always widen to a
        // UTF-16 leaf regardless of size — never pass through structurally.
        return flattenToLeaf(s);
    }
    const HeapConfig& cfg = allocator.getConfig();
    if (hdr->size <= cfg.string_flatten_limit) {
        return flattenToLeaf(s);
    }
    // Oversized: keep structural form to bound memory. For ropes, this is
    // also where rebalance heuristics fire — but actual rebalancing is
    // deferred per the plan (Q9). The conditions checked here are for the
    // future rebalancer; today we only emit a debug TODO.
    if (hdr->tag == Tag_StringRope && reason == FlattenReason::Structural) {
        ElmStringRope* r = static_cast<ElmStringRope*>(obj);
        bool tall = r->height > cfg.rope_max_height;
        bool tooManyTinyLeaves = r->leafCount > cfg.rope_leaf_count_limit &&
                                 (r->header.size / r->leafCount) < cfg.rope_min_leaf_size;
        if (tall || tooManyTinyLeaves) {
            // TODO: rebalance — keep this rope as-is for now.
        }
    }
    return s;
}

HPointer ensureFlat(HPointer s) {
    return maybeFlattenOrRebalance(s, FlattenReason::RandomAccess);
}

// ============================================================================
// slice — builds a Tag_StringSlice for non-tiny ranges over leaves; collapses
// slice-of-slice into a single slice over the underlying leaf base.
// ============================================================================

HPointer slice(void* str, i64 start, i64 end) {
    if (!str) return alloc::emptyString();
    Header* hdr = static_cast<Header*>(str);
    i64 len = static_cast<i64>(hdr->size);

    // Normalize negative indices.
    if (start < 0) start = std::max(i64(0), len + start);
    if (end < 0) end = std::max(i64(0), len + end);

    // Clamp.
    start = std::max(i64(0), std::min(start, len));
    end = std::max(i64(0), std::min(end, len));

    if (start >= end) return alloc::emptyString();
    if (start == 0 && end == len) return Allocator::instance().wrap(str);

    size_t slice_len = static_cast<size_t>(end - start);
    auto& allocator = Allocator::instance();

    // UTF-8 (ASCII) forms: the unit index is the byte offset. Tiny ranges copy
    // a fresh UTF-8 leaf; larger ranges share the source via a UTF-8 view. No
    // transcode, result stays UTF-8.
    if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
        if (slice_len <= allocator.getConfig().string_tiny_slice_limit) {
            auto pr = utf8Bytes(str);
            return makeUtf8LeafFromBytes(pr.first + start,
                                         static_cast<u32>(slice_len));
        }
        if (hdr->tag == Tag_StringUtf8Leaf) {
            HPointer baseHp = allocator.wrap(str);
            return makeUtf8View(baseHp, static_cast<u32>(start),
                                static_cast<u32>(slice_len));
        }
        // View: collapse onto the view's own base + adjusted byte offset.
        ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(str);
        HPointer baseHp = v->base;
        u32 baseOffset = v->offset + static_cast<u32>(start);
        return makeUtf8View(baseHp, baseOffset, static_cast<u32>(slice_len));
    }

    // Tiny slice: flatten directly into a leaf — avoids slice metadata for
    // short ranges and matches the prior behaviour.
    if (slice_len <= allocator.getConfig().string_tiny_slice_limit) {
        if (hdr->tag == Tag_String) {
            // Direct allocString from the source pointer — no intermediate vector.
            ElmString* s = static_cast<ElmString*>(str);
            return alloc::allocString(s->chars + start, slice_len);
        }
        if (hdr->tag == Tag_LargeStringHeader) {
            LargeStringHeader* h = static_cast<LargeStringHeader*>(str);
            void* body = allocator.resolve(h->body);
            if (!body) return alloc::emptyString();
            ElmString* leaf = static_cast<ElmString*>(body);
            return alloc::allocString(leaf->chars + start, slice_len);
        }
        if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            u32 baseOffset = slc->offset;
            void* baseObj = allocator.resolve(slc->base);
            if (!baseObj) return alloc::emptyString();
            if (static_cast<Header*>(baseObj)->tag == Tag_LargeStringHeader) {
                LargeStringHeader* lh = static_cast<LargeStringHeader*>(baseObj);
                baseObj = allocator.resolve(lh->body);
                if (!baseObj) return alloc::emptyString();
            }
            ElmString* leaf = static_cast<ElmString*>(baseObj);
            assert(leaf->header.tag == Tag_String &&
                   "Tag_StringSlice base must resolve to Tag_String "
                   "(directly or via Tag_LargeStringHeader::body)");
            assert(static_cast<u64>(baseOffset) + static_cast<u64>(start) +
                       static_cast<u64>(slice_len) <=
                   static_cast<u64>(leaf->header.size) &&
                   "slice range exceeds underlying leaf");
            return alloc::allocString(leaf->chars + baseOffset + start, slice_len);
        }
        // Rope: walk leaf segments via forEachSegment, advancing past `start`
        // logical positions and writing the next `slice_len` units into the
        // result. Avoids per-char charAt tag dispatch.
        HPointer srcHp = allocator.wrap(str);
        alloc::BlankString out;
        {
            Elm::StackRootGuard guard(&srcHp);
            out = alloc::allocStringBlank(slice_len);
        }
        i64 remaining_skip = start;
        u32 written = 0;
        forEachSegment(allocator.resolve(srcHp), [&](const u16* p, u32 n) {
            if (written >= slice_len) return;
            u32 segOff = 0;
            if (remaining_skip > 0) {
                if (static_cast<i64>(n) <= remaining_skip) {
                    remaining_skip -= n;
                    return;
                }
                segOff = static_cast<u32>(remaining_skip);
                remaining_skip = 0;
            }
            u32 take = std::min<u32>(n - segOff, slice_len - written);
            std::memcpy(out.chars + written, p + segOff, take * sizeof(u16));
            written += take;
        });
        return out.hp;
    }

    // Large slice over a leaf: build a Tag_StringSlice over the source.
    if (hdr->tag == Tag_String) {
        HPointer baseHp = allocator.wrap(str);
        return makeSlice(baseHp, static_cast<u32>(start), static_cast<u32>(slice_len));
    }
    // Large slice over a split-header: keep the slice's `base` pointing at
    // the Tag_LargeStringHeader itself, NOT at the body. The body's lifetime
    // is governed by nursery_owned_bodies_ + sweepNurseryLargeBodies, which
    // tracks reachability via the header. If we set base = h->body, dropping
    // the original header (and any intervening references) would let
    // sweepNurseryLargeBodies free the body even though the slice still
    // references it. Reads through the slice resolve through the header
    // (charAt / toStdU16String handle this case).
    if (hdr->tag == Tag_LargeStringHeader) {
        HPointer headerHp = allocator.wrap(str);
        return makeSlice(headerHp, static_cast<u32>(start), static_cast<u32>(slice_len));
    }

    // Large slice over a slice: collapse to a single slice over the deepest
    // leaf base by adding offsets.
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        HPointer baseHp = slc->base;
        u32 baseOffset = slc->offset + static_cast<u32>(start);
        return makeSlice(baseHp, baseOffset, static_cast<u32>(slice_len));
    }

    // Rope: walk by child lengths and rebuild a rope-of-slices for the cut
    // pieces, sharing fully-included subtrees. Done via recursion on the
    // resolved children. We snapshot the rope's children up front because
    // makeSlice/makeRope both allocate.
    HPointer self = allocator.wrap(str);
    Elm::StackRootGuard rootSelf(&self);
    void* topObj = allocator.resolve(self);
    if (!topObj) return alloc::emptyString();
    ElmStringRope* topRope = static_cast<ElmStringRope*>(topObj);
    HPointer leftHp = topRope->left;
    HPointer rightHp = topRope->right;

    void* leftObj = allocator.resolve(leftHp);
    u32 leftLen = leftObj ? static_cast<Header*>(leftObj)->size : 0;

    if (static_cast<u64>(end) <= leftLen) {
        // Entire range is in the left subtree; recurse.
        return slice(leftObj, start, end);
    }
    if (static_cast<u64>(start) >= leftLen) {
        void* rightObj = allocator.resolve(rightHp);
        return slice(rightObj, start - leftLen, end - leftLen);
    }

    // Spans both children: build a rope of (left[start..leftLen) ++ right[0..end-leftLen)).
    HPointer leftPiece = slice(leftObj, start, static_cast<i64>(leftLen));
    Elm::StackRootGuard rootLeft(&leftPiece);
    void* rightObj = allocator.resolve(rightHp);
    HPointer rightPiece = slice(rightObj, 0, end - static_cast<i64>(leftLen));
    return makeRope(leftPiece, rightPiece);
}

// ============================================================================
// concat / join / indexes / split / toList / uncons / map / filter / foldl /
// foldr / toStdString — all updated to handle slice inputs by snapshotting
// via toStdU16String / charAt before any allocation.
// ============================================================================

// Build a balanced rope from a pre-collected vector of element HPointers
// using the merge-stack algorithm. Each new element is pushed onto a stack;
// adjacent stack entries of similar size are merged. This avoids the
// degenerate O(n^2) shape of left-leaning chains and produces a
// reasonably balanced tree with O(log n) merges per push.
//
// The vector itself must be GC-rooted by the caller (use
// StackRootRangeGuard with mask=all-1s). Each merge uses makeRope, which
// itself roots its arguments across allocation, so this loop is safe.
static HPointer buildBalancedRope(std::vector<HPointer>& parts) {
    if (parts.empty()) return alloc::emptyString();
    if (parts.size() == 1) return parts[0];

    auto& allocator = Allocator::instance();
    auto rawSize = [&](HPointer hp) -> u32 {
        if (alloc::isEmbeddedConstant(hp)) return 0;
        void* obj = allocator.resolve(hp);
        return obj ? static_cast<Header*>(obj)->size : 0;
    };

    // Merge adjacent stack entries while top.size() <= second.size().
    // The merge stack itself holds HPointers that must survive each makeRope
    // allocation; without rooting `stack.data()`, a GC inside makeRope would
    // leave the entries we haven't yet merged dangling at their from-space
    // addresses.
    std::vector<HPointer> stack;
    stack.reserve(parts.size());
    for (auto& hp : parts) {
        stack.push_back(hp);
        while (stack.size() >= 2) {
            HPointer top = stack[stack.size() - 1];
            HPointer next = stack[stack.size() - 2];
            if (rawSize(top) > rawSize(next)) break;
            HPointer merged;
            {
                Elm::StackRootRangeGuard stack_guard(stack.data(), stack.size(), ~0ULL);
                merged = makeRope(next, top);
            }
            stack.pop_back();
            stack.pop_back();
            stack.push_back(merged);
        }
    }
    while (stack.size() >= 2) {
        HPointer top = stack.back();
        HPointer next = stack[stack.size() - 2];
        HPointer merged;
        {
            Elm::StackRootRangeGuard stack_guard(stack.data(), stack.size(), ~0ULL);
            merged = makeRope(next, top);
        }
        stack.pop_back();
        stack.pop_back();
        stack.push_back(merged);
    }
    return stack[0];
}

HPointer concat(HPointer stringList) {
    auto& allocator = Allocator::instance();

    // First pass: calculate total length using header.size for any string tag.
    size_t total_len = 0;
    size_t count = 0;
    HPointer current = stringList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        if (!alloc::isEmptyString(c->head.p)) {
            void* strObj = allocator.resolve(c->head.p);
            if (strObj) {
                total_len += static_cast<Header*>(strObj)->size;
                ++count;
            }
        }
        current = c->tail;
    }

    if (total_len == 0) return alloc::emptyString();

    // Pattern B: stringList is NOT a field of the result string — it's
    // walked AFTER the allocation to populate result->chars. So we must
    // keep it live across the allocate via the helper's slow-path
    // rooting, then re-read the (possibly relocated) handle from roots[].
    if (total_len <= allocator.getConfig().string_flatten_limit) {
        size_t data_size = total_len * sizeof(u16);
        size_t total_size = sizeof(ElmString) + data_size;
        total_size = (total_size + 7) & ~7;

        uint64_t roots[1];
        std::memcpy(&roots[0], &stringList, sizeof(stringList));
        ElmString* result = static_cast<ElmString*>(
            eco_alloc_with_roots(Tag_String, total_size, roots, 1, 0x1));
        std::memcpy(&stringList, &roots[0], sizeof(stringList));
        result->header.size = static_cast<u32>(total_len);

        // Second pass: copy each element's segments straight into result->chars
        // via the tag-aware visitor — no per-element std::u16string alloc.
        size_t offset = 0;
        current = stringList;

        while (!alloc::isNil(current)) {
            void* cell = allocator.resolve(current);
            if (!cell) break;

            Cons* c = static_cast<Cons*>(cell);
            if (!alloc::isEmptyString(c->head.p)) {
                void* strObj = allocator.resolve(c->head.p);
                if (strObj) {
                    forEachSegment(strObj, [&](const u16* p, u32 n) {
                        std::memcpy(result->chars + offset, p, n * sizeof(u16));
                        offset += n;
                    });
                }
            }
            current = c->tail;
        }

        return allocator.wrap(result);
    }

    // Large total: collect element HPointers and build a balanced rope.
    // Skipping empty children matches the existing concat semantics.
    std::vector<HPointer> parts;
    parts.reserve(count);
    current = stringList;
    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;
        Cons* c = static_cast<Cons*>(cell);
        if (!alloc::isEmptyString(c->head.p)) {
            void* strObj = allocator.resolve(c->head.p);
            if (strObj && static_cast<Header*>(strObj)->size > 0) {
                parts.push_back(c->head.p);
            }
        }
        current = c->tail;
    }

    // Root all parts in one batch range across rope construction. mask=all-1s
    // tells the GC every slot is a boxed HPointer.
    Elm::StackRootRangeGuard partsGuard(parts.data(), parts.size(), ~0ULL);
    return buildBalancedRope(parts);
}

HPointer join(void* sep, HPointer stringList) {
    auto& allocator = Allocator::instance();
    size_t sep_len = sep ? static_cast<Header*>(sep)->size : 0;

    // Wrap separator as HPointer for the rope-building path; rooted via
    // stackRootRange below. The wrap() must happen before any GC.
    HPointer sepHp = sep ? allocator.wrap(sep) : alloc::emptyString();

    // First pass: count strings and total length.
    size_t total_len = 0;
    size_t count = 0;
    HPointer current = stringList;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        if (!alloc::isEmptyString(c->head.p)) {
            void* strObj = allocator.resolve(c->head.p);
            if (strObj) {
                total_len += static_cast<Header*>(strObj)->size;
            }
        }
        ++count;
        current = c->tail;
    }

    if (count == 0) return alloc::emptyString();
    total_len += sep_len * (count - 1);

    if (total_len <= allocator.getConfig().string_flatten_limit) {
        size_t data_size = total_len * sizeof(u16);
        size_t total_size = sizeof(ElmString) + data_size;
        total_size = (total_size + 7) & ~7;

        // Pattern B: both stringList and sepHp are walked AFTER the allocate
        // to populate result->chars; root them via the helper's slow-path
        // mechanism and re-read post-call.
        uint64_t roots[2];
        std::memcpy(&roots[0], &stringList, sizeof(stringList));
        std::memcpy(&roots[1], &sepHp, sizeof(sepHp));
        ElmString* result = static_cast<ElmString*>(
            eco_alloc_with_roots(Tag_String, total_size, roots, 2, 0x3));
        std::memcpy(&stringList, &roots[0], sizeof(stringList));
        std::memcpy(&sepHp, &roots[1], sizeof(sepHp));
        result->header.size = static_cast<u32>(total_len);

        size_t offset = 0;
        bool first = true;
        current = stringList;

        while (!alloc::isNil(current)) {
            void* cell = allocator.resolve(current);
            if (!cell) break;

            Cons* c = static_cast<Cons*>(cell);

            if (!first && sep_len > 0) {
                void* sepObj = allocator.resolve(sepHp);
                forEachSegment(sepObj, [&](const u16* p, u32 n) {
                    std::memcpy(result->chars + offset, p, n * sizeof(u16));
                    offset += n;
                });
            }
            first = false;

            if (!alloc::isEmptyString(c->head.p)) {
                void* strObj = allocator.resolve(c->head.p);
                if (strObj) {
                    forEachSegment(strObj, [&](const u16* p, u32 n) {
                        std::memcpy(result->chars + offset, p, n * sizeof(u16));
                        offset += n;
                    });
                }
            }
            current = c->tail;
        }
        return allocator.wrap(result);
    }

    // Large total: build a balanced rope with `sep` interleaved between elems.
    std::vector<HPointer> parts;
    parts.reserve(count * 2);
    current = stringList;
    bool first = true;
    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;
        Cons* c = static_cast<Cons*>(cell);
        if (!first && sep_len > 0) {
            parts.push_back(sepHp);
        }
        first = false;
        if (!alloc::isEmptyString(c->head.p)) {
            void* strObj = allocator.resolve(c->head.p);
            if (strObj && static_cast<Header*>(strObj)->size > 0) {
                parts.push_back(c->head.p);
            }
        }
        current = c->tail;
    }

    Elm::StackRootRangeGuard partsGuard(parts.data(), parts.size(), ~0ULL);
    return buildBalancedRope(parts);
}

HPointer indexes(void* needle, void* haystack) {
    if (!haystack) return alloc::listFromInts({});
    if (!needle) {
        size_t haystack_len = static_cast<Header*>(haystack)->size;
        std::vector<i64> indices;
        for (size_t i = 0; i <= haystack_len; ++i) {
            indices.push_back(static_cast<i64>(i));
        }
        return alloc::listFromInts(indices);
    }

    auto needleBuf = toStdU16String(needle);
    auto haystackBuf = toStdU16String(haystack);
    const u16* nPtr = reinterpret_cast<const u16*>(needleBuf.data());
    const u16* hPtr = reinterpret_cast<const u16*>(haystackBuf.data());
    size_t needle_len = needleBuf.size();
    size_t haystack_len = haystackBuf.size();

    std::vector<i64> indices;
    if (needle_len == 0) {
        for (size_t i = 0; i <= haystack_len; ++i) {
            indices.push_back(static_cast<i64>(i));
        }
    } else if (needle_len <= haystack_len) {
        // BMH for longer needles; naive otherwise.
        if (needle_len >= 4) {
            u32 skip[256];
            for (u32 i = 0; i < 256; ++i) skip[i] = static_cast<u32>(needle_len);
            for (size_t i = 0; i + 1 < needle_len; ++i) {
                skip[nPtr[i] & 0xFF] = static_cast<u32>(needle_len - 1 - i);
            }
            size_t i = 0;
            while (i + needle_len <= haystack_len) {
                size_t j = needle_len;
                while (j > 0 && hPtr[i + j - 1] == nPtr[j - 1]) --j;
                if (j == 0) {
                    indices.push_back(static_cast<i64>(i));
                    ++i;  // contains() found-overlap semantics: advance by 1
                } else {
                    i += skip[hPtr[i + needle_len - 1] & 0xFF];
                }
            }
        } else {
            for (size_t i = 0; i <= haystack_len - needle_len; ++i) {
                bool match = true;
                for (size_t j = 0; j < needle_len && match; ++j) {
                    if (hPtr[i + j] != nPtr[j]) match = false;
                }
                if (match) {
                    indices.push_back(static_cast<i64>(i));
                }
            }
        }
    }
    return alloc::listFromInts(indices);
}

HPointer split(void* sep, void* str) {
    if (!str) {
        return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
    }

    size_t sep_len = sep ? static_cast<Header*>(sep)->size : 0;
    size_t str_len = static_cast<Header*>(str)->size;

    if (str_len == 0) {
        return alloc::cons(alloc::boxed(alloc::emptyString()), alloc::listNil(), true);
    }

    if (sep_len == 0 || !sep) {
        return toList(str);
    }

    // Snapshot both strings before any allocation. toStdU16String handles
    // both leaf and slice tags and produces a contiguous std::u16string,
    // which is already a contiguous read-only u16 buffer — no need to
    // duplicate it into a std::vector.
    auto strU16 = toStdU16String(str);
    auto sepU16 = toStdU16String(sep);
    const u16* strData = reinterpret_cast<const u16*>(strU16.data());
    const u16* sepData = reinterpret_cast<const u16*>(sepU16.data());

    // Boyer-Moore-Horspool skip-table search for needles ≥ 4 chars.
    // For shorter needles the skip-table build cost outweighs the savings,
    // so we fall back to the naive byte-by-byte scan in those cases.
    std::vector<size_t> splitPositions;
    if (sep_len >= 4) {
        // Build skip table indexed by haystack char (mod 256 to bound size).
        u32 skip[256];
        for (u32 i = 0; i < 256; ++i) skip[i] = static_cast<u32>(sep_len);
        for (size_t i = 0; i + 1 < sep_len; ++i) {
            skip[sepData[i] & 0xFF] = static_cast<u32>(sep_len - 1 - i);
        }
        size_t i = 0;
        while (i + sep_len <= str_len) {
            // Compare from the end.
            size_t j = sep_len;
            while (j > 0 && strData[i + j - 1] == sepData[j - 1]) --j;
            if (j == 0) {
                splitPositions.push_back(i);
                i += sep_len;
            } else {
                i += skip[strData[i + sep_len - 1] & 0xFF];
            }
        }
    } else {
        for (size_t i = 0; i <= str_len - sep_len; ++i) {
            bool match = true;
            for (size_t j = 0; j < sep_len && match; ++j) {
                if (strData[i + j] != sepData[j]) match = false;
            }
            if (match) {
                splitPositions.push_back(i);
                i += sep_len - 1;
            }
        }
    }

    size_t numParts = splitPositions.size() + 1;
    std::vector<HPointer> parts(numParts, alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& hp : parts) rs.pushStackRootRange(&hp, 1, 1);

    size_t start = 0;
    for (size_t idx = 0; idx < splitPositions.size(); ++idx) {
        parts[idx] = alloc::allocString(strData + start,
                                         splitPositions[idx] - start);
        start = splitPositions[idx] + sep_len;
    }
    parts[splitPositions.size()] = alloc::allocString(strData + start,
                                                       str_len - start);

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(parts);
}

HPointer toList(void* str) {
    if (!str) return alloc::listNil();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::listNil();

    // `buf` is already a contiguous u16 buffer; no need to duplicate it
    // into a separate std::vector<u16>.
    const u16* chars = reinterpret_cast<const u16*>(buf.data());
    std::vector<HPointer> charPtrs(len, alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(charPtrs.data(), charPtrs.size(), ~0ULL);

    for (size_t i = 0; i < len; ++i) {
        charPtrs[i] = fromChar(chars[i]);
    }

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(charPtrs);
}

HPointer uncons(void* str) {
    if (!str) return alloc::nothing();
    Header* hdr = static_cast<Header*>(str);
    if (hdr->size == 0) return alloc::nothing();

    // Read the first char before any allocation. charAt does not allocate.
    u16 firstChar = charAt(str, 0);
    u32 restLen = hdr->size - 1;

    // Bypass slice()'s tiny-path *flattening* copy: build a Tag_StringSlice
    // directly when the source is a leaf, large-header, or another slice.
    // This makes a long fold-with-uncons over a string O(n) total allocation
    // instead of O(n²) (each tail slice would otherwise copy its full body).
    HPointer rest;
    if (restLen == 0) {
        rest = alloc::emptyString();
    } else {
        auto& allocator = Allocator::instance();
        if (hdr->tag == Tag_String || hdr->tag == Tag_LargeStringHeader) {
            HPointer baseHp = allocator.wrap(str);
            rest = makeSlice(baseHp, 1, restLen);
        } else if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            HPointer baseHp = slc->base;
            u32 newOffset = slc->offset + 1;
            rest = makeSlice(baseHp, newOffset, restLen);
        } else if (hdr->tag == Tag_StringUtf8Leaf) {
            // ASCII: rest is a UTF-8 view advanced by one byte over the leaf.
            HPointer baseHp = allocator.wrap(str);
            rest = makeUtf8View(baseHp, 1, restLen);
        } else if (hdr->tag == Tag_StringUtf8View) {
            ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(str);
            rest = makeUtf8View(v->base, v->offset + 1, restLen);
        } else {
            // Rope: defer to slice() which handles rope-aware partitioning.
            rest = slice(str, 1, static_cast<i64>(hdr->size));
        }
    }

    Unboxable charVal = alloc::unboxedChar(firstChar);
    Unboxable restVal = alloc::boxed(rest);

    // 2-bit-per-slot bitmap: field 0 = kind 3 (Char), field 1 = kind 0 (boxed HPointer)
    // bits[1:0]=11, bits[3:2]=00 => 0x3
    HPointer tuple = alloc::tuple2(charVal, restVal, 0x3);
    return alloc::just(alloc::boxed(tuple), true);
}

HPointer map(CharToCharMapper mapFunc, void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();

    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(len);
    }
    // Walk segments directly into the result, applying mapFunc per char.
    u32 written = 0;
    forEachSegment(allocator.resolve(srcHp), [&](const u16* p, u32 n) {
        for (u32 i = 0; i < n; ++i) out.chars[written + i] = mapFunc(p[i]);
        written += n;
    });
    return out.hp;
}

HPointer filter(CharPredicate pred, void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();

    // Two-pass: count survivors to allocate the right-sized result, then
    // copy survivors into it. Avoids both std::vector and std::u16string.
    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);

    u32 keptCount = 0;
    forEachSegment(allocator.resolve(srcHp), [&](const u16* p, u32 n) {
        for (u32 i = 0; i < n; ++i) if (pred(p[i])) ++keptCount;
    });

    if (keptCount == 0) return alloc::emptyString();
    if (keptCount == len && isLeaf(allocator.resolve(srcHp))) {
        return allocator.wrap(allocator.resolve(srcHp));
    }

    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&srcHp);
        out = alloc::allocStringBlank(keptCount);
    }
    u32 written = 0;
    forEachSegment(allocator.resolve(srcHp), [&](const u16* p, u32 n) {
        for (u32 i = 0; i < n; ++i) {
            if (pred(p[i])) out.chars[written++] = p[i];
        }
    });
    return out.hp;
}

Unboxable foldl(CharFolder fold, Unboxable acc, void* str) {
    if (!str) return acc;
    auto buf = toStdU16String(str);
    Unboxable result = acc;
    for (auto c : buf) {
        result = fold(c, result);
    }
    return result;
}

Unboxable foldr(CharFolder fold, Unboxable acc, void* str) {
    if (!str) return acc;
    auto buf = toStdU16String(str);
    Unboxable result = acc;
    for (size_t i = buf.size(); i > 0; --i) {
        result = fold(buf[i - 1], result);
    }
    return result;
}

std::string toStdString(void* str) {
    if (!str) return {};
    // UTF-8 (ASCII) forms: the bytes are already valid UTF-8 — copy directly.
    {
        Header* hdr = static_cast<Header*>(str);
        if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
            auto pr = utf8Bytes(str);
            return std::string(reinterpret_cast<const char*>(pr.first), pr.second);
        }
    }
    auto buf = toStdU16String(str);
    const u16* p = reinterpret_cast<const u16*>(buf.data());
    const size_t n = buf.size();

    // First pass: count UTF-8 bytes. ASCII dominates most strings, so the
    // worst-case 3x reservation almost always over-allocates by 3x; a
    // single count pass replaces that with the exact size.
    size_t out_bytes = 0;
    for (size_t i = 0; i < n; ++i) {
        u16 c = p[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) {
            u16 c2 = p[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                out_bytes += 4;
                ++i;
                continue;
            }
        }
        if (c < 0x80)       out_bytes += 1;
        else if (c < 0x800) out_bytes += 2;
        else                out_bytes += 3;
    }

    std::string result(out_bytes, '\0');
    char* out = result.data();
    size_t w = 0;
    for (size_t i = 0; i < n; ++i) {
        u16 c = p[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) {
            u16 c2 = p[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                uint32_t codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                out[w++] = static_cast<char>(0xF0 | ((codepoint >> 18) & 0x07));
                out[w++] = static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F));
                out[w++] = static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
                out[w++] = static_cast<char>(0x80 | (codepoint & 0x3F));
                ++i;
                continue;
            }
        }
        if (c < 0x80) {
            out[w++] = static_cast<char>(c);
        } else if (c < 0x800) {
            out[w++] = static_cast<char>(0xC0 | ((c >> 6) & 0x1F));
            out[w++] = static_cast<char>(0x80 | (c & 0x3F));
        } else {
            out[w++] = static_cast<char>(0xE0 | ((c >> 12) & 0x0F));
            out[w++] = static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            out[w++] = static_cast<char>(0x80 | (c & 0x3F));
        }
    }
    return result;
}

} // namespace StringOps
} // namespace Elm
