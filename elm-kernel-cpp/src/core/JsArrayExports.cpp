//===- JsArrayExports.cpp - C-linkage exports for JsArray module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "JsArray.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_JsArray_empty() {
    return Export::encode(JsArray::empty());
}

uint64_t Elm_Kernel_JsArray_singleton(uint64_t value) {
    return Export::encode(JsArray::singleton(Export::decode(value)));
}

uint32_t Elm_Kernel_JsArray_length(uint64_t array) {
    return JsArray::length(Export::toPtr(array));
}

uint64_t Elm_Kernel_JsArray_unsafeGet(uint32_t index, uint64_t array) {
    Unboxable result = JsArray::unsafeGet(index, Export::toPtr(array));
    // Assume boxed for now - in full implementation, need unboxed tracking
    return Export::encode(result.p);
}

uint64_t Elm_Kernel_JsArray_unsafeSet(uint32_t index, uint64_t value, uint64_t array) {
    HPointer result = JsArray::unsafeSet(index, Export::decode(value), Export::toPtr(array));
    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_push(uint64_t value, uint64_t array) {
    HPointer result = JsArray::push(Export::decode(value), Export::toPtr(array));
    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_slice(int64_t start, int64_t end, uint64_t array) {
    HPointer result = JsArray::slice(start, end, Export::toPtr(array));
    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_appendN(uint32_t n, uint64_t dest, uint64_t source) {
    HPointer result = JsArray::appendN(n, Export::toPtr(dest), Export::toPtr(source));
    return Export::encode(result);
}

} // extern "C"
