//===- Process.cpp - Stub implementations for Process kernel module -------===//

#include "Process.hpp"

namespace Eco::Kernel::Process {

uint64_t exit(uint64_t /*code*/) {
    // TODO: exit process with ExitCode (never returns)
    return 0;
}

uint64_t spawn(uint64_t /*config*/) {
    // TODO: spawn external process, return (Maybe Handle, ProcessHandle) tuple
    return 0;
}

uint64_t wait(uint64_t /*handle*/) {
    // TODO: wait for process to exit, return ExitCode
    return 0;
}

} // namespace Eco::Kernel::Process
