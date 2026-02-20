#ifndef ECO_BROWSER_HPP
#define ECO_BROWSER_HPP

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../json/Json.hpp"
#include <functional>
#include <memory>

namespace Elm::Kernel::Browser {

using DecoderPtr = Json::DecoderPtr;

struct NavKey {
    std::function<void()> notifyUrlChange;
};
using NavKeyPtr = std::shared_ptr<NavKey>;

enum class Visibility { Visible, Hidden };

HPointer element(HPointer impl);
HPointer document(HPointer impl);
HPointer application(HPointer impl);

HPointer load(void* url);
HPointer reload(bool skipCache);
HPointer pushUrl(NavKeyPtr key, void* url);
HPointer replaceUrl(NavKeyPtr key, void* url);
HPointer go(NavKeyPtr key, i64 steps);

HPointer getViewport();
HPointer getViewportOf(void* id);
HPointer setViewport(f64 x, f64 y);
HPointer setViewportOf(void* id, f64 x, f64 y);

HPointer getElement(void* id);

HPointer on(HPointer node, void* eventName, HPointer handler);
HPointer decodeEvent(DecoderPtr decoder, HPointer event);

HPointer doc();
HPointer window();
HPointer withWindow(std::function<HPointer(HPointer)> func);

HPointer rAF();
HPointer now();
HPointer visibilityInfo();
HPointer call(std::function<HPointer()> func);

} // namespace Elm::Kernel::Browser

#endif // ECO_BROWSER_HPP
