// The native side of the `Eco.Console` kernel: writing to standard output and standard error, reading standard
// input, and asking whether a standard stream is a terminal.
//
// A *handle* is an Int naming a standard stream: 0 for standard input, 1 for standard output, 2 for standard error;
// `write` also accepts the stdin handle of a child started by `Eco.Process.spawnProcess` (`Process::streamHandleFd`).
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

/// Returns the word of a Task that writes the String `content` as UTF-8 to standard output when `handle` is 1, to
/// standard error when it is 2, or to the child's stdin pipe when `handle` is an open `spawnProcess` stdin handle, and
/// succeeds with Unit. For any other `handle` the Task writes nothing and fails with the IO error tuple for `EBADF`.
///
/// The whole string is written, retrying a write interrupted by a signal and continuing a short one. Any other
/// failed write fails the Task with the IO error tuple for its `errno`, with an empty path; bytes already written stay
/// written. A non-blocking descriptor that is full fails with `EAGAIN`; nothing waits for it to drain. A write to a
/// pipe whose reader has gone fails with `EPIPE` only if the process ignores SIGPIPE;
/// otherwise the signal's default action ends the process. Nothing here sets that.
uint64_t write(uint64_t handle, uint64_t content);

/// Returns the word of a Task that reads one line from standard input and succeeds with it, without its `\n`.
///
/// At the end of input, or when standard input cannot be read, it succeeds with what is left of the last line,
/// possibly the empty string; it never fails. Only `\n` ends a line, so a `\r` before it is kept.
///
/// The read is done on the module's stdin reader thread, not on the thread running Elm, which goes on with timers
/// and other work meanwhile; the Task resumes when the line arrives. Reads are served one at a time in the order
/// their Tasks ran, and bytes after a line are kept for the next `readLine` or `readAll`. Killing the Task stops
/// the wait; a read already in progress still consumes its line.
uint64_t readLine();

/// Returns the word of a Task that reads standard input to its end and succeeds with every byte read, unchanged
/// (decoded as UTF-8), including any bytes a `readLine` read ahead. It never fails.
///
/// It reads off the thread running Elm, like `readLine`, and resumes at the end of input.
uint64_t readAll();

/// Returns the word of a Task that succeeds with True when `handle` is 0, 1 or 2 and that standard stream is a
/// terminal, and with False otherwise. It never fails.
uint64_t isTerminal(uint64_t handle);

/// Writes the String `tag` and a `\n` to standard error, at once, and returns the word `value` unchanged.
///
/// It writes unbuffered, retrying a write interrupted by a signal and continuing a short one, and ignores a failed
/// write (a non-blocking standard error that is full, `EAGAIN`, ends the message there). It does not allocate on the
/// Elm heap.
uint64_t log(uint64_t tag, uint64_t value);

} // namespace Eco::Kernel::Console

#endif // ECO_CONSOLE_HPP
