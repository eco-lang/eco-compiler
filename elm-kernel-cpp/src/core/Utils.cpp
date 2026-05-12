/**
 * Elm Kernel Utils Module - Runtime Heap Integration
 *
 * This module provides core comparison, equality, and utility functions
 * that work with the GC-managed heap values.
 */

#include "Utils.hpp"
#include "ExportHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include "allocator/ListOps.hpp"

#include <vector>

namespace Elm::Kernel::Utils {

// Order type: type_id 0 is reserved for built-in Order type
constexpr u16 ORDER_TYPE_ID = 0;
constexpr u16 ORDER_LT = 0;
constexpr u16 ORDER_EQ = 1;
constexpr u16 ORDER_GT = 2;

// Pre-allocated Order singletons. Slots hold encoded HPointer Elm values,
// registered with eco_gc_add_value_root so the GC keeps them live and updates
// the encoded HPointer in place if the underlying Custom moves.
static uint64_t ORDER_LT_SINGLETON = 0;
static uint64_t ORDER_EQ_SINGLETON = 0;
static uint64_t ORDER_GT_SINGLETON = 0;
static bool ORDER_SINGLETONS_INITIALIZED = false;

void initOrderSingletons() {
    if (ORDER_SINGLETONS_INITIALIZED) return;
    HPointer lt = alloc::custom(ORDER_LT, {}, 0);
    ORDER_LT_SINGLETON = Export::encode(lt);
    HPointer eq = alloc::custom(ORDER_EQ, {}, 0);
    ORDER_EQ_SINGLETON = Export::encode(eq);
    HPointer gt = alloc::custom(ORDER_GT, {}, 0);
    ORDER_GT_SINGLETON = Export::encode(gt);
    eco_gc_add_value_root(&ORDER_LT_SINGLETON);
    eco_gc_add_value_root(&ORDER_EQ_SINGLETON);
    eco_gc_add_value_root(&ORDER_GT_SINGLETON);
    ORDER_SINGLETONS_INITIALIZED = true;
}

uint64_t getOrderLT() { return ORDER_LT_SINGLETON; }
uint64_t getOrderEQ() { return ORDER_EQ_SINGLETON; }
uint64_t getOrderGT() { return ORDER_GT_SINGLETON; }

// Reserved ctor tags for runtime-recognised types. Must match
// `Compiler.Data.CtorTag` in the compiler.
//
// `Dict.RBNode_elm_builtin` and `Dict.RBEmpty_elm_builtin` are tagged so the
// runtime can compare two Dicts by content (in-order key/value traversal)
// instead of by the tree shape that happens to be produced by Elm's LLRB
// `insertHelp`. Stock Elm JS achieves the same thing via a negative `$` tag.
constexpr u16 CTOR_DICT_RBNODE = 0xFFFF;
constexpr u16 CTOR_DICT_RBEMPTY = 0xFFFE;

static bool isDictCtor(u16 ctor) {
    return ctor == CTOR_DICT_RBNODE || ctor == CTOR_DICT_RBEMPTY;
}

// ============================================================================
// Helper Functions
// ============================================================================

static Tag getTag(void* obj) {
    if (!obj) return Tag_Forward;  // Invalid
    Header* hdr = static_cast<Header*>(obj);
    return static_cast<Tag>(hdr->tag);
}

// Safely resolve an HPointer field value.
// Returns nullptr for embedded constants (caller must handle constant comparison).
static void* safeResolve(Allocator& allocator, HPointer p) {
    if (alloc::isConstant(p)) return nullptr;
    return allocator.resolve(p);
}

// Compare two HPointer field values that may be embedded constants.
// Both must be boxed (non-unboxed) fields. Returns:
//   1 if both resolved successfully (caller should call eqHelp/cmp on aOut, bOut)
//   0 if comparison is determined (result stored in *result)
static int resolveAndCompare(Allocator& allocator, HPointer ap, HPointer bp,
                              void** aOut, void** bOut, bool* eqResult) {
    bool aConst = alloc::isConstant(ap);
    bool bConst = alloc::isConstant(bp);

    if (aConst || bConst) {
        // At least one is an embedded constant - compare raw i64 values
        union { HPointer hp; uint64_t val; } ua, ub;
        ua.hp = ap;
        ub.hp = bp;
        *eqResult = (ua.val == ub.val);
        return 0;  // Comparison determined
    }

    *aOut = allocator.resolve(ap);
    *bOut = allocator.resolve(bp);
    return 1;  // Need recursive comparison
}

// Forward decls
static bool eqHelp(void* a, void* b, int depth);
static bool dictEq(void* a, void* b, int depth);

// Compare two Unboxable slots structurally for equality.
// Returns true iff the slots are equal. Mixed kinds compare as unequal.
static bool eqUnboxableSlot(Allocator& allocator,
                             Elm::Unboxable a, Elm::Unboxable b,
                             uint32_t aKind, uint32_t bKind, int depth) {
    if (aKind == bKind) {
        switch (aKind) {
            case 1: return a.i == b.i;
            case 2: return a.f == b.f;
            case 3: return a.c == b.c;
            default: {
                void* ao; void* bo; bool eq;
                if (resolveAndCompare(allocator, a.p, b.p, &ao, &bo, &eq) == 0) return eq;
                return eqHelp(ao, bo, depth + 1);
            }
        }
    }

    // Mixed kinds: one slot stores a primitive unboxed (kind 1/2/3) while the
    // other stores a boxed HPointer (kind 0) to the matching primitive heap
    // type. This happens legitimately when the two containers were built via
    // different paths — e.g. a List.range boxed-Int Cons list vs an
    // Array.fromList literal, or a JSON-decoded Int array vs one built via
    // Array.fromList over a boxed list. Fall through to the Tag_Cons-style
    // primitive cross-check.
    if (aKind == 0 || bKind == 0) {
        HPointer boxedHP = (aKind == 0) ? a.p : b.p;
        Elm::Unboxable prim = (aKind == 0) ? b : a;
        uint32_t primKind = (aKind == 0) ? bKind : aKind;
        void* boxedPtr = safeResolve(allocator, boxedHP);
        if (!boxedPtr) return false;
        Header* hdr = static_cast<Header*>(boxedPtr);
        if (hdr->tag == Tag_Int && primKind == 1) {
            return static_cast<ElmInt*>(boxedPtr)->value == prim.i;
        }
        if (hdr->tag == Tag_Float && primKind == 2) {
            return static_cast<ElmFloat*>(boxedPtr)->value == prim.f;
        }
        if (hdr->tag == Tag_Char && primKind == 3) {
            return static_cast<ElmChar*>(boxedPtr)->value == prim.c;
        }
    }

    return false;
}

// Compare two Unboxable slots whose kinds agree (0=boxed, 1=Int, 2=Float, 3=Char).
// Returns -1, 0, or 1.
static int compareUnboxableSlot(Allocator& allocator,
                                 Elm::Unboxable a, Elm::Unboxable b, uint32_t kind,
                                 int (*cmpFn)(void*, void*)) {
    switch (kind) {
        case 1:
            if (a.i == b.i) return 0;
            return a.i < b.i ? -1 : 1;
        case 2:
            if (a.f == b.f) return 0;
            return a.f < b.f ? -1 : 1;
        case 3:
            if (a.c == b.c) return 0;
            return a.c < b.c ? -1 : 1;
        default: {
            // Both slots are boxed HPointers - recurse.
            void* ao; void* bo; bool eq;
            if (resolveAndCompare(allocator, a.p, b.p, &ao, &bo, &eq) == 0) {
                if (eq) return 0;
                bool aConst = alloc::isConstant(a.p);
                bool bConst = alloc::isConstant(b.p);

                // Canonicalise Const_EmptyString against a heap-resident
                // String of size 0 (any of the four forms recognised by
                // alloc::isString: leaf / slice / rope / large header).
                // header.size is the logical UTF-16 length on all of them.
                constexpr unsigned EmptyStringTag = Const_EmptyString + 1;
                if (aConst && a.p.constant == EmptyStringTag && !bConst) {
                    void* bo2 = allocator.resolve(b.p);
                    if (bo2 && alloc::isString(bo2)) {
                        return static_cast<Header*>(bo2)->size == 0 ? 0 : -1;
                    }
                }
                if (bConst && b.p.constant == EmptyStringTag && !aConst) {
                    void* ao2 = allocator.resolve(a.p);
                    if (ao2 && alloc::isString(ao2)) {
                        return static_cast<Header*>(ao2)->size == 0 ? 0 : 1;
                    }
                }

                // Elm's two comparable embedded constants — Const_EmptyString
                // ("") and Const_Nil ([]) — represent the minimum value of
                // their type. Per Elm semantics, "" < any non-empty String
                // and [] < any non-empty List, so a const-vs-heap comparison
                // is LT (constant side) or GT (heap side). The EmptyString
                // canonicalisation above handles the edge case where the
                // heap value is itself an empty string.
                if (aConst && !bConst) return -1;
                if (!aConst && bConst) return 1;

                // Both sides are constants AND resolveAndCompare reported
                // eq=false (different constant families). Unreachable in
                // well-typed Elm — any comparable-typed value pair shares
                // one constant family, and no other comparable embedded
                // constants are planned (REP_COMPARE_CONST_001).
                assert(false &&
                       "compareUnboxableSlot: cross-family constant comparison "
                       "is unreachable in well-typed Elm");
                __builtin_unreachable();
            }
            return cmpFn(ao, bo);
        }
    }
}

// Low-level comparison returning -1 (LT), 0 (EQ), or 1 (GT)
static int cmp(void* a, void* b) {
    // Null checks
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;

    Tag tagA = getTag(a);
    Tag tagB = getTag(b);

    // Strings can appear in multiple representations (Tag_String / Tag_StringSlice).
    // Two equal-content strings must compare equal regardless of form, so route
    // any string-vs-string comparison through StringOps::compare before the
    // generic tag-difference fallback.
    if (alloc::isString(a) && alloc::isString(b)) {
        return StringOps::compare(a, b);
    }

    // Different types - compare by tag
    if (tagA != tagB) {
        return static_cast<int>(tagA) - static_cast<int>(tagB);
    }

    auto& allocator = Allocator::instance();

    switch (tagA) {
        case Tag_Int: {
            ElmInt* ai = static_cast<ElmInt*>(a);
            ElmInt* bi = static_cast<ElmInt*>(b);
            if (ai->value < bi->value) return -1;
            if (ai->value > bi->value) return 1;
            return 0;
        }

        case Tag_Float: {
            ElmFloat* af = static_cast<ElmFloat*>(a);
            ElmFloat* bf = static_cast<ElmFloat*>(b);
            if (af->value < bf->value) return -1;
            if (af->value > bf->value) return 1;
            return 0;
        }

        case Tag_Char: {
            ElmChar* ac = static_cast<ElmChar*>(a);
            ElmChar* bc = static_cast<ElmChar*>(b);
            if (ac->value < bc->value) return -1;
            if (ac->value > bc->value) return 1;
            return 0;
        }

        case Tag_String: {
            return StringOps::compare(a, b);
        }

        case Tag_Tuple2: {
            Elm::Tuple2* atup = static_cast<Elm::Tuple2*>(a);
            Elm::Tuple2* btup = static_cast<Elm::Tuple2*>(b);
            Header* ahdr = getHeader(a);
            Header* bhdr = getHeader(b);

            // Field a (slot 0)
            {
                uint32_t aKind = Elm::tupleFieldKind(ahdr->unboxed, 0);
                uint32_t bKind = Elm::tupleFieldKind(bhdr->unboxed, 0);
                if (aKind != bKind) return aKind < bKind ? -1 : 1;
                int ord = compareUnboxableSlot(allocator, atup->a, btup->a, aKind, cmp);
                if (ord != 0) return ord;
            }
            // Field b (slot 1)
            {
                uint32_t aKind = Elm::tupleFieldKind(ahdr->unboxed, 1);
                uint32_t bKind = Elm::tupleFieldKind(bhdr->unboxed, 1);
                if (aKind != bKind) return aKind < bKind ? -1 : 1;
                return compareUnboxableSlot(allocator, atup->b, btup->b, aKind, cmp);
            }
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);
            Header* ahdr = getHeader(a);
            Header* bhdr = getHeader(b);

            for (unsigned i = 0; i < 3; ++i) {
                uint32_t aKind = Elm::tupleFieldKind(ahdr->unboxed, i);
                uint32_t bKind = Elm::tupleFieldKind(bhdr->unboxed, i);
                if (aKind != bKind) return aKind < bKind ? -1 : 1;
                Elm::Unboxable aSlot = (i == 0) ? atup->a : (i == 1) ? atup->b : atup->c;
                Elm::Unboxable bSlot = (i == 0) ? btup->a : (i == 1) ? btup->b : btup->c;
                int ord = compareUnboxableSlot(allocator, aSlot, bSlot, aKind, cmp);
                if (ord != 0 || i == 2) return ord;
            }
            return 0;
        }

        case Tag_Cons: {
            // Compare lists element by element
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);

                uint32_t aKind = Elm::tupleFieldKind(ahdr->unboxed, 0);
                uint32_t bKind = Elm::tupleFieldKind(bhdr->unboxed, 0);

                if (aKind == bKind) {
                    int ord = compareUnboxableSlot(allocator, ax->head, bx->head, aKind, cmp);
                    if (ord != 0) return ord;
                } else {
                    // Mixed kinds — attempt mixed Int+boxed-Int comparison for backward
                    // compatibility with mono-type lists; otherwise arbitrary total order
                    // by kind.
                    if (aKind == 0 || bKind == 0) {
                        // One side boxed, the other primitive: resolve boxed and compare
                        // if both are the same primitive type.
                        HPointer boxedHP = (aKind == 0) ? ax->head.p : bx->head.p;
                        Elm::Unboxable prim = (aKind == 0) ? bx->head : ax->head;
                        uint32_t primKind = (aKind == 0) ? bKind : aKind;
                        void* boxedPtr = safeResolve(allocator, boxedHP);
                        if (!boxedPtr) return (aKind == 0) ? 1 : -1;
                        Header* hdr = static_cast<Header*>(boxedPtr);
                        if ((hdr->tag == Tag_Int && primKind == 1)
                         || (hdr->tag == Tag_Float && primKind == 2)
                         || (hdr->tag == Tag_Char && primKind == 3)) {
                            // Compare boxed primitive vs unboxed primitive.
                            int ord = 0;
                            if (primKind == 1) {
                                i64 bv = static_cast<ElmInt*>(boxedPtr)->value;
                                i64 uv = prim.i;
                                if (aKind == 0) { ord = (bv == uv) ? 0 : (bv < uv ? -1 : 1); }
                                else             { ord = (uv == bv) ? 0 : (uv < bv ? -1 : 1); }
                            } else if (primKind == 2) {
                                f64 bv = static_cast<ElmFloat*>(boxedPtr)->value;
                                f64 uv = prim.f;
                                if (aKind == 0) { ord = (bv == uv) ? 0 : (bv < uv ? -1 : 1); }
                                else             { ord = (uv == bv) ? 0 : (uv < bv ? -1 : 1); }
                            } else {
                                u16 bv = static_cast<ElmChar*>(boxedPtr)->value;
                                u16 uv = prim.c;
                                if (aKind == 0) { ord = (bv == uv) ? 0 : (bv < uv ? -1 : 1); }
                                else             { ord = (uv == bv) ? 0 : (uv < bv ? -1 : 1); }
                            }
                            if (ord != 0) return ord;
                        } else {
                            return aKind < bKind ? -1 : 1;
                        }
                    } else {
                        return aKind < bKind ? -1 : 1;
                    }
                }

                // Move to tails
                if (alloc::isNil(ax->tail)) ax = nullptr;
                else ax = static_cast<Cons*>(safeResolve(allocator, ax->tail));

                if (alloc::isNil(bx->tail)) bx = nullptr;
                else bx = static_cast<Cons*>(safeResolve(allocator, bx->tail));
            }

