module Compiler.MonoOpt.NullableMaybeRunTest exposing (suite)

{-| Tests for the pass of `Compiler.MonoOpt.NullableMaybe` (plans/constructor-representation-levels.md
§7, N1a and N1b), on a program monomorphized with the representation passes
off:

    type alias Rec = { n : Int }
    type Opt = None | Some Rec

    get m = case m of Just r -> r.n ; Nothing -> 0          -- m : Maybe Rec
    both p = case p of ( Just a, Just b ) -> a.n + b.n ; _ -> 0
    opt o = case o of Some r -> r.n ; None -> -1
    pairOr p = case p of ( Just a, Just b ) -> a.n + b.n ; _ -> List.foldl (\x acc -> x + acc) 0 [ 1 ]

The tests establish:

  - `Maybe Rec` is made nullable, and every decision-tree test of `Just` on a
    nullable value is rewritten: afterwards the graph tests `Nothing` on it and
    never `Just` (including inside the pair's chain of tests);
  - with `userTypes`, the Maybe-shaped `Opt`, whose field is a record, is made
    nullable with the constant-bit test, and its `Some` tests are gone too;
  - without `userTypes` it is left alone;
  - the exclusion by views: a meet of `Maybe Rec` with any other view (here a
    `Maybe` of a type variable) excludes it, and then nothing is rewritten;
  - rewriting a chain of two tests into nested chains duplicates no lambda: the
    fallback of `pairOr`, reached from both nested chains, holds a closure, and
    after the pass no lambda id occurs more often than before (two copies of
    one lambda id are two lambdas once later passes transform them apart,
    which MONO_019 forbids).

-}

import Array
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , accessExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , negateExpr
        , lambdaExpr
        , listExpr
        , pAnything
        , pCtor
        , qualVarExpr
        , pTuple
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.DecisionTree.Test as DTest
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as Traverse
import Compiler.IR.Source as Src
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Compiler.Monomorphize.RepresentationMeets as RepresentationMeets
import Data.NonEmptyList as NE
import Dict
import Expect
import Test exposing (Test, describe, test)
import TestLogic.TestPipeline as Pipeline


tInt : Src.Type
tInt =
    tType "Int" []


tRec : Src.Type
tRec =
    tRecord [ ( "n", tInt ) ]


program : Src.Module
program =
    let
        optUnion : UnionDef
        optUnion =
            { name = "Opt", args = [], ctors = [ { name = "None", args = [] }, { name = "Some", args = [ tRec ] } ] }

        get : TypedDef
        get =
            { name = "get"
            , args = [ pVar "m" ]
            , tipe = tLambda (tType "Maybe" [ tRec ]) tInt
            , body = caseExpr (varExpr "m") [ ( pCtor "Just" [ pVar "r" ], accessExpr (varExpr "r") "n" ), ( pCtor "Nothing" [], intExpr 0 ) ]
            }

        both : TypedDef
        both =
            { name = "both"
            , args = [ pVar "p" ]
            , tipe = tLambda (tTuple (tType "Maybe" [ tRec ]) (tType "Maybe" [ tRec ])) tInt
            , body =
                caseExpr (varExpr "p")
                    [ ( pTuple (pCtor "Just" [ pVar "a" ]) (pCtor "Just" [ pVar "b" ])
                      , binopsExpr [ ( accessExpr (varExpr "a") "n", "+" ) ] (accessExpr (varExpr "b") "n")
                      )
                    , ( pAnything, intExpr 0 )
                    ]
            }

        opt : TypedDef
        opt =
            { name = "opt"
            , args = [ pVar "o" ]
            , tipe = tLambda (tType "Opt" []) tInt
            , body = caseExpr (varExpr "o") [ ( pCtor "Some" [ pVar "r" ], accessExpr (varExpr "r") "n" ), ( pCtor "None" [], negateExpr (intExpr 1) ) ]
            }

