//===- TerminalManager.hpp - The C++ effect manager of System.Terminal ----===//
//
// plans/eco-system-library.md §3.6 and Appendix C.4 (manager key
// "System.Terminal"). The Elm declaration lives in
// system-kernel-cpp/src/System/Terminal.elm, section "EFFECT MANAGER":
//
//     type MySub msg = OnResize (( Int, Int ) -> msg)
//     -- tag 0: [tagger boxed]; arg = ( columns, rows ), mask 0x5
//
// Tags are the zero-based declaration indexes (Compiler/Data/CtorTag.elm).
// Keep the two in sync.
//
// Templates used: T6 (manager), T5 (state), T8 (delivery).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TERMINAL_TERMINAL_MANAGER_HPP
#define ECO_SYSTEM_TERMINAL_TERMINAL_MANAGER_HPP

#include <cstdint>

namespace Eco::System::TerminalManager {

// MySub
constexpr uint16_t CTOR_ON_RESIZE = 0;
constexpr int ON_RESIZE_TAGGER_FIELD = 0;

} // namespace Eco::System::TerminalManager

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (§3.6);
// returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_System_Terminal();
}

#endif // ECO_SYSTEM_TERMINAL_TERMINAL_MANAGER_HPP
