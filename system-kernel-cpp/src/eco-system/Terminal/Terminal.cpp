//===- Terminal.cpp - eco/system kernel module Terminal -------------------===//
//
// plans/eco-system-library.md Appendix B.5, §3.8 and Phase 5 step 5.3.
//
//   * getConfiguration — `Nothing` unless isatty(1); otherwise
//     ( colorDepth, columns, rows ) from TIOCGWINSZ and the B.5 colour
//     heuristic (NO_COLOR / TERM=dumb → 1; FORCE_COLOR=0/1/2/3 → 1/4/8/24;
//     COLORTERM truecolor/24bit → 24; TERM *256color → 8; otherwise 4).
//   * setStdInRawMode — termios on fd 0 (a no-op unless it is a terminal).
//     The original mode is saved on first use and restored by an atexit
//     handler. While raw mode is on, this kernel holds an INTERNAL
//     SignalService listener on SIGINT and SIGTERM (the one exception to
//     "handlers only for Elm subscriptions"): when no Elm subscription
//     listens to the signal, the listener restores the original termios and
//     chains to the previous disposition (by default: the process dies of
//     the signal, with a sane terminal). When the program does listen
//     (System.onSignalInterrupt / onSignalTerminate), raw mode stays on.
//     Raw mode is node's (uv_tty_set_mode UV_TTY_MODE_RAW).
//   * setProcessTitle — Linux: pthread_setname_np(eco_process_main_thread(),
//     first 15 bytes), which changes `comm` only; macOS: a no-op (§3.8).
//
// Windows: every kernel is infallible (Task Never), so it crashes with a
// clear message (§1).
//
// Templates used: T1 (bodies), G3 (copy out, syscall, allocate).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Terminal/Terminal.hpp"

#include "eco-system/Core/SignalService.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>

#ifndef _WIN32
#include "allocator/RuntimeExports.h"   // eco_process_main_thread
#include <csignal>
#include <pthread.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif

