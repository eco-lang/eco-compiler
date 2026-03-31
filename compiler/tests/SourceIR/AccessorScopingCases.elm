module SourceIR.AccessorScopingCases exposing (expectSuite)

{-| Test cases for accessor type-variable scoping across control flow and containers.

These tests are variations on the known accessor scoping bug where standalone
accessors inside case/if branches get unresolved type variables. They exercise:

  - Control flow: case vs if
  - Container types: tuple2, tuple3, record, custom type, list
  - Combinations of both axes

Each test stores accessor functions selected by control flow in a container,
then applies them. The type variables from the accessor's polymorphic type
must be resolved against the enclosing record type.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessorExpr
        , boolExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , destruct
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pList
        , pTuple
        , pTuple3
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tuple3Expr
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Accessor scoping " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ ifAccessorCases expectFn
        , containerVariationCases expectFn
        , ifContainerCases expectFn
        ]



-- ============================================================================
-- HELPERS
-- ============================================================================


tInt : Src.Type
tInt =
    tType "Int" []


tBool : Src.Type
tBool =
    tType "Bool" []


recAB : Src.Type
recAB =
    tRecord [ ( "a", tInt ), ( "b", tInt ) ]


recABC : Src.Type
recABC =
    tRecord [ ( "a", tInt ), ( "b", tInt ), ( "c", tInt ) ]


locUnion : UnionDef
locUnion =
    { name = "Loc"
    , args = []
    , ctors =
        [ { name = "First", args = [] }
        , { name = "Second", args = [] }
        ]
    }


loc3Union : UnionDef
loc3Union =
    { name = "Loc3"
    , args = []
    , ctors =
        [ { name = "LocA", args = [] }
        , { name = "LocB", args = [] }
        , { name = "LocC", args = [] }
        ]
    }


wrapperUnion : UnionDef
wrapperUnion =
    { name = "Getter"
    , args = []
    , ctors =
        [ { name = "MkGetter", args = [ tLambda recAB tInt ] }
        ]
    }



-- ============================================================================
-- A1: If-selected accessors stored in tuple
-- ============================================================================


ifAccessorCases : (Src.Module -> Expectation) -> List TestCase
ifAccessorCases expectFn =
    [ { label = "If-selected accessors in tuple", run = ifAccessorTuple expectFn }
    , { label = "If-selected accessor+lambda in tuple", run = ifAccessorLambdaTuple expectFn }
    ]


