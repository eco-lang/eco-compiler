//===- BrowserExports.cpp - C-linkage exports for Browser module -----------===//
//
// Browser module exports - mostly stubs since they require platform integration.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Browser_element(uint64_t impl) {
    return impl;
}

uint64_t Elm_Kernel_Browser_document(uint64_t impl) {
    return impl;
}

uint64_t Elm_Kernel_Browser_application(uint64_t impl) {
    return impl;
}

uint64_t Elm_Kernel_Browser_load(uint64_t url) {
    (void)url;
    assert(false && "Elm_Kernel_Browser_load not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_reload(bool skipCache) {
    (void)skipCache;
    assert(false && "Elm_Kernel_Browser_reload not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_pushUrl(uint64_t key, uint64_t url) {
    (void)key;
    (void)url;
    assert(false && "Elm_Kernel_Browser_pushUrl not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_replaceUrl(uint64_t key, uint64_t url) {
    (void)key;
    (void)url;
    assert(false && "Elm_Kernel_Browser_replaceUrl not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_go(uint64_t key, int64_t steps) {
    (void)key;
    (void)steps;
    assert(false && "Elm_Kernel_Browser_go not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_getViewport() {
    assert(false && "Elm_Kernel_Browser_getViewport not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_getViewportOf(uint64_t id) {
    (void)id;
    assert(false && "Elm_Kernel_Browser_getViewportOf not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_setViewport(double x, double y) {
    (void)x;
    (void)y;
    assert(false && "Elm_Kernel_Browser_setViewport not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_setViewportOf(uint64_t id, double x, double y) {
    (void)id;
    (void)x;
    (void)y;
    assert(false && "Elm_Kernel_Browser_setViewportOf not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_getElement(uint64_t id) {
    (void)id;
    assert(false && "Elm_Kernel_Browser_getElement not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_on(uint64_t node, uint64_t eventName, uint64_t handler) {
    (void)node;
    (void)eventName;
    (void)handler;
    assert(false && "Elm_Kernel_Browser_on not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_decodeEvent(uint64_t decoder, uint64_t event) {
    (void)decoder;
    (void)event;
    assert(false && "Elm_Kernel_Browser_decodeEvent not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_doc() {
    assert(false && "Elm_Kernel_Browser_doc not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_window() {
    assert(false && "Elm_Kernel_Browser_window not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_withWindow(uint64_t closure) {
    (void)closure;
    assert(false && "Elm_Kernel_Browser_withWindow not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_rAF() {
    assert(false && "Elm_Kernel_Browser_rAF not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_now() {
    assert(false && "Elm_Kernel_Browser_now not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_visibilityInfo() {
    assert(false && "Elm_Kernel_Browser_visibilityInfo not implemented - requires platform");
    return 0;
}

uint64_t Elm_Kernel_Browser_call(uint64_t closure) {
    (void)closure;
    assert(false && "Elm_Kernel_Browser_call not implemented - requires platform");
    return 0;
}

} // extern "C"
