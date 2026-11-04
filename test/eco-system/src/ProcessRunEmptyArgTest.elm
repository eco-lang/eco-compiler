module ProcessRunEmptyArgTest exposing (main)

{-| HEAP-01 (plans/kernel-lib-bug-fixes.md, group 10): `ChildProcess.run` with empty-string
arguments.

The literal `""` is the embedded empty-String constant (HEAP_014). `listToStringVector`
(eco-kernel-cpp/src/eco-kernel/KernelHelpers.hpp), which the run kernel uses for the arguments,
passes each element to `Allocator::resolve`, which must never see an embedded constant: an
assertion abort (asserts on) or a wild read. Fixed, the child gets empty arguments (plain POSIX
behaviour).

-}

-- CHECK: empty arg: ok stdout=[a][] stderr=
-- CHECK: only empty: ok stdout=1| stderr=
-- EXIT: 0

import ChildProcess as P
import ProcessTestHelp exposing (describeRun, noShell, simpleRun)


main =
    simpleRun
        [ ( "empty arg", describeRun (P.run "printf" [ "[%s][%s]", "a", "" ] noShell) )
        , ( "only empty", describeRun (P.run "sh" [ "-c", "echo $#", "sh", "" ] noShell) )
        ]
