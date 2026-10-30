#include "StringOps.hpp"
#include <vector>

namespace Elm {
namespace StringOps {

// ============================================================================
// Constructors of the forms, and flattening
// ============================================================================

HPointer makeLeafFromBuffer(const u16* data, u32 len) {
    if (len == 0) return alloc::emptyString();
    return alloc::allocString(data, len);
}

HPointer makeSlice(HPointer base, u32 offset, u32 len) {
    if (len == 0) return alloc::emptyString();

    size_t total_size = sizeof(ElmStringSlice);
    total_size = (total_size + 7) & ~7;

    // eco_alloc_with_roots keeps `base` alive through roots[] and updates it there if a
    // collection moves it.
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

    auto sizeOf = [&](HPointer hp) -> u32 {
        if (alloc::isEmptyString(hp)) return 0;
        if (alloc::isEmbeddedConstant(hp)) return 0;
        void* obj = Allocator::resolveFast(hp);
        return obj ? static_cast<Header*>(obj)->size : 0;
    };

    u32 leftLen = sizeOf(left);
    u32 rightLen = sizeOf(right);
    if (leftLen == 0 && rightLen == 0) return alloc::emptyString();
    if (leftLen == 0) return right;
    if (rightLen == 0) return left;

    // Read the children's heights and leaf counts before allocating, while the resolved pointers
    // are still valid.
    auto heightLeafOf = [&](HPointer hp) -> std::pair<u32, u32> {
        if (alloc::isEmbeddedConstant(hp)) return {0, 0};
        void* obj = Allocator::resolveFast(hp);
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

    // A slice or view as base is replaced by its own base, as alloc::makeByteBufferSlice does for
    // Bytes slices.
    void* base_obj = Allocator::resolveFast(base);
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

    if (!allocator.getConfig().utf8_strings_enabled) {
        std::vector<u16> wide(len);
        Utf8::widenAscii(bytes, len, wide.data());
        return alloc::allocString(wide.data(), len);
    }

    size_t total_size = (sizeof(ElmStringUtf8Leaf) + len + 7) & ~7;
    if (total_size >= allocator.getLargeObjectThreshold()) {
        // There is no large UTF-8 form, so this becomes a large UTF-16 String. `bytes` is copied
        // into `wide` before the allocation, so a collection cannot invalidate it.
        std::vector<u16> wide(len);
        Utf8::widenAscii(bytes, len, wide.data());
        return alloc::allocString(wide.data(), len);
    }

    // Bytes inside the heap range may move in the allocation below, so they are copied first: to
    // the stack when short, and otherwise to C++ memory. Bytes outside it are copied straight into
    // the leaf.
    const u8* src = bytes;
    u8 small[256];
    std::vector<u8> big;
    if (allocator.isInHeap(const_cast<u8*>(bytes))) {
        if (len <= sizeof(small)) {
            std::memcpy(small, bytes, len);
            src = small;
        } else {
            big.assign(bytes, bytes + len);
            src = big.data();
        }
    }
    void* obj = eco_alloc_with_roots(Tag_StringUtf8Leaf, total_size, nullptr, 0, 0);
    ElmStringUtf8Leaf* leaf = static_cast<ElmStringUtf8Leaf*>(obj);
    leaf->header.size = len;
    std::memcpy(leaf->bytes, src, len);
#if ECO_HEAP_VALIDATE
    for (u32 i = 0; i < len; ++i)
        assert(!(leaf->bytes[i] & 0x80) && "UTF-8 leaf must be all-ASCII");
#endif
    return allocator.wrap(leaf);
}

// Declared, with its contract, in HeapHelpers.hpp; defined here because it builds the UTF-8 forms
// with makeUtf8LeafFromBytes and makeUtf8View.
bool tryMakeAsciiString(const char* data, size_t len, HPointer* out) {
    auto& allocator = Allocator::instance();
    if (!allocator.getConfig().utf8_strings_enabled) return false;
    if (len == 0 || len > 0xFFFFFFFFull) return false;
    const u8* bytes = reinterpret_cast<const u8*>(data);
    if (!Utf8::allAscii(bytes, len)) return false;
    size_t leafSize = (sizeof(ElmStringUtf8Leaf) + len + 7) & ~static_cast<size_t>(7);
    if (leafSize < allocator.getLargeObjectThreshold()) {
        *out = makeUtf8LeafFromBytes(bytes, static_cast<u32>(len));
        return true;
    }
    // makeUtf8LeafFromBytes would widen a leaf this large to UTF-16, so the bytes go into large
    // Bytes instead, and the String is a view of all of them.
    HPointer buf = alloc::allocByteBuffer(bytes, len);
    *out = makeUtf8View(buf, 0, static_cast<u32>(len));
    return true;
}

AsciiOut allocAsciiOut(size_t len) {
    // A zero-length leaf would be a header-only 8-byte object (HEAP_071).
    assert(len > 0 && "allocAsciiOut: empty strings are the Empty constant");
    auto& allocator = Allocator::instance();
    size_t leafSize = (sizeof(ElmStringUtf8Leaf) + len + 7) & ~static_cast<size_t>(7);
    if (leafSize < allocator.getLargeObjectThreshold()) {
        ElmStringUtf8Leaf* leaf = static_cast<ElmStringUtf8Leaf*>(
            eco_alloc_with_roots(Tag_StringUtf8Leaf, leafSize, nullptr, 0, 0));
        leaf->header.size = static_cast<u32>(len);
        return AsciiOut{allocator.wrap(leaf), leaf->bytes, static_cast<u32>(len), true};
    }
    // At or above the threshold, allocByteBufferBlank makes large Bytes, whose body is pinned.
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(len);
    return AsciiOut{bb.hp, bb.bytes, static_cast<u32>(len), false};
}

HPointer finishAsciiOut(const AsciiOut& out) {
#if ECO_HEAP_VALIDATE
    for (u32 i = 0; i < out.len; ++i)
        assert(!(out.dst[i] & 0x80) && "AsciiOut result must be all-ASCII");
#endif
    if (out.isLeaf) return out.hp;
    // makeUtf8View keeps out.hp alive across its allocation and does not read the bytes.
    return makeUtf8View(out.hp, 0, out.len);
}

HPointer flattenToLeaf(HPointer s) {
    if (alloc::isEmbeddedConstant(s)) return s;

    auto& allocator = Allocator::instance();
    void* obj = Allocator::resolveFast(s);
    if (!obj) return alloc::emptyString();

    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_String) return s;
    // A large String is already flat; copying it would only make another large String.
    if (hdr->tag == Tag_LargeStringHeader) return s;
    if (hdr->size == 0) return alloc::emptyString();

    // Copy the units out before allocating, while `obj` is still valid.
    if (isUtf8(obj))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_ENSURE_FLAT, hdr->size);
    std::u16string buf = toStdU16String(obj);

