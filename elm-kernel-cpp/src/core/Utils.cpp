#include "Utils.hpp"
#include "ExportHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include "allocator/ListOps.hpp"

#include <cassert>
#include <utility>
#include <vector>

namespace Elm::Kernel::Utils {

/// A type id for Order. Nothing uses it.
constexpr u16 ORDER_TYPE_ID = 0;
/// The constructor index of LT, the first of Order's nullary constructors.
constexpr u16 ORDER_LT = 0;
/// The constructor index of EQ.
constexpr u16 ORDER_EQ = 1;
/// The constructor index of GT.
constexpr u16 ORDER_GT = 2;

// Order's constructors take no arguments, so each value is the null-cons word `nullConsWordFor` builds
// from its constructor index.
void initOrderSingletons() {}

uint64_t getOrderLT() { return nullConsWordFor(ORDER_LT); }
uint64_t getOrderEQ() { return nullConsWordFor(ORDER_EQ); }
uint64_t getOrderGT() { return nullConsWordFor(ORDER_GT); }

/// The constructor tag the compiler gives `Dict.RBNode_elm_builtin`, so that equality can recognise a Dict
/// node and compare two Dicts by content rather than by the shape of their trees. It must match
/// `Compiler.IR.Runtime.CtorTag` in the compiler; `test/scripts/check-ctor-tags.sh` checks that it does.
///
/// `RBEmpty_elm_builtin` needs no tag: it has no fields, so it is an embedded constant and never reaches
/// `eqHelp` as a heap object.
constexpr u16 CTOR_DICT_RBNODE = 0xFFFF;
// 0xFFFC to 0xFFFE are reserved too: 0xFFFD is the tag the runtime reports for the Empty constant (runtime
// `Heap.hpp`, `CONSTANT_TAG`, which lists the whole range), 0xFFFC and 0xFFFE its router and stack-frame
// constructors.

/// Returns whether `ctor` is the constructor tag of a Dict node.
static bool isDictCtor(u16 ctor) {
    return ctor == CTOR_DICT_RBNODE;
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Returns the heap tag of the object at `obj`, or `Tag_Forward` for a null `obj`, which no caller treats
/// as a real tag.
static Tag getTag(void* obj) {
    if (!obj) return Tag_Forward;
    Header* hdr = static_cast<Header*>(obj);
    return static_cast<Tag>(hdr->tag);
}

/// Returns the address of the object the slot word `p` refers to, or null when `p` is an embedded constant.
static void* safeResolve(Allocator& allocator, HPointer p) {
    if (alloc::isConstant(p)) return nullptr;
    return allocator.resolve(p);
}

/// Decides equality of two boxed slot words `ap` and `bp` when either is an embedded constant, or resolves
/// both when neither is.
///
/// Returns 0 when either is a constant, with `*eqResult` set: true when the words are equal, or when one
/// is the Empty constant and the other a String of length 0. `*aOut` and `*bOut` are then not written.
/// Returns 1 when both are heap words, with their addresses in `*aOut` and `*bOut` and `*eqResult` not
/// written.
static int resolveAndCompare(Allocator& allocator, HPointer ap, HPointer bp,
                              void** aOut, void** bOut, bool* eqResult) {
    bool aConst = alloc::isConstant(ap);
    bool bConst = alloc::isConstant(bp);

    if (aConst || bConst) {
        union { HPointer hp; uint64_t val; } ua, ub;
        ua.hp = ap;
        ub.hp = bp;
        *eqResult = (ua.val == ub.val);
        if (!*eqResult && aConst != bConst) {
            HPointer c = aConst ? ap : bp;
            HPointer h = aConst ? bp : ap;
            *eqResult = alloc::isEmptyString(c) &&
                        alloc::isZeroLengthString(allocator.resolve(h));
        }
        return 0;
    }

    *aOut = allocator.resolve(ap);
    *bOut = allocator.resolve(bp);
    return 1;
}

/// The pairs `eqHelp` met beyond its depth bound and left for `equal` to compare, as elm/core's JS
/// `_Utils_eqHelp` does with its `stack`. The raw addresses stay valid because equality allocates
/// nothing, so no collection can run, and no object moves, while one `equal` call runs; the vector itself
/// is ordinary C++ memory, off the GC heap.
using EqDeferred = std::vector<std::pair<void*, void*>>;

static bool eqHelp(void* a, void* b, int depth, EqDeferred& deferred);
static bool dictEq(void* a, void* b, int depth, EqDeferred& deferred);

/// Returns whether slots `a` and `b`, of kinds `aKind` and `bKind`, hold equal values, with `depth` the
/// nesting depth `eqHelp` bounds and `deferred` the pairs it leaves for `equal`.
///
/// Same-kind primitives compare by value, Floats with IEEE `==`. Two boxed slots are decided by
/// `resolveAndCompare`, or by `eqHelp` one level deeper. A boxed slot and an unboxed one are equal when
/// the boxed side is a heap Int, Float or Char of the unboxed kind with the same value; any other pair of
/// different kinds is unequal.
static bool eqUnboxableSlot(Allocator& allocator,
                             Elm::Unboxable a, Elm::Unboxable b,
                             uint32_t aKind, uint32_t bKind, int depth, EqDeferred& deferred) {
    if (aKind == bKind) {
        switch (aKind) {
            case 1: return a.i == b.i;
            case 2: return a.f == b.f;
            case 3: return a.c == b.c;
            default: {
                void* ao; void* bo; bool eq;
                if (resolveAndCompare(allocator, a.p, b.p, &ao, &bo, &eq) == 0) return eq;
                return eqHelp(ao, bo, depth + 1, deferred);
            }
        }
    }

    // Mixed kinds arise when two containers of the same type were built by different paths, for example an
    // Int array decoded from JSON (unboxed) and one built from a list of boxed Ints.
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

/// Returns -1, 0 or 1 as Char `a` is below, equal to or above `b` in code-point order.
static int compareChar(u32 a, u32 b) {
    return a < b ? -1 : (a > b ? 1 : 0);
}

/// Returns the order of slots `a` and `b`, which must both have kind `kind`, with `cmpFn` used to compare
/// two boxed heap values.
///
/// Ints compare numerically, Floats by `compareFloat`, Chars by code point. For two boxed slots, a
/// constant equal to the other word is 0; the Empty constant against a String object is 0 when the String
/// has length 0 and below it otherwise; any other constant is below a heap value. Two different constants
/// must not reach here: that asserts, and is undefined behaviour when assertions are off.
static int compareUnboxableSlot(Allocator& allocator,
                                 Elm::Unboxable a, Elm::Unboxable b, uint32_t kind,
                                 int (*cmpFn)(void*, void*)) {
    switch (kind) {
        case 1:
            if (a.i == b.i) return 0;
            return a.i < b.i ? -1 : 1;
        case 2:
            return compareFloat(a.f, b.f);
        case 3:
            return compareChar(a.c, b.c);
        default: {
            void* ao; void* bo; bool eq;
            if (resolveAndCompare(allocator, a.p, b.p, &ao, &bo, &eq) == 0) {
                if (eq) return 0;
                bool aConst = alloc::isConstant(a.p);
                bool bConst = alloc::isConstant(b.p);

                // `header.size` is the length in UTF-16 units in every String form.
                if (alloc::isEmptyString(a.p) && !bConst) {
                    void* bo2 = allocator.resolve(b.p);
                    if (alloc::isString(bo2)) {
                        return static_cast<Header*>(bo2)->size == 0 ? 0 : -1;
                    }
                }
                if (alloc::isEmptyString(b.p) && !aConst) {
                    void* ao2 = allocator.resolve(a.p);
                    if (alloc::isString(ao2)) {
                        return static_cast<Header*>(ao2)->size == 0 ? 0 : 1;
                    }
                }

                // The only comparable constants are "" and [], each the least value of its type.
                if (aConst && !bConst) return -1;
                if (!aConst && bConst) return 1;

                // Two different constants: in well-typed Elm two comparable values of one type cannot both
                // be constants and differ.
                assert(false &&
                       "compareUnboxableSlot: cross-family constant comparison "
                       "is unreachable in well-typed Elm");
                __builtin_unreachable();
            }
            return cmpFn(ao, bo);
        }
    }
}

/// Returns whether the object at `p` is a list spine node, a `Tag_Cons` cell or a `Tag_ConsChunk` view.
///
/// A spine may mix both forms, and neither the forms nor where chunks begin are part of a list's value, so
/// equality and ordering walk the elements with `alloc::ListCursor` whenever the forms differ.
static inline bool isListNode(void* p) {
    Tag t = getTag(p);
    return t == Tag_Cons || t == Tag_ConsChunk;
}

/// Returns the order of slots `aSlot` and `bSlot` (list elements or tuple fields), of kinds `aKind` and
/// `bKind`, with `cmpFn` used to compare two boxed heap values.
///
/// Same-kind slots go to `compareUnboxableSlot`. When one is boxed and refers to a heap Int, Float or
/// Char of the other's kind, the values are compared as `compareUnboxableSlot` compares them (Floats by
/// `compareFloat`), so the order agrees with `eqUnboxableSlot`. A boxed slot that is a constant orders
/// above the unboxed one. Any other pair orders by kind; well-typed values do not reach that.
static int compareMixedSlot(Elm::Allocator& allocator,
                           Elm::Unboxable aSlot, uint32_t aKind,
                           Elm::Unboxable bSlot, uint32_t bKind,
                           int (*cmpFn)(void*, void*)) {
    if (aKind == bKind) {
        return compareUnboxableSlot(allocator, aSlot, bSlot, aKind, cmpFn);
    }
    if (aKind == 0 || bKind == 0) {
        HPointer boxedHP = (aKind == 0) ? aSlot.p : bSlot.p;
        Elm::Unboxable prim = (aKind == 0) ? bSlot : aSlot;
        uint32_t primKind = (aKind == 0) ? bKind : aKind;
        void* boxedPtr = safeResolve(allocator, boxedHP);
        if (!boxedPtr) return (aKind == 0) ? 1 : -1;
        Header* hdr = static_cast<Header*>(boxedPtr);
        if ((hdr->tag == Tag_Int && primKind == 1)
         || (hdr->tag == Tag_Float && primKind == 2)
         || (hdr->tag == Tag_Char && primKind == 3)) {
            int ord = 0;
            if (primKind == 1) {
                i64 bv = static_cast<ElmInt*>(boxedPtr)->value;
                i64 uv = prim.i;
                if (aKind == 0) { ord = (bv == uv) ? 0 : (bv < uv ? -1 : 1); }
                else             { ord = (uv == bv) ? 0 : (uv < bv ? -1 : 1); }
            } else if (primKind == 2) {
                f64 bv = static_cast<ElmFloat*>(boxedPtr)->value;
                f64 uv = prim.f;
                if (aKind == 0) { ord = compareFloat(bv, uv); }
                else             { ord = compareFloat(uv, bv); }
            } else {
                u32 bv = static_cast<ElmChar*>(boxedPtr)->value;
                u32 uv = prim.c;
                if (aKind == 0) { ord = compareChar(bv, uv); }
                else             { ord = compareChar(uv, bv); }
            }
            return ord;
        }
        return aKind < bKind ? -1 : 1;
    }
    return aKind < bKind ? -1 : 1;
}

static int cmp(void* a, void* b);

/// Returns the order of the lists whose first spine nodes are at `a` and `b`, walking their elements in
/// whatever spine forms they have. A list that is a proper prefix of the other orders below it.
///
/// `cmp` comes here only when a spine contains a chunk view; a spine of cells alone is walked directly.
static int cmpListHybrid(void* a, void* b) {
    auto& allocator = Allocator::instance();
    alloc::ListCursor ca(allocator.wrap(a));
    alloc::ListCursor cb(allocator.wrap(b));
    while (!ca.done() && !cb.done()) {
        int ord = compareMixedSlot(allocator, ca.current(), ca.currentKind(),
                                  cb.current(), cb.currentKind(), cmp);
        if (ord != 0) return ord;
        ca.next();
        cb.next();
    }
    if (!ca.done()) return 1;
    if (!cb.done()) return -1;
    return 0;
}

/// Returns the unclamped sign `cmp3` documents; `cmp3` is this function under a public name.
static int cmp(void* a, void* b) {
    if (!a && !b) return 0;
    if (!a) return alloc::isZeroLengthString(b) ? 0 : -1;
    if (!b) return alloc::isZeroLengthString(a) ? 0 : 1;

    Tag tagA = getTag(a);
    Tag tagB = getTag(b);

    // Checked before the tags, which differ between String forms.
    if (alloc::isString(a) && alloc::isString(b)) {
        return StringOps::compare(a, b);
    }

    // A cell and a chunk view have different tags but may be equal lists. Testing for them only here keeps
    // the test off the path where the tags agree.
    if (tagA != tagB) {
        if (isListNode(a) && isListNode(b)) {
            return cmpListHybrid(a, b);
        }
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
            return compareFloat(af->value, bf->value);
        }

        case Tag_Char: {
            // Code-point order. elm/core's JS compares Chars as UTF-16 strings, which differs from this only
            // between U+E000..U+FFFF and code points above U+FFFF, where JS puts the surrogate pair first.
            ElmChar* ac = static_cast<ElmChar*>(a);
            ElmChar* bc = static_cast<ElmChar*>(b);
            return compareChar(ac->value, bc->value);
        }

        case Tag_String: {
            return StringOps::compare(a, b);
        }

        case Tag_Tuple2: {
            Elm::Tuple2* atup = static_cast<Elm::Tuple2*>(a);
            Elm::Tuple2* btup = static_cast<Elm::Tuple2*>(b);
            Header* ahdr = getHeader(a);
            Header* bhdr = getHeader(b);

            // A slot boxed on one side and unboxed on the other compares by value, as `==` does.
            int ord = compareMixedSlot(allocator, atup->a, Elm::tupleFieldKind(ahdr->unboxed, 0),
                                       btup->a, Elm::tupleFieldKind(bhdr->unboxed, 0), cmp);
            if (ord != 0) return ord;
            return compareMixedSlot(allocator, atup->b, Elm::tupleFieldKind(ahdr->unboxed, 1),
                                    btup->b, Elm::tupleFieldKind(bhdr->unboxed, 1), cmp);
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);
            Header* ahdr = getHeader(a);
            Header* bhdr = getHeader(b);

            for (unsigned i = 0; i < 3; ++i) {
                uint32_t aKind = Elm::tupleFieldKind(ahdr->unboxed, i);
                uint32_t bKind = Elm::tupleFieldKind(bhdr->unboxed, i);
                Elm::Unboxable aSlot = (i == 0) ? atup->a : (i == 1) ? atup->b : atup->c;
                Elm::Unboxable bSlot = (i == 0) ? btup->a : (i == 1) ? btup->b : btup->c;
                int ord = compareMixedSlot(allocator, aSlot, aKind, bSlot, bKind, cmp);
                if (ord != 0 || i == 2) return ord;
            }
            return 0;
        }

        case Tag_Cons: {
            // Walks cells directly, and hands the rest of both lists to the cursor walk as soon as either
            // spine reaches a chunk view.
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);
                if (ahdr->tag != Tag_Cons || bhdr->tag != Tag_Cons) {
                    return cmpListHybrid(ax, bx);
                }

                int ord = compareMixedSlot(
                    allocator, ax->head,
                    Elm::tupleFieldKind(ahdr->unboxed, 0), bx->head,
                    Elm::tupleFieldKind(bhdr->unboxed, 0), cmp);
                if (ord != 0) return ord;

                ax = alloc::isNil(ax->tail)
                         ? nullptr
                         : static_cast<Cons*>(safeResolve(allocator, ax->tail));
                bx = alloc::isNil(bx->tail)
                         ? nullptr
                         : static_cast<Cons*>(safeResolve(allocator, bx->tail));
            }

            if (ax != nullptr) return 1;
            if (bx != nullptr) return -1;
            return 0;
        }

