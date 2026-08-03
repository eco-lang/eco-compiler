//===- JsonExports.cpp - C-linkage exports for Json module -----------------===//
//
// Full JSON decoder/encoder implementation using nlohmann/json.
// JSON values are represented as heap-resident Custom objects using the
// JSON value ADT (CTOR_JSON_* ctors), not as foreign C++ pointers.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic ignored "-Wcovered-switch-default"
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wcovered-switch-default"
#endif
#include <nlohmann/json.hpp>
#if defined(__clang__)
#  pragma clang diagnostic pop
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif
#include <string>
#include <cstring>
#include <cassert>
#include <vector>
#include <algorithm>

using json = nlohmann::json;
using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

// Declare closure call
extern "C" HPtr eco_apply_closure(HPtr closure, uint64_t* args, uint32_t num_args);

//===----------------------------------------------------------------------===//
// JSON Value Heap ADT
//===----------------------------------------------------------------------===//

// Ctor tags for the heap-resident JSON value ADT.
// All use Tag_Custom with these ctor values.
static constexpr u16 CTOR_JSON_NULL   = 100;
static constexpr u16 CTOR_JSON_BOOL   = 101;  // 1 boxed field: True/False constant
static constexpr u16 CTOR_JSON_INT    = 102;  // 1 unboxed field: i64
static constexpr u16 CTOR_JSON_FLOAT  = 103;  // 1 unboxed field: f64
static constexpr u16 CTOR_JSON_STRING = 104;  // 1 boxed field: HPointer to ElmString
static constexpr u16 CTOR_JSON_ARRAY  = 105;  // 1 boxed field: HPointer to ElmArray
static constexpr u16 CTOR_JSON_OBJECT = 106;  // 1 boxed field: Elm List of (String, JsonValue) tuples

// Decoder ctor values
static constexpr u16 DEC_STRING = 0;
static constexpr u16 DEC_BOOL = 1;
static constexpr u16 DEC_INT = 2;
static constexpr u16 DEC_FLOAT = 3;
static constexpr u16 DEC_NULL = 4;
static constexpr u16 DEC_LIST = 5;
static constexpr u16 DEC_ARRAY = 6;
static constexpr u16 DEC_FIELD = 7;
static constexpr u16 DEC_INDEX = 8;
static constexpr u16 DEC_KEYVALUE = 9;
static constexpr u16 DEC_VALUE = 10;
static constexpr u16 DEC_SUCCEED = 11;
static constexpr u16 DEC_FAIL = 12;
static constexpr u16 DEC_ANDTHEN = 13;
static constexpr u16 DEC_ONEOF = 14;
static constexpr u16 DEC_MAP1 = 15;
static constexpr u16 DEC_MAP2 = 16;
static constexpr u16 DEC_MAP3 = 17;
static constexpr u16 DEC_MAP4 = 18;
static constexpr u16 DEC_MAP5 = 19;
static constexpr u16 DEC_MAP6 = 20;
static constexpr u16 DEC_MAP7 = 21;
static constexpr u16 DEC_MAP8 = 22;

// Encoder ctor values
static constexpr u16 ENC_NULL = 0;
static constexpr u16 ENC_BOOL = 1;
static constexpr u16 ENC_INT = 2;
static constexpr u16 ENC_FLOAT = 3;
static constexpr u16 ENC_STRING = 4;
static constexpr u16 ENC_ARRAY = 5;
static constexpr u16 ENC_OBJECT = 6;

//===----------------------------------------------------------------------===//
// Helper Functions
//===----------------------------------------------------------------------===//

// Create an Elm String from a C++ string (UTF-8 to UTF-16 conversion).
static HPointer allocElmString(const std::string& str) {
    return allocStringFromUTF8(str);
}

// Convert any Elm String form (leaf or slice) to a UTF-8 C++ string.
// Routes through StringOps::toStdString — the canonical interop path.
static std::string elmStringToStd(uint64_t strEnc) {
    HPointer h = Export::decode(strEnc);
    if (Elm::alloc::isEmptyString(h)) {
        return "";
    }

    void* ptr = Export::toPtr(strEnc);
    return Elm::StringOps::toStdString(ptr);
}

// Create Ok result. Roots `value` across the Custom allocate so callers may
// pass an HPointer captured before this call.
static uint64_t makeOk(HPointer value) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &value, sizeof(value));
    Custom* result = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&value, &roots[0], sizeof(value));
    result->header.size = 1;
    result->ctor = 0;  // Ok
    result->unboxed = 0;
    result->values[0].p = value;
    return Export::encode(Allocator::instance().wrap(result));
}


// Create Err result with a Json.Error.
static uint64_t makeErr(const std::string& message) {
    auto& allocator = Allocator::instance();

    HPointer msgStr = allocElmString(message);

    // Create Error.Failure message value (simplified).
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t failureRoots[1];
    std::memcpy(&failureRoots[0], &msgStr, sizeof(msgStr));
    Custom* failure = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, failureRoots, 1, 0x1));
    std::memcpy(&msgStr, &failureRoots[0], sizeof(msgStr));
    failure->header.size = 2;
    failure->ctor = 0;  // Failure ctor
    failure->unboxed = 0;
    failure->values[0].p = msgStr;     // message
    failure->values[1].p = listNil();  // context (empty)
    HPointer failureHP = allocator.wrap(failure);

    // Wrap in Err.
    size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t errRoots[1];
    std::memcpy(&errRoots[0], &failureHP, sizeof(failureHP));
    Custom* err = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, errRoots, 1, 0x1));
    std::memcpy(&failureHP, &errRoots[0], sizeof(failureHP));
    err->header.size = 1;
    err->ctor = 1;  // Err
    err->unboxed = 0;
    err->values[0].p = failureHP;

    return Export::encode(allocator.wrap(err));
}

// Check if a result is Ok.
static bool isOk(uint64_t result) {
    void* ptr = Export::toPtr(result);
    if (!ptr) return false;
    Custom* c = static_cast<Custom*>(ptr);
    return c->ctor == 0;
}

// Get value from Ok result.
static HPointer getOkValue(uint64_t result) {
    void* ptr = Export::toPtr(result);
    Custom* c = static_cast<Custom*>(ptr);
    return c->values[0].p;
}

//===----------------------------------------------------------------------===//
// JSON Value ADT - Construction Helpers
//===----------------------------------------------------------------------===//

// Create a heap-resident JSON null.
static HPointer makeJsonNull() {
    size_t size = sizeof(Custom);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    c->header.size = 0;
    c->ctor = CTOR_JSON_NULL;
    c->unboxed = 0;
    return Allocator::instance().wrap(c);
}

// Create a heap-resident JSON bool.
static HPointer makeJsonBool(bool b) {
    // No HPointer args (elmTrue/elmFalse return embedded constants).
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    c->header.size = 1;
    c->ctor = CTOR_JSON_BOOL;
    c->unboxed = 0;
    c->values[0].p = b ? elmTrue() : elmFalse();
    return Allocator::instance().wrap(c);
}

// Create a heap-resident JSON int.
static HPointer makeJsonInt(i64 val) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    c->header.size = 1;
    c->ctor = CTOR_JSON_INT;
    c->unboxed = 1;
    c->values[0].i = val;
    return Allocator::instance().wrap(c);
}

// Create a heap-resident JSON float.
static HPointer makeJsonFloat(f64 val) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    c->header.size = 1;
    c->ctor = CTOR_JSON_FLOAT;
    c->unboxed = 2;  // kind=Float at slot 0
    c->values[0].f = val;
    return Allocator::instance().wrap(c);
}

// Create a heap-resident JSON string.
static HPointer makeJsonString(HPointer elmStr) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &elmStr, sizeof(elmStr));
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&elmStr, &roots[0], sizeof(elmStr));
    c->header.size = 1;
    c->ctor = CTOR_JSON_STRING;
    c->unboxed = 0;
    c->values[0].p = elmStr;
    return Allocator::instance().wrap(c);
}

