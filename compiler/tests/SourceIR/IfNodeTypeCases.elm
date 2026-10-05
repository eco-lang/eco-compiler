module SourceIR.IfNodeTypeCases exposing (expectSuite)

{-| Gives a later stage `if` nodes whose recorded type is a fresh type variable,
so that a stage which mishandles the type recorded there has something to fail
on.

On the typed path (the MLIR and native pipeline, on which the type checker runs
with node recording on) the type checker records a type variable for each `if`
node, and which variable depends on what the `if` is expected to be. When the
`if` is checked against a type annotation,
`Compiler.Type.Constrain.Typed.Expression` records the type the `if` is checked
against if that type is a bare type variable, and otherwise a fresh variable
constrained equal to that type. For the body of an annotated definition, that
type is what is left of the annotation after one arrow is removed for each of
the definition's arguments. Five of these programs give an `if` the second
path.

There are six small programs, in each of which an `if` produces a value of a
structured type, a `List`, a `Maybe` or a function, and each is handed to a
check the caller supplies.

Each program is a module named `Test`, built with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`, holding two
annotated top-level values: a function containing the `if`, and `testValue`,
which applies that function to concrete arguments.

The module asserts nothing. `expectSuite` hands each program to the
expectation function its caller supplies, so what is checked depends on the
caller. The programs are:

  - A: `identity : List a -> List a`, whose body is an `if` checked against
    `List a`.
  - B: `keepPositive : Maybe Int -> Maybe Int`, a `case` whose `Just` branch is
    an `if` checked against the concrete type `Maybe Int`.
  - C: `choose`, an `if` both of whose branches are `if`s, all three checked
    against `Maybe t`.
  - D: `pick : Bool -> List Int`, which binds an `if` to a `let` name with no
    annotation, so that `if` is not checked against an annotation; this is the
    one program whose `if` takes neither path above.
  - E: `pickFn`, whose body is an `if` choosing between two lambdas, checked
    against the function type `List a -> List a`.
  - F: `transform : (a -> a) -> List a -> List a`, whose body is an `if`
    checked against `List a`, used by `testValue` at `a = Int`.

Among what is not tested: an `else if` chain, since every `if` here has one
condition, and an `if` checked against an annotation where the type left after
the definition's arguments is a bare type variable.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named `"If node type "` followed by `condStr`, that applies
`expectFn` to the six programs in order and stops at the first whose expectation
fails; the programs after it are not run. The test then fails with that
program's label and the failure's description, as
`Compiler.BulkCheck.bulkCheck` reports it.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("If node type " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Pairs each program, A to F in order, with its label, each to be checked with
`expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "If returning List a in polymorphic fn", run = ifReturningListA expectFn }
    , { label = "If returning Maybe a with constructors", run = ifReturningMaybeA expectFn }
    , { label = "Nested if with parameterized type", run = nestedIfParameterized expectFn }
    , { label = "If in unannotated let binding", run = ifInUnannotatedLet expectFn }
    , { label = "If returning function type", run = ifReturningFunctionType expectFn }
    , { label = "Polymorphic if body specialized at Int", run = polyIfBodySpecialized expectFn }
    ]



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


{-| The Source type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The Source type `Bool`.
-}
tBool : Src.Type
tBool =
    tType "Bool" []


{-| Builds the Source type of a list whose elements have type `a`.
-}
tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]


{-| Builds the Source type `Maybe` applied to `a`.
-}
tMaybe : Src.Type -> Src.Type
tMaybe a =
    tType "Maybe" [ a ]


{-| Applies `expectFn` to program A:

    identity : List a -> List a
    identity xs =
        if True then
            xs

        else
            xs

    testValue : List Int
    testValue =
        identity [ 1, 2 ]

-}
ifReturningListA : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningListA expectFn _ =
    let
        identityDef : TypedDef
        identityDef =
            { name = "identity"
            , args = [ pVar "xs" ]
            , tipe = tLambda (tList (tVar "a")) (tList (tVar "a"))
            , body =
                ifExpr
                    (boolExpr True)
                    (varExpr "xs")
                    (varExpr "xs")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body = callExpr (varExpr "identity") [ listExpr [ intExpr 1, intExpr 2 ] ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ identityDef, testValueDef ]
            []
            []
        )


