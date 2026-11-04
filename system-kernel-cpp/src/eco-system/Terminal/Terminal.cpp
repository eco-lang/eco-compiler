//===- Terminal.cpp - eco/system kernel module Terminal -------------------===//
//
// Raw mode keeps one piece of process-wide state, `TtyState`, used on the eco thread and by the exit handler. The
// original mode of fd 0 is read once, at the first request, and every restore puts back that same copy. The exit
// handler is registered at that moment, with `std::atexit`, and restores only while raw mode is on.
//
// Raw mode clears the input flags BRKINT, ICRNL, INPCK, ISTRIP and IXON and the local flags ECHO, ICANON, IEXTEN and
// ISIG, sets 8-bit characters, keeps output newline translation (ONLCR), and makes each read return after one byte.
//
// The signal listener restores the original mode and calls `SignalService::chainToPrevious`, which by default ends
// the process. If the process survives (the previous disposition ignored the signal, or a previous handler
// returned), raw mode is put back on. The listener does none of this when the signal has any other listener, which
// is taken to mean the program handles the signal itself.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Terminal/Terminal.hpp"

#include "eco-system/Core/SignalService.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>

#ifndef _WIN32
#include <csignal>
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

std::string terminalTitleSequence(const std::string& title) {
    std::string out = "\x1b]2;";
    for (char ch : title) {
        unsigned char c = static_cast<unsigned char>(ch);
        if (c >= 0x20 && c != 0x7f) out.push_back(ch);
    }
    out.push_back('\x07');
    return out;
}

namespace {

#ifndef _WIN32

/// The raw-mode state of fd 0. Used on the eco thread, and read by `restoreAtExit` on whichever thread exits.
struct TtyState {
    bool saved = false;          ///< Whether `original` holds fd 0's mode, read at the first request.
    struct termios original {};
    bool raw = false;            ///< Whether raw mode is on.
    /// The internal SIGINT and SIGTERM listeners while raw mode is on; 0 when off, or when `addListener` refused.
    SignalService::ListenerId sigint = 0;
    SignalService::ListenerId sigterm = 0;
};

/// Returns the one `TtyState`, created on first use and never freed, so the exit handler can still read it while
/// static objects are being destroyed.
TtyState& tty() {
    static auto* t = new TtyState();
    return *t;
}

/// Sets fd 0 to raw mode, derived from the saved original mode, and returns whether that succeeded. Waits for
/// pending output to drain first, and retries on EINTR. Requires `tty().saved`.
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

/// Puts the saved original mode back on fd 0, after pending output drains, retrying on EINTR. Does nothing when no
/// mode has been saved; a failure is ignored.
void restoreOriginal() {
    auto& s = tty();
    if (!s.saved) return;
    int rc;
    do { rc = ::tcsetattr(0, TCSADRAIN, &s.original); } while (rc != 0 && errno == EINTR);
}

/// Restores the original mode if raw mode is on. This is the handler registered with `std::atexit`.
void restoreAtExit() {
    if (tty().raw) restoreOriginal();
}

/// Handles SIGINT or SIGTERM while raw mode is on: unless `signo` has another listener, restores the original mode,
/// gives the signal its previous effect, and turns raw mode back on if the process is still running.
void rawModeSignal(int signo, void*) {
    auto& svc = SignalService::instance();
    if (svc.listenerCount(signo) > 1) return;
    restoreOriginal();
    svc.chainToPrevious(signo);
    if (tty().raw) applyRaw();
}

/// Turns raw mode on fd 0 on or off, as `terminalSetStdInRawModeBody` describes, adding or removing the signal
/// listeners with it. Turning raw mode on fails silently, leaving it off, when the mode cannot be set.
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
// Bodies
// ---------------------------------------------------------------------------

#ifdef _WIN32

HPointer terminalGetConfigurationBody(HPointer) {
    ::Eco::Kernel::reportFatal(
        "eco/system: Terminal.getConfiguration is not supported on Windows yet");
}

HPointer terminalIsTerminalBody(HPointer) {
    ::Eco::Kernel::reportFatal(
        "eco/system: Terminal.isTerminal is not supported on Windows yet");
}

HPointer terminalSetStdInRawModeBody(HPointer) {
    ::Eco::Kernel::reportFatal(
        "eco/system: Terminal.setStdInRawMode is not supported on Windows yet");
}

HPointer terminalSetTitleBody(HPointer) {
    ::Eco::Kernel::reportFatal(
        "eco/system: Terminal.setTitle is not supported on Windows yet");
}

#else // POSIX

// getConfiguration : Task Never (Maybe ( Int, Int, Int ))
HPointer terminalGetConfigurationBody(HPointer /*captured*/) {
    ECO_SYSTEM_BODY_GUARD(Never,
        if (!::isatty(1)) return succeed(alloc::nothing());
        int columns = 0, rows = 0;
        (void)terminalSize(columns, rows);
        int depth = terminalColorDepth();
        // The tuple is passed straight to `just`, which roots its argument, so it needs no guard. Mask 0x15 marks
        // all three slots as unboxed Ints.
        return succeed(alloc::just(
            alloc::boxed(alloc::tuple3(alloc::unboxedInt(depth), alloc::unboxedInt(columns),
                                       alloc::unboxedInt(rows), 0x15)),
            /*is_boxed=*/true));
    )
}

// isTerminal : Int -> Task Never Bool  — payload: the file descriptor, a boxed Int.
HPointer terminalIsTerminalBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int fd = static_cast<int>(
            static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value);
        return succeed(::isatty(fd) ? alloc::elmTrue() : alloc::elmFalse());
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

// setTitle : String -> Task Never ()  — payload: the String.
HPointer terminalSetTitleBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        std::string title = toStdString(captured);
        if (::isatty(1)) {
            std::string seq = terminalTitleSequence(title);
            size_t done = 0;
            while (done < seq.size()) {
                ssize_t n = ::write(1, seq.data() + done, seq.size() - done);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;
                done += static_cast<size_t>(n);
            }
        }
        return succeedUnit();
    )
}

#endif // _WIN32

} // namespace Eco::System
