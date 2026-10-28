// Windows fallback definition for `Eco_Kernel_Order_register_gc_roots`.
//
// The real definition is in elm-kernel-cpp (`UtilsExports.cpp`). Some binaries
// link without it, so their callers declare the symbol weak and call it only
// when its address is non-null. On ELF and Mach-O an unresolved weak symbol is
// null. On Windows the callers declare it as an ordinary `extern "C"` function
// instead, because clang-cl's weak declarations duplicate across archives
// linked with /WHOLEARCHIVE and lld-link rejects the duplicates.
//
// This file supplies the Windows answer: a no-op default and an
// /alternatename directive. The linker uses the real definition when one is
// linked and the no-op otherwise, so in a binary that links this file the
// symbol always resolves and the call is always made. On other platforms the
// file is empty.

#if defined(_WIN32)

/// Does nothing. The definition `Eco_Kernel_Order_register_gc_roots` resolves
/// to when no other definition is linked.
extern "C" void Eco_Kernel_Order_register_gc_roots_default() {}

#pragma comment( \
    linker, \
    "/alternatename:Eco_Kernel_Order_register_gc_roots=Eco_Kernel_Order_register_gc_roots_default")

#endif // _WIN32
