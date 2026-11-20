module SourceIR.WrapperCases exposing (expectSuite)

{-| Source programs built around the shapes the representation passes of
plans/constructor-representation-levels.md change: wrapper types (one
constructor of one field, which `EraseWrappers` represents as the field), `Maybe`
of a record and a Maybe-shaped user type (which `NullableMaybe` represents as
the payload), and a constructor value cased where it is built (which
`KnownCtorCase` folds). They are the E2E fixtures `test/elm/src/EraseWrapper*Test.elm`
and `Nullable*Test.elm` in miniature, run through every check of the standard
suites.

This module only builds the programs. `expectSuite` hands them, in order, to
the expectation function its caller supplies, stopping at the first that
fails. Every program is a module named `TestMod` built with
`makeModuleWithTypedDefsUnionsAliases`, whose `testValue` uses every
definition.

The cases:

  - `Float wrapper in containers`: `type Q = Q Float` in a list, a record field
    and a lambda capture, folded with a function that unwraps both arguments.
  - `Function wrapper`: `type P = P (Int -> Int)`, built from a lambda, mapped
    by a function that unwraps it in its parameter pattern, and applied.
  - `Polymorphic wrapper`: `type Box a = Box a` at `Int` and at a record,
    unwrapped by a polymorphic function.
  - `Recursive wrapper`: `type T = T (List T)`, counted recursively (a cycle,
    which `EraseWrappers` must leave alone).
  - `Nested wrapper`: `Box (Box Int)`.
  - `Maybe of a record`: built with `Just` and `Nothing`, matched, mapped and
    defaulted.
  - `Maybe-shaped user type`: `type Opt = None | Some { n : Int }`, matched.
  - `Known constructor case`: a `case` on a value built by a constructor in the
    same `let`.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , floatExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCtor
        , pVar
        , qualVarExpr
        , recordExpr
        , tLambda
        , tRecord
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Applies `expectFn` to every program of the module, reporting the first
failure under the name built from `condStr`.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Wrapper and Maybe representations " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Float wrapper in containers", run = \_ -> expectFn floatWrapper }
    , { label = "Function wrapper", run = \_ -> expectFn functionWrapper }
    , { label = "Polymorphic wrapper", run = \_ -> expectFn polyWrapper }
    , { label = "Recursive wrapper", run = \_ -> expectFn recursiveWrapper }
    , { label = "Nested wrapper", run = \_ -> expectFn nestedWrapper }
    , { label = "Maybe of a record", run = \_ -> expectFn maybeRecord }
    , { label = "Maybe-shaped user type", run = \_ -> expectFn maybeShaped }
    , { label = "Known constructor case", run = \_ -> expectFn knownCtor }
    ]


tInt : Src.Type
tInt =
    tType "Int" []


tFloat : Src.Type
tFloat =
    tType "Float" []


tRec : Src.Type
tRec =
    tRecord [ ( "n", tInt ) ]


wrapper : String -> Src.Type -> UnionDef
wrapper name field =
    { name = name, args = [], ctors = [ { name = name, args = [ field ] } ] }


testValueOf : Src.Type -> Src.Expr -> TypedDef
testValueOf tipe body =
    { name = "testValue", args = [], tipe = tipe, body = body }


{-|

    type Q = Q Float
    addQ (Q a) (Q b) = Q (a + b)
    testValue = case List.foldl addQ (Q 0) [ Q 1.5, (\(Q x) -> Q x) (Q 2) ] of Q x -> x

-}
floatWrapper : Src.Module
floatWrapper =
    let
        addQ : TypedDef
        addQ =
            { name = "addQ"
            , args = [ pCtor "Q" [ pVar "a" ], pCtor "Q" [ pVar "b" ] ]
            , tipe = tLambda (tType "Q" []) (tLambda (tType "Q" []) (tType "Q" []))
            , body = callExpr (ctorExpr "Q") [ binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b") ]
            }

        q x =
            callExpr (ctorExpr "Q") [ floatExpr x ]

        holder =
            recordExpr [ ( "q", q 0.5 ) ]
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ addQ
        , testValueOf tFloat
            (caseExpr
                (callExpr (qualVarExpr "List" "foldl")
                    [ varExpr "addQ"
                    , accessExpr holder "q"
                    , listExpr [ q 1.5, callExpr (lambdaExpr [ pCtor "Q" [ pVar "x" ] ] (callExpr (ctorExpr "Q") [ varExpr "x" ])) [ q 2 ] ]
                    ]
                )
                [ ( pCtor "Q" [ pVar "r" ], varExpr "r" ) ]
            )
        ]
        [ wrapper "Q" tFloat ]
        []


