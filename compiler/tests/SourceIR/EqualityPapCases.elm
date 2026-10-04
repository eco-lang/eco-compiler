module SourceIR.EqualityPapCases exposing (expectSuite)

{-| Supplies programs built around equality used as a function value, lists of
`Bool`, and `compare`, so that a test of a compiler stage can be run against
these shapes and a failure names the case it came from.

A partial application (PAP) is a function applied to fewer arguments than it
takes, which leaves a function value waiting for the rest. The equality cases
make one by applying a local function such as `eq a b = a == b` to a single
argument. None of them uses the operator `(==)` itself as a value.

Each case builds, with `Compiler.AST.SourceBuilder.makeModule`, a module named
`Test` that imports `Basics` and `List` and whose one top-level value,
`testValue`, is the case's expression. This module asserts nothing:
`expectSuite` hands the programs in turn to the caller's expectation function,
so what is checked, and after which stage, is the caller's choice. The cases run
through `Compiler.BulkCheck.bulkCheck` as one test, which stops at the first
case that fails.

The programs, in four groups:

  - Equality partially applied: `List.filter` with `eq` applied to an `Int`, a
    `Float`, a `Char` and a `String`, one case each, and one case with two
    such functions, one applied to an `Int` and one to a `String`.
  - `List.any` and `List.all` over a `Bool` list, with `Basics.identity` and
    with `Basics.not` as the predicate.
  - `Basics.compare` on two `Char`s, two `Float`s and two `String`s, and a
    `case` on the `Order` that `compare 1 2` returns.
  - `List.map` producing a `Bool` list: `Basics.not` and `Basics.identity` over
    a `Bool` list, and the anonymous function `\x -> x == 5` over an `Int`
    list.

Among what is not tested: `(==)` passed directly as a value; one equality
function used at two types, since the two-type case defines a separate function
for each type and its value uses only the `Int` one; and the values the
programs compute, which only a caller's expectation function could check.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , chrExpr
        , define
        , floatExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pCtor
        , pVar
        , qualVarExpr
        , strExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named `"Equality PAP and Bool list operations "` followed
by `condStr`, that applies `expectFn` to the sixteen programs in turn through
`bulkCheck`, stopping at the first that fails, and fails with that case's label
followed by the description of its failure.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Equality PAP and Bool list operations " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the sixteen labelled cases, each applying `expectFn` to one program.

The labels of the `Float`, `Char` and `String` equality cases list fewer
elements than the programs' lists hold.

-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ -- A local equality function, partially applied
      { label = "Equality PAP on Int: List.filter (eq 5) [1,2,5,3,5]"
      , run = equalityPapInt expectFn
      }
    , { label = "Equality PAP on Float: List.filter (eq 2.5) [1.0,2.5,3.0]"
      , run = equalityPapFloat expectFn
      }
    , { label = "Equality PAP on Char: List.filter (eq 'a') ['a','b','a']"
      , run = equalityPapChar expectFn
      }
    , { label = "Equality PAP on String: List.filter (eq \"hello\") [\"hi\",\"hello\"]"
      , run = equalityPapString expectFn
      }
    , { label = "Equality PAP used at multiple types in same module"
      , run = equalityPapMultiType expectFn
      }

    -- List.any and List.all over Bool lists
    , { label = "List.any identity [False, True, False]"
      , run = listAnyIdentityBool expectFn
      }
    , { label = "List.all identity [True, True, True]"
      , run = listAllIdentityBool expectFn
      }
    , { label = "List.any not [True, False]"
      , run = listAnyNotBool expectFn
      }
    , { label = "List.all not [False, False]"
      , run = listAllNotBool expectFn
      }

    -- compare producing Order values
    , { label = "compare on Char: compare 'a' 'b'"
      , run = compareChar expectFn
      }
    , { label = "compare on Float: compare 1.5 2.5"
      , run = compareFloat expectFn
      }
    , { label = "compare on String: compare \"apple\" \"banana\""
      , run = compareString expectFn
      }
    , { label = "case on compare result (Order pattern match)"
      , run = caseOnCompareResult expectFn
      }

    -- List.map producing Bool lists
    , { label = "List.map not [True, False, True]"
      , run = listMapNot expectFn
      }
    , { label = "List.map identity [True, False, True]"
      , run = listMapIdentityBool expectFn
      }
    , { label = "List.map with equality predicate producing Bool list"
      , run = listMapEqualityPredicate expectFn
      }
    ]



