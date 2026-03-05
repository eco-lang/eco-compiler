/**
 * Elm Kernel Utils Module - Runtime Heap Integration
 *
 * This module provides core comparison, equality, and utility functions
 * that work with the GC-managed heap values.
 */

#include "Utils.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/ListOps.hpp"

namespace Elm::Kernel::Utils {

// Order type: type_id 0 is reserved for built-in Order type
constexpr u16 ORDER_TYPE_ID = 0;
constexpr u16 ORDER_LT = 0;
constexpr u16 ORDER_EQ = 1;
constexpr u16 ORDER_GT = 2;

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

// Low-level comparison returning -1 (LT), 0 (EQ), or 1 (GT)
static int cmp(void* a, void* b) {
    // Null checks
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;

    Tag tagA = getTag(a);
    Tag tagB = getTag(b);

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

            {
                void* a1; void* b1; bool eq;
                if (resolveAndCompare(allocator, atup->a.p, btup->a.p, &a1, &b1, &eq) == 0) {
                    if (!eq) return atup->a.p.constant < btup->a.p.constant ? -1 : 1;
                } else {
                    int ord = cmp(a1, b1);
                    if (ord != 0) return ord;
                }
            }
            {
                void* a2; void* b2; bool eq;
                if (resolveAndCompare(allocator, atup->b.p, btup->b.p, &a2, &b2, &eq) == 0) {
                    return eq ? 0 : (atup->b.p.constant < btup->b.p.constant ? -1 : 1);
                }
                return cmp(a2, b2);
            }
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);

