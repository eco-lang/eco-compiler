//===- Env.cpp - Stub implementations for Env kernel module ---------------===//

#include "Env.hpp"

namespace Eco::Kernel::Env {

uint64_t lookup(uint64_t /*name*/) {
    // TODO: look up environment variable by name, return Maybe String
    return 0;
}

uint64_t rawArgs() {
    // TODO: get raw CLI args, return List String
    return 0;
}

} // namespace Eco::Kernel::Env