    // Nothing on the Elm heap is read after the allocation, so `s` need not be rooted.
    return alloc::allocString(reinterpret_cast<const u16*>(buf.data()),
                              buf.size());
}

HPointer ensureFlat(HPointer s) {
    if (alloc::isEmbeddedConstant(s)) return s;
    void* obj = Allocator::resolveFast(s);
    if (!obj) return s;
    Header* hdr = static_cast<Header*>(obj);
    if (hdr->tag == Tag_String) return s;
    if (hdr->tag == Tag_LargeStringHeader) return s;
    if (hdr->tag == Tag_StringUtf8View || hdr->tag == Tag_StringUtf8Leaf) {
        // Widened whatever its length, so a result that is not a slice or rope is always a flat
        // UTF-16 form. The widening is counted in flattenToLeaf, so it is not counted here.
        return flattenToLeaf(s);
    }
    if (hdr->size <= Allocator::instance().getConfig().string_flatten_limit) {
        return flattenToLeaf(s);
    }
    // Too long to copy: the slice or rope is returned as it is.
    return s;
}

// ============================================================================
// Slicing
// ============================================================================

// Returns a new String holding the `n` UTF-16 units from unit `off` of `owner`, a UTF-16 leaf or a
// large String. `n` must be positive. The result is a UTF-8 leaf when the units are all ASCII, `n`
// is at most 512 (the stack buffer) and UTF-8 Strings are enabled, so that an ASCII run cut from a
// UTF-16 String does not make the operations it later enters widen; otherwise it is a UTF-16
// String. The UTF-8 path copies the units to the stack before it allocates. The UTF-16 path roots
// `owner` across its allocation and reads the units afterwards from `owner` re-resolved, so a
// collection there neither moves the source under the copy nor, for a large String, frees its
// body. A GC point.
static HPointer tinyFromFlat(HPointer owner, size_t off, size_t n) {
    auto& allocator = Allocator::instance();
    if (n <= 512 && allocator.getConfig().utf8_strings_enabled) {
        const u16* p = flatStringChars(Allocator::resolveFast(owner)) + off;
        u16 acc = 0;
        for (size_t i = 0; i < n; ++i) acc |= p[i];
        if (acc < 0x80) {
            u8 buf[512];
            for (size_t i = 0; i < n; ++i) buf[i] = static_cast<u8>(p[i]);
            return makeUtf8LeafFromBytes(buf, static_cast<u32>(n));
        }
    }
    alloc::BlankString out;
    {
        Elm::StackRootGuard guard(&owner);
        out = alloc::allocStringBlank(n);
    }
    std::memcpy(out.chars, flatStringChars(Allocator::resolveFast(owner)) + off, n * sizeof(u16));
    return out.hp;
}

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

