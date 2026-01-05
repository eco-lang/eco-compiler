/**
 * Elm Kernel Browser Module - Runtime Heap Integration
 *
 * Provides browser operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific browser APIs.
 */

#include "Browser.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include <chrono>

namespace Elm::Kernel::Browser {

// Browser type ID (use generic 1 for compatibility)
constexpr u16 BROWSER_TYPE_ID = 1;

// Program type tags
constexpr u16 TAG_ELEMENT = 0;
constexpr u16 TAG_DOCUMENT = 1;
constexpr u16 TAG_APPLICATION = 2;

// Dom.Error tags
constexpr u16 TAG_NOT_FOUND = 0;

// ============================================================================
// Helper to create Viewport record
// ============================================================================

static HPointer createViewport(f64 sceneW, f64 sceneH, f64 x, f64 y, f64 w, f64 h) {
    // Create viewport record with scene and viewport sub-records
    // Fields in alphabetical order: scene, viewport
    // scene fields: height, width
    // viewport fields: height, width, x, y

    HPointer sceneHeight = alloc::allocFloat(sceneH);
    HPointer sceneWidth = alloc::allocFloat(sceneW);
    HPointer scene = alloc::record({alloc::boxed(sceneHeight), alloc::boxed(sceneWidth)}, 0);

    HPointer vpHeight = alloc::allocFloat(h);
    HPointer vpWidth = alloc::allocFloat(w);
    HPointer vpX = alloc::allocFloat(x);
    HPointer vpY = alloc::allocFloat(y);
    HPointer viewport = alloc::record({alloc::boxed(vpHeight), alloc::boxed(vpWidth), alloc::boxed(vpX), alloc::boxed(vpY)}, 0);

    return alloc::record({alloc::boxed(scene), alloc::boxed(viewport)}, 0);
}

// Helper to create NotFound error
static HPointer notFound(void* id) {
    HPointer idPtr = Allocator::instance().wrap(id);
    HPointer notFoundErr = alloc::custom(BROWSER_TYPE_ID, TAG_NOT_FOUND, {alloc::boxed(idPtr)}, 0);
    return alloc::err(alloc::boxed(notFoundErr), false);
}

// ============================================================================
// Program Types - Stubs
// ============================================================================

HPointer element(HPointer impl) {
    return alloc::custom(BROWSER_TYPE_ID, TAG_ELEMENT, {alloc::boxed(impl)}, 0);
}

HPointer document(HPointer impl) {
    return alloc::custom(BROWSER_TYPE_ID, TAG_DOCUMENT, {alloc::boxed(impl)}, 0);
}

HPointer application(HPointer impl) {
    return alloc::custom(BROWSER_TYPE_ID, TAG_APPLICATION, {alloc::boxed(impl)}, 0);
}

// ============================================================================
// Navigation - Stubs
// ============================================================================

TaskPtr load(void* url) {
    (void)url;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Navigation never completes - page leaves
        (void)callback;
        return []() {};
    });
}

TaskPtr reload(bool skipCache) {
    (void)skipCache;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Reload never completes
        (void)callback;
        return []() {};
    });
}

TaskPtr pushUrl(NavKeyPtr key, void* url) {
    (void)url;
    return Scheduler::binding([key](Scheduler::Callback callback) -> std::function<void()> {
        if (key && key->notifyUrlChange) {
            key->notifyUrlChange();
        }
        callback(alloc::unit());
        return []() {};
    });
}

TaskPtr replaceUrl(NavKeyPtr key, void* url) {
    (void)url;
    return Scheduler::binding([key](Scheduler::Callback callback) -> std::function<void()> {
        if (key && key->notifyUrlChange) {
            key->notifyUrlChange();
        }
        callback(alloc::unit());
        return []() {};
    });
}

TaskPtr go(NavKeyPtr key, i64 steps) {
    return Scheduler::binding([key, steps](Scheduler::Callback callback) -> std::function<void()> {
        if (steps != 0 && key && key->notifyUrlChange) {
            key->notifyUrlChange();
        }
        callback(alloc::unit());
        return []() {};
    });
}

// ============================================================================
// Viewport - Stubs
// ============================================================================

TaskPtr getViewport() {
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Default viewport: 1920x1080
        HPointer viewport = createViewport(1920, 1080, 0, 0, 1920, 1080);
        callback(viewport);
        return []() {};
    });
}

TaskPtr getViewportOf(void* id) {
    return Scheduler::binding([id](Scheduler::Callback callback) -> std::function<void()> {
        // Element not found - return error
        callback(notFound(id));
        return []() {};
    });
}

TaskPtr setViewport(f64 x, f64 y) {
    (void)x;
    (void)y;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        callback(alloc::unit());
        return []() {};
    });
}

TaskPtr setViewportOf(void* id, f64 x, f64 y) {
    (void)x;
    (void)y;
    return Scheduler::binding([id](Scheduler::Callback callback) -> std::function<void()> {
        callback(notFound(id));
        return []() {};
    });
}

// ============================================================================
// Element queries - Stubs
// ============================================================================

TaskPtr getElement(void* id) {
    return Scheduler::binding([id](Scheduler::Callback callback) -> std::function<void()> {
        callback(notFound(id));
        return []() {};
    });
}

// ============================================================================
// Events - Stubs
// ============================================================================

HPointer on(HPointer node, void* eventName, HPointer handler) {
    (void)node;
    (void)eventName;
    (void)handler;
    // Return placeholder process ID
    return alloc::allocInt(0);
}

HPointer decodeEvent(DecoderPtr decoder, HPointer event) {
    (void)decoder;
    (void)event;
    // Return Nothing
    return alloc::nothing();
}

// ============================================================================
// Document/Window access - Stubs
// ============================================================================

HPointer doc() {
    return alloc::custom(BROWSER_TYPE_ID, 0, {}, 0);
}

HPointer window() {
    return alloc::custom(BROWSER_TYPE_ID, 0, {}, 0);
}

TaskPtr withWindow(std::function<HPointer(HPointer)> func) {
    return Scheduler::binding([func](Scheduler::Callback callback) -> std::function<void()> {
        HPointer win = window();
        HPointer result = func(win);
        callback(result);
        return []() {};
    });
}

// ============================================================================
// Animation - Stub
// ============================================================================

TaskPtr rAF() {
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Return current time as animation frame time
        auto now = std::chrono::system_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
        callback(alloc::allocInt(ms));
        return []() {};
    });
}

// ============================================================================
// Time - Stub
// ============================================================================

TaskPtr now() {
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        auto now = std::chrono::system_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
        callback(alloc::allocInt(ms));
        return []() {};
    });
}

// ============================================================================
// Visibility
// ============================================================================

HPointer visibilityInfo() {
    // Return Visible (ctor 0) - always visible in stub
    return alloc::custom(BROWSER_TYPE_ID, 0, {}, 0);
}

// ============================================================================
// Call helper
// ============================================================================

HPointer call(std::function<HPointer()> func) {
    return func();
}

} // namespace Elm::Kernel::Browser
