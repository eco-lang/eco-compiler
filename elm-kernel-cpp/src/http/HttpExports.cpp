//===- HttpExports.cpp - C-linkage exports for Http module -----------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Http_emptyBody() {
    assert(false && "Elm_Kernel_Http_emptyBody not implemented - requires Http body type");
    return 0;
}

uint64_t Elm_Kernel_Http_pair(uint64_t key, uint64_t value) {
    (void)key;
    (void)value;
    assert(false && "Elm_Kernel_Http_pair not implemented");
    return 0;
}

uint64_t Elm_Kernel_Http_toTask(uint64_t request) {
    (void)request;
    assert(false && "Elm_Kernel_Http_toTask not implemented - requires platform HTTP support");
    return 0;
}

uint64_t Elm_Kernel_Http_expect(uint64_t responseToResult) {
    (void)responseToResult;
    assert(false && "Elm_Kernel_Http_expect not implemented");
    return 0;
}

uint64_t Elm_Kernel_Http_mapExpect(uint64_t closure, uint64_t expectVal) {
    (void)closure;
    (void)expectVal;
    assert(false && "Elm_Kernel_Http_mapExpect not implemented");
    return 0;
}

uint64_t Elm_Kernel_Http_bytesToBlob(uint64_t bytes, uint64_t mimeType) {
    (void)bytes;
    (void)mimeType;
    assert(false && "Elm_Kernel_Http_bytesToBlob not implemented");
    return 0;
}

uint64_t Elm_Kernel_Http_toDataView(uint64_t bytes) {
    (void)bytes;
    assert(false && "Elm_Kernel_Http_toDataView not implemented");
    return 0;
}

uint64_t Elm_Kernel_Http_toFormData(uint64_t parts) {
    (void)parts;
    assert(false && "Elm_Kernel_Http_toFormData not implemented");
    return 0;
}

} // extern "C"
