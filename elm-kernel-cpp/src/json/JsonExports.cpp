//===- JsonExports.cpp - C-linkage exports for Json module -----------------===//
//
// Full JSON decoder/encoder implementation using nlohmann/json.
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
// JsonValue Heap Type
//===----------------------------------------------------------------------===//

// Custom tag for JsonValue (using Tag_Custom with a specific ctor)
static constexpr u16 CTOR_JsonValue = 100;  // Arbitrary high ctor to avoid conflicts

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

// Create an Elm String from a C++ string
static HPointer allocElmString(const std::string& str) {
    auto& allocator = Allocator::instance();

    // Convert UTF-8 to UTF-16
    std::u16string utf16;
    size_t i = 0;
    while (i < str.size()) {
        uint32_t cp;
        uint8_t c = str[i];
        if ((c & 0x80) == 0) {
            cp = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            cp = (c & 0x1F) << 6;
            if (i + 1 < str.size()) cp |= (str[i+1] & 0x3F);
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            cp = (c & 0x0F) << 12;
            if (i + 1 < str.size()) cp |= (str[i+1] & 0x3F) << 6;
            if (i + 2 < str.size()) cp |= (str[i+2] & 0x3F);
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            cp = (c & 0x07) << 18;
            if (i + 1 < str.size()) cp |= (str[i+1] & 0x3F) << 12;
            if (i + 2 < str.size()) cp |= (str[i+2] & 0x3F) << 6;
            if (i + 3 < str.size()) cp |= (str[i+3] & 0x3F);
            i += 4;
        } else {
            cp = 0xFFFD;  // replacement character
            i += 1;
        }

        if (cp <= 0xFFFF) {
            utf16.push_back(static_cast<char16_t>(cp));
        } else {
            cp -= 0x10000;
            utf16.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
            utf16.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
        }
    }

    size_t allocSize = sizeof(ElmString) + utf16.size() * sizeof(u16);
    allocSize = (allocSize + 7) & ~7;
    ElmString* elmStr = static_cast<ElmString*>(allocator.allocate(allocSize, Tag_String));
    elmStr->header.size = static_cast<u32>(utf16.size());
    std::memcpy(elmStr->chars, utf16.data(), utf16.size() * sizeof(u16));

    return allocator.wrap(elmStr);
}

// Convert Elm String to C++ string
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

// Create Ok result
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

// Create Err result with a Json.Error
static uint64_t makeErr(const std::string& message) {
    HPointer msgStr = allocElmString(message);

    auto& allocator = Allocator::instance();
    // Create Error.Failure message value (simplified)
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* failure = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    failure->header.size = 2;
    failure->ctor = 0;  // Failure ctor
    failure->unboxed = 0;
    failure->values[0].p = msgStr;  // message
    failure->values[1].p = listNil();  // context (empty)

    // Wrap in Err
    size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* err = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    err->header.size = 1;
    err->ctor = 1;  // Err
    err->unboxed = 0;
    err->values[0].p = allocator.wrap(failure);

    return Export::encode(allocator.wrap(err));
}

// Check if a result is Ok
static bool isOk(uint64_t result) {
    void* ptr = Export::toPtr(result);
    if (!ptr) return false;
    Custom* c = static_cast<Custom*>(ptr);
    return c->ctor == 0;
}

// Get value from Ok result
static HPointer getOkValue(uint64_t result) {
    void* ptr = Export::toPtr(result);
    Custom* c = static_cast<Custom*>(ptr);
    return c->values[0].p;
}

//===----------------------------------------------------------------------===//
// JSON Value Storage
//===----------------------------------------------------------------------===//

// Store JSON as a heap-allocated pointer in a Custom
// We use C++ new/delete for the json object and store the raw pointer.
// This is not GC-friendly but works for the kernel implementation.

struct JsonStorage {
    json* data;
};

static std::vector<JsonStorage> jsonValues;

