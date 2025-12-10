#ifndef ECO_BROWSER_HPP
#define ECO_BROWSER_HPP

/**
 * Elm Kernel Browser Module - Runtime Heap Integration
 *
 * Provides browser operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific browser APIs.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../core/Scheduler.hpp"
#include "../json/Json.hpp"
#include <functional>
#include <memory>

namespace Elm::Kernel::Browser {

using TaskPtr = Scheduler::TaskPtr;
using DecoderPtr = Json::DecoderPtr;

// Navigation Key - opaque reference for navigation commands.
struct NavKey {
    std::function<void()> notifyUrlChange;
};
using NavKeyPtr = std::shared_ptr<NavKey>;

// Visibility states for page.
enum class Visibility { Visible, Hidden };

// ============================================================================
// Program Types
// ============================================================================

// Creates an element program.
HPointer element(HPointer impl);

// Creates a document program.
HPointer document(HPointer impl);

// Creates an application program.
HPointer application(HPointer impl);

// ============================================================================
// Navigation
// ============================================================================

// Loads a new URL (full page navigation).
TaskPtr load(void* url);

// Reloads the page.
TaskPtr reload(bool skipCache);

// Pushes a URL onto the history stack.
TaskPtr pushUrl(NavKeyPtr key, void* url);

// Replaces the current URL in history.
TaskPtr replaceUrl(NavKeyPtr key, void* url);

// Navigates forward or back in history.
TaskPtr go(NavKeyPtr key, i64 steps);

// ============================================================================
// Viewport
// ============================================================================

// Returns the viewport dimensions and scroll position.
TaskPtr getViewport();

// Returns viewport info for a specific element.
TaskPtr getViewportOf(void* id);

// Sets the viewport scroll position.
TaskPtr setViewport(f64 x, f64 y);

// Sets scroll position for a specific element.
TaskPtr setViewportOf(void* id, f64 x, f64 y);

// ============================================================================
// Element Queries
// ============================================================================

// Returns element position and size.
TaskPtr getElement(void* id);

// ============================================================================
// Events
// ============================================================================

// Attaches an event handler to a node.
HPointer on(HPointer node, void* eventName, HPointer handler);

// Decodes an event using a JSON decoder.
HPointer decodeEvent(DecoderPtr decoder, HPointer event);

// ============================================================================
// Document/Window Access (Platform-Specific)
// ============================================================================

// Returns a reference to the document.
HPointer doc();

// Returns a reference to the window.
HPointer window();

// Runs a function with the window object.
TaskPtr withWindow(std::function<HPointer(HPointer)> func);

// ============================================================================
// Animation
// ============================================================================

// Requests animation frame.
TaskPtr rAF();

// ============================================================================
// Time
// ============================================================================

// Returns current time (same as Time.now).
TaskPtr now();

// ============================================================================
// Visibility
// ============================================================================

// Returns current page visibility info.
HPointer visibilityInfo();

// ============================================================================
// Call Helper
// ============================================================================

// Calls a function (used for delayed effects).
HPointer call(std::function<HPointer()> func);

} // namespace Elm::Kernel::Browser

#endif // ECO_BROWSER_HPP
