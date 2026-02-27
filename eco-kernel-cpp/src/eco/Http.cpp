//===- Http.cpp - Stub implementations for Http kernel module -------------===//

#include "Http.hpp"
#include <cassert>

namespace Eco::Kernel::Http {

uint64_t fetch(uint64_t /*method*/, uint64_t /*url*/, uint64_t /*headers*/) {
    assert(false && "Eco::Kernel::Http::fetch not implemented");
    return 0;
}

uint64_t getArchive(uint64_t /*url*/) {
    assert(false && "Eco::Kernel::Http::getArchive not implemented");
    return 0;
}

} // namespace Eco::Kernel::Http
