module SourceIR.EqualityPapCases exposing (expectSuite)

{-| Test cases for equality as first-class function value / PAP, List.any/all
with Bool elements, compare on Char/Float/String, and List.map producing Bool.

Covers gaps 3, 15, 16, 26 from e2e-to-elmtest.md.

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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Equality PAP and Bool list operations " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ -- Gap 3: Equality (==) as first-class function value / PAP
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

    -- Gap 15: List.any / List.all with Bool elements
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

    -- Gap 16: Compare on Char/Float/String producing Order values
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

    -- Gap 26: List.map producing Bool results
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
-- GAP 3: EQUALITY (==) AS FIRST-CLASS FUNCTION VALUE / PAP
-- ============================================================================


{-| let eq a b = a == b in List.filter (eq 5) [1, 2, 5, 3, 5]
Tests (==) as a PAP for Int.
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


{-| let eq a b = a == b in List.filter (eq 2.5) [1.0, 2.5, 3.0, 2.5]
Tests (==) as a PAP for Float.
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


{-| let eq a b = a == b in List.filter (eq 'a') ['a', 'b', 'a', 'c']
Tests (==) as a PAP for Char.
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


{-| let eq a b = a == b in List.filter (eq "hello") ["hi", "hello", "world", "hello"]
Tests (==) as a PAP for String.
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


{-| Tests (==) PAP used at both Int and String types in the same module.
let eqI a b = a == b
eqS a b = a == b
ints = List.filter (eqI 5) [1, 5, 3]
strs = List.filter (eqS "x") ["x", "y"]
in (ints, strs)
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
-- GAP 15: LIST.ANY / LIST.ALL WITH BOOL ELEMENTS
-- ============================================================================


{-| List.any identity [False, True, False]
Exercises papExtend with Bool elements and identity as predicate on Bool list.
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


{-| List.all identity [True, True, True]
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


{-| List.any not [True, False]
Tests Basics.not as predicate on a Bool list.
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


{-| List.all not [False, False]
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
-- GAP 16: COMPARE ON CHAR/FLOAT/STRING PRODUCING ORDER VALUES
-- ============================================================================


{-| compare 'a' 'b' -- should produce LT
Tests the polymorphic compare function on Char type.
-}
compareChar : (Src.Module -> Expectation) -> (() -> Expectation)
compareChar expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "compare")
                [ chrExpr "a", chrExpr "b" ]
            )
        )


{-| compare 1.5 2.5 -- should produce LT
Tests the polymorphic compare function on Float type.
-}
compareFloat : (Src.Module -> Expectation) -> (() -> Expectation)
compareFloat expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "compare")
                [ floatExpr 1.5, floatExpr 2.5 ]
            )
        )


{-| compare "apple" "banana" -- should produce LT
Tests the polymorphic compare function on String type.
-}
compareString : (Src.Module -> Expectation) -> (() -> Expectation)
compareString expectFn _ =
    expectFn
        (makeModule "testValue"
            (callExpr (qualVarExpr "Basics" "compare")
                [ strExpr "apple", strExpr "banana" ]
            )
        )


{-| Case on the result of compare to exercise Order pattern matching:
let result = compare 1 2
in case result of LT -> "less"; EQ -> "equal"; GT -> "greater"
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
-- GAP 26: LIST.MAP PRODUCING BOOL RESULTS
-- ============================================================================


{-| List.map not [True, False, True] -> [False, True, False]
Exercises Bool as the mapped result type in list operations.
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


{-| List.map identity [True, False, True] -> [True, False, True]
Exercises Bool identity through list mapping.
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


{-| List.map (\\x -> x == 5) [1, 5, 3, 5, 2] -> [False, True, False, True, False]
Exercises an equality predicate producing a Bool list from an Int list.
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
