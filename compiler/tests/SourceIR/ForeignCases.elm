module SourceIR.ForeignCases exposing (expectSuite)

{-| Supplies canonical modules that refer to values of another module, so that a
check working on the Canonical AST can be run on exactly these references and
ids without parsing or canonicalizing anything.

A `VarForeign` node in the Canonical AST is a reference to a value imported from
another module that is not a constructor, an operator or a `Debug` value. It
names the value's home module and carries the value's type annotation, and the
constraint generator types the reference from that annotation rather than by
looking the module up. Every foreign reference built here has `Basics` in
`elm/core` as its home and names `identity` or `always`, with an annotation
written out in this file.

The modules are built with `Compiler.AST.CanonicalBuilder`, whose module
docstring states what every module it builds shares. The ids are chosen by hand
for each case, and no two nodes in one module share an id.

This module asserts nothing itself. `expectSuite` passes each module to the
expectation function its caller supplies, so what is checked depends on the
caller. The cases, by label:

  - "VarForeign identity": `testValue` is a bare reference to `identity`,
    annotated `a -> a`.
  - "VarForeign const": `testValue` is a bare reference to `always`, annotated
    `a -> b -> a`. The label says `const`; the name referenced is `always`.
  - "Call identity on int": `testValue` is `identity 42`.
  - "Call const on int and int": `testValue` is `always 1 2`.
  - "Typed def using foreign identity": the module's one declaration is
    `apply : (a -> b) -> a -> b` with `apply f x = identity (f x)`, and
    `identity` is annotated `c -> c`. This module has no `testValue`.
  - "Nested foreign calls": `testValue` is `identity (identity 42)`, the two
    references carrying the same annotation.

Among what is not covered: a home module other than `Basics`, a foreign
reference inside a `let`, lambda or `case`, an annotation with a concrete or
super-constrained type, and a program that fails to type check. Nothing here
compares the annotations with the real `Basics`.

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
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Creates one test, titled "VarForeign expressions " followed by `condStr`,
that applies `expectFn` to each of the six modules in turn.

The cases run as `Compiler.BulkCheck.bulkCheck` describes: in order, stopping
at the first failure, which is reported under that case's label.

-}
expectSuite : (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("VarForeign expressions " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns all six cases, each applying `expectFn` to its module: the bare
references, then the calls, then the annotated definition and the nested call.
-}
testCases : (Can.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ simpleForeignCases expectFn
        , foreignCallCases expectFn
        , polymorphicForeignCases expectFn
        ]



-- ============================================================================
-- SIMPLE FOREIGN EXPRESSIONS
-- ============================================================================


{-| Returns the two cases whose `testValue` is a bare foreign reference, to
`identity` and to `always`.
-}
simpleForeignCases : (Can.Module -> Expectation) -> List TestCase
simpleForeignCases expectFn =
    [ { label = "VarForeign identity", run = varForeignIdentity expectFn }
    , { label = "VarForeign const", run = varForeignConst expectFn }
    ]


{-| Builds the case `testValue = identity`, where the reference to
`Basics.identity` (id 1) is annotated `a -> a`, and returns `expectFn`'s
expectation for it, deferred.
-}
varForeignIdentity : (Can.Module -> Expectation) -> (() -> Expectation)
varForeignIdentity expectFn _ =
    let
        annotation =
            makeAnnotation [ "a" ] (funType (varType "a") (varType "a"))

        home =
            ModuleName.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (varForeignExpr 1 home "identity" annotation)
    in
    expectFn modul


{-| Builds the case `testValue = always`, where the reference to
`Basics.always` (id 1) is annotated `a -> b -> a`, and returns `expectFn`'s
expectation for it, deferred.
-}
varForeignConst : (Can.Module -> Expectation) -> (() -> Expectation)
varForeignConst expectFn _ =
    let
        annotation =
            makeAnnotation [ "a", "b" ]
                (funType (varType "a") (funType (varType "b") (varType "a")))

        home =
            ModuleName.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (varForeignExpr 1 home "always" annotation)
    in
    expectFn modul



-- ============================================================================
-- FOREIGN CALL TESTS
-- ============================================================================


{-| Returns the two cases whose `testValue` calls a foreign function with
integer literals: `identity 42` and `always 1 2`.
-}
foreignCallCases : (Can.Module -> Expectation) -> List TestCase
foreignCallCases expectFn =
    [ { label = "Call identity on int", run = callIdentityOnInt expectFn }
    , { label = "Call const on int and int", run = callConstOnIntAndInt expectFn }
    ]


{-| Builds the case `testValue = identity 42`, with `identity` annotated
`a -> a`, and returns `expectFn`'s expectation for it, deferred. The call has
id 1, the reference id 2 and the literal id 3.
-}
callIdentityOnInt : (Can.Module -> Expectation) -> (() -> Expectation)
callIdentityOnInt expectFn _ =
    let
        annotation =
            makeAnnotation [ "a" ] (funType (varType "a") (varType "a"))

        home =
            ModuleName.Canonical Pkg.core "Basics"

        modul =
            makeModule "testValue"
                (callExpr 1
                    (varForeignExpr 2 home "identity" annotation)
                    [ intExpr 3 42 ]
                )
    in
    expectFn modul


{-| Builds the case `testValue = always 1 2`, one call with both arguments and
`always` annotated `a -> b -> a`, and returns `expectFn`'s expectation for it,
deferred. The call has id 1, the reference id 2 and the literals ids 3 and 4.
-}
callConstOnIntAndInt : (Can.Module -> Expectation) -> (() -> Expectation)
callConstOnIntAndInt expectFn _ =
    let
        annotation =
            makeAnnotation [ "a", "b" ]
                (funType (varType "a") (funType (varType "b") (varType "a")))

        home =
            ModuleName.Canonical Pkg.core "Basics"

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


{-| Returns two cases: `identity` called in the body of the annotated
definition `apply`, and the nested call `identity (identity 42)`.
-}
polymorphicForeignCases : (Can.Module -> Expectation) -> List TestCase
polymorphicForeignCases expectFn =
    [ { label = "Typed def using foreign identity", run = typedDefUsingForeignIdentity expectFn }
    , { label = "Nested foreign calls", run = nestedForeignCalls expectFn }
    ]


{-| Builds the case whose one declaration is the annotated definition

    apply : (a -> b) -> a -> b
    apply f x =
        identity (f x)

with `identity` annotated `c -> c`, and returns `expectFn`'s expectation for it,
deferred. The patterns `f` and `x` have ids 1 and 2; the outer call has id 3,
the reference to `identity` id 4, the call `f x` id 5, and `f` and `x` in it ids
6 and 7.

Unlike the other cases, this module defines no `testValue`.

-}
typedDefUsingForeignIdentity : (Can.Module -> Expectation) -> (() -> Expectation)
typedDefUsingForeignIdentity expectFn _ =
    let
        -- Named `c` only for the reader: the annotation quantifies its own variables.
        identityAnnotation =
            makeAnnotation [ "c" ] (funType (varType "c") (varType "c"))

        home =
            ModuleName.Canonical Pkg.core "Basics"

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


{-| Builds the case `testValue = identity (identity 42)`, both references to
`identity` carrying the same `a -> a` annotation, and returns `expectFn`'s
expectation for it, deferred. The outer call has id 1 and its reference id 2;
the inner call has id 3, its reference id 4 and the literal id 5.
-}
nestedForeignCalls : (Can.Module -> Expectation) -> (() -> Expectation)
nestedForeignCalls expectFn _ =
    let
        annotation =
            makeAnnotation [ "a" ] (funType (varType "a") (varType "a"))

        home =
            ModuleName.Canonical Pkg.core "Basics"

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