// Create a heap-resident JSON array from an ElmArray of JSON values.
static HPointer makeJsonArray(HPointer elmArray) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &elmArray, sizeof(elmArray));
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&elmArray, &roots[0], sizeof(elmArray));
    c->header.size = 1;
    c->ctor = CTOR_JSON_ARRAY;
    c->unboxed = 0;
    c->values[0].p = elmArray;
    return Allocator::instance().wrap(c);
}

// Create a heap-resident JSON object from an Elm List of (String, JsonValue) tuples.
static HPointer makeJsonObject(HPointer kvList) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &kvList, sizeof(kvList));
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&kvList, &roots[0], sizeof(kvList));
    c->header.size = 1;
    c->ctor = CTOR_JSON_OBJECT;
    c->unboxed = 0;
    c->values[0].p = kvList;
    return Allocator::instance().wrap(c);
}

//===----------------------------------------------------------------------===//
// JSON Value ADT - Query Helpers
//===----------------------------------------------------------------------===//

// Get the ctor tag of a heap-resident JSON value.
// Returns 0 for non-JSON-value inputs (e.g. embedded constants).
static u16 jsonValueCtor(uint64_t jvalEnc) {
    void* ptr = Export::toPtr(jvalEnc);
    if (!ptr) return 0;
    Custom* c = static_cast<Custom*>(ptr);
    return c->ctor;
}

//===----------------------------------------------------------------------===//
// jsonToHeap - Convert nlohmann::json to heap-resident JSON value ADT
//===----------------------------------------------------------------------===//

static HPointer jsonToHeap(const json& j) {
    auto& allocator = Allocator::instance();

    if (j.is_null()) {
        return makeJsonNull();
    }

    if (j.is_boolean()) {
        return makeJsonBool(j.get<bool>());
    }

    if (j.is_number_integer()) {
        return makeJsonInt(j.get<i64>());
    }

    if (j.is_number_float()) {
        return makeJsonFloat(j.get<f64>());
    }

    if (j.is_string()) {
        HPointer str = allocElmString(j.get<std::string>());
        return makeJsonString(str);
    }

    if (j.is_array()) {
        // Convert each element to heap, collecting HPointers.
        //
        // Each recursive `jsonToHeap` call is a GC point. We must keep
        // every previously-collected HPointer rooted so a GC inside the
        // loop body relocates them in-place. The previous push_back
        // pattern left already-pushed slots stale across subsequent
        // recursions and broke down on arrays of nontrivial size — the
        // STALE-hptr validator caught this in JsonRoundtrip*.elm.
        //
        // Approach: pre-fill a vector of size j.size() with Nil, then
        // register stack-root ranges over its contiguous buffer (chunked
        // into 64-slot pieces because StackRootRange's hpointer_mask is
        // a uint64_t bitfield indexed by `1ULL << i`, UB for i>=64).
        // The vector's data() pointer is stable since we don't grow.
        size_t n = j.size();
        std::vector<HPointer> elements(n, listNil());
        auto& rs = Allocator::instance().getRootSet();
        size_t saved = rs.stackRangePoint();
        for (size_t base = 0; base < n; base += 64) {
            size_t chunk = std::min<size_t>(64, n - base);
            uint64_t mask = (chunk == 64) ? ~uint64_t{0}
                                           : ((uint64_t{1} << chunk) - 1);
            rs.pushStackRootRange(elements.data() + base, chunk, mask);
        }

        size_t i = 0;
        for (const auto& elem : j) {
            elements[i++] = jsonToHeap(elem);
        }

        // Build ElmArray from collected (and still-rooted) HPointers.
        HPointer arr = arrayFromPointers(elements);
        rs.restoreStackRangePoint(saved);
        return makeJsonArray(arr);
    }

    if (j.is_object()) {
        // Build list of (key, value) tuples in reverse iteration order
        // so the final list preserves insertion order.
        std::vector<std::string> keys;
        for (auto it = j.begin(); it != j.end(); ++it) {
            keys.push_back(it.key());
        }

        HPointer kvList = listNil();
        HPointer keyStr = listNil();  // placeholder; assigned per-iteration
        // `kvList` accumulates across iterations and must survive every
        // alloc-capable call (allocElmString / jsonToHeap / tuple2 / cons).
        // `keyStr` is hoisted into a single rooted slot held outside the loop
        // so each iteration just rewrites the slot rather than push/pop a
        // fresh StackRootGuard.
        Elm::StackRootGuard objRoots(&kvList, &keyStr);
        for (auto it = keys.rbegin(); it != keys.rend(); ++it) {
            keyStr = allocElmString(*it);
            HPointer val = jsonToHeap(j[*it]);

            HPointer tup = tuple2(boxed(keyStr), boxed(val), 0);
            kvList = cons(boxed(tup), kvList, true);
        }

        return makeJsonObject(kvList);
    }

    // Fallback: null.
    return makeJsonNull();
}

//===----------------------------------------------------------------------===//
// heapJsonToNlohmann - Convert heap-resident JSON value ADT to nlohmann::json
//===----------------------------------------------------------------------===//

static json heapJsonToNlohmann(uint64_t jvalEnc) {
    auto& allocator = Allocator::instance();

    void* ptr = Export::toPtr(jvalEnc);
    if (!ptr) return json(nullptr);

    Header* hdr = static_cast<Header*>(ptr);
    if (hdr->tag != Tag_Custom) return json(nullptr);

    Custom* c = static_cast<Custom*>(ptr);

    switch (c->ctor) {
        case CTOR_JSON_NULL:
            return json(nullptr);

        case CTOR_JSON_BOOL: {
            HPointer boolVal = c->values[0].p;
            return json(boolValue(boolVal));
        }

        case CTOR_JSON_INT:
            return json(c->values[0].i);

        case CTOR_JSON_FLOAT:
            return json(c->values[0].f);

        case CTOR_JSON_STRING: {
            return json(elmStringToStd(Export::encode(c->values[0].p)));
        }

        case CTOR_JSON_ARRAY: {
            json arr = json::array();
            void* arrPtr = allocator.resolve(c->values[0].p);
            ElmArray* elmArr = static_cast<ElmArray*>(arrPtr);
            u32 len = elmArr->header.size;
            for (u32 i = 0; i < len; i++) {
                arr.push_back(heapJsonToNlohmann(Export::encode(elmArr->elements[i].p)));
            }
            return arr;
        }

        case CTOR_JSON_OBJECT: {
            json obj = json::object();
            for (alloc::ListCursor kv(c->values[0].p); !kv.done(); kv.next()) {
                void* tuplePtr = allocator.resolve(kv.current().p);
                Tuple2* tup = static_cast<Tuple2*>(tuplePtr);

                std::string key = elmStringToStd(Export::encode(tup->a.p));
                json val = heapJsonToNlohmann(Export::encode(tup->b.p));
                obj[key] = val;
            }
            return obj;
        }

        default:
            return json(nullptr);
    }
}

//===----------------------------------------------------------------------===//
// Decoder Creation Helpers
//===----------------------------------------------------------------------===//

static uint64_t makeDecoder0(u16 ctor) {
    size_t size = sizeof(Custom);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    dec->header.size = 0;
    dec->ctor = ctor;
    dec->unboxed = 0;
    return Export::encode(Allocator::instance().wrap(dec));
}

static uint64_t makeDecoder1(u16 ctor, uint64_t arg) {
    HPointer payload = Export::decode(arg);
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &payload, sizeof(payload));
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&payload, &roots[0], sizeof(payload));
    dec->header.size = 1;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = payload;
    return Export::encode(Allocator::instance().wrap(dec));
}

static uint64_t makeDecoder1i(u16 ctor, int64_t arg) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    dec->header.size = 1;
    dec->ctor = ctor;
    dec->unboxed = 1;
    dec->values[0].i = arg;
    return Export::encode(Allocator::instance().wrap(dec));
}

