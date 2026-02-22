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
#include <nlohmann/json.hpp>
#include <string>
#include <cstring>
#include <cassert>

using json = nlohmann::json;
using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

// Declare closure call
extern "C" uint64_t eco_apply_closure(uint64_t closure, uint64_t* args, uint32_t num_args);

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

// Convert Elm String to C++ string (UTF-16 to UTF-8 conversion).
static std::string elmStringToStd(uint64_t strEnc) {
    HPointer h = Export::decode(strEnc);
    if (h.constant == Const_EmptyString + 1) {
        return "";
    }

    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return "";

    ElmString* str = static_cast<ElmString*>(ptr);
    std::string result;

    for (u32 i = 0; i < str->header.size; i++) {
        u16 ch = str->chars[i];

        // Handle surrogate pairs
        if (ch >= 0xD800 && ch <= 0xDBFF && i + 1 < str->header.size) {
            u16 lo = str->chars[i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                uint32_t cp = 0x10000 + ((ch - 0xD800) << 10) + (lo - 0xDC00);
                result.push_back(static_cast<char>(0xF0 | ((cp >> 18) & 0x07)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                i++;
                continue;
            }
        }

        if (ch < 0x80) {
            result.push_back(static_cast<char>(ch));
        } else if (ch < 0x800) {
            result.push_back(static_cast<char>(0xC0 | ((ch >> 6) & 0x1F)));
            result.push_back(static_cast<char>(0x80 | (ch & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | ((ch >> 12) & 0x0F)));
            result.push_back(static_cast<char>(0x80 | ((ch >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (ch & 0x3F)));
        }
    }

    return result;
}

// Create Ok result.
static uint64_t makeOk(HPointer value) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* result = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    result->header.size = 1;
    result->ctor = 0;  // Ok
    result->unboxed = 0;
    result->values[0].p = value;
    return Export::encode(allocator.wrap(result));
}

// Create Err result with a Json.Error.
static uint64_t makeErr(const std::string& message) {
    HPointer msgStr = allocElmString(message);

    auto& allocator = Allocator::instance();
    // Create Error.Failure message value (simplified).
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* failure = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    failure->header.size = 2;
    failure->ctor = 0;  // Failure ctor
    failure->unboxed = 0;
    failure->values[0].p = msgStr;  // message
    failure->values[1].p = listNil();  // context (empty)

    // Wrap in Err.
    size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* err = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    err->header.size = 1;
    err->ctor = 1;  // Err
    err->unboxed = 0;
    err->values[0].p = allocator.wrap(failure);

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
    c->unboxed = 1;
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
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 1;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(arg);
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
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(arg1);
    dec->values[1].p = Export::decode(arg2);
    return Export::encode(allocator.wrap(dec));
}

static uint64_t makeDecoder2ip(u16 ctor, int64_t arg1, uint64_t arg2) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 1;  // first field unboxed
    dec->values[0].i = arg1;
    dec->values[1].p = Export::decode(arg2);
    return Export::encode(allocator.wrap(dec));
}

//===----------------------------------------------------------------------===//
// Decoder Execution - operates on heap-resident JSON values
//===----------------------------------------------------------------------===//

// Run decoder on a heap-resident JSON value and return Result.
// jvalEnc is an encoded HPointer to a CTOR_JSON_* Custom object.
static uint64_t runDecoder(Custom* decoder, uint64_t jvalEnc) {
    auto& allocator = Allocator::instance();

    // Resolve the JSON value to inspect its ctor.
    void* jvalPtr = Export::toPtr(jvalEnc);
    Custom* jval = (jvalPtr && static_cast<Header*>(jvalPtr)->tag == Tag_Custom)
                   ? static_cast<Custom*>(jvalPtr) : nullptr;
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
            HPointer fallback = decoder->values[0].p;
            return makeOk(fallback);
        }

        case DEC_VALUE: {
            // Return the heap-resident JSON value directly.
            return makeOk(Export::decode(jvalEnc));
        }

        case DEC_LIST: {
            if (!jval || jctor != CTOR_JSON_ARRAY) {
                return makeErr("Expecting a LIST");
            }

            // Get element decoder.
            void* elemDecPtr = allocator.resolve(decoder->values[0].p);
            Custom* elemDec = static_cast<Custom*>(elemDecPtr);

            // Get the ElmArray.
            void* arrPtr = allocator.resolve(jval->values[0].p);
            ElmArray* arr = static_cast<ElmArray*>(arrPtr);
            u32 len = arr->header.size;

            // Decode each element in reverse to build list.
            HPointer result = listNil();
            for (i64 i = static_cast<i64>(len) - 1; i >= 0; i--) {
                // Re-resolve after allocations in recursive calls.
                arrPtr = allocator.resolve(jval->values[0].p);
                arr = static_cast<ElmArray*>(arrPtr);

                uint64_t elemEnc = Export::encode(arr->elements[i].p);

                // Re-resolve decoder after potential GC.
                elemDecPtr = allocator.resolve(decoder->values[0].p);
                elemDec = static_cast<Custom*>(elemDecPtr);

                uint64_t elemResult = runDecoder(elemDec, elemEnc);
                if (!isOk(elemResult)) {
                    return elemResult;
                }
                HPointer elemVal = getOkValue(elemResult);
                result = cons(boxed(elemVal), result, true);
            }
            return makeOk(result);
        }

        case DEC_ARRAY: {
            if (!jval || jctor != CTOR_JSON_ARRAY) {
                return makeErr("Expecting an ARRAY");
            }

            // Get element decoder.
            void* elemDecPtr = allocator.resolve(decoder->values[0].p);
            Custom* elemDec = static_cast<Custom*>(elemDecPtr);

            // Get the ElmArray.
            void* arrPtr = allocator.resolve(jval->values[0].p);
            ElmArray* arr = static_cast<ElmArray*>(arrPtr);
            u32 len = arr->header.size;

            // Decode each element, collecting results.
            std::vector<HPointer> elements;
            elements.reserve(len);
            for (u32 i = 0; i < len; i++) {
                // Re-resolve after allocations in recursive calls.
                arrPtr = allocator.resolve(jval->values[0].p);
                arr = static_cast<ElmArray*>(arrPtr);

                uint64_t elemEnc = Export::encode(arr->elements[i].p);

                elemDecPtr = allocator.resolve(decoder->values[0].p);
                elemDec = static_cast<Custom*>(elemDecPtr);

                uint64_t elemResult = runDecoder(elemDec, elemEnc);
                if (!isOk(elemResult)) {
                    return elemResult;
                }
                elements.push_back(getOkValue(elemResult));
            }

            // Build ElmArray from results.
            HPointer resultArr = arrayFromPointers(elements);
            return makeOk(resultArr);
        }

        case DEC_FIELD: {
            if (!jval || jctor != CTOR_JSON_OBJECT) {
                return makeErr("Expecting an OBJECT");
            }

            // Get field name from decoder.
            std::string fieldName = elmStringToStd(Export::encode(decoder->values[0].p));

            // Search the key-value list for a matching key.
            HPointer kvList = jval->values[0].p;
            while (!isNil(kvList)) {
                void* cellPtr = allocator.resolve(kvList);
                Cons* cell = static_cast<Cons*>(cellPtr);

                void* tuplePtr = allocator.resolve(cell->head.p);
                Tuple2* tup = static_cast<Tuple2*>(tuplePtr);

                std::string key = elmStringToStd(Export::encode(tup->a.p));
                if (key == fieldName) {
                    // Found: run the nested decoder on the value.
                    uint64_t valEnc = Export::encode(tup->b.p);

                    void* nestedDecPtr = allocator.resolve(decoder->values[1].p);
                    Custom* nestedDec = static_cast<Custom*>(nestedDecPtr);

                    return runDecoder(nestedDec, valEnc);
                }

                kvList = cell->tail;
            }

            return makeErr("Expecting an OBJECT with a field named `" + fieldName + "`");
        }

        case DEC_INDEX: {
            if (!jval || jctor != CTOR_JSON_ARRAY) {
                return makeErr("Expecting an ARRAY");
            }

            int64_t index = decoder->values[0].i;

            // Get the ElmArray.
            void* arrPtr = allocator.resolve(jval->values[0].p);
            ElmArray* arr = static_cast<ElmArray*>(arrPtr);

            if (index < 0 || static_cast<u32>(index) >= arr->header.size) {
                return makeErr("Expecting a LONGER array");
            }

            uint64_t elemEnc = Export::encode(arr->elements[index].p);

            // Get nested decoder.
            void* nestedDecPtr = allocator.resolve(decoder->values[1].p);
            Custom* nestedDec = static_cast<Custom*>(nestedDecPtr);

            return runDecoder(nestedDec, elemEnc);
        }

        case DEC_KEYVALUE: {
            if (!jval || jctor != CTOR_JSON_OBJECT) {
                return makeErr("Expecting an OBJECT");
            }

            // Get value decoder.
            void* valDecPtr = allocator.resolve(decoder->values[0].p);
            Custom* valDec = static_cast<Custom*>(valDecPtr);

            // Collect key-value pairs into a vector first, then build the list
            // in reverse to preserve original order.
            HPointer kvList = jval->values[0].p;

            // First, collect all pairs into a vector.
            std::vector<HPointer> tuples;
            while (!isNil(kvList)) {
                void* cellPtr = allocator.resolve(kvList);
                Cons* cell = static_cast<Cons*>(cellPtr);
                tuples.push_back(cell->head.p);
                kvList = cell->tail;
            }

            // Build result list in reverse.
            HPointer result = listNil();
            for (auto it = tuples.rbegin(); it != tuples.rend(); ++it) {
                void* tuplePtr = allocator.resolve(*it);
                Tuple2* srcTup = static_cast<Tuple2*>(tuplePtr);

                // Decode the value.
                uint64_t valEnc = Export::encode(srcTup->b.p);
                HPointer keyStr = srcTup->a.p;

                // Re-resolve decoder after potential GC.
                valDecPtr = allocator.resolve(decoder->values[0].p);
                valDec = static_cast<Custom*>(valDecPtr);

                uint64_t valResult = runDecoder(valDec, valEnc);
                if (!isOk(valResult)) {
                    return valResult;
                }

                HPointer decodedVal = getOkValue(valResult);

                // Create result Tuple2 (key, decodedValue).
                HPointer resTup = tuple2(boxed(keyStr), boxed(decodedVal), 0);
                result = cons(boxed(resTup), result, true);
            }
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
            // Run the inner decoder first.
            void* innerDecPtr = allocator.resolve(decoder->values[1].p);
            Custom* innerDec = static_cast<Custom*>(innerDecPtr);

            uint64_t innerResult = runDecoder(innerDec, jvalEnc);
            if (!isOk(innerResult)) {
                return innerResult;
            }

            // Call the callback closure with the decoded value to get a new decoder.
            HPointer callback = decoder->values[0].p;
            HPointer value = getOkValue(innerResult);

            uint64_t args[1] = { Export::encode(value) };
            uint64_t newDecEnc = eco_apply_closure(Export::encode(callback), args, 1);

            // Run the new decoder on the same JSON value.
            void* newDecPtr = Export::toPtr(newDecEnc);
            Custom* newDec = static_cast<Custom*>(newDecPtr);

            return runDecoder(newDec, jvalEnc);
        }

        case DEC_ONEOF: {
            HPointer decoders = decoder->values[0].p;

            while (!isNil(decoders)) {
                void* cellPtr = allocator.resolve(decoders);
                Cons* cell = static_cast<Cons*>(cellPtr);

                void* decPtr = allocator.resolve(cell->head.p);
                Custom* dec = static_cast<Custom*>(decPtr);

                uint64_t result = runDecoder(dec, jvalEnc);
                if (isOk(result)) {
                    return result;
                }

                // Re-resolve after potential GC in runDecoder.
                cellPtr = allocator.resolve(decoders);
                cell = static_cast<Cons*>(cellPtr);
                decoders = cell->tail;
            }

            return makeErr("Ran into a oneOf with no possibilities");
        }

        case DEC_MAP1: {
            void* dec1Ptr = allocator.resolve(decoder->values[1].p);
            Custom* dec1 = static_cast<Custom*>(dec1Ptr);

            uint64_t result1 = runDecoder(dec1, jvalEnc);
            if (!isOk(result1)) return result1;

            HPointer callback = decoder->values[0].p;
            uint64_t args[1] = { Export::encode(getOkValue(result1)) };
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 1);

            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP2: {
            void* dec1Ptr = allocator.resolve(decoder->values[1].p);
            void* dec2Ptr = allocator.resolve(decoder->values[2].p);
            Custom* dec1 = static_cast<Custom*>(dec1Ptr);
            Custom* dec2 = static_cast<Custom*>(dec2Ptr);

            uint64_t result1 = runDecoder(dec1, jvalEnc);
            if (!isOk(result1)) return result1;

            // Re-resolve dec2 after potential GC.
            dec2Ptr = allocator.resolve(decoder->values[2].p);
            dec2 = static_cast<Custom*>(dec2Ptr);

            uint64_t result2 = runDecoder(dec2, jvalEnc);
            if (!isOk(result2)) return result2;

            HPointer callback = decoder->values[0].p;
            uint64_t args[2] = {
                Export::encode(getOkValue(result1)),
                Export::encode(getOkValue(result2))
            };
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 2);

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

            uint64_t results[8];
            for (int i = 0; i < n; i++) {
                // Re-resolve decoder sub-field each iteration.
                void* decIPtr = allocator.resolve(decoder->values[i+1].p);
                Custom* decI = static_cast<Custom*>(decIPtr);

                results[i] = runDecoder(decI, jvalEnc);
                if (!isOk(results[i])) return results[i];
            }

            HPointer callback = decoder->values[0].p;
            uint64_t args[8];
            for (int i = 0; i < n; i++) {
                args[i] = Export::encode(getOkValue(results[i]));
            }
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, static_cast<u32>(n));

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
                json arr = json::array();
                HPointer list = c->values[0].p;
                while (!isNil(list)) {
                    void* cellPtr = allocator.resolve(list);
                    Cons* cell = static_cast<Cons*>(cellPtr);
                    arr.push_back(elmToJson(Export::encode(cell->head.p)));
                    list = cell->tail;
                }
                return arr;
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

uint64_t Elm_Kernel_Json_decodeString() {
    return makeDecoder0(DEC_STRING);
}

uint64_t Elm_Kernel_Json_decodeBool() {
    return makeDecoder0(DEC_BOOL);
}

uint64_t Elm_Kernel_Json_decodeInt() {
    return makeDecoder0(DEC_INT);
}

uint64_t Elm_Kernel_Json_decodeFloat() {
    return makeDecoder0(DEC_FLOAT);
}

uint64_t Elm_Kernel_Json_decodeNull(uint64_t fallback) {
    return makeDecoder1(DEC_NULL, fallback);
}

uint64_t Elm_Kernel_Json_decodeList(uint64_t decoder) {
    return makeDecoder1(DEC_LIST, decoder);
}

uint64_t Elm_Kernel_Json_decodeArray(uint64_t decoder) {
    return makeDecoder1(DEC_ARRAY, decoder);
}

uint64_t Elm_Kernel_Json_decodeField(uint64_t fieldName, uint64_t decoder) {
    return makeDecoder2(DEC_FIELD, fieldName, decoder);
}

uint64_t Elm_Kernel_Json_decodeIndex(int64_t index, uint64_t decoder) {
    return makeDecoder2ip(DEC_INDEX, index, decoder);
}

uint64_t Elm_Kernel_Json_decodeKeyValuePairs(uint64_t decoder) {
    return makeDecoder1(DEC_KEYVALUE, decoder);
}

uint64_t Elm_Kernel_Json_decodeValue() {
    return makeDecoder0(DEC_VALUE);
}

//===----------------------------------------------------------------------===//
// Decoder Combinators
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_succeed(uint64_t value) {
    return makeDecoder1(DEC_SUCCEED, value);
}

uint64_t Elm_Kernel_Json_fail(uint64_t message) {
    return makeDecoder1(DEC_FAIL, message);
}

uint64_t Elm_Kernel_Json_andThen(uint64_t closure, uint64_t decoder) {
    return makeDecoder2(DEC_ANDTHEN, closure, decoder);
}

uint64_t Elm_Kernel_Json_oneOf(uint64_t decoders) {
    return makeDecoder1(DEC_ONEOF, decoders);
}

//===----------------------------------------------------------------------===//
// Map Functions
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_map1(uint64_t closure, uint64_t d1) {
    return makeDecoder2(DEC_MAP1, closure, d1);
}

uint64_t Elm_Kernel_Json_map2(uint64_t closure, uint64_t d1, uint64_t d2) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 3 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 3;
    dec->ctor = DEC_MAP2;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(closure);
    dec->values[1].p = Export::decode(d1);
    dec->values[2].p = Export::decode(d2);
    return Export::encode(allocator.wrap(dec));
}

uint64_t Elm_Kernel_Json_map3(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 4 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 4;
    dec->ctor = DEC_MAP3;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(closure);
    dec->values[1].p = Export::decode(d1);
    dec->values[2].p = Export::decode(d2);
    dec->values[3].p = Export::decode(d3);
    return Export::encode(allocator.wrap(dec));
}

uint64_t Elm_Kernel_Json_map4(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 5 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 5;
    dec->ctor = DEC_MAP4;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(closure);
    dec->values[1].p = Export::decode(d1);
    dec->values[2].p = Export::decode(d2);
    dec->values[3].p = Export::decode(d3);
    dec->values[4].p = Export::decode(d4);
    return Export::encode(allocator.wrap(dec));
}

uint64_t Elm_Kernel_Json_map5(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 6 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 6;
    dec->ctor = DEC_MAP5;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(closure);
    dec->values[1].p = Export::decode(d1);
    dec->values[2].p = Export::decode(d2);
    dec->values[3].p = Export::decode(d3);
    dec->values[4].p = Export::decode(d4);
    dec->values[5].p = Export::decode(d5);
    return Export::encode(allocator.wrap(dec));
}

uint64_t Elm_Kernel_Json_map6(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 7 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 7;
    dec->ctor = DEC_MAP6;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(closure);
    dec->values[1].p = Export::decode(d1);
    dec->values[2].p = Export::decode(d2);
    dec->values[3].p = Export::decode(d3);
    dec->values[4].p = Export::decode(d4);
    dec->values[5].p = Export::decode(d5);
    dec->values[6].p = Export::decode(d6);
    return Export::encode(allocator.wrap(dec));
}

uint64_t Elm_Kernel_Json_map7(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6, uint64_t d7) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 8 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 8;
    dec->ctor = DEC_MAP7;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(closure);
    dec->values[1].p = Export::decode(d1);
    dec->values[2].p = Export::decode(d2);
    dec->values[3].p = Export::decode(d3);
    dec->values[4].p = Export::decode(d4);
    dec->values[5].p = Export::decode(d5);
    dec->values[6].p = Export::decode(d6);
    dec->values[7].p = Export::decode(d7);
    return Export::encode(allocator.wrap(dec));
}