        case Tag_ConsChunk:
            return cmpListHybrid(a, b);

        default:
            // Elm cannot order other types, so a well-typed program does not reach this.
            return 0;
    }
}

// ============================================================================
// Comparison Operations
// ============================================================================

HPointer compare(void* a, void* b) {
    int n = cmp(a, b);
    uint64_t enc = (n < 0) ? getOrderLT()
                : (n > 0) ? getOrderGT()
                          : getOrderEQ();
    return Export::decode(enc);
}

int cmp3(void* a, void* b) {
    return cmp(a, b);
}

// ============================================================================
// Equality Operations
// ============================================================================

bool equal(void* a, void* b) {
    // `eqHelp` recurses at most about 100 boxed levels deep and defers the pairs below that; each deferred
    // pair is compared afresh from depth 0, which may defer more. So the C stack stays bounded and every
    // part of both values is still examined.
    EqDeferred deferred;
    bool isEqual = eqHelp(a, b, 0, deferred);
    while (isEqual && !deferred.empty()) {
        auto [x, y] = deferred.back();
        deferred.pop_back();
        isEqual = eqHelp(x, y, 0, deferred);
    }
    return isEqual;
}

/// Returns whether list elements `aSlot` and `bSlot`, of kinds `aKind` and `bKind`, are equal, with
/// `depth` the nesting depth `eqHelp` bounds and `deferred` the pairs it leaves for `equal`.
///
/// Same-kind elements go to `eqUnboxableSlot`. A boxed element and an unboxed one are equal when the
/// boxed side is a heap Int, Float or Char of the unboxed kind with the same value; any other pair of
/// different kinds is unequal.
static bool eqListElem(Elm::Allocator& allocator,
                       Elm::Unboxable aSlot, uint32_t aKind,
                       Elm::Unboxable bSlot, uint32_t bKind, int depth, EqDeferred& deferred) {
    if (aKind == bKind) {
        return eqUnboxableSlot(allocator, aSlot, bSlot, aKind, bKind, depth, deferred);
    }
    if (aKind == 0 || bKind == 0) {
        HPointer boxedHP = (aKind == 0) ? aSlot.p : bSlot.p;
        Elm::Unboxable prim = (aKind == 0) ? bSlot : aSlot;
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
        return false;
    }
    return false;
}

