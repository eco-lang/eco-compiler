// Unit tests of the Task binding trampolines (runtime/src/platform/TaskBinding.hpp).
//
// An exception thrown by a binding body (`bindingTrampoline` / `asyncBindingTrampoline`) was caught by nothing
// on the way out of the scheduler, so it never became `[eco-runtime] FATAL: <what>` (the `ECO_KERNEL_GUARD`
// around a Task-returning export only covers building the Task, not running its body) (ABI-NEW-1). Fixed: the
// trampolines catch it and call `reportFatal` (platform/Fatal.hpp).
//
// Each case runs in its own spawned process (the isolated suite) and forks the scenario with
// ForkedChild::runInChild, since the scenario ends the process.

#include "TaskBindingTest.hpp"

#include "../ForkedChild.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/platform/Scheduler.hpp"
#include "../../runtime/src/platform/TaskBinding.hpp"

#include <csignal>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using Elm::HPointer;
using Elm::Platform::Scheduler;

namespace {

#if !defined(_WIN32)

std::string describeStatus(int status) {
    if (WIFEXITED(status)) return "exit " + std::to_string(WEXITSTATUS(status));
    if (WIFSIGNALED(status)) return "signal " + std::to_string(WTERMSIG(status));
    return "status " + std::to_string(status);
}

std::string readWholeFile(const std::string& path) {
    std::ifstream in(path);
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// ---- ABI-NEW-1: a throwing binding body ---------------------------------------------------------

// The body announces itself on stderr (unbuffered, so the parent sees it whatever happens next),
// leaves "before-throw" in the stdout buffer (reportFatal flushes stdout first), then throws.
HPointer throwingSyncBody(HPointer) {
    std::fprintf(stderr, "body-ran\n");
    std::printf("before-throw\n");
    throw std::runtime_error("boom");
}

HPointer throwingAsyncBody(HPointer, HPointer) {
    std::fprintf(stderr, "body-ran\n");
    std::printf("before-throw\n");
    throw std::runtime_error("boom");
}

// Spawns `task` as a process and drains the scheduler, which steps the binding and runs its body.
// stdout goes to `stdoutPath` so the parent can check what was flushed.
int runBindingScenario(bool async, const std::string& stdoutPath) {
    const int fd = ::open(stdoutPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 3;
    ::dup2(fd, 1);
    ::close(fd);
    initAllocator();
    auto& s = Scheduler::instance();
    HPointer task = async ? Elm::Platform::makeAsyncBinding<throwingAsyncBody>(Elm::alloc::unit())
                          : Elm::Platform::makeBinding<throwingSyncBody>(Elm::alloc::unit());
    (void)s.rawSpawn(task);
    s.drain();
    std::fprintf(stderr, "drain returned\n");
    return 0;
}

// The child aborts (SIGABRT) with `[eco-runtime] FATAL: boom` on stderr, and "before-throw" was
// flushed to stdout. Before the fix there was no FATAL line: the exception unwound out of
// Scheduler::drain (here to runInChild's catch, "exception: boom", exit 99; from a native
// program's main loop to std::terminate).
void checkThrowingBinding(bool async) {
    const std::string outPath = "/tmp/eco-task-binding-throw-" + std::string(async ? "async" : "sync") +
                                "-" + std::to_string(::getpid()) + ".out";
    ForkedChild::ChildResult r = ForkedChild::runInChild([&] { return runBindingScenario(async, outPath); });
    const std::string out = readWholeFile(outPath);
    ::unlink(outPath.c_str());
    const std::string kind = async ? "async binding body" : "sync binding body";
    // Precondition: the scheduler really stepped the binding and ran the body.
    if (r.stderrText.find("body-ran") == std::string::npos) {
        TEST_FAIL("ABI-NEW-1 (" + kind + "): the body never ran; " + describeStatus(r.status) +
                  ", stderr: " + r.stderrText);
    }
    const bool fatalLine = r.stderrText.find("[eco-runtime] FATAL: boom") != std::string::npos;
    const bool aborted = WIFSIGNALED(r.status) && WTERMSIG(r.status) == SIGABRT;
    const bool flushed = out.find("before-throw") != std::string::npos;
    if (!(fatalLine && aborted && flushed)) {
        TEST_FAIL("ABI-NEW-1 (" + kind + ") threw: " + describeStatus(r.status) + ", FATAL line " +
                  (fatalLine ? "present" : "absent") + ", stdout " + (flushed ? "flushed" : "lost") +
                  ", stderr: " + r.stderrText);
    }
}

void testThrowingSyncBinding() { checkThrowingBinding(false); }
void testThrowingAsyncBinding() { checkThrowingBinding(true); }

#endif  // !_WIN32

}  // namespace

void registerTaskBindingTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    suite.add(Testing::TestCase("task-binding/throwing-sync-body-ends-in-fatal", testThrowingSyncBinding));
    suite.add(Testing::TestCase("task-binding/throwing-async-body-ends-in-fatal", testThrowingAsyncBinding));
#else
    (void)suite;
#endif
}
