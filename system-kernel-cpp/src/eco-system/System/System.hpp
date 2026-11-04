//===- System.hpp - eco/system kernel module System (internal) ------------===//
//
// An Elm program needs facts about the process it runs in, and a way to end it. This component supplies
// them for the eco/system `System` module: the startup environment, the environment variables, and the
// process exit code.
//
// The startup environment is one plain value, not a Task: the platform and architecture names, the path of
// the executable, the command-line arguments, the start time, and the ids of the stream pairs for stdin,
// stdout and stderr. The other functions here are binding bodies: each runs when its Task is run, not when
// the kernel is called, and each Task's error type is `Never`, so an exception escaping a body is a fatal
// error (`ECO_SYSTEM_BODY_GUARD`).
//
// The `extern "C"` kernels that build these Tasks are in SystemExports.cpp. The "System" effect manager,
// with its subscriptions, is `SystemManager`. Every function here must be called on the eco thread, the
// thread that runs the Elm scheduler.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SYSTEM_SYSTEM_HPP
#define ECO_SYSTEM_SYSTEM_SYSTEM_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

/// Returns the startup environment, the Elm value
/// `( ( platform, arch, appPath ), ( argv, startMillis ), ( stdinId, stdoutId, stderrId ) )`.
///
/// `platform` and `arch` are fixed when this file is compiled, spelled as Node's `process.platform` and
/// `process.arch` are, or "unknown". `appPath` is the executable's path, or "" where it cannot be found or
/// the platform is neither Linux nor macOS. `argv` is the whole C argv of the process, the program name
/// included; in a process that embeds the program it is the host's. `argv` is empty on platforms other than
/// Linux, macOS and Windows, and on Linux when /proc/self/cmdline cannot be read. `startMillis` is the
/// wall-clock time of this call in milliseconds since the Unix epoch, held unboxed, as are the three stream
/// ids.
///
/// The stdio pairs are made by the first call in each heap generation and pinned, so they are never erased;
/// later calls return the same ids while all three ids are nonzero and still in the stream table. An id is 0
/// when its pair could not be made. They never close fds 0 to 2. Allocates.
HPointer systemEnvironmentNow();
/// Returns a Task that succeeds with the process's environment variables as a list of `( name, value )`
/// pairs, in the order the environment holds them. Each entry is split at its first '='; an entry with no
/// '=' gives an empty value. `captured` is unused.
HPointer systemGetEnvironmentVariablesBody(HPointer captured);
/// Records the boxed Int `captured`, truncated to `int`, as the exit code, and stops the program.
///
/// In embed mode it asks the scheduler to stop (`Scheduler::requestStop`) and returns a Task that succeeds
/// with `()`; the host reads the code. Otherwise it flushes every C stdio stream and calls `std::exit`, so
/// it does not return, and IO still pending in other threads or in stream tables is not waited for.
HPointer systemExitWithCodeBody(HPointer captured);
/// Records the boxed Int `captured`, truncated to `int`, as the exit code the process will end with, and
/// returns a Task that succeeds with `()`. The program keeps running.
HPointer systemSetExitCodeBody(HPointer captured);
/// Arms the empty-event-loop subscription again (`SystemManager::rearmEmptyEventLoop`) and returns a Task
/// that succeeds with `()`. `captured` is unused.
HPointer systemRearmEmptyEventLoopBody(HPointer captured);

} // namespace Eco::System

#endif // ECO_SYSTEM_SYSTEM_SYSTEM_HPP