static uint64_t wrapJson(const json& j) {
    auto& allocator = Allocator::instance();

    // Store JSON in a Custom with the pointer encoded as an integer
    json* jptr = new json(j);

    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(allocator.allocate(size, Tag_Custom));
    c->header.size = 1;
    c->ctor = CTOR_JsonValue;
    c->unboxed = 1;
    c->values[0].i = reinterpret_cast<int64_t>(jptr);

    return Export::encode(allocator.wrap(c));
}

static json* unwrapJson(uint64_t enc) {
    void* ptr = Export::toPtr(enc);
    if (!ptr) return nullptr;
    Custom* c = static_cast<Custom*>(ptr);
    if (c->ctor != CTOR_JsonValue) return nullptr;
    return reinterpret_cast<json*>(c->values[0].i);
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
// Decoder Execution
//===----------------------------------------------------------------------===//

// Forward declaration
static uint64_t runDecoder(Custom* decoder, const json& jval);

// Run decoder on a JSON value and return Result
static uint64_t runDecoder(Custom* decoder, const json& jval) {
    auto& allocator = Allocator::instance();

    switch (decoder->ctor) {
        case DEC_STRING: {
            if (!jval.is_string()) {
                return makeErr("Expecting a STRING");
            }
            HPointer str = allocElmString(jval.get<std::string>());
            return makeOk(str);
        }

        case DEC_BOOL: {
            if (!jval.is_boolean()) {
                return makeErr("Expecting a BOOL");
            }
            bool b = jval.get<bool>();
            return makeOk(b ? elmTrue() : elmFalse());
        }

        case DEC_INT: {
            if (!jval.is_number_integer()) {
                return makeErr("Expecting an INT");
            }
            int64_t n = jval.get<int64_t>();
            HPointer intVal = allocInt(n);
            return makeOk(intVal);
        }

        case DEC_FLOAT: {
            if (!jval.is_number()) {
                return makeErr("Expecting a FLOAT");
            }
            double d = jval.get<double>();
            HPointer floatVal = allocFloat(d);
            return makeOk(floatVal);
        }

        case DEC_NULL: {
            if (!jval.is_null()) {
                return makeErr("Expecting null");
            }
            HPointer fallback = decoder->values[0].p;
            return makeOk(fallback);
        }

        case DEC_VALUE: {
            // Wrap the json value as a JsonValue
            uint64_t wrapped = wrapJson(jval);
            return makeOk(Export::decode(wrapped));
        }

        case DEC_LIST: {
            if (!jval.is_array()) {
                return makeErr("Expecting a LIST");
            }

            // Get element decoder
            void* elemDecPtr = allocator.resolve(decoder->values[0].p);
            Custom* elemDec = static_cast<Custom*>(elemDecPtr);

            // Decode each element in reverse to build list
            HPointer result = listNil();
            for (auto it = jval.rbegin(); it != jval.rend(); ++it) {
                uint64_t elemResult = runDecoder(elemDec, *it);
                if (!isOk(elemResult)) {
                    return elemResult;  // Propagate error
                }
                HPointer elemVal = getOkValue(elemResult);
                result = cons(boxed(elemVal), result, true);
            }
            return makeOk(result);
        }

        case DEC_ARRAY: {
            if (!jval.is_array()) {
                return makeErr("Expecting an ARRAY");
            }

            // Get element decoder
            void* elemDecPtr = allocator.resolve(decoder->values[0].p);
            Custom* elemDec = static_cast<Custom*>(elemDecPtr);

            // Decode each element
            std::vector<uint64_t> elements;
            for (const auto& elem : jval) {
                uint64_t elemResult = runDecoder(elemDec, elem);
                if (!isOk(elemResult)) {
                    return elemResult;
                }
                elements.push_back(Export::encode(getOkValue(elemResult)));
            }

            // Build Array (ElmArray)
            size_t arrSize = sizeof(ElmArray) + elements.size() * sizeof(Unboxable);
            arrSize = (arrSize + 7) & ~7;
            ElmArray* arr = static_cast<ElmArray*>(allocator.allocate(arrSize, Tag_Array));
            arr->header.size = static_cast<u32>(elements.size());
            for (size_t i = 0; i < elements.size(); i++) {
                arr->elements[i].p = Export::decode(elements[i]);
            }

            return makeOk(allocator.wrap(arr));
        }

        case DEC_FIELD: {
            if (!jval.is_object()) {
                return makeErr("Expecting an OBJECT");
            }

            // Get field name
            std::string fieldName = elmStringToStd(Export::encode(decoder->values[0].p));

            if (!jval.contains(fieldName)) {
                return makeErr("Expecting an OBJECT with a field named `" + fieldName + "`");
            }

            // Get nested decoder
            void* nestedDecPtr = allocator.resolve(decoder->values[1].p);
            Custom* nestedDec = static_cast<Custom*>(nestedDecPtr);

            return runDecoder(nestedDec, jval[fieldName]);
        }

        case DEC_INDEX: {
            if (!jval.is_array()) {
                return makeErr("Expecting an ARRAY");
            }

            int64_t index = decoder->values[0].i;
            if (index < 0 || static_cast<size_t>(index) >= jval.size()) {
                return makeErr("Expecting a LONGER array");
            }

            // Get nested decoder
            void* nestedDecPtr = allocator.resolve(decoder->values[1].p);
            Custom* nestedDec = static_cast<Custom*>(nestedDecPtr);

            return runDecoder(nestedDec, jval[static_cast<size_t>(index)]);
        }

        case DEC_KEYVALUE: {
            if (!jval.is_object()) {
                return makeErr("Expecting an OBJECT");
            }

            // Get value decoder
            void* valDecPtr = allocator.resolve(decoder->values[0].p);
            Custom* valDec = static_cast<Custom*>(valDecPtr);

            // Build list of (key, value) tuples in reverse
            HPointer result = listNil();
            for (auto it = jval.rbegin(); it != jval.rend(); ++it) {
                uint64_t valResult = runDecoder(valDec, it.value());
                if (!isOk(valResult)) {
                    return valResult;
                }

                // Create Tuple2 (key, value)
                HPointer keyStr = allocElmString(it.key());
                HPointer val = getOkValue(valResult);

                Tuple2* tuple = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
                tuple->header.unboxed = 0;
                tuple->a.p = keyStr;
                tuple->b.p = val;

                result = cons(boxed(allocator.wrap(tuple)), result, true);
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
            // First run the decoder
            void* innerDecPtr = allocator.resolve(decoder->values[1].p);
            Custom* innerDec = static_cast<Custom*>(innerDecPtr);

            uint64_t innerResult = runDecoder(innerDec, jval);
            if (!isOk(innerResult)) {
                return innerResult;
            }

            // Call the callback with the result to get a new decoder
            HPointer callback = decoder->values[0].p;
            HPointer value = getOkValue(innerResult);

            uint64_t args[1] = { Export::encode(value) };
            uint64_t newDecEnc = eco_apply_closure(Export::encode(callback), args, 1);

            // Run the new decoder
            void* newDecPtr = Export::toPtr(newDecEnc);
            Custom* newDec = static_cast<Custom*>(newDecPtr);

            return runDecoder(newDec, jval);
        }

        case DEC_ONEOF: {
            HPointer decoders = decoder->values[0].p;

            while (!isNil(decoders)) {
                void* cellPtr = allocator.resolve(decoders);
                Cons* cell = static_cast<Cons*>(cellPtr);

                void* decPtr = allocator.resolve(cell->head.p);
                Custom* dec = static_cast<Custom*>(decPtr);

                uint64_t result = runDecoder(dec, jval);
                if (isOk(result)) {
                    return result;
                }

                decoders = cell->tail;
            }

            return makeErr("Ran into a oneOf with no possibilities");
        }

        case DEC_MAP1: {
            void* dec1Ptr = allocator.resolve(decoder->values[1].p);
            Custom* dec1 = static_cast<Custom*>(dec1Ptr);

            uint64_t result1 = runDecoder(dec1, jval);
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

            uint64_t result1 = runDecoder(dec1, jval);
            if (!isOk(result1)) return result1;
            uint64_t result2 = runDecoder(dec2, jval);
            if (!isOk(result2)) return result2;

            HPointer callback = decoder->values[0].p;
            uint64_t args[2] = {
                Export::encode(getOkValue(result1)),
                Export::encode(getOkValue(result2))
            };
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 2);

            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP3: {
            Custom* decs[3];
            for (int i = 0; i < 3; i++) {
                decs[i] = static_cast<Custom*>(allocator.resolve(decoder->values[i+1].p));
            }

            uint64_t results[3];
            for (int i = 0; i < 3; i++) {
                results[i] = runDecoder(decs[i], jval);
                if (!isOk(results[i])) return results[i];
            }

            HPointer callback = decoder->values[0].p;
            uint64_t args[3];
            for (int i = 0; i < 3; i++) {
                args[i] = Export::encode(getOkValue(results[i]));
            }
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 3);

            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP4: {
            Custom* decs[4];
            for (int i = 0; i < 4; i++) {
                decs[i] = static_cast<Custom*>(allocator.resolve(decoder->values[i+1].p));
            }

            uint64_t results[4];
            for (int i = 0; i < 4; i++) {
                results[i] = runDecoder(decs[i], jval);
                if (!isOk(results[i])) return results[i];
            }

            HPointer callback = decoder->values[0].p;
            uint64_t args[4];
            for (int i = 0; i < 4; i++) {
                args[i] = Export::encode(getOkValue(results[i]));
            }
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 4);

            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP5: {
            Custom* decs[5];
            for (int i = 0; i < 5; i++) {
                decs[i] = static_cast<Custom*>(allocator.resolve(decoder->values[i+1].p));
            }

            uint64_t results[5];
            for (int i = 0; i < 5; i++) {
                results[i] = runDecoder(decs[i], jval);
                if (!isOk(results[i])) return results[i];
            }

            HPointer callback = decoder->values[0].p;
            uint64_t args[5];
            for (int i = 0; i < 5; i++) {
                args[i] = Export::encode(getOkValue(results[i]));
            }
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 5);

            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP6: {
            Custom* decs[6];
            for (int i = 0; i < 6; i++) {
                decs[i] = static_cast<Custom*>(allocator.resolve(decoder->values[i+1].p));
            }

            uint64_t results[6];
            for (int i = 0; i < 6; i++) {
                results[i] = runDecoder(decs[i], jval);
                if (!isOk(results[i])) return results[i];
            }

            HPointer callback = decoder->values[0].p;
            uint64_t args[6];
            for (int i = 0; i < 6; i++) {
                args[i] = Export::encode(getOkValue(results[i]));
            }
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 6);

            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP7: {
            Custom* decs[7];
            for (int i = 0; i < 7; i++) {
                decs[i] = static_cast<Custom*>(allocator.resolve(decoder->values[i+1].p));
            }

            uint64_t results[7];
            for (int i = 0; i < 7; i++) {
                results[i] = runDecoder(decs[i], jval);
                if (!isOk(results[i])) return results[i];
            }

            HPointer callback = decoder->values[0].p;
            uint64_t args[7];
            for (int i = 0; i < 7; i++) {
                args[i] = Export::encode(getOkValue(results[i]));
            }
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 7);

            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP8: {
            Custom* decs[8];
            for (int i = 0; i < 8; i++) {
                decs[i] = static_cast<Custom*>(allocator.resolve(decoder->values[i+1].p));
            }

            uint64_t results[8];
            for (int i = 0; i < 8; i++) {
                results[i] = runDecoder(decs[i], jval);
                if (!isOk(results[i])) return results[i];
            }

            HPointer callback = decoder->values[0].p;
            uint64_t args[8];
            for (int i = 0; i < 8; i++) {
                args[i] = Export::encode(getOkValue(results[i]));
            }
            uint64_t mapped = eco_apply_closure(Export::encode(callback), args, 8);

            return makeOk(Export::decode(mapped));
        }

        default:
            return makeErr("Unknown decoder type");
    }
}

//===----------------------------------------------------------------------===//
// Encoding Helper
//===----------------------------------------------------------------------===//

// Convert Elm value to JSON (for encoding)
static json elmToJson(uint64_t valueEnc);

static json elmToJson(uint64_t valueEnc) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(valueEnc);

    // Check for embedded constants
    if (h.constant == Const_Unit + 1 || h.constant == 0) {
        // Check if it's actually a null encoder
        void* ptr = Export::toPtr(valueEnc);
        if (!ptr) {
            return json(nullptr);
        }

        // Check the tag
        Header* header = static_cast<Header*>(ptr);

        if (header->tag == Tag_Custom) {
            Custom* c = static_cast<Custom*>(ptr);

            switch (c->ctor) {
                case ENC_NULL:
                    return json(nullptr);

                case ENC_BOOL: {
                    HPointer boolVal = c->values[0].p;
                    bool b = (boolVal.constant == Const_True + 1);
                    return json(b);
                }

                case ENC_INT:
                    return json(c->values[0].i);

                case ENC_FLOAT:
                    return json(c->values[0].f);

                case ENC_STRING: {
                    std::string s = elmStringToStd(Export::encode(c->values[0].p));
                    return json(s);
                }

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

                        // Each entry is a tuple (key, value)
                        void* tuplePtr = allocator.resolve(cell->head.p);
                        Tuple2* tuple = static_cast<Tuple2*>(tuplePtr);

                        std::string key = elmStringToStd(Export::encode(tuple->a.p));
                        json val = elmToJson(Export::encode(tuple->b.p));
                        obj[key] = val;

                        list = cell->tail;
                    }
                    return obj;
                }

                case CTOR_JsonValue: {
                    // Already a JSON value
                    json* jptr = reinterpret_cast<json*>(c->values[0].i);
                    return *jptr;
                }

                default:
                    // Unknown encoder type - try to handle raw values
                    break;
            }
        }

        // Check for primitives
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

        // Default to null for unknown types
        return json(nullptr);
    }

    // Handle True/False constants
    if (h.constant == Const_True + 1) {
        return json(true);
    }
    if (h.constant == Const_False + 1) {
        return json(false);
    }
    if (h.constant == Const_Nil + 1) {
        return json::array();
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
    // Value should be a JsonValue (wrapped json pointer)
    json* jptr = unwrapJson(value);
    if (!jptr) {
        return makeErr("Invalid JSON value");
    }

    void* decPtr = Export::toPtr(decoder);
    Custom* dec = static_cast<Custom*>(decPtr);

    return runDecoder(dec, *jptr);
}

