//===- Console.cpp - Stub implementations for Console kernel module -------===//

#include "Console.hpp"

namespace Eco::Kernel::Console {

uint64_t write(uint64_t /*handle*/, uint64_t /*content*/) {
    // TODO: write string to console handle (stdout/stderr), return Unit
    return 0;
}

uint64_t readLine() {
    // TODO: read one line from stdin, return String
    return 0;
}

uint64_t readAll() {
    // TODO: read all of stdin as string, return String
    return 0;
}

} // namespace Eco::Kernel::Console
