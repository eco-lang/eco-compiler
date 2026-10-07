//===- SystemManager.hpp - The C++ effect manager of `System` -------------===//
//
// plans/eco-system-library.md §3.6 and Appendix C.1 (manager key "System").
// The Elm declarations live in system-kernel-cpp/src/System.elm, in the
// "EFFECT MANAGER" section:
//
//     type MyCmd msg = Execute (Task Never ())          -- tag 0: [task boxed]
//     type MySub msg
//         = OnEmptyEventLoop msg                        -- tag 0: [msg boxed]
//         | OnSignalInterrupt msg                       -- tag 1: [msg boxed]
//         | OnSignalTerminate msg                       -- tag 2: [msg boxed]
//
// Tags are the zero-based declaration indexes (Compiler/Data/CtorTag.elm);
// every constructor has one boxed field. Keep the two in sync.
//
// Templates used: T6 (manager), T5 (state registry), T8/G12 (delivery).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SYSTEM_SYSTEM_MANAGER_HPP
#define ECO_SYSTEM_SYSTEM_SYSTEM_MANAGER_HPP

#include <cstdint>

namespace Eco::System::SystemManager {

// MyCmd
constexpr uint16_t CTOR_EXECUTE = 0;
constexpr int EXECUTE_TASK_FIELD = 0;

// MySub
constexpr uint16_t CTOR_ON_EMPTY_EVENT_LOOP = 0;
constexpr uint16_t CTOR_ON_SIGNAL_INTERRUPT = 1;
constexpr uint16_t CTOR_ON_SIGNAL_TERMINATE = 2;
constexpr int SUB_MSG_FIELD = 0;
constexpr int SUB_CTOR_COUNT = 3;

} // namespace Eco::System::SystemManager

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (§3.6);
// returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_System();
}

#endif // ECO_SYSTEM_SYSTEM_SYSTEM_MANAGER_HPP
