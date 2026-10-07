//===- ChildProcessExports.cpp - C exports of Eco.Kernel.ChildProcess -----===//
//
// plans/eco-system-library.md Appendix B.4. Exports only decode, root, pack
// and bind (G2); the body is in ChildProcess.cpp. The `System.Process`
// effect-manager registration is in ChildProcessManager.cpp.
//
// Templates used: T1 (export shape), T2 (async binding).
//
//===----------------------------------------------------------------------===//

#include "eco-system/ChildProcess/ChildProcess.hpp"

using namespace Eco::System;

extern "C" {

// run : String -> List String -> ( Int, String ) -> ( Bool, String )
//       -> ( Int, List ( String, String ) ) -> ( Int, Int )
//       -> Task ( Int, String, ( Int, Bytes, Bytes ) ) ( Bytes, Bytes )
//
// Six arguments: packed as nested tuples (G2),
//   tuple3( (program, args), (shell, cwd), (env, (maxBytes, runDurationMs)) ).
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
