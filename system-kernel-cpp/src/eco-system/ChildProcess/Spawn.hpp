//===- Spawn.hpp - posix_spawn of a child process (POD only) --------------===//
//
// plans/eco-system-library.md Phase 5 step 5.2 "Spawning", "Shell",
// "Environment". Pure POD: no heap access, so it may run anywhere on the
// main thread (children are spawned from the main thread only, which is
// what makes the macOS pipe()+FD_CLOEXEC sequence race-free, §3.4).
//
//   * posix_spawn / posix_spawnp only, never fork (HEAP_075: no atfork
//     handlers run, nothing of the parent's heap or locks is duplicated).
//   * Every pipe end is O_CLOEXEC (pipe2 on Linux); the child gets its stdio
//     through posix_spawn_file_actions_adddup2, which clears CLOEXEC on the
//     targets. On macOS POSIX_SPAWN_CLOEXEC_DEFAULT closes every other fd in
//     the child.
//   * The working directory is set with posix_spawn_file_actions_addchdir_np
//     where available (ECO_SYSTEM_HAVE_ADDCHDIR_NP, from CMake); otherwise
//     the program runs through
//     /bin/sh -c 'cd "$0" && exec "$@"' <cwd> <argv...>.
//   * Shell: DefaultShell = /bin/sh -c "<program> <args joined by spaces>"
//     (as gren's ChildProcess.js joins them); CustomShell s = s -c "<…>";
//     NoShell = posix_spawnp(program, [program, args…]).
//   * Environment: Inherit = environ; Merge = environ overlaid with the
//     pairs; Replace = the pairs only.
//
// Windows: spawnChild fails with ENOTSUP (§1).
//
// Templates used: none (POD only, G1/G3).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CHILD_PROCESS_SPAWN_HPP
#define ECO_SYSTEM_CHILD_PROCESS_SPAWN_HPP

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace Eco::System {

// Elm-side encodings (B.4, C.3).
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
};

// How the child's fds 0–2 are connected.
enum class StdioMode : uint8_t {
    Inherit,    // Integrated: share the parent's 0–2
    Pipes,      // External: three pipes (stdin, stdout, stderr)
    Null,       // Ignored / Detached: /dev/null for 0–2
    RunPipes,   // run: stdin /dev/null, stdout and stderr pipes
};

struct SpawnedChild {
    int err = 0;          // 0, or the errno of the failed spawn (no child exists)
    int64_t pid = -1;
    // Parent ends (O_CLOEXEC, blocking), -1 when not piped. The caller owns
    // them.
    int stdinFd = -1;     // write end of the child's stdin
    int stdoutFd = -1;    // read end of the child's stdout
    int stderrFd = -1;    // read end of the child's stderr
};

// Spawns the child described by `spec`. `newSession`: POSIX_SPAWN_SETSID
// (Detached), falling back to a new process group where SETSID is missing.
// Main thread only.
SpawnedChild spawnChild(const SpawnSpec& spec, StdioMode mode, bool newSession);

} // namespace Eco::System

#endif // ECO_SYSTEM_CHILD_PROCESS_SPAWN_HPP
