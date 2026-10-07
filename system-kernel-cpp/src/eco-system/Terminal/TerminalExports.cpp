//===- TerminalExports.cpp - C exports of Eco.Kernel.Terminal -------------===//
//
// plans/eco-system-library.md Appendix B.5. Exports only pack and bind
// (G2); the bodies are in Terminal.cpp. The `System.Terminal` effect-manager
// registration is in TerminalManager.cpp.
//
// Templates used: T1.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Terminal/Terminal.hpp"

using namespace Eco::System;

extern "C" {

// getConfiguration : Task Never (Maybe ( Int, Int, Int ))
uint64_t Eco_Kernel_Terminal_getConfiguration() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<terminalGetConfigurationBody>(alloc::unit()));
    )
}

// setStdInRawMode : Bool -> Task Never ()
uint64_t Eco_Kernel_Terminal_setStdInRawMode(uint64_t toggle) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<terminalSetStdInRawModeBody>(dec(toggle)));
    )
}

// setProcessTitle : String -> Task Never ()
uint64_t Eco_Kernel_Terminal_setProcessTitle(uint64_t title) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<terminalSetProcessTitleBody>(dec(title)));
    )
}

} // extern "C"
