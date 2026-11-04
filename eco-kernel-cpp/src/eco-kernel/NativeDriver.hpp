//===- NativeDriver.hpp - Eco kernel module: MLIR -> native driver bridge -===//
//
// The Elm module `Eco.NativeDriver` lets a program lower eco-dialect MLIR to a native binary in-process. The work
// is done by the two C functions that the runtime's `codegen/EcoNativeAPI.h` declares, `eco_native_lower_and_link`
// (MLIR in a file) and `eco_native_lower_and_link_bytes` (MLIR in memory); this component wraps each in an Elm Task.
//
// Each function here copies its arguments into a Task binding, so nothing runs when it is called. When the
// scheduler steps the Task, the binding body converts the arguments to C strings or a byte range, calls the C
// function on the thread stepping the Task, and blocks that thread until the driver returns.
//
// Whether lowering is available depends on what the program links. `EcoNativeAPI.h` owns the rule: a binary that
// links `EcoNativeDriverStatic` gets the real definitions, and one built on `EcoEntryStatic` or `EcoEmbedStatic`
// without it gets weak stand-ins that return -1, so the Task fails as for any other non-zero code.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_NATIVE_DRIVER_KERNEL_HPP
#define ECO_NATIVE_DRIVER_KERNEL_HPP

#include <cstdint>

namespace Eco::Kernel::NativeDriver {

/// Returns a Task that lowers the MLIR file named by the Elm String `mlirPath` and links it into a native binary at
/// the Elm String `outputPath`, then succeeds with Unit. `rootModule` is an Elm String passed to the driver as the
/// program's root module name; `EcoNativeAPI.h` says when the driver uses it. The arguments and the result are
/// kernel ABI words.
///
/// The Task fails with the String `Eco.NativeDriver.lowerAndLink: lowering/linking failed (rc=<code>)` when the
/// driver returns a non-zero code. Calling this allocates the binding, so it is a GC point.
uint64_t lowerAndLink(uint64_t mlirPath, uint64_t outputPath,
                      uint64_t rootModule);

/// Returns a Task like `lowerAndLink`, except that the MLIR is the contents of the Elm Bytes value `bytes` and no
/// root module name is passed. Its failure message begins `Eco.NativeDriver.lowerAndLinkBytes:`.
uint64_t lowerAndLinkBytes(uint64_t bytes, uint64_t outputPath);

} // namespace Eco::Kernel::NativeDriver

#endif // ECO_NATIVE_DRIVER_KERNEL_HPP