static uint64_t makeDecoder2(u16 ctor, uint64_t arg1, uint64_t arg2) {
    HPointer p0 = Export::decode(arg1);
    HPointer p1 = Export::decode(arg2);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[2];
    std::memcpy(&roots[0], &p0, sizeof(p0));
    std::memcpy(&roots[1], &p1, sizeof(p1));
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 2, 0x3));
    std::memcpy(&p0, &roots[0], sizeof(p0));
    std::memcpy(&p1, &roots[1], sizeof(p1));
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = p0;
    dec->values[1].p = p1;
    return Export::encode(Allocator::instance().wrap(dec));
}

static uint64_t makeDecoder2ip(u16 ctor, int64_t arg1, uint64_t arg2) {
    HPointer p1 = Export::decode(arg2);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    // arg1 is unboxed Int (slot 0); p1 is HPointer (slot 1). mask = 0b10 = 0x2.
    uint64_t roots[2] = { static_cast<uint64_t>(arg1), 0 };
    std::memcpy(&roots[1], &p1, sizeof(p1));
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 2, 0x2));
    std::memcpy(&p1, &roots[1], sizeof(p1));
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 1;  // first field unboxed
    dec->values[0].i = arg1;
    dec->values[1].p = p1;
    return Export::encode(Allocator::instance().wrap(dec));
}

//===----------------------------------------------------------------------===//
// Decoder Execution - operates on heap-resident JSON values
//===----------------------------------------------------------------------===//

