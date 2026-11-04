#ifndef ECO_PROCESS_HPP
#define ECO_PROCESS_HPP

/// @file
/// The kernel of `Eco.Process`: ending this program, and starting other
/// programs and waiting for them to finish.
///
/// A child program is started directly, not through a shell, and shares this
/// process's standard output and error. Its standard input is either shared too
/// or, for `spawnProcess`, a pipe whose writing end is handed back to Elm. A
/// program that cannot be started fails the Task with the IO error tuple.
///
/// Every function except `exit` returns a Task that does its work when the
/// scheduler runs it, not when the function is called. `exit` acts at once,
/// since it never returns and there would be no Task to deliver.
///
/// Waiting for a child does not block the thread running Elm: the wait is done
/// on a thread of the runtime's `WaitService`, and the Task resumes when the
/// child's exit code comes back.
///
/// Every `uint64_t` parameter and result is the encoded word of an Elm value,
/// except `wait`'s `handle`, which is the process id itself.

#include <cstdint>

namespace Eco::Kernel::Process {

/// Ends the process with status `code` when called, through
/// `eco_terminate_process` (`std::exit` on POSIX, `TerminateProcess` on
/// Windows). Does not return.
uint64_t exit(int64_t code);

/// Returns a Task that starts the program `cmd` (an Elm String) with the List
/// of String arguments `args`, sharing all three standard streams, and succeeds
/// with the child's process id as an Int. The Task fails with the IO error
/// tuple, whose path is `cmd`, when the program cannot be started. A GC point.
uint64_t spawn(uint64_t cmd, uint64_t args);

/// Returns a Task that starts `cmd` with `args` as `spawn` does, and succeeds
/// with the tuple `( stdinHandle, pid )`. A GC point.
///
/// `stdin_` is a String. When it is `"pipe"`, the child's standard input is a
/// pipe and `stdinHandle` is `Just` the file descriptor of its writing end, an
/// Int, which `Console.write` writes to and `File.close` closes; for any other
/// value standard input is shared and `stdinHandle` is `Nothing`. Standard
/// output and error are always shared. The Task fails as `spawn`'s does.
uint64_t spawnProcess(uint64_t cmd, uint64_t args, uint64_t stdin_);

/// Returns a Task that waits for the child with process id `handle` to exit,
/// and succeeds with its exit code as an Int, or -1 when it could not be
/// waited for; on POSIX a child ended by a signal gives 128 plus the signal
/// number. The Task never fails. Killing it stops the wait (it no longer keeps
/// the program alive) but not the child. A GC point.
uint64_t wait(uint64_t handle);

/// Returns the descriptor of the open `spawnProcess` stdin pipe whose handle
/// is `handle`, or -1 when `handle` names none. Eco thread only.
int streamHandleFd(int64_t handle);

/// Forgets the `spawnProcess` stdin pipe whose handle is `handle`, if any, so
/// a later write to that number (a reused descriptor) is refused. Called when
/// the handle is closed. Eco thread only.
void forgetStreamHandle(int64_t handle);

} // namespace Eco::Kernel::Process

#endif // ECO_PROCESS_HPP
