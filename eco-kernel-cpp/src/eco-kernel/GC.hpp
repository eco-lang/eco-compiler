#ifndef ECO_GC_HPP
#define ECO_GC_HPP

// Eco.GC kernel (plans/frontend-heap-release.md §4.3, HEAP_076): explicit
// collections as Task bindings. Each step returns the GCReport as a JSON
// string (keys = the Elm field names of Eco.GC.GCReport, every value an
// integer except `kind`), which Eco/GC.elm decodes.

#include <cstdint>

namespace Eco::Kernel::GC {

uint64_t minorGC();
uint64_t majorGC();

} // namespace Eco::Kernel::GC

#endif // ECO_GC_HPP