{-|

    type P = P (Int -> Int)
    run (P f) n = f n
    twice (P f) = P (\n -> f (f n))
    testValue = run (twice (P (\n -> n + 1))) 3

-}
functionWrapper : Src.Module
functionWrapper =
    let
        tP =
            tType "P" []

        runDef : TypedDef
        runDef =
            { name = "run", args = [ pCtor "P" [ pVar "f" ], pVar "n" ], tipe = tLambda tP (tLambda tInt tInt), body = callExpr (varExpr "f") [ varExpr "n" ] }

        twiceDef : TypedDef
        twiceDef =
            { name = "twice"
            , args = [ pCtor "P" [ pVar "f" ] ]
            , tipe = tLambda tP tP
            , body = callExpr (ctorExpr "P") [ lambdaExpr [ pVar "n" ] (callExpr (varExpr "f") [ callExpr (varExpr "f") [ varExpr "n" ] ]) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ runDef
        , twiceDef
        , testValueOf tInt
            (callExpr (varExpr "run")
                [ callExpr (varExpr "twice") [ callExpr (ctorExpr "P") [ lambdaExpr [ pVar "n" ] (binopsExpr [ ( varExpr "n", "+" ) ] (intExpr 1)) ] ]
                , intExpr 3
                ]
            )
        ]
        [ wrapper "P" (tLambda tInt tInt) ]
        []


{-|

    type Box a = Box a
    unbox (Box a) = a
    testValue = unbox (Box 1) + (unbox (Box { n = 2 })).n

-}
polyWrapper : Src.Module
polyWrapper =
    let
        unbox : TypedDef
        unbox =
            { name = "unbox", args = [ pCtor "Box" [ pVar "a" ] ], tipe = tLambda (tType "Box" [ tVar "a" ]) (tVar "a"), body = varExpr "a" }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ unbox
        , testValueOf tInt
            (binopsExpr [ ( callExpr (varExpr "unbox") [ callExpr (ctorExpr "Box") [ intExpr 1 ] ], "+" ) ]
                (accessExpr (callExpr (varExpr "unbox") [ callExpr (ctorExpr "Box") [ recordExpr [ ( "n", intExpr 2 ) ] ] ]) "n")
            )
        ]
        [ { name = "Box", args = [ "a" ], ctors = [ { name = "Box", args = [ tVar "a" ] } ] } ]
        []


{-|

    type T = T (List T)
    size (T kids) = List.foldl (\k acc -> acc + size k) 1 kids
    testValue = size (T [ T [], T [] ])

-}
recursiveWrapper : Src.Module
recursiveWrapper =
    let
        tT =
            tType "T" []

        size : TypedDef
        size =
            { name = "size"
            , args = [ pCtor "T" [ pVar "kids" ] ]
            , tipe = tLambda tT tInt
            , body =
                callExpr (qualVarExpr "List" "foldl")
                    [ lambdaExpr [ pVar "k", pVar "acc" ] (binopsExpr [ ( varExpr "acc", "+" ) ] (callExpr (varExpr "size") [ varExpr "k" ]))
                    , intExpr 1
                    , varExpr "kids"
                    ]
            }

        t kids =
            callExpr (ctorExpr "T") [ listExpr kids ]
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ size, testValueOf tInt (callExpr (varExpr "size") [ t [ t [], t [] ] ]) ]
        [ wrapper "T" (tType "List" [ tT ]) ]
        []


