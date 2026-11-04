module Compiler.MonoOpt.Borrow.BorrowTailCallEscapeTest exposing (suite)

{-| Pins, for the program of `SourceIR.BorrowTailCallCases`, that borrow
inference finds a `MonoTailFunc` with heap tail-call arguments and that some
resource of it does die before the end of its body, so that the check that no
tail-call argument resource does
(`TestLogic.MonoOpt.BorrowTailCallEscapeTest`, over the whole standard
catalogue) is not passing because `Lifetime.endsBefore` answers `False` for
every live resource.

The program, a tail-recursive `loop` with a `List Int` accumulator, is
compiled with `TestLogic.TestPipeline.runToGlobalOpt` and its `MonoTailFunc`s
analysed with `TestLogic.MonoOpt.BorrowTailCallEscape.tailFuncAnalyses`. Of
those whose tail-call argument resources are not empty, the one with the
highest `SpecId` is taken; the test fails if there is none. For that one it
expects both that every tail-call argument resource has an `ltA` other than
`LEmpty` that `endsBefore` does not report dead at the end of the body, and
that some resource of the definition has an `ltA` other than `LEmpty` that
`endsBefore` reports dead there. The let-bound list `xs` in the program is that
resource: the `case` reads it inside the `else` arm, so its lifetime ends
there.

Among what is not tested: which local resource satisfies the second check.

-}

import Compiler.IR.Source as Src
import Compiler.MonoOpt.Borrow.Lifetime as L exposing (Lifetime(..))
import Compiler.MonoOpt.Borrow.Solve as Solve
import Expect
import SourceIR.BorrowTailCallCases as BorrowTailCallCases
import Test exposing (Test)
import TestLogic.MonoOpt.BorrowTailCallEscape as BorrowTailCallEscape
import TestLogic.TestPipeline as Pipeline


{-| The one test: `expectNegativeControl` over the program of
`SourceIR.BorrowTailCallCases`.
-}
suite : Test
suite =
    Test.describe "MonoTailCall escape check has a negative control"
        [ BorrowTailCallCases.expectSuite expectNegativeControl "have a tail-call argument and a resource that dies"
        ]


{-| The expectation the module docstring describes.
-}
expectNegativeControl : Src.Module -> Expect.Expectation
expectNegativeControl srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail ("pipeline: " ++ msg)

        Ok { optimizedMonoGraph } ->
            case List.filter (\a -> not (List.isEmpty a.tailArgRes)) (BorrowTailCallEscape.tailFuncAnalyses optimizedMonoGraph) of
                [] ->
                    Expect.fail "no MonoTailFunc with escape-seeded tail-call args was found (expected `loop`)"

                analysis :: _ ->
                    let
                        live r =
                            ltaNonEmpty (Solve.ltAOf r analysis.solved)
                                && not (L.endsBefore (Solve.ltAOf r analysis.solved) [])

                        dies r =
                            ltaNonEmpty (Solve.ltAOf r analysis.solved)
                                && L.endsBefore (Solve.ltAOf r analysis.solved) []
                    in
                    Expect.equal ( True, True )
                        ( List.all live analysis.tailArgRes
                        , List.any dies (List.range 0 (analysis.resourceCount - 1))
                        )


{-| Returns whether `lt` is anything other than `LEmpty`, the lifetime of a
resource that is never live.
-}
ltaNonEmpty : Lifetime -> Bool
ltaNonEmpty lt =
    case lt of
        LEmpty ->
            False

        _ ->
            True
