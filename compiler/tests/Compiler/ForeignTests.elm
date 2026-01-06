module Compiler.ForeignTests exposing (expectSuite)

{-| Tests for VarForeign expressions.

VarForeign expressions represent references to functions from other modules
with type annotations. These test the interaction between foreign function
constraints and the extra CEqual constraints in the WithIds path.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.CanonicalBuilder
    exposing
        ( callExpr
        , funType
        , intExpr
        , makeAnnotation
        , makeModule
        , makeModuleWithDecls
        , makeTypedDef
        , pVar
        , varForeignExpr
        , varLocalExpr
        , varType
        )
import Compiler.Elm.Package as Pkg
import Expect exposing (Expectation)
import System.TypeCheck.IO as IO
import Test exposing (Test)


expectSuite : (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe "VarForeign expressions"
        [ simpleForeignTests expectFn condStr
        , foreignCallTests expectFn condStr
        , polymorphicForeignTests expectFn condStr
        ]



-- ============================================================================
-- SIMPLE FOREIGN EXPRESSIONS
-- ============================================================================


simpleForeignTests : (Can.Module -> Expectation) -> String -> Test
simpleForeignTests expectFn condStr =
    Test.describe "Simple foreign expressions"
        [ Test.test ("VarForeign identity " ++ condStr) (varForeignIdentity expectFn)
        , Test.test ("VarForeign const " ++ condStr) (varForeignConst expectFn)
        ]


{-| identity : a -> a
-}
varForeignIdentity : (Can.Module -> Expectation) -> (() -> Expectation)
varForeignIdentity expectFn _ =
    let
        -- identity : a -> a
        annotation =
            makeAnnotation [ "a" ] (funType (varType "a") (varType "a"))

        home =
            IO.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (varForeignExpr 1 home "identity" annotation)
    in
    expectFn modul


{-| const : a -> b -> a
-}
varForeignConst : (Can.Module -> Expectation) -> (() -> Expectation)
varForeignConst expectFn _ =
    let
        -- const : a -> b -> a
        annotation =
            makeAnnotation [ "a", "b" ]
                (funType (varType "a") (funType (varType "b") (varType "a")))

        home =
            IO.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (varForeignExpr 1 home "always" annotation)
    in
    expectFn modul



-- ============================================================================
-- FOREIGN CALL TESTS
-- ============================================================================


foreignCallTests : (Can.Module -> Expectation) -> String -> Test
foreignCallTests expectFn condStr =
    Test.describe "Foreign call expressions"
        [ Test.test ("Call identity on int " ++ condStr) (callIdentityOnInt expectFn)
        , Test.test ("Call const on int and int " ++ condStr) (callConstOnIntAndInt expectFn)
        ]


{-| identity 42
-}
callIdentityOnInt : (Can.Module -> Expectation) -> (() -> Expectation)
callIdentityOnInt expectFn _ =
    let
        -- identity : a -> a
        annotation =
            makeAnnotation [ "a" ] (funType (varType "a") (varType "a"))

        home =
            IO.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (callExpr 1
                    (varForeignExpr 2 home "identity" annotation)
                    [ intExpr 3 42 ]
                )
    in
    expectFn modul


{-| always 1 2
-}
callConstOnIntAndInt : (Can.Module -> Expectation) -> (() -> Expectation)
callConstOnIntAndInt expectFn _ =
    let
        -- always : a -> b -> a
        annotation =
            makeAnnotation [ "a", "b" ]
                (funType (varType "a") (funType (varType "b") (varType "a")))

        home =
            IO.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (callExpr 1
                    (varForeignExpr 2 home "always" annotation)
                    [ intExpr 3 1, intExpr 4 2 ]
                )
    in
    expectFn modul



-- ============================================================================
-- POLYMORPHIC FOREIGN TESTS
-- ============================================================================


polymorphicForeignTests : (Can.Module -> Expectation) -> String -> Test
polymorphicForeignTests expectFn condStr =
    Test.describe "Polymorphic foreign expressions"
        [ Test.test ("Typed def using foreign identity " ++ condStr) (typedDefUsingForeignIdentity expectFn)
        , Test.test ("Nested foreign calls " ++ condStr) (nestedForeignCalls expectFn)
        ]


{-| apply : (a -> b) -> a -> b
apply f x = identity (f x)

This tests the interaction between typed definitions and foreign function calls.

-}
typedDefUsingForeignIdentity : (Can.Module -> Expectation) -> (() -> Expectation)
typedDefUsingForeignIdentity expectFn _ =
    let
        -- identity : c -> c  (using 'c' to avoid confusion with 'a' and 'b' from apply)
        identityAnnotation =
            makeAnnotation [ "c" ] (funType (varType "c") (varType "c"))

        home =
            IO.Canonical Pkg.core "Basics"

        -- apply f x = identity (f x)
        applyDef =
            makeTypedDef "apply"
                [ ( pVar 1 "f", funType (varType "a") (varType "b") )
                , ( pVar 2 "x", varType "a" )
                ]
                (callExpr 3
                    (varForeignExpr 4 home "identity" identityAnnotation)
                    [ callExpr 5
                        (varLocalExpr 6 "f")
                        [ varLocalExpr 7 "x" ]
                    ]
                )
                (varType "b")

        decls =
            Can.Declare applyDef Can.SaveTheEnvironment

        modul =
            makeModuleWithDecls decls
    in
    expectFn modul


{-| identity (identity 42)

Nested foreign function calls.

-}
nestedForeignCalls : (Can.Module -> Expectation) -> (() -> Expectation)
nestedForeignCalls expectFn _ =
    let
        -- identity : a -> a
        annotation =
            makeAnnotation [ "a" ] (funType (varType "a") (varType "a"))

        home =
            IO.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (callExpr 1
                    (varForeignExpr 2 home "identity" annotation)
                    [ callExpr 3
                        (varForeignExpr 4 home "identity" annotation)
                        [ intExpr 5 42 ]
                    ]
                )
    in
    expectFn modul
