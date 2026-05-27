//===- Crash.cpp - Crash kernel module implementation ---------------------===//

#include "Crash.hpp"
#include "KernelHelpers.hpp"
#include <cstdio>
#include <cstdlib>
// musl (Stage B static build) ships no <execinfo.h>/backtrace; stub them as
// no-ops so the crash handler compiles. glibc keeps its real backtrace. See
// plans/static-link-eco-binary.md.
#if defined(__has_include) && __has_include(<execinfo.h>)
#  include <execinfo.h>
#else
[[maybe_unused]] static inline int backtrace(void**, int) { return 0; }
[[maybe_unused]] static inline char** backtrace_symbols(void* const*, int) { return nullptr; }
[[maybe_unused]] static inline void backtrace_symbols_fd(void* const*, int, int) {}
#endif

namespace Eco::Kernel::Crash {

uint64_t crash(uint64_t message) {
    std::string msg = toString(message);
    fprintf(stderr, "Eco crash: %s\n", msg.c_str());
    {
        void* bt[64];
        int n = backtrace(bt, 64);
        fprintf(stderr, "Backtrace (%d frames):\n", n);
        backtrace_symbols_fd(bt, n, fileno(stderr));
        std::fflush(stderr);
    }
    ::exit(1);
    // Never returns.
    return 0;
}

} // namespace Eco::Kernel::Crash
