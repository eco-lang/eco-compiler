module Compiler.IR.Runtime.CtorTagTest exposing (suite)

{-| Pins `Compiler.IR.Runtime.CtorTag.isEmbeddedConstantCtor`, which picks out
the constructors represented by a fixed constant word: elm/core's
`Maybe.Nothing`, `Basics.True` and `Basics.False`. It must go by the home
module as well as the name; matched by bare name, a program's own `True` and
`False` both got the reserved constant tag, and a `case` on their type could
not tell them apart. `isEmbeddedConstantCtor` is used by
`Compiler.GenerateMlir.Patterns.testToTagInt`, the emitters in
`Compiler.GenerateMlir.Functions` and the spec maps in
`Compiler.GenerateMlir.Backend`.

What the tests establish:

  - `isEmbeddedConstantCtor` holds for `Nothing` in `Maybe` and for `True` and
    `False` in `Basics`;
  - it does not hold for those names in a user module, for `Nothing` in
    `Basics` or `True` in `Maybe`, or for `Just` in `Maybe`;
  - end to end, a program declaring `type Tri = True | False | Unknown` and
    matching it with a `case` compiles (`TestLogic.TestPipeline.runToMlir`) to
    `eco.case` ops with the same `tags` as the same program with the
    constructors renamed `Yes | No | Unknown`. The `True`/`False` program is
    also a catalogue case of `SourceIR.CaseCases`.

Among what is not tested: `embedsAsNullCons`, `effective` and the other
functions of the module.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Runtime.CtorTag as CtorTag
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule)
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getArrayAttr)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The tests of the module docstring.
-}
suite : Test
suite =
    Test.describe "CtorTag.isEmbeddedConstantCtor"
        [ Test.test "elm/core's Nothing, True and False are embedded constants" <|
            \_ ->
                [ CtorTag.isEmbeddedConstantCtor ModuleName.maybe "Nothing"
                , CtorTag.isEmbeddedConstantCtor ModuleName.basics "True"
                , CtorTag.isEmbeddedConstantCtor ModuleName.basics "False"
                ]
                    |> Expect.equal [ True, True, True ]
        , Test.test "the same names elsewhere, and other constructors, are not" <|
            \_ ->
                [ CtorTag.isEmbeddedConstantCtor userModule "Nothing"
                , CtorTag.isEmbeddedConstantCtor userModule "True"
                , CtorTag.isEmbeddedConstantCtor userModule "False"
                , CtorTag.isEmbeddedConstantCtor ModuleName.basics "Nothing"
                , CtorTag.isEmbeddedConstantCtor ModuleName.maybe "True"
                , CtorTag.isEmbeddedConstantCtor ModuleName.maybe "Just"
                ]
                    |> Expect.equal [ False, False, False, False, False, False ]
        , Test.test "a program's own True and False constructors dispatch like any others" userTrueFalseCtors
        ]


{-| A user module, `TestMod` of the package `author/project`.
-}
userModule : ModuleName.Canonical
userModule =
    ModuleName.Canonical ( "author", "project" ) "TestMod"


{-| Compiles `triModule [ "True", "False", "Unknown" ]` and
`triModule [ "Yes", "No", "Unknown" ]` and expects the `tags` of their
`eco.case` ops to be the same.
-}
userTrueFalseCtors : () -> Expectation
userTrueFalseCtors _ =
    case ( runToMlir (triModule "True" "False" "Unknown"), runToMlir (triModule "Yes" "No" "Unknown") ) of
        ( Ok user, Ok renamed ) ->
            Expect.equal (caseTags renamed.mlirModule) (caseTags user.mlirModule)
                |> Expect.onFail "eco.case tags for a type with its own True/False constructors differ from the same type with renamed constructors"

        ( Err err, _ ) ->
            Expect.fail ("Compilation failed: " ++ err)

        ( _, Err err ) ->
            Expect.fail ("Compilation failed: " ++ err)


{-| A module declaring `type Tri` with the three nullary constructors named,
`pick : Tri -> Int` returning 1, 2 or 3 by constructor, and
`testValue = pick <second> + pick <third>`.
-}
triModule : String -> String -> String -> Src.Module
triModule first second third =
    let
        tri : UnionDef
        tri =
            { name = "Tri", args = [], ctors = List.map (\n -> { name = n, args = [] }) [ first, second, third ] }

        pick : TypedDef
        pick =
            { name = "pick"
            , args = [ pVar "t" ]
            , tipe = tLambda (tType "Tri" []) (tType "Int" [])
            , body =
                caseExpr (varExpr "t")
                    [ ( pCtor first [], intExpr 1 )
                    , ( pCtor second [], intExpr 2 )
                    , ( pCtor third [], intExpr 3 )
                    ]
            }

        mainDef : TypedDef
        mainDef =
            { name = "testValue"
            , args = []
            , tipe = tType "Int" []
            , body =
                binopsExpr [ ( callExpr (varExpr "pick") [ ctorExpr second ], "+" ) ]
                    (callExpr (varExpr "pick") [ ctorExpr third ])
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod" [ pick, mainDef ] [ tri ] []


{-| The `tags` of every `eco.case` in the module, in the order `findOpsNamed`
returns them.
-}
caseTags : MlirModule -> List (List Int)
caseTags mlirModule =
    findOpsNamed "eco.case" mlirModule
        |> List.map (\op -> getArrayAttr "tags" op |> Maybe.withDefault [] |> List.filterMap intOf)


{-| The integer of an `IntAttr`, or `Nothing` for any other attribute.
-}
intOf : MlirAttr -> Maybe Int
intOf attr =
    case attr of
        IntAttr _ n ->
            Just n

        _ ->
            Nothing