            // Shorter list is less
            if (ax != nullptr) return 1;   // a is longer
            if (bx != nullptr) return -1;  // b is longer
            return 0;
        }

        default:
            return 0;  // Other types compare as equal
    }
}

// ============================================================================
// Comparison Operations
// ============================================================================

HPointer compare(void* a, void* b) {
    int n = cmp(a, b);
    uint64_t enc = (n < 0) ? ORDER_LT_SINGLETON
                : (n > 0) ? ORDER_GT_SINGLETON
                          : ORDER_EQ_SINGLETON;
    return Export::decode(enc);
}

// ============================================================================
// Equality Operations
// ============================================================================

bool equal(void* a, void* b) {
    return eqHelp(a, b, 0);
}

static bool eqHelp(void* a, void* b, int depth) {
    // Reference equality
    if (a == b) return true;

    // Null checks
    if (!a || !b) return false;

    Tag tagA = getTag(a);
    Tag tagB = getTag(b);

    // Strings may appear in multiple representations; route any
    // string-vs-string equality through StringOps::equal so a leaf and an
    // equivalent slice compare equal.
    if (alloc::isString(a) && alloc::isString(b)) {
        return StringOps::equal(a, b);
    }

    // ByteBuffers may appear as flat Tag_ByteBuffer or as a Tag_LargeByteHeader
    // pointing at a pinned old-gen body; resolve both sides to their bodies and
    // compare as raw bytes.
    if (alloc::isByteBuffer(a) && alloc::isByteBuffer(b)) {
        ByteBuffer* ab = alloc::resolveByteBufferBody(a);
        ByteBuffer* bb = alloc::resolveByteBufferBody(b);
        if (!ab || !bb) return ab == bb;
        if (ab->header.size != bb->header.size) return false;
        return std::memcmp(ab->bytes, bb->bytes, ab->header.size) == 0;
    }

    // Type mismatch
    if (tagA != tagB) {
        // TRACE: log tag mismatches to stderr for debugging.
        static int traceCount = 0;
        if (traceCount < 10) {
            fprintf(stderr, "[eq] tag mismatch: %d vs %d\n", (int)tagA, (int)tagB);
            traceCount++;
        }
        return false;
    }

    // Depth limit check (prevent stack overflow on deep structures)
    if (depth > 100) {
        return true;  // Assume equal at depth limit
    }

    auto& allocator = Allocator::instance();

    switch (tagA) {
        case Tag_Int: {
            ElmInt* ai = static_cast<ElmInt*>(a);
            ElmInt* bi = static_cast<ElmInt*>(b);
            return ai->value == bi->value;
        }

        case Tag_Float: {
            ElmFloat* af = static_cast<ElmFloat*>(a);
            ElmFloat* bf = static_cast<ElmFloat*>(b);
            return af->value == bf->value;
        }

        case Tag_Char: {
            ElmChar* ac = static_cast<ElmChar*>(a);
            ElmChar* bc = static_cast<ElmChar*>(b);
            return ac->value == bc->value;
        }

        case Tag_String: {
            return StringOps::equal(a, b);
        }

        case Tag_Tuple2: {
            Elm::Tuple2* atup = static_cast<Elm::Tuple2*>(a);
            Elm::Tuple2* btup = static_cast<Elm::Tuple2*>(b);
            Header* ahdr = getHeader(a);
            Header* bhdr = getHeader(b);
            if (!eqUnboxableSlot(allocator, atup->a, btup->a,
                                  Elm::tupleFieldKind(ahdr->unboxed, 0),
                                  Elm::tupleFieldKind(bhdr->unboxed, 0), depth)) return false;
            return eqUnboxableSlot(allocator, atup->b, btup->b,
                                    Elm::tupleFieldKind(ahdr->unboxed, 1),
                                    Elm::tupleFieldKind(bhdr->unboxed, 1), depth);
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);
            Header* ahdr = getHeader(a);
            Header* bhdr = getHeader(b);
            if (!eqUnboxableSlot(allocator, atup->a, btup->a,
                                  Elm::tupleFieldKind(ahdr->unboxed, 0),
                                  Elm::tupleFieldKind(bhdr->unboxed, 0), depth)) return false;
            if (!eqUnboxableSlot(allocator, atup->b, btup->b,
                                  Elm::tupleFieldKind(ahdr->unboxed, 1),
                                  Elm::tupleFieldKind(bhdr->unboxed, 1), depth)) return false;
            return eqUnboxableSlot(allocator, atup->c, btup->c,
                                    Elm::tupleFieldKind(ahdr->unboxed, 2),
                                    Elm::tupleFieldKind(bhdr->unboxed, 2), depth);
        }

        case Tag_Cons: {
            // Compare lists element by element
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);
                uint32_t aKind = Elm::tupleFieldKind(ahdr->unboxed, 0);
                uint32_t bKind = Elm::tupleFieldKind(bhdr->unboxed, 0);

                if (aKind == bKind) {
                    if (!eqUnboxableSlot(allocator, ax->head, bx->head, aKind, bKind, depth)) return false;
                } else if (aKind == 0 || bKind == 0) {
                    // One boxed, one unboxed primitive. Resolve boxed side to check if
                    // it matches the primitive value.
                    HPointer boxedHP = (aKind == 0) ? ax->head.p : bx->head.p;
                    Elm::Unboxable prim = (aKind == 0) ? bx->head : ax->head;
                    uint32_t primKind = (aKind == 0) ? bKind : aKind;
                    void* boxedPtr = safeResolve(allocator, boxedHP);
                    if (!boxedPtr) return false;
                    Header* hdr = static_cast<Header*>(boxedPtr);
                    if (hdr->tag == Tag_Int && primKind == 1) {
                        if (static_cast<ElmInt*>(boxedPtr)->value != prim.i) return false;
                    } else if (hdr->tag == Tag_Float && primKind == 2) {
                        if (static_cast<ElmFloat*>(boxedPtr)->value != prim.f) return false;
                    } else if (hdr->tag == Tag_Char && primKind == 3) {
                        if (static_cast<ElmChar*>(boxedPtr)->value != prim.c) return false;
                    } else {
                        return false;
                    }
                } else {
                    return false;
                }

                // Move to tails
                if (alloc::isNil(ax->tail)) ax = nullptr;
                else ax = static_cast<Cons*>(safeResolve(allocator, ax->tail));

                if (alloc::isNil(bx->tail)) bx = nullptr;
                else bx = static_cast<Cons*>(safeResolve(allocator, bx->tail));
            }

            return ax == nullptr && bx == nullptr;
        }

        case Tag_Custom: {
            Custom* ac = static_cast<Custom*>(a);
            Custom* bc = static_cast<Custom*>(b);

            // Dict equality: compare by content so that two dicts with the
            // same key/value pairs but different insertion-order tree shapes
            // compare equal. (See notes on CTOR_DICT_RBNODE/CTOR_DICT_RBEMPTY.)
            if (isDictCtor(ac->ctor) || isDictCtor(bc->ctor)) {
                return dictEq(a, b, depth);
            }

            if (ac->ctor != bc->ctor) return false;

            u32 fieldCount = ac->header.size;
            if (fieldCount != bc->header.size) return false;

            for (u32 i = 0; i < fieldCount; ++i) {
                uint32_t aKind = static_cast<uint32_t>(Elm::fieldKind(ac->unboxed, i));
                uint32_t bKind = static_cast<uint32_t>(Elm::fieldKind(bc->unboxed, i));
                if (!eqUnboxableSlot(allocator, ac->values[i], bc->values[i], aKind, bKind, depth)) return false;
            }

            return true;
        }

        case Tag_Record: {
            Record* ar = static_cast<Record*>(a);
            Record* br = static_cast<Record*>(b);

            u32 fieldCount = ar->header.size;
            if (fieldCount != br->header.size) return false;

            for (u32 i = 0; i < fieldCount; ++i) {
                uint32_t aKind = static_cast<uint32_t>(Elm::fieldKind(ar->unboxed, i));
                uint32_t bKind = static_cast<uint32_t>(Elm::fieldKind(br->unboxed, i));
                if (!eqUnboxableSlot(allocator, ar->values[i], br->values[i], aKind, bKind, depth)) return false;
            }

            return true;
        }

        case Tag_Array: {
            ElmArray* aa = static_cast<ElmArray*>(a);
            ElmArray* ba = static_cast<ElmArray*>(b);

            if (aa->length != ba->length) return false;

            uint32_t aKind = aa->header.unboxed & 0x3;
            uint32_t bKind = ba->header.unboxed & 0x3;

            // Two arrays representing the same element sequence may disagree on
            // the uniform "unboxed kind" stored in the header — e.g. one built
            // via Array.fromList over a boxed-Int Cons list (kind 0) vs one
            // decoded from JSON with an Int decoder (kind 1). Delegate to
            // eqUnboxableSlot per-element, which handles mixed boxed/unboxed
            // primitive comparisons (same logic the Tag_Cons path uses).
            for (u32 i = 0; i < aa->length; ++i) {
                if (!eqUnboxableSlot(allocator, aa->elements[i], ba->elements[i], aKind, bKind, depth)) return false;
            }

            return true;
        }

        case Tag_ByteBuffer: {
            // The early ByteBuffer fast-path above already handles split forms;
            // this case is only reached when both sides have tag Tag_ByteBuffer.
            ByteBuffer* ab = alloc::resolveByteBufferBody(a);
            ByteBuffer* bb = alloc::resolveByteBufferBody(b);

            if (ab->header.size != bb->header.size) return false;
            return std::memcmp(ab->bytes, bb->bytes, ab->header.size) == 0;
        }

        case Tag_Closure:
            // Functions cannot be compared in Elm
            return false;

        default:
            return false;
    }
}

