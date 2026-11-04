//===- SystemManager.hpp - The C++ effect manager of `System` -------------===//
//
// On the native backend an Elm effect module's manager is a set of C++ closures registered under the module's
// name, and this component is that manager for the `System` effect module (`system-kernel-cpp/src/System.elm`).
// It runs the module's one command and reports its three subscriptions.
//
// The manager reads the module's `MyCmd` and `MySub` values by constructor tag and field position, so the
// constants below mirror the Elm declarations:
//
//     type MyCmd msg = Execute (Task Never ())          -- tag 0, field 0: the task
//     type MySub msg
//         = OnEmptyEventLoop msg                        -- tag 0, field 0: the msg
//         | OnSignalInterrupt msg                       -- tag 1, field 0: the msg
//         | OnSignalTerminate msg                       -- tag 2, field 0: the msg
//
// A constructor's tag is its zero-based position in the declaration, and each constructor has one boxed field.
// Nothing checks the two against each other; a change to either must be made to both.
//
// What the manager does with them:
//
//   * `Execute task` spawns `task` as a process of its own, whose result is ignored.
//   * `OnSignalInterrupt msg` and `OnSignalTerminate msg` send `msg` to the program for each SIGINT or
//     SIGTERM that `SignalService` delivers, through listeners held only while such a subscription exists.
//   * `OnEmptyEventLoop msg` sends `msg` when the event loop runs out of work, through a scheduler quiescence
//     listener. It fires once per *arming*: one armed flag for the program's state, which starts set, is
//     cleared by each delivery, and is set again only by `rearmEmptyEventLoop` (or by a heap reset, which
//     re-creates the state). New work arriving does not re-arm it. The JavaScript kernel
//     (`src/Eco/Kernel/System.js`) must follow the same arming rule.
//
// When several subscriptions of one kind exist, each receives its msg, in subscription order, with the program's
// update run and the scheduler drained after each. None of the three subscriptions keeps the program running,
// and neither the signal nor the empty-event-loop subscription fires in embed mode, where `SignalService`
// installs no handlers and the scheduler calls no quiescence listeners.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SYSTEM_SYSTEM_MANAGER_HPP
#define ECO_SYSTEM_SYSTEM_SYSTEM_MANAGER_HPP

#include <cstdint>

namespace Eco::System::SystemManager {

/// The constructor tag of `Execute`, the only `MyCmd` constructor.
constexpr uint16_t CTOR_EXECUTE = 0;
/// The field of an `Execute` command that holds its task.
constexpr int EXECUTE_TASK_FIELD = 0;

/// The constructor tag of `OnEmptyEventLoop`.
constexpr uint16_t CTOR_ON_EMPTY_EVENT_LOOP = 0;
/// The constructor tag of `OnSignalInterrupt`, the SIGINT subscription.
constexpr uint16_t CTOR_ON_SIGNAL_INTERRUPT = 1;
/// The constructor tag of `OnSignalTerminate`, the SIGTERM subscription.
constexpr uint16_t CTOR_ON_SIGNAL_TERMINATE = 2;
/// The field of every `MySub` constructor that holds its msg.
constexpr int SUB_MSG_FIELD = 0;
/// The number of `MySub` constructors. A subscription with a tag at or above it is ignored.
constexpr int SUB_CTOR_COUNT = 3;

/// Arms the empty-event-loop subscription, so that `onEmptyEventLoop` delivers again the next time the event loop
/// runs out of work. Arming an already armed subscription changes nothing.
/// Must be called on the eco thread, the one that runs the Elm scheduler.
void rearmEmptyEventLoop();

} // namespace Eco::System::SystemManager

extern "C" {
/// Registers this manager's closures with `PlatformRuntime` under the name "System", and returns the encoded Unit
/// word. It allocates the closures on the GC heap, so it must be called on the eco thread, and it must be called
/// before the program's effects are set up: `PlatformRuntime::registerManager` says what happens to a manager
/// registered later. A C++ exception inside it is reported as fatal rather than returned.
uint64_t Eco_System_registerManager_System();
}

#endif // ECO_SYSTEM_SYSTEM_SYSTEM_MANAGER_HPP
