// Terminal unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/Terminal/).
//
//   TERM-04  Raw mode on stdin was put back only by `std::atexit` and the SIGINT/SIGTERM listeners
//            (Terminal.cpp `setRaw`), so a fatal end, `Eco::Kernel::reportFatal` (std::abort), left
//            the user's terminal raw (no echo, no line editing). Fixed (decision D3): `setRaw`
//            registers a pre-fatal hook that `reportFatal` runs. The plain abort() and SIGHUP
//            endings still leave it raw by D3 (no signal handlers); they are printed for information.
//   TERM-05  `terminalTitleSequence` kept the C1 controls U+0080..U+009F (UTF-8 C2 80..C2 9F), so
//            a title could carry U+009C (ST) or U+009B (CSI) and end the OSC sequence early. Fixed:
//            they are stripped like the C0 controls.
//   TERM-06  The first `setStdInRawMode` call saved the mode, even when it was `False`. A later
//            True then derived raw mode from, and exit restored, that stale mode, undoing any
//            change the user made in between (stty). Fixed: the mode is saved each time raw mode
//            goes on, and a False while raw mode is off does nothing.
//
// TERM-04/06 need a terminal on fd 0. The parent opens a pseudo-terminal (posix_openpt) and passes
// the slave's path to a child scenario in ECO_CORE_TEST_PTY; the child opens it as fd 0 (O_NOCTTY),
// runs `terminalSetStdInRawModeBody`, and ends; the parent then reads the slave's termios. The
// parent keeps both pty ends open, so the mode the child left behind persists.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Terminal/Terminal.hpp"
#include "allocator/HeapHelpers.hpp"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <string>

#ifndef _WIN32
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#endif

