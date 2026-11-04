// The native side of the `Eco.Console` kernel: writing to standard output and standard error, reading standard
// input, and asking whether a standard stream is a terminal.
//
// A *handle* is an Int naming a standard stream: 0 for standard input, 1 for standard output, 2 for standard error.
// A *word* is the `uint64_t` encoding of an Elm value used at the kernel ABI. A handle reaches these functions as
// the raw Int bits of its word, not as a boxed value.
//
// Four of the functions, `write`, `readLine`, `readAll` and `isTerminal`, return a Task, and calling them does no
// IO: each returns a binding Task (`Eco::Kernel::makeBinding`) whose body does the IO each time the scheduler runs
// the Task. `log` is the exception. It is not a Task but an Elm function of type `String -> a -> a`, and it writes
// when it is called.
//
// Every function here allocates on the Elm heap except `log`, so each of the others is a GC point.

#ifndef ECO_CONSOLE_HPP
#define ECO_CONSOLE_HPP

#include <cstdint>

namespace Eco::Kernel::Console {

/// Returns the word of a Task that writes the String `content` as UTF-8 to standard output when `handle` is 1, or to
/// standard error when it is 2, and succeeds with Unit. For any other `handle` the Task writes nothing and succeeds.
///
/// The whole string is written, retrying a write interrupted by a signal. Any other failed write fails the Task with
/// the IO error tuple for its `errno`, with an empty path; bytes already written stay written. A write to a pipe
/// whose reader has gone fails with `EPIPE` only if the process ignores SIGPIPE;
/// otherwise the signal's default action ends the process. Nothing here sets that.
uint64_t write(uint64_t handle, uint64_t content);

/// Returns the word of a Task that reads one line from standard input and succeeds with it, without its `\n`.
///
/// At the end of input, or when standard input cannot be read, it succeeds with the empty string; it never fails.
/// Only `\n` ends a line, so a `\r` before it is kept. The read blocks the thread running the Task until a line or
/// the end of input arrives.
uint64_t readLine();

/// Returns the word of a Task that reads standard input to its end and succeeds with the lines read, joined by `\n`,
/// with no `\n` after the last. It never fails.
///
/// Empty lines before the first non-empty line are dropped, since a `\n` is added only once the result is non-empty.
/// The read blocks the thread running the Task until the end of input.
uint64_t readAll();

/// Returns the word of a Task that succeeds with True when `handle` is 0, 1 or 2 and that standard stream is a
/// terminal, and with False otherwise. It never fails.
uint64_t isTerminal(uint64_t handle);

/// Writes the String `tag` and a `\n` to standard error, at once, and returns the word `value` unchanged.
///
/// It makes a single write call, unbuffered, and ignores its result, so an error or a short write goes unreported.
/// It does not allocate on the Elm heap.
uint64_t log(uint64_t tag, uint64_t value);

} // namespace Eco::Kernel::Console

#endif // ECO_CONSOLE_HPP
