//===- NativeDriver.hpp - Eco kernel module: MLIR -> ELF driver bridge ----===//
//
// Kernel intrinsic that exposes EcoNativeAPI's `eco_native_lower_and_link`
// to the Elm front-end. Used by `Eco.NativeDriver.lowerAndLink` (called from
// `Terminal.Make.handleElfOutput` in the unified `eco` binary).
//
// The intrinsic is declared in every AOT-compiled binary's link line
// because the front-end MLIR may reference it, but only the `eco` binary
// (which links `EcoNativeDriverStatic`) actually has a strong implementation
// of the underlying `eco_native_lower_and_link` symbol. Other binaries
// (eco-compiler, user AOT programs) link the weak undefined reference and
// the kernel implementation surfaces a runtime error if called.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_NATIVE_DRIVER_KERNEL_HPP
#define ECO_NATIVE_DRIVER_KERNEL_HPP

#include <cstdint>

namespace Eco::Kernel::NativeDriver {

// Compile MLIR text from `mlirPath` to an ELF executable at `outputPath`.
// `rootModule` is the program's root module name, baked into the binary as
// `__eco_root_module` for the N-API addon's Elm.<RootModule> export.
// Returns a Task: succeeds with Unit on success, fails with a String error
// message otherwise.
uint64_t lowerAndLink(uint64_t mlirPath, uint64_t outputPath,
                      uint64_t rootModule);

// In-memory variant — Phase 2 entry. `bytes` is an Elm Bytes value carrying
// the full MLIR text; `outputPath` is the ELF path.
uint64_t lowerAndLinkBytes(uint64_t bytes, uint64_t outputPath);

} // namespace Eco::Kernel::NativeDriver

#endif // ECO_NATIVE_DRIVER_KERNEL_HPP