/// Returns whether the lists whose first spine nodes are at `a` and `b` have equal elements and the same
/// length, walking them in whatever spine forms they have. Used only where a spine contains a chunk view,
/// as for `cmpListHybrid`.
static bool eqListHybrid(void* a, void* b, int depth, EqDeferred& deferred) {
    auto& allocator = Allocator::instance();
    alloc::ListCursor ca(allocator.wrap(a));
    alloc::ListCursor cb(allocator.wrap(b));
    while (!ca.done() && !cb.done()) {
        if (!eqListElem(allocator, ca.current(), ca.currentKind(),
                        cb.current(), cb.currentKind(), depth, deferred)) {
            return false;
        }
        ca.next();
        cb.next();
    }
    return ca.done() && cb.done();
}

/// Returns `equal(a, b)` for values reached through `depth` levels of boxed slots, as far as this call
/// decides it. Above 100, for two values with the same tag that are not Strings or Bytes, it pushes the
/// pair onto `deferred` and returns true; `equal` compares the deferred pairs afterwards.
static bool eqHelp(void* a, void* b, int depth, EqDeferred& deferred) {
    if (a == b) return true;

    if (!a || !b) return alloc::isZeroLengthString(a ? a : b);

    Tag tagA = getTag(a);
    Tag tagB = getTag(b);

    // Checked before the tags, which differ between String forms, and likewise for Bytes below.
    if (alloc::isString(a) && alloc::isString(b)) {
        return StringOps::equal(a, b);
    }

    if (alloc::isByteBuffer(a) && alloc::isByteBuffer(b)) {
        auto va = alloc::byteBufferView(a);
        auto vb = alloc::byteBufferView(b);
        if (va.length != vb.length) return false;
        if (va.length == 0) return true;
        return std::memcmp(va.data, vb.data, va.length) == 0;
    }

    // As in `cmp`, a cell and a chunk view are tested for only when the tags differ.
    if (tagA != tagB) {
        if (isListNode(a) && isListNode(b)) {
            return eqListHybrid(a, b, depth, deferred);
        }
        return false;
    }

    // Bounds the recursion: the pair is compared later, from depth 0, by `equal`.
    if (depth > 100) {
        deferred.emplace_back(a, b);
        return true;
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
                                  Elm::tupleFieldKind(bhdr->unboxed, 0), depth, deferred)) return false;
            return eqUnboxableSlot(allocator, atup->b, btup->b,
                                    Elm::tupleFieldKind(ahdr->unboxed, 1),
                                    Elm::tupleFieldKind(bhdr->unboxed, 1), depth, deferred);
        }

        case Tag_Tuple3: {
            Elm::Tuple3* atup = static_cast<Elm::Tuple3*>(a);
            Elm::Tuple3* btup = static_cast<Elm::Tuple3*>(b);
            Header* ahdr = getHeader(a);
            Header* bhdr = getHeader(b);
            if (!eqUnboxableSlot(allocator, atup->a, btup->a,
                                  Elm::tupleFieldKind(ahdr->unboxed, 0),
                                  Elm::tupleFieldKind(bhdr->unboxed, 0), depth, deferred)) return false;
            if (!eqUnboxableSlot(allocator, atup->b, btup->b,
                                  Elm::tupleFieldKind(ahdr->unboxed, 1),
                                  Elm::tupleFieldKind(bhdr->unboxed, 1), depth, deferred)) return false;
            return eqUnboxableSlot(allocator, atup->c, btup->c,
                                    Elm::tupleFieldKind(ahdr->unboxed, 2),
                                    Elm::tupleFieldKind(bhdr->unboxed, 2), depth, deferred);
        }

        case Tag_Cons: {
            // Walks cells directly, as in `cmp`.
            Cons* ax = static_cast<Cons*>(a);
            Cons* bx = static_cast<Cons*>(b);

            while (ax && bx) {
                Header* ahdr = getHeader(ax);
                Header* bhdr = getHeader(bx);
                if (ahdr->tag != Tag_Cons || bhdr->tag != Tag_Cons) {
                    return eqListHybrid(ax, bx, depth, deferred);
                }

                if (!eqListElem(allocator, ax->head,
                                Elm::tupleFieldKind(ahdr->unboxed, 0),
                                bx->head,
                                Elm::tupleFieldKind(bhdr->unboxed, 0),
                                depth, deferred)) {
                    return false;
                }

                ax = alloc::isNil(ax->tail)
                         ? nullptr
                         : static_cast<Cons*>(safeResolve(allocator, ax->tail));
                bx = alloc::isNil(bx->tail)
                         ? nullptr
                         : static_cast<Cons*>(safeResolve(allocator, bx->tail));
            }

            return ax == nullptr && bx == nullptr;
        }

        case Tag_ConsChunk:
            return eqListHybrid(a, b, depth, deferred);

        case Tag_Custom: {
            Custom* ac = static_cast<Custom*>(a);
            Custom* bc = static_cast<Custom*>(b);

            // Two Dicts with the same pairs may have different trees, depending on insertion order.
            if (isDictCtor(ac->ctor) || isDictCtor(bc->ctor)) {
                return dictEq(a, b, depth, deferred);
            }

            if (ac->ctor != bc->ctor) return false;

            u32 fieldCount = ac->header.size;
            if (fieldCount != bc->header.size) return false;

            for (u32 i = 0; i < fieldCount; ++i) {
                uint32_t aKind = static_cast<uint32_t>(Elm::customSlotKind(ac, i));
                uint32_t bKind = static_cast<uint32_t>(Elm::customSlotKind(bc, i));
                if (!eqUnboxableSlot(allocator, ac->values[i], bc->values[i], aKind, bKind, depth, deferred)) return false;
            }

            return true;
        }

        case Tag_Record: {
            Record* ar = static_cast<Record*>(a);
            Record* br = static_cast<Record*>(b);

            u32 fieldCount = ar->header.size;
            if (fieldCount != br->header.size) return false;

            for (u32 i = 0; i < fieldCount; ++i) {
                uint32_t aKind = static_cast<uint32_t>(Elm::recordSlotKind(ar, i));
                uint32_t bKind = static_cast<uint32_t>(Elm::recordSlotKind(br, i));
                if (!eqUnboxableSlot(allocator, ar->values[i], br->values[i], aKind, bKind, depth, deferred)) return false;
            }

            return true;
        }

        case Tag_Array: {
            ElmArray* aa = static_cast<ElmArray*>(a);
            ElmArray* ba = static_cast<ElmArray*>(b);

            if (aa->length != ba->length) return false;

            uint32_t aKind = aa->header.unboxed & 0x3;
            uint32_t bKind = ba->header.unboxed & 0x3;

            // One kind covers every element. Two arrays with the same elements may still differ in it, for
            // example one decoded from JSON with an Int decoder and one built from a list of boxed Ints.
            for (u32 i = 0; i < aa->length; ++i) {
                if (!eqUnboxableSlot(allocator, aa->elements[i], ba->elements[i], aKind, bKind, depth, deferred)) return false;
            }

            return true;
        }

        case Tag_ByteBuffer: {
            // Unreachable: the `isByteBuffer` test above already took every Bytes pair.
            auto va = alloc::byteBufferView(a);
            auto vb = alloc::byteBufferView(b);
            if (va.length != vb.length) return false;
            if (va.length == 0) return true;
            return std::memcmp(va.data, vb.data, va.length) == 0;
        }

        case Tag_Closure:
            return false;

        default:
            return false;
    }
}

