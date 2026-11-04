module Compiler.PreMono.ShaderTest exposing (suite)

{-| Runs a program holding a GLSL shader through the pre-monomorphization
passes, so that their handling of a shader expression runs under test:
`Compiler.PreMono.AssignMVarIds` giving the shader's type its ids, and
`Compiler.PreMono.Fresh.mintNewNode` minting a body that holds one.

The program is the source text of a module named `Test`, parsed as an
application module, with the default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks dropped. `withShader`,
annotated `Int -> Fn` with `Fn` an alias of `Int -> Int` and written with one
parameter, is a `let` around a local function whose body binds a shader, so
η-expansion rewrites it and mints the shader node.

The test passes when `TestLogic.TestPipeline.runToAssigned` succeeds on the
program and `Compiler.Pipeline.Steps.preMono` runs on the result under the
production configuration and η-expands at least one definition. The regression
test for finding F9, that monomorphization rejects the shader, which the
native back end does not support, with an error rather than aborting the
process, is now the shader case of `SourceIR.MonoFailsCases`, checked by
`TestLogic.Reporting.ExpectedRejectionTest`; this test stays here until shader
programs are in the standard catalogue. The group label contains `coverage
run`, so that the coverage loop's quick runs count the test.

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


{-| The group "coverage run: pre-mono shader", with its test.
-}
suite : Test
suite =
    Test.describe "coverage run: pre-mono shader"
        [ Test.test "assigns ids and η-expands around a shader" <|
            \_ ->
                case Parse.fromByteString Parse.Application source of
                    Ok (Src.Module m) ->
                        case Pipeline.runToAssigned (Src.Module { m | imports = List.filter isMockImport m.imports }) of
                            Ok assigned ->
                                let
                                    pre =
                                        Steps.preMono Pipeline.productionConfig assigned
                                in
                                Expect.atLeast 1 pre.etaExpand.defs

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


type alias Fn =
    Int -> Int


withShader : Int -> Fn
withShader n =
    let
        h z =
            let
                s =
                    [glsl| attribute vec3 position; void main () { gl_Position = vec4(position, 1.0); } |]
            in
            z + n
    in
    h


testValue =
    withShader 1 2
"""
