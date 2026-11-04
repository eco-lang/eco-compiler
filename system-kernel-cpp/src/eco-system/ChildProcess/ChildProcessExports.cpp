//===- ChildProcessExports.cpp - C exports of Eco.Kernel.ChildProcess -----===//
//
// The C export of the `ChildProcess.run` kernel. It only turns its arguments into one payload and binds
// `childProcessRunBody` to it; the child is started each time the Task runs. The `ChildProcess` effect manager is
// registered by ChildProcessManager.cpp.
//
//===----------------------------------------------------------------------===//

#include "eco-system/ChildProcess/ChildProcess.hpp"

using namespace Eco::System;

extern "C" {

/// Returns a Task that, each time it runs, runs one child as `childProcessRunBody` describes, for the Elm kernel
///
///     run : String -> List String -> ( Int, String ) -> ( Bool, String )
///           -> ( Int, List ( String, String ) ) -> ( Int, Int )
///           -> Task ( Int, String, ( Int, Bytes, Bytes ) ) ( Bytes, Bytes )
///
/// A binding captures a single value, so the six arguments are packed as
/// `( ( program, args ), ( shell, cwd ), ( env, limits ) )`, where `limits` is `( maxBytes, runDurationMs )`. A C++
/// exception while building the Task is fatal, as `ECO_KERNEL_GUARD` makes it.
uint64_t Eco_Kernel_ChildProcess_run(uint64_t program, uint64_t args, uint64_t shell,
                                     uint64_t cwd, uint64_t env, uint64_t limits) {
    ECO_KERNEL_GUARD(
        HPointer programHP = dec(program);
        HPointer argsHP = dec(args);
        HPointer shellHP = dec(shell);
        HPointer cwdHP = dec(cwd);
        HPointer envHP = dec(env);
        HPointer limitsHP = dec(limits);
        HPointer a = alloc::listNil();
        HPointer b = alloc::listNil();
        HPointer c = alloc::listNil();
        Elm::StackRootGuard g({&programHP, &argsHP, &shellHP, &cwdHP, &envHP, &limitsHP,
                               &a, &b, &c});
        a = alloc::tuple2(alloc::boxed(programHP), alloc::boxed(argsHP), 0);
        b = alloc::tuple2(alloc::boxed(shellHP), alloc::boxed(cwdHP), 0);
        c = alloc::tuple2(alloc::boxed(envHP), alloc::boxed(limitsHP), 0);
        HPointer payload = alloc::tuple3(alloc::boxed(a), alloc::boxed(b), alloc::boxed(c), 0);
        return enc(makeAsyncBinding<childProcessRunBody>(payload));
    )
}

} // extern "C"
