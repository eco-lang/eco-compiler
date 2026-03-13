module SourceIR.LetDestructFnCases exposing (expectSuite)

{-| Tests for destructuring let expressions where the bound value
contains functions (lambdas, accessors, record update closures).

These test cases target the monomorphizer's handling of LetDestruct
when the bound expression has a type containing TLambda. The optimizer
compiles `let (a, b) = expr` into `Let (Def "_v0" expr) (Destruct ... (Root "_v0") ...)`,
and the monomorphizer must have "_v0" in VarEnv when processing the
Destruct nodes.

Bug scenario: When `shouldUseValueMulti` returns True (the type contains
lambdas AND has CEcoValue type variables), the body may be processed
before the let-bound variable is added to VarEnv, causing a crash at
`specializePath: Root variable '_v0' not found in VarEnv`.
-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessorExpr
        , boolExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , destruct
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pTuple
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tupleExpr
        , updateExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let destruct with function-typed values " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Destruct tuple of lambdas from case", run = destructTupleOfLambdasFromCase expectFn }
    , { label = "Destruct tuple of accessors from case", run = destructTupleOfAccessorsFromCase expectFn }
    , { label = "Destruct tuple of lambdas direct", run = destructTupleOfLambdasDirect expectFn }
    , { label = "Destruct tuple of accessor and lambda from case", run = destructTupleOfAccessorAndLambdaFromCase expectFn }
    , { label = "Destruct pair of lambdas used in body", run = destructPairOfLambdasUsedInBody expectFn }
    ]



-- ============================================================================
-- 1. Tuple of lambdas from case (matches the original crash exactly)
-- ============================================================================