{-| A1: choose flag rec = let (getter, setter) = if flag then (.a, .b) else (.b, .a) in (getter rec, setter rec)
-}
ifAccessorTuple : (Src.Module -> Expectation) -> (() -> Expectation)
ifAccessorTuple expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "choose"
            , args = [ pVar "flag", pVar "rec" ]
            , tipe = tLambda tBool (tLambda recAB (tTuple tInt tInt))
            , body =
                letExpr
                    [ destruct (pTuple (pVar "getter") (pVar "setter"))
                        (ifExpr
                            (varExpr "flag")
                            (tupleExpr (accessorExpr "a") (accessorExpr "b"))
                            (tupleExpr (accessorExpr "b") (accessorExpr "a"))
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "getter") [ varExpr "rec" ])
                        (callExpr (varExpr "setter") [ varExpr "rec" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple tInt tInt
            , body =
                callExpr (varExpr "choose")
                    [ boolExpr True
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            []
            []
        )


{-| A2: processGesture flag rec = let (get, set) = if flag then (.a, \\x m -> {m|a=x}) else (.b, \\x m -> {m|b=x}) in (get rec, set 99 rec)
-}
ifAccessorLambdaTuple : (Src.Module -> Expectation) -> (() -> Expectation)
ifAccessorLambdaTuple expectFn _ =
    let
        processFn : TypedDef
        processFn =
            { name = "processGesture"
            , args = [ pVar "flag", pVar "rec" ]
            , tipe = tLambda tBool (tLambda recAB (tTuple tInt recAB))
            , body =
                letExpr
                    [ destruct (pTuple (pVar "get") (pVar "set"))
                        (ifExpr
                            (varExpr "flag")
                            (tupleExpr
                                (accessorExpr "a")
                                (lambdaExpr [ pVar "x", pVar "m" ] (updateExpr (varExpr "m") [ ( "a", varExpr "x" ) ]))
                            )
                            (tupleExpr
                                (accessorExpr "b")
                                (lambdaExpr [ pVar "x", pVar "m" ] (updateExpr (varExpr "m") [ ( "b", varExpr "x" ) ]))
                            )
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "get") [ varExpr "rec" ])
                        (callExpr (varExpr "set") [ intExpr 99, varExpr "rec" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple tInt recAB
            , body =
                callExpr (varExpr "processGesture")
                    [ boolExpr True
                    , recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ processFn, testValueDef ]
            []
            []
        )



-- ============================================================================
-- B1-B5: Container variations (all using case)
-- ============================================================================


containerVariationCases : (Src.Module -> Expectation) -> List TestCase
containerVariationCases expectFn =
    [ { label = "Case-selected accessors in tuple3", run = caseAccessorTuple3 expectFn }
    , { label = "Case-selected accessors applied in record", run = caseAccessorRecordApplied expectFn }
    , { label = "Case-selected accessors stored in record", run = caseAccessorRecordDeferred expectFn }
    , { label = "Case-selected accessor in custom type", run = caseAccessorCustomType expectFn }
    , { label = "Case-selected accessors in list", run = caseAccessorList expectFn }
    ]


{-| B1: choose3 loc rec = let (f, g, h) = case loc of ... -> (.a, .b, .c) ... in (f rec, g rec, h rec)
-}
caseAccessorTuple3 : (Src.Module -> Expectation) -> (() -> Expectation)
caseAccessorTuple3 expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "choose3"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe =
                tLambda (tType "Loc3" [])
                    (tLambda recABC tInt)
            , body =
                letExpr
                    [ destruct (pTuple3 (pVar "f") (pVar "g") (pVar "h"))
                        (caseExpr (varExpr "loc")
                            [ ( pCtor "LocA" [], tuple3Expr (accessorExpr "a") (accessorExpr "b") (accessorExpr "c") )
                            , ( pCtor "LocB" [], tuple3Expr (accessorExpr "b") (accessorExpr "c") (accessorExpr "a") )
                            , ( pCtor "LocC" [], tuple3Expr (accessorExpr "c") (accessorExpr "a") (accessorExpr "b") )
                            ]
                        )
                    ]
                    (callExpr (varExpr "f") [ varExpr "rec" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "choose3")
                    [ ctorExpr "LocA"
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ), ( "c", intExpr 30 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            [ loc3Union ]
            []
        )


{-| B2: chooseRec loc rec = case loc of First -> { get = .a rec, set = .b rec } ...
Applies accessors immediately inside the branch.
-}
caseAccessorRecordApplied : (Src.Module -> Expectation) -> (() -> Expectation)
caseAccessorRecordApplied expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "chooseRec"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe =
                tLambda (tType "Loc" [])
                    (tLambda recAB (tRecord [ ( "get", tInt ), ( "set", tInt ) ]))
            , body =
                caseExpr (varExpr "loc")
                    [ ( pCtor "First" []
                      , recordExpr
                            [ ( "get", callExpr (accessorExpr "a") [ varExpr "rec" ] )
                            , ( "set", callExpr (accessorExpr "b") [ varExpr "rec" ] )
                            ]
                      )
                    , ( pCtor "Second" []
                      , recordExpr
                            [ ( "get", callExpr (accessorExpr "b") [ varExpr "rec" ] )
                            , ( "set", callExpr (accessorExpr "a") [ varExpr "rec" ] )
                            ]
                      )
                    ]
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tRecord [ ( "get", tInt ), ( "set", tInt ) ]
            , body =
                callExpr (varExpr "chooseRec")
                    [ ctorExpr "First"
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            [ locUnion ]
            []
        )


{-| B3: chooseRecFn loc rec = let ops = case loc of ... -> { getter = .a, setter = .b } ... in (ops.getter rec, ops.setter rec)
Stores accessors as record fields, projects and applies later.
-}
caseAccessorRecordDeferred : (Src.Module -> Expectation) -> (() -> Expectation)
caseAccessorRecordDeferred expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "chooseRecFn"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe =
                tLambda (tType "Loc" [])
                    (tLambda recAB (tTuple tInt tInt))
            , body =
                letExpr
                    [ define "ops"
                        []
                        (caseExpr (varExpr "loc")
                            [ ( pCtor "First" []
                              , recordExpr [ ( "getter", accessorExpr "a" ), ( "setter", accessorExpr "b" ) ]
                              )
                            , ( pCtor "Second" []
                              , recordExpr [ ( "getter", accessorExpr "b" ), ( "setter", accessorExpr "a" ) ]
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (accessorExpr "getter") [ varExpr "ops", varExpr "rec" ])
                        (callExpr (accessorExpr "setter") [ varExpr "ops", varExpr "rec" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple tInt tInt
            , body =
                callExpr (varExpr "chooseRecFn")
                    [ ctorExpr "First"
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            [ locUnion ]
            []
        )


{-| B4: chooseAccessor loc rec = let (MkGetter g) = case loc of First -> MkGetter .a; Second -> MkGetter .b in g rec
Wraps accessor in a custom type constructor.
-}
caseAccessorCustomType : (Src.Module -> Expectation) -> (() -> Expectation)
caseAccessorCustomType expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "chooseAccessor"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe =
                tLambda (tType "Loc" [])
                    (tLambda recAB tInt)
            , body =
                letExpr
                    [ destruct (pCtor "MkGetter" [ pVar "g" ])
                        (caseExpr (varExpr "loc")
                            [ ( pCtor "First" [], callExpr (ctorExpr "MkGetter") [ accessorExpr "a" ] )
                            , ( pCtor "Second" [], callExpr (ctorExpr "MkGetter") [ accessorExpr "b" ] )
                            ]
                        )
                    ]
                    (callExpr (varExpr "g") [ varExpr "rec" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "chooseAccessor")
                    [ ctorExpr "First"
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            [ locUnion, wrapperUnion ]
            []
        )


{-| B5: chooseFromList loc rec = let accessors = case loc of ... -> [.a, .b] ... in case accessors of f :: \_ -> f rec; [] -> 0
Stores accessors in a list.
-}
caseAccessorList : (Src.Module -> Expectation) -> (() -> Expectation)
caseAccessorList expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "chooseFromList"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe =
                tLambda (tType "Loc" [])
                    (tLambda recAB tInt)
            , body =
                letExpr
                    [ define "accessors"
                        []
                        (caseExpr (varExpr "loc")
                            [ ( pCtor "First" [], listExpr [ accessorExpr "a", accessorExpr "b" ] )
                            , ( pCtor "Second" [], listExpr [ accessorExpr "b", accessorExpr "a" ] )
                            ]
                        )
                    ]
                    (caseExpr (varExpr "accessors")
                        [ ( pCons (pVar "f") pAnything, callExpr (varExpr "f") [ varExpr "rec" ] )
                        , ( pList [], intExpr 0 )
                        ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "chooseFromList")
                    [ ctorExpr "First"
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            [ locUnion ]
            []
        )



-- ============================================================================
-- C1-C3: If + alternative containers
-- ============================================================================


ifContainerCases : (Src.Module -> Expectation) -> List TestCase
ifContainerCases expectFn =
    [ { label = "If-selected accessors in tuple3", run = ifAccessorTuple3 expectFn }
    , { label = "If-selected accessors in list", run = ifAccessorList expectFn }
    , { label = "If-selected accessor in custom type", run = ifAccessorCustomType expectFn }
    ]


{-| C1: choose3If x y rec = let (f, g, h) = if x then (if y then (.a,.b,.c) else (.c,.b,.a)) else ... in f rec
Nested if + tuple3 + accessors.
-}
ifAccessorTuple3 : (Src.Module -> Expectation) -> (() -> Expectation)
ifAccessorTuple3 expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "choose3If"
            , args = [ pVar "x", pVar "y", pVar "rec" ]
            , tipe =
                tLambda tBool (tLambda tBool (tLambda recABC tInt))
            , body =
                letExpr
                    [ destruct (pTuple3 (pVar "f") (pVar "g") (pVar "h"))
                        (ifExpr
                            (varExpr "x")
                            (ifExpr
                                (varExpr "y")
                                (tuple3Expr (accessorExpr "a") (accessorExpr "b") (accessorExpr "c"))
                                (tuple3Expr (accessorExpr "c") (accessorExpr "b") (accessorExpr "a"))
                            )
                            (ifExpr
                                (varExpr "y")
                                (tuple3Expr (accessorExpr "b") (accessorExpr "a") (accessorExpr "c"))
                                (tuple3Expr (accessorExpr "c") (accessorExpr "a") (accessorExpr "b"))
                            )
                        )
                    ]
                    (callExpr (varExpr "f") [ varExpr "rec" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "choose3If")
                    [ boolExpr True
                    , boolExpr False
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ), ( "c", intExpr 30 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            []
            []
        )


{-| C2: chooseListIf flag rec = let accessors = if flag then [.a, .b] else [.b, .a] in case accessors of f :: \_ -> f rec; [] -> 0
If-selection + list container.
-}
ifAccessorList : (Src.Module -> Expectation) -> (() -> Expectation)
ifAccessorList expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "chooseListIf"
            , args = [ pVar "flag", pVar "rec" ]
            , tipe = tLambda tBool (tLambda recAB tInt)
            , body =
                letExpr
                    [ define "accessors"
                        []
                        (ifExpr
                            (varExpr "flag")
                            (listExpr [ accessorExpr "a", accessorExpr "b" ])
                            (listExpr [ accessorExpr "b", accessorExpr "a" ])
                        )
                    ]
                    (caseExpr (varExpr "accessors")
                        [ ( pCons (pVar "f") pAnything, callExpr (varExpr "f") [ varExpr "rec" ] )
                        , ( pList [], intExpr 0 )
                        ]
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "chooseListIf")
                    [ boolExpr True
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            []
            []
        )


{-| C3: chooseGetterIf flag rec = let (MkGetter g) = if flag then MkGetter .a else MkGetter .b in g rec
If-selection + custom type wrapping.
-}
ifAccessorCustomType : (Src.Module -> Expectation) -> (() -> Expectation)
ifAccessorCustomType expectFn _ =
    let
        chooseDef : TypedDef
        chooseDef =
            { name = "chooseGetterIf"
            , args = [ pVar "flag", pVar "rec" ]
            , tipe = tLambda tBool (tLambda recAB tInt)
            , body =
                letExpr
                    [ destruct (pCtor "MkGetter" [ pVar "g" ])
                        (ifExpr
                            (varExpr "flag")
                            (callExpr (ctorExpr "MkGetter") [ accessorExpr "a" ])
                            (callExpr (ctorExpr "MkGetter") [ accessorExpr "b" ])
                        )
                    ]
                    (callExpr (varExpr "g") [ varExpr "rec" ])
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                callExpr (varExpr "chooseGetterIf")
                    [ boolExpr True
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }
    in
    expectFn
        (makeModuleWithTypedDefsUnionsAliases "Test"
            [ chooseDef, testValueDef ]
            [ wrapperUnion ]
            []
        )
