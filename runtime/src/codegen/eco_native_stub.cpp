//===- eco_native_stub.cpp - Weak stubs for EcoNativeAPI ------------------===//
//
// A program built on `EcoEntryStatic` or `EcoEmbedStatic` may call the two
// functions `EcoNativeAPI.h` declares without linking the MLIR/LLVM driver
// that implements them, and this file is what makes such a program link. It
// is compiled into both of those libraries.
//
// It defines both functions as weak symbols that do nothing and return -1,
// meaning that no lowering is available. When `EcoNativeDriverStatic` is also
// linked, the linker takes its strong definitions instead and these are
// unused. The contracts are on the declarations in `EcoNativeAPI.h`.
//
//===----------------------------------------------------------------------===//

#include <stddef.h>

extern "C" {

// Returns -1 without reading its arguments.
__attribute__((weak)) int eco_native_lower_and_link(const char * /*mlirPath*/,
                                                     const char * /*outputPath*/,
                                                     const char * /*rootModule*/) {
    return -1;
}

// Returns -1 without reading its arguments.
__attribute__((weak)) int eco_native_lower_and_link_bytes(
    const char * /*bytes*/, size_t /*len*/, const char * /*outputPath*/) {
    return -1;
}

} // extern "C"
