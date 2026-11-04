module Compiler.LocalOpt.Typed.LocalOptPathsCoverageTest exposing (suite)

{-| Compiles programs built to reach paths of the typed optimizer and of
PostSolve that the standard catalogue does not: a recursive `let` group one
of whose members also calls itself, a top-level value without parameters or
annotation that refers to itself under a lambda, and a kernel function first
used bare as an operand of `|>`.

Each program is the source text of a module named `Test`, parsed as an
application module, with the default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks dropped.

  - "Self-call inside a recursive let group": `testValue` defines `f` and `g`
    in one `let`, each calling the other and `f` also calling itself, and
    returns `f 0`. It must pass `TestLogic.TestPipeline.expectCoverageRun`.
  - "Recursive value without an annotation": `count = \n -> ...` calls
    `count` again under its lambda, and `testValue = count 0`. It must pass
    `expectCoverageRun`.
  - "Kernels as constructor arguments of record and unit function types":
    `type K = K ({ x : Int } -> Int) (() -> Int)` is applied to two bare
    kernel references, so that PostSolve gives each kernel the constructor's
    argument type, a function of a record and a function of the unit type. The
    program must pass `TestLogic.TestPipeline.runToPostSolve`; the kernels are
    not real ones, so it is not compiled further.
  - "Kernel called after it was piped": `Elm.Kernel.Basics.add` is first
    used bare as the left operand of `|>`, and then called with two
    arguments. After `TestLogic.TestPipeline.runToPostSolve` its entry in the
    kernel type environment must be the operand's own type, a function of two
    parameters returning `Int` (the parameters stay type variables: `a` comes
    from an unconstrained kernel call). PostSolve used to record the parameter type in `|>`'s annotation,
    the bare variable `a`, and a program with that entry could crash
    monomorphization (finding F1).

-}

import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Canonical as Can
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Compiler.Type.KernelTypes as KernelTypes
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The four tests, under a label that contains "coverage run" so that the
coverage loop's quick run includes them.
-}
suite : Test
suite =
    Test.describe "Typed optimizer and PostSolve paths (coverage run)"
        [ Test.test "Self-call inside a recursive let group" <|
            \_ -> withModule letGroupSource Pipeline.expectCoverageRun
        , Test.test "Recursive value without an annotation" <|
            \_ -> withModule recursiveValueSource Pipeline.expectCoverageRun
        , Test.test "Kernels as constructor arguments of record and unit function types" <|
            \_ ->
                withModule kernelCtorSource
                    (\m ->
                        case Pipeline.runToPostSolve m of
                            Ok _ ->
                                Expect.pass

                            Err message ->
                                Expect.fail message
                    )
        , Test.test "Kernel called after it was piped" <|
            \_ ->
                withModule pipedKernelSource
                    (\m ->
                        case Pipeline.runToPostSolve m of
                            Ok artifacts ->
                                case KernelTypes.lookup "Elm" "Basics" "add" artifacts.kernelEnv of
                                    Just (Can.TLambda _ _ (Can.TLambda _ _ (Can.TType _ "Int" []))) ->
                                        Expect.pass

                                    other ->
                                        Expect.fail ("Elm.Kernel.Basics.add recorded as " ++ Debug.toString other)

                            Err message ->
                                Expect.fail message
                    )
        ]


{-| Runs `expectFn` on the program parsed from `text`, or fails when it does
not parse.
-}
withModule : String -> (Src.Module -> Expectation) -> Expectation
withModule text expectFn =
    case Parse.fromByteString Parse.Application text of
        Ok (Src.Module m) ->
            expectFn (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Expect.fail "fixture failed to parse"


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The source of "Self-call inside a recursive let group".
-}
letGroupSource : String
letGroupSource =
    """module Test exposing (..)


testValue : Int
testValue =
    let
        f k =
            if k > 10 then
                g k

            else
                f (k + 1)

        g k =
            if k > 20 then
                k

            else
                f (k * 2)
    in
    f 0
"""


{-| The source of "Recursive value without an annotation".
-}
recursiveValueSource : String
recursiveValueSource =
    """module Test exposing (..)


count =
    \\n ->
        if n > 3 then
            n

        else
            count (n + 1)


testValue =
    count 0
"""


{-| The source of "Kernel called after it was piped".
-}
pipedKernelSource : String
pipedKernelSource =
    """module Test exposing (..)


testValue : Int
testValue =
    let
        a =
            Elm.Kernel.Basics.sub 5 3
    in
    (Elm.Kernel.Basics.add |> (\\f -> f a 2)) + Elm.Kernel.Basics.add 1 2
"""


{-| The source of "Kernels as constructor arguments of record and unit
function types".
-}
kernelCtorSource : String
kernelCtorSource =
    """module Test exposing (..)


type K
    = K ({ x : Int } -> Int) (() -> Int)


testValue : K
testValue =
    K Elm.Kernel.Coverage.fromRecord Elm.Kernel.Coverage.fromUnit
"""