namespace Eco::System {

// ---------------------------------------------------------------------------
// POD helpers
// ---------------------------------------------------------------------------

bool terminalSize(int& columns, int& rows) {
#ifdef _WIN32
    (void)columns;
    (void)rows;
    return false;
#else
    for (int fd : {1, 0, 2}) {
        struct winsize ws {};
        if (::ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
            columns = ws.ws_col;
            rows = ws.ws_row;
            return true;
        }
    }
    return false;
#endif
}

int terminalColorDepth() {
    auto env = [](const char* name) -> const char* { return std::getenv(name); };
    const char* term = env("TERM");
    std::string termS = term ? term : "";
    if (const char* nc = env("NO_COLOR"); nc && *nc) return 1;
    if (termS == "dumb") return 1;
    if (const char* fc = env("FORCE_COLOR")) {
        std::string f = fc;
        if (f == "0") return 1;
        if (f == "1") return 4;
        if (f == "2") return 8;
        if (f == "3") return 24;
    }
    if (const char* ct = env("COLORTERM")) {
        std::string c = ct;
        if (c == "truecolor" || c == "24bit") return 24;
    }
    const std::string suffix = "256color";
    if (termS.size() >= suffix.size() &&
        termS.compare(termS.size() - suffix.size(), suffix.size(), suffix) == 0)
        return 8;
    return 4;
}

std::string truncatedThreadName(const std::string& title) {
    if (title.size() <= 15) return title;
    size_t n = 15;
    // Do not end inside a UTF-8 sequence: back off over continuation bytes.
    while (n > 0 && (static_cast<unsigned char>(title[n]) & 0xC0) == 0x80) --n;
    return title.substr(0, n);
}

namespace {

#ifndef _WIN32

// --- Raw mode (main thread only, except the atexit handler) ----------------

struct TtyState {
    bool saved = false;          // `original` holds fd 0's mode at first use
    struct termios original {};
    bool raw = false;
    SignalService::ListenerId sigint = 0;
    SignalService::ListenerId sigterm = 0;
};

TtyState& tty() {
    static auto* t = new TtyState();   // leaky: read by the atexit handler
    return *t;
}

bool applyRaw() {
    struct termios t = tty().original;
    t.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    t.c_oflag |= ONLCR;
    t.c_cflag |= CS8;
    t.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    int rc;
    do { rc = ::tcsetattr(0, TCSADRAIN, &t); } while (rc != 0 && errno == EINTR);
    return rc == 0;
}

void restoreOriginal() {
    auto& s = tty();
    if (!s.saved) return;
    int rc;
    do { rc = ::tcsetattr(0, TCSADRAIN, &s.original); } while (rc != 0 && errno == EINTR);
}

void restoreAtExit() {
    if (tty().raw) restoreOriginal();
}

// Internal SignalService listener while raw mode is on (step 5.3).
void rawModeSignal(int signo, void*) {
    auto& svc = SignalService::instance();
    if (svc.listenerCount(signo) > 1) return;   // the program listens: stay raw
    restoreOriginal();
    svc.chainToPrevious(signo);                 // by default the process ends here
    if (tty().raw) applyRaw();                  // survived (SIG_IGN / a handler)
}

void setRaw(bool on) {
    auto& s = tty();
    if (!::isatty(0)) return;
    if (!s.saved) {
        if (::tcgetattr(0, &s.original) != 0) return;
        s.saved = true;
        std::atexit(&restoreAtExit);
    }
    auto& svc = SignalService::instance();
    if (on && !s.raw) {
        if (!applyRaw()) return;
        s.raw = true;
        s.sigint = svc.addListener(SIGINT, &rawModeSignal, nullptr);
        s.sigterm = svc.addListener(SIGTERM, &rawModeSignal, nullptr);
    } else if (!on && s.raw) {
        restoreOriginal();
        s.raw = false;
        svc.removeListener(s.sigint);
        svc.removeListener(s.sigterm);
        s.sigint = s.sigterm = 0;
    }
}

#endif // !_WIN32

} // namespace

// ---------------------------------------------------------------------------
// Bodies (B.5)
// ---------------------------------------------------------------------------

#ifdef _WIN32

HPointer terminalGetConfigurationBody(HPointer) {
    ::Eco::Kernel::reportFatal(
        "eco/system: Terminal.getConfiguration is not supported on Windows yet");
}

HPointer terminalSetStdInRawModeBody(HPointer) {
    ::Eco::Kernel::reportFatal(
        "eco/system: Terminal.setStdInRawMode is not supported on Windows yet");
}

HPointer terminalSetProcessTitleBody(HPointer) {
    ::Eco::Kernel::reportFatal(
        "eco/system: Terminal.setProcessTitle is not supported on Windows yet");
}

#else // POSIX

namespace {

void setThreadName(const std::string& title) {
#if defined(__linux__)
    std::string name = truncatedThreadName(title);
    (void)::pthread_setname_np(eco_process_main_thread(), name.c_str());
#else
    (void)title;   // macOS: a no-op (pthread_setname_np names only the caller)
#endif
}

} // namespace

// getConfiguration : Task Never (Maybe ( Int, Int, Int ))
HPointer terminalGetConfigurationBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        if (!::isatty(1)) return succeed(alloc::nothing());
        int columns = 0, rows = 0;
        (void)terminalSize(columns, rows);
        int depth = terminalColorDepth();
        // The tuple3 is fresh when passed to just, which roots its argument (G4).
        return succeed(alloc::just(
            alloc::boxed(alloc::tuple3(alloc::unboxedInt(depth), alloc::unboxedInt(columns),
                                       alloc::unboxedInt(rows), 0x15)),
            /*is_boxed=*/true));
    )
}

// setStdInRawMode : Bool -> Task Never ()  — payload: the Bool.
HPointer terminalSetStdInRawModeBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        bool on = ::Elm::hpBits(captured) == ::Elm::hpBits(alloc::elmTrue());
        setRaw(on);
        return succeedUnit();
    )
}

// setProcessTitle : String -> Task Never ()  — payload: the String.
HPointer terminalSetProcessTitleBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        std::string title = toStdString(captured);   // G3: copy out first
        setThreadName(title);
        return succeedUnit();
    )
}

#endif // _WIN32

} // namespace Eco::System
