#ifndef ECO_BROWSER_HPP
#define ECO_BROWSER_HPP

// A C++ API for elm/browser's kernel functions that nothing calls.
//
// elm/browser's kernel functions need a DOM, a window, navigation history and a debugger UI, and a
// natively compiled program has none of these. What compiled Elm code actually calls is the set of
// C-linkage exports declared in `KernelExports.h` and defined in `BrowserExports.cpp`. They exist so
// that a program which references elm/browser still links: `element`, `document` and `application`
// return their argument unchanged, and every other export asserts, or returns the word 0 when
// assertions are compiled out. Word 0 is neither an embedded constant nor a heap object.
//
// The functions declared here are a separate C++ API in the `Elm::Kernel::Browser` namespace. They are
// compiled into the `ElmKernel_Browser` library, but no code in the kernel libraries calls them, and
// they do not behave like the exports: `element`, `document` and `application` here wrap their
// argument in a Custom instead of passing it through, and several functions here return a value
// where the export asserts.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../json/Json.hpp"
#include <functional>
#include <memory>

namespace Elm::Kernel::Browser {

/// Another name for `Json::DecoderPtr`, a shared pointer to a decoder type that is never defined.
using DecoderPtr = Json::DecoderPtr;

/// A navigation key, the handle a URL-changing function is given.
///
/// Nothing in this API creates one or calls `notifyUrlChange`; the functions that take a key assert
/// without using it.
struct NavKey {
    std::function<void()> notifyUrlChange;
};
/// A shared pointer to a `NavKey`. It may be empty.
using NavKeyPtr = std::shared_ptr<NavKey>;

/// Whether the page is visible or hidden. Nothing in this API produces or reads a `Visibility`.
enum class Visibility { Visible, Hidden };

/// Returns a new Custom with constructor 0 whose one boxed field is `impl`. Allocates.
HPointer element(HPointer impl);
/// Returns a new Custom with constructor 1 whose one boxed field is `impl`. Allocates.
HPointer document(HPointer impl);
/// Returns a new Custom with constructor 2 whose one boxed field is `impl`. Allocates.
HPointer application(HPointer impl);

/// Asserts. With assertions compiled out, returns Unit and does nothing.
HPointer load(void* url);
/// Asserts. With assertions compiled out, returns Unit and does nothing.
HPointer reload(bool skipCache);
/// Asserts. With assertions compiled out, returns Unit and does nothing.
HPointer pushUrl(NavKeyPtr key, void* url);
/// Asserts. With assertions compiled out, returns Unit and does nothing.
HPointer replaceUrl(NavKeyPtr key, void* url);
/// Asserts. With assertions compiled out, returns Unit and does nothing.
HPointer go(NavKeyPtr key, i64 steps);

/// Asserts. With assertions compiled out, returns Unit.
HPointer getViewport();
/// Asserts. With assertions compiled out, returns Unit.
HPointer getViewportOf(void* id);
/// Asserts. With assertions compiled out, returns Unit and does nothing.
HPointer setViewport(f64 x, f64 y);
/// Asserts. With assertions compiled out, returns Unit and does nothing.
HPointer setViewportOf(void* id, f64 x, f64 y);

/// Asserts. With assertions compiled out, returns Unit.
HPointer getElement(void* id);

/// Ignores its arguments and returns a new boxed Int 0. Allocates.
HPointer on(HPointer node, void* eventName, HPointer handler);
/// Ignores its arguments and returns `Nothing`.
HPointer decodeEvent(DecoderPtr decoder, HPointer event);

/// Returns the nullary constructor 0 constant.
HPointer doc();
/// Returns the nullary constructor 0 constant.
HPointer window();
/// Asserts without calling `func`. With assertions compiled out, returns Unit.
HPointer withWindow(std::function<HPointer(HPointer)> func);

/// Asserts. With assertions compiled out, returns Unit.
HPointer rAF();
/// Asserts. With assertions compiled out, returns Unit.
HPointer now();
/// Returns the nullary constructor 0 constant.
HPointer visibilityInfo();
/// Calls `func` once and returns what it returns. An empty `func` throws `std::bad_function_call`.
HPointer call(std::function<HPointer()> func);

} // namespace Elm::Kernel::Browser

#endif // ECO_BROWSER_HPP
