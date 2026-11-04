module Compiler.PreMono.EtaExpandStageCapTest exposing (suite)

{-| Runs a program whose function type is wider than the runtime's stage limit
through the pre-monomorphization passes, so that η-expansion's stage-arity
cap is reached at both of its rules.

`Big` is an alias of a function type of 2,049 arrows, more than
`Compiler.IR.Runtime.HeapLimits.maxStageArity` (2047). `wider`, annotated `Big`
and written with one parameter as a call of the tail-recursive `wide`, has a
deficit that would make a stage that wide, so the definition rule declines it;
the lambda passed to `useBig : Big -> Int` has the same deficit, so the
continuation rule declines it. No canonicalization limit applies, because no function is written with
more than one parameter.

The program is the source text of a module named `Test`, parsed as an
application module, with the default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks dropped. The test passes when
`TestLogic.TestPipeline.runToAssigned` succeeds and
`Compiler.Pipeline.Steps.preMono` reports two declines at the cap
(`declinedArityCap`). It is a single test rather than a catalogue program
because type checking a type that wide takes seconds, and the catalogue runs
every program in about a hundred suites. The group label contains
`coverage run`, so that the coverage loop's quick runs count it.

-}

import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Compiler.Pipeline.Steps as Steps
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The group "coverage run: pre-mono stage cap".
-}
suite : Test
suite =
    Test.describe "coverage run: pre-mono stage cap"
        [ Test.test "η-expansion declines a stage wider than the limit" <|
            \_ ->
                case Parse.fromByteString Parse.Application source of
                    Ok (Src.Module m) ->
                        case Pipeline.runToAssigned (Src.Module { m | imports = List.filter isMockImport m.imports }) of
                            Ok assigned ->
                                Expect.equal 2 (Steps.preMono Pipeline.productionConfig assigned).etaExpand.declinedArityCap

                            Err message ->
                                Expect.fail message

                    Err _ ->
                        Expect.fail "fixture failed to parse"
        ]


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The program's source text.
-}
source : String
source =
    """module Test exposing (..)


type alias Big =
    Int -> """ ++ String.repeat 2048 "Int -> " ++ """Int


wide : Big
wide x =
    wide x


wider : Big
wider x =
    wide x


useBig : Big -> Int
useBig _ =
    0


unused : Int
unused =
    useBig (\\x -> wide x)


testValue =
    1
"""
