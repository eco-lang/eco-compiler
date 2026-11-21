module Compiler.GenerateMlir.ArrayGetIntrinsicTest exposing (suite)

{-| Tests that a call of elm/core's `Elm.JsArray.unsafeGet` alias on a `JsArray Int`
is emitted as the inline `eco.array.get`, not as a call of the alias's shared
specialization and the boxing kernel (plans/constructor-representation-followups.md
F5b, `Expr.coreIntrinsicHome`).

The program reads element 1 of `JsArray.push 5 (JsArray.push 4 JsArray.empty)`. It is compiled
with the post-mono inliner off: with it on, the inliner inlines the alias into a
direct kernel call, which already reaches the intrinsic, so only the alias call
itself shows whether the alias's module is matched against the `JsArray`
intrinsics.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , callExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , qualVarExpr
        , tType
        )
import Compiler.Config as Config
import Expect
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    describe "Compiler.GenerateMlir: Elm.JsArray alias calls reach the JsArray intrinsics"
        [ test "JsArray.unsafeGet on a JsArray Int is an inline eco.array.get" <|
            \_ ->
                case Pipeline.runToMlirWith noPostMonoInline program of
                    Err msg ->
                        Expect.fail ("Compilation failed: " ++ msg)

                    Ok { mlirOutput } ->
                        Expect.all
                            [ \out -> String.contains "eco.array.get" out |> Expect.equal True
                            , \out -> String.contains "Elm_Kernel_JsArray_unsafeGet_Int" out |> Expect.equal False
                            ]
                            mlirOutput
        ]


noPostMonoInline : Config.EcoConfig
noPostMonoInline =
    let
        cfg =
            Pipeline.productionConfig

        inline =
            cfg.inline
    in
    { cfg | inline = { inline | postMono = False } }


{-| `testValue = JsArray.unsafeGet 1 (JsArray.push 5 (JsArray.push 4 JsArray.empty))`.
-}
program =
    let
        testValue : TypedDef
        testValue =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                callExpr (qualVarExpr "JsArray" "unsafeGet")
                    [ intExpr 1
                    , callExpr (qualVarExpr "JsArray" "push")
                        [ intExpr 5
                        , callExpr (qualVarExpr "JsArray" "push") [ intExpr 4, qualVarExpr "JsArray" "empty" ]
                        ]
                    ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod" [ testValue ] [] []
