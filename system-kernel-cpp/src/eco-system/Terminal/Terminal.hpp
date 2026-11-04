//===- Terminal.hpp - eco/system kernel module Terminal (internal) --------===//
//
// A program that draws on a terminal needs to know how big the terminal is and how many colours it shows, to read
// keys as they are pressed, and to name its window. This component is the C++ side of `Eco.Kernel.Terminal`, which
// provides those four things and also says whether a given standard stream is a terminal.
//
// The other three Task operations each ask whether their standard stream is a terminal (`isatty`), and do nothing
// terminal-specific when it is not, so output redirected to a file or pipe never receives escape sequences.
//
// Raw mode is the one operation with lasting effect. In raw mode the terminal on standard input (fd 0) delivers each
// byte as soon as it is typed, without echo, line editing, or turning Ctrl-C into SIGINT. The mode in force at the
// first `setStdInRawMode` call (of either value) is saved, and is put back when raw mode is turned off and when the
// process exits normally (through `std::exit` or by returning from `main`). While raw mode is on, an internal
// `SignalService` listener on SIGINT and SIGTERM also puts it back before the signal takes its previous effect, unless
// that signal has any other `SignalService` listener, in which case raw mode stays on. No listener is added in embed
// mode, where `SignalService::subscribe` refuses.
//
// The functions ending in `Body` are binding bodies: each runs when its Task is run, not when the kernel export
// that made the Task is called. Their Tasks never fail: an exception thrown inside one ends the process, as
// `ECO_SYSTEM_BODY_GUARD` does for the `Never` shape. On Windows each of them ends the process with
// `Eco::Kernel::reportFatal`. The other three functions are plain C++ helpers that touch no heap.
//
// The `Terminal` effect manager, which reports resizes, is in TerminalManager.{hpp,cpp}.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TERMINAL_TERMINAL_HPP
#define ECO_SYSTEM_TERMINAL_TERMINAL_HPP

#include "eco-system/Core/Core.hpp"

#include <string>

namespace Eco::System {

/// Succeeds with `Nothing` when standard output is not a terminal, and otherwise with `Just ( colorDepth, columns,
/// rows )`: `terminalColorDepth()` and the size from `terminalSize`, or 0 columns and 0 rows when that finds none.
/// `captured` is unused.
HPointer terminalGetConfigurationBody(HPointer captured);
/// Succeeds with `True` when the file descriptor in `captured`, a boxed Int (0, 1 or 2 from Elm), is a terminal, and
/// with `False` otherwise.
HPointer terminalIsTerminalBody(HPointer captured);
/// Turns raw mode on standard input on when `captured` is the Bool `True`, and off otherwise, then succeeds with
/// `()`. Does nothing when standard input is not a terminal, or when its mode cannot be read or set; nothing reports
/// that. Asking for the mode already in force changes nothing. Turning it off restores the mode saved at the first
/// `setStdInRawMode` call, of either value.
HPointer terminalSetStdInRawModeBody(HPointer captured);
/// Sets the terminal window title to the String `captured`, by writing `terminalTitleSequence` of it to standard
/// output, then succeeds with `()`. Writes nothing when standard output is not a terminal. A write that fails or
/// stops short is abandoned without being reported.
HPointer terminalSetTitleBody(HPointer captured);

/// Writes the size of the terminal in character cells to `columns` and `rows`, and returns true; returns false,
/// leaving both alone, when no size is known.
///
/// The size is asked for (`TIOCGWINSZ`) on standard output, then standard input, then standard error, and the first
/// answer with a non-zero column count is used; its row count may be 0. Always false on Windows.
bool terminalSize(int& columns, int& rows);

/// Returns how many bits of colour the terminal is taken to show, judged from the environment: 1 when `NO_COLOR`
/// is set and non-empty or `TERM` is `dumb`; otherwise 1, 4, 8 or 24 when `FORCE_COLOR` is `0`, `1`, `2` or `3`;
/// otherwise 24 when `COLORTERM` is `truecolor` or `24bit`; otherwise 8 when `TERM` ends in `256color`; otherwise
/// 4. Nothing checks the terminal itself.
int terminalColorDepth();

/// Returns the escape sequence that sets the terminal window title to `title`: ESC `]2;`, the title, then BEL
/// (OSC 2). Bytes below 0x20 and 0x7F are left out of the title, so that none can end the sequence early; every
/// other byte is kept as it is.
std::string terminalTitleSequence(const std::string& title);

} // namespace Eco::System

#endif // ECO_SYSTEM_TERMINAL_TERMINAL_HPP
