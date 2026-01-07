//===- JsonExports.cpp - C-linkage exports for Json module -----------------===//
//
// JSON decoder/encoder exports - mostly stubs since full implementation
// requires JSON parsing infrastructure.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

//===----------------------------------------------------------------------===//
// Primitive Decoders (stubs)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_decodeString() {
    assert(false && "Elm_Kernel_Json_decodeString not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeBool() {
    assert(false && "Elm_Kernel_Json_decodeBool not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeInt() {
    assert(false && "Elm_Kernel_Json_decodeInt not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeFloat() {
    assert(false && "Elm_Kernel_Json_decodeFloat not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeNull(uint64_t fallback) {
    (void)fallback;
    assert(false && "Elm_Kernel_Json_decodeNull not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeList(uint64_t decoder) {
    (void)decoder;
    assert(false && "Elm_Kernel_Json_decodeList not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeArray(uint64_t decoder) {
    (void)decoder;
    assert(false && "Elm_Kernel_Json_decodeArray not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeField(uint64_t fieldName, uint64_t decoder) {
    (void)fieldName;
    (void)decoder;
    assert(false && "Elm_Kernel_Json_decodeField not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeIndex(int64_t index, uint64_t decoder) {
    (void)index;
    (void)decoder;
    assert(false && "Elm_Kernel_Json_decodeIndex not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeKeyValuePairs(uint64_t decoder) {
    (void)decoder;
    assert(false && "Elm_Kernel_Json_decodeKeyValuePairs not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_decodeValue() {
    assert(false && "Elm_Kernel_Json_decodeValue not implemented");
    return 0;
}

//===----------------------------------------------------------------------===//
// Decoder Combinators (stubs)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_succeed(uint64_t value) {
    (void)value;
    assert(false && "Elm_Kernel_Json_succeed not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_fail(uint64_t message) {
    (void)message;
    assert(false && "Elm_Kernel_Json_fail not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_andThen(uint64_t closure, uint64_t decoder) {
    (void)closure;
    (void)decoder;
    assert(false && "Elm_Kernel_Json_andThen not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_oneOf(uint64_t decoders) {
    (void)decoders;
    assert(false && "Elm_Kernel_Json_oneOf not implemented");
    return 0;
}

//===----------------------------------------------------------------------===//
// Map Functions (stubs)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_map1(uint64_t closure, uint64_t d1) {
    (void)closure; (void)d1;
    assert(false && "Elm_Kernel_Json_map1 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_map2(uint64_t closure, uint64_t d1, uint64_t d2) {
    (void)closure; (void)d1; (void)d2;
    assert(false && "Elm_Kernel_Json_map2 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_map3(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3) {
    (void)closure; (void)d1; (void)d2; (void)d3;
    assert(false && "Elm_Kernel_Json_map3 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_map4(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4) {
    (void)closure; (void)d1; (void)d2; (void)d3; (void)d4;
    assert(false && "Elm_Kernel_Json_map4 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_map5(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5) {
    (void)closure; (void)d1; (void)d2; (void)d3; (void)d4; (void)d5;
    assert(false && "Elm_Kernel_Json_map5 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_map6(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6) {
    (void)closure; (void)d1; (void)d2; (void)d3; (void)d4; (void)d5; (void)d6;
    assert(false && "Elm_Kernel_Json_map6 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_map7(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6, uint64_t d7) {
    (void)closure; (void)d1; (void)d2; (void)d3; (void)d4; (void)d5; (void)d6; (void)d7;
    assert(false && "Elm_Kernel_Json_map7 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_map8(uint64_t closure, uint64_t d1, uint64_t d2, uint64_t d3, uint64_t d4, uint64_t d5, uint64_t d6, uint64_t d7, uint64_t d8) {
    (void)closure; (void)d1; (void)d2; (void)d3; (void)d4; (void)d5; (void)d6; (void)d7; (void)d8;
    assert(false && "Elm_Kernel_Json_map8 not implemented");
    return 0;
}

//===----------------------------------------------------------------------===//
// Running Decoders (stubs)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_run(uint64_t decoder, uint64_t value) {
    (void)decoder;
    (void)value;
    assert(false && "Elm_Kernel_Json_run not implemented - requires JSON parsing");
    return 0;
}

uint64_t Elm_Kernel_Json_runOnString(uint64_t decoder, uint64_t jsonString) {
    (void)decoder;
    (void)jsonString;
    assert(false && "Elm_Kernel_Json_runOnString not implemented - requires JSON parsing");
    return 0;
}

//===----------------------------------------------------------------------===//
// Encoding (stubs)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_Json_encode(int64_t indent, uint64_t value) {
    (void)indent;
    (void)value;
    assert(false && "Elm_Kernel_Json_encode not implemented - requires JSON serialization");
    return 0;
}

uint64_t Elm_Kernel_Json_wrap(uint64_t value) {
    // Wrap an Elm value as a JSON value - just return as-is for now.
    return value;
}

uint64_t Elm_Kernel_Json_encodeNull() {
    // Create a JSON null value.
    return Export::encode(alloc::unit());
}

uint64_t Elm_Kernel_Json_emptyArray() {
    (void)0;
    assert(false && "Elm_Kernel_Json_emptyArray not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_emptyObject() {
    // Create an empty JSON object - use empty list.
    return Export::encode(alloc::listNil());
}

uint64_t Elm_Kernel_Json_addEntry(uint64_t entry, uint64_t array) {
    (void)entry;
    (void)array;
    assert(false && "Elm_Kernel_Json_addEntry not implemented");
    return 0;
}

uint64_t Elm_Kernel_Json_addField(uint64_t key, uint64_t value, uint64_t object) {
    (void)key;
    (void)value;
    (void)object;
    assert(false && "Elm_Kernel_Json_addField not implemented");
    return 0;
}

} // extern "C"
