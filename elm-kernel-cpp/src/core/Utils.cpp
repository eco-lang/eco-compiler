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

            // Compare first element
            void* a1 = allocator.resolve(atup->a.p);
            void* b1 = allocator.resolve(btup->a.p);
            int ord = cmp(a1, b1);
            if (ord != 0) return ord;

            // Compare second element
            void* a2 = allocator.resolve(atup->b.p);
            void* b2 = allocator.resolve(btup->b.p);
            return cmp(a2, b2);
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);

            // Compare first element
            void* a1 = allocator.resolve(atup->a.p);
            void* b1 = allocator.resolve(btup->a.p);
            int ord = cmp(a1, b1);
            if (ord != 0) return ord;

            // Compare second element
            void* a2 = allocator.resolve(atup->b.p);
            void* b2 = allocator.resolve(btup->b.p);
            ord = cmp(a2, b2);
            if (ord != 0) return ord;

            // Compare third element
            void* a3 = allocator.resolve(atup->c.p);
            void* b3 = allocator.resolve(btup->c.p);
            return cmp(a3, b3);
        }

        case Tag_Cons: {
            // Compare lists element by element
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);

                // Compare heads
                void* aHead;
                void* bHead;

                if (ahdr->unboxed & 1) {
                    // Unboxed - box for comparison
                    aHead = allocator.resolve(alloc::allocInt(ax->head.i));
                } else {
                    aHead = allocator.resolve(ax->head.p);
                }

                if (bhdr->unboxed & 1) {
                    bHead = allocator.resolve(alloc::allocInt(bx->head.i));
                } else {
                    bHead = allocator.resolve(bx->head.p);
                }

                int ord = cmp(aHead, bHead);
                if (ord != 0) return ord;

                // Move to tails
                if (alloc::isNil(ax->tail)) ax = nullptr;
                else ax = static_cast<Cons*>(allocator.resolve(ax->tail));

                if (alloc::isNil(bx->tail)) bx = nullptr;
                else bx = static_cast<Cons*>(allocator.resolve(bx->tail));
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
    return alloc::custom(ORDER_TYPE_ID, orderCtor, {}, 0);
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

            void* a1 = allocator.resolve(atup->a.p);
            void* b1 = allocator.resolve(btup->a.p);
            if (!eqHelp(a1, b1, depth + 1)) return false;

            void* a2 = allocator.resolve(atup->b.p);
            void* b2 = allocator.resolve(btup->b.p);
            return eqHelp(a2, b2, depth + 1);
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);

            void* a1 = allocator.resolve(atup->a.p);
            void* b1 = allocator.resolve(btup->a.p);
            if (!eqHelp(a1, b1, depth + 1)) return false;

            void* a2 = allocator.resolve(atup->b.p);
            void* b2 = allocator.resolve(btup->b.p);
            if (!eqHelp(a2, b2, depth + 1)) return false;

            void* a3 = allocator.resolve(atup->c.p);
            void* b3 = allocator.resolve(btup->c.p);
            return eqHelp(a3, b3, depth + 1);
        }

        case Tag_Cons: {
            // Compare lists element by element
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);

                // Compare heads
                void* aHead;
                void* bHead;

                if (ahdr->unboxed & 1) {
                    aHead = allocator.resolve(alloc::allocInt(ax->head.i));
                } else {
                    aHead = allocator.resolve(ax->head.p);
                }

                if (bhdr->unboxed & 1) {
                    bHead = allocator.resolve(alloc::allocInt(bx->head.i));
                } else {
                    bHead = allocator.resolve(bx->head.p);
                }

                if (!eqHelp(aHead, bHead, depth + 1)) return false;

                // Move to tails
                if (alloc::isNil(ax->tail)) ax = nullptr;
                else ax = static_cast<Cons*>(allocator.resolve(ax->tail));

                if (alloc::isNil(bx->tail)) bx = nullptr;
                else bx = static_cast<Cons*>(allocator.resolve(bx->tail));
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

                void* aVal;
                void* bVal;

                if (aUnboxed) {
                    aVal = allocator.resolve(alloc::allocInt(ac->values[i].i));
                } else {
                    aVal = allocator.resolve(ac->values[i].p);
                }

                if (bUnboxed) {
                    bVal = allocator.resolve(alloc::allocInt(bc->values[i].i));
                } else {
                    bVal = allocator.resolve(bc->values[i].p);
                }

                if (!eqHelp(aVal, bVal, depth + 1)) return false;
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

                void* aVal;
                void* bVal;

                if (aUnboxed) {
                    aVal = allocator.resolve(alloc::allocInt(ar->values[i].i));
                } else {
                    aVal = allocator.resolve(ar->values[i].p);
                }

                if (bUnboxed) {
                    bVal = allocator.resolve(alloc::allocInt(br->values[i].i));
                } else {
                    bVal = allocator.resolve(br->values[i].p);
                }

                if (!eqHelp(aVal, bVal, depth + 1)) return false;
            }

            return true;
        }

        case Tag_Array: {
            ElmArray* aa = static_cast<ElmArray*>(a);
            ElmArray* ba = static_cast<ElmArray*>(b);

            if (aa->length != ba->length) return false;

            for (u32 i = 0; i < aa->length; ++i) {
                bool aUnboxed = (aa->unboxed >> i) & 1;
                bool bUnboxed = (ba->unboxed >> i) & 1;

                void* aVal;
                void* bVal;

                if (aUnboxed) {
                    aVal = allocator.resolve(alloc::allocInt(aa->elements[i].i));
                } else {
                    aVal = allocator.resolve(aa->elements[i].p);
                }

                if (bUnboxed) {
                    bVal = allocator.resolve(alloc::allocInt(ba->elements[i].i));
                } else {
                    bVal = allocator.resolve(ba->elements[i].p);
                }

                if (!eqHelp(aVal, bVal, depth + 1)) return false;
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
    if (!a || !b) {
        if (!a) return Allocator::instance().wrap(b);
        return Allocator::instance().wrap(a);
    }

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