            {
                void* a1; void* b1; bool eq;
                if (resolveAndCompare(allocator, atup->a.p, btup->a.p, &a1, &b1, &eq) == 0) {
                    if (!eq) return atup->a.p.constant < btup->a.p.constant ? -1 : 1;
                } else {
                    int ord = cmp(a1, b1);
                    if (ord != 0) return ord;
                }
            }
            {
                void* a2; void* b2; bool eq;
                if (resolveAndCompare(allocator, atup->b.p, btup->b.p, &a2, &b2, &eq) == 0) {
                    if (!eq) return atup->b.p.constant < btup->b.p.constant ? -1 : 1;
                } else {
                    int ord = cmp(a2, b2);
                    if (ord != 0) return ord;
                }
            }
            {
                void* a3; void* b3; bool eq;
                if (resolveAndCompare(allocator, atup->c.p, btup->c.p, &a3, &b3, &eq) == 0) {
                    return eq ? 0 : (atup->c.p.constant < btup->c.p.constant ? -1 : 1);
                }
                return cmp(a3, b3);
            }
        }

        case Tag_Cons: {
            // Compare lists element by element
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);

                bool aHUnboxed = (ahdr->unboxed & 1);
                bool bHUnboxed = (bhdr->unboxed & 1);

                if (aHUnboxed && bHUnboxed) {
                    if (ax->head.i != bx->head.i) {
                        return ax->head.i < bx->head.i ? -1 : 1;
                    }
                } else if (!aHUnboxed && !bHUnboxed) {
                    void* aHead; void* bHead; bool eq;
                    if (resolveAndCompare(allocator, ax->head.p, bx->head.p,
                                          &aHead, &bHead, &eq) == 0) {
                        if (!eq) return ax->head.p.constant < bx->head.p.constant ? -1 : 1;
                    } else {
                        int ord = cmp(aHead, bHead);
                        if (ord != 0) return ord;
                    }
                } else {
                    // Mixed unboxed/boxed: resolve the boxed head for comparison.
                    i64 unboxedVal = aHUnboxed ? ax->head.i : bx->head.i;
                    HPointer boxedHP = aHUnboxed ? bx->head.p : ax->head.p;
                    void* boxedPtr = safeResolve(allocator, boxedHP);
                    if (!boxedPtr) return aHUnboxed ? -1 : 1;
                    Header* hdr = static_cast<Header*>(boxedPtr);
                    if (hdr->tag == Tag_Int) {
                        i64 boxedVal = static_cast<ElmInt*>(boxedPtr)->value;
                        if (unboxedVal != boxedVal) {
                            return unboxedVal < boxedVal ? -1 : 1;
                        }
                    } else {
                        return aHUnboxed ? -1 : 1;
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

    u16 orderCtor = (n < 0) ? ORDER_LT : (n > 0) ? ORDER_GT : ORDER_EQ;
    // Order has no fields, just the constructor tag
    return alloc::custom(orderCtor, {}, 0);
}

// ============================================================================
// Equality Operations
// ============================================================================

// Forward declaration
static bool eqHelp(void* a, void* b, int depth);

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

    // Type mismatch
    if (tagA != tagB) return false;

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

            {
                void* a1; void* b1; bool eq;
                if (resolveAndCompare(allocator, atup->a.p, btup->a.p, &a1, &b1, &eq) == 0) {
                    if (!eq) return false;
                } else {
                    if (!eqHelp(a1, b1, depth + 1)) return false;
                }
            }
            {
                void* a2; void* b2; bool eq;
                if (resolveAndCompare(allocator, atup->b.p, btup->b.p, &a2, &b2, &eq) == 0) {
                    return eq;
                }
                return eqHelp(a2, b2, depth + 1);
            }
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);

            {
                void* a1; void* b1; bool eq;
                if (resolveAndCompare(allocator, atup->a.p, btup->a.p, &a1, &b1, &eq) == 0) {
                    if (!eq) return false;
                } else {
                    if (!eqHelp(a1, b1, depth + 1)) return false;
                }
            }
            {
                void* a2; void* b2; bool eq;
                if (resolveAndCompare(allocator, atup->b.p, btup->b.p, &a2, &b2, &eq) == 0) {
                    if (!eq) return false;
                } else {
                    if (!eqHelp(a2, b2, depth + 1)) return false;
                }
            }
            {
                void* a3; void* b3; bool eq;
                if (resolveAndCompare(allocator, atup->c.p, btup->c.p, &a3, &b3, &eq) == 0) {
                    return eq;
                }
                return eqHelp(a3, b3, depth + 1);
            }
        }

        case Tag_Cons: {
            // Compare lists element by element
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);

                // Compare heads
                bool aHUnboxed = (ahdr->unboxed & 1);
                bool bHUnboxed = (bhdr->unboxed & 1);

                if (aHUnboxed && bHUnboxed) {
                    if (ax->head.i != bx->head.i) return false;
                } else if (aHUnboxed != bHUnboxed) {
                    // Mixed: one head is unboxed (raw i64), other is boxed (HPointer).
                    // Resolve the boxed head and compare values.
                    i64 unboxedVal = aHUnboxed ? ax->head.i : bx->head.i;
                    HPointer boxedHP = aHUnboxed ? bx->head.p : ax->head.p;
                    void* boxedPtr = safeResolve(allocator, boxedHP);
                    if (!boxedPtr) return false;
                    Header* hdr = static_cast<Header*>(boxedPtr);
                    if (hdr->tag == Tag_Int) {
                        if (static_cast<ElmInt*>(boxedPtr)->value != unboxedVal) return false;
                    } else {
                        return false;
                    }
                } else {
                    void* aHead; void* bHead; bool eq;
                    if (resolveAndCompare(allocator, ax->head.p, bx->head.p,
                                          &aHead, &bHead, &eq) == 0) {
                        if (!eq) return false;
                    } else {
                        if (!eqHelp(aHead, bHead, depth + 1)) return false;
                    }
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

            if (ac->ctor != bc->ctor) return false;

            // Compare fields
            u32 fieldCount = ac->header.size;
            if (fieldCount != bc->header.size) return false;

            for (u32 i = 0; i < fieldCount; ++i) {
                bool aUnboxed = (ac->unboxed >> i) & 1;
                bool bUnboxed = (bc->unboxed >> i) & 1;

                if (aUnboxed && bUnboxed) {
                    // Both unboxed - compare raw values
                    if (ac->values[i].i != bc->values[i].i) return false;
                } else if (aUnboxed || bUnboxed) {
                    // Mixed unboxed/boxed - not equal
                    return false;
                } else {
                    // Both boxed - handle embedded constants
                    void* aVal;
                    void* bVal;
                    bool eqResult;
                    if (resolveAndCompare(allocator, ac->values[i].p, bc->values[i].p,
                                          &aVal, &bVal, &eqResult) == 0) {
                        if (!eqResult) return false;
                    } else {
                        if (!eqHelp(aVal, bVal, depth + 1)) return false;
                    }
                }
            }

            return true;
        }

        case Tag_Record: {
            Record* ar = static_cast<Record*>(a);
            Record* br = static_cast<Record*>(b);

            u32 fieldCount = ar->header.size;
            if (fieldCount != br->header.size) return false;

            for (u32 i = 0; i < fieldCount; ++i) {
                bool aUnboxed = (ar->unboxed >> i) & 1;
                bool bUnboxed = (br->unboxed >> i) & 1;

                if (aUnboxed && bUnboxed) {
                    if (ar->values[i].i != br->values[i].i) return false;
                } else if (aUnboxed || bUnboxed) {
                    return false;
                } else {
                    void* aVal; void* bVal; bool eq;
                    if (resolveAndCompare(allocator, ar->values[i].p, br->values[i].p,
                                          &aVal, &bVal, &eq) == 0) {
                        if (!eq) return false;
                    } else {
                        if (!eqHelp(aVal, bVal, depth + 1)) return false;
                    }
                }
            }

            return true;
        }

        case Tag_Array: {
            ElmArray* aa = static_cast<ElmArray*>(a);
            ElmArray* ba = static_cast<ElmArray*>(b);

            if (aa->length != ba->length) return false;

            bool aUnboxed = aa->header.unboxed != 0;
            bool bUnboxed = ba->header.unboxed != 0;

            if (aUnboxed != bUnboxed) return false;

            for (u32 i = 0; i < aa->length; ++i) {
                if (aUnboxed) {
                    if (aa->elements[i].i != ba->elements[i].i) return false;
                } else {
                    void* aVal; void* bVal; bool eq;
                    if (resolveAndCompare(allocator, aa->elements[i].p, ba->elements[i].p,
                                          &aVal, &bVal, &eq) == 0) {
                        if (!eq) return false;
                    } else {
                        if (!eqHelp(aVal, bVal, depth + 1)) return false;
                    }
                }
            }

            return true;
        }

        case Tag_ByteBuffer: {
            ByteBuffer* ab = static_cast<ByteBuffer*>(a);
            ByteBuffer* bb = static_cast<ByteBuffer*>(b);

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

    if (tagA == Tag_String && tagB == Tag_String) {
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
