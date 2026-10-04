module TestLogic.Canonicalize.DuplicateDeclsTest exposing (suite)

{-| Elm forbids a module to declare two values, two types, or two constructors of
one name, and forbids a local binding to reuse a name that an enclosing scope of
the same module already binds (an imported name may be reused). Canonicalization
enforces both rules. These tests check that it reports a repeated value, type or
constructor name and a rebound function argument, and that it reports none of
these for two modules that have none.

Each test builds a small source module with `Compiler.AST.SourceBuilder`, through
one of the builders below, and hands it to an expectation from
`TestLogic.Canonicalize.DuplicateDecls`, which canonicalizes it and looks only at
the errors. An expectation that asks for an error passes when at least one reported
error is of that kind and names the given name, whatever else is reported beside
it. Value and shadowing modules import only `Basics` and `List`; the type and
constructor modules declare no values.

In the shadowing modules the outer binding is always an argument of a top-level
function `test`, and the inner binding reuses its name.

The tests establish:

  - DuplicateDecl errors: a top-level value declared twice is reported as a
    `DuplicateDecl` for its name, both when the two bodies are the same integer
    literal and when they differ.
  - DuplicateType errors: a `DuplicateType` for the name is reported for two
    type aliases of one name, for two custom types of one name whose
    constructors differ, and for an alias and a custom type sharing a name.
  - DuplicateCtor errors: a `DuplicateCtor` for the name is reported for two
    constructors of one name in the same custom type (one taking an `Int`, one
    taking nothing), and for one constructor name used in two custom types.
  - Shadowing errors: a `Shadowing` error for the argument's name is reported
    when a `let` definition, a lambda argument, or a `case` branch's variable
    pattern rebinds the argument.
  - Valid modules without duplicates: no duplicate-related error (one of the
    duplicate kinds, or `Shadowing`) is reported for three distinct top-level
    values, nor for two top-level values that each bind a local `x` in a `let`.
    The expectation also passes when canonicalization fails with errors of
    other kinds, so these tests do not show that the modules canonicalize.

Among what is not tested: duplicate operators, record fields, type parameters,
pattern variables and exports; a constructor clashing with a record alias's
constructor; a local binding that shadows a top-level value rather than an
argument; and the regions an error carries.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Test exposing (Test)
import TestLogic.Canonicalize.DuplicateDecls
    exposing
        ( expectDuplicateCtorError
        , expectDuplicateDeclError
        , expectDuplicateTypeError
        , expectNoDuplicateErrors
        , expectShadowingError
        )


{-| The whole suite: the duplicate value, duplicate type, duplicate constructor,
shadowing and valid-module groups.
-}
suite : Test
suite =
    Test.describe "No duplicate top-level declarations (CANON_003)"
        [ duplicateDeclTests
        , duplicateTypeTests
        , duplicateCtorTests
        , shadowingTests
        , validModuleTests
        ]


{-| The tests that a top-level value declared twice is reported as a
`DuplicateDecl`.
-}
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


{-| The tests that two type declarations of one name, aliases or custom types in
any pairing, are reported as a `DuplicateType`.
-}
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


{-| The tests that two constructors of one name, in one custom type or in two, are
reported as a `DuplicateCtor`.
-}
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


{-| The tests that rebinding a function argument's name in a `let`, a lambda or a
`case` pattern is reported as `Shadowing`.
-}
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


{-| The tests that no duplicate-related error is reported for modules whose names
are all distinct within each scope.
-}
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


{-| Builds a module `DupValue` that declares the top-level value `name` twice, both
times with no arguments and the integer literal 1 as its body.
-}
makeDuplicateValueModule : String -> Src.Module
makeDuplicateValueModule name =
    SB.makeModuleWithDefs "DupValue"
        [ ( name, [], SB.intExpr 1 )
        , ( name, [], SB.intExpr 1 )
        ]


{-| Builds a module `DupValueDiff` that declares the top-level value `name` twice,
once with the integer literal 1 as its body and once with 2.
-}
makeDuplicateValueModuleDifferentBodies : String -> Src.Module
makeDuplicateValueModuleDifferentBodies name =
    SB.makeModuleWithDefs "DupValueDiff"
        [ ( name, [], SB.intExpr 1 )
        , ( name, [], SB.intExpr 2 )
        ]


{-| Builds a module `DupAlias` that declares two type aliases named `name`, one for
`Int` and one for `String`.
-}
makeDuplicateAliasModule : String -> Src.Module
makeDuplicateAliasModule name =
    SB.makeModuleWithTypedDefsUnionsAliases "DupAlias"
        []
        []
        [ SB.AliasDef name [] (SB.tType "Int" [])
        , SB.AliasDef name [] (SB.tType "String" [])
        ]


{-| Builds a module `DupUnion` that declares two custom types named `name`, one with
the single constructor `A` and one with `B`, so only the type name repeats.
-}
makeDuplicateUnionModule : String -> Src.Module
makeDuplicateUnionModule name =
    SB.makeModuleWithTypedDefsUnionsAliases "DupUnion"
        []
        [ SB.UnionDef name [] [ SB.UnionCtor "A" [] ]
        , SB.UnionDef name [] [ SB.UnionCtor "B" [] ]
        ]
        []


{-| Builds a module `AliasUnionConflict` that declares a custom type named `name`,
with the single constructor `C`, and a type alias of the same name for `Int`.
-}
makeAliasUnionConflictModule : String -> Src.Module
makeAliasUnionConflictModule name =
    SB.makeModuleWithTypedDefsUnionsAliases "AliasUnionConflict"
        []
        [ SB.UnionDef name [] [ SB.UnionCtor "C" [] ] ]
        [ SB.AliasDef name [] (SB.tType "Int" []) ]


{-| Builds a module `DupCtorSame` with one custom type, `MyType`, whose two
constructors are both named `ctorName`: the first takes no argument and the
second takes an `Int`.
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


{-| Builds a module `DupCtorAcross` with two custom types, `Type1` and `Type2`, each
having a single constructor named `ctorName` that takes no argument.
-}
makeDuplicateCtorAcrossUnionsModule : String -> Src.Module
makeDuplicateCtorAcrossUnionsModule ctorName =
    SB.makeModuleWithTypedDefsUnionsAliases "DupCtorAcross"
        []
        [ SB.UnionDef "Type1" [] [ SB.UnionCtor ctorName [] ]
        , SB.UnionDef "Type2" [] [ SB.UnionCtor ctorName [] ]
        ]
        []


{-| Builds a module `ShadowLet` with one top-level function,
`test name = let name = 1 in name`, whose `let` rebinds the argument.
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


{-| Builds a module `ShadowLambda` with one top-level function,
`test name = \name -> name`, whose lambda rebinds the argument.
-}
makeShadowingLambdaModule : String -> Src.Module
makeShadowingLambdaModule name =
    SB.makeModuleWithDefs "ShadowLambda"
        [ ( "test"
          , [ SB.pVar name ]
          , SB.lambdaExpr [ SB.pVar name ] (SB.varExpr name)
          )
        ]


{-| Builds a module `ShadowCase` with one top-level function,
`test name = case 1 of name -> name`, whose `case` branch pattern rebinds the
argument.
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