{-|

    type Box a = Box a
    testValue = case Box (Box 7) of Box (Box n) -> n

-}
nestedWrapper : Src.Module
nestedWrapper =
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ testValueOf tInt
            (caseExpr (callExpr (ctorExpr "Box") [ callExpr (ctorExpr "Box") [ intExpr 7 ] ])
                [ ( pCtor "Box" [ pCtor "Box" [ pVar "n" ] ], varExpr "n" ) ]
            )
        ]
        [ { name = "Box", args = [ "a" ], ctors = [ { name = "Box", args = [ tVar "a" ] } ] } ]
        []


{-|

    get : Maybe { n : Int } -> Int
    get m = case m of Just r -> r.n ; Nothing -> 0
    testValue = get (Just { n = 3 }) + get Nothing + (case Just { n = 4 } of Just q -> q.n ; _ -> 0)

-}
maybeRecord : Src.Module
maybeRecord =
    let
        get : TypedDef
        get =
            { name = "get"
            , args = [ pVar "m" ]
            , tipe = tLambda (tType "Maybe" [ tRec ]) tInt
            , body = caseExpr (varExpr "m") [ ( pCtor "Just" [ pVar "r" ], accessExpr (varExpr "r") "n" ), ( pCtor "Nothing" [], intExpr 0 ) ]
            }

        just n =
            callExpr (ctorExpr "Just") [ recordExpr [ ( "n", intExpr n ) ] ]
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ get
        , testValueOf tInt
            (binopsExpr
                [ ( callExpr (varExpr "get") [ just 3 ], "+" )
                , ( callExpr (varExpr "get") [ ctorExpr "Nothing" ], "+" )
                ]
                (caseExpr (just 4) [ ( pCtor "Just" [ pVar "q" ], accessExpr (varExpr "q") "n" ), ( pAnything, intExpr 0 ) ])
            )
        ]
        []
        []


{-|

    type Opt = None | Some { n : Int }
    opt o = case o of Some r -> r.n ; None -> 0
    testValue = opt (Some { n = 5 }) + opt None

-}
maybeShaped : Src.Module
maybeShaped =
    let
        opt : TypedDef
        opt =
            { name = "opt"
            , args = [ pVar "o" ]
            , tipe = tLambda (tType "Opt" []) tInt
            , body = caseExpr (varExpr "o") [ ( pCtor "Some" [ pVar "r" ], accessExpr (varExpr "r") "n" ), ( pCtor "None" [], intExpr 0 ) ]
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ opt
        , testValueOf tInt
            (binopsExpr [ ( callExpr (varExpr "opt") [ callExpr (ctorExpr "Some") [ recordExpr [ ( "n", intExpr 5 ) ] ] ], "+" ) ]
                (callExpr (varExpr "opt") [ ctorExpr "None" ])
            )
        ]
        [ { name = "Opt", args = [], ctors = [ { name = "None", args = [] }, { name = "Some", args = [ tRec ] } ] } ]
        []


{-|

    type Work = WorkA Int | Idle
    direct x = let w = WorkA x in case w of WorkA n -> n ; Idle -> 0
    testValue = direct 6

-}
knownCtor : Src.Module
knownCtor =
    let
        direct : TypedDef
        direct =
            { name = "direct"
            , args = [ pVar "x" ]
            , tipe = tLambda tInt tInt
            , body =
                letExpr [ define "w" [] (callExpr (ctorExpr "WorkA") [ varExpr "x" ]) ]
                    (caseExpr (varExpr "w") [ ( pCtor "WorkA" [ pVar "n" ], varExpr "n" ), ( pAnything, intExpr 0 ) ])
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod"
        [ direct, testValueOf tInt (callExpr (varExpr "direct") [ intExpr 6 ]) ]
        [ { name = "Work", args = [], ctors = [ { name = "WorkA", args = [ tInt ] }, { name = "Idle", args = [] } ] } ]
        []
