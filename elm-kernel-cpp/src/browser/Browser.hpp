#ifndef ELM_KERNEL_BROWSER_HPP
#define ELM_KERNEL_BROWSER_HPP

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

// Navigation Key - opaque reference for navigation commands
struct NavKey {
    std::function<void()> notifyUrlChange;
};
using NavKeyPtr = std::shared_ptr<NavKey>;

// Visibility
enum class Visibility { Visible, Hidden };

// ============================================================================
// Program types
// ============================================================================

/**
 * Create an element program.
 */
HPointer element(HPointer impl);

/**
 * Create a document program.
 */
HPointer document(HPointer impl);

/**
 * Create an application program.
 */
HPointer application(HPointer impl);

// ============================================================================
// Navigation
// ============================================================================

/**
 * Load a new URL (full page navigation).
 */
TaskPtr load(void* url);

/**
 * Reload the page.
 */
TaskPtr reload(bool skipCache);

/**
 * Push a URL onto the history stack.
 */
TaskPtr pushUrl(NavKeyPtr key, void* url);

/**
 * Replace the current URL in history.
 */
TaskPtr replaceUrl(NavKeyPtr key, void* url);

/**
 * Navigate forward or back in history.
 */
TaskPtr go(NavKeyPtr key, i64 steps);

// ============================================================================
// Viewport
// ============================================================================

/**
 * Get the viewport dimensions and scroll position.
 */
TaskPtr getViewport();

/**
 * Get viewport info for a specific element.
 */
TaskPtr getViewportOf(void* id);

/**
 * Set the viewport scroll position.
 */
TaskPtr setViewport(f64 x, f64 y);

/**
 * Set scroll position for a specific element.
 */
TaskPtr setViewportOf(void* id, f64 x, f64 y);

// ============================================================================
// Element queries
// ============================================================================

/**
 * Get element position and size.
 */
TaskPtr getElement(void* id);

// ============================================================================
// Events
// ============================================================================

/**
 * Attach an event handler to a node.
 */
HPointer on(HPointer node, void* eventName, HPointer handler);

/**
 * Decode an event using a JSON decoder.
 */
HPointer decodeEvent(DecoderPtr decoder, HPointer event);

// ============================================================================
// Document/Window access (platform-specific)
// ============================================================================

/**
 * Get a reference to the document.
 */
HPointer doc();

/**
 * Get a reference to the window.
 */
HPointer window();

/**
 * Run a function with the window object.
 */
TaskPtr withWindow(std::function<HPointer(HPointer)> func);

// ============================================================================
// Animation
// ============================================================================

/**
 * Request animation frame.
 */
TaskPtr rAF();

// ============================================================================
// Time
// ============================================================================

/**
 * Get current time (same as Time.now).
 */
TaskPtr now();

// ============================================================================
// Visibility
// ============================================================================

/**
 * Get current page visibility info.
 */
HPointer visibilityInfo();

// ============================================================================
// Call helper
// ============================================================================

/**
 * Call a function (used for delayed effects).
 */
HPointer call(std::function<HPointer()> func);

} // namespace Elm::Kernel::Browser

#endif // ELM_KERNEL_BROWSER_HPP