/// Returns whether the Dicts whose root nodes are at `a` and `b` hold equal key/value pairs in the same
/// key order, with `depth` the nesting depth `eqHelp` bounds and `deferred` the pairs it leaves for `equal`.
///
/// Walks both trees in order, in step, with an explicit stack each. A node is
/// `RBNode_elm_builtin color key value left right`, in slots 0 to 4. Colours are ignored, since two trees
/// holding the same pairs can colour their nodes differently. A non-Dict node, such as a Custom with
/// another constructor on one side, ends that tree's walk.
static bool dictEq(void* a, void* b, int depth, EqDeferred& deferred) {
    auto& allocator = Allocator::instance();

    // Returns the Custom a subtree word refers to, or null for a constant (the empty subtree, RBEmpty) or a
    // heap object that is not a Custom.
    auto resolveCustom = [&allocator](HPointer hp) -> Custom* {
        if (alloc::isConstant(hp)) return nullptr;
        void* obj = allocator.resolve(hp);
        Header* hdr = static_cast<Header*>(obj);
        if (hdr->tag != Tag_Custom) return nullptr;
        return static_cast<Custom*>(obj);
    };

    // Pushes `node` and its chain of left children, stopping at the first that is not a Dict node.
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
                              aKKind, bKKind, depth, deferred)) {
            return false;
        }

        uint32_t aVKind = static_cast<uint32_t>(Elm::fieldKind(aNode->unboxed, 2));
        uint32_t bVKind = static_cast<uint32_t>(Elm::fieldKind(bNode->unboxed, 2));
        if (!eqUnboxableSlot(allocator, aNode->values[2], bNode->values[2],
                              aVKind, bVKind, depth, deferred)) {
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

/// Returns whether `a` and `b` are both heap Floats, and if so writes their values to `x` and `y`. When it
/// returns false, `x` and `y` are not written.
static bool bothFloats(void* a, void* b, double& x, double& y) {
    if (!a || !b || getTag(a) != Tag_Float || getTag(b) != Tag_Float) return false;
    x = static_cast<ElmFloat*>(a)->value;
    y = static_cast<ElmFloat*>(b)->value;
    return true;
}

bool lt(void* a, void* b) {
    double x, y;
    if (bothFloats(a, b, x, y)) return x < y;
    return cmp(a, b) < 0;
}

bool le(void* a, void* b) {
    double x, y;
    if (bothFloats(a, b, x, y)) return x <= y;
    return cmp(a, b) <= 0;
}

bool gt(void* a, void* b) {
    double x, y;
    if (bothFloats(a, b, x, y)) return x > y;
    return cmp(a, b) > 0;
}

bool ge(void* a, void* b) {
    double x, y;
    if (bothFloats(a, b, x, y)) return x >= y;
    return cmp(a, b) >= 0;
}

// ============================================================================
// Append Operation
// ============================================================================

HPointer append(void* a, void* b) {
    // Two constants never get here: the export returns one of them itself.
    assert((a || b) && "Utils::append: both operands are constants; the export returns one of them");
    if (!a) return Allocator::instance().wrap(b);
    if (!b) return Allocator::instance().wrap(a);

    Tag tagA = getTag(a);
    Tag tagB = getTag(b);

    if (alloc::isString(a) && alloc::isString(b)) {
        return StringOps::append(a, b);
    }

    if (tagA == Tag_Cons || tagA == Tag_ConsChunk) {
        HPointer listA = Allocator::instance().wrap(a);
        HPointer listB = Allocator::instance().wrap(b);
        return ListOps::append(listA, listB);
    }

    // Elm's `++` takes only Strings and Lists, so a well-typed program does not reach this.
    return Allocator::instance().wrap(a);
}

} // namespace Elm::Kernel::Utils
