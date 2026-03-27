//===- Crash.cpp - Crash kernel module implementation ---------------------===//

#include "Crash.hpp"
#include "KernelHelpers.hpp"
#include <cstdio>
#include <cstdlib>

namespace Eco::Kernel::Crash {

uint64_t crash(uint64_t message) {
    std::string msg = toString(message);
    fprintf(stderr, "Eco crash: %s\n", msg.c_str());
    ::exit(1);
    // Never returns.
    return 0;
}

} // namespace Eco::Kernel::Crash
