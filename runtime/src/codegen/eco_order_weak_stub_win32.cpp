// Windows-only weak-link fallback for Eco_Kernel_Order_register_gc_roots.
//
// The Order LT/EQ/GT singleton registrar lives in ElmKernel_Utils. Targets
// that whole-archive ElmKernel_Utils (the eco AOT binary) get the real
// definition. Targets that do NOT (the JIT test binary, ecoc, eco-boot-native)
// need the symbol to resolve to a harmless no-op so the conditional call in
// the runtime's GC root registration links.
//
// On ELF/Mach-O the source files declare the symbol with `__attribute__((weak))`
// and the linker resolves the undef to NULL; the call site guards on the
// address. clang-cl in COFF mode does not have working weak-decl semantics —
// the weak attribute emits a COMDAT extern that duplicates across every
// /WHOLEARCHIVE archive that has the decl, and lld-link rejects the duplicate.
// On Windows we drop the weak attribute (regular extern "C" decl) and provide
// this default via lld-link's /alternatename directive so the symbol always
// resolves: to the real definition when ElmKernel_Utils is in the link, to
// the no-op default otherwise.

#if defined(_WIN32)

extern "C" void Eco_Kernel_Order_register_gc_roots_default() {}

#pragma comment( \
    linker, \
    "/alternatename:Eco_Kernel_Order_register_gc_roots=Eco_Kernel_Order_register_gc_roots_default")

#endif // _WIN32
