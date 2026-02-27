//===- Process.cpp - Stub implementations for Process kernel module -------===//

#include "Process.hpp"
#include <cassert>

namespace Eco::Kernel::Process {

uint64_t exit(int64_t /*code*/) {
    assert(false && "Eco::Kernel::Process::exit not implemented");
    return 0;
}

uint64_t spawn(uint64_t /*cmd*/, uint64_t /*args*/) {
    assert(false && "Eco::Kernel::Process::spawn not implemented");
    return 0;
}

uint64_t spawnProcess(uint64_t /*cmd*/, uint64_t /*args*/, uint64_t /*stdin_*/, uint64_t /*stdout_*/, uint64_t /*stderr_*/) {
    assert(false && "Eco::Kernel::Process::spawnProcess not implemented");
    return 0;
}

uint64_t wait(uint64_t /*handle*/) {
    assert(false && "Eco::Kernel::Process::wait not implemented");
    return 0;
}

} // namespace Eco::Kernel::Process
