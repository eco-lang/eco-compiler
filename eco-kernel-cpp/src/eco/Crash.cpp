//===- Crash.cpp - Crash kernel module implementation ---------------------===//

#include "Crash.hpp"
#include "KernelHelpers.hpp"
#include <cstdio>
#include <cstdlib>
#include <execinfo.h>

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