// Run decoder on a heap-resident JSON value and return Result.
//
// Both `decoderHP` and the JSON value referenced by `jvalEnc` are rooted for
// the lifetime of the body so the GC keeps them valid across recursive
// `runDecoder` calls, closure invocations, and any other allocator activity.
// Raw `Custom*` for `decoder` / `jval` MUST be re-derived through the rooted
// handles after every potential GC point.
static uint64_t runDecoder(HPointer decoderHP, uint64_t jvalEnc) {
    auto& allocator = Allocator::instance();

    HPointer jvalHP = Export::decode(jvalEnc);
    StackRootGuard topRoots(&decoderHP, &jvalHP);

    // Helpers — always re-resolve after a potential GC.
    auto resolveDecoder = [&]() -> Custom* {
        return static_cast<Custom*>(allocator.resolve(decoderHP));
    };
    auto resolveJval = [&]() -> Custom* {
        if (jvalHP.ptr_ind != 0) return nullptr;
        void* p = allocator.resolve(jvalHP);
        if (!p) return nullptr;
        if (static_cast<Header*>(p)->tag != Tag_Custom) return nullptr;
        return static_cast<Custom*>(p);
    };

    Custom* decoder = resolveDecoder();
    Custom* jval = resolveJval();
    u16 jctor = jval ? jval->ctor : 0;

    switch (decoder->ctor) {
        case DEC_STRING: {
            if (!jval || jctor != CTOR_JSON_STRING) {
                return makeErr("Expecting a STRING");
            }
            // The string is already an ElmString on the heap.
            return makeOk(jval->values[0].p);
        }

        case DEC_BOOL: {
            if (!jval || jctor != CTOR_JSON_BOOL) {
                return makeErr("Expecting a BOOL");
            }
            return makeOk(jval->values[0].p);
        }

        case DEC_INT: {
            if (!jval || jctor != CTOR_JSON_INT) {
                return makeErr("Expecting an INT");
            }
            HPointer intVal = allocInt(jval->values[0].i);
            return makeOk(intVal);
        }

        case DEC_FLOAT: {
            // Accept both JSON int and JSON float as numbers.
            if (!jval || (jctor != CTOR_JSON_FLOAT && jctor != CTOR_JSON_INT)) {
                return makeErr("Expecting a FLOAT");
            }
            f64 d;
            if (jctor == CTOR_JSON_FLOAT) {
                d = jval->values[0].f;
            } else {
                d = static_cast<f64>(jval->values[0].i);
            }
            HPointer floatVal = allocFloat(d);
            return makeOk(floatVal);
        }

        case DEC_NULL: {
            if (!jval || jctor != CTOR_JSON_NULL) {
                return makeErr("Expecting null");
            }
            // `decoder` is still fresh here (no allocations between top-of-fn and now).
            HPointer fallback = decoder->values[0].p;
            // makeOk roots its argument internally.
            return makeOk(fallback);
        }

        case DEC_VALUE: {
            // Return the heap-resident JSON value directly.
            return makeOk(jvalHP);
        }

        case DEC_LIST: {
            if (!jval || jctor != CTOR_JSON_ARRAY) {
                return makeErr("Expecting a LIST");
            }

            // Get element decoder handle and infer cons-head kind. The kind
            // decision is made up-front on the *static* sub-decoder type, so a
            // brief raw-pointer use here (no GC point) is safe.
            HPointer elemDecHP = decoder->values[0].p;
            HPointer arrayHP   = jval->values[0].p;
            u8 elemConsKind = 0;  // 0 = boxed
            {
                Custom* elemDec0 = static_cast<Custom*>(allocator.resolve(elemDecHP));
                switch (elemDec0->ctor) {
                    case DEC_INT:   elemConsKind = 1; break;  // unboxed i64
                    case DEC_FLOAT: elemConsKind = 2; break;  // unboxed f64
                    default:        elemConsKind = 0; break;  // boxed HPointer
                }
            }

            // Get the ElmArray length (primitive snapshot).
            u32 len;
            {
                ElmArray* arr0 = static_cast<ElmArray*>(allocator.resolve(arrayHP));
                len = arr0->header.size;
            }

            // Chunks: decode in the SAME reverse order (failure semantics —
            // the error returned is the last failing index) but accumulate
            // on the GC-rooted scratch stack; eco_scratch_finish reverses,
            // so the logical order matches the cells path exactly, and the
            // whole result becomes a dense chunk chain instead of len cells.
            if (eco_g_list_chunks) {
                StackRootGuard decRoots(&arrayHP, &elemDecHP);
                int64_t mark = eco_scratch_mark();
                for (i64 i = static_cast<i64>(len) - 1; i >= 0; i--) {
                    ElmArray* arr =
                        static_cast<ElmArray*>(allocator.resolve(arrayHP));
                    uint64_t elemEnc = Export::encode(arr->elements[i].p);
                    uint64_t elemResult = runDecoder(elemDecHP, elemEnc);
                    if (!isOk(elemResult)) {
                        eco_scratch_abandon(mark);
                        return elemResult;
                    }
                    HPointer elemVal = getOkValue(elemResult);
                    if (elemConsKind == 1) {
                        ElmInt* ei = static_cast<ElmInt*>(
                            allocator.resolve(elemVal));
                        eco_scratch_push_scalar(
                            static_cast<uint64_t>(ei->value), 1);
                    } else if (elemConsKind == 2) {
                        ElmFloat* ef = static_cast<ElmFloat*>(
                            allocator.resolve(elemVal));
                        Unboxable fbits;
                        fbits.f = ef->value;
                        eco_scratch_push_scalar(
                            static_cast<uint64_t>(fbits.i), 2);
                    } else {
                        eco_scratch_push_boxed(
                            HPtr::fromBits(hpBits(elemVal)));
                    }
                }
                HPtr chunked = eco_scratch_finish(
                    mark, HPtr::fromBits(hpBits(listNil())), elemConsKind);
                return makeOk(chunked.toHPointer());
            }

            // Decode each element in reverse to build the list. `result` is
            // the accumulator; `arrayHP` and `elemDecHP` may be moved by GC
            // during the recursion or `cons`. Root all three.
            HPointer result = listNil();
            StackRootGuard listRoots(&result, &arrayHP, &elemDecHP);

            for (i64 i = static_cast<i64>(len) - 1; i >= 0; i--) {
                ElmArray* arr = static_cast<ElmArray*>(allocator.resolve(arrayHP));
                uint64_t elemEnc = Export::encode(arr->elements[i].p);

                uint64_t elemResult = runDecoder(elemDecHP, elemEnc);
                if (!isOk(elemResult)) {
                    return elemResult;
                }
                HPointer elemVal = getOkValue(elemResult);

                // Unwrap primitive wrappers so the Cons head holds the unboxed
                // value directly when the caller expects that representation.
                Unboxable headSlot;
                if (elemConsKind == 1) {
                    ElmInt* ei = static_cast<ElmInt*>(allocator.resolve(elemVal));
                    headSlot.i = ei->value;
                } else if (elemConsKind == 2) {
                    ElmFloat* ef = static_cast<ElmFloat*>(allocator.resolve(elemVal));
                    headSlot.f = ef->value;
                } else {
                    headSlot.p = elemVal;
                }
                // `cons` allocates; `result` is rooted via listRoots above.
                // For boxed heads the head HPointer must also stay valid.
                if (elemConsKind == 0) {
                    StackRootGuard headRoot(&headSlot.p);
                    result = cons(headSlot, result, /*head_kind=*/(u8)0);
                } else {
                    result = cons(headSlot, result, /*head_kind=*/elemConsKind);
                }
            }
            return makeOk(result);
        }

        case DEC_ARRAY: {
            if (!jval || jctor != CTOR_JSON_ARRAY) {
                return makeErr("Expecting an ARRAY");
            }

            // Snapshot the element decoder handle and source-array handle.
            HPointer elemDecHP = decoder->values[0].p;
            HPointer arrayHP   = jval->values[0].p;

            // Determine element kind from the element decoder (pure read,
            // pre-loop, no GC point yet).
            u8 elemKind = 0;  // 0=boxed, 1=Int, 2=Float, 3=Char
            {
                Custom* elemDec0 = static_cast<Custom*>(allocator.resolve(elemDecHP));
                switch (elemDec0->ctor) {
                    case DEC_INT:   elemKind = 1; break;
                    case DEC_FLOAT: elemKind = 2; break;
                    // DEC_STRING / composites stay boxed (kind 0)
                    default:        elemKind = 0; break;
                }
            }

            // Snapshot length (primitive).
            u32 len;
            {
                ElmArray* arr0 = static_cast<ElmArray*>(allocator.resolve(arrayHP));
                len = arr0->length;
            }

            // Decode each element, collecting result HPointers. The collected
            // vector is range-rooted so each subsequent recursive `runDecoder`
            // can't invalidate already-decoded entries. Because `push_back`
            // may reallocate the vector storage, we re-pin the buffer after
            // every push.
            std::vector<HPointer> elements;
            elements.reserve(len);

            auto& rs = allocator.getRootSet();
            size_t savedRoots = rs.stackRangePoint();
            rs.pushStackRootRange(&elemDecHP, 1, 1);
            rs.pushStackRootRange(&arrayHP,   1, 1);

            for (u32 i = 0; i < len; i++) {
                ElmArray* arr = static_cast<ElmArray*>(allocator.resolve(arrayHP));
                uint64_t elemEnc = Export::encode(arr->elements[i].p);

                uint64_t elemResult = runDecoder(elemDecHP, elemEnc);
                if (!isOk(elemResult)) {
                    rs.restoreStackRangePoint(savedRoots);
                    return elemResult;
                }
                elements.push_back(getOkValue(elemResult));

                // Re-pin: vector may have reallocated, invalidating the prior
                // base address.
                rs.restoreStackRangePoint(savedRoots);
                rs.pushStackRootRange(&elemDecHP, 1, 1);
                rs.pushStackRootRange(&arrayHP,   1, 1);
                rs.pushStackRootRange(elements.data(), elements.size(),
                                      /*hpointer_mask=*/~uint64_t(0));
            }

            // Build Elm `Array a` = `Array_elm_builtin Int Int (Tree a) (JsArray a)`.
            // Array_elm_builtin is the first (and only) ctor of `Array`, so
            // ctor index = 0. Fields:
            //   0: length      (Int, unboxed  → kind 01)
            //   1: startShift  (Int, unboxed  → kind 01)
            //   2: tree        (JsArray Node  → boxed HPointer)
            //   3: tail        (JsArray a     → boxed HPointer)
            // Unboxed bitmap (2 bits/slot): slot0=01, slot1=01, slot2=00, slot3=00 → 0b0101 = 0x5.
            auto buildElmArray = [&](HPointer tree_hp, HPointer tail_hp, u32 length) -> HPointer {
                size_t sz = sizeof(Custom) + 4 * sizeof(Unboxable);
                sz = (sz + 7) & ~7;

                // Pattern A: tree_hp + tail_hp are HPointer fields at slots
                // 2 and 3. Pack length and 5 (Int slots) into roots[0,1]
                // alongside; mask = 0b1100 = 0xC roots only the HPointer
                // slots.
                uint64_t roots[4] = {
                    static_cast<uint64_t>(length),
                    5,
                    0,
                    0,
                };
                std::memcpy(&roots[2], &tree_hp, sizeof(tree_hp));
                std::memcpy(&roots[3], &tail_hp, sizeof(tail_hp));

                Custom* c = static_cast<Custom*>(
                    eco_alloc_with_roots(Tag_Custom, sz, roots, 4, 0xC));
                c->ctor = 0;       // Array_elm_builtin
                c->unboxed = 0x5;  // field 0 and 1 are unboxed Int
                c->values[0].i = static_cast<i64>(roots[0]);
                c->values[1].i = static_cast<i64>(roots[1]);
                std::memcpy(&c->values[2].p, &roots[2], sizeof(HPointer));
                std::memcpy(&c->values[3].p, &roots[3], sizeof(HPointer));
                return Allocator::instance().wrap(c);
            };

            // Helper: allocate a JsArray of a given uniform kind and length,
            // initialized from `elements[start..start+count)`. For boxed kind
            // (0) elements are HPointers; for unboxed kinds the decoded values
            // are boxed primitives and we unbox them into the element slot.
            auto buildJsArray = [&](size_t start, size_t count, u8 kind) -> HPointer {
                // Root the element HPointers across the allocation.
                std::vector<HPointer> rooted(elements.begin() + start,
                                              elements.begin() + start + count);
                auto& rs = Allocator::instance().getRootSet();
                size_t saved = rs.stackRangePoint();
                for (auto& hp : rooted) rs.pushStackRootRange(&hp, 1, 1);

                HPointer jsArr = alloc::allocArray(count);
                auto& allocLocal = Allocator::instance();
                for (size_t i = 0; i < count; ++i) {
                    void* arrObj = allocLocal.resolve(jsArr);
                    if (kind == 1) {
                        ElmInt* ei = static_cast<ElmInt*>(allocLocal.resolve(rooted[i]));
                        Unboxable u; u.i = ei->value;
                        alloc::arrayPushKind(arrObj, u, 1);
                    } else if (kind == 2) {
                        ElmFloat* ef = static_cast<ElmFloat*>(allocLocal.resolve(rooted[i]));
                        Unboxable u; u.f = ef->value;
                        alloc::arrayPushKind(arrObj, u, 2);
                    } else {
                        Unboxable u; u.p = rooted[i];
                        alloc::arrayPush(arrObj, u, true);
                    }
                }
                rs.restoreStackRangePoint(saved);
                return jsArr;
            };

            // Replicate Array.fromList's layout: partition into fixed-size
            // leaves (branchFactor = 32) with a remainder tail. For small
            // arrays (len < 32) the tree is empty and everything lives in tail.
            constexpr u32 kBranch = 32;
            u32 tailStart = (len / kBranch) * kBranch;
            u32 tailLen = len - tailStart;

            // Build the tail JsArray (can be empty for len multiple of 32).
            HPointer tailJsArr = buildJsArray(tailStart, tailLen, elemKind);

            // Build leaf Nodes and the tree JsArray. For len < 32 the tree
            // is empty (alloc::allocArray(0)). Root the tail across leaf /
            // node / tree allocations.
            HPointer treeJsArr;
            {
                auto& rs = Allocator::instance().getRootSet();
                size_t saved = rs.stackRangePoint();
                HPointer tailRoot = tailJsArr;
                rs.pushStackRootRange(&tailRoot, 1, 1);

                u32 numLeaves = tailStart / kBranch;
                std::vector<HPointer> leafNodes;
                leafNodes.reserve(numLeaves);
                for (u32 k = 0; k < numLeaves; ++k) {
                    // Root prior leaves across this leaf's allocations.
                    for (auto& hp : leafNodes) rs.pushStackRootRange(&hp, 1, 1);

                    HPointer leafJsArr = buildJsArray(k * kBranch, kBranch, elemKind);

                    // Build `Leaf (JsArray a)` Custom. In Array.elm's Node type,
                    // `SubTree` is ctor 0 and `Leaf` is ctor 1 (declaration order).
                    size_t sz = sizeof(Custom) + 1 * sizeof(Unboxable);
                    sz = (sz + 7) & ~7;

                    uint64_t roots[1];
                    std::memcpy(&roots[0], &leafJsArr, sizeof(leafJsArr));
                    Custom* node = static_cast<Custom*>(
                        eco_alloc_with_roots(Tag_Custom, sz, roots, 1, 0x1));
                    std::memcpy(&leafJsArr, &roots[0], sizeof(leafJsArr));
                    node->ctor = 1;      // Leaf
                    node->unboxed = 0;
                    node->values[0].p = leafJsArr;
                    leafNodes.push_back(Allocator::instance().wrap(node));

                    rs.restoreStackRangePoint(saved);
                    rs.pushStackRootRange(&tailRoot, 1, 1);
                }

                // Build the tree as a JsArray of leaf Nodes (boxed, kind 0).
                for (auto& hp : leafNodes) rs.pushStackRootRange(&hp, 1, 1);
                treeJsArr = alloc::allocArray(numLeaves);
                void* tObj = Allocator::instance().resolve(treeJsArr);
                for (u32 k = 0; k < numLeaves; ++k) {
                    Unboxable u; u.p = leafNodes[k];
                    alloc::arrayPush(tObj, u, true);
                    tObj = Allocator::instance().resolve(treeJsArr);
                }

                // Update tailJsArr from the root in case GC moved it.
                tailJsArr = tailRoot;
                rs.restoreStackRangePoint(saved);
            }

            HPointer resultArr = buildElmArray(treeJsArr, tailJsArr, len);
            rs.restoreStackRangePoint(savedRoots);
            return makeOk(resultArr);
        }

        case DEC_FIELD: {
            if (!jval || jctor != CTOR_JSON_OBJECT) {
                return makeErr("Expecting an OBJECT");
            }

            // Snapshot the field name (std::string copy, GC-immune) and the
            // nested decoder handle. `elmStringToStd` may walk a slice or
            // rope but does not allocate.
            std::string fieldName =
                elmStringToStd(Export::encode(decoder->values[0].p));
            HPointer nestedDecHP = decoder->values[1].p;

            // Walk the key/value list (hybrid spines: RootedListCursor keeps
            // the spine node rooted and re-resolves per element).
            // `nestedDecHP` survives into the recursive `runDecoder` call.
            StackRootGuard fieldRoots(&nestedDecHP);
            alloc::RootedListCursor kv(jval->values[0].p);
            Unboxable kvHead;
            u8 kvKind;

            while (kv.read(kvHead, kvKind)) {
                Tuple2* tup = static_cast<Tuple2*>(allocator.resolve(kvHead.p));
                HPointer keyHP = tup->a.p;
                HPointer valHP = tup->b.p;

                std::string key = elmStringToStd(Export::encode(keyHP));
                if (key == fieldName) {
                    return runDecoder(nestedDecHP, Export::encode(valHP));
                }

                kv.advance();
            }

            return makeErr("Expecting an OBJECT with a field named `" + fieldName + "`");
        }

        case DEC_INDEX: {
            if (!jval || jctor != CTOR_JSON_ARRAY) {
                return makeErr("Expecting an ARRAY");
            }

            int64_t index = decoder->values[0].i;
            HPointer nestedDecHP = decoder->values[1].p;
            HPointer arrayHP = jval->values[0].p;

            ElmArray* arr = static_cast<ElmArray*>(allocator.resolve(arrayHP));
            if (index < 0 || static_cast<u32>(index) >= arr->header.size) {
                return makeErr("Expecting a LONGER array");
            }

            uint64_t elemEnc = Export::encode(arr->elements[index].p);
            return runDecoder(nestedDecHP, elemEnc);
        }

        case DEC_KEYVALUE: {
            if (!jval || jctor != CTOR_JSON_OBJECT) {
                return makeErr("Expecting an OBJECT");
            }

            // Snapshot the value-decoder handle and infer the unboxed kind for
            // the tuple's value slot up front (no GC point in this block).
            HPointer valDecHP = decoder->values[0].p;
            u8 valKind;
            {
                Custom* valDec0 = static_cast<Custom*>(allocator.resolve(valDecHP));
                switch (valDec0->ctor) {
                    case DEC_INT:   valKind = 1; break;  // unboxed i64
                    case DEC_FLOAT: valKind = 2; break;  // unboxed f64
                    default:        valKind = 0; break;  // boxed HPointer
                }
            }
            u64 tupleBitmap = static_cast<u64>(valKind) << 2;

            // Collect key/value tuple HPointers into a buffer (no allocations
            // here; safe to walk with raw pointers if we re-resolve cell on
            // each iteration).
            std::vector<HPointer> tuples;
            for (alloc::ListCursor kv(jval->values[0].p); !kv.done(); kv.next()) {
                tuples.push_back(kv.current().p);
            }

            // Build the result list in reverse. Pin `result`, `valDecHP`,
            // `keyStr`, and the `tuples` buffer across each `runDecoder`
            // (which may GC) and each `cons` / `tuple2` (which allocate).
            HPointer result = listNil();
            // `keyStr` is hoisted into the base roots so it's rooted once
            // and reassigned per iteration, instead of paying for a
            // per-iter pushStackRootRange/restore.
            HPointer keyStr = listNil();

            auto& rs = allocator.getRootSet();
            size_t kvSaved = rs.stackRangePoint();

            // StackRootRange::hpointer_mask is a uint64_t indexed by
            // `1ULL << i` — UB for `i >= 64`, so a single range with
            // mask=~0 only covers slots 0-63. Dicts with > 64 entries
            // need chunked ranges; otherwise tuples[64..] go stale across
            // recursive runDecoder calls.
            auto pushBaseRoots = [&]() {
                rs.pushStackRootRange(&result,    1, 1);
                rs.pushStackRootRange(&valDecHP,  1, 1);
                rs.pushStackRootRange(&keyStr,    1, 1);
                for (size_t base = 0; base < tuples.size(); base += 64) {
                    size_t chunk = std::min<size_t>(64, tuples.size() - base);
                    uint64_t mask = (chunk == 64) ? ~uint64_t{0}
                                                   : ((uint64_t{1} << chunk) - 1);
                    rs.pushStackRootRange(tuples.data() + base, chunk, mask);
                }
            };
            pushBaseRoots();

            for (auto it = tuples.rbegin(); it != tuples.rend(); ++it) {
                Tuple2* srcTup = static_cast<Tuple2*>(allocator.resolve(*it));
                uint64_t valEnc = Export::encode(srcTup->b.p);
                keyStr = srcTup->a.p;

                uint64_t valResult = runDecoder(valDecHP, valEnc);
                if (!isOk(valResult)) {
                    rs.restoreStackRangePoint(kvSaved);
                    return valResult;
                }

                HPointer decodedVal = getOkValue(valResult);

                Unboxable valSlot;
                if (valKind == 1) {
                    ElmInt* ei = static_cast<ElmInt*>(allocator.resolve(decodedVal));
                    valSlot.i = ei->value;
                } else if (valKind == 2) {
                    ElmFloat* ef = static_cast<ElmFloat*>(allocator.resolve(decodedVal));
                    valSlot.f = ef->value;
                } else {
                    valSlot.p = decodedVal;
                }

                // Root the (possibly heap-pointer) value slot across `tuple2`.
                if (valKind == 0) rs.pushStackRootRange(&valSlot.p, 1, 1);
                HPointer resTup = tuple2(boxed(keyStr), valSlot, tupleBitmap);
                if (valKind == 0) {
                    rs.restoreStackRangePoint(kvSaved);
                    pushBaseRoots();
                }

                rs.pushStackRootRange(&resTup, 1, 1);
                result = cons(boxed(resTup), result, true);
                // Pop the `resTup` and `keyStr` roots now that result owns them.
                rs.restoreStackRangePoint(kvSaved);
                pushBaseRoots();
            }
            rs.restoreStackRangePoint(kvSaved);
            return makeOk(result);
        }

        case DEC_SUCCEED: {
            return makeOk(decoder->values[0].p);
        }

        case DEC_FAIL: {
            std::string msg = elmStringToStd(Export::encode(decoder->values[0].p));
            return makeErr(msg);
        }

        case DEC_ANDTHEN: {
            // Snapshot inner decoder + callback handles before any recursion.
            HPointer innerDecHP = decoder->values[1].p;
            HPointer callbackHP = decoder->values[0].p;

            // Root callback (and our own jvalHP, already top-rooted) across
            // the inner runDecoder.
            uint64_t innerResult;
            {
                StackRootGuard guard(&callbackHP);
                innerResult = runDecoder(innerDecHP, jvalEnc);
            }
            if (!isOk(innerResult)) return innerResult;

            HPointer value = getOkValue(innerResult);
            HPointer newDecHP;
            {
                // Root callback + decoded value + new-decoder slot across the
                // closure call. eco_apply_closure may GC.
                StackRootGuard guard(&callbackHP, &value);
                uint64_t args[1] = { Export::encode(value) };
                uint64_t newDecEnc = eco_apply_closure(
                    HPtr::fromBits(Export::encode(callbackHP)), args, 1).toBits();
                newDecHP = Export::decode(newDecEnc);
            }

            return runDecoder(newDecHP, jvalEnc);
        }

        case DEC_ONEOF: {
            // RootedListCursor keeps the spine node rooted and re-resolves
            // fresh on every read/advance, so the recursive runDecoder GC
            // points are safe (hybrid spines: cells + chunk views).
            alloc::RootedListCursor decs(decoder->values[0].p);
            Unboxable decHead;
            u8 decKind;

            while (decs.read(decHead, decKind)) {
                uint64_t result = runDecoder(decHead.p, jvalEnc);
                if (isOk(result)) {
                    return result;
                }
                decs.advance();
            }

            return makeErr("Ran into a oneOf with no possibilities");
        }

        case DEC_MAP1: {
            HPointer dec1HP = decoder->values[1].p;
            HPointer callbackHP = decoder->values[0].p;

            uint64_t result1;
            {
                // Root dec1HP too: the recursive runDecoder doesn't update
                // *our* by-value `dec1HP`, but if its return path passes
                // back via makeOk that's a fresh HPointer; the trouble was
                // an unrooted `callbackHP` was the only declared root —
                // any nursery dec/callback objects allocated mid-decode
                // could otherwise leave a separate stale local. Mirrors
                // DEC_MAP2..DEC_MAP4 patterns.
                StackRootGuard guard(&dec1HP, &callbackHP);
                result1 = runDecoder(dec1HP, jvalEnc);
            }
            if (!isOk(result1)) return result1;

            HPointer v1 = getOkValue(result1);
            uint64_t mapped;
            {
                StackRootGuard guard(&callbackHP, &v1);
                uint64_t args[1] = { Export::encode(v1) };
                mapped = eco_apply_closure(
                    HPtr::fromBits(Export::encode(callbackHP)), args, 1).toBits();
            }
            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP2: {
            HPointer dec1HP = decoder->values[1].p;
            HPointer dec2HP = decoder->values[2].p;
            HPointer callbackHP = decoder->values[0].p;

            uint64_t result1;
            {
                StackRootGuard guard(&dec2HP, &callbackHP);
                result1 = runDecoder(dec1HP, jvalEnc);
            }
            if (!isOk(result1)) return result1;

            HPointer v1 = getOkValue(result1);
            uint64_t result2;
            {
                StackRootGuard guard(&v1, &callbackHP);
                result2 = runDecoder(dec2HP, jvalEnc);
            }
            if (!isOk(result2)) return result2;

            HPointer v2 = getOkValue(result2);
            uint64_t mapped;
            {
                StackRootGuard guard(&v1, &v2, &callbackHP);
                uint64_t args[2] = { Export::encode(v1), Export::encode(v2) };
                mapped = eco_apply_closure(
                    HPtr::fromBits(Export::encode(callbackHP)), args, 2).toBits();
            }
            return makeOk(Export::decode(mapped));
        }

        // Generic mapN for 3-8 decoders.
        case DEC_MAP3:
        case DEC_MAP4:
        case DEC_MAP5:
        case DEC_MAP6:
        case DEC_MAP7:
        case DEC_MAP8: {
            int n = decoder->ctor - DEC_MAP1 + 1;

            // Snapshot the callback and all sub-decoder handles up front.
            HPointer callbackHP = decoder->values[0].p;
            std::vector<HPointer> subDecHPs;
            subDecHPs.reserve(n);
            for (int i = 0; i < n; i++) {
                subDecHPs.push_back(decoder->values[i + 1].p);
            }

            // `results` accumulates fresh HPointer-encoded ok-values; the
            // buffer must be range-rooted because each subsequent runDecoder
            // may GC and invalidate previously-decoded entries.
            std::vector<HPointer> results;
            results.reserve(n);

            auto& rs = allocator.getRootSet();
            size_t mapSaved = rs.stackRangePoint();
            rs.pushStackRootRange(&callbackHP, 1, 1);
            if (!subDecHPs.empty()) {
                rs.pushStackRootRange(subDecHPs.data(), subDecHPs.size(),
                                      /*hpointer_mask=*/~uint64_t(0));
            }

            for (int i = 0; i < n; i++) {
                uint64_t r = runDecoder(subDecHPs[i], jvalEnc);
                if (!isOk(r)) {
                    rs.restoreStackRangePoint(mapSaved);
                    return r;
                }
                results.push_back(getOkValue(r));

                // Re-pin every range — `results` may have reallocated.
                rs.restoreStackRangePoint(mapSaved);
                rs.pushStackRootRange(&callbackHP, 1, 1);
                if (!subDecHPs.empty()) {
                    rs.pushStackRootRange(subDecHPs.data(), subDecHPs.size(),
                                          /*hpointer_mask=*/~uint64_t(0));
                }
                rs.pushStackRootRange(results.data(), results.size(),
                                      /*hpointer_mask=*/~uint64_t(0));
            }

            uint64_t args[8];
            for (int i = 0; i < n; i++) {
                args[i] = Export::encode(results[i]);
            }
            uint64_t mapped = eco_apply_closure(
                HPtr::fromBits(Export::encode(callbackHP)), args, static_cast<u32>(n)).toBits();
            rs.restoreStackRangePoint(mapSaved);
            return makeOk(Export::decode(mapped));
        }

        default:
            return makeErr("Unknown decoder type");
    }
}

//===----------------------------------------------------------------------===//
// Encoding Helper
//===----------------------------------------------------------------------===//

// Convert Elm encoder value to nlohmann::json.
static json elmToJson(uint64_t valueEnc) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(valueEnc);

    // Embedded constants do not normally reach the recursive encoder — every
    // Json.Encode primitive is boxed into an ENC_* Custom node first (see
    // Elm_Kernel_Json_wrap; empty array/object/null are ENC_* nodes too). Handle
    // any that arrive defensively: a Bool constant -> its JSON bool; anything
    // else -> null. This is merge-ready (no dependence on which empty). Plan P0.5.
    if (isConstantBits(valueEnc)) {
        if (isBoolConst(h)) return json(boolValue(h));
        return json(nullptr);
    }

    void* ptr = Export::toPtr(valueEnc);
    if (!ptr) return json(nullptr);

    Header* header = static_cast<Header*>(ptr);

    if (header->tag == Tag_Custom) {
        Custom* c = static_cast<Custom*>(ptr);

        switch (c->ctor) {
            case ENC_NULL:
                return json(nullptr);

            case ENC_BOOL: {
                HPointer boolVal = c->values[0].p;
                return json(boolValue(boolVal));
            }

            case ENC_INT:
                return json(c->values[0].i);

            case ENC_FLOAT:
                return json(c->values[0].f);

            case ENC_STRING:
                return json(elmStringToStd(Export::encode(c->values[0].p)));

            case ENC_ARRAY: {
                // The internal list is in reverse order because List.foldl + cons
                // prepends each element. Collect and reverse to restore original order.
                std::vector<json> elements;
                for (alloc::ListCursor l(c->values[0].p); !l.done(); l.next()) {
                    elements.push_back(elmToJson(Export::encode(l.current().p)));
                }
                std::reverse(elements.begin(), elements.end());
                return json(elements);
            }

            case ENC_OBJECT: {
                json obj = json::object();
                for (alloc::ListCursor l(c->values[0].p); !l.done(); l.next()) {
                    void* tuplePtr = allocator.resolve(l.current().p);
                    Tuple2* tuple = static_cast<Tuple2*>(tuplePtr);

                    std::string key = elmStringToStd(Export::encode(tuple->a.p));
                    json val = elmToJson(Export::encode(tuple->b.p));
                    obj[key] = val;
                }
                return obj;
            }

            // Heap-resident JSON value ADT: convert back to nlohmann::json.
            case CTOR_JSON_NULL:
            case CTOR_JSON_BOOL:
            case CTOR_JSON_INT:
            case CTOR_JSON_FLOAT:
            case CTOR_JSON_STRING:
            case CTOR_JSON_ARRAY:
            case CTOR_JSON_OBJECT:
                return heapJsonToNlohmann(valueEnc);

            default:
                break;
        }
    }

    // Check for primitives.
    if (header->tag == Tag_Int) {
        ElmInt* i = static_cast<ElmInt*>(ptr);
        return json(i->value);
    }

    if (header->tag == Tag_Float) {
        ElmFloat* f = static_cast<ElmFloat*>(ptr);
        return json(f->value);
    }

    // Any string form: flat leaf, slice, rope, or large-block header.
    if (isString(ptr)) {
        return json(elmStringToStd(valueEnc));
    }

    return json(nullptr);
}