{-| Applies `expectFn` to program B, in which the `if` is a `case` branch and the
type it is checked against is concrete:

    keepPositive : Maybe Int -> Maybe Int
    keepPositive mx =
        case mx of
            Just x ->
                if x > 0 then
                    mx

                else
                    Nothing

            Nothing ->
                Nothing

    testValue : Maybe Int
    testValue =
        keepPositive (Just 42)

-}
ifReturningMaybeA : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningMaybeA expectFn _ =
    let
        keepPositiveDef : TypedDef
        keepPositiveDef =
            { name = "keepPositive"
            , args = [ pVar "mx" ]
            , tipe = tLambda (tMaybe tInt) (tMaybe tInt)
            , body =
                caseExpr (varExpr "mx")
                    [ ( pCtor "Just" [ pVar "x" ]
                      , ifExpr
                            (binopsExpr [ ( varExpr "x", ">" ) ] (intExpr 0))
                            (varExpr "mx")
                            (ctorExpr "Nothing")
                      )
                    , ( pCtor "Nothing" [], ctorExpr "Nothing" )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body = callExpr (varExpr "keepPositive") [ callExpr (ctorExpr "Just") [ intExpr 42 ] ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ keepPositiveDef, testValueDef ]
            []
            []
        )


{-| Applies `expectFn` to program C, in which both branches of the outer `if` are
`if`s:

    choose : Bool -> Bool -> Maybe t -> Maybe t -> Maybe t
    choose x y a b =
        if x then
            if y then
                a

            else
                b

        else if y then
            b

        else
            a

    testValue : Maybe Int
    testValue =
        choose True False (Just 1) (Just 2)

The `else if` above is how Elm prints the built program, whose `else` branch is
a separate `if` node; the outer `if` has one condition.

-}
nestedIfParameterized : (Src.Module -> Expectation) -> (() -> Expectation)
nestedIfParameterized expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "choose"
            , args = [ pVar "x", pVar "y", pVar "a", pVar "b" ]
            , tipe =
                tLambda tBool
                    (tLambda tBool
                        (tLambda (tMaybe (tVar "t"))
                            (tLambda (tMaybe (tVar "t")) (tMaybe (tVar "t")))
                        )
                    )
            , body =
                ifExpr
                    (varExpr "x")
                    (ifExpr (varExpr "y") (varExpr "a") (varExpr "b"))
                    (ifExpr (varExpr "y") (varExpr "b") (varExpr "a"))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tMaybe tInt
            , body =
                callExpr (varExpr "choose")
                    [ boolExpr True
                    , boolExpr False
                    , callExpr (ctorExpr "Just") [ intExpr 1 ]
                    , callExpr (ctorExpr "Just") [ intExpr 2 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            []
            []
        )


{-| Applies `expectFn` to program D, in which the `if` is bound by a `let` with no
type annotation:

    pick : Bool -> List Int
    pick flag =
        let
            result =
                if flag then
                    [ 1, 2 ]

                else
                    [ 3, 4 ]
        in
        result

    testValue : List Int
    testValue =
        pick True

-}
ifInUnannotatedLet : (Src.Module -> Expectation) -> (() -> Expectation)
ifInUnannotatedLet expectFn _ =
    let
        pickDef : TypedDef
        pickDef =
            { name = "pick"
            , args = [ pVar "flag" ]
            , tipe = tLambda tBool (tList tInt)
            , body =
                letExpr
                    [ define "result"
                        []
                        (ifExpr
                            (varExpr "flag")
                            (listExpr [ intExpr 1, intExpr 2 ])
                            (listExpr [ intExpr 3, intExpr 4 ])
                        )
                    ]
                    (varExpr "result")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body = callExpr (varExpr "pick") [ boolExpr True ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ pickDef, testValueDef ]
            []
            []
        )


{-| Applies `expectFn` to program E, in which `pickFn` takes one argument and its
`if` returns a function:

    pickFn : Bool -> List a -> List a
    pickFn flag =
        if flag then
            \xs -> xs

        else
            \xs -> xs

    testValue : List Int
    testValue =
        pickFn True [ 1, 2, 3 ]

`testValue` is built as a call of the call `pickFn True`, not as one call with
two arguments.

-}
ifReturningFunctionType : (Src.Module -> Expectation) -> (() -> Expectation)
ifReturningFunctionType expectFn _ =
    let
        pickFnDef : TypedDef
        pickFnDef =
            { name = "pickFn"
            , args = [ pVar "flag" ]
            , tipe = tLambda tBool (tLambda (tList (tVar "a")) (tList (tVar "a")))
            , body =
                ifExpr
                    (varExpr "flag")
                    (lambdaExpr [ pVar "xs" ] (varExpr "xs"))
                    (lambdaExpr [ pVar "xs" ] (varExpr "xs"))
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body =
                callExpr
                    (callExpr (varExpr "pickFn") [ boolExpr True ])
                    [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ] ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ pickFnDef, testValueDef ]
            []
            []
        )


{-| Applies `expectFn` to program F, in which `transform` ignores its function
argument and `testValue` calls `transform` at `a = Int`:

    transform : (a -> a) -> List a -> List a
    transform f xs =
        if True then
            xs

        else
            xs

    testValue : List Int
    testValue =
        transform (\x -> x + 1) [ 1, 2, 3 ]

-}
polyIfBodySpecialized : (Src.Module -> Expectation) -> (() -> Expectation)
polyIfBodySpecialized expectFn _ =
    let
        transformDef : TypedDef
        transformDef =
            { name = "transform"
            , args = [ pVar "f", pVar "xs" ]
            , tipe =
                tLambda (tLambda (tVar "a") (tVar "a"))
                    (tLambda (tList (tVar "a")) (tList (tVar "a")))
            , body =
                ifExpr
                    (boolExpr True)
                    (varExpr "xs")
                    (varExpr "xs")
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tList tInt
            , body =
                callExpr (varExpr "transform")
                    [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ transformDef, testValueDef ]
            []
            []
        )
