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

// URL Request types for application
enum class UrlRequestType { Internal, External };

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
// Focus management
// ============================================================================

/**
 * Focus an element by ID.
 */
TaskPtr focus(void* id);

/**
 * Blur (unfocus) an element by ID.
 */
TaskPtr blur(void* id);

// ============================================================================
// Events
// ============================================================================

/**
 * Attach an event handler to a node.
 */
HPointer onEvent(HPointer node, void* eventName, HPointer handler);

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
HPointer getDocument();

/**
 * Get a reference to the window.
 */
HPointer getWindow();

// ============================================================================
// Visibility
// ============================================================================

/**
 * Get current page visibility.
 */
Visibility getVisibility();

// ============================================================================
// URL helpers
// ============================================================================

/**
 * Create an internal URL request.
 */
HPointer internal(HPointer url);

/**
 * Create an external URL request.
 */
HPointer external(void* url);

// ============================================================================
// Dom error
// ============================================================================

/**
 * Create a NotFound error for an element ID.
 */
HPointer notFound(void* id);

} // namespace Elm::Kernel::Browser

#endif // ELM_KERNEL_BROWSER_HPP
