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
    if (h.constant == Const_EmptyString + 1) {
        return "";
    }

    void* ptr = Export::toPtr(strEnc);
    return Elm::StringOps::toStdString(ptr);
}

// Create Ok result. Roots `value` across the Custom allocate so callers may
// pass an HPointer captured before this call.
static uint64_t makeOk(HPointer value) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* result;
    {
        StackRootGuard guard(&value);
        result = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
    result->header.size = 1;
    result->ctor = 0;  // Ok
    result->unboxed = 0;
    result->values[0].p = value;
    return Export::encode(allocator.wrap(result));
}


// Create Err result with a Json.Error.
static uint64_t makeErr(const std::string& message) {
    auto& allocator = Allocator::instance();

    HPointer msgStr = allocElmString(message);

    // Create Error.Failure message value (simplified).
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    HPointer failureHP;
    {
        // Root msgStr across the Failure custom allocate.
        StackRootGuard guard(&msgStr);
        Custom* failure = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
        failure->header.size = 2;
        failure->ctor = 0;  // Failure ctor
        failure->unboxed = 0;
        failure->values[0].p = msgStr;     // message
        failure->values[1].p = listNil();  // context (empty)
        failureHP = allocator.wrap(failure);
    }

    // Wrap in Err. Root the failure handle across the Err allocate.
    size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* err;
    {
        StackRootGuard guard(&failureHP);
        err = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
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
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 0;
    c->ctor = CTOR_JSON_NULL;
    c->unboxed = 0;
    return allocator.wrap(c);
}

// Create a heap-resident JSON bool.
static HPointer makeJsonBool(bool b) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 1;
    c->ctor = CTOR_JSON_BOOL;
    c->unboxed = 0;
    c->values[0].p = b ? elmTrue() : elmFalse();
    return allocator.wrap(c);
}

// Create a heap-resident JSON int.
static HPointer makeJsonInt(i64 val) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 1;
    c->ctor = CTOR_JSON_INT;
    c->unboxed = 1;
    c->values[0].i = val;
    return allocator.wrap(c);
}

// Create a heap-resident JSON float.
static HPointer makeJsonFloat(f64 val) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 1;
    c->ctor = CTOR_JSON_FLOAT;
    c->unboxed = 2;  // kind=Float at slot 0
    c->values[0].f = val;
    return allocator.wrap(c);
}

// Create a heap-resident JSON string.
static HPointer makeJsonString(HPointer elmStr) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 1;
    c->ctor = CTOR_JSON_STRING;
    c->unboxed = 0;
    c->values[0].p = elmStr;
    return allocator.wrap(c);
}

// Create a heap-resident JSON array from an ElmArray of JSON values.
static HPointer makeJsonArray(HPointer elmArray) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 1;
    c->ctor = CTOR_JSON_ARRAY;
    c->unboxed = 0;
    c->values[0].p = elmArray;
    return allocator.wrap(c);
}

