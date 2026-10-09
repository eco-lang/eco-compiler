//===- Spawn.hpp - start a child process without fork (POD only) ----------===//
//
// plans/spawn-not-fork.md Phase 1: the ONE way the runtime, the kernels and
// the test harnesses start a child process. Moved from the eco-system
// library's ChildProcess/Spawn (plans/eco-system-library.md Phase 5 step 5.2),
// which keeps its names as aliases.
//
// No fork, ever:
//   * POSIX: posix_spawn / posix_spawnp. No pthread_atfork handler runs
//     (HEAP_075's prepare/parent/child are fork-only), nothing of the parent's
//     heap or locks is duplicated (glibc: clone(CLONE_VM | CLONE_VFORK)).
//     Pinned by test/platform/SpawnTest.cpp.
//   * Windows: CreateProcessW, with explicit handle inheritance
//     (PROC_THREAD_ATTRIBUTE_HANDLE_LIST) and a kill-on-close Job object.
//
// POSIX details (unchanged from the eco-system version):
//   * Every pipe end is O_CLOEXEC (pipe2 on Linux); the child gets its stdio
//     through posix_spawn_file_actions_adddup2, which clears CLOEXEC on the
//     targets. On macOS POSIX_SPAWN_CLOEXEC_DEFAULT closes every other fd in
//     the child.
//   * The working directory is set with posix_spawn_file_actions_addchdir_np
//     where available (ECO_SPAWN_HAVE_ADDCHDIR_NP, from CMake); otherwise the
//     program runs through /bin/sh -c 'cd "$0" && exec "$@"' <cwd> <argv...>.
//   * Shell: DefaultShell = /bin/sh -c "<program> <args joined by spaces>";
//     CustomShell s = s -c "<…>"; NoShell = posix_spawnp(program, argv).
//     Windows: DefaultShell = %ComSpec% (cmd.exe) /d /s /c "<…>"; NoShell
//     searches PATH with PATHEXT (SearchPathW).
//   * Environment: Inherit = the parent's; Merge = the parent's overlaid with
//     the pairs (case-insensitive keys on Windows); Replace = the pairs only.
//
// Templates used: none (POD only, G1/G3). No heap access: callers copy every
// input out of the heap first. Spawn from one thread at a time on macOS (the
// pipe()+FD_CLOEXEC sequence is not atomic there).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PLATFORM_SPAWN_HPP
#define ECO_PLATFORM_SPAWN_HPP

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace Elm::platform {

// Elm-side encodings (eco-system B.4, C.3).
constexpr int kShellNone = 0;
constexpr int kShellDefault = 1;
constexpr int kShellCustom = 2;

constexpr int kEnvInherit = 0;
constexpr int kEnvMerge = 1;
constexpr int kEnvReplace = 2;

struct SpawnSpec {
    std::string program;
    std::vector<std::string> args;
    int shellKind = kShellDefault;
    std::string customShell;
    bool inheritCwd = true;
    std::string cwd;
    int envMode = kEnvInherit;
    std::vector<std::pair<std::string, std::string>> env;
    // StdioMode::ToFile: stdout and stderr both go to this file (created or
    // truncated); stdin is `inputPath` when set, else the null device.
    std::string outputPath;
    std::string inputPath;
    // Windows: put the child in a kill-on-close Job object, so killChild and
    // releaseChild end it AND every process it started (the test harnesses'
    // timeouts). Off by default: like a POSIX child, a spawned program then
    // outlives a parent that exits without waiting for it. Ignored on POSIX.
    bool killTreeOnRelease = false;
};

// How the child's fds 0–2 are connected.
enum class StdioMode : uint8_t {
    Inherit,    // share the parent's 0–2
    Pipes,      // three pipes (stdin, stdout, stderr)
    Null,       // the null device for 0–2
    RunPipes,   // stdin null, stdout and stderr pipes
    StdinPipe,  // stdin pipe, stdout and stderr inherited (Eco.Process.spawnProcess)
    ToFile,     // stdin null (or spec.inputPath), stdout + stderr into spec.outputPath (the test harnesses)
};

struct SpawnedChild {
    int err = 0;          // 0, or the errno of the failed spawn (no child exists)
    int64_t pid = -1;
    // Parent ends (close-on-exec, blocking), -1 when not piped. The caller
    // owns them. On Windows they are CRT fds over the pipe handles
    // (_open_osfhandle).
    int stdinFd = -1;     // write end of the child's stdin
    int stdoutFd = -1;    // read end of the child's stdout
    int stderrFd = -1;    // read end of the child's stderr
    // Windows: the process and its kill-on-close Job object (HANDLEs); null
    // on POSIX. releaseChild closes them.
    void* process = nullptr;
    void* job = nullptr;
};

// Spawns the child described by `spec`. `newSession`: a new session /
// process group (POSIX_SPAWN_SETSID, falling back to SETPGROUP); on Windows
// CREATE_NEW_PROCESS_GROUP.
SpawnedChild spawnChild(const SpawnSpec& spec, StdioMode mode, bool newSession);

// How a child ended.
struct ChildExit {
    bool exited = false;     // ended normally: `code` is its exit status
    int code = 0;
    bool signaled = false;   // POSIX: killed by `signal`; Windows: an exception
    int signal = 0;          // exit code (0xC0000005, …) reported in `signal`
};

enum class ChildState : uint8_t { Running, Ended, Error };

// Non-blocking. On Ended the child is reaped (POSIX) and `out` describes it.
ChildState pollChild(SpawnedChild& child, ChildExit& out);
// Blocks until the child ends; reaps it.
ChildExit waitChild(SpawnedChild& child);
// Kills the child (SIGKILL; on Windows its whole Job). Does not reap.
void killChild(SpawnedChild& child);
// Closes the Windows process and Job handles (no-op on POSIX). The Job is
// kill-on-close, so a still-running child dies here.
void releaseChild(SpawnedChild& child);

#if defined(_WIN32)
// The process HANDLE that spawnChild kept for `pid`, removed from the table
// (the caller now owns it), or null. Eco.Process registers its children so
// WaitService can wait on the handle instead of re-opening a pid.
void* takeProcessHandle(int64_t pid);
void registerProcessHandle(int64_t pid, void* process);
#endif

} // namespace Elm::platform

#endif // ECO_PLATFORM_SPAWN_HPP
