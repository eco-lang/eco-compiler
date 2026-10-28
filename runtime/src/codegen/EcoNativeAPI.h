//===- EcoNativeAPI.h - C ABI bridge for Elm-side kernel intrinsics ------===//
//
// A program can lower eco-dialect MLIR to a native binary in-process (the
// final link still runs an external linker), and this header is the C
// interface it does that through. It declares two functions with C linkage,
// one taking the MLIR in a file and one taking it in memory, so that code
// outside the codegen library, such as the C++ kernel functions behind the
// Elm module `Eco.NativeDriver`, can call them.
//
// Two definitions exist and the linker chooses. `EcoNativeDriverStatic`
// defines both functions and does the work. `eco_native_stub.cpp`, which is
// linked into `EcoEntryStatic` and `EcoEmbedStatic`, defines both as weak
// symbols that return -1. A binary that links the driver gets the driver's
// definitions; one that does not still links, and a call returns -1 at run
// time. This header adds no linkage attribute of its own.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_NATIVE_API_H
#define ECO_NATIVE_API_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lowers the MLIR in the file at `mlirPath` and links it into a native
/// binary at `outputPath`. Returns 0 on success and nonzero on failure.
///
/// The file may hold MLIR text or bytecode. The kind of binary follows from
/// the extension of `outputPath`: `.o` gives an object file, `.so` or `.node`
/// a shared library, and anything else an executable. `rootModule`, which may
/// be null or empty, is the name of the program's root Elm module; when it is
/// non-empty and the output is a shared library, the name is stored in the
/// binary as the symbol `__eco_root_module`, and otherwise it is ignored. The
/// driver's errors are written to standard error. The stub definition returns
/// -1 without doing anything.
int eco_native_lower_and_link(const char *mlirPath, const char *outputPath,
                              const char *rootModule);

/// Lowers the `mlirLen` bytes of MLIR at `mlirBytes` and links them into a
/// native binary at `outputPath`, as `eco_native_lower_and_link` does for a
/// file, except that no root module name can be given. The bytes are read
/// only during the call.
int eco_native_lower_and_link_bytes(const char *mlirBytes, size_t mlirLen,
                                    const char *outputPath);

#ifdef __cplusplus
}
#endif

#endif // ECO_NATIVE_API_H
