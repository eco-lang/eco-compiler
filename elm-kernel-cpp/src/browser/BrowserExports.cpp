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

HPtr Elm_Kernel_Browser_element(HPtr impl) {
    return impl;
}

HPtr Elm_Kernel_Browser_document(HPtr impl) {
    return impl;
}

HPtr Elm_Kernel_Browser_application(HPtr impl) {
    return impl;
}

HPtr Elm_Kernel_Browser_load(HPtr url) {
    (void)url;
    assert(false && "Elm_Kernel_Browser_load not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_reload(bool skipCache) {
    (void)skipCache;
    assert(false && "Elm_Kernel_Browser_reload not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_pushUrl(HPtr key, HPtr url) {
    (void)key;
    (void)url;
    assert(false && "Elm_Kernel_Browser_pushUrl not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_replaceUrl(HPtr key, HPtr url) {
    (void)key;
    (void)url;
    assert(false && "Elm_Kernel_Browser_replaceUrl not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_go(HPtr key, int64_t steps) {
    (void)key;
    (void)steps;
    assert(false && "Elm_Kernel_Browser_go not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_getViewport() {
    assert(false && "Elm_Kernel_Browser_getViewport not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_getViewportOf(HPtr id) {
    (void)id;
    assert(false && "Elm_Kernel_Browser_getViewportOf not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_setViewport(double x, double y) {
    (void)x;
    (void)y;
    assert(false && "Elm_Kernel_Browser_setViewport not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_setViewportOf(HPtr id, double x, double y) {
    (void)id;
    (void)x;
    (void)y;
    assert(false && "Elm_Kernel_Browser_setViewportOf not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_getElement(HPtr id) {
    (void)id;
    assert(false && "Elm_Kernel_Browser_getElement not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_on(HPtr node, HPtr eventName, HPtr handler) {
    (void)node;
    (void)eventName;
    (void)handler;
    assert(false && "Elm_Kernel_Browser_on not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_decodeEvent(HPtr decoder, HPtr event) {
    (void)decoder;
    (void)event;
    assert(false && "Elm_Kernel_Browser_decodeEvent not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_doc() {
    assert(false && "Elm_Kernel_Browser_doc not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_window() {
    assert(false && "Elm_Kernel_Browser_window not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_withWindow(HPtr closure) {
    (void)closure;
    assert(false && "Elm_Kernel_Browser_withWindow not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_rAF() {
    assert(false && "Elm_Kernel_Browser_rAF not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_now() {
    assert(false && "Elm_Kernel_Browser_now not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_visibilityInfo() {
    assert(false && "Elm_Kernel_Browser_visibilityInfo not implemented - requires platform");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Browser_call(HPtr closure) {
    (void)closure;
    assert(false && "Elm_Kernel_Browser_call not implemented - requires platform");
    return HPtr::fromBits(0);
}

//===----------------------------------------------------------------------===//
// Debugger Module (elm/browser) - Browser debugging tools
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Debugger_init(HPtr value) {
    (void)value;
    assert(false && "Elm_Kernel_Debugger_init not implemented - requires browser");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debugger_isOpen(HPtr popout) {
    (void)popout;
    assert(false && "Elm_Kernel_Debugger_isOpen not implemented - requires browser");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debugger_open(HPtr popout) {
    (void)popout;
    assert(false && "Elm_Kernel_Debugger_open not implemented - requires browser");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debugger_scroll(HPtr popout) {
    (void)popout;
    assert(false && "Elm_Kernel_Debugger_scroll not implemented - requires browser");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debugger_messageToString(HPtr message) {
    (void)message;
    assert(false && "Elm_Kernel_Debugger_messageToString not implemented - requires browser");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debugger_download(int64_t historyLength, HPtr json) {
    (void)historyLength;
    (void)json;
    assert(false && "Elm_Kernel_Debugger_download not implemented - requires browser");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debugger_upload() {
    assert(false && "Elm_Kernel_Debugger_upload not implemented - requires browser");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Debugger_unsafeCoerce(HPtr value) {
    (void)value;
    assert(false && "Elm_Kernel_Debugger_unsafeCoerce not implemented - requires browser");
    return HPtr::fromBits(0);
}

} // extern "C"
