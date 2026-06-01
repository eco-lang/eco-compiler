//===- KernelDebug.hpp - Kernel-side stderr tracing -----------------------===//
//
// One-line stderr traces for HTTP requests/responses, libzip extraction, file
// IO, and the curl-side worker. Gated by ECO_KERNEL_DEBUG (CMake option,
// defaults ON). When the flag is off the macro expands to a no-op statement.
//
// Output format: `[eco-kernel:<tag>] <message>\n` to stderr — matches the
// existing Crash.cpp / Console.cpp convention so the bootstrap's stdout
// (compiler artefacts) stays clean.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_KERNEL_DEBUG_HPP
#define ECO_KERNEL_DEBUG_HPP

#include <cstdio>

#ifdef ECO_KERNEL_DEBUG
#define ECO_KLOG(tag, fmt, ...) \
    std::fprintf(stderr, "[eco-kernel:" tag "] " fmt "\n", ##__VA_ARGS__)
#else
#define ECO_KLOG(tag, fmt, ...) ((void)0)
#endif

#endif // ECO_KERNEL_DEBUG_HPP
