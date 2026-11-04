//===- BrowserExports.cpp - C-linkage exports for Browser module -----------===//
//
// The C exports for elm/browser's `Browser` and `Debugger` kernels. Natively there is no DOM,
// navigation or debugger. `element`, `document` and `application` pass their argument through, so a
// program referencing elm/browser links. The kernels behind `Browser.Dom` Tasks that can fail
// (`getViewportOf`, `setViewportOf`, `getElement`, `focus`, `blur`) return a Task failing with
// `NotFound id`: natively no element has that id. Every other one ends the program with
// "<Elm function> is not supported natively" and exit status 1 (`unsupportedNatively`, decision D9 of
// plans/kernel-lib-bug-fixes.md), except `Debugger.unsafeCoerce`, which returns its argument as it does
// in JavaScript. Their contracts are on the declarations in `KernelExports.h`.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "../NotSupportedNatively.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Elm;
using namespace Elm::Kernel;

namespace {

/// Returns a Task that fails with `Browser.Dom.NotFound id`. `Browser.Dom.Error` has one constructor with one
/// field, a box: ctor 0 with the String `id` in a boxed field.
HPtr notFound(HPtr id) {
    HPointer error = alloc::custom(0, {alloc::boxed(Export::decode(id.toBits()))}, 0);
    return Elm_Kernel_Scheduler_fail(HPtr::fromBits(Export::encode(error)));
}

} // anonymous namespace

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
    unsupportedNatively("Browser.Navigation.load");
}

HPtr Elm_Kernel_Browser_reload(HPtr skipCache) {
    (void)skipCache;
    unsupportedNatively("Browser.Navigation.reload");
}

HPtr Elm_Kernel_Browser_pushUrl(HPtr key, HPtr url) {
    (void)key;
    (void)url;
    unsupportedNatively("Browser.Navigation.pushUrl");
}

HPtr Elm_Kernel_Browser_replaceUrl(HPtr key, HPtr url) {
    (void)key;
    (void)url;
    unsupportedNatively("Browser.Navigation.replaceUrl");
}

HPtr Elm_Kernel_Browser_go(HPtr key, int64_t steps) {
    (void)key;
    (void)steps;
    unsupportedNatively("Browser.Navigation.back/forward");
}

HPtr Elm_Kernel_Browser_getViewport() {
    unsupportedNatively("Browser.Dom.getViewport");
}

HPtr Elm_Kernel_Browser_getViewportOf(HPtr id) {
    return notFound(id);
}

HPtr Elm_Kernel_Browser_setViewport(double x, double y) {
    (void)x;
    (void)y;
    unsupportedNatively("Browser.Dom.setViewport");
}

HPtr Elm_Kernel_Browser_setViewportOf(HPtr id, double x, double y) {
    (void)x;
    (void)y;
    return notFound(id);
}

HPtr Elm_Kernel_Browser_getElement(HPtr id) {
    return notFound(id);
}

HPtr Elm_Kernel_Browser_on(HPtr node, HPtr eventName, HPtr handler) {
    (void)node;
    (void)eventName;
    (void)handler;
    unsupportedNatively("Browser.Events.on");
}

HPtr Elm_Kernel_Browser_decodeEvent(HPtr decoder, HPtr event) {
    (void)decoder;
    (void)event;
    unsupportedNatively("Browser.Events.on");
}

HPtr Elm_Kernel_Browser_doc() {
    unsupportedNatively("Browser.Events.on");
}

HPtr Elm_Kernel_Browser_window() {
    unsupportedNatively("Browser.Events.on");
}

HPtr Elm_Kernel_Browser_withWindow(HPtr closure) {
    (void)closure;
    unsupportedNatively("Browser.Dom.getViewport");
}

HPtr Elm_Kernel_Browser_rAF() {
    unsupportedNatively("Browser.Events.onAnimationFrame");
}

HPtr Elm_Kernel_Browser_now() {
    unsupportedNatively("Browser.Events.onAnimationFrame");
}

HPtr Elm_Kernel_Browser_visibilityInfo() {
    unsupportedNatively("Browser.Events.onVisibilityChange");
}

HPtr Elm_Kernel_Browser_call(HPtr functionName, HPtr id) {
    (void)functionName;
    return notFound(id);
}

//===----------------------------------------------------------------------===//
// Debugger Module (elm/browser) - Browser debugging tools
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Debugger_init(HPtr value) {
    (void)value;
    unsupportedNatively("The Elm debugger (Debugger.init)");
}

HPtr Elm_Kernel_Debugger_isOpen(HPtr popout) {
    (void)popout;
    unsupportedNatively("The Elm debugger (Debugger.isOpen)");
}

HPtr Elm_Kernel_Debugger_open(HPtr popout) {
    (void)popout;
    unsupportedNatively("The Elm debugger (Debugger.open)");
}

HPtr Elm_Kernel_Debugger_scroll(HPtr popout) {
    (void)popout;
    unsupportedNatively("The Elm debugger (Debugger.scroll)");
}

HPtr Elm_Kernel_Debugger_messageToString(HPtr message) {
    (void)message;
    unsupportedNatively("The Elm debugger (Debugger.messageToString)");
}

HPtr Elm_Kernel_Debugger_download(int64_t historyLength, HPtr json) {
    (void)historyLength;
    (void)json;
    unsupportedNatively("The Elm debugger (Debugger.download)");
}

HPtr Elm_Kernel_Debugger_upload() {
    unsupportedNatively("The Elm debugger (Debugger.upload)");
}

HPtr Elm_Kernel_Debugger_unsafeCoerce(HPtr value) {
    return value;
}

} // extern "C"
