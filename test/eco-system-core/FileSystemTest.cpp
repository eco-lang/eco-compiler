// FileSystem unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/FileSystem/FileSystem.cpp).
//
// FS-03: `fsPoolSubmit` (S/FileSystem/FileSystem.cpp) erased a closing fd from the open-handle table BEFORE it
// parked the resume and submitted the close to the pool. If `parkResume` or `SysWorkPool::submit` threw
// (`std::bad_alloc`), the guard failed the Task with "out of memory in kernel", but the fd was no longer in the
// table and was never closed: it leaked, and a retried `close` failed with EBADF. The check opens /dev/null through
// `fsPoolSubmit`, arms `SysWorkPool::failNextSubmitForTest()` (decision D11), closes it, and then asks whether the
// fd is either really closed or still tracked (a second close succeeds). Fixed with FS-01's handle table: the
// close's mark is undone when the submit throws. `open` now returns a handle id; `fdOfHandleForTest` gives its fd.
//
// It runs in a child process (scenario "filesystem/close-submit-fails"): it parks and resumes Tasks through the
// Scheduler and the pool, which must not leak into the other in-process tests.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/FileSystem/FileSystem.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

using namespace Eco::System;
using namespace Eco::System::Fs;

namespace {

// --- FS-03: close erases the fd before the submit that can throw -------------------------------------------------

std::vector<std::string> g_resumed12;   // "ok:<Int>" / "err:<code>:<message>"

// The resume closure: records the Task it is called with (a Task of an FErr `( code, message )`, succeeding with
// an unboxed Int for `open` and with `()` for `close`).
void* recordResume12(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    if (t->ctor == Elm::alloc::Task_Succeed) {
        g_resumed12.push_back("ok:" + std::to_string(t->value.i));
    } else {
        Tuple2* tup = asTuple2(t->value.p);
        g_resumed12.push_back("err:" + toStdString(tup->a.p) + ":" + toStdString(tup->b.p));
    }
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// Calls `fsPoolSubmit(op, kind, captured, resume)` with the recording resume and waits (draining the pool) until
// the Task has been resumed or 5 s have passed. Returns how it ended, or "timeout".
std::string runFs(FsOp op, FsKind kind, HPointer captured) {
    g_resumed12.clear();
    HPointer resume = alloc::listNil();
    Elm::StackRootGuard g({&captured, &resume});
    resume = alloc::allocClosureK(&recordResume12, 1, PK_Boxed);
    fsPoolSubmit(op, kind, captured, resume);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (g_resumed12.empty() && std::chrono::steady_clock::now() < deadline) {
        poolDrain();
        if (g_resumed12.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return g_resumed12.empty() ? std::string("timeout") : g_resumed12.back();
}

HPointer openArgs(const char* path, const char* flags) {
    HPointer p = alloc::allocStringFromUTF8(path);
    HPointer f = alloc::listNil();
    Elm::StackRootGuard g({&p, &f});
    f = alloc::allocStringFromUTF8(flags);
    return packFsArgs(enc(p), enc(f));
}

// Prints "FS-03 <step>: <result>" lines and a final "FS-03 verdict: ..." line; the parent decides. Exit status 0
// means the scenario ran to its verdict, 2 that a precondition failed (the hook is missing, or the open failed).
int scenarioCloseSubmitFails() {
    initCoreRuntime();
#if !ECO_TEST_HOOKS
    std::printf("FS-03 precondition: built without ECO_TEST_HOOKS\n");
    return 2;
#else
    std::string opened = runFs(&opOpen, FsKind::Open, openArgs("/dev/null", "r"));
    std::printf("FS-03 open: %s\n", opened.c_str());
    if (opened.rfind("ok:", 0) != 0) return 2;
    const int64_t handle = std::stoll(opened.substr(3));
    const int fd = fdOfHandleForTest(handle);
    std::printf("FS-03 handle %lld has fd %d\n", static_cast<long long>(handle), fd);
    if (fd < 0) return 2;

    SysWorkPool::failNextSubmitForTest();
    std::string closed = runFs(&opClose, FsKind::Close, packFsArgs(0, 0, handle));
    std::printf("FS-03 close with failing submit: %s\n", closed.c_str());
    if (closed.find("out of memory") == std::string::npos) {
        std::printf("FS-03 precondition: the injected submit failure did not reach the close\n");
        return 2;
    }

    errno = 0;
    const bool stillOpen = ::fcntl(fd, F_GETFD) != -1;
    std::string retried = runFs(&opClose, FsKind::Close, packFsArgs(0, 0, handle));
    errno = 0;
    const bool openAfterRetry = ::fcntl(fd, F_GETFD) != -1;
    std::printf("FS-03 fd still open: %d, retried close: %s, open after it: %d\n", stillOpen ? 1 : 0,
                retried.c_str(), openAfterRetry ? 1 : 0);
    const bool tracked = retried.rfind("ok:", 0) == 0 && !openAfterRetry;
    // Bug: the fd is open but no longer in the table, so nothing can ever close it.
    const bool leaked = stillOpen && !tracked;
    if (leaked) ::close(fd);
    std::printf("FS-03 verdict: %s\n", leaked ? "leaked" : "ok");
    return 0;
#endif
}

void testCloseSubmitFails() {
    std::printf("filesystem/close-whose-submit-throws-keeps-the-fd-tracked\n");
    auto r = ChildScenario::runChildScenario("filesystem/close-submit-fails", {}, 20000);
    const bool ran = r.ok() && r.out.find("FS-03 verdict: ") != std::string::npos;
    CHECK_MSG(ran, ("FS-03 scenario did not reach its verdict: " + r.describe() + "; stdout: " + r.out +
                    "; stderr: " + r.err).c_str());
    if (!ran) return;
    const bool defect = r.out.find("FS-03 verdict: leaked") != std::string::npos;
    CHECK_MSG(!defect, "FS-03 child stdout: " + r.out);
}

}  // namespace

void runFileSystemTests() {
    testCloseSubmitFails();
}

void registerFileSystemScenarios() {
    ChildScenario::add("filesystem/close-submit-fails", scenarioCloseSubmitFails);
}