// Compare two Dicts by content: equal iff they contain the same key/value
// pairs under the same comparable ordering. Uses iterative in-order traversal
// over both trees in lockstep, so we never materialise intermediate lists.
//
// Dict's constructor layout is
//   RBNode_elm_builtin NColor k v left right
// with values[0]=color, values[1]=k, values[2]=v, values[3]=left, values[4]=right.
// RBEmpty_elm_builtin has no fields.
//
// Color is deliberately ignored: for two LLRB trees representing the same
// key/value set, the colour on individual nodes depends on insertion order.
static bool dictEq(void* a, void* b, int depth) {
    auto& allocator = Allocator::instance();

    // Resolve a subtree HPointer to its Custom header. Returns nullptr if the
    // HPointer is an embedded constant or the resolved tag isn't Custom (the
    // latter would indicate malformed input, not a normal empty subtree —
    // RBEmpty is a heap-allocated Custom with ctor == CTOR_DICT_RBEMPTY).
    auto resolveCustom = [&allocator](HPointer hp) -> Custom* {
        if (alloc::isConstant(hp)) return nullptr;
        void* obj = allocator.resolve(hp);
        if (!obj) return nullptr;
        Header* hdr = static_cast<Header*>(obj);
        if (hdr->tag != Tag_Custom) return nullptr;
        return static_cast<Custom*>(obj);
    };

    auto pushLeftSpine = [&resolveCustom](std::vector<Custom*>& stack, Custom* node) {
        while (node != nullptr && node->ctor == CTOR_DICT_RBNODE) {
            stack.push_back(node);
            node = resolveCustom(node->values[3].p);
        }
    };

    std::vector<Custom*> aStack, bStack;
    pushLeftSpine(aStack, static_cast<Custom*>(a));
    pushLeftSpine(bStack, static_cast<Custom*>(b));

    while (!aStack.empty() && !bStack.empty()) {
        Custom* aNode = aStack.back(); aStack.pop_back();
        Custom* bNode = bStack.back(); bStack.pop_back();

        uint32_t aKKind = static_cast<uint32_t>(Elm::fieldKind(aNode->unboxed, 1));
        uint32_t bKKind = static_cast<uint32_t>(Elm::fieldKind(bNode->unboxed, 1));
        if (!eqUnboxableSlot(allocator, aNode->values[1], bNode->values[1],
                              aKKind, bKKind, depth)) {
            return false;
        }

        uint32_t aVKind = static_cast<uint32_t>(Elm::fieldKind(aNode->unboxed, 2));
        uint32_t bVKind = static_cast<uint32_t>(Elm::fieldKind(bNode->unboxed, 2));
        if (!eqUnboxableSlot(allocator, aNode->values[2], bNode->values[2],
                              aVKind, bVKind, depth)) {
            return false;
        }

        pushLeftSpine(aStack, resolveCustom(aNode->values[4].p));
        pushLeftSpine(bStack, resolveCustom(bNode->values[4].p));
    }

    return aStack.empty() && bStack.empty();
}

