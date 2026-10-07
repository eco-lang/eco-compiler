//===- ChildProcessManager.hpp - The C++ effect manager of System.Process -===//
//
// plans/eco-system-library.md §3.6, Appendix C.3 (manager key
// "System.Process") and Phase 5 step 5.2. The Elm declaration lives in
// system-kernel-cpp/src/System/Process.elm, section "EFFECT MANAGER":
//
//     type MyCmd msg
//         = Spawn
//             ( ( String, List String ), ( ( Int, String ), ( Bool, String ) ), ( ( Int, List ( String, String ) ), Int, Int ) )
//             (( Process.Id, Maybe ( Int, Int, Int ) ) -> msg)
//             (( Int, Int ) -> msg)
//     -- tag 0: [spec boxed, onInit boxed, onExit boxed]
//
// spec = ((program, args), ((shellKind, customShell), (inheritCwd, cwd)),
//         ((envMode, pairs), runDurationMs, connectionKind)); the last triple
// has mask 0x14 (boxed, Int, Int), (Int, String) has mask 0x1.
// Tags are the zero-based declaration indexes (Compiler/Data/CtorTag.elm).
// Keep the two in sync.
//
// Templates used: T6 (manager), T7 (child kill handle), T8 (taggers).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_MANAGER_HPP
#define ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_MANAGER_HPP

#include <cstdint>

namespace Eco::System::ChildProcessManager {

// MyCmd
constexpr uint16_t CTOR_SPAWN = 0;
constexpr int SPAWN_SPEC_FIELD = 0;
constexpr int SPAWN_ON_INIT_FIELD = 1;
constexpr int SPAWN_ON_EXIT_FIELD = 2;

// spec.c (the triple) slots: ( ( envMode, pairs ), runDurationMs, connectionKind )
constexpr uint32_t SPEC_TRIPLE_MASK = 0x14;

// connectionKind
constexpr int64_t CONN_INTEGRATED = 0;
constexpr int64_t CONN_EXTERNAL = 1;
constexpr int64_t CONN_IGNORED = 2;
constexpr int64_t CONN_DETACHED = 3;

} // namespace Eco::System::ChildProcessManager

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (§3.6);
// returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_System_Process();
}

#endif // ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_MANAGER_HPP