-- ============================================================================
-- A LOCAL EQUALITY FUNCTION, PARTIALLY APPLIED
-- ============================================================================


{-| Applies `expectFn` to the program
`let eq a b = a == b in List.filter (eq 5) [ 1, 2, 5, 3, 5 ]`.
-}
equalityPapInt : (Src.Module -> Expectation) -> (() -> Expectation)
equalityPapInt expectFn _ =
    let
        eqFn =
            define "eq"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ eqFn ]
                    (callExpr (qualVarExpr "List" "filter")
                        [ callExpr (varExpr "eq") [ intExpr 5 ]
                        , listExpr [ intExpr 1, intExpr 2, intExpr 5, intExpr 3, intExpr 5 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program
`let eq a b = a == b in List.filter (eq 2.5) [ 1.0, 2.5, 3.0, 2.5 ]`.
-}
equalityPapFloat : (Src.Module -> Expectation) -> (() -> Expectation)
equalityPapFloat expectFn _ =
    let
        eqFn =
            define "eq"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ eqFn ]
                    (callExpr (qualVarExpr "List" "filter")
                        [ callExpr (varExpr "eq") [ floatExpr 2.5 ]
                        , listExpr [ floatExpr 1.0, floatExpr 2.5, floatExpr 3.0, floatExpr 2.5 ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program
`let eq a b = a == b in List.filter (eq 'a') [ 'a', 'b', 'a', 'c' ]`.
-}
equalityPapChar : (Src.Module -> Expectation) -> (() -> Expectation)
equalityPapChar expectFn _ =
    let
        eqFn =
            define "eq"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ eqFn ]
                    (callExpr (qualVarExpr "List" "filter")
                        [ callExpr (varExpr "eq") [ chrExpr "a" ]
                        , listExpr [ chrExpr "a", chrExpr "b", chrExpr "a", chrExpr "c" ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Applies `expectFn` to the program
`let eq a b = a == b in List.filter (eq "hello") [ "hi", "hello", "world", "hello" ]`.
-}
equalityPapString : (Src.Module -> Expectation) -> (() -> Expectation)
equalityPapString expectFn _ =
    let
        eqFn =
            define "eq"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        modul =
            makeModule "testValue"
                (letExpr [ eqFn ]
                    (callExpr (qualVarExpr "List" "filter")
                        [ callExpr (varExpr "eq") [ strExpr "hello" ]
                        , listExpr [ strExpr "hi", strExpr "hello", strExpr "world", strExpr "hello" ]
                        ]
                    )
                )
    in
    expectFn modul


{-| Applies `expectFn` to a program with two equality functions in one `let`:
`ints` is `List.filter (eqI 5) [ 1, 5, 3 ]` and `strs` is
`List.filter (eqS "x") [ "x", "y" ]`, where `eqI a b` and `eqS a b` are each
`a == b`.

The program's value is `ints` alone; `strs` is defined but not used.

-}
equalityPapMultiType : (Src.Module -> Expectation) -> (() -> Expectation)
equalityPapMultiType expectFn _ =
    let
        eqI =
            define "eqI"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        eqS =
            define "eqS"
                [ pVar "a", pVar "b" ]
                (binopsExpr [ ( varExpr "a", "==" ) ] (varExpr "b"))

        ints =
            define "ints"
                []
                (callExpr (qualVarExpr "List" "filter")
                    [ callExpr (varExpr "eqI") [ intExpr 5 ]
                    , listExpr [ intExpr 1, intExpr 5, intExpr 3 ]
                    ]
                )

        strs =
            define "strs"
                []
                (callExpr (qualVarExpr "List" "filter")
                    [ callExpr (varExpr "eqS") [ strExpr "x" ]
                    , listExpr [ strExpr "x", strExpr "y" ]
                    ]
                )
    in
    expectFn
        (makeModule "testValue"
            (letExpr [ eqI, eqS, ints, strs ]
                (varExpr "ints")
            )
        )



-- ============================================================================
-- LIST.ANY AND LIST.ALL OVER BOOL LISTS
-- ============================================================================


{-| Applies `expectFn` to the program
`List.any Basics.identity [ False, True, False ]`.
-}
listAnyIdentityBool : (Src.Module -> Expectation) -> (() -> Expectation)
listAnyIdentityBool expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "List" "any")
                [ qualVarExpr "Basics" "identity"
                , listExpr [ boolExpr False, boolExpr True, boolExpr False ]
                ]
            )
        )


{-| Applies `expectFn` to the program
`List.all Basics.identity [ True, True, True ]`.
-}
listAllIdentityBool : (Src.Module -> Expectation) -> (() -> Expectation)
listAllIdentityBool expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "List" "all")
                [ qualVarExpr "Basics" "identity"
                , listExpr [ boolExpr True, boolExpr True, boolExpr True ]
                ]
            )
        )


