#ifndef ECO_GC_HPP
#define ECO_GC_HPP

// The Eco.GC kernel: lets an Elm program ask for a garbage collection and see what it did.
//
// Each function returns a Binding Task (see `makeBinding` in `TaskBinding.hpp`), so the collection runs each time
// the Task is stepped, never when the function is called (KERNEL_TASK_IO_001). The Task succeeds with an Elm String
// holding the collection's `Elm::GCReport` as a JSON object: `kind` is `"minor"` or `"major"`, `collected` is always
// 1, and every other key is the camelCase name of a report field with its integer value. If the report cannot be
// formatted the String is `{"kind":"error"}`. The values are observations; nothing may branch on them (HEAP_076).

#include <cstdint>

namespace Eco::Kernel::GC {

/// Returns, as a kernel ABI word, a Task that runs `Elm::Allocator::collectMinor` and succeeds with its report.
/// A GC point.
uint64_t minorGC();

/// Returns, as a kernel ABI word, a Task that runs `Elm::Allocator::collectMajorAndRelease` and succeeds with its
/// report. A GC point.
uint64_t majorGC();

} // namespace Eco::Kernel::GC

#endif // ECO_GC_HPP
