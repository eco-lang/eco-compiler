//===- KernelDebug.hpp - Kernel-side stderr tracing -----------------------===//
//
// Debug traces from the kernels must not mix with what a program writes to
// stdout, and must cost nothing in a normal build. This header gives the
// eco kernels one macro, ECO_KLOG, that writes a single line to stderr when
// ECO_KERNEL_DEBUG is defined and expands to nothing otherwise.
//
// ECO_KERNEL_DEBUG is a CMake option, OFF by default and ON in the `dev`
// preset. It is defined only for the EcoKernel_Http and EcoKernel_File
// libraries, so traces in any other library that includes this header are
// always compiled out.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_KERNEL_DEBUG_HPP
#define ECO_KERNEL_DEBUG_HPP

#include <cstdio>

#ifdef ECO_KERNEL_DEBUG
/// Writes `[eco-kernel:<tag>] <message>` and a newline to stderr, where the
/// message is `fmt` formatted with the remaining arguments as by printf.
///
/// `tag` and `fmt` must be string literals: they are joined into one format
/// string by literal concatenation. The arguments after `fmt` may be omitted.
/// The macro expands to an expression, and without ECO_KERNEL_DEBUG it expands
/// to `((void)0)` and its arguments are not evaluated.
#define ECO_KLOG(tag, fmt, ...) \
    std::fprintf(stderr, "[eco-kernel:" tag "] " fmt "\n", ##__VA_ARGS__)
#else
#define ECO_KLOG(tag, fmt, ...) ((void)0)
#endif

#endif // ECO_KERNEL_DEBUG_HPP