uint64_t Elm_Kernel_Json_runOnString(uint64_t decoder, uint64_t jsonString) {
    std::string str = elmStringToStd(jsonString);

    try {
        json jval = json::parse(str);

        void* decPtr = Export::toPtr(decoder);
        Custom* dec = static_cast<Custom*>(decPtr);

        return runDecoder(dec, jval);
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
    // For primitive Elm values, we need to wrap them in an encoder
    // For now, just return as-is since we handle it in elmToJson
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

    // Get existing array
    void* arrPtr = Export::toPtr(array);
    Custom* arr = static_cast<Custom*>(arrPtr);

    // Prepend entry to the list
    HPointer newList = cons(boxed(Export::decode(entry)), arr->values[0].p, true);

    // Create new array encoder
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

    // Get existing object
    void* objPtr = Export::toPtr(object);
    Custom* obj = static_cast<Custom*>(objPtr);

    // Create a tuple (key, value)
    Tuple2* tuple = static_cast<Tuple2*>(allocator.allocate(sizeof(Tuple2), Tag_Tuple2));
    tuple->header.unboxed = 0;
    tuple->a.p = Export::decode(key);
    tuple->b.p = Export::decode(value);

    // Prepend tuple to the list
    HPointer newList = cons(boxed(allocator.wrap(tuple)), obj->values[0].p, true);

    // Create new object encoder
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
