module Compiler.LocalOpt.Typed.ShaderCoverageTest exposing (suite)

{-| Runs a program with GLSL shaders through the typed optimizer, so that the
optimizer's handling of a shader expression runs under test: lowering it
(`Compiler.LocalOpt.Typed.Expression`), searching past it for a local's solver
variable, and renaming a `case` branch that holds one when
`Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries` merges the branch lambdas.

The program is the source text of a module named `Test`, parsed as an
application module. `pick n` is a `case` on `n` whose two branches are lambdas
over an `Int`; the first branch's body is a `let` that defines a constant and
returns a shader paired with it, so that the search for the constant's solver
variable passes the shader first, and the second returns another shader paired
with its parameter. `testValue` takes the second element of `pick 0 1`.
Default imports of modules that `Compiler.Elm.Interface.Basic.testIfaces`
lacks are dropped. The test passes when
`TestLogic.TestPipeline.runToTypedOpt` succeeds on the program.

Among what is not tested: monomorphizing or generating code for a shader,
which the native back end does not support.

-}

import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The one test, under a label that contains "coverage run" so that the
coverage loop's quick run includes it.
-}
suite : Test
suite =
    Test.describe "Shaders in the typed optimizer (coverage run)"
        [ Test.test "optimizes" <|
            \_ ->
                case Parse.fromByteString Parse.Application source of
                    Ok (Src.Module m) ->
                        case Pipeline.runToTypedOpt (Src.Module { m | imports = List.filter isMockImport m.imports }) of
                            Ok _ ->
                                Expect.pass

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


pick n =
    case n of
        0 ->
            \\p ->
                let
                    k =
                        p + 1
                in
                ( [glsl| attribute vec3 position; void main () { gl_Position = vec4(position, 1.0); } |], k )

        _ ->
            \\q ->
                ( [glsl| attribute vec3 position; void main () { gl_Position = vec4(position, 1.0); } |], q )


testValue =
    Tuple.second (pick 0 1)
"""
