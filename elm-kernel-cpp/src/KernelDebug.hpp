//===- KernelDebug.hpp - Kernel-side stderr tracing (Elm kernel) ----------===//
//
// Mirror of eco-kernel-cpp/src/eco/KernelDebug.hpp for the Elm kernel libs.
// Re-declared rather than re-included to keep the two kernel packages
// independent — neither has the other on its include path. The macro
// definition must stay in sync.
//
//===----------------------------------------------------------------------===//
#ifndef ELM_KERNEL_DEBUG_HPP
#define ELM_KERNEL_DEBUG_HPP

#include <cstdio>

#ifdef ECO_KERNEL_DEBUG
#define ECO_KLOG(tag, fmt, ...) \
    std::fprintf(stderr, "[eco-kernel:" tag "] " fmt "\n", ##__VA_ARGS__)
#else
#define ECO_KLOG(tag, fmt, ...) ((void)0)
#endif

#endif // ELM_KERNEL_DEBUG_HPP