namespace {

// ---- TERM-05: C1 controls in the window title ---------------------------------------------------

void testTitleKeepsC1Controls() {
    std::printf("terminal/title-sequence-strips-c1-controls\n");
    using Eco::System::terminalTitleSequence;
    // Regression guards: what is stripped or kept today must stay so.
    CHECK_MSG(terminalTitleSequence("a\x1b" "b") == "\x1b]2;ab\x07", "ESC is stripped");
    CHECK_MSG(terminalTitleSequence("a\x7f" "b") == "\x1b]2;ab\x07", "DEL is stripped");
    CHECK_MSG(terminalTitleSequence("a\xC4\x9C" "b") == "\x1b]2;a\xC4\x9C" "b\x07",
              "U+011C (continuation byte 0x9C) is kept");
    CHECK_MSG(terminalTitleSequence("a\xC2\xA0" "b") == "\x1b]2;a\xC2\xA0" "b\x07", "U+00A0 is kept");
    // The defect: U+009C (ST), U+009B (CSI) and U+0080 must be stripped like the C0 controls.
    std::string seen;
    bool defect = false;
    for (const char* c1 : {"\xC2\x9C", "\xC2\x9B", "\xC2\x80"}) {
        const std::string got = terminalTitleSequence(std::string("a") + c1 + "b");
        if (got != "\x1b]2;ab\x07") {
            defect = true;
            char buf[16];
            std::snprintf(buf, sizeof buf, "C2 %02X", static_cast<unsigned char>(c1[1]));
            seen += std::string(seen.empty() ? "" : ", ") + buf + " kept";
        }
    }
    CHECK_MSG(!defect, "TERM-05 terminalTitleSequence: " + seen);
}

#ifndef _WIN32

// ---- pty harness (TERM-04, TERM-06) -------------------------------------------------------------

struct Pty {
    int master = -1;
    int slave = -1;
    std::string slaveName;
    bool ok() const { return master >= 0 && slave >= 0; }
    ~Pty() {
        if (slave >= 0) ::close(slave);
        if (master >= 0) ::close(master);
    }
};

void openPty(Pty& p) {
    p.master = ::posix_openpt(O_RDWR | O_NOCTTY);
    if (p.master < 0 || ::grantpt(p.master) != 0 || ::unlockpt(p.master) != 0) return;
    const char* name = ::ptsname(p.master);
    if (!name) return;
    p.slaveName = name;
    p.slave = ::open(name, O_RDWR | O_NOCTTY);
}

// In the child: makes the pty slave named in ECO_CORE_TEST_PTY fd 0. Returns false on failure.
bool ptyAsStdin() {
    const char* name = std::getenv("ECO_CORE_TEST_PTY");
    if (!name) return false;
    const int fd = ::open(name, O_RDWR | O_NOCTTY);
    if (fd < 0) return false;
    if (::dup2(fd, 0) < 0) return false;
    ::close(fd);
    return ::isatty(0) == 1;
}

void setRawMode(bool on) {
    (void)Eco::System::terminalSetStdInRawModeBody(on ? Elm::alloc::elmTrue() : Elm::alloc::elmFalse());
}

bool stdinIsRaw() {
    struct termios t {};
    return ::tcgetattr(0, &t) == 0 && (t.c_lflag & (ECHO | ICANON)) == 0;
}

// ---- TERM-04: raw mode survives a fatal end -----------------------------------------------------

// Turns raw mode on, says so on stdout, then ends the way ECO_CORE_TEST_END says.
int scenarioRawThenFatal() {
    if (!ptyAsStdin()) {
        std::printf("no pty on stdin\n");
        return 3;
    }
    initCoreRuntime();
    setRawMode(true);
    std::printf("raw-on %d\n", stdinIsRaw() ? 1 : 0);
    std::fflush(stdout);
    const char* end = std::getenv("ECO_CORE_TEST_END");
    const std::string how = end ? end : "reportFatal";
    if (how == "abort") std::abort();
    if (how == "sighup") {
        std::raise(SIGHUP);
        return 4;   // not reached: SIGHUP's default action ends the process
    }
    Eco::Kernel::reportFatal("TERM-04 test");
}

// Runs the scenario with a fresh pty and returns whether the slave was left raw; `r` and
// `precondition` describe the run. The pty starts in its default (cooked) mode.
bool runRawThenEnd(const char* end, ChildScenario::ChildRun& r, bool& precondition) {
    Pty p;
    openPty(p);
    precondition = false;
    if (!p.ok()) {
        CHECK_MSG(false, "TERM-04: could not open a pseudo-terminal");
        return false;
    }
    struct termios before {};
    ::tcgetattr(p.slave, &before);
    if ((before.c_lflag & (ECHO | ICANON)) != (ECHO | ICANON)) {
        CHECK_MSG(false, "TERM-04: the fresh pty is not in cooked mode");
        return false;
    }
    r = ChildScenario::runChildScenario("terminal/raw-then-fatal",
                                        {{"ECO_CORE_TEST_PTY", p.slaveName}, {"ECO_CORE_TEST_END", end}}, 30000);
    precondition = r.out.find("raw-on 1") != std::string::npos;
    struct termios after {};
    ::tcgetattr(p.slave, &after);
    return (after.c_lflag & (ECHO | ICANON)) == 0;
}

void testRawModeRestoredOnFatal() {
    std::printf("terminal/raw-mode-restored-on-a-fatal-end\n");
    ChildScenario::ChildRun r;
    bool pre = false;
    const bool leftRaw = runRawThenEnd("reportFatal", r, pre);
    CHECK_MSG(pre, "TERM-04: the child did not turn raw mode on; " + r.describe() + "; stdout: " + r.out +
                       "; stderr: " + r.err);
    CHECK_MSG(r.signaled && r.signal == SIGABRT, "TERM-04: reportFatal did not abort; " + r.describe());
    if (!pre) return;
    CHECK_MSG(!leftRaw, std::string("TERM-04: after reportFatal (") + r.describe() + ") the pty is " +
                            (leftRaw ? "still raw (ECHO|ICANON clear)" : "restored"));
    // Information only (D3 leaves these raw: no signal handlers): abort() and SIGHUP.
    for (const char* end : {"abort", "sighup"}) {
        ChildScenario::ChildRun r2;
        bool pre2 = false;
        const bool raw2 = runRawThenEnd(end, r2, pre2);
        std::printf("  TERM-04 info: after %s (%s, raw-on %s) the pty is %s\n", end, r2.describe().c_str(),
                    pre2 ? "seen" : "NOT seen", raw2 ? "still raw" : "restored");
    }
}

// ---- TERM-06: a first False call saves the mode --------------------------------------------------

// False first (saves the mode under the bug), then clears ECHOE as `stty -echoe` would, then True,
// then exits through std::exit so the atexit restore runs.
int scenarioFalseThenStty() {
    if (!ptyAsStdin()) {
        std::printf("no pty on stdin\n");
        return 3;
    }
    initCoreRuntime();
    setRawMode(false);
    struct termios t {};
    if (::tcgetattr(0, &t) != 0) return 5;
    t.c_lflag &= ~static_cast<tcflag_t>(ECHOE);
    if (::tcsetattr(0, TCSANOW, &t) != 0) return 6;
    setRawMode(true);
    std::printf("raw-on %d\n", stdinIsRaw() ? 1 : 0);
    std::fflush(stdout);
    std::exit(0);
}

void testFirstFalseSavesMode() {
    std::printf("terminal/raw-mode-false-first-does-not-save-the-mode\n");
    Pty p;
    openPty(p);
    if (!p.ok()) {
        CHECK_MSG(false, "TERM-06: could not open a pseudo-terminal");
        return;
    }
    struct termios before {};
    ::tcgetattr(p.slave, &before);
    CHECK_MSG((before.c_lflag & ECHOE) != 0, "TERM-06: the fresh pty has ECHOE clear already");
    auto r = ChildScenario::runChildScenario("terminal/false-then-stty", {{"ECO_CORE_TEST_PTY", p.slaveName}}, 30000);
    const bool pre = r.ok() && r.out.find("raw-on 1") != std::string::npos;
    CHECK_MSG(pre, "TERM-06: the child did not run to the end with raw mode on; " + r.describe() +
                       "; stdout: " + r.out + "; stderr: " + r.err);
    if (!pre) return;
    struct termios after {};
    ::tcgetattr(p.slave, &after);
    const bool cooked = (after.c_lflag & (ECHO | ICANON)) == (ECHO | ICANON);
    CHECK_MSG(cooked, "TERM-06: exit did not restore cooked mode at all");
    const bool echoeBack = (after.c_lflag & ECHOE) != 0;   // the stale mode from the first False call
    CHECK_MSG(!echoeBack, std::string("TERM-06: after exit ECHOE is ") +
                          (echoeBack ? "set again (restored the mode saved at the first False call)"
                                     : "clear (the mode in force just before going raw)"));
}

#endif  // !_WIN32

}  // namespace

void runTerminalTests() {
    testTitleKeepsC1Controls();
#ifndef _WIN32
    testRawModeRestoredOnFatal();
    testFirstFalseSavesMode();
#endif
}

void registerTerminalScenarios() {
#ifndef _WIN32
    ChildScenario::add("terminal/raw-then-fatal", scenarioRawThenFatal);
    ChildScenario::add("terminal/false-then-stty", scenarioFalseThenStty);
#endif
}
