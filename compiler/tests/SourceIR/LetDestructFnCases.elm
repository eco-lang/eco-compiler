module SourceIR.LetDestructFnCases exposing (expectSuite)

{-| Source programs in which a `let` takes apart a pair of functions, such as
`let ( get, set ) = ... in ...`, so that a pipeline stage can be checked on
destructuring when the parts of the value taken apart are functions.

Destructuring on the typed path depends on two stages agreeing about a name.
The typed optimizer (`Compiler.LocalOpt.Typed.Expression`) turns
`let ( a, b ) = e in body` into a `let` that binds `e` to a generated name,
around one destructor per variable, each reading its part from that name. The
substitution-engine monomorphizer (`Compiler.Monomorphize.Specialize`) crashes
if that name is not in its variable environment when it reaches a destructor.
It also treats a `let` binding that is not itself a function, but whose type
contains one together with an unresolved type variable, differently from
other bindings (`shouldUseValueMulti`), and a pair of functions is the kind of
value that can have such a type.

The module asserts nothing itself. `expectSuite` hands each program to the
expectation function its caller supplies, and that function decides which
stage runs and what is checked.

Each program is a module named `Test`, made with
`makeModuleWithTypedDefsUnionsAliases`. It holds one annotated function whose
body is the destructuring `let`, and an annotated `testValue` that calls the
function with fixed arguments. Every `let` binds a pair pattern of two
variables.

The programs, one per case:

  - `processGesture` cases on a two-constructor `Loc` and binds a record
    accessor and a two-argument record-update lambda.
  - `choose` cases on `Loc` and binds two record accessors.
  - `applyBoth` binds an accessor and an identity lambda from a literal pair,
    with no branching.
  - `getSet` branches with `if` on a `Bool` and binds an accessor and a
    record-update lambda.
  - `transform` cases on a two-constructor `Dir` and binds two one-argument
    arithmetic lambdas.

Among what is not tested: patterns other than a pair of variables, such as a
triple, a record, a constructor or a nested pair; a pair that comes from a
function call rather than from a `case`, an `if` or a literal pair; and whether
any program reaches the `shouldUseValueMulti` route, which nothing here
observes.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessorExpr
        , binopsExpr
        , boolExpr
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


{-| Creates one test, named "Let destruct with function-typed values "
followed by `condStr`, that passes each of the five programs to `expectFn` in
turn. It fails with the label of the first program whose expectation fails, and
the programs after that one are not checked. A program whose check crashes ends
the whole test without its label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Let destruct with function-typed values " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the five labelled cases, each of which builds its program when run
and gives `expectFn`'s verdict on it.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Destruct tuple of lambdas from case", run = destructTupleOfLambdasFromCase expectFn }
    , { label = "Destruct tuple of accessors from case", run = destructTupleOfAccessorsFromCase expectFn }
    , { label = "Destruct tuple of lambdas direct", run = destructTupleOfLambdasDirect expectFn }
    , { label = "Destruct tuple of accessor and lambda from case", run = destructTupleOfAccessorAndLambdaFromCase expectFn }
    , { label = "Destruct pair of lambdas used in body", run = destructPairOfLambdasUsedInBody expectFn }
    ]



-- ============================================================================
-- 1. Accessor and record-update lambda from a case
-- ============================================================================


{-| Checks with `expectFn` a module whose `let` takes apart a pair chosen by a
`case`, holding a record accessor and a two-argument record-update lambda:

    type Loc
        = Doc
        | Div

    processGesture : Loc -> { a : Int, b : Int } -> ( Int, { a : Int, b : Int } )
    processGesture loc rec =
        let
            ( get, set ) =
                case loc of
                    Doc ->
                        ( .a, \x m -> { m | a = x } )

                    Div ->
                        ( .b, \x m -> { m | b = x } )
        in
        ( get rec, set 99 rec )

    testValue : ( Int, { a : Int, b : Int } )
    testValue =
        processGesture Doc { a = 1, b = 2 }

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
-- 2. Two accessors from a case
-- ============================================================================


{-| Checks with `expectFn` a module whose `let` takes apart a pair of record
accessors chosen by a `case`. `Loc` is the same two-constructor type as in
`destructTupleOfLambdasFromCase`, declared again in this program's `Test`
module:

    choose : Loc -> { a : Int, b : Int } -> ( Int, Int )
    choose loc rec =
        let
            ( fst, snd ) =
                case loc of
                    Doc ->
                        ( .a, .b )

                    Div ->
                        ( .b, .a )
        in
        ( fst rec, snd rec )

    testValue : ( Int, Int )
    testValue =
        choose Doc { a = 10, b = 20 }

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
-- 3. Accessor and lambda from a literal pair (no branching)
-- ============================================================================


{-| Checks with `expectFn` a module whose `let` takes apart a literal pair of
a record accessor and an identity lambda, with no branch choosing it:

    applyBoth : { a : Int, b : Int } -> ( Int, Int )
    applyBoth rec =
        let
            ( get, transform ) =
                ( .a, \x -> x )
        in
        ( get rec, transform (get rec) )

    testValue : ( Int, Int )
    testValue =
        applyBoth { a = 5, b = 10 }

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
-- 4. Accessor and record-update lambda from an if
-- ============================================================================


{-| Checks with `expectFn` a module whose `let` takes apart a pair chosen by
an `if`, holding a record accessor and a two-argument record-update lambda:

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

    testValue : ( Int, { x : Int } )
    testValue =
        getSet True { x = 7 }

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
-- 5. Two arithmetic lambdas from a case, both applied in the body
-- ============================================================================


{-| Checks with `expectFn` a module whose `let` takes apart a pair of
one-argument arithmetic lambdas chosen by a `case`, and applies each of them to
a different argument of the enclosing function:

    type Dir
        = Left
        | Right

    transform : Dir -> Int -> Int -> ( Int, Int )
    transform dir a b =
        let
            ( f, g ) =
                case dir of
                    Left ->
                        ( \x -> x + 1, \x -> x * 2 )

                    Right ->
                        ( \x -> x * 3, \x -> x + 4 )
        in
        ( f a, g b )

    testValue : ( Int, Int )
    testValue =
        transform Left 10 20

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
