//===- Runtime.cpp - Stub implementations for Runtime kernel module -------===//

#include "Runtime.hpp"
#include <cassert>

namespace Eco::Kernel::Runtime {

uint64_t dirname() {
    // TODO: return directory of current script/binary as String
    return 0;
}

double random() {
    // TODO: return random Float from runtime
    return 0.0;
}

uint64_t saveState(uint64_t /*state*/) {
    // TODO: persist REPL state to runtime storage, return Unit
    return 0;
}

uint64_t loadState() {
    assert(false && "Eco::Kernel::Runtime::loadState not implemented");
    return 0;
}

} // namespace Eco::Kernel::Runtime