{-| Mirrors Scene.Drawing.processGesture:

    type Loc = Doc | Div

    processGesture : Loc -> { a : Int, b : Int } -> ( { a : Int, b : Int } -> Int, Int -> { a : Int, b : Int } -> { a : Int, b : Int } )
    processGesture loc rec =
        let
            ( get, set ) =
                case loc of
                    Doc -> ( .a, \x m -> { m | a = x } )
                    Div -> ( .b, \x m -> { m | b = x } )
        in
        ( get rec, set 99 rec )

-}
destructTupleOfLambdasFromCase : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleOfLambdasFromCase expectFn _ =
    let
        locUnion : UnionDef
        locUnion =
            { name = "Loc"
            , args = []
            , ctors =
                [ { name = "Doc", args = [] }
                , { name = "Div", args = [] }
                ]
            }

        recType =
            tRecord [ ( "a", tType "Int" [] ), ( "b", tType "Int" [] ) ]

        getterType =
            tLambda recType (tType "Int" [])

        setterType =
            tLambda (tType "Int" []) (tLambda recType recType)

        -- processGesture : Loc -> { a : Int, b : Int } -> ( Int, { a : Int, b : Int } )
        processFn : TypedDef
        processFn =
            { name = "processGesture"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe = tLambda (tType "Loc" []) (tLambda recType (tTuple (tType "Int" []) recType))
            , body =
                letExpr
                    [ destruct (pTuple (pVar "get") (pVar "set"))
                        (caseExpr (varExpr "loc")
                            [ ( pCtor "Doc" []
                              , tupleExpr
                                    (accessorExpr "a")
                                    (lambdaExpr [ pVar "x", pVar "m" ] (updateExpr (varExpr "m") [ ( "a", varExpr "x" ) ]))
                              )
                            , ( pCtor "Div" []
                              , tupleExpr
                                    (accessorExpr "b")
                                    (lambdaExpr [ pVar "x", pVar "m" ] (updateExpr (varExpr "m") [ ( "b", varExpr "x" ) ]))
                              )
                            ]
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
            , tipe = tTuple (tType "Int" []) recType
            , body =
                callExpr (varExpr "processGesture")
                    [ ctorExpr "Doc"
                    , recordExpr [ ( "a", intExpr 1 ), ( "b", intExpr 2 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ processFn, testValueDef ] [ locUnion ] []
    in
    expectFn modul



-- ============================================================================
-- 2. Tuple of accessors from case
-- ============================================================================


{-| Similar but both elements are accessors:

    choose : Loc -> { a : Int, b : Int } -> ( Int, Int )
    choose loc rec =
        let
            ( fst, snd ) =
                case loc of
                    Doc -> ( .a, .b )
                    Div -> ( .b, .a )
        in
        ( fst rec, snd rec )

-}
destructTupleOfAccessorsFromCase : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleOfAccessorsFromCase expectFn _ =
    let
        locUnion : UnionDef
        locUnion =
            { name = "Loc"
            , args = []
            , ctors =
                [ { name = "Doc", args = [] }
                , { name = "Div", args = [] }
                ]
            }

        recType =
            tRecord [ ( "a", tType "Int" [] ), ( "b", tType "Int" [] ) ]

        chooseFn : TypedDef
        chooseFn =
            { name = "choose"
            , args = [ pVar "loc", pVar "rec" ]
            , tipe = tLambda (tType "Loc" []) (tLambda recType (tTuple (tType "Int" []) (tType "Int" [])))
            , body =
                letExpr
                    [ destruct (pTuple (pVar "fst") (pVar "snd"))
                        (caseExpr (varExpr "loc")
                            [ ( pCtor "Doc" []
                              , tupleExpr (accessorExpr "a") (accessorExpr "b")
                              )
                            , ( pCtor "Div" []
                              , tupleExpr (accessorExpr "b") (accessorExpr "a")
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "fst") [ varExpr "rec" ])
                        (callExpr (varExpr "snd") [ varExpr "rec" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                callExpr (varExpr "choose")
                    [ ctorExpr "Doc"
                    , recordExpr [ ( "a", intExpr 10 ), ( "b", intExpr 20 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ chooseFn, testValueDef ] [ locUnion ] []
    in
    expectFn modul



-- ============================================================================
-- 3. Tuple of lambdas direct (no case)
-- ============================================================================


{-| Destructure a tuple of lambdas without a case expression:

    applyBoth : { a : Int, b : Int } -> ( Int, Int )
    applyBoth rec =
        let
            ( get, transform ) =
                ( .a, \x -> x )
        in
        ( get rec, transform (get rec) )

-}
destructTupleOfLambdasDirect : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleOfLambdasDirect expectFn _ =
    let
        recType =
            tRecord [ ( "a", tType "Int" [] ), ( "b", tType "Int" [] ) ]

        applyBothFn : TypedDef
        applyBothFn =
            { name = "applyBoth"
            , args = [ pVar "rec" ]
            , tipe = tLambda recType (tTuple (tType "Int" []) (tType "Int" []))
            , body =
                letExpr
                    [ destruct (pTuple (pVar "get") (pVar "transform"))
                        (tupleExpr
                            (accessorExpr "a")
                            (lambdaExpr [ pVar "x" ] (varExpr "x"))
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "get") [ varExpr "rec" ])
                        (callExpr (varExpr "transform") [ callExpr (varExpr "get") [ varExpr "rec" ] ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                callExpr (varExpr "applyBoth")
                    [ recordExpr [ ( "a", intExpr 5 ), ( "b", intExpr 10 ) ] ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ applyBothFn, testValueDef ] [] []
    in
    expectFn modul



-- ============================================================================
-- 4. Tuple of accessor and record-update lambda from case
-- ============================================================================


{-| Mixed accessor and record update lambda via if expression:

    getSet : Bool -> { x : Int } -> ( Int, { x : Int } )
    getSet flag rec =
        let
            ( getter, setter ) =
                if flag then
                    ( .x, \v r -> { r | x = v } )
                else
                    ( .x, \v r -> { r | x = v + 1 } )
        in
        ( getter rec, setter 42 rec )

-}
destructTupleOfAccessorAndLambdaFromCase : (Src.Module -> Expectation) -> (() -> Expectation)
destructTupleOfAccessorAndLambdaFromCase expectFn _ =
    let
        recType =
            tRecord [ ( "x", tType "Int" [] ) ]

        getSetFn : TypedDef
        getSetFn =
            { name = "getSet"
            , args = [ pVar "flag", pVar "rec" ]
            , tipe = tLambda (tType "Bool" []) (tLambda recType (tTuple (tType "Int" []) recType))
            , body =
                letExpr
                    [ destruct (pTuple (pVar "getter") (pVar "setter"))
                        (ifExpr (varExpr "flag")
                            (tupleExpr
                                (accessorExpr "x")
                                (lambdaExpr [ pVar "v", pVar "r" ] (updateExpr (varExpr "r") [ ( "x", varExpr "v" ) ]))
                            )
                            (tupleExpr
                                (accessorExpr "x")
                                (lambdaExpr [ pVar "v", pVar "r" ]
                                    (updateExpr (varExpr "r")
                                        [ ( "x", binopsExpr [ ( varExpr "v", "+" ) ] (intExpr 1) ) ]
                                    )
                                )
                            )
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "getter") [ varExpr "rec" ])
                        (callExpr (varExpr "setter") [ intExpr 42, varExpr "rec" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) recType
            , body =
                callExpr (varExpr "getSet")
                    [ boolExpr True
                    , recordExpr [ ( "x", intExpr 7 ) ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ getSetFn, testValueDef ] [] []
    in
    expectFn modul



-- ============================================================================
-- 5. Tuple of lambdas, both used in body expressions
-- ============================================================================


{-| Both destructured functions are used with multiple args:

    type Dir = Left | Right

    transform : Dir -> Int -> Int -> ( Int, Int )
    transform dir a b =
        let
            ( f, g ) =
                case dir of
                    Left  -> ( \x -> x + 1, \x -> x * 2 )
                    Right -> ( \x -> x * 3, \x -> x + 4 )
        in
        ( f a, g b )

-}
destructPairOfLambdasUsedInBody : (Src.Module -> Expectation) -> (() -> Expectation)
destructPairOfLambdasUsedInBody expectFn _ =
    let
        dirUnion : UnionDef
        dirUnion =
            { name = "Dir"
            , args = []
            , ctors =
                [ { name = "Left", args = [] }
                , { name = "Right", args = [] }
                ]
            }

        transformFn : TypedDef
        transformFn =
            { name = "transform"
            , args = [ pVar "dir", pVar "a", pVar "b" ]
            , tipe =
                tLambda (tType "Dir" [])
                    (tLambda (tType "Int" [])
                        (tLambda (tType "Int" [])
                            (tTuple (tType "Int" []) (tType "Int" []))
                        )
                    )
            , body =
                letExpr
                    [ destruct (pTuple (pVar "f") (pVar "g"))
                        (caseExpr (varExpr "dir")
                            [ ( pCtor "Left" []
                              , tupleExpr
                                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)))
                                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2)))
                              )
                            , ( pCtor "Right" []
                              , tupleExpr
                                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 3)))
                                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 4)))
                              )
                            ]
                        )
                    ]
                    (tupleExpr
                        (callExpr (varExpr "f") [ varExpr "a" ])
                        (callExpr (varExpr "g") [ varExpr "b" ])
                    )
            }

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tTuple (tType "Int" []) (tType "Int" [])
            , body =
                callExpr (varExpr "transform")
                    [ ctorExpr "Left"
                    , intExpr 10
                    , intExpr 20
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test" [ transformFn, testValueDef ] [ dirUnion ] []
    in
    expectFn modul