//===----------------------------------------------------------------------===//
// Extern C Functions
//===----------------------------------------------------------------------===//

extern "C" {

//===----------------------------------------------------------------------===//
// Primitive Decoders
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_decodeString() {
    return HPtr::fromBits(makeDecoder0(DEC_STRING));
}

HPtr Elm_Kernel_Json_decodeBool() {
    return HPtr::fromBits(makeDecoder0(DEC_BOOL));
}

HPtr Elm_Kernel_Json_decodeInt() {
    return HPtr::fromBits(makeDecoder0(DEC_INT));
}

HPtr Elm_Kernel_Json_decodeFloat() {
    return HPtr::fromBits(makeDecoder0(DEC_FLOAT));
}

HPtr Elm_Kernel_Json_decodeNull(HPtr fallback) {
    return HPtr::fromBits(makeDecoder1(DEC_NULL, fallback.toBits()));
}

HPtr Elm_Kernel_Json_decodeList(HPtr decoder) {
    return HPtr::fromBits(makeDecoder1(DEC_LIST, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeArray(HPtr decoder) {
    return HPtr::fromBits(makeDecoder1(DEC_ARRAY, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeField(HPtr fieldName, HPtr decoder) {
    return HPtr::fromBits(makeDecoder2(DEC_FIELD, fieldName.toBits(), decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeIndex(int64_t index, HPtr decoder) {
    return HPtr::fromBits(makeDecoder2ip(DEC_INDEX, index, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeKeyValuePairs(HPtr decoder) {
    return HPtr::fromBits(makeDecoder1(DEC_KEYVALUE, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeValue() {
    return HPtr::fromBits(makeDecoder0(DEC_VALUE));
}

//===----------------------------------------------------------------------===//
// Decoder Combinators
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_succeed(HPtr value) {
    return HPtr::fromBits(makeDecoder1(DEC_SUCCEED, value.toBits()));
}

HPtr Elm_Kernel_Json_fail(HPtr message) {
    return HPtr::fromBits(makeDecoder1(DEC_FAIL, message.toBits()));
}

HPtr Elm_Kernel_Json_andThen(HPtr closure, HPtr decoder) {
    return HPtr::fromBits(makeDecoder2(DEC_ANDTHEN, closure.toBits(), decoder.toBits()));
}

HPtr Elm_Kernel_Json_oneOf(HPtr decoders) {
    return HPtr::fromBits(makeDecoder1(DEC_ONEOF, decoders.toBits()));
}

//===----------------------------------------------------------------------===//
// Map Functions
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_map1(HPtr closure, HPtr d1) {
    return HPtr::fromBits(makeDecoder2(DEC_MAP1, closure.toBits(), d1.toBits()));
}

// Pre-decode every input handle and pass them as roots to the helper.
// `nFields` includes the closure and all decoder slots.
static uint64_t buildMapDecoder(u16 ctor, u32 nFields, std::initializer_list<uint64_t> args) {
    // All args are HPointers (closure + N decoders).
    std::vector<uint64_t> roots;
    roots.reserve(args.size());
    for (uint64_t a : args) {
        HPointer hp = Export::decode(a);
        uint64_t b;
        std::memcpy(&b, &hp, sizeof(b));
        roots.push_back(b);
    }

    size_t size = sizeof(Custom) + nFields * sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t mask = (roots.size() >= 64) ? ~uint64_t{0}
                                         : ((uint64_t{1} << roots.size()) - 1);
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots.data(),
                             static_cast<uint32_t>(roots.size()), mask));
    dec->header.size = nFields;
    dec->ctor = ctor;
    dec->unboxed = 0;
    for (size_t i = 0; i < roots.size(); ++i) {
        std::memcpy(&dec->values[i].p, &roots[i], sizeof(HPointer));
    }
    return Export::encode(Allocator::instance().wrap(dec));
}

HPtr Elm_Kernel_Json_map2(HPtr closure, HPtr d1, HPtr d2) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP2, 3,
        { closure.toBits(), d1.toBits(), d2.toBits() }));
}

HPtr Elm_Kernel_Json_map3(HPtr closure, HPtr d1, HPtr d2, HPtr d3) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP3, 4,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits() }));
}

HPtr Elm_Kernel_Json_map4(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP4, 5,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits() }));
}

HPtr Elm_Kernel_Json_map5(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP5, 6,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits() }));
}

HPtr Elm_Kernel_Json_map6(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP6, 7,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits(), d6.toBits() }));
}

