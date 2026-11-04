// `Allocator::resolve` of an embedded constant (PARSE-NEW-1).
//
// `Allocator::resolve` never returns null; given an embedded constant (True, Unit, Nil, ...) it aborts on the
// `ptr_ind == 0` assert in every assert build (and in a build without assertions dereferences the constant's
// made-up address). Kernels nevertheless tested its result for null right after the call; those guards are dead
// (test/scripts/check-resolve-null-guards.sh lists them). The case pins the contract, that `resolve` of a
// constant dies instead of returning null, in a forked child (stderr silenced; run with `ulimit -c 0`).

#include "ResolveConstantTest.hpp"

#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../runtime/src/allocator/HeapHelpers.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>

#if !defined(_WIN32)
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

#if !defined(_WIN32)
// Resolves `constant` in a forked child. Returns the child's wait status: a signal when
// `resolve` dies, exit 0 when it returned null, exit 1 when it returned a non-null pointer.
int resolveInChild(Elm::HPointer constant) {
    std::fflush(stdout);
    std::fflush(stderr);
    pid_t pid = fork();
    if (pid == 0) {
        if (std::getenv("ECO_TEST_CHILD_STDERR") == nullptr) {   // debugging aid
            int fd = open("/dev/null", O_WRONLY);
            if (fd >= 0) dup2(fd, 2);
        }
        void* p = Elm::Allocator::instance().resolve(constant);
        _exit(p == nullptr ? 0 : 1);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return st;
}

std::string describeStatus(int st) {
    if (WIFSIGNALED(st)) return "signal " + std::to_string(WTERMSIG(st));
    if (WIFEXITED(st)) {
        return WEXITSTATUS(st) == 0 ? "returned null" : "returned a non-null pointer";
    }
    return "status " + std::to_string(st);
}

// PARSE-NEW-1: `resolve` of an embedded constant never returns (null or otherwise).
void testResolveConstantDies() {
    initAllocator();
    const struct { const char* what; Elm::HPointer hp; } cases[] = {
        {"Empty (Unit/Nil/Nothing/\"\")", Elm::alloc::empty()},
        {"True", Elm::alloc::elmTrue()},
    };
    for (const auto& c : cases) {
        int st = resolveInChild(c.hp);
        if (!WIFSIGNALED(st)) {
            TEST_FAIL(std::string("PARSE-NEW-1: resolve(") + c.what + ") " + describeStatus(st) +
                      "; the null guards after resolve would be live");
        }
    }
}
#endif

}  // namespace

void registerResolveConstantTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    suite.add(Testing::TestCase("allocator/resolve-of-embedded-constant-dies-never-returns-null",
                                testResolveConstantDies));
#else
    (void)suite;
#endif
}