uint64_t Elm_Kernel_Json_map8(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6, uint64_t d7, uint64_t d8) {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + 9 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* dec = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    dec->header.size = 9;
    dec->ctor = DEC_MAP8;
    dec->unboxed = 0;
    dec->values[0].p = Export::decode(closure);
    dec->values[1].p = Export::decode(d1);
    dec->values[2].p = Export::decode(d2);
    dec->values[3].p = Export::decode(d3);
    dec->values[4].p = Export::decode(d4);
    dec->values[5].p = Export::decode(d5);
    dec->values[6].p = Export::decode(d6);
    dec->values[7].p = Export::decode(d7);
    dec->values[8].p = Export::decode(d8);
    return Export::encode(allocator.wrap(dec));
}

//===----------------------------------------------------------------------===//
// Running Decoders
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_run(uint64_t decoder, uint64_t value) {
    // Value is a heap-resident JSON value (CTOR_JSON_* Custom).
    void* decPtr = Export::toPtr(decoder);
    if (!decPtr) {
        return makeErr("Invalid decoder");
    }
    Custom* dec = static_cast<Custom*>(decPtr);

    return runDecoder(dec, value);
}

uint64_t Elm_Kernel_Json_runOnString(uint64_t decoder, uint64_t jsonString) {
    std::string str = elmStringToStd(jsonString);

    try {
        json jval = json::parse(str);

        // Convert the parsed JSON tree to heap-resident objects.
        HPointer heapJson = jsonToHeap(jval);
        // nlohmann::json falls out of scope here - no leak.

        void* decPtr = Export::toPtr(decoder);
        Custom* dec = static_cast<Custom*>(decPtr);

        return runDecoder(dec, Export::encode(heapJson));
    } catch (const json::parse_error& e) {
        return makeErr(std::string("Problem with the given value:\n\n") + e.what());
    }
}

