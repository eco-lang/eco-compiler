//===- MVar.cpp - Stub implementations for MVar kernel module -------------===//

#include "MVar.hpp"

namespace Eco::Kernel::MVar {

int64_t newEmpty() {
    // TODO: create new empty MVar, return MVar id
    return 0;
}

uint64_t read(uint64_t /*typeTag*/, uint64_t /*id*/) {
    // TODO: read MVar (blocks until full), return value without removing
    return 0;
}

uint64_t take(uint64_t /*typeTag*/, uint64_t /*id*/) {
    // TODO: take MVar (blocks until full), return value and empty MVar
    return 0;
}

uint64_t put(uint64_t /*typeTag*/, uint64_t /*id*/, uint64_t /*value*/) {
    // TODO: put value into MVar (blocks until empty), return Unit
    return 0;
}

} // namespace Eco::Kernel::MVar
