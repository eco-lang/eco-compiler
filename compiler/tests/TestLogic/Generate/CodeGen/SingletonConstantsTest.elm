module TestLogic.Generate.CodeGen.SingletonConstantsTest exposing (suite)

{-| Runs the singleton-constant check over the standard catalogue of test
programs, so that generated MLIR that builds a well-known value such as `True`,
`Nothing` or the empty string by construction rather than as an embedded
constant is caught on those programs.

The check is
`TestLogic.Generate.CodeGen.SingletonConstants.expectSingletonConstants`,
whose module docstring says what an embedded constant is and lists what it
reports. It compiles a program to MLIR and fails if compilation fails, or if
the MLIR holds an `eco.constant` whose `kind` is missing or not 0 (False),
1 (True) or 2 (the shared empty constant), an `eco.construct.custom` of size 0
(a nullary constructor built on the heap), or an `eco.string_literal` of the
empty string.

`suite` runs the check on the programs `SourceIR.Suite.StandardTestSuites`
gathers.

`userTrueFalseCtors` checks that the singleton treatment is not given by name
to a program's own constructors: `type Tri = True | False | Unknown` matched
by a `case` must dispatch exactly as the same program with the constructors
renamed `Yes | No | Unknown`, so the `tags` of every `eco.case` must be the
same in both. It guards `Compiler.Data.CtorTag.isEmbeddedConstantCtor` (used by
`Compiler.Generate.MLIR.Patterns.testToTagInt`, the emitters in
`Compiler.Generate.MLIR.Functions` and the spec maps in
`Compiler.Generate.MLIR.Backend`), which must recognise `True`, `False` and
`Nothing` by home module as well as name: matched by bare name, both user
constructors got the reserved constant tag and the case could not tell them
apart.

Among what is not tested:

  - programs of the `SourceIR` case modules the standard catalogue leaves
    out, such as `SourceIR.CaseSafepointLeakCases`;
  - whether an `eco.constant` has the right kind for its value: any of the
    three kinds passes;
  - a well-known value built by an op the check does not examine, as its
    module docstring lists.

-}

import Compiler.AST.Source as Src
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
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getArrayAttr)
import TestLogic.Generate.CodeGen.SingletonConstants exposing (expectSingletonConstants)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The singleton-constant check applied to the programs of the standard
catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_019: Singleton Constants"
        [ StandardTestSuites.expectSuite expectSingletonConstants "passes singleton constants invariant"
        , Test.test "a program's own True and False constructors dispatch like any others" userTrueFalseCtors
        ]


{-| Compiles `triModule [ "True", "False", "Unknown" ]` and
`triModule [ "Yes", "No", "Unknown" ]` and expects the `tags` of their
`eco.case` ops to be the same.
-}
userTrueFalseCtors : () -> Expectation
userTrueFalseCtors _ =
    case ( runToMlir (triModule [ "True", "False", "Unknown" ]), runToMlir (triModule [ "Yes", "No", "Unknown" ]) ) of
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
triModule : List String -> Src.Module
triModule names =
    let
        ( first, second, third ) =
            case names of
                [ a, b, c ] ->
                    ( a, b, c )

                _ ->
                    ( "A", "B", "C" )

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


intOf : MlirAttr -> Maybe Int
intOf attr =
    case attr of
        IntAttr _ n ->
            Just n

        _ ->
            Nothing