    // A short range is copied: a slice object would cost about as much as the copy.
    if (slice_len <= allocator.getConfig().string_tiny_slice_limit) {
        if (hdr->tag == Tag_String || hdr->tag == Tag_LargeStringHeader)
            return tinyFromFlat(allocator.wrap(str), static_cast<size_t>(start), slice_len);
        if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            u32 baseOffset = slc->offset;
            void* baseObj = Allocator::resolveFast(slc->base);
            if (!baseObj) return alloc::emptyString();
            assert((static_cast<Header*>(baseObj)->tag == Tag_String ||
                    static_cast<Header*>(baseObj)->tag == Tag_LargeStringHeader) &&
                   "Tag_StringSlice base must be a Tag_String or a Tag_LargeStringHeader");
            assert(static_cast<u64>(baseOffset) + static_cast<u64>(start) +
                       static_cast<u64>(slice_len) <=
                   static_cast<u64>(static_cast<Header*>(baseObj)->size) &&
                   "slice range exceeds underlying leaf");
            return tinyFromFlat(slc->base, static_cast<size_t>(baseOffset) + static_cast<size_t>(start),
                                slice_len);
        }
        // A rope: skip `start` units of its segments and copy the next `slice_len`.
        HPointer srcHp = allocator.wrap(str);
        alloc::BlankString out;
        {
            Elm::StackRootGuard guard(&srcHp);
            out = alloc::allocStringBlank(slice_len);
        }
        i64 remaining_skip = start;
        u32 written = 0;
        forEachSegment(Allocator::resolveFast(srcHp), [&](const u16* p, u32 n) {
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

    if (hdr->tag == Tag_String) {
        HPointer baseHp = allocator.wrap(str);
        return makeSlice(baseHp, static_cast<u32>(start), static_cast<u32>(slice_len));
    }
    // The slice's base is the large String's header, never its body: a body is kept alive only
    // through its header, so a slice referring to the body would not stop it being freed.
    if (hdr->tag == Tag_LargeStringHeader) {
        HPointer headerHp = allocator.wrap(str);
        return makeSlice(headerHp, static_cast<u32>(start), static_cast<u32>(slice_len));
    }

    // A slice of a slice is a slice of the inner slice's base.
    if (hdr->tag == Tag_StringSlice) {
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
        HPointer baseHp = slc->base;
        u32 baseOffset = slc->offset + static_cast<u32>(start);
        return makeSlice(baseHp, baseOffset, static_cast<u32>(slice_len));
    }

    // A rope: recurse into the child that holds the range, or slice both and join them. The
    // recursion depth is at most the rope's height.
    HPointer self = allocator.wrap(str);
    Elm::StackRootGuard rootSelf(&self);
    void* topObj = Allocator::resolveFast(self);
    if (!topObj) return alloc::emptyString();
    ElmStringRope* topRope = static_cast<ElmStringRope*>(topObj);
    HPointer leftHp = topRope->left;
    HPointer rightHp = topRope->right;

    void* leftObj = Allocator::resolveFast(leftHp);
    u32 leftLen = leftObj ? static_cast<Header*>(leftObj)->size : 0;

    if (static_cast<u64>(end) <= leftLen) {
        return slice(leftObj, start, end);
    }
    if (static_cast<u64>(start) >= leftLen) {
        void* rightObj = Allocator::resolveFast(rightHp);
        return slice(rightObj, start - leftLen, end - leftLen);
    }

    // Spans both children: build a rope of (left[start..leftLen) ++ right[0..end-leftLen)).
    HPointer leftPiece = slice(leftObj, start, static_cast<i64>(leftLen));
    Elm::StackRootGuard rootLeft(&leftPiece);
    // Re-derive the right child from the rooted `self`: the recursive slice
    // above allocates whenever start > 0, and a GC there moves the child —
    // the pre-recursion `rightHp` snapshot would be stale.
    rightHp = static_cast<ElmStringRope*>(Allocator::resolveFast(self))->right;
    void* rightObj = Allocator::resolveFast(rightHp);
    HPointer rightPiece = slice(rightObj, 0, end - static_cast<i64>(leftLen));
    return makeRope(leftPiece, rightPiece);
}

// ============================================================================
// The remaining operations
// ============================================================================

// Returns the Strings in `parts` joined in order, as a tree of ropes: the Empty constant for none,
// and the one String itself for one.
//
// Each String is pushed onto a stack, and while the top entry is no longer than the one below it
// the two are joined into one rope. Joining like-sized neighbours keeps the tree balanced, where
// appending one at a time would make it as deep as `parts` is long. The caller must root `parts`,
// which is read after allocations; the stack is rooted here. A GC point.
static HPointer buildBalancedRope(std::vector<HPointer>& parts) {
    if (parts.empty()) return alloc::emptyString();
    if (parts.size() == 1) return parts[0];

    auto& allocator = Allocator::instance();
    auto rawSize = [&](HPointer hp) -> u32 {
        if (alloc::isEmbeddedConstant(hp)) return 0;
        void* obj = Allocator::resolveFast(hp);
        return obj ? static_cast<Header*>(obj)->size : 0;
    };

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

// Returns the UTF-16 leaf `leafHp` as a new UTF-8 form when its units are all ASCII and UTF-8
// Strings are enabled, and `leafHp` unchanged otherwise, including when it is not a UTF-16 leaf.
// This keeps an ASCII result built through UTF-16, because one element was a UTF-16 String, from
// making the operations it later enters widen. A GC point.
static HPointer healAsciiResult(HPointer leafHp) {
    auto& allocator = Allocator::instance();
    if (!allocator.getConfig().utf8_strings_enabled) return leafHp;
    if (alloc::isEmbeddedConstant(leafHp)) return leafHp;
    void* obj = Allocator::resolveFast(leafHp);
    if (!obj || static_cast<Header*>(obj)->tag != Tag_String) return leafHp;
    ElmString* s = static_cast<ElmString*>(obj);
    size_t n = s->header.size;
    u16 acc = 0;
    for (size_t i = 0; i < n; ++i) acc |= s->chars[i];
    if (acc >= 0x80 || n == 0) return leafHp;
    AsciiOut out;
    { Elm::StackRootGuard guard(&leafHp); out = allocAsciiOut(n); }
    ElmString* s2 = static_cast<ElmString*>(Allocator::resolveFast(leafHp));
    for (size_t i = 0; i < n; ++i) out.dst[i] = static_cast<u8>(s2->chars[i]);
    return finishAsciiOut(out);
}

HPointer concat(HPointer stringList) {
    auto& allocator = Allocator::instance();

    // First pass, without allocating: the total length, and whether every element is UTF-8.
    size_t total_len = 0;
    size_t count = 0;
    bool allUtf8 = true;
    for (alloc::ListCursor lc(stringList); !lc.done(); lc.next()) {
        if (!alloc::isEmptyString(lc.current().p)) {
            void* strObj = Allocator::resolveFast(lc.current().p);
            if (strObj) {
                total_len += static_cast<Header*>(strObj)->size;
                ++count;
                if (!isUtf8(strObj)) allUtf8 = false;
            }
        }
    }

    if (total_len == 0) return alloc::emptyString();

    // The list is walked again after the allocation, so it is rooted across it in both copy paths
    // below and re-read afterwards.
    if (total_len <= allocator.getConfig().string_flatten_limit) {
        if (allUtf8 && allocator.getConfig().utf8_strings_enabled) {
            HPointer listHp = stringList;
            AsciiOut out;
            { Elm::StackRootGuard g(&listHp); out = allocAsciiOut(total_len); }
            size_t off = 0;
            for (alloc::ListCursor lc(listHp); !lc.done(); lc.next()) {
                if (!alloc::isEmptyString(lc.current().p)) {
                    void* strObj = Allocator::resolveFast(lc.current().p);
                    if (strObj) {
                        auto pr = utf8Bytes(strObj);
                        std::memcpy(out.dst + off, pr.first, pr.second);
                        off += pr.second;
                    }
                }
            }
            return finishAsciiOut(out);
        }

        size_t data_size = total_len * sizeof(u16);
        size_t total_size = sizeof(ElmString) + data_size;
        total_size = (total_size + 7) & ~7;

        uint64_t roots[1];
        std::memcpy(&roots[0], &stringList, sizeof(stringList));
        ElmString* result = static_cast<ElmString*>(
            eco_alloc_with_roots(Tag_String, total_size, roots, 1, 0x1));
        std::memcpy(&stringList, &roots[0], sizeof(stringList));
        result->header.size = static_cast<u32>(total_len);

        size_t offset = 0;
        for (alloc::ListCursor lc(stringList); !lc.done(); lc.next()) {
            if (!alloc::isEmptyString(lc.current().p)) {
                void* strObj = Allocator::resolveFast(lc.current().p);
                if (strObj) {
                    forEachSegment(strObj, [&](const u16* p, u32 n) {
                        std::memcpy(result->chars + offset, p, n * sizeof(u16));
                        offset += n;
                    });
                }
            }
        }

        return healAsciiResult(allocator.wrap(result));
    }

    std::vector<HPointer> parts;
    parts.reserve(count);
    for (alloc::ListCursor lc(stringList); !lc.done(); lc.next()) {
        if (!alloc::isEmptyString(lc.current().p)) {
            void* strObj = Allocator::resolveFast(lc.current().p);
            if (strObj && static_cast<Header*>(strObj)->size > 0) {
                parts.push_back(lc.current().p);
            }
        }
    }

    // An all-ones mask marks every slot as an HPointer.
    Elm::StackRootRangeGuard partsGuard(parts.data(), parts.size(), ~0ULL);
    return buildBalancedRope(parts);
}

HPointer join(void* sep, HPointer stringList) {
    auto& allocator = Allocator::instance();
    size_t sep_len = sep ? static_cast<Header*>(sep)->size : 0;

    // Wrapped before anything allocates, while `sep` is still valid; each path below roots it.
    HPointer sepHp = sep ? allocator.wrap(sep) : alloc::emptyString();

    // First pass, without allocating: the element count, the total length of the elements, and
    // whether every element is UTF-8.
    size_t total_len = 0;
    size_t count = 0;
    bool allUtf8 = true;
    for (alloc::ListCursor lc(stringList); !lc.done(); lc.next()) {
        if (!alloc::isEmptyString(lc.current().p)) {
            void* strObj = Allocator::resolveFast(lc.current().p);
            if (strObj) {
                total_len += static_cast<Header*>(strObj)->size;
                if (!isUtf8(strObj)) allUtf8 = false;
            }
        }
        ++count;
    }

    if (count == 0) return alloc::emptyString();
    total_len += sep_len * (count - 1);
    // A non-empty list joins to "" when every element is empty and the separator is empty or
    // never written, as for one empty element. The result must then be the Empty constant, never a
    // zero-length object (HEAP_071; allocAsciiOut asserts it).
    if (total_len == 0) return alloc::emptyString();
    bool sepUtf8 = (sep_len == 0) || (sep && isUtf8(sep));

    if (total_len <= allocator.getConfig().string_flatten_limit) {
        if (allUtf8 && sepUtf8 && allocator.getConfig().utf8_strings_enabled) {
            HPointer listHp = stringList;
            AsciiOut out;
            { Elm::StackRootGuard g(&listHp, &sepHp); out = allocAsciiOut(total_len); }
            size_t off = 0;
            bool first = true;
            for (alloc::ListCursor lc(listHp); !lc.done(); lc.next()) {
                if (!first && sep_len > 0) {
                    auto ps = utf8Bytes(Allocator::resolveFast(sepHp));
                    std::memcpy(out.dst + off, ps.first, ps.second);
                    off += ps.second;
                }
                first = false;
                if (!alloc::isEmptyString(lc.current().p)) {
                    void* strObj = Allocator::resolveFast(lc.current().p);
                    if (strObj) {
                        auto pr = utf8Bytes(strObj);
                        std::memcpy(out.dst + off, pr.first, pr.second);
                        off += pr.second;
                    }
                }
            }
            return finishAsciiOut(out);
        }

        size_t data_size = total_len * sizeof(u16);
        size_t total_size = sizeof(ElmString) + data_size;
        total_size = (total_size + 7) & ~7;

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
        for (alloc::ListCursor lc(stringList); !lc.done(); lc.next()) {
            if (!first && sep_len > 0) {
                void* sepObj = Allocator::resolveFast(sepHp);
                forEachSegment(sepObj, [&](const u16* p, u32 n) {
                    std::memcpy(result->chars + offset, p, n * sizeof(u16));
                    offset += n;
                });
            }
            first = false;

            if (!alloc::isEmptyString(lc.current().p)) {
                void* strObj = Allocator::resolveFast(lc.current().p);
                if (strObj) {
                    forEachSegment(strObj, [&](const u16* p, u32 n) {
                        std::memcpy(result->chars + offset, p, n * sizeof(u16));
                        offset += n;
                    });
                }
            }
        }
        return healAsciiResult(allocator.wrap(result));
    }

    std::vector<HPointer> parts;
    parts.reserve(count * 2);
    bool first = true;
    for (alloc::ListCursor lc(stringList); !lc.done(); lc.next()) {
        if (!first && sep_len > 0) {
            parts.push_back(sepHp);
        }
        first = false;
        if (!alloc::isEmptyString(lc.current().p)) {
            void* strObj = Allocator::resolveFast(lc.current().p);
            if (strObj && static_cast<Header*>(strObj)->size > 0) {
                parts.push_back(lc.current().p);
            }
        }
    }

    Elm::StackRootRangeGuard partsGuard(parts.data(), parts.size(), ~0ULL);
    return buildBalancedRope(parts);
}

HPointer indexes(void* needle, void* haystack) {
    // An empty needle has no index, as elm/core's `_String_indexes` returns [] when the needle's length is
    // below 1. A null pointer is the empty string.
    if (!haystack || !needle) return alloc::listFromInts({});

    if (isUtf8(needle))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_INDEXES, static_cast<Header*>(needle)->size);
    if (isUtf8(haystack))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_INDEXES, static_cast<Header*>(haystack)->size);
    auto needleBuf = toStdU16String(needle);
    auto haystackBuf = toStdU16String(haystack);
    const u16* nPtr = reinterpret_cast<const u16*>(needleBuf.data());
    const u16* hPtr = reinterpret_cast<const u16*>(haystackBuf.data());
    size_t needle_len = needleBuf.size();
    size_t haystack_len = haystackBuf.size();

    std::vector<i64> indices;
    if (needle_len == 0) {
        // No index, as above.
    } else if (needle_len <= haystack_len) {
        // Boyer-Moore-Horspool for a needle of 4 or more units, and a direct scan otherwise. The skip
        // table is indexed by a unit's low byte, so units that share it share an entry.
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
                    ++i;  // By one, so that overlapping occurrences are found too.
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

    // Both UTF-8: search the bytes, and make each piece with slice(), so pieces stay UTF-8 and
    // long ones share the source. Mixed forms fall through to the UTF-16 copy below.
    if (isUtf8(str) && isUtf8(sep) &&
        Allocator::instance().getConfig().utf8_strings_enabled) {
        auto& allocator = Allocator::instance();
        // Phase 1: search over raw bytes. No Elm allocation here, so the
        // in-place payload pointers stay valid for the whole scan.
        auto sp = utf8Bytes(str);
        auto np = utf8Bytes(sep);
        const u8* strB = sp.first;
        const u8* sepB = np.first;
        std::vector<size_t> splitPositions;
        if (sep_len >= 4) {
            u32 skip[256];
            for (u32 i = 0; i < 256; ++i) skip[i] = static_cast<u32>(sep_len);
            for (size_t i = 0; i + 1 < sep_len; ++i)
                skip[sepB[i]] = static_cast<u32>(sep_len - 1 - i);
            size_t i = 0;
            while (i + sep_len <= str_len) {
                size_t j = sep_len;
                while (j > 0 && strB[i + j - 1] == sepB[j - 1]) --j;
                if (j == 0) { splitPositions.push_back(i); i += sep_len; }
                else { i += skip[strB[i + sep_len - 1]]; }
            }
        } else {
            for (size_t i = 0; i + sep_len <= str_len; ++i) {
                bool match = true;
                for (size_t j = 0; j < sep_len && match; ++j)
                    if (strB[i + j] != sepB[j]) match = false;
                if (match) { splitPositions.push_back(i); i += sep_len - 1; }
            }
        }
        // Phase 2: build parts via slice() (UTF-8 sub-forms). slice allocates,
        // so root the source + parts and re-resolve the source each iteration.
        size_t numParts = splitPositions.size() + 1;
        std::vector<HPointer> parts(numParts, alloc::listNil());
        HPointer srcHp = allocator.wrap(str);
        auto& rs = allocator.getRootSet();
        size_t saved = rs.stackRangePoint();
        // One record roots the whole buffer: an all-ones mask covers a range of any length, and
        // the slots not yet filled hold the Empty constant, which a collection skips.
        rs.pushStackRootRange(parts.data(), parts.size(), ~0ULL);
        rs.pushStackRootRange(&srcHp, 1, ~0ULL);
        size_t start = 0;
        for (size_t idx = 0; idx < splitPositions.size(); ++idx) {
            parts[idx] = slice(Allocator::resolveFast(srcHp),
                               static_cast<i64>(start),
                               static_cast<i64>(splitPositions[idx]));
            start = splitPositions[idx] + sep_len;
        }
        parts[splitPositions.size()] = slice(Allocator::resolveFast(srcHp),
                                             static_cast<i64>(start),
                                             static_cast<i64>(str_len));
        rs.restoreStackRangePoint(saved);
        return alloc::listFromPointers(parts);
    }

    // Copy both into C++ memory before anything allocates.
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_SPLIT_MIXED, str_len);
    if (isUtf8(sep))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_SPLIT_MIXED, sep_len);
    auto strU16 = toStdU16String(str);
    auto sepU16 = toStdU16String(sep);
    const u16* strData = reinterpret_cast<const u16*>(strU16.data());
    const u16* sepData = reinterpret_cast<const u16*>(sepU16.data());

