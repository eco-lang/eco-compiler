module Compiler.LocalOpt.Typed.TailDefTypesTest exposing (suite)

{-| Pins that each program of `SourceIR.TailDefTypeCases` compiles to a typed
local graph holding a `TailDef` in a `Cycle` node, so that the rule those
programs were written for has a definition to check in each.

The rule, that a `TailDef`'s parameters and body have the types its stored
type and its annotation declare (TOPT\_004, TOPT\_005), is part of
`TestLogic.LocalOpt.TypePreservation` and runs over the whole standard
catalogue, these programs included, as
`TestLogic.LocalOpt.TypedOptimizedTypePreservationTest`.

Each program is compiled with `TestLogic.TestPipeline.runToTypedOpt`; the test
fails with the pipeline's message if that fails, and if no `Cycle` node of the
local graph holds a `TailDef`.

-}

import Compiler.IR.Source as Src
import Compiler.IR.Typed.Optimized as TOpt
import Data.Map
import Expect exposing (Expectation)
import SourceIR.TailDefTypeCases as TailDefTypeCases
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The one test: `expectTopLevelTailDef` over the programs of
`SourceIR.TailDefTypeCases`.
-}
suite : Test
suite =
    Test.describe "TailDef types match the annotation (TOPT_004, TOPT_005)"
        [ TailDefTypeCases.expectSuite expectTopLevelTailDef "have a top-level TailDef"
        ]


{-| Passes when `srcModule`'s typed local graph has a `Cycle` node holding a
`TailDef`.
-}
expectTopLevelTailDef : Src.Module -> Expectation
expectTopLevelTailDef srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { localGraph } ->
            let
                (TOpt.LocalGraph data) =
                    localGraph

                isTailDef def =
                    case def of
                        TOpt.TailDef _ _ _ _ _ _ ->
                            True

                        TOpt.Def _ _ _ _ ->
                            False

                hasTailDef node =
                    case node of
                        TOpt.Cycle _ _ defs _ ->
                            List.any isTailDef defs

                        _ ->
                            False
            in
            if List.any hasTailDef (Data.Map.values data.nodes) then
                Expect.pass

            else
                Expect.fail "no Cycle node of the typed local graph holds a TailDef"