// Create a heap-resident JSON object from an Elm List of (String, JsonValue) tuples.
static HPointer makeJsonObject(HPointer kvList) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 1;
    c->ctor = CTOR_JSON_OBJECT;
    c->unboxed = 0;
    c->values[0].p = kvList;
    return allocator.wrap(c);
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
        std::vector<HPointer> elements;
        elements.reserve(j.size());
        for (const auto& elem : j) {
            elements.push_back(jsonToHeap(elem));
        }

        // Build ElmArray from collected HPointers.
        HPointer arr = arrayFromPointers(elements);
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
        for (auto it = keys.rbegin(); it != keys.rend(); ++it) {
            HPointer keyStr = allocElmString(*it);
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
            return json(boolVal.constant == Const_True + 1);
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
            HPointer kvList = c->values[0].p;
            while (!isNil(kvList)) {
                void* cellPtr = allocator.resolve(kvList);
                Cons* cell = static_cast<Cons*>(cellPtr);

                void* tuplePtr = allocator.resolve(cell->head.p);
                Tuple2* tup = static_cast<Tuple2*>(tuplePtr);

                std::string key = elmStringToStd(Export::encode(tup->a.p));
                json val = heapJsonToNlohmann(Export::encode(tup->b.p));
                obj[key] = val;

                kvList = cell->tail;
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
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 0;
    dec->ctor = ctor;
    dec->unboxed = 0;
    return Export::encode(allocator.wrap(dec));
}

static uint64_t makeDecoder1(u16 ctor, uint64_t arg) {
    auto& allocator = Allocator::instance();
    HPointer payload = Export::decode(arg);
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec;
    {
        StackRootGuard guard(&payload);
        dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
    dec->header.size = 1;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = payload;
    return Export::encode(allocator.wrap(dec));
}

static uint64_t makeDecoder1i(u16 ctor, int64_t arg) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 1;
    dec->ctor = ctor;
    dec->unboxed = 1;
    dec->values[0].i = arg;
    return Export::encode(allocator.wrap(dec));
}

static uint64_t makeDecoder2(u16 ctor, uint64_t arg1, uint64_t arg2) {
    auto& allocator = Allocator::instance();
    HPointer p0 = Export::decode(arg1);
    HPointer p1 = Export::decode(arg2);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec;
    {
        StackRootGuard guard(&p0, &p1);
        dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = p0;
    dec->values[1].p = p1;
    return Export::encode(allocator.wrap(dec));
}

static uint64_t makeDecoder2ip(u16 ctor, int64_t arg1, uint64_t arg2) {
    auto& allocator = Allocator::instance();
    HPointer p1 = Export::decode(arg2);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec;
    {
        StackRootGuard guard(&p1);
        dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 1;  // first field unboxed
    dec->values[0].i = arg1;
    dec->values[1].p = p1;
    return Export::encode(allocator.wrap(dec));
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
        if (jvalHP.constant != 0) return nullptr;
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

                // Fast path: bump-pointer with no rooting. allocateFast cannot
                // GC, so tree_hp / tail_hp cannot move out from under us.
                Custom* c = static_cast<Custom*>(
                    Allocator::instance().allocateFast(sz));
                if (c) {
                    Header* hdr = &c->header;
                    std::memset(hdr, 0, sizeof(Header));
                    hdr->tag = Tag_Custom;
                    hdr->size = 4;
                    c->ctor = 0;       // Array_elm_builtin
                    c->unboxed = 0x5;
                    c->values[0].i = static_cast<i64>(length);
                    c->values[1].i = 5;  // shiftStep
                    c->values[2].p = tree_hp;
                    c->values[3].p = tail_hp;
                    return Allocator::instance().wrap(c);
                }

                // Slow path: root tree/tail across the GC that allocateSlow
                // may run, then re-read after the call.
                auto& rs = Allocator::instance().getRootSet();
                size_t saved = rs.stackRangePoint();
                HPointer tree_root = tree_hp;
                HPointer tail_root = tail_hp;
                rs.pushStackRootRange(&tree_root, 1, 1);
                rs.pushStackRootRange(&tail_root, 1, 1);

                c = static_cast<Custom*>(
                    Allocator::instance().allocateSlow(sz, Tag_Custom));
                c->header.size = 4;
                c->ctor = 0;       // Array_elm_builtin
                c->unboxed = 0x5;  // field 0 and 1 are unboxed Int
                c->values[0].i = static_cast<i64>(length);
                c->values[1].i = 5;  // shiftStep
                c->values[2].p = tree_root;
                c->values[3].p = tail_root;

                HPointer result = Allocator::instance().wrap(c);
                rs.restoreStackRangePoint(saved);
                return result;
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

                    // Fast path: bump-pointer with no extra rooting.
                    // leafJsArr cannot move because allocateFast cannot GC.
                    Custom* node = static_cast<Custom*>(
                        Allocator::instance().allocateFast(sz));
                    if (node) {
                        Header* hdr = &node->header;
                        std::memset(hdr, 0, sizeof(Header));
                        hdr->tag = Tag_Custom;
                        hdr->size = 1;
                        node->ctor = 1;      // Leaf
                        node->unboxed = 0;   // field 0 (JsArray) is boxed
                        node->values[0].p = leafJsArr;
                    } else {
                        // Slow path: extend rooting to leafJsArr across the
                        // GC that allocateSlow may run.
                        HPointer leafRoot = leafJsArr;
                        rs.pushStackRootRange(&leafRoot, 1, 1);
                        node = static_cast<Custom*>(
                            Allocator::instance().allocateSlow(sz, Tag_Custom));
                        node->header.size = 1;
                        node->ctor = 1;      // Leaf
                        node->unboxed = 0;
                        node->values[0].p = leafRoot;
                    }
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
            HPointer kvList = jval->values[0].p;

            // Walk the key/value list. `kvList` and `nestedDecHP` survive
            // a recursive `runDecoder` (in the matching branch) and any
            // future allocations.
            StackRootGuard fieldRoots(&kvList, &nestedDecHP);

            while (!isNil(kvList)) {
                Cons* cell = static_cast<Cons*>(allocator.resolve(kvList));
                HPointer headHP = cell->head.p;
                HPointer tailHP = cell->tail;

                Tuple2* tup = static_cast<Tuple2*>(allocator.resolve(headHP));
                HPointer keyHP = tup->a.p;
                HPointer valHP = tup->b.p;

                std::string key = elmStringToStd(Export::encode(keyHP));
                if (key == fieldName) {
                    return runDecoder(nestedDecHP, Export::encode(valHP));
                }

                kvList = tailHP;
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
            {
                HPointer kvList = jval->values[0].p;
                while (!isNil(kvList)) {
                    Cons* cell = static_cast<Cons*>(allocator.resolve(kvList));
                    tuples.push_back(cell->head.p);
                    kvList = cell->tail;
                }
            }

            // Build the result list in reverse. Pin `result`, `valDecHP`, and
            // the `tuples` buffer across each `runDecoder` (which may GC) and
            // each `cons` / `tuple2` (which allocate).
            HPointer result = listNil();

            auto& rs = allocator.getRootSet();
            size_t kvSaved = rs.stackRangePoint();
            rs.pushStackRootRange(&result,    1, 1);
            rs.pushStackRootRange(&valDecHP,  1, 1);
            if (!tuples.empty()) {
                rs.pushStackRootRange(tuples.data(), tuples.size(),
                                      /*hpointer_mask=*/~uint64_t(0));
            }

            for (auto it = tuples.rbegin(); it != tuples.rend(); ++it) {
                Tuple2* srcTup = static_cast<Tuple2*>(allocator.resolve(*it));
                uint64_t valEnc = Export::encode(srcTup->b.p);
                HPointer keyStr = srcTup->a.p;

                // Root keyStr across the recursive decode + tuple2 + cons.
                rs.pushStackRootRange(&keyStr, 1, 1);

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
                    rs.pushStackRootRange(&result,   1, 1);
                    rs.pushStackRootRange(&valDecHP, 1, 1);
                    if (!tuples.empty()) {
                        rs.pushStackRootRange(tuples.data(), tuples.size(),
                                              /*hpointer_mask=*/~uint64_t(0));
                    }
                }

                rs.pushStackRootRange(&resTup, 1, 1);
                result = cons(boxed(resTup), result, true);
                // Pop the `resTup` and `keyStr` roots now that result owns them.
                rs.restoreStackRangePoint(kvSaved);
                rs.pushStackRootRange(&result,    1, 1);
                rs.pushStackRootRange(&valDecHP,  1, 1);
                if (!tuples.empty()) {
                    rs.pushStackRootRange(tuples.data(), tuples.size(),
                                          /*hpointer_mask=*/~uint64_t(0));
                }
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
            HPointer decoders = decoder->values[0].p;

            // `decoders` (the cons-list head) and the running tail must
            // survive recursive `runDecoder` calls.
            StackRootGuard guard(&decoders);

            while (!isNil(decoders)) {
                Cons* cell = static_cast<Cons*>(allocator.resolve(decoders));
                HPointer decHP = cell->head.p;
                HPointer tailHP = cell->tail;

                uint64_t result = runDecoder(decHP, jvalEnc);
                if (isOk(result)) {
                    return result;
                }

                decoders = tailHP;
            }

            return makeErr("Ran into a oneOf with no possibilities");
        }

        case DEC_MAP1: {
            HPointer dec1HP = decoder->values[1].p;
            HPointer callbackHP = decoder->values[0].p;

            uint64_t result1;
            {
                StackRootGuard guard(&callbackHP);
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

    // Check for embedded constants.
    if (h.constant == Const_True + 1) return json(true);
    if (h.constant == Const_False + 1) return json(false);
    if (h.constant == Const_Nil + 1) return json::array();
    if (h.constant == Const_EmptyString + 1) return json("");
    if (h.constant != 0 && h.constant != Const_Unit + 1) return json(nullptr);

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
                return json(boolVal.constant == Const_True + 1);
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
                HPointer list = c->values[0].p;
                while (!isNil(list)) {
                    void* cellPtr = allocator.resolve(list);
                    Cons* cell = static_cast<Cons*>(cellPtr);
                    elements.push_back(elmToJson(Export::encode(cell->head.p)));
                    list = cell->tail;
                }
                std::reverse(elements.begin(), elements.end());
                return json(elements);
            }

            case ENC_OBJECT: {
                json obj = json::object();
                HPointer list = c->values[0].p;
                while (!isNil(list)) {
                    void* cellPtr = allocator.resolve(list);
                    Cons* cell = static_cast<Cons*>(cellPtr);

                    void* tuplePtr = allocator.resolve(cell->head.p);
                    Tuple2* tuple = static_cast<Tuple2*>(tuplePtr);

                    std::string key = elmStringToStd(Export::encode(tuple->a.p));
                    json val = elmToJson(Export::encode(tuple->b.p));
                    obj[key] = val;

                    list = cell->tail;
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

    if (header->tag == Tag_String) {
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

// Pre-decode every input handle, root the buffer across allocate, then store.
// `nFields` includes the closure and all decoder slots.
static uint64_t buildMapDecoder(u16 ctor, u32 nFields, std::initializer_list<uint64_t> args) {
    auto& allocator = Allocator::instance();
    std::vector<HPointer> roots;
    roots.reserve(args.size());
    for (uint64_t a : args) roots.push_back(Export::decode(a));

    size_t size = sizeof(Custom) + nFields * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec;
    {
        StackRootRangeGuard guard(roots.data(), roots.size(), /*hpointer_mask=*/~uint64_t(0));
        dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
    dec->header.size = nFields;
    dec->ctor = ctor;
    dec->unboxed = 0;
    for (size_t i = 0; i < roots.size(); ++i) {
        dec->values[i].p = roots[i];
    }
    return Export::encode(allocator.wrap(dec));
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
    if (decoderHP.constant != 0 ||
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

    // Embedded constant booleans → ENC_BOOL
    if (h.constant == Const_True + 1 || h.constant == Const_False + 1) {
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
        enc->header.size = 1;
        enc->ctor = ENC_BOOL;
        enc->unboxed = 0;
        enc->values[0].p = (h.constant == Const_True + 1) ? elmTrue() : elmFalse();
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // Embedded empty-string constant → ENC_STRING wrapping the Const_EmptyString pointer.
    // (The heap-string path below also builds an ENC_STRING; both must serialize via
    // elmStringToStd, which handles the Const_EmptyString constant itself.)
    if (h.constant == Const_EmptyString + 1) {
        // h is an embedded constant: stable across GC, no rooting needed.
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
        enc->header.size = 1;
        enc->ctor = ENC_STRING;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // Other embedded constants (Unit, Nil, Nothing) → ENC_NULL
    if (h.constant != 0) {
        return Elm_Kernel_Json_encodeNull();
    }

    void* ptr = Export::toPtr(valueEnc);
    if (!ptr) return Elm_Kernel_Json_encodeNull();

    Header* header = static_cast<Header*>(ptr);

    if (header->tag == Tag_Int) {
        // Snapshot the unboxed int before any allocation may move the source.
        int64_t intVal = static_cast<ElmInt*>(ptr)->value;
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
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
        Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
        enc->header.size = 1;
        enc->ctor = ENC_FLOAT;
        enc->unboxed = 2;  // kind=Float at slot 0
        enc->values[0].f = floatVal;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    if (header->tag == Tag_String) {
        // Root the string handle across the Custom allocation.
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc;
        {
            StackRootGuard guard(&h);
            enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
        }
        enc->header.size = 1;
        enc->ctor = ENC_STRING;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // Already an encoder Custom (ENC_OBJECT, ENC_ARRAY, etc.) — return as-is.
    return value;
}

HPtr Elm_Kernel_Json_encodeNull() {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 0;
    enc->ctor = ENC_NULL;
    enc->unboxed = 0;
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

HPtr Elm_Kernel_Json_emptyArray() {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = ENC_ARRAY;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

HPtr Elm_Kernel_Json_emptyObject() {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
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

    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc;
    {
        StackRootGuard guard(&newList);
        enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
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

    // Build (key, value) Tuple2, rooting the boxed inputs across the allocate.
    HPointer tupleHP;
    {
        StackRootGuard guard(&keyHP, &valueHP, &objectHP);
        Tuple2* tuple = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
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
    Custom* enc;
    {
        StackRootGuard guard(&newList);
        enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    }
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = newList;

    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

} // extern "C"
