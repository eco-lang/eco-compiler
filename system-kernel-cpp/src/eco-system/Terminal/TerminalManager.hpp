//===- TerminalManager.hpp - The C++ effect manager of Terminal ----===//
//
// A program that draws on a terminal must redraw when the terminal is resized. `Terminal.onResize` is the
// subscription that tells it, and this component is the effect manager behind it on the native backend: the C++
// code registered under the key "Terminal" in place of the Elm manager in `system-kernel-cpp/src/Terminal.elm`.
//
// An effect manager is a set of closures the runtime calls to keep the program's subscriptions current. Each time
// the subscriptions change, the manager is given the whole new list, and it keeps it until the next. This one has
// one kind of subscription, declared in Elm as
//
//     type MySub msg = OnResize (( Int, Int ) -> msg)
//
// where the function, the *tagger*, turns a size `( columns, rows )` into the program's message. It has no
// commands.
//
// While at least one `OnResize` subscription exists, the manager listens for SIGWINCH, the signal a terminal sends
// when its size changes, through `SignalService`. On each one it reads the size as `terminalSize` does and sends
// one message per subscription to the program; when no standard stream reports a size, nothing is sent. A
// subscription does not keep the program running. Nothing is ever received in embed mode, where `SignalService`
// refuses listeners. On Windows a non-empty subscription list ends the process with `Eco::Kernel::reportFatal`.
//
// The C++ code reads an `OnResize` value by its constructor number and field position, which must match the
// declaration in `Terminal.elm`: constructors are numbered from 0 in declaration order. Nothing checks that the
// two agree.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TERMINAL_TERMINAL_MANAGER_HPP
#define ECO_SYSTEM_TERMINAL_TERMINAL_MANAGER_HPP

#include <cstdint>

namespace Eco::System::TerminalManager {

/// The constructor number of `OnResize`, the only constructor of `MySub`.
constexpr uint16_t CTOR_ON_RESIZE = 0;
/// The field of an `OnResize` value that holds its tagger.
constexpr int ON_RESIZE_TAGGER_FIELD = 0;

} // namespace Eco::System::TerminalManager

extern "C" {
/// Registers the "Terminal" effect manager with the runtime, and returns the encoded `()`. Called from the
/// compiler-emitted `@__eco_register_ports` function. A C++ exception inside ends the process with
/// `Eco::Kernel::reportFatal`.
uint64_t Eco_System_registerManager_Terminal();
}

#endif // ECO_SYSTEM_TERMINAL_TERMINAL_MANAGER_HPP
