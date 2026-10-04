module TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistencyTest exposing (suite)

{-| Runs the list head layout check on every program in the standard catalogue,
so that a compiler change which hands a list between code expecting its
elements boxed and code expecting them unboxed fails a test, wherever that
check can see it, on many programs rather than on a hand-picked few.

A list element is _unboxed_ when it is held as a raw machine value rather than
as a pointer to a heap object. The check, and the two ways it looks for a
mismatch in the monomorphized graph, are described in
`TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency`.

The fixture is the catalogue of source programs that
`SourceIR.Suite.StandardTestSuites` gathers from its case modules.

`suite` establishes, for each program in the catalogue, that it compiles to
MLIR and that `expectProjectionHeapLayoutConsistency` finds no problem in its
monomorphized graph: no call to a global that the checker examines passes a
list whose elements are unboxed where the callee's parameter expects them boxed,
or the reverse, and no name has specializations whose list element types
include both an unboxed one and an erased type variable.

Among what is not tested: any MLIR op, including `eco.project.list_head`
itself; the calls and list positions the checker's docstring lists as
unchecked; and programs outside the catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency exposing (expectProjectionHeapLayoutConsistency)


{-| A test group that checks every program in the standard catalogue with
`expectProjectionHeapLayoutConsistency`.
-}
suite : Test
suite =
    Test.describe "REP_BOUNDARY_003: Projection heap layout consistency"
        [ StandardTestSuites.expectSuite expectProjectionHeapLayoutConsistency "passes projection heap layout consistency"
        ]