        pairOr : TypedDef
        pairOr =
            { name = "pairOr"
            , args = [ pVar "p" ]
            , tipe = tLambda (tTuple (tType "Maybe" [ tRec ]) (tType "Maybe" [ tRec ])) tInt
            , body =
                caseExpr (varExpr "p")
                    [ ( pTuple (pCtor "Just" [ pVar "a" ]) (pCtor "Just" [ pVar "b" ])
                      , binopsExpr [ ( accessExpr (varExpr "a") "n", "+" ) ] (accessExpr (varExpr "b") "n")
                      )
                    , ( pAnything
                      , callExpr (qualVarExpr "List" "foldl")
                            [ lambdaExpr [ pVar "x", pVar "acc" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc"))
                            , intExpr 0
                            , listExpr [ intExpr 1 ]
                            ]
                      )
                    ]
            }

        rec n =
            recordExpr [ ( "n", intExpr n ) ]

        testValue : TypedDef
        testValue =
            { name = "testValue"
            , args = []
            , tipe = tInt
            , body =
                binopsExpr
                    [ ( callExpr (varExpr "get") [ callExpr (ctorExpr "Just") [ rec 1 ] ], "+" )
                    , ( callExpr (varExpr "both") [ tupleExpr (callExpr (ctorExpr "Just") [ rec 2 ]) (ctorExpr "Nothing") ], "+" )
                    ]
                    (binopsExpr [ ( callExpr (varExpr "opt") [ callExpr (ctorExpr "Some") [ rec 3 ] ], "+" ) ]
                        (callExpr (varExpr "pairOr") [ tupleExpr (ctorExpr "Nothing") (callExpr (ctorExpr "Just") [ rec 4 ]) ])
                    )
            }
    in
    makeModuleWithTypedDefsUnionsAliases "TestMod" [ get, both, opt, pairOr, testValue ] [ optUnion ] []


maybeRec : Mono.MonoType
maybeRec =
    Mono.mCustom ModuleName.maybe "Maybe" [ Mono.mRecord (Dict.fromList [ ( "n", Mono.MInt ) ]) ]


{-| The constructor names tested in every decision tree of the graph.
-}
testedCtors : Mono.MonoGraph -> List String
testedCtors (Mono.MonoGraph g) =
    let
        fromDecider d acc =
            case d of
                Mono.Leaf _ ->
                    acc

                Mono.Chain tests s f ->
                    NE.toList tests
                        |> List.foldl
                            (\( _, t ) a ->
                                case t of
                                    DTest.IsCtor _ name _ _ _ ->
                                        name :: a

                                    _ ->
                                        a
                            )
                            (fromDecider f (fromDecider s acc))

                Mono.FanOut _ edges fb ->
                    NE.toList edges
                        |> List.foldl
                            (\( t, sub ) a ->
                                fromDecider sub
                                    (case t of
                                        DTest.FCtor _ name _ _ _ ->
                                            name :: a

                                        _ ->
                                            a
                                    )
                            )
                            (fromDecider fb acc)
    in
    Array.toList g.nodes
        |> List.filterMap identity
        |> List.concatMap
            (\node ->
                case node of
                    Mono.MonoDefine e _ ->
                        Traverse.foldExpr
                            (\sub acc ->
                                case sub of
                                    Mono.MonoCase _ _ d _ _ ->
                                        fromDecider d acc

                                    _ ->
                                        acc
                            )
                            []
                            e

                    _ ->
                        []
            )


run : { userTypes : Bool } -> List RepresentationMeets.Meet -> (Mono.MonoGraph -> Mono.MonoGraph -> Expect.Expectation) -> () -> Expect.Expectation
run opts meets check _ =
    case Pipeline.runToMonoWith (Pipeline.withoutReprPasses Pipeline.productionConfig) program of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { globalTypeEnv, monoGraph } ->
            let
                ( g1, _ ) =
                    NullableMaybe.run opts (KernelVisible.compute globalTypeEnv monoGraph) meets monoGraph
            in
            check monoGraph g1


{-| The lambda ids of every closure in the graph, one entry per closure.
-}
closureIds : Mono.MonoGraph -> List Mono.LambdaId
closureIds (Mono.MonoGraph g) =
    let
        inExpr e acc =
            case e of
                Mono.MonoClosure info _ _ ->
                    info.lambdaId :: acc

                _ ->
                    acc

        nodeExprs node =
            case node of
                Mono.MonoDefine e _ ->
                    [ e ]

                Mono.MonoTailFunc _ e _ ->
                    [ e ]

                Mono.MonoPortIncoming e _ ->
                    [ e ]

                Mono.MonoPortOutgoing e _ ->
                    [ e ]

                _ ->
                    []
    in
    Array.toList g.nodes
        |> List.filterMap identity
        |> List.concatMap nodeExprs
        |> List.concatMap (Traverse.foldExpr inExpr [])


{-| The lambda ids that occur more often in `after` than in `before`.
-}
duplicatedLambdas : Mono.MonoGraph -> Mono.MonoGraph -> List Mono.LambdaId
duplicatedLambdas before after =
    let
        count id ids =
            List.length (List.filter (\x -> x == id) ids)

        b =
            closureIds before

        a =
            closureIds after
    in
    List.filter (\id -> count id a > count id b) a


nullableNames : Mono.MonoGraph -> List String
nullableNames (Mono.MonoGraph g) =
    Mono.layoutMapValues g.repr.nullable |> List.map .valueCtor


suite : Test
suite =
    describe "Compiler.MonoOpt.NullableMaybe (the pass)"
        [ test "Maybe Rec is nullable and its Just tests become Nothing tests" <|
            run { userTypes = False }
                []
                (\before after ->
                    Expect.all
                        [ \_ -> Expect.equal (List.member "Just" (testedCtors before)) True
                        , \_ -> Expect.equal (List.member "Just" (testedCtors after)) False
                        , \_ -> Expect.equal (List.member "Nothing" (testedCtors after)) True
                        , \_ -> Expect.equal (List.member "Just" (nullableNames after)) True
                        , \_ -> Expect.equal (List.member "Some" (nullableNames after)) False
                        ]
                        ()
                )
        , test "with userTypes the Maybe-shaped Opt is nullable with a null-cons null word" <|
            run { userTypes = True }
                []
                (\_ (Mono.MonoGraph g) ->
                    let
                        opts =
                            Mono.layoutMapValues g.repr.nullable |> List.filter (\i -> i.valueCtor == "Some")
                    in
                    Expect.all
                        [ \_ -> Expect.equal (List.map (.nullWord >> .nullCons) opts) [ True ]
                        , \_ -> Expect.equal (List.member "Some" (testedCtors (Mono.MonoGraph g))) False
                        ]
                        ()
                )
        , test "a meet with another view excludes the type, and nothing is rewritten" <|
            run { userTypes = False }
                [ { a = maybeRec, b = Mono.mCustom ModuleName.maybe "Maybe" [ Mono.MVar TypeIds.firstMVarId Mono.CEcoValue ], root = True, spec = 0, site = "test", via = RepresentationMeets.ViaOther } ]
                (\before after ->
                    Expect.all
                        [ \_ -> Expect.equal (nullableNames after) []
                        , \_ -> Expect.equal (testedCtors after) (testedCtors before)
                        ]
                        ()
                )
        , test "Maybe Rec only moved through a listed kernel alias's type variable stays nullable (F4)" <|
            run { userTypes = False }
                -- The meets `splitAt` builds for `List (Maybe Rec)` used as the alias's `List a`.
                [ { a = Mono.mList maybeRec, b = Mono.mList (Mono.MVar TypeIds.firstMVarId Mono.CEcoValue), root = True, spec = 0, site = "global->1", via = RepresentationMeets.ViaKernelAlias "List" "append" }
                , { a = maybeRec, b = Mono.MVar TypeIds.firstMVarId Mono.CEcoValue, root = False, spec = 0, site = "global->1", via = RepresentationMeets.ViaKernelAlias "List" "append" }
                ]
                (\_ after -> Expect.equal (List.member "Just" (nullableNames after)) True)
        , test "Maybe Rec met as Maybe a through a listed kernel alias is excluded" <|
            run { userTypes = False }
                [ { a = maybeRec, b = Mono.mCustom ModuleName.maybe "Maybe" [ Mono.MVar TypeIds.firstMVarId Mono.CEcoValue ], root = True, spec = 0, site = "global->1", via = RepresentationMeets.ViaKernelAlias "List" "append" } ]
                (\_ after -> Expect.equal (nullableNames after) [])
        , test "splitting a chain of tests duplicates no lambda (MONO_019)" <|
            run { userTypes = False }
                []
                (\before after ->
                    Expect.all
                        [ \_ -> Expect.equal (List.member "Just" (nullableNames after)) True
                        , \_ -> Expect.equal (duplicatedLambdas before after) []
                        ]
                        ()
                )
        ]