HPtr Elm_Kernel_Json_map7(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP7, 8,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits(), d6.toBits(), d7.toBits() }));
}

HPtr Elm_Kernel_Json_map8(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7, HPtr d8) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP8, 9,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits(), d6.toBits(), d7.toBits(), d8.toBits() }));
}

//===----------------------------------------------------------------------===//
// Running Decoders
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_run(HPtr decoder, HPtr value) {
    // Value is a heap-resident JSON value (CTOR_JSON_* Custom).
    HPointer decoderHP = Export::decode(decoder.toBits());
    if (decoderHP.ptr_ind != 0 ||
        !Allocator::instance().resolve(decoderHP)) {
        return HPtr::fromBits(makeErr("Invalid decoder"));
    }
    return HPtr::fromBits(runDecoder(decoderHP, value.toBits()));
}

HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString) {
    uint64_t jsonStringEnc = jsonString.toBits();
    std::string str = elmStringToStd(jsonStringEnc);

    try {
        json jval = json::parse(str);

        // Convert the parsed JSON tree to heap-resident objects. `jsonToHeap`
        // allocates; the decoder handle must be rooted across that.
        HPointer decoderHP = Export::decode(decoder.toBits());
        HPointer heapJson;
        {
            StackRootGuard guard(&decoderHP);
            heapJson = jsonToHeap(jval);
        }

        return HPtr::fromBits(runDecoder(decoderHP, Export::encode(heapJson)));
    } catch (const json::parse_error& e) {
        return HPtr::fromBits(makeErr(std::string("Problem with the given value:\n\n") + e.what()));
    }
}

