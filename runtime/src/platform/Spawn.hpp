//===- Spawn.hpp - start a child process without fork ---------------------===//
//
// Starting a child process from a process that runs a garbage-collected heap with helper threads is
// hazardous when it goes through `fork`: `fork` runs the `pthread_atfork` handlers the collector
// installs, and the child begins as a copy of the parent's memory and locks. This component starts
// children without `fork`.
//
// It offers one operation to start a child, `spawnChild`, and four to follow it: `pollChild`,
// `waitChild`, `killChild` and `releaseChild`. The inputs are plain data: strings, integers and flags,
// with no Elm values. Nothing here touches the heap, so a caller copies its inputs out of the heap before
// calling.
//
// On POSIX a child is started with `posix_spawn` or `posix_spawnp`, which run no `pthread_atfork`
// handler. On Windows it is started with `CreateProcessW`, which inherits only the three standard
// handles chosen for the child, listed explicitly with `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.
//
// A `SpawnSpec` describes what to run, in three independent choices:
//
// - The shell. With `kShellNone`, `program` is run directly with `args` as its arguments, and is looked
//   up on `PATH` when it is not a path (on Windows, with `SearchPathW`'s search order, trying `.exe`,
//   and an unfound name is left to `CreateProcessW`). With a shell, `program` and `args` are joined by
//   single spaces, with no quoting, into one command line that the shell interprets. On POSIX that
//   shell is `/bin/sh -c <line>`, or `<customShell> -c <line>`. On Windows it is
//   `%ComSpec%` (or `cmd.exe`) given `/d /s /c <line>`, and a custom shell is given the same three flags.
// - The working directory: the parent's, or `cwd`. Where the build defines
//   `ECO_SPAWN_HAVE_ADDCHDIR_NP`, POSIX sets it with `posix_spawn_file_actions_addchdir_np`. Otherwise
//   the child runs as `/bin/sh -c 'cd "$0" && exec "$@"' <cwd> <argv...>`.
// - The environment: the parent's (`kEnvInherit`), the parent's with the pairs in `env` added or
//   replacing entries of the same name (`kEnvMerge`), or the pairs alone (`kEnvReplace`). Names are
//   compared case-sensitively on POSIX and case-insensitively on Windows.
//
// A `StdioMode`, passed separately, says how the child's standard input, output and error are connected.
//
// On POSIX every pipe and file this component opens is close-on-exec. The child receives its standard
// streams through `posix_spawn_file_actions_adddup2`, which leaves the duplicates open across `exec`.
// On macOS `POSIX_SPAWN_CLOEXEC_DEFAULT` also closes every other descriptor in the child. On Linux pipes
// are created close-on-exec in one step with `pipe2`. On other POSIX systems `pipe` and `fcntl` are two
// steps, so a child started by another thread between them can inherit the pipe. On macOS
// `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps the pipe out of children started by `spawnChild`, so only a child
// started by other means can inherit it.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PLATFORM_SPAWN_HPP
#define ECO_PLATFORM_SPAWN_HPP

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace Elm::platform {

/// The value of `SpawnSpec::shellKind` that runs `program` directly, with no shell.
///
/// The `kShell*` and `kEnv*` constants are plain `int`s, so the compiler accepts any integer where one is
/// expected. Their values are the encoding the Elm side uses.
constexpr int kShellNone = 0;
/// The value of `SpawnSpec::shellKind` that runs the command line through the platform's default shell.
constexpr int kShellDefault = 1;
/// The value of `SpawnSpec::shellKind` that runs the command line through `SpawnSpec::customShell`. An
/// empty `customShell` falls back to the default shell.
constexpr int kShellCustom = 2;

/// The value of `SpawnSpec::envMode` that gives the child the parent's environment.
constexpr int kEnvInherit = 0;
/// The value of `SpawnSpec::envMode` that gives the child the parent's environment overlaid with
/// `SpawnSpec::env`.
constexpr int kEnvMerge = 1;
/// The value of `SpawnSpec::envMode` that gives the child only `SpawnSpec::env`.
constexpr int kEnvReplace = 2;

/// A description of a child process to start: what to run, where, and with what environment.
///
/// The file comment sets out what `shellKind`, `inheritCwd`/`cwd` and `envMode`/`env` mean. An
/// unrecognised `shellKind` is treated as a shell, and an unrecognised `envMode` as `kEnvMerge`.
struct SpawnSpec {
    std::string program;
    std::vector<std::string> args;
    int shellKind = kShellDefault;
    std::string customShell;
    bool inheritCwd = true;
    std::string cwd; ///< Used only when `inheritCwd` is false.
    int envMode = kEnvInherit;
    std::vector<std::pair<std::string, std::string>> env;
    std::string outputPath; ///< Used only by `StdioMode::ToFile`.
    std::string inputPath;  ///< Used only by `StdioMode::ToFile`; empty means the null device.
    /// Windows only: put the child in a Job object that kills every process in it when the Job's handle
    /// is closed. `killChild` then ends the child and every process it started; `releaseChild` describes
    /// closing the Job. If the Job cannot be created or the child cannot be assigned to it, the child runs
    /// without one. If the kill-on-close limit cannot be set, the Job is kept without it. When false, the
    /// child is not ended by `releaseChild` and can outlive the parent. Ignored on POSIX.
    bool killTreeOnRelease = false;
};

/// How the child's standard input, output and error (descriptors 0 to 2) are connected. Where a mode gives
/// the child a stream of the parent's, on Windows a stream the parent lacks, or cannot duplicate, is left
/// unset in the child.
enum class StdioMode : uint8_t {
    Inherit,    ///< All three are the parent's.
    Pipes,      ///< Each is a pipe to the parent.
    Null,       ///< All three are the null device.
    RunPipes,   ///< Input is the null device; output and error are pipes.
    StdinPipe,  ///< Input is a pipe; output and error are the parent's.
    ToFile,     ///< Input is `SpawnSpec::inputPath`, or the null device when that is empty; output and
                ///< error both go to `SpawnSpec::outputPath`, created or truncated.
};

/// The result of `spawnChild`: whether a child was started, and the handles on it.
///
/// When `err` is non-zero no child exists, `pid` is -1, every descriptor is -1 and both handles are
/// null.
struct SpawnedChild {
    /// Zero on success, or an `errno` value for the failure. On Windows the system error is mapped to
    /// `ENOENT`, `EACCES`, `ENOMEM` or `ENOEXEC`, and any other to `EIO`.
    int err = 0;
    int64_t pid = -1;
    // The parent's ends of the pipes, blocking, and -1 for a stream that is not a pipe. The caller owns
    // them and must close them. On POSIX they are close-on-exec. On Windows they are C runtime
    // descriptors over the pipe handles, which are not inheritable.
    int stdinFd = -1;     ///< Write end of the child's input pipe.
    int stdoutFd = -1;    ///< Read end of the child's output pipe.
    int stderrFd = -1;    ///< Read end of the child's error pipe.
    /// Windows: the process handle, closed by `releaseChild`. Null on POSIX. Once it is passed to
    /// `registerProcessHandle` the record no longer owns it: set it to null before `releaseChild`.
    void* process = nullptr;
    /// Windows: the Job handle, null unless `SpawnSpec::killTreeOnRelease` created one.
    /// Closed by `releaseChild`. Null on POSIX.
    void* job = nullptr;
};

/// Starts the child that `spec` describes, with its standard streams connected as `mode` says, and
/// returns the handles on it, or the error in `SpawnedChild::err`.
///
/// When `newSession` is true the child is put in a new session (`POSIX_SPAWN_SETSID`), or, where that
/// flag is unavailable, a new process group; on Windows, a new process group. On POSIX the child starts
/// with an empty signal mask and the default disposition for `SIGPIPE`, `SIGINT`, `SIGTERM` and
/// `SIGWINCH`. On failure every descriptor and handle opened for the child is closed.
///
/// When a shell runs the command line, or on POSIX the `cd` wrapper runs it, a program the shell cannot
/// run is reported as a child that exits (127 under `/bin/sh`). With `kShellNone` and no wrapper,
/// whether it is reported in `err` or as a child that exits is decided by `posix_spawn` and
/// `CreateProcessW`.
SpawnedChild spawnChild(const SpawnSpec& spec, StdioMode mode, bool newSession);

/// How a child ended. Both flags are false when the outcome is unknown.
struct ChildExit {
    bool exited = false;     ///< The child ended normally, with exit status `code`.
    int code = 0;
    /// POSIX: the child was killed by signal `signal`. Windows: it ended with an exit code of the form
    /// `0xCxxxxxxx`, an NTSTATUS error such as an access violation, and `signal` holds that code.
    bool signaled = false;
    int signal = 0;
};

/// What `pollChild` found: the child is still running, it has ended, or the check failed.
enum class ChildState : uint8_t { Running, Ended, Error };

/// Checks, without blocking, whether `child` has ended, and on `Ended` writes how into `out`.
///
/// On POSIX an ended child is reaped, so a later call for it returns `Error`. On Windows nothing is
/// reaped and a later call returns `Ended` again. `Error` is also returned for a record with no child
/// (no pid on POSIX, no process handle on Windows). `out` is written only on `Ended`.
ChildState pollChild(SpawnedChild& child, ChildExit& out);
/// Blocks until `child` ends, and returns how. On POSIX the child is reaped. A record with no child, or
/// on POSIX a failed wait, returns a `ChildExit` with both flags false. On Windows a failed wait is not
/// detected, and the result is whatever exit code the process reports.
ChildExit waitChild(SpawnedChild& child);
/// Kills `child` without reaping it. On POSIX it sends `SIGKILL` to the child's pid alone, not to its
/// process group. On Windows it terminates the child's Job, and so every process in it, when there is
/// one, and otherwise the child alone.
///
/// On POSIX the pid must not yet have been reaped, or the signal may reach an unrelated process that
/// reused it.
void killChild(SpawnedChild& child);
/// Closes the Windows process and Job handles and sets both to null; on POSIX it only sets them to null.
/// It does not close the pipe descriptors.
///
/// Closing the Job, when `SpawnSpec::killTreeOnRelease` created one with the kill-on-close limit, kills
/// the child and every process it started, unless another handle holds the Job open. Without such a Job
/// the child keeps running.
void releaseChild(SpawnedChild& child);

#if defined(_WIN32)
/// Removes the process handle registered for `pid` and returns it, or returns null if none is. The
/// caller then owns the handle and must close it.
void* takeProcessHandle(int64_t pid);
/// Registers `process` as the handle for `pid`, for a later `takeProcessHandle`, replacing any handle
/// registered for `pid` without closing it. `spawnChild` registers nothing itself. The `SpawnedChild`
/// the handle came from no longer owns it. Nothing here closes a registered handle; it passes to whoever
/// takes it. Both functions take one mutex, so they may be called from several threads at once.
void registerProcessHandle(int64_t pid, void* process);
#endif

} // namespace Elm::platform

#endif // ECO_PLATFORM_SPAWN_HPP
