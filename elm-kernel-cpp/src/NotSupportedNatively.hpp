//===- NotSupportedNatively.hpp - Ending a program at a browser-only kernel -===//
//
// elm/browser and elm/file have kernels that need a browser (the DOM, navigation, the debugger, file
// pickers). Natively they have no counterpart. By decision D9 of plans/kernel-lib-bug-fixes.md, such a
// kernel whose Task can fail fails its Task, and every other one (a pure function, a `Cmd`, a `Sub` or a
// Task that cannot fail) ends the program with `unsupportedNatively`.
//
//===----------------------------------------------------------------------===//

#ifndef ELM_KERNEL_NOT_SUPPORTED_NATIVELY_HPP
#define ELM_KERNEL_NOT_SUPPORTED_NATIVELY_HPP

#include "allocator/RuntimeExports.h"

namespace Elm::Kernel {

/// Prints "<elmFunction> is not supported natively" and ends the process with status 1 through
/// `eco_terminate_process`, as `Debug.todo` does. `elmFunction` names the Elm function the program called,
/// e.g. `Browser.Navigation.load`.
[[noreturn]] inline void unsupportedNatively(const char* elmFunction) {
    eco_output_text(elmFunction);
    eco_output_text(" is not supported natively\n");
    eco_terminate_process(1);
}

} // namespace Elm::Kernel

#endif // ELM_KERNEL_NOT_SUPPORTED_NATIVELY_HPP
