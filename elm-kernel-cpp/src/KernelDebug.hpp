//===- KernelDebug.hpp - Kernel-side stderr tracing (Elm kernel) ----------===//
//
// Kernel code needs one-line diagnostic traces that cost nothing in a normal
// build and never touch stdout. This header gives the Elm kernel libraries the
// ECO_KLOG macro for that: it prints to stderr when ECO_KERNEL_DEBUG is defined
// and compiles to nothing otherwise. ECO_KERNEL_DEBUG is defined only for
// ElmKernel_Http (a CMake option, ON in the `dev` preset), so traces elsewhere
// are compiled out.
//
// The definitions of ECO_KLOG here and in runtime/src/platform/HttpService.cpp
// must stay identical. (eco-kernel-cpp had a copy for its File and Http
// modules, removed with them: plans/compiler-io-on-eco-system.md.)
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