{-| Applies `expectFn` to the program `List.any Basics.not [ True, False ]`.
-}
listAnyNotBool : (Src.Module -> Expectation) -> (() -> Expectation)
listAnyNotBool expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "List" "any")
                [ qualVarExpr "Basics" "not"
                , listExpr [ boolExpr True, boolExpr False ]
                ]
            )
        )


{-| Applies `expectFn` to the program `List.all Basics.not [ False, False ]`.
-}
listAllNotBool : (Src.Module -> Expectation) -> (() -> Expectation)
listAllNotBool expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "List" "all")
                [ qualVarExpr "Basics" "not"
                , listExpr [ boolExpr False, boolExpr False ]
                ]
            )
        )



-- ============================================================================
-- COMPARE PRODUCING ORDER VALUES
-- ============================================================================


{-| Applies `expectFn` to the program `Basics.compare 'a' 'b'`.
-}
compareChar : (Src.Module -> Expectation) -> (() -> Expectation)
compareChar expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "compare")
                [ chrExpr "a", chrExpr "b" ]
            )
        )


{-| Applies `expectFn` to the program `Basics.compare 1.5 2.5`.
-}
compareFloat : (Src.Module -> Expectation) -> (() -> Expectation)
compareFloat expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "compare")
                [ floatExpr 1.5, floatExpr 2.5 ]
            )
        )


{-| Applies `expectFn` to the program `Basics.compare "apple" "banana"`.
-}
compareString : (Src.Module -> Expectation) -> (() -> Expectation)
compareString expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "compare")
                [ strExpr "apple", strExpr "banana" ]
            )
        )


{-| Applies `expectFn` to a program that binds `result = Basics.compare 1 2`
in a `let` and matches it with one branch per `Order` constructor, giving
`"less"` for `LT`, `"equal"` for `EQ` and `"greater"` for `GT`.
-}
caseOnCompareResult : (Src.Module -> Expectation) -> (() -> Expectation)
caseOnCompareResult expectFn _ =
    let
        result =
            define "result"
                []
                (callExpr (qualVarExpr "Basics" "compare")
                    [ intExpr 1, intExpr 2 ]
                )

        modul =
            makeModule "testValue"
                (letExpr [ result ]
                    (caseExpr (varExpr "result")
                        [ ( pCtor "LT" [], strExpr "less" )
                        , ( pCtor "EQ" [], strExpr "equal" )
                        , ( pCtor "GT" [], strExpr "greater" )
                        ]
                    )
                )
    in
    expectFn modul



-- ============================================================================
-- LIST.MAP PRODUCING BOOL LISTS
-- ============================================================================


{-| Applies `expectFn` to the program
`List.map Basics.not [ True, False, True ]`.
-}
listMapNot : (Src.Module -> Expectation) -> (() -> Expectation)
listMapNot expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "List" "map")
                [ qualVarExpr "Basics" "not"
                , listExpr [ boolExpr True, boolExpr False, boolExpr True ]
                ]
            )
        )


{-| Applies `expectFn` to the program
`List.map Basics.identity [ True, False, True ]`.
-}
listMapIdentityBool : (Src.Module -> Expectation) -> (() -> Expectation)
listMapIdentityBool expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "List" "map")
                [ qualVarExpr "Basics" "identity"
                , listExpr [ boolExpr True, boolExpr False, boolExpr True ]
                ]
            )
        )


{-| Applies `expectFn` to the program
`List.map (\x -> x == 5) [ 1, 5, 3, 5, 2 ]`, whose function is an anonymous
one rather than a partial application.
-}
listMapEqualityPredicate : (Src.Module -> Expectation) -> (() -> Expectation)
listMapEqualityPredicate expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "List" "map")
                [ lambdaExpr [ pVar "x" ]
                    (binopsExpr [ ( varExpr "x", "==" ) ] (intExpr 5))
                , listExpr [ intExpr 1, intExpr 5, intExpr 3, intExpr 5, intExpr 2 ]
                ]
            )
        )
