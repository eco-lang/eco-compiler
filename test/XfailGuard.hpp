#pragma once

// Expected-fail ("[xfail ID]") guards for open defects, the convention of
// test/allocator/ConcurrencyRegisterTest.hpp: a guard reproduces a defect that
// is not fixed yet. By default it PASSES while the defect reproduces (XFAIL)
// and FAILS when it does not (XPASS: the defect looks fixed, so the fixing
// change turns the guard into a plain test). ECO_TEST_XFAIL=strict makes each
// guard assert the fixed behaviour instead, so it fails on today's code:
//
//   ECO_TEST_XFAIL=strict build/test/test --filter "xfail "
//
// Used by the guards for cpp-review-bugs.md entries (ids "RB-<line>").

#include "TestSuite.hpp"
#include "allocator/TestHelpers.hpp"   // TEST_FAIL

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>
#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace XfailGuard {

// Whether ECO_TEST_XFAIL=strict is set.
inline bool strict() {
    const char* e = std::getenv("ECO_TEST_XFAIL");
    return e != nullptr && std::strcmp(e, "strict") == 0;
}

// Reports the outcome of guard `id`: `defect` says whether the defect
// reproduced, `how` describes what was seen. Fails the test on XPASS, or in
// strict mode when the defect reproduces.
inline void report(const std::string& id, bool defect, const std::string& how) {
    if (strict()) {
        if (defect) TEST_FAIL(id + " reproduces: " + how);
        std::cout << "  " << id << " (strict): " << how << "\n";
        return;
    }
    if (!defect) {
        TEST_FAIL(id + " XPASS: " + how + " -- the defect looks fixed; turn this guard into a plain test");
    }
    std::cout << "  XFAIL " << id << ": " << how << " (ECO_TEST_XFAIL=strict makes it fail)\n";
}

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
    if (pipe(fds) != 0) TEST_FAIL("XfailGuard: pipe failed");
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
    if (waitpid(pid, &r.status, 0) != pid) TEST_FAIL("XfailGuard: waitpid failed");
    return r;
}
#endif

}  // namespace XfailGuard
