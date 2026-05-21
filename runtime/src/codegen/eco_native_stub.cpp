//===- eco_native_stub.cpp - Weak stubs for EcoNativeAPI ------------------===//
//
// Weak definitions of the EcoNativeAPI C ABI entry points. Every AOT binary
// that ships EcoEntryStatic (i.e. every binary built by eco-boot-native or
// linked via the equivalent CMake target_link_libraries chain) gets these
// stubs in its link line. When EcoNativeDriverStatic is also linked in (as
// the unified `eco` binary does), its strong definitions override these
// weak ones and lowering happens in-process; otherwise calls into the
// kernel intrinsic surface a runtime "lowering unavailable" failure.
//
// The stubs return -1 to signal "no implementation available". The
// kernel-side wrapper (eco-kernel-cpp/src/eco/NativeDriver.cpp) translates
// any nonzero return into a Task failure with an explanatory message.
//
//===----------------------------------------------------------------------===//

#include <stddef.h>

extern "C" {

__attribute__((weak)) int eco_native_lower_and_link(const char * /*mlirPath*/,
                                                     const char * /*outputPath*/) {
    return -1;
}

__attribute__((weak)) int eco_native_lower_and_link_bytes(
    const char * /*bytes*/, size_t /*len*/, const char * /*outputPath*/) {
    return -1;
}

} // extern "C"
