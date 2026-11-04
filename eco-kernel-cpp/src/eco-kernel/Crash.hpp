//===- Crash.hpp - Crash kernel module -------------------------------------===//
//
// The Crash kernel module gives an Elm program a way to stop at an unrecoverable error and report why it stopped,
// with a native backtrace where the C library provides one. It holds one function, `crash`, which the C-linkage
// export for `Crash.crash` in `KernelExports.h` calls; that export's comment is the contract seen by generated code.
//
// `crash` acts when called: it does not build a Task, and it never returns, because it ends the process.
//
//===----------------------------------------------------------------------===//
#ifndef ECO_CRASH_HPP
#define ECO_CRASH_HPP

#include <cstdint>

namespace Eco::Kernel::Crash {

/// Writes `Eco crash: ` followed by the Elm String `message` and a newline to stderr, then the line
/// `Backtrace (N frames):` and up to 64 native stack frames, and exits the process with status 1.
///
/// `message` must be a String word, as `toString` requires. Where `<execinfo.h>` is not available, no frames are
/// captured and N is 0. The exit goes through `eco_terminate_process`, so on POSIX it runs the process's normal exit
/// handlers and on Windows it ends the process with `TerminateProcess`, which runs none. Never returns; the `uint64_t` return type
/// only matches the other kernel functions.
uint64_t crash(uint64_t message);

} // namespace Eco::Kernel::Crash

#endif // ECO_CRASH_HPP