    // Boyer-Moore-Horspool for a separator of 4 or more units, and a direct scan otherwise.
    std::vector<size_t> splitPositions;
    if (sep_len >= 4) {
        // Indexed by a unit's low byte, so units that share it share an entry.
        u32 skip[256];
        for (u32 i = 0; i < 256; ++i) skip[i] = static_cast<u32>(sep_len);
        for (size_t i = 0; i + 1 < sep_len; ++i) {
            skip[sepData[i] & 0xFF] = static_cast<u32>(sep_len - 1 - i);
        }
        size_t i = 0;
        while (i + sep_len <= str_len) {
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
        // `i + sep_len <= str_len`, not `i <= str_len - sep_len`: size_t
        // underflows when the separator is longer than the input.
        for (size_t i = 0; i + sep_len <= str_len; ++i) {
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
    // One record roots the whole buffer; unfilled slots hold the Empty constant.
    rs.pushStackRootRange(parts.data(), parts.size(), ~0ULL);

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
    if (isUtf8(str))
        GC_STATS_UTF8_WIDEN_SITE(UTF8_WIDEN_TO_LIST, static_cast<Header*>(str)->size);
    auto buf = toStdU16String(str);
    size_t len = buf.size();
    if (len == 0) return alloc::listNil();

    // Count the code points first so that the rooted buffer is sized once.
    const u16* chars = reinterpret_cast<const u16*>(buf.data());
    size_t count = 0;
    for (size_t i = 0; i < len; ++count) (void)nextCodePoint(chars, len, i);
    std::vector<HPointer> charPtrs(count, alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(charPtrs.data(), charPtrs.size(), ~0ULL);

    size_t k = 0;
    for (size_t i = 0; i < len; ++k) {
        charPtrs[k] = fromChar(nextCodePoint(chars, len, i));
    }

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(charPtrs);
}

HPointer uncons(void* str) {
    if (!str) return alloc::nothing();
    Header* hdr = static_cast<Header*>(str);
    if (hdr->size == 0) return alloc::nothing();

    // Read the first code point before anything allocates. A UTF-8 form is ASCII (HEAP_032), so
    // `used` is 1 there, which the UTF-8 branches below rely on.
    size_t used = 0;
    u32 firstChar = codePointAt(str, hdr->size, used);
    u32 restLen = hdr->size - static_cast<u32>(used);

    // Share rather than going through slice(), which would copy a short rest. Uncons applied to
    // each rest in turn then allocates in total in proportion to the length, not its square.
    HPointer rest;
    if (restLen == 0) {
        rest = alloc::emptyString();
    } else {
        auto& allocator = Allocator::instance();
        if (hdr->tag == Tag_String || hdr->tag == Tag_LargeStringHeader) {
            HPointer baseHp = allocator.wrap(str);
            rest = makeSlice(baseHp, static_cast<u32>(used), restLen);
        } else if (hdr->tag == Tag_StringSlice) {
            ElmStringSlice* slc = static_cast<ElmStringSlice*>(str);
            HPointer baseHp = slc->base;
            u32 newOffset = slc->offset + static_cast<u32>(used);
            rest = makeSlice(baseHp, newOffset, restLen);
        } else if (hdr->tag == Tag_StringUtf8Leaf) {
            HPointer baseHp = allocator.wrap(str);
            rest = makeUtf8View(baseHp, 1, restLen);
        } else if (hdr->tag == Tag_StringUtf8View) {
            ElmStringUtf8View* v = static_cast<ElmStringUtf8View*>(str);
            rest = makeUtf8View(v->base, v->offset + 1, restLen);
        } else {
            rest = slice(str, static_cast<i64>(used), static_cast<i64>(hdr->size));
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

    // A mapped Char may take a different number of units than its source, so the result is
    // built in C++ memory and allocated once at the end.
    auto buf = toStdU16String(str);
    const u16* p = reinterpret_cast<const u16*>(buf.data());
    size_t n = buf.size();
    std::vector<u16> result;
    result.reserve(n);
    for (size_t i = 0; i < n;) appendCodePoint(result, mapFunc(nextCodePoint(p, n, i)));
    return alloc::allocString(result.data(), result.size());
}

HPointer filter(CharPredicate pred, void* str) {
    if (!str) return alloc::emptyString();
    u32 len = rawLen(str);
    if (len == 0) return alloc::emptyString();

    auto& allocator = Allocator::instance();
    HPointer srcHp = allocator.wrap(str);

    // UTF-8: count what is kept, allocate once, then copy it. `pred` does not allocate, so the bytes
    // stay put during the count; they are fetched again after allocAsciiOut.
    if (isUtf8(str) && allocator.getConfig().utf8_strings_enabled) {
        auto pr = utf8Bytes(Allocator::resolveFast(srcHp));
        u32 kept = 0;
        for (u32 i = 0; i < pr.second; ++i)
            if (pred(static_cast<u32>(pr.first[i]))) ++kept;
        if (kept == 0) return alloc::emptyString();
        if (kept == len) return allocator.wrap(Allocator::resolveFast(srcHp));
        AsciiOut out;
        { Elm::StackRootGuard guard(&srcHp); out = allocAsciiOut(kept); }
        auto pr2 = utf8Bytes(Allocator::resolveFast(srcHp));
        u32 w = 0;
        for (u32 i = 0; i < pr2.second; ++i) {
            u8 c = pr2.first[i];
            if (pred(static_cast<u32>(c))) out.dst[w++] = c;
        }
        return finishAsciiOut(out);
    }

    // UTF-16: copied first, because a surrogate pair may straddle two segments of a rope.
    auto buf = toStdU16String(Allocator::resolveFast(srcHp));
    const u16* p = reinterpret_cast<const u16*>(buf.data());
    size_t n = buf.size();
    std::vector<u16> kept;
    kept.reserve(n);
    for (size_t i = 0; i < n;) {
        size_t start = i;
        u32 cp = nextCodePoint(p, n, i);
        if (pred(cp)) kept.insert(kept.end(), p + start, p + i);
    }

    if (kept.empty()) return alloc::emptyString();
    if (kept.size() == len && isLeaf(Allocator::resolveFast(srcHp))) {
        return allocator.wrap(Allocator::resolveFast(srcHp));
    }
    return alloc::allocString(kept.data(), kept.size());
}

Unboxable foldl(CharFolder fold, Unboxable acc, void* str) {
    if (!str) return acc;
    Unboxable result = acc;
    // `fold` may allocate, so the bytes are copied into C++ memory first, as the units are on the
    // UTF-16 path.
    if (isUtf8(str)) {
        auto pr = utf8Bytes(str);
        std::string snap(reinterpret_cast<const char*>(pr.first), pr.second);
        for (unsigned char c : snap) result = fold(static_cast<u32>(c), result);
        return result;
    }
    auto buf = toStdU16String(str);
    const u16* p = reinterpret_cast<const u16*>(buf.data());
    size_t n = buf.size();
    for (size_t i = 0; i < n;) {
        result = fold(nextCodePoint(p, n, i), result);
    }
    return result;
}

Unboxable foldr(CharFolder fold, Unboxable acc, void* str) {
    if (!str) return acc;
    Unboxable result = acc;
    if (isUtf8(str)) {
        auto pr = utf8Bytes(str);
        std::string snap(reinterpret_cast<const char*>(pr.first), pr.second);
        for (size_t i = snap.size(); i > 0; --i)
            result = fold(static_cast<u32>(static_cast<unsigned char>(snap[i - 1])), result);
        return result;
    }
    auto buf = toStdU16String(str);
    const u16* p = reinterpret_cast<const u16*>(buf.data());
    for (size_t i = buf.size(); i > 0;) {
        result = fold(prevCodePoint(p, i), result);
    }
    return result;
}

std::string toStdString(void* str) {
    if (!str) return {};
    // ASCII bytes are already UTF-8.
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

    // First pass: the exact UTF-8 length, so that the result is allocated once at its size.
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


// ============================================================================
// The out-of-line halves of equal and compare
// ============================================================================

bool equalSlow(void* a, void* b) {
    Header* ha = static_cast<Header*>(a);
    // Each side one contiguous run of UTF-16 units. singleSegmentView gives null for a UTF-8 form
    // or rope, which then takes the segment walk below.
    auto [aPtr, aLen] = singleSegmentView(a);
    auto [bPtr, bLen] = singleSegmentView(b);
    if (aPtr && bPtr) {
        return std::memcmp(aPtr, bPtr, ha->size * sizeof(u16)) == 0;
    }

    // Walk both Strings' segments side by side, unit by unit. Nothing here allocates on the Elm
    // heap, so the segment pointers stay valid.
    std::vector<SegView> aSegs, bSegs;
    aSegs.reserve(16); bSegs.reserve(16);
    collectSegs(a, aSegs);
    collectSegs(b, bSegs);

    size_t ai = 0, bi = 0;
    u32 aOff = 0, bOff = 0;
    while (ai < aSegs.size() && bi < bSegs.size()) {
        if (segElemAt(aSegs[ai], aOff) != segElemAt(bSegs[bi], bOff)) return false;
        if (++aOff == aSegs[ai].len) { ++ai; aOff = 0; }
        if (++bOff == bSegs[bi].len) { ++bi; bOff = 0; }
    }
    return ai == aSegs.size() && bi == bSegs.size();
}

int compareSlow(void* a, void* b) {
    Header* ha = static_cast<Header*>(a);
    Header* hb = static_cast<Header*>(b);
    auto charCompare = [](const u16* pa, const u16* pb, size_t n) -> int {
        for (size_t i = 0; i < n; ++i) {
            if (pa[i] != pb[i]) {
                return static_cast<int>(pa[i]) - static_cast<int>(pb[i]);
            }
        }
        return 0;
    };

    auto [aPtr, aLen] = singleSegmentView(a);
    auto [bPtr, bLen] = singleSegmentView(b);
    if (aPtr && bPtr) {
        size_t min_len = std::min<size_t>(aLen, bLen);
        int c = charCompare(aPtr, bPtr, min_len);
        if (c != 0) return c;
        return static_cast<int>(aLen) - static_cast<int>(bLen);
    }

    // As in equalSlow. A byte compares as the unit it stands for.
    std::vector<SegView> aSegs, bSegs;
    aSegs.reserve(16); bSegs.reserve(16);
    collectSegs(a, aSegs);
    collectSegs(b, bSegs);

    size_t ai = 0, bi = 0;
    u32 aOff = 0, bOff = 0;
    while (ai < aSegs.size() && bi < bSegs.size()) {
        u16 ca = segElemAt(aSegs[ai], aOff);
        u16 cb = segElemAt(bSegs[bi], bOff);
        if (ca != cb) return static_cast<int>(ca) - static_cast<int>(cb);
        if (++aOff == aSegs[ai].len) { ++ai; aOff = 0; }
        if (++bOff == bSegs[bi].len) { ++bi; bOff = 0; }
    }
    return static_cast<int>(ha->size) - static_cast<int>(hb->size);
}

} // namespace StringOps
} // namespace Elm
