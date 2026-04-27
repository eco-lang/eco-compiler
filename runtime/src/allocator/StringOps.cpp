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

    auto& allocator = Allocator::instance();

    // Caller is expected to have rooted `base` already, but be defensive
    // (StackRootGuard is cheap).
    Elm::StackRootGuard guard(&base);

    size_t total_size = sizeof(ElmStringSlice);
    total_size = (total_size + 7) & ~7;
    void* obj = allocator.allocate(total_size, Tag_StringSlice);
    ElmStringSlice* slc = static_cast<ElmStringSlice*>(obj);
    slc->header.size = len;
    slc->base = base;
    slc->offset = offset;
    slc->_padding = 0;
    return allocator.wrap(slc);
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

    // Root both children across the allocation.
    Elm::StackRootGuard guard(&left, &right);

    size_t total_size = sizeof(ElmStringRope);
    total_size = (total_size + 7) & ~7;
    void* obj = allocator.allocate(total_size, Tag_StringRope);
    ElmStringRope* rope = static_cast<ElmStringRope*>(obj);
    rope->header.size = leftLen + rightLen;
    rope->left = left;
    rope->right = right;
    rope->height = newHeight;
    rope->leafCount = newLeafCount;
    return allocator.wrap(rope);
}

HPointer flattenToLeaf(HPointer s) {
    if (alloc::isEmbeddedConstant(s)) return s;  // Const_EmptyString stays embedded

    auto& allocator = Allocator::instance();
    void* obj = allocator.resolve(s);
    if (!obj) return alloc::emptyString();

    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_String) return s;  // already a leaf
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
    void* obj = Allocator::instance().resolve(s);
    if (!obj) return s;
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_String) return s;  // already flat
    if (hdr->size <= detail::FLATTEN_LIMIT) {
        return flattenToLeaf(s);
    }
    // Oversized: keep structural form to bound memory. For ropes, this is
    // also where rebalance heuristics fire — but actual rebalancing is
    // deferred per the plan (Q9). The conditions checked here are for the
    // future rebalancer; today we only emit a debug TODO.
    if (hdr->tag == Tag_StringRope && reason == FlattenReason::Structural) {
        ElmStringRope* r = static_cast<ElmStringRope*>(obj);
        bool tall = r->height > detail::MAX_HEIGHT;
        bool tooManyTinyLeaves = r->leafCount > detail::LEAFCOUNT_LIMIT &&
                                 (r->header.size / r->leafCount) < detail::MIN_LEAF_SIZE;
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

    // Tiny slice: flatten directly into a leaf — avoids slice metadata for
    // short ranges and matches the prior behaviour.
    if (slice_len <= detail::TINY_SLICE_LIMIT) {
        if (hdr->tag == Tag_String) {
            ElmString* s = static_cast<ElmString*>(str);
            std::vector<u16> data(s->chars + start, s->chars + start + slice_len);
            return alloc::allocString(data.data(), slice_len);
        }
        if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            u32 baseOffset = slc->offset;
            void* baseObj = allocator.resolve(slc->base);
            if (!baseObj) return alloc::emptyString();
            ElmString* leaf = static_cast<ElmString*>(baseObj);
            std::vector<u16> data(leaf->chars + baseOffset + start,
                                  leaf->chars + baseOffset + start + slice_len);
            return alloc::allocString(data.data(), slice_len);
        }
        // Rope: walk via charAt to fill a small buffer, then flatten.
        std::vector<u16> data(slice_len);
        for (size_t i = 0; i < slice_len; ++i) {
            data[i] = charAt(str, start + static_cast<i64>(i));
        }
        return alloc::allocString(data.data(), slice_len);
    }

    // Large slice over a leaf: build a Tag_StringSlice over the source.
    if (hdr->tag == Tag_String) {
        HPointer baseHp = allocator.wrap(str);
        return makeSlice(baseHp, static_cast<u32>(start), static_cast<u32>(slice_len));
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
    std::vector<HPointer> stack;
    stack.reserve(parts.size());
    for (auto& hp : parts) {
        stack.push_back(hp);
        while (stack.size() >= 2) {
            HPointer top = stack[stack.size() - 1];
            HPointer next = stack[stack.size() - 2];
            if (rawSize(top) > rawSize(next)) break;
            stack.pop_back();
            stack.pop_back();
            HPointer merged = makeRope(next, top);
            stack.push_back(merged);
        }
    }
    while (stack.size() >= 2) {
        HPointer top = stack.back(); stack.pop_back();
        HPointer next = stack.back(); stack.pop_back();
        stack.push_back(makeRope(next, top));
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

    // Root stringList across the allocation so GC updates it.
    Elm::StackRootGuard guard(&stringList);

    if (total_len <= detail::FLATTEN_LIMIT) {
        size_t data_size = total_len * sizeof(u16);
        size_t total_size = sizeof(ElmString) + data_size;
        total_size = (total_size + 7) & ~7;

        ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
        result->header.size = static_cast<u32>(total_len);

        // Second pass: copy via tag-aware toStdU16String to handle slice/rope.
        size_t offset = 0;
        current = stringList;

        while (!alloc::isNil(current)) {
            void* cell = allocator.resolve(current);
            if (!cell) break;

            Cons* c = static_cast<Cons*>(cell);
            if (!alloc::isEmptyString(c->head.p)) {
                void* strObj = allocator.resolve(c->head.p);
                if (strObj) {
                    auto buf = toStdU16String(strObj);
                    std::memcpy(result->chars + offset, buf.data(),
                                buf.size() * sizeof(u16));
                    offset += buf.size();
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

    // Snapshot the separator data before any allocation. After allocate(),
    // `sep` (a void* into the heap) may be invalid; the snapshot is on the
    // C stack and unaffected.
    std::vector<u16> sepData;
    if (sep && sep_len > 0) {
        auto sepBuf = toStdU16String(sep);
        sepData.assign(sepBuf.begin(), sepBuf.end());
    }

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

    // Root stringList + sepHp across allocation.
    Elm::StackRootGuard guard(&stringList, &sepHp);

    if (total_len <= detail::FLATTEN_LIMIT) {
        size_t data_size = total_len * sizeof(u16);
        size_t total_size = sizeof(ElmString) + data_size;
        total_size = (total_size + 7) & ~7;

        ElmString* result = static_cast<ElmString*>(allocator.allocate(total_size, Tag_String));
        result->header.size = static_cast<u32>(total_len);

        size_t offset = 0;
        bool first = true;
        current = stringList;

        while (!alloc::isNil(current)) {
            void* cell = allocator.resolve(current);
            if (!cell) break;

            Cons* c = static_cast<Cons*>(cell);

            if (!first && sep_len > 0) {
                std::memcpy(result->chars + offset, sepData.data(),
                            sep_len * sizeof(u16));
                offset += sep_len;
            }
            first = false;

            if (!alloc::isEmptyString(c->head.p)) {
                void* strObj = allocator.resolve(c->head.p);
                if (strObj) {
                    auto buf = toStdU16String(strObj);
                    std::memcpy(result->chars + offset, buf.data(),
                                buf.size() * sizeof(u16));
                    offset += buf.size();
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
    size_t needle_len = needleBuf.size();
    size_t haystack_len = haystackBuf.size();

    std::vector<i64> indices;
    if (needle_len == 0) {
        for (size_t i = 0; i <= haystack_len; ++i) {
            indices.push_back(static_cast<i64>(i));
        }
    } else if (needle_len <= haystack_len) {
        for (size_t i = 0; i <= haystack_len - needle_len; ++i) {
            bool match = true;
            for (size_t j = 0; j < needle_len && match; ++j) {
                if (haystackBuf[i + j] != needleBuf[j]) match = false;
            }
            if (match) {
                indices.push_back(static_cast<i64>(i));
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
    // both leaf and slice tags and produces a contiguous std::u16string.
    auto strU16 = toStdU16String(str);
    auto sepU16 = toStdU16String(sep);
    std::vector<u16> strData(strU16.begin(), strU16.end());
    std::vector<u16> sepData(sepU16.begin(), sepU16.end());

    std::vector<size_t> splitPositions;
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

    size_t numParts = splitPositions.size() + 1;
    std::vector<HPointer> parts(numParts, alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& hp : parts) rs.pushStackRootRange(&hp, 1, 1);

    size_t start = 0;
    for (size_t idx = 0; idx < splitPositions.size(); ++idx) {
        parts[idx] = alloc::allocString(strData.data() + start,
                                         splitPositions[idx] - start);
        start = splitPositions[idx] + sep_len;
    }
    parts[splitPositions.size()] = alloc::allocString(strData.data() + start,
                                                       str_len - start);

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(parts);
}

HPointer toList(void* str) {
    if (!str) return alloc::listNil();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::listNil();

    std::vector<u16> chars(buf.begin(), buf.end());
    std::vector<HPointer> charPtrs(len, alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& hp : charPtrs) rs.pushStackRootRange(&hp, 1, 1);

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
    HPointer rest = slice(str, 1, static_cast<i64>(hdr->size));

    Unboxable charVal = alloc::unboxedChar(firstChar);
    Unboxable restVal = alloc::boxed(rest);

    // 2-bit-per-slot bitmap: field 0 = kind 3 (Char), field 1 = kind 0 (boxed HPointer)
    // bits[1:0]=11, bits[3:2]=00 => 0x3
    HPointer tuple = alloc::tuple2(charVal, restVal, 0x3);
    return alloc::just(alloc::boxed(tuple), true);
}

HPointer map(CharToCharMapper mapFunc, void* str) {
    if (!str) return alloc::emptyString();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    std::vector<u16> data(len);
    for (size_t i = 0; i < len; ++i) {
        data[i] = mapFunc(buf[i]);
    }
    return alloc::allocString(data.data(), len);
}

HPointer filter(CharPredicate pred, void* str) {
    if (!str) return alloc::emptyString();
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::emptyString();

    std::vector<u16> data;
    data.reserve(len);
    for (auto c : buf) {
        if (pred(c)) data.push_back(c);
    }

    if (data.empty()) return alloc::emptyString();
    if (data.size() == len && isLeaf(str)) return Allocator::instance().wrap(str);
    return alloc::allocString(data.data(), data.size());
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
    auto buf = toStdU16String(str);
    std::string result;
    result.reserve(buf.size() * 3);  // Worst case for UTF-8

    for (size_t i = 0; i < buf.size(); ++i) {
        u16 c = buf[i];

        // Handle surrogate pairs
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < buf.size()) {
            u16 c2 = buf[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                // Valid surrogate pair
                uint32_t codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                result.push_back(static_cast<char>(0xF0 | ((codepoint >> 18) & 0x07)));
                result.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
                ++i;
                continue;
            }
        }

        // Regular BMP character
        if (c < 0x80) {
            result.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            result.push_back(static_cast<char>(0xC0 | ((c >> 6) & 0x1F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | ((c >> 12) & 0x0F)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }

    return result;
}

} // namespace StringOps
} // namespace Elm
