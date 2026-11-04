//===- ChildProcessManager.hpp - The C++ effect manager of ChildProcess -===//
//
// An Elm program starts a long-lived child process with `ChildProcess.spawn`, a command, and learns of the child
// twice: once it has started, and once it has ended. This header is the native side of the `ChildProcess` effect
// manager that carries those commands out: the numbers by which it reads the commands, and the export that
// registers it.
//
// An *effect manager* is a set of closures (init, onEffects, onSelfMsg, cmdMap, subMap) registered under a string
// key, here "ChildProcess", before the program starts. The Elm module `ChildProcess` (ChildProcess.elm) declares
// the manager's one command:
//
//     type MyCmd msg
//         = Spawn
//             ( ( String, List String )
//             , ( ( Int, String ), ( Bool, String ) )
//             , ( ( Int, List ( String, String ) ), Int, Int )
//             )
//             (( Process.Id, Maybe ( Int, Int, Int ) ) -> msg)
//             (( Int, Int ) -> msg)
//
// The first field, the *spec*, is `( ( program, args ), ( ( shellKind, customShell ), ( inheritCwd, cwd ) ),
// ( ( envMode, pairs ), runDurationMs, connectionKind ) )`. The second, *onInit*, makes the message that reports
// the start: the Elm process that stands for the child and, for an External connection, the stream ids of the
// child's stdin, stdout and stderr. The third, *onExit*, makes the message that reports the end from
// `( exitCode, signal )`.
//
// The C++ manager reads a command by constructor number and field position, so the constants below must match the
// Elm declaration. Constructors are numbered from 0 in declaration order.
//
// A *connection* kind says how the child's standard input, output and error are connected, and whether the child
// keeps the program running.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_MANAGER_HPP
#define ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_MANAGER_HPP

#include <cstdint>

namespace Eco::System::ChildProcessManager {

/// The constructor number of `MyCmd`'s `Spawn`.
constexpr uint16_t CTOR_SPAWN = 0;
/// The field of a `Spawn` that holds the spec.
constexpr int SPAWN_SPEC_FIELD = 0;
/// The field of a `Spawn` that holds the onInit function.
constexpr int SPAWN_ON_INIT_FIELD = 1;
/// The field of a `Spawn` that holds the onExit function.
constexpr int SPAWN_ON_EXIT_FIELD = 2;

/// The slot-kind mask of the spec's third tuple, `( ( envMode, pairs ), runDurationMs, connectionKind )`: the
/// first slot boxed, the other two unboxed Ints.
constexpr uint32_t SPEC_TRIPLE_MASK = 0x14;

/// The connection kind whose child shares the program's stdin, stdout and stderr.
constexpr int64_t CONN_INTEGRATED = 0;
/// The connection kind whose child's stdin, stdout and stderr are pipes, handed to the program as streams.
constexpr int64_t CONN_EXTERNAL = 1;
/// The connection kind whose child's stdin, stdout and stderr are the null device.
constexpr int64_t CONN_IGNORED = 2;
/// The connection kind whose child's stdin, stdout and stderr are the null device, whose child is started in a new
/// session or process group, and which does not keep the program running while the child runs.
constexpr int64_t CONN_DETACHED = 3;

} // namespace Eco::System::ChildProcessManager

extern "C" {
/// Registers the `ChildProcess` effect manager, which has commands and no subscriptions, and returns the encoded
/// `()`.
///
/// Each `Spawn` command the manager receives starts a child and creates the Elm process that stands for it, which
/// ends when the child ends; killing that process sends the child SIGTERM. The manager then sends the program the
/// onInit message, and the onExit message with the child's `( exitCode, signal )` once the child has ended. When
/// spawning fails (the start reports an errno), the program still gets the onInit message, with stream ids 0 for an
/// External connection, followed at once by onExit `( -errno, 0 )`. A program a shell cannot run is
/// reported as an ordinary exit instead. On Windows a `Spawn` ends the program with a fatal error.
uint64_t Eco_System_registerManager_ChildProcess();
}

#endif // ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_MANAGER_HPP
