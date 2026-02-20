#include "Browser.hpp"
#include "allocator/Allocator.hpp"
#include <cassert>
#include <chrono>

namespace Elm::Kernel::Browser {

HPointer element(HPointer impl) {
    return alloc::custom(0, {alloc::boxed(impl)}, 0);
}

HPointer document(HPointer impl) {
    return alloc::custom(1, {alloc::boxed(impl)}, 0);
}

HPointer application(HPointer impl) {
    return alloc::custom(2, {alloc::boxed(impl)}, 0);
}

HPointer load(void*) {
    assert(false && "Browser.load not implemented in native runtime");
    return alloc::unit();
}

HPointer reload(bool) {
    assert(false && "Browser.reload not implemented in native runtime");
    return alloc::unit();
}

HPointer pushUrl(NavKeyPtr, void*) {
    assert(false && "Browser.pushUrl not implemented in native runtime");
    return alloc::unit();
}

HPointer replaceUrl(NavKeyPtr, void*) {
    assert(false && "Browser.replaceUrl not implemented in native runtime");
    return alloc::unit();
}

HPointer go(NavKeyPtr, i64) {
    assert(false && "Browser.go not implemented in native runtime");
    return alloc::unit();
}

HPointer getViewport() {
    assert(false && "Browser.getViewport not implemented in native runtime");
    return alloc::unit();
}

HPointer getViewportOf(void*) {
    assert(false && "Browser.getViewportOf not implemented in native runtime");
    return alloc::unit();
}

HPointer setViewport(f64, f64) {
    assert(false && "Browser.setViewport not implemented in native runtime");
    return alloc::unit();
}

HPointer setViewportOf(void*, f64, f64) {
    assert(false && "Browser.setViewportOf not implemented in native runtime");
    return alloc::unit();
}

HPointer getElement(void*) {
    assert(false && "Browser.getElement not implemented in native runtime");
    return alloc::unit();
}

HPointer on(HPointer, void*, HPointer) {
    return alloc::allocInt(0);
}

HPointer decodeEvent(DecoderPtr, HPointer) {
    return alloc::nothing();
}

HPointer doc() {
    return alloc::custom(0, {}, 0);
}

HPointer window() {
    return alloc::custom(0, {}, 0);
}

HPointer withWindow(std::function<HPointer(HPointer)>) {
    assert(false && "Browser.withWindow not implemented in native runtime");
    return alloc::unit();
}

HPointer rAF() {
    assert(false && "Browser.rAF not implemented in native runtime");
    return alloc::unit();
}

HPointer now() {
    assert(false && "Browser.now not implemented in native runtime");
    return alloc::unit();
}

HPointer visibilityInfo() {
    return alloc::custom(0, {}, 0);
}

HPointer call(std::function<HPointer()> func) {
    return func();
}

} // namespace Elm::Kernel::Browser
