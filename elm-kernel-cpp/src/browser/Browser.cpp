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

// UrlRequest type tags
constexpr u16 TAG_INTERNAL = 0;
constexpr u16 TAG_EXTERNAL = 1;

// Dom.Error tags
constexpr u16 TAG_NOT_FOUND = 0;

// Result tags
constexpr u16 TAG_OK = 0;
constexpr u16 TAG_ERR = 1;

// Program type tags
constexpr u16 TAG_ELEMENT = 0;
constexpr u16 TAG_DOCUMENT = 1;
constexpr u16 TAG_APPLICATION = 2;

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

// ============================================================================
// Program Types - Stubs
// ============================================================================

HPointer element(HPointer impl) {
    return alloc::custom(TAG_ELEMENT, {alloc::boxed(impl)}, 0);
}

HPointer document(HPointer impl) {
    return alloc::custom(TAG_DOCUMENT, {alloc::boxed(impl)}, 0);
}

HPointer application(HPointer impl) {
    return alloc::custom(TAG_APPLICATION, {alloc::boxed(impl)}, 0);
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
// Focus management - Stubs
// ============================================================================

TaskPtr focus(void* id) {
    return Scheduler::binding([id](Scheduler::Callback callback) -> std::function<void()> {
        callback(notFound(id));
        return []() {};
    });
}

TaskPtr blur(void* id) {
    return Scheduler::binding([id](Scheduler::Callback callback) -> std::function<void()> {
        callback(notFound(id));
        return []() {};
    });
}

// ============================================================================
// Events - Stubs
// ============================================================================

HPointer onEvent(HPointer node, void* eventName, HPointer handler) {
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

HPointer getDocument() {
    return alloc::custom(0, {}, 0);
}

HPointer getWindow() {
    return alloc::custom(0, {}, 0);
}

// ============================================================================
// Visibility
// ============================================================================

Visibility getVisibility() {
    // Always visible in stub implementation
    return Visibility::Visible;
}

// ============================================================================
// URL helpers
// ============================================================================

HPointer internal(HPointer url) {
    return alloc::custom(TAG_INTERNAL, {alloc::boxed(url)}, 0);
}

HPointer external(void* url) {
    HPointer urlPtr = Allocator::instance().wrap(url);
    return alloc::custom(TAG_EXTERNAL, {alloc::boxed(urlPtr)}, 0);
}

// ============================================================================
// Dom error
// ============================================================================

HPointer notFound(void* id) {
    // Create Dom.NotFound error wrapped in Result.Err
    HPointer idPtr = Allocator::instance().wrap(id);
    HPointer notFoundErr = alloc::custom(TAG_NOT_FOUND, {alloc::boxed(idPtr)}, 0);
    return alloc::err(alloc::boxed(notFoundErr), false);
}

} // namespace Elm::Kernel::Browser
