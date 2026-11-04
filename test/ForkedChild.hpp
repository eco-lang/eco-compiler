#pragma once

// Runs a scenario in a forked child of the `test` binary and captures its stderr, for cases that
// must watch a crash, an exit or a signal from outside (the ReviewBugGuards regressions, the kernel
// cases that call an export which dies or exits). Run the case itself in an isolated suite, so
// that the fork copies a process that holds nothing but that case.

#include "TestSuite.hpp"
#include "allocator/TestHelpers.hpp"   // TEST_FAIL

#include <cstdio>
#include <exception>
#include <functional>
#include <iostream>
#include <string>
#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace ForkedChild {

#if !defined(_WIN32)
// The outcome of a scenario run in a forked child.
struct ChildResult {
    int status = 0;       // the child's wait status
    std::string stderrText;  // everything the child wrote to stderr
};

// Runs `scenario` in a forked child with its stderr captured, and returns the
// child's wait status and stderr. The child exits with `scenario`'s result.
inline ChildResult runInChild(const std::function<int()>& scenario) {
    std::cout.flush();
    std::fflush(stdout);
    std::fflush(stderr);
    int fds[2];
    if (pipe(fds) != 0) TEST_FAIL("ForkedChild: pipe failed");
    const pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 2);
        int rc = 99;
        try {
            rc = scenario();
        } catch (const std::exception& e) {
            std::fprintf(stderr, "exception: %s\n", e.what());
        }
        std::fflush(stdout);
        std::fflush(stderr);
        _exit(rc);
    }
    close(fds[1]);
    ChildResult r;
    char buf[512];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof buf)) > 0) r.stderrText.append(buf, static_cast<size_t>(n));
    close(fds[0]);
    if (waitpid(pid, &r.status, 0) != pid) TEST_FAIL("ForkedChild: waitpid failed");
    return r;
}
#endif

}  // namespace ForkedChild
