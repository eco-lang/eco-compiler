//===- Console.cpp - Console kernel module implementation -----------------===//

#include "Console.hpp"
#include "KernelHelpers.hpp"
#include <cerrno>
#include <iostream>
#include <string>
#include <unistd.h>

namespace Eco::Kernel::Console {

uint64_t write(uint64_t handle, uint64_t content) {
    std::string str = toString(content);
    int64_t h = static_cast<int64_t>(handle);
    int fd;
    if (h == 1) {
        fd = STDOUT_FILENO;
    } else if (h == 2) {
        fd = STDERR_FILENO;
    } else {
        // Stream handle support would go here (check global stream handle map).
        return taskSucceedUnit();
    }
    // Write the whole buffer, surfacing errors (e.g. EPIPE when a downstream
    // reader closed the pipe). SIGPIPE is ignored at startup so the write
    // returns EPIPE rather than terminating the process (see eco_entry.cpp).
    const char* data = str.data();
    size_t remaining = str.size();
    while (remaining > 0) {
        ssize_t n = ::write(fd, data, remaining);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            int err = errno;
            return taskFailErrno(err, "", "console write failed");
        }
        data += n;
        remaining -= static_cast<size_t>(n);
    }
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
