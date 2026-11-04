//===- TerminalExports.cpp - C exports of Eco.Kernel.Terminal -------------===//
//
// The C-linkage entry points of `Eco.Kernel.Terminal`. Each decodes its arguments and returns a Task that runs the
// matching binding body in Terminal.hpp when it is run; making the Task does no terminal IO. The `Terminal` effect
// manager is registered by TerminalManager.cpp.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Terminal/Terminal.hpp"

using namespace Eco::System;

extern "C" {

/// Returns the Task `getConfiguration : Task Never (Maybe ( Int, Int, Int ))`, run by
/// `terminalGetConfigurationBody`.
uint64_t Eco_Kernel_Terminal_getConfiguration() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<terminalGetConfigurationBody>(alloc::unit()));
    )
}

/// Returns the Task `isTerminal fd : Task Never Bool`, run by `terminalIsTerminalBody`. `fd` is the standard stream's
/// file descriptor, 0, 1 or 2.
uint64_t Eco_Kernel_Terminal_isTerminal(int64_t fd) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<terminalIsTerminalBody>(alloc::allocInt(fd)));
    )
}

/// Returns the Task `setStdInRawMode toggle : Task Never ()`, run by `terminalSetStdInRawModeBody`.
uint64_t Eco_Kernel_Terminal_setStdInRawMode(uint64_t toggle) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<terminalSetStdInRawModeBody>(dec(toggle)));
    )
}

/// Returns the Task `setTitle title : Task Never ()`, run by `terminalSetTitleBody`.
uint64_t Eco_Kernel_Terminal_setTitle(uint64_t title) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<terminalSetTitleBody>(dec(title)));
    )
}

} // extern "C"
