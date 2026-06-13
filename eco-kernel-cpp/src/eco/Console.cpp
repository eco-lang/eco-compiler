//===- Console.cpp - Console kernel module implementation -----------------===//
//
// Per KERNEL_TASK_IO_001 / plans/defer-eager-kernel-tasks-via-binding.md
// Phase 1: `write`, `readLine`, `readAll` are returned as Task_Bindings so
// the actual stdin/stdout IO runs when the scheduler steps the binding (NOT
// at the kernel call site). `log` is the explicit Q7/KERNEL_TASK_IO_001
// exemption — it's an identity helper that returns its `value` arg, not a
// Task, and stays eager.
//
// readLine/readAll bindings still block the scheduler thread on stdin inside
// the evaluator (Q3); a future StdinService follow-up (mirror of
// TimerService/HttpService) will move stdin reads to a worker thread.
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
// On Windows route stdout/stderr writes through _write()/_fileno() — the
// underlying CRT primitive that matches POSIX ::write semantics (returns
// short bytes, no buffering layered on top). EINTR cannot happen on Win64
// for a regular file/pipe but the retry loop is harmless.
namespace { inline int _eco_write(int fd, const void* buf, unsigned int len) {
    return ::_write(fd, buf, len);
} }
namespace {
inline int _eco_stdout_fd() { return ::_fileno(stdout); }
inline int _eco_stderr_fd() { return ::_fileno(stderr); }
}
#else
#include <unistd.h>
namespace { inline ssize_t _eco_write(int fd, const void* buf, size_t len) {
    return ::write(fd, buf, len);
} }
namespace {
inline int _eco_stdout_fd() { return STDOUT_FILENO; }
inline int _eco_stderr_fd() { return STDERR_FILENO; }
}
#endif

namespace Eco::Kernel::Console {

namespace {

// Body for `write`. Captured payload is a Tuple2 with the handle as an
// unboxed Int (slot 0) and the content as a boxed String (slot 1). The
// scheduler thread runs this when the binding is stepped.
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
        // Stream handle support would go here (check global stream handle map).
        return succeedUnit();
    }
    // Write the whole buffer, surfacing errors (e.g. EPIPE when a downstream
    // reader closed the pipe). SIGPIPE is ignored at startup so the write
    // returns EPIPE rather than terminating the process (see eco_entry.cpp).
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

// TODO(StdinService): blocking stdin read inside the binding evaluator. Move
// to a worker thread in a follow-up plan (mirror TimerService / HttpService).
HPointer readLineBody(HPointer /*captured*/) {
    std::string line;
    if (std::getline(std::cin, line)) {
        return succeedString(line);
    }
    return succeedString("");
}

// TODO(StdinService): same — blocking stdin read inside the evaluator.
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

uint64_t log(uint64_t tag, uint64_t value) {
    // EXEMPT from KERNEL_TASK_IO_001: `log` is an identity helper, not a
    // Task producer. It eagerly writes its `tag` argument to stderr and
    // returns `value` unchanged so it can be spliced into Elm expressions
    // (`Console.log "x" x`). See plans/defer-eager-kernel-tasks-via-binding.md
    // Q7 for the exemption rationale.
    std::string msg = toString(tag);
    msg += '\n';
    // Direct stderr write — bypasses iostream sync so traces appear in
    // FIFO order with other ::write-based output in the process.
#if defined(_WIN32)
    (void)_eco_write(_eco_stderr_fd(), msg.data(),
                     static_cast<unsigned int>(
                         msg.size() > 0x7fffffff ? 0x7fffffff : msg.size()));
#else
    (void)_eco_write(_eco_stderr_fd(), msg.data(), msg.size());
#endif
    // Identity on `value`: return the same HPointer bits we were handed.
    return value;
}

} // namespace Eco::Kernel::Console
