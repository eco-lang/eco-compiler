//===- KernelDebug.hpp - Kernel-side stderr tracing (Elm kernel) ----------===//
//
// Kernel code needs one-line diagnostic traces that cost nothing in a normal
// build and never touch stdout. This header gives the Elm kernel libraries the
// ECO_KLOG macro for that: it prints to stderr when ECO_KERNEL_DEBUG is defined
// and compiles to nothing otherwise. ECO_KERNEL_DEBUG is defined only for
// ElmKernel_Http (a CMake option, ON in the `dev` preset), so traces elsewhere
// are compiled out.
//
// It is a copy of eco-kernel-cpp/src/eco-kernel/KernelDebug.hpp, not an
// include of it, because neither kernel package has the other on its include
// path. The definitions of ECO_KLOG here, in that header, and in
// runtime/src/platform/HttpService.cpp must stay identical.
//
//===----------------------------------------------------------------------===//
#ifndef ELM_KERNEL_DEBUG_HPP
#define ELM_KERNEL_DEBUG_HPP

#include <cstdio>

/// Writes one trace line `[eco-kernel:<tag>] <message>` to stderr, where the
/// message is `fmt` formatted with the remaining arguments as by printf.
///
/// `tag` and `fmt` must be string literals: they are joined to the prefix and
/// the newline by literal concatenation, which is why this is a macro. The
/// arguments may be omitted. Expands to an expression; without
/// ECO_KERNEL_DEBUG it expands to `((void)0)` and its arguments are not
/// evaluated.
#ifdef ECO_KERNEL_DEBUG
#define ECO_KLOG(tag, fmt, ...) \
    std::fprintf(stderr, "[eco-kernel:" tag "] " fmt "\n", ##__VA_ARGS__)
#else
#define ECO_KLOG(tag, fmt, ...) ((void)0)
#endif

#endif // ELM_KERNEL_DEBUG_HPP
