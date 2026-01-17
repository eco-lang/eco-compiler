module Compiler.Canonicalize.DuplicateDeclsTest exposing (suite)

{-| Test suite for invariant CANON\_003: No duplicate top-level declarations.

This module tests that canonicalization properly rejects modules with
duplicate declarations of various kinds.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.Canonicalize.DuplicateDecls
    exposing
        ( expectDuplicateCtorError
        , expectDuplicateDeclError
        , expectDuplicateTypeError
        , expectNoDuplicateErrors
        , expectShadowingError
        )
import Test exposing (Test)


suite : Test
suite =
    Test.describe "No duplicate top-level declarations (CANON_003)"
        [ duplicateDeclTests
        , duplicateTypeTests
        , duplicateCtorTests
        , shadowingTests
        , validModuleTests
        ]


duplicateDeclTests : Test
duplicateDeclTests =
    Test.describe "DuplicateDecl errors"
        [ Test.test "duplicate value declaration" <|
            \_ ->
                let
                    modul =
                        makeDuplicateValueModule "foo"
                in
                expectDuplicateDeclError "foo" modul
        , Test.test "duplicate value declaration with different bodies" <|
            \_ ->
                let
                    modul =
                        makeDuplicateValueModuleDifferentBodies "bar"
                in
                expectDuplicateDeclError "bar" modul
        ]


duplicateTypeTests : Test
duplicateTypeTests =
    Test.describe "DuplicateType errors"
        [ Test.test "duplicate type alias" <|
            \_ ->
                let
                    modul =
                        makeDuplicateAliasModule "MyAlias"
                in
                expectDuplicateTypeError "MyAlias" modul
        , Test.test "duplicate union type" <|
            \_ ->
                let
                    modul =
                        makeDuplicateUnionModule "MyUnion"
                in
                expectDuplicateTypeError "MyUnion" modul
        , Test.test "alias and union with same name" <|
            \_ ->
                let
                    modul =
                        makeAliasUnionConflictModule "Conflict"
                in
                expectDuplicateTypeError "Conflict" modul
        ]


duplicateCtorTests : Test
duplicateCtorTests =
    Test.describe "DuplicateCtor errors"
        [ Test.test "duplicate constructor in same union" <|
            \_ ->
                let
                    modul =
                        makeDuplicateCtorSameUnionModule "Dup"
                in
                expectDuplicateCtorError "Dup" modul
        , Test.test "duplicate constructor across unions" <|
            \_ ->
                let
                    modul =
                        makeDuplicateCtorAcrossUnionsModule "Shared"
                in
                expectDuplicateCtorError "Shared" modul
        ]


shadowingTests : Test
shadowingTests =
    Test.describe "Shadowing errors"
        [ Test.test "shadowing in let binding" <|
            \_ ->
                let
                    modul =
                        makeShadowingLetModule "x"
                in
                expectShadowingError "x" modul
        , Test.test "shadowing in lambda" <|
            \_ ->
                let
                    modul =
                        makeShadowingLambdaModule "y"
                in
                expectShadowingError "y" modul
        , Test.test "shadowing in case pattern" <|
            \_ ->
                let
                    modul =
                        makeShadowingCaseModule "z"
                in
                expectShadowingError "z" modul
        ]


validModuleTests : Test
validModuleTests =
    Test.describe "Valid modules without duplicates"
        [ Test.test "distinct declarations" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "Valid"
                            [ ( "foo", [], SB.intExpr 1 )
                            , ( "bar", [], SB.intExpr 2 )
                            , ( "baz", [], SB.intExpr 3 )
                            ]
                in
                expectNoDuplicateErrors modul
        , Test.test "same name in different scopes is OK" <|
            \_ ->
                let
                    modul =
                        SB.makeModuleWithDefs "ScopedNames"
                            [ ( "foo"
                              , []
                              , SB.letExpr
                                    [ SB.define "x" [] (SB.intExpr 1) ]
                                    (SB.varExpr "x")
                              )
                            , ( "bar"
                              , []
                              , SB.letExpr
                                    [ SB.define "x" [] (SB.intExpr 2) ]
                                    (SB.varExpr "x")
                              )
                            ]
                in
                expectNoDuplicateErrors modul
        ]



-- ============================================================================
-- TEST MODULE BUILDERS
-- ============================================================================


{-| Create a module with duplicate value declarations.
-}
makeDuplicateValueModule : String -> Src.Module
makeDuplicateValueModule name =
    SB.makeModuleWithDefs "DupValue"
        [ ( name, [], SB.intExpr 1 )
        , ( name, [], SB.intExpr 1 )
        ]


{-| Create a module with duplicate value declarations with different bodies.
-}
makeDuplicateValueModuleDifferentBodies : String -> Src.Module
makeDuplicateValueModuleDifferentBodies name =
    SB.makeModuleWithDefs "DupValueDiff"
        [ ( name, [], SB.intExpr 1 )
        , ( name, [], SB.intExpr 2 )
        ]


{-| Create a module with duplicate type alias declarations.
-}
makeDuplicateAliasModule : String -> Src.Module
makeDuplicateAliasModule name =
    SB.makeModuleWithTypedDefsUnionsAliases "DupAlias"
        []
        []
        [ SB.AliasDef name [] (SB.tType "Int" [])
        , SB.AliasDef name [] (SB.tType "String" [])
        ]


{-| Create a module with duplicate union type declarations.
-}
makeDuplicateUnionModule : String -> Src.Module
makeDuplicateUnionModule name =
    SB.makeModuleWithTypedDefsUnionsAliases "DupUnion"
        []
        [ SB.UnionDef name [] [ SB.UnionCtor "A" [] ]
        , SB.UnionDef name [] [ SB.UnionCtor "B" [] ]
        ]
        []


{-| Create a module with an alias and union with the same name.
-}
makeAliasUnionConflictModule : String -> Src.Module
makeAliasUnionConflictModule name =
    SB.makeModuleWithTypedDefsUnionsAliases "AliasUnionConflict"
        []
        [ SB.UnionDef name [] [ SB.UnionCtor "C" [] ] ]
        [ SB.AliasDef name [] (SB.tType "Int" []) ]


{-| Create a module with duplicate constructor in the same union.
-}
makeDuplicateCtorSameUnionModule : String -> Src.Module
makeDuplicateCtorSameUnionModule ctorName =
    SB.makeModuleWithTypedDefsUnionsAliases "DupCtorSame"
        []
        [ SB.UnionDef "MyType"
            []
            [ SB.UnionCtor ctorName []
            , SB.UnionCtor ctorName [ SB.tType "Int" [] ]
            ]
        ]
        []


{-| Create a module with duplicate constructor across different unions.
-}
makeDuplicateCtorAcrossUnionsModule : String -> Src.Module
makeDuplicateCtorAcrossUnionsModule ctorName =
    SB.makeModuleWithTypedDefsUnionsAliases "DupCtorAcross"
        []
        [ SB.UnionDef "Type1" [] [ SB.UnionCtor ctorName [] ]
        , SB.UnionDef "Type2" [] [ SB.UnionCtor ctorName [] ]
        ]
        []


{-| Create a module with shadowing in a let binding.
-}
makeShadowingLetModule : String -> Src.Module
makeShadowingLetModule name =
    SB.makeModuleWithDefs "ShadowLet"
        [ ( "test"
          , [ SB.pVar name ]
          , SB.letExpr
                [ SB.define name [] (SB.intExpr 1) ]
                (SB.varExpr name)
          )
        ]


{-| Create a module with shadowing in a lambda.
-}
makeShadowingLambdaModule : String -> Src.Module
makeShadowingLambdaModule name =
    SB.makeModuleWithDefs "ShadowLambda"
        [ ( "test"
          , [ SB.pVar name ]
          , SB.lambdaExpr [ SB.pVar name ] (SB.varExpr name)
          )
        ]


{-| Create a module with shadowing in a case pattern.
-}
makeShadowingCaseModule : String -> Src.Module
makeShadowingCaseModule name =
    SB.makeModuleWithDefs "ShadowCase"
        [ ( "test"
          , [ SB.pVar name ]
          , SB.caseExpr
                (SB.intExpr 1)
                [ ( SB.pVar name, SB.varExpr name ) ]
          )
        ]
