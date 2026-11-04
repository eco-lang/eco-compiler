// Unit tests of Eco.Console's kernel (eco-kernel-cpp/src/eco-kernel/Console.cpp).
//
// log-survives-short-write (CONSOLE-02): `log` wrote its message with one write(2) and ignored a short count, so
// a write interrupted by a signal lost the rest of the message. Fixed: writeAll.

// The `test` binary whole-archives EcoKernel_Console (test/CMakeLists.txt), so the CONSOLE-02 guard
// calls the kernel's own Console functions through its header.
#if !defined(_WIN32)
#include "../../eco-kernel-cpp/src/eco-kernel/Console.hpp"
#endif

#include "ConsoleKernelTest.hpp"

#include "../ForkedChild.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace Elm;
namespace Ex = Elm::Kernel::Export;

namespace {

#if !defined(_WIN32)
std::string describeStatus(const ForkedChild::ChildResult& r) {
    std::ostringstream os;
    if (WIFSIGNALED(r.status)) os << "child signal " << WTERMSIG(r.status);
    else if (WIFEXITED(r.status)) os << "child exit " << WEXITSTATUS(r.status);
    else os << "child status " << r.status;
    if (!r.stderrText.empty()) os << ", stderr: " << r.stderrText;
    return os.str();
}
#endif

constexpr int kChildDefect = 10;   // exit status: the child saw the defect's value
constexpr int kChildOther = 3;     // exit status: neither the fixed nor the defective result

#if !defined(_WIN32)
void onSigusr1(int) {}

constexpr size_t kLogBytes = size_t{1} << 20;   // 1 MiB, far more than a 64 KiB pipe buffer

// One run: fd 2 is a pipe that nobody reads for 200 ms, Console.log writes a 1 MiB message to it (the write
// blocks once the pipe is full), and a SIGUSR1 without SA_RESTART interrupts it after 50 ms. Returns the
// number of bytes that reached the pipe; the full message is kLogBytes + 1 (the '\n').
size_t logThroughInterruptedPipe(uint64_t tag, uint64_t unitWord) {
    int fds[2];
    if (pipe(fds) != 0) return 0;
    const int savedStderr = dup(2);
    dup2(fds[1], 2);
    close(fds[1]);

    std::atomic<size_t> received{0};
    std::thread reader([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        char buf[65536];
        ssize_t n;
        while ((n = read(fds[0], buf, sizeof buf)) > 0) received += static_cast<size_t>(n);
    });
    const pthread_t mainThread = pthread_self();
    std::thread signaller([mainThread] {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        pthread_kill(mainThread, SIGUSR1);
    });

    (void)Eco::Kernel::Console::log(tag, unitWord);

    dup2(savedStderr, 2);   // closes the pipe's last write end: the reader sees EOF
    close(savedStderr);
    signaller.join();
    reader.join();
    close(fds[0]);
    return received.load();
}
#endif

// Console.log of a 1 MiB message to a blocking pipe, interrupted by a signal: every byte arrives (EINTR
// retried, short writes continued by `writeAll`). Before the fix the write returned a short count (the
// pipe's 64 KiB) and `log` dropped the rest. Three runs, to make the signal timing irrelevant; any short
// run fails.
void testConsole02LogShortWrite() {
#if defined(_WIN32)
    std::cout << "  skipped on Windows\n";
#else
    initAllocator();
    const auto r = ForkedChild::runInChild([]() -> int {
        struct sigaction sa;
        std::memset(&sa, 0, sizeof sa);
        sa.sa_handler = onSigusr1;
        sa.sa_flags = 0;   // no SA_RESTART: the blocked write returns early
        sigemptyset(&sa.sa_mask);
        if (sigaction(SIGUSR1, &sa, nullptr) != 0) return kChildOther;

        std::u16string text(kLogBytes, u'a');
        const uint64_t tag = Ex::encode(alloc::allocString(text));
        const uint64_t unitWord = Ex::encode(alloc::unit());
        bool shortRun = false;
        std::string counts;
        for (int run = 0; run < 3; run++) {
            const size_t got = logThroughInterruptedPipe(tag, unitWord);
            counts += (run ? ", " : "") + std::to_string(got);
            if (got != kLogBytes + 1) shortRun = true;
        }
        std::fprintf(stderr, "received %s of %zu bytes", counts.c_str(), kLogBytes + 1);
        return shortRun ? kChildDefect : 0;
    });
    const bool ok = WIFEXITED(r.status) && WEXITSTATUS(r.status) == 0;
    const bool defect = WIFEXITED(r.status) && WEXITSTATUS(r.status) == kChildDefect;
    if (defect) TEST_FAIL("CONSOLE-02: Console.log lost bytes after a short write: " + describeStatus(r));
    if (!ok) TEST_FAIL("CONSOLE-02 scenario did not run: " + describeStatus(r));
#endif
}

}  // namespace

void registerConsoleKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("console-kernel/log-keeps-writing-after-signal-interrupted-short-write",
                                testConsole02LogShortWrite));
}
