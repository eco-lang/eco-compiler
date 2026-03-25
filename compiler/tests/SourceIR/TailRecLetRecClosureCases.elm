module SourceIR.TailRecLetRecClosureCases exposing (expectSuite)

{-| Tests for local recursive closures inside tail-recursive functions.

These exercise the TailRec.compileLetStep path for MonoDef closures that
are self-recursive and capture variables from the enclosing scope. This is
the pattern found in Cheapskate/Parse.elm's processElts/takeListItems.

The bug: compileLetStep for MonoDef calls Expr.generateExpr directly
without setting up currentLetSiblings or placeholder mappings, so the
PendingLambda for the closure gets empty siblingMappings. When the closure
body later tries to reference itself (for recursion), lookupVar fails with
"unbound variable".

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAnything
        , pCons
        , pCtor
        , pList
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Tail-rec with local recursive closure " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    [ { label = "Local recursive closure in tail-rec case branch", run = tailRecWithLocalRecClosure expectFn }
    , { label = "Local recursive closure capturing outer param", run = tailRecWithCapturingClosure expectFn }
    ]


{-| Reproduces the takeListItems pattern:


    type Item
        = Num Int
        | Blank

    processItems threshold items =
        case items of
            [] ->
                []

            (Num n) :: rest ->
                let
                    takeMore xs =
                        case xs of
                            (Num m) :: ys ->
                                m :: takeMore ys

                            _ ->
                                []

                    collected =
                        takeMore rest
                in
                n :: collected

            Blank :: rest ->
                processItems threshold rest

    -- tail call

The function is tail-recursive (Blank branch), with a local recursive
closure (takeMore) defined inside a let in the non-tail Num branch.

-}
tailRecWithLocalRecClosure : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecWithLocalRecClosure expectFn _ =
    let
        unions : List UnionDef
        unions =
            [ { name = "Item"
              , args = []
              , ctors =
                    [ { name = "Num", args = [ tType "Int" [] ] }
                    , { name = "Blank", args = [] }
                    ]
              }
            ]

        -- takeMore : List Item -> List Int
        -- takeMore xs = case xs of
        --     (Num m) :: ys -> m :: takeMore ys
        --     _ -> []
        takeMoreBody =
            caseExpr (varExpr "xs")
                [ ( pCons (pCtor "Num" [ pVar "m" ]) (pVar "ys")
                  , binopsExpr
                        [ ( varExpr "m", "::" ) ]
                        (callExpr (varExpr "takeMore") [ varExpr "ys" ])
                  )
                , ( pAnything, listExpr [] )
                ]

        takeMoreDef =
            define "takeMore" [ pVar "xs" ] takeMoreBody

        -- collected = takeMore rest
        collectedDef =
            define "collected" [] (callExpr (varExpr "takeMore") [ varExpr "rest" ])

        -- processItems : Int -> List Item -> List Int
        -- processItems threshold items = case items of ...
        processItemsBody =
            caseExpr (varExpr "items")
                [ -- [] -> []
                  ( pList [], listExpr [] )
                , -- (Num n) :: rest -> let takeMore = ...; collected = takeMore rest in n :: collected
                  ( pCons (pCtor "Num" [ pVar "n" ]) (pVar "rest")
                  , letExpr [ takeMoreDef, collectedDef ]
                        (binopsExpr [ ( varExpr "n", "::" ) ] (varExpr "collected"))
                  )
                , -- Blank :: rest -> processItems threshold rest  (tail call!)
                  ( pCons (pCtor "Blank" []) (pVar "rest")
                  , callExpr (varExpr "processItems") [ varExpr "threshold", varExpr "rest" ]
                  )
                ]

        typedDefs : List TypedDef
        typedDefs =
            [ { name = "processItems"
              , tipe =
                    tLambda (tType "Int" [])
                        (tLambda (tType "List" [ tType "Item" [] ])
                            (tType "List" [ tType "Int" [] ])
                        )
              , args = [ pVar "threshold", pVar "items" ]
              , body = processItemsBody
              }
            ]

        testValueDef : TypedDef
        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tType "List" [ tType "Int" [] ]
            , body =
                callExpr (varExpr "processItems")
                    [ intExpr 0
                    , listExpr
                        [ callExpr (ctorExpr "Num") [ intExpr 1 ]
                        , callExpr (ctorExpr "Num") [ intExpr 2 ]
                        , ctorExpr "Blank"
                        ]
                    ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                (typedDefs ++ [ testValueDef ])
                unions
                []
    in
    expectFn modul


{-| Simpler variant: the local recursive closure captures a parameter
from the enclosing tail-recursive function.


    process threshold items =
        case items of
            [] ->
                []

            x :: rest ->
                let
                    helper ys =
                        case ys of
                            y :: zs ->
                                y :: helper zs

                            _ ->
                                []
                in
                x :: helper rest

            _ ->
                process threshold []

    -- tail call

The helper closure captures nothing extra here but is self-recursive
inside a let within a non-tail branch of a tail-recursive function.

-}
tailRecWithCapturingClosure : (Src.Module -> Expectation) -> (() -> Expectation)
tailRecWithCapturingClosure expectFn _ =
    let
        -- helper ys = case ys of
        --     y :: zs -> y :: helper zs
        --     _ -> []
        helperBody =
            caseExpr (varExpr "ys")
                [ ( pCons (pVar "y") (pVar "zs")
                  , binopsExpr
                        [ ( varExpr "y", "::" ) ]
                        (callExpr (varExpr "helper") [ varExpr "zs" ])
                  )
                , ( pAnything, listExpr [] )
                ]

        helperDef =
            define "helper" [ pVar "ys" ] helperBody

        processBody =
            caseExpr (varExpr "items")
                [ -- [] -> []
                  ( pList [], listExpr [] )
                , -- x :: rest -> let helper = ... in x :: helper rest
                  ( pCons (pVar "x") (pVar "rest")
                  , letExpr [ helperDef ]
                        (binopsExpr
                            [ ( varExpr "x", "::" ) ]
                            (callExpr (varExpr "helper") [ varExpr "rest" ])
                        )
                  )
                , -- _ -> process threshold []  (tail call!)
                  ( pAnything
                  , callExpr (varExpr "process") [ varExpr "threshold", listExpr [] ]
                  )
                ]

        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "process"
                  , tipe =
                        tLambda (tType "Int" [])
                            (tLambda (tType "List" [ tType "Int" [] ])
                                (tType "List" [ tType "Int" [] ])
                            )
                  , args = [ pVar "threshold", pVar "items" ]
                  , body = processBody
                  }
                , { name = "testValue"
                  , args = []
                  , tipe = tType "List" [ tType "Int" [] ]
                  , body =
                        callExpr (varExpr "process")
                            [ intExpr 0
                            , listExpr [ intExpr 1, intExpr 2, intExpr 3 ]
                            ]
                  }
                ]
                []
                []
    in
    expectFn modul