bool notEqual(void* a, void* b) {
    return !equal(a, b);
}

bool lt(void* a, void* b) {
    return cmp(a, b) < 0;
}

bool le(void* a, void* b) {
    return cmp(a, b) <= 0;
}

bool gt(void* a, void* b) {
    return cmp(a, b) > 0;
}

bool ge(void* a, void* b) {
    return cmp(a, b) >= 0;
}

// ============================================================================
// Append Operation
// ============================================================================

HPointer append(void* a, void* b) {
    if (!a && !b) return alloc::emptyString();
    if (!a) return Allocator::instance().wrap(b);
    if (!b) return Allocator::instance().wrap(a);

    Tag tagA = getTag(a);
    Tag tagB = getTag(b);

    // Either side may be a slice; route any string-shaped append through
    // StringOps::append so slice inputs are handled.
    if (alloc::isString(a) && alloc::isString(b)) {
        return StringOps::append(a, b);
    }

    if (tagA == Tag_Cons || alloc::isNil(Allocator::instance().wrap(a))) {
        // List append
        HPointer listA = Allocator::instance().wrap(a);
        HPointer listB = Allocator::instance().wrap(b);
        return ListOps::append(listA, listB);
    }

    // Unsupported types - return first value
    return Allocator::instance().wrap(a);
}

} // namespace Elm::Kernel::Utils