//===----------------------------------------------------------------------===//
// Encoding
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_encode(int64_t indent, HPtr value) {
    uint64_t valueEnc = value.toBits();
    json j = elmToJson(valueEnc);
    std::string str;
    if (indent > 0) {
        str = j.dump(static_cast<int>(indent));
    } else {
        str = j.dump();
    }
    HPointer result = allocElmString(str);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_Json_wrap(HPtr value) {
    uint64_t valueEnc = value.toBits();
    // Wrap a boxed Elm value into an encoder Custom object for elmToJson.
    // Called with AllBoxed ABI: the compiler auto-boxes primitives (i64→ElmInt,
    // f64→ElmFloat) before calling, so we always receive an HPointer.
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(valueEnc);

    // Embedded constant booleans → ENC_BOOL (store the Bool constant verbatim).
    if (isBoolConst(h)) {
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_BOOL;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // Embedded empty-string constant → ENC_STRING wrapping the constant. This is
    // the only empty that reaches wrap in well-typed use (Json.Encode.string "").
    // Post-merge isEmptyString matches the merged empty; the Bool check above
    // has already peeled off True/False, so this only sees the empty string.
    if (isEmptyString(h)) {
        // h is an embedded constant: stable across GC, no rooting needed.
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_STRING;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // Any other embedded constant is not a valid Json.Encode primitive argument
    // (defensive) → ENC_NULL.
    if (isConstantBits(valueEnc)) {
        return Elm_Kernel_Json_encodeNull();
    }

    void* ptr = Export::toPtr(valueEnc);
    if (!ptr) return Elm_Kernel_Json_encodeNull();

    Header* header = static_cast<Header*>(ptr);

    if (header->tag == Tag_Int) {
        // Snapshot the unboxed int before any allocation may move the source.
        int64_t intVal = static_cast<ElmInt*>(ptr)->value;
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_INT;
        enc->unboxed = 1;
        enc->values[0].i = intVal;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    if (header->tag == Tag_Float) {
        // Snapshot the unboxed float before any allocation may move the source.
        double floatVal = static_cast<ElmFloat*>(ptr)->value;
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_FLOAT;
        enc->unboxed = 2;  // kind=Float at slot 0
        enc->values[0].f = floatVal;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // Any string form: flat leaf, slice, rope, or large-block header.
    // Checking Tag_String alone misroutes ropes/slices/large strings (built
    // by String.repeat / concatenation above the leaf size classes) into the
    // "already an encoder" fallthrough, which elmToJson then renders as null.
    if (isString(ptr)) {
        // Pattern A: h is the only HPointer field.
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        uint64_t roots[1];
        std::memcpy(&roots[0], &h, sizeof(h));
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
        std::memcpy(&h, &roots[0], sizeof(h));
        enc->header.size = 1;
        enc->ctor = ENC_STRING;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // Already an encoder Custom (ENC_OBJECT, ENC_ARRAY, etc.) — return as-is.
    return value;
}

// Phase C per-instance variants. Each takes a typed primitive directly and
// builds the corresponding ENC_INT / ENC_FLOAT / ENC_INT (Char as code point)
// encoder Custom without first going through a heap-resident ElmInt /
// ElmFloat wrapper.
HPtr Elm_Kernel_Json_wrap_Int(int64_t value) {
    auto& allocator = Allocator::instance();
    size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_INT;
    enc->unboxed = 1;  // kind=Int at slot 0
    enc->values[0].i = value;
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

HPtr Elm_Kernel_Json_wrap_Float(double value) {
    auto& allocator = Allocator::instance();
    size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_FLOAT;
    enc->unboxed = 2;  // kind=Float at slot 0
    enc->values[0].f = value;
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

HPtr Elm_Kernel_Json_wrap_Char(uint16_t value) {
    // Char is a Unicode code point. JSON has no native char type; encode as
    // an integer code point (matches what `Json.Encode.int (Char.toCode c)`
    // would produce). This branch is rare in practice — Json.Encode has no
    // public Char encoder — but is reachable via polymorphic uses.
    auto& allocator = Allocator::instance();
    size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_INT;
    enc->unboxed = 1;
    enc->values[0].i = static_cast<int64_t>(value);
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

HPtr Elm_Kernel_Json_encodeNull() {
    size_t size = sizeof(Custom);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 0;
    enc->ctor = ENC_NULL;
    enc->unboxed = 0;
    return HPtr::fromBits(Export::encode(Allocator::instance().wrap(enc)));
}

HPtr Elm_Kernel_Json_emptyArray() {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_ARRAY;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return HPtr::fromBits(Export::encode(Allocator::instance().wrap(enc)));
}

HPtr Elm_Kernel_Json_emptyObject() {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return HPtr::fromBits(Export::encode(Allocator::instance().wrap(enc)));
}

HPtr Elm_Kernel_Json_addEntry(HPtr func, HPtr entry, HPtr array) {
    auto& allocator = Allocator::instance();

    // Call the encoder function on the entry: encoded = func(entry).
    // The closure call is a GC point; re-resolve everything afterwards through
    // rooted handles.
    HPointer arrayHP = Export::decode(array.toBits());
    HPointer encodedHP;
    {
        StackRootGuard guard(&arrayHP);
        uint64_t args[] = { entry.toBits() };
        uint64_t encoded = eco_apply_closure(func, args, 1).toBits();
        encodedHP = Export::decode(encoded);
    }

    // Build the new cons cell. `cons` allocates; root the inputs across it.
    HPointer newList;
    {
        StackRootGuard guard(&arrayHP, &encodedHP);
        Custom* arr = static_cast<Custom*>(allocator.resolve(arrayHP));
        HPointer tailHP = arr->values[0].p;
        StackRootGuard guard2(&tailHP);
        newList = cons(boxed(encodedHP), tailHP, true);
    }

    // Build the ENC_ARRAY Custom; newList is the only HPointer field.
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &newList, sizeof(newList));
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&newList, &roots[0], sizeof(newList));
    enc->header.size = 1;
    enc->ctor = ENC_ARRAY;
    enc->unboxed = 0;
    enc->values[0].p = newList;

    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

HPtr Elm_Kernel_Json_addField(HPtr key, HPtr value, HPtr object) {
    auto& allocator = Allocator::instance();
    HPointer keyHP    = Export::decode(key.toBits());
    HPointer valueHP  = Export::decode(value.toBits());
    HPointer objectHP = Export::decode(object.toBits());

    // Build (key, value) Tuple2. Pattern A: keyHP and valueHP are fields;
    // objectHP is live-across (we use it later via resolve).
    HPointer tupleHP;
    {
        // objectHP isn't a field of the tuple but must survive the allocate.
        StackRootGuard guardObj(&objectHP);
        uint64_t roots[2];
        std::memcpy(&roots[0], &keyHP, sizeof(keyHP));
        std::memcpy(&roots[1], &valueHP, sizeof(valueHP));
        Tuple2* tuple = static_cast<Tuple2*>(
            eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), roots, 2, 0x3));
        std::memcpy(&keyHP, &roots[0], sizeof(keyHP));
        std::memcpy(&valueHP, &roots[1], sizeof(valueHP));
        tuple->header.unboxed = 0;
        tuple->a.p = keyHP;
        tuple->b.p = valueHP;
        tupleHP = allocator.wrap(tuple);
    }

    // cons (the new tuple, prior list head) and root across the call.
    HPointer newList;
    {
        StackRootGuard guard(&tupleHP, &objectHP);
        Custom* obj = static_cast<Custom*>(allocator.resolve(objectHP));
        HPointer tailHP = obj->values[0].p;
        StackRootGuard guard2(&tailHP);
        newList = cons(boxed(tupleHP), tailHP, true);
    }

    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &newList, sizeof(newList));
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&newList, &roots[0], sizeof(newList));
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = newList;

    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

} // extern "C"
