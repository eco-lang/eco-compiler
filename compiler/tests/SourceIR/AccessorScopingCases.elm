module SourceIR.AccessorScopingCases exposing (expectSuite)

{-| Programs in which a record accessor such as `.a` is chosen in a branch of a
`case` or `if`, and in all but one of them kept in a tuple, record, list or
custom type, before it is applied. They exist so that a compiler stage that
leaves such an accessor's type variables unresolved has programs to fail on.

An accessor is polymorphic: `.a` has the type `{ r | a : x } -> x`, so it reads
the `a` field of any record that has one. A stage handling these programs must
still resolve `r` and `x` against the record the accessor is applied to. In
every case but one, the accessor leaves the branch that chose it inside a tuple,
record, list or `Getter`, and is applied only after that container is taken
apart; in the other, it is applied to `rec` inside the branch.

Each case builds a module named `Test` with
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefsUnionsAliases`, holding two
annotated values: a function that chooses the accessors and applies one or more
of them to its argument `rec`, and `testValue`, which applies that function to
fixed arguments.

`rec` is annotated as `{ a : Int, b : Int }` in every case except the two
triple cases, where it is `{ a : Int, b : Int, c : Int }`. Some cases also
declare `type Loc = First | Second` or `type Loc3 = LocA | LocB | LocC` for the
`case` to select on, or `type Getter = MkGetter ({ a : Int, b : Int } -> Int)`
to wrap one accessor.

This module only builds the programs. Each case that runs hands its module to
the `expectFn` given to `expectSuite`, which decides what is done with it and
what counts as passing. The cases run in order inside one test through
`Compiler.BulkCheck.bulkCheck`, and the first failure ends the run, so the cases
after it do not run; `bulkCheck`'s docstring says how that failure is reported.

The cases, by label:

  - "If-selected accessors in tuple": an `if` picks `( .a, .b )` or
    `( .b, .a )`; a `let` takes the pair apart and both accessors are applied.
  - "If-selected accessor+lambda in tuple": an `if` picks `.a` or `.b`, paired
    with a lambda that updates the same field; the accessor is applied to `rec`
    and the lambda to `99` and `rec`.
  - "Case-selected accessors in tuple3": a `case` on `Loc3` picks a rotation of
    `( .a, .b, .c )`; only the first component is applied.
  - "Case-selected accessors applied in record": a `case` on `Loc` applies `.a`
    and `.b` to `rec` inside each branch and returns the two results as a
    record, so no accessor leaves its branch unapplied.
  - "Case-selected accessors stored in record": a `case` on `Loc` returns a
    record holding two accessors; each is projected out and applied to `rec`.
  - "Case-selected accessor in custom type": a `case` on `Loc` wraps `.a` or
    `.b` in `MkGetter`; a `let` unwraps it and applies it.
  - "Case-selected accessors in list": a `case` on `Loc` picks `[ .a, .b ]` or
    `[ .b, .a ]`; a second `case` applies the head of the list.
  - "If-selected accessors in tuple3": nested `if`s on two flags pick one of
    four orderings of `.a`, `.b` and `.c`; only the first component is applied.
  - "If-selected accessors in list": the list case with an `if` in place of the
    `case`.
  - "If-selected accessor in custom type": the custom type case with an `if` in
    place of the `case`.

Among what is not tested: an accessor applied to an extensible record; an
accessor passed to a function other than a constructor; containers other than
these, such as `Maybe`; and, in the triple and list cases, applying any
component but the first.

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


{-| Returns one test, named `"Accessor scoping "` followed by `condStr`, that
runs the cases listed in the module docstring in order through
`Compiler.BulkCheck.bulkCheck`; the first failure ends the test.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Accessor scoping " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each bound to `expectFn`: the two `if` and tuple cases,
then the five `case` cases, then the three `if` and container cases.
-}
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


{-| The closed record type `{ a : Int, b : Int }`, the type of `rec` in every
case except the two triple cases.
-}
recAB : Src.Type
recAB =
    tRecord [ ( "a", tInt ), ( "b", tInt ) ]


{-| The closed record type `{ a : Int, b : Int, c : Int }`, the type of `rec` in
the two triple cases.
-}
recABC : Src.Type
recABC =
    tRecord [ ( "a", tInt ), ( "b", tInt ), ( "c", tInt ) ]


{-| The declaration `type Loc = First | Second`, which the two-way `case` cases
select on.
-}
locUnion : UnionDef
locUnion =
    { name = "Loc"
    , args = []
    , ctors =
        [ { name = "First", args = [] }
        , { name = "Second", args = [] }
        ]
    }


{-| The declaration `type Loc3 = LocA | LocB | LocC`, which the `case` triple
case selects on.
-}
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


{-| The declaration `type Getter = MkGetter ({ a : Int, b : Int } -> Int)`, a
single-constructor custom type that holds one accessor.
-}
wrapperUnion : UnionDef
wrapperUnion =
    { name = "Getter"
    , args = []
    , ctors =
        [ { name = "MkGetter", args = [ tLambda recAB tInt ] }
        ]
    }



-- ============================================================================
-- A1-A2: If-selected accessor kept in a pair
-- ============================================================================


{-| Returns the two cases that choose with an `if` an accessor kept in a pair,
together with a second accessor or with an update lambda, bound to `expectFn`.
-}
ifAccessorCases : (Src.Module -> Expectation) -> List TestCase
ifAccessorCases expectFn =
    [ { label = "If-selected accessors in tuple", run = ifAccessorTuple expectFn }
    , { label = "If-selected accessor+lambda in tuple", run = ifAccessorLambdaTuple expectFn }
    ]


{-| Returns the check that hands `expectFn` a module with this function, and a
`testValue` of `choose True { a = 10, b = 20 }`:

    choose : Bool -> { a : Int, b : Int } -> ( Int, Int )
    choose flag rec =
        let
            ( getter, setter ) =
                if flag then
                    ( .a, .b )

                else
                    ( .b, .a )
        in
        ( getter rec, setter rec )

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


{-| Returns the check that hands `expectFn` a module with this function, and a
`testValue` of `processGesture True { a = 1, b = 2 }`:

    processGesture : Bool -> { a : Int, b : Int } -> ( Int, { a : Int, b : Int } )
    processGesture flag rec =
        let
            ( get, set ) =
                if flag then
                    ( .a, \x m -> { m | a = x } )

                else
                    ( .b, \x m -> { m | b = x } )
        in
        ( get rec, set 99 rec )

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
-- B1-B5: Case-selected accessors
-- ============================================================================


{-| Returns the five cases that choose accessors with a `case`, bound to
`expectFn`: a triple, a record of applied results, a record of accessors, a
`Getter`, and a list.
-}
containerVariationCases : (Src.Module -> Expectation) -> List TestCase
containerVariationCases expectFn =
    [ { label = "Case-selected accessors in tuple3", run = caseAccessorTuple3 expectFn }
    , { label = "Case-selected accessors applied in record", run = caseAccessorRecordApplied expectFn }
    , { label = "Case-selected accessors stored in record", run = caseAccessorRecordDeferred expectFn }
    , { label = "Case-selected accessor in custom type", run = caseAccessorCustomType expectFn }
    , { label = "Case-selected accessors in list", run = caseAccessorList expectFn }
    ]


{-| Returns the check that hands `expectFn` a module declaring `Loc3`, with this
function and a `testValue` of `choose3 LocA { a = 10, b = 20, c = 30 }`:

    choose3 : Loc3 -> { a : Int, b : Int, c : Int } -> Int
    choose3 loc rec =
        let
            ( f, g, h ) =
                case loc of
                    LocA ->
                        ( .a, .b, .c )

                    LocB ->
                        ( .b, .c, .a )

                    LocC ->
                        ( .c, .a, .b )
        in
        f rec

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


{-| Returns the check that hands `expectFn` a module declaring `Loc`, with this
function and a `testValue` of `chooseRec First { a = 10, b = 20 }`:

    chooseRec : Loc -> { a : Int, b : Int } -> { get : Int, set : Int }
    chooseRec loc rec =
        case loc of
            First ->
                { get = .a rec, set = .b rec }

            Second ->
                { get = .b rec, set = .a rec }

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


{-| Returns the check that hands `expectFn` a module declaring `Loc`, with this
function and a `testValue` of `chooseRecFn First { a = 10, b = 20 }`:

    chooseRecFn : Loc -> { a : Int, b : Int } -> ( Int, Int )
    chooseRecFn loc rec =
        let
            ops =
                case loc of
                    First ->
                        { getter = .a, setter = .b }

                    Second ->
                        { getter = .b, setter = .a }
        in
        ( .getter ops rec, .setter ops rec )

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


{-| Returns the check that hands `expectFn` a module declaring `Loc` and
`Getter`, with this function and a `testValue` of
`chooseAccessor First { a = 10, b = 20 }`:

    chooseAccessor : Loc -> { a : Int, b : Int } -> Int
    chooseAccessor loc rec =
        let
            (MkGetter g) =
                case loc of
                    First ->
                        MkGetter .a

                    Second ->
                        MkGetter .b
        in
        g rec

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


{-| Returns the check that hands `expectFn` a module declaring `Loc`, with this
function and a `testValue` of `chooseFromList First { a = 10, b = 20 }`:

    chooseFromList : Loc -> { a : Int, b : Int } -> Int
    chooseFromList loc rec =
        let
            accessors =
                case loc of
                    First ->
                        [ .a, .b ]

                    Second ->
                        [ .b, .a ]
        in
        case accessors of
            f :: _ ->
                f rec

            [] ->
                0

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
-- C1-C3: If-selected accessors in a triple, a list and a custom type
-- ============================================================================


{-| Returns the three cases that choose accessors with an `if` and keep them in a
triple, a list or a `Getter`, bound to `expectFn`.
-}
ifContainerCases : (Src.Module -> Expectation) -> List TestCase
ifContainerCases expectFn =
    [ { label = "If-selected accessors in tuple3", run = ifAccessorTuple3 expectFn }
    , { label = "If-selected accessors in list", run = ifAccessorList expectFn }
    , { label = "If-selected accessor in custom type", run = ifAccessorCustomType expectFn }
    ]


{-| Returns the check that hands `expectFn` a module with this function, and a
`testValue` of `choose3If True False { a = 10, b = 20, c = 30 }`:

    choose3If : Bool -> Bool -> { a : Int, b : Int, c : Int } -> Int
    choose3If x y rec =
        let
            ( f, g, h ) =
                if x then
                    if y then
                        ( .a, .b, .c )

                    else
                        ( .c, .b, .a )

                else if y then
                    ( .b, .a, .c )

                else
                    ( .c, .a, .b )
        in
        f rec

The code above shows `else if y then`, the only layout elm-format keeps, but the
inner `if` sits directly in the else branch of the outer `if` rather than
forming an `else if` chain: it is a separate `if`, not a second condition and
branch of the outer one.

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


{-| Returns the check that hands `expectFn` a module with this function, and a
`testValue` of `chooseListIf True { a = 10, b = 20 }`:

    chooseListIf : Bool -> { a : Int, b : Int } -> Int
    chooseListIf flag rec =
        let
            accessors =
                if flag then
                    [ .a, .b ]

                else
                    [ .b, .a ]
        in
        case accessors of
            f :: _ ->
                f rec

            [] ->
                0

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


{-| Returns the check that hands `expectFn` a module declaring `Getter`, with
this function and a `testValue` of `chooseGetterIf True { a = 10, b = 20 }`:

    chooseGetterIf : Bool -> { a : Int, b : Int } -> Int
    chooseGetterIf flag rec =
        let
            (MkGetter g) =
                if flag then
                    MkGetter .a

                else
                    MkGetter .b
        in
        g rec

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
