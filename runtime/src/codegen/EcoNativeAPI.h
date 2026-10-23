//===- EcoNativeAPI.h - C ABI bridge for Elm-side kernel intrinsics ------===//
//
// Exposes the EcoNativeDriver library functions with C linkage so the
// Eco_Kernel_NativeDriver_* C++ kernel exports can call them and, by
// extension, so the Elm front-end can invoke MLIR lowering + native linking
// in-process via `Eco.NativeDriver.lowerAndLink`.
//
// Implementations live in EcoNativeDriver.cpp (EcoNativeDriverStatic).
// Stub-friendly: `eco_native_lower_and_link` is declared without weak
// linkage here so callers get a link error if EcoNativeDriverStatic is
// missing from the link line. Binaries that need a stub provide one in a
// dedicated stub TU.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_NATIVE_API_H
#define ECO_NATIVE_API_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// MLIR file path (text or bytecode) -> native executable path. This is the
// hand-off `eco make` uses: Terminal/Make.elm `handleElfOutput` writes a temp
// MLIR file (bytecode unless text MLIR is requested) and calls
// `Eco.NativeDriver.lowerAndLink`, which forwards here. Returns 0 on success,
// nonzero on failure (errors printed to stderr via the LLVM diagnostics
// machinery).
// rootModule (nullable/empty allowed) is baked into the program as the
// __eco_root_module symbol so the N-API addon names the Elm.<RootModule>
// export after the program's actual root module instead of "Main".
int eco_native_lower_and_link(const char *mlirPath, const char *outputPath,
                              const char *rootModule);

// In-memory MLIR -> native executable (`Eco.NativeDriver.lowerAndLinkBytes`).
// Not on the `eco make` path, which goes through the file variant above.
int eco_native_lower_and_link_bytes(const char *mlirBytes, size_t mlirLen,
                                    const char *outputPath);

#ifdef __cplusplus
}
#endif

#endif // ECO_NATIVE_API_H
