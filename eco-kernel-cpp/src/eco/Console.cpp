//===- Console.cpp - Console kernel module implementation -----------------===//

#include "Console.hpp"
#include "KernelHelpers.hpp"
#include <iostream>
#include <string>
#include <unistd.h>

namespace Eco::Kernel::Console {

uint64_t write(uint64_t handle, uint64_t content) {
    std::string str = toString(content);
    int64_t h = static_cast<int64_t>(handle);
    if (h == 1) {
        ::write(STDOUT_FILENO, str.data(), str.size());
    } else if (h == 2) {
        ::write(STDERR_FILENO, str.data(), str.size());
    }
    // Stream handle support would go here (check global stream handle map).
    return taskSucceedUnit();
}

uint64_t readLine() {
    std::string line;
    if (std::getline(std::cin, line)) {
        return taskSucceedString(line);
    }
    return taskSucceedString("");
}

uint64_t readAll() {
    std::string content;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (!content.empty()) {
            content += '\n';
        }
        content += line;
    }
    return taskSucceedString(content);
}

uint64_t log(uint64_t tag, uint64_t value) {
    std::string msg = toString(tag);
    msg += '\n';
    // Direct stderr write — bypasses iostream sync so traces appear in
    // FIFO order with other ::write-based output in the process.
    (void)::write(STDERR_FILENO, msg.data(), msg.size());
    // Identity on `value`: return the same HPointer bits we were handed.
    return value;
}

} // namespace Eco::Kernel::Console