//===----------------------------------------------------------------------===//
// Encoding
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_encode(int64_t indent, uint64_t value) {
    json j = elmToJson(value);
    std::string str;
    if (indent > 0) {
        str = j.dump(static_cast<int>(indent));
    } else {
        str = j.dump();
    }
    HPointer result = allocElmString(str);
    return Export::encode(result);
}

uint64_t Elm_Kernel_Json_wrap(uint64_t value) {
    // For primitive Elm values, we need to wrap them in an encoder.
    // For now, just return as-is since we handle it in elmToJson.
    return value;
}

uint64_t Elm_Kernel_Json_encodeNull() {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 0;
    enc->ctor = ENC_NULL;
    enc->unboxed = 0;
    return Export::encode(allocator.wrap(enc));
}

uint64_t Elm_Kernel_Json_emptyArray() {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = ENC_ARRAY;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return Export::encode(allocator.wrap(enc));
}

uint64_t Elm_Kernel_Json_emptyObject() {
    auto& allocator = Allocator::instance();
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return Export::encode(allocator.wrap(enc));
}

uint64_t Elm_Kernel_Json_addEntry(uint64_t entry, uint64_t array) {
    auto& allocator = Allocator::instance();

    void* arrPtr = Export::toPtr(array);
    Custom* arr = static_cast<Custom*>(arrPtr);

    HPointer newList = cons(boxed(Export::decode(entry)), arr->values[0].p, true);

    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = ENC_ARRAY;
    enc->unboxed = 0;
    enc->values[0].p = newList;

    return Export::encode(allocator.wrap(enc));
}

uint64_t Elm_Kernel_Json_addField(uint64_t key, uint64_t value, uint64_t object) {
    auto& allocator = Allocator::instance();

    void* objPtr = Export::toPtr(object);
    Custom* obj = static_cast<Custom*>(objPtr);

    Tuple2* tuple = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
    tuple->header.unboxed = 0;
    tuple->a.p = Export::decode(key);
    tuple->b.p = Export::decode(value);

    HPointer newList = cons(boxed(allocator.wrap(tuple)), obj->values[0].p, true);

    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = newList;

    return Export::encode(allocator.wrap(enc));
}

} // extern "C"
