//===- Console.cpp - Console kernel module implementation -----------------===//
//
// Each Task-returning function packs what its body needs into the binding's captured value and leaves all IO to
// the body. `write` and `isTerminal` capture a Tuple2 whose slot 0 is the handle as an unboxed Int; slot 1 is the
// String for `write` and Unit for `isTerminal`. `readLine` and `readAll` capture Unit.
//
// Output goes straight to the file descriptors with `write`, or `_write` on Windows, not through a buffered stream.
// Input is read through `std::cin` on the thread that runs the Task, which blocks there.
//
//===----------------------------------------------------------------------===//

#include "Console.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include <cerrno>
#include <iostream>
#include <string>

#if defined(_WIN32)
#include <io.h>
#include <stdio.h>
// The platform layer: `_eco_write` is one unbuffered write that may write fewer bytes than asked, the `_fd`
// functions give the descriptors of the three standard streams, and `_eco_isatty` says whether a descriptor is a
// terminal. On Windows `_write` takes an `unsigned int` length, so callers cap a single write at 0x7fffffff bytes.
namespace { inline int _eco_write(int fd, const void* buf, unsigned int len) {
    return ::_write(fd, buf, len);
} }
namespace {
inline int _eco_stdout_fd() { return ::_fileno(stdout); }
inline int _eco_stderr_fd() { return ::_fileno(stderr); }
inline int _eco_stdin_fd() { return ::_fileno(stdin); }
inline bool _eco_isatty(int fd) { return ::_isatty(fd) != 0; }
}
#else
#include <unistd.h>
// The POSIX platform layer, with the same meaning as the Windows one above.
namespace { inline ssize_t _eco_write(int fd, const void* buf, size_t len) {
    return ::write(fd, buf, len);
} }
namespace {
inline int _eco_stdout_fd() { return STDOUT_FILENO; }
inline int _eco_stderr_fd() { return STDERR_FILENO; }
inline int _eco_stdin_fd() { return STDIN_FILENO; }
inline bool _eco_isatty(int fd) { return ::isatty(fd) != 0; }
}
#endif

namespace Eco::Kernel::Console {

namespace {

// Writes the String in `captured` to the stream its handle names and returns the Task `write` documents.
// `captured` is the Tuple2 `write` builds. The String is copied out before anything allocates.
HPointer writeBody(HPointer captured) {
    int64_t handle;
    HPointer contentHP;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        handle = tup->a.i;
        contentHP = tup->b.p;
    }
    std::string str = toString(Export::encode(contentHP));

    int fd;
    if (handle == 1) {
        fd = _eco_stdout_fd();
    } else if (handle == 2) {
        fd = _eco_stderr_fd();
    } else {
        return succeedUnit();
    }
    const char* data = str.data();
    size_t remaining = str.size();
    while (remaining > 0) {
        auto n = _eco_write(fd, data,
#if defined(_WIN32)
                            static_cast<unsigned int>(
                                remaining > 0x7fffffff ? 0x7fffffff : remaining));
#else
                            remaining);
#endif
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            int err = errno;
            return failErrno(err, "", "console write failed");
        }
        data += n;
        remaining -= static_cast<size_t>(n);
    }
    return succeedUnit();
}

// Reads one line from `std::cin`, blocking, and returns the Task `readLine` documents.
HPointer readLineBody(HPointer /*captured*/) {
    std::string line;
    if (std::getline(std::cin, line)) {
        return succeedString(line);
    }
    return succeedString("");
}

// Reads `std::cin` to its end, blocking, and returns the Task `readAll` documents.
HPointer readAllBody(HPointer /*captured*/) {
    std::string content;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (!content.empty()) {
            content += '\n';
        }
        content += line;
    }
    return succeedString(content);
}

// Returns the Task `isTerminal` documents for the handle in `captured`, the Tuple2 `isTerminal` builds.
HPointer isTerminalBody(HPointer captured) {
    int64_t handle;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        handle = tup->a.i;
    }
    bool tty = false;
    if (handle == 0) {
        tty = _eco_isatty(_eco_stdin_fd());
    } else if (handle == 1) {
        tty = _eco_isatty(_eco_stdout_fd());
    } else if (handle == 2) {
        tty = _eco_isatty(_eco_stderr_fd());
    }
    return succeedBool(tty);
}

} // anonymous namespace

uint64_t write(uint64_t handle, uint64_t content) {
    HPointer contentHP = Export::decode(content);
    Elm::StackRootGuard g(&contentHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(contentHP),
        /*unboxed_mask=*/0x1);
    return Export::encode(Eco::Kernel::makeBinding<writeBody>(payload));
}

uint64_t readLine() {
    return Export::encode(Eco::Kernel::makeBinding<readLineBody>(Elm::alloc::unit()));
}

uint64_t readAll() {
    return Export::encode(Eco::Kernel::makeBinding<readAllBody>(Elm::alloc::unit()));
}

uint64_t isTerminal(uint64_t handle) {
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        /*unboxed_mask=*/0x1);
    return Export::encode(Eco::Kernel::makeBinding<isTerminalBody>(payload));
}

uint64_t log(uint64_t tag, uint64_t value) {
    // Not deferred to a binding: `log` returns no Task, only `value`, so there is no Task to run the write later.
    std::string msg = toString(tag);
    msg += '\n';
    // Written to the descriptor, not through `std::cerr`, so it is not held in a stream buffer.
#if defined(_WIN32)
    (void)_eco_write(_eco_stderr_fd(), msg.data(),
                     static_cast<unsigned int>(
                         msg.size() > 0x7fffffff ? 0x7fffffff : msg.size()));
#else
    (void)_eco_write(_eco_stderr_fd(), msg.data(), msg.size());
#endif
    return value;
}

} // namespace Eco::Kernel::Console
