module TestLogic.GlobalOpt.EtaExpandTest exposing (suite)

{-| Test suite for PRE-monomorphization η-expansion
(`plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md` §5).

The pass runs on the `TOpt.GlobalGraph MVarId` that
`Builder.Generate.runMonoOptPipeline` hands it, so every fixture goes through
`Pipeline.runToAssigned` and calls `EtaExpand.run` directly — the same route
`InlineSimplifyTest` takes.

Every fixture declares a state-monad alias `St a = Int -> ( Int, a )`, because
the whole point of the transform is arity that only the ALIAS knows about: a
definition annotated `St Int` looks like a value and is a one-parameter
function.

What is pinned:

  - F1 a two-of-three `andThen` chain saturates: the node gains a parameter,
    the call reaches three arguments, and the continuation gains its own;
  - F2/F3 the definition rule at full and partial syntactic arity;
  - F4 a continuation that is ALREADY saturated is left alone;
  - F5 a Cycle member expands and BOTH `case` branches are saturated (R8 — a
    missed `jumps` entry leaves one branch holding the un-applied PAP);
  - F6 a `TailDef` is declined and its body is untouched;
  - F7/F8 the cheapness gate: an expensive `let`, and the `Debug.log` ordering
    pin;
  - F9 a type with no arrow spine is never touched;
  - the pass is inert with the flag off, and `bodiesSeen` is never zero.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCons
        , pList
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.PreMono.EtaExpand as EtaExpand
import Compiler.Reporting.Annotation as A
import Data.Map
import Dict as CoreDict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "EtaExpand (pre-mono)"
        [ denominatorSuite
        , definitionSuite
        , continuationSuite
        , cycleSuite
        , gateSuite
        , scopeSuite
        , inertSuite
        ]



-- ============================================================================
-- THE DENOMINATOR
-- ============================================================================


denominatorSuite : Test
denominatorSuite =
    Test.describe "Denominator"
        [ Test.test "the pass examines top-level bodies at all" <|
            \_ ->
                -- `defs = 0` reads identically whether the pass refused
                -- everything or matched no node shape at all. This is the
                -- counter that separates them, and it is the pre-mono
                -- inliner's lesson written down as a test.
                withMetrics chainModule
                    (\m ->
                        if m.bodiesSeen > 0 then
                            Expect.pass

                        else
                            Expect.fail "EtaExpand matched no top-level body"
                    )
        ]



-- ============================================================================
-- F1-F3: THE DEFINITION RULE (§2.2)
-- ============================================================================


definitionSuite : Test
definitionSuite =
    Test.describe "Definition rule"
        [ Test.test "F1: a 2-of-3 andThen chain gains the state parameter" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal (Just 1) (nodeParamCount g "prog"))
        , Test.test "F1: the andThen call reaches three arguments" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal (Just 3) (List.head (callArgCounts g "prog")))
        , Test.test "F1: the continuation gains its own state parameter" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal [ 2 ] (lambdaParamCounts g "prog"))
        , Test.test "F1: one definition and one continuation are counted" <|
            \_ ->
                withMetrics chainModule
                    (\m -> Expect.equal ( 1, 1 ) ( m.defs, m.conts ))
        , Test.test "F1: the merge is counted" <|
            \_ ->
                withMetrics chainModule
                    (\m ->
                        if m.merged > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the new argument to MERGE into the andThen call"
                    )
        , Test.test "F2: a bare global of alias-arrow type becomes a lambda" <|
            \_ ->
                withGraph bareGlobalModule
                    (\g -> Expect.equal (Just 1) (nodeParamCount g "d"))
        , Test.test "F2: the bare global's reference becomes a saturated call" <|
            \_ ->
                withGraph bareGlobalModule
                    (\g -> Expect.equal (Just 1) (List.head (callArgCounts g "d")))
        , Test.test "F3: partial syntactic arity is topped up, not replaced" <|
            \_ ->
                -- `d : Int -> St Int` written with ONE parameter declares two.
                withGraph partialArityModule
                    (\g -> Expect.equal (Just 2) (nodeParamCount g "d"))
        ]



-- ============================================================================
-- F4: THE CONTINUATION RULE (§2.3)
-- ============================================================================


continuationSuite : Test
continuationSuite =
    Test.describe "Continuation rule"
        [ Test.test "F4: an already-saturated continuation is left alone" <|
            \_ ->
                withMetrics saturatedContModule (\m -> Expect.equal 0 m.conts)
        , Test.test "F4: an already-saturated continuation keeps two parameters" <|
            \_ ->
                withGraph saturatedContModule
                    (\g -> Expect.equal [ 2 ] (lambdaParamCounts g "prog"))
        ]



-- ============================================================================
-- F5/F6: CYCLE MEMBERS (§2.6)
-- ============================================================================


cycleSuite : Test
cycleSuite =
    Test.describe "Cycle members"
        [ Test.test "F5: a recursive sequence-shaped definition expands" <|
            \_ ->
                withMetrics sequenceModule
                    (\m ->
                        if m.cycleDefs > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the Cycle Def to be η-expanded"
                    )
        , Test.test "F5: EVERY case branch is saturated, jumps included (R8)" <|
            \_ ->
                -- The failure this pins: pushing the new argument into the
                -- decider's `Inline` choices but not into `jumps` leaves a
                -- SHARED branch holding the un-applied PAP while its siblings
                -- are saturated. `cycleBranchArgCounts` walks BOTH — the
                -- decider's `Inline` leaves and every `jumps` entry — and
                -- asserts no call anywhere in the expanded body still has the
                -- pre-η argument count.
                --
                -- Honest about its reach: the fixture's duplicated `pure []`
                -- branch GIVES the decision-tree builder the option of sharing
                -- a body through `jumps`, but does not force it. If it inlines
                -- both, this pins the `Inline` half only. The `jumps` half is
                -- covered end-to-end by `test/elm/src/EtaExpandStateTest.elm`,
                -- which runs the real `sequence` and prints its numbers.
                withGraph sequenceModule
                    (\g ->
                        case cycleBranchArgCounts g of
                            [] ->
                                Expect.fail "found no calls in the expanded Cycle body"

                            counts ->
                                if List.all (\n -> n >= 2) counts then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("an unsaturated branch survived: " ++ Debug.toString counts)
                    )
        , Test.test "F6: a TailDef with a deficit is declined" <|
            \_ ->
                withMetrics tailDefModule
                    (\m ->
                        if m.tailDef > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the TailDef to be counted as declined"
                    )
        ]



-- ============================================================================
-- F7/F8: THE CHEAPNESS GATE (§2.5)
-- ============================================================================


gateSuite : Test
gateSuite =
    Test.describe "Cheapness gate"
        [ Test.test "F7: an expensive let-bound value is declined" <|
            \_ ->
                withMetrics expensiveLetModule
                    (\m ->
                        if m.notCheap > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the expensive `let` body to be refused"
                    )
        , Test.test "F7: the expensive definition is left as a bare value" <|
            \_ ->
                withGraph expensiveLetModule
                    (\g -> Expect.equal Nothing (nodeParamCount g "d"))
        , Test.test "F8: an over-threshold saturated call in argument position is declined" <|
            \_ ->
                withMetrics notCheapArgModule
                    (\m ->
                        if m.notCheap > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected the over-threshold argument to be refused"
                    )
        , Test.test "F8: that definition is left as a bare value" <|
            \_ ->
                withGraph notCheapArgModule
                    (\g -> Expect.equal Nothing (nodeParamCount g "d"))
        ]



-- ============================================================================
-- F9: SCOPE
-- ============================================================================


scopeSuite : Test
scopeSuite =
    Test.describe "Scope"
        [ Test.test "F9: a type with no arrow spine is declined as noSpine" <|
            \_ ->
                withMetrics noSpineModule
                    (\m ->
                        if m.noSpine > 0 then
                            Expect.pass

                        else
                            Expect.fail "expected a non-arrow definition to decline as noSpine"
                    )
        , Test.test "a kernel-alias node is refused (LSS_016)" <|
            \_ ->
                -- `List.cons = Elm.Kernel.List.cons` is in every graph the
                -- harness builds, and `LssInfer.kernelAliasOf` recognises it
                -- by the EXACT shape `Define (VarKernel …)`. This test failed
                -- before the refusal existed: the pass expanded both aliased
                -- kernels, which is a split `g|`/`k|` identity.
                withMetrics chainModule
                    (\m ->
                        if m.kernelAlias >= 2 then
                            Expect.pass

                        else
                            Expect.fail "expected the graph's kernel aliases to be refused"
                    )
        , Test.test "F9: a type with no arrow spine is never rewritten" <|
            \_ ->
                withGraph noSpineModule
                    (\g -> Expect.equal Nothing (nodeParamCount g "d"))
        , Test.test "a constructor alias is refused (ctorAlias)" <|
            \_ ->
                -- `mkU8 = U8` / `mkU32 = U32`: elm/bytes' `unsignedInt8 = U8`
                -- shape. Expanding a bare constructor buys no arity and turned
                -- a non-inlinable CAF-alias call into an inlinable one that
                -- hid the constructor from bytes fusion's name-keyed
                -- recogniser (FusionGlobalMapFnTest, 2026-09-11).
                withMetrics ctorAliasModule
                    (\m ->
                        if m.ctorAlias >= 2 then
                            Expect.pass

                        else
                            Expect.fail ("expected both constructor aliases to be refused, ctorAlias=" ++ String.fromInt m.ctorAlias)
                    )
        , Test.test "a constructor alias is never rewritten" <|
            \_ ->
                withGraph ctorAliasModule
                    (\g -> Expect.equal ( Nothing, Nothing ) ( nodeParamCount g "mkU8", nodeParamCount g "mkU32" ))
        ]



-- ============================================================================
-- FLAG OFF
-- ============================================================================


inertSuite : Test
inertSuite =
    Test.describe "Flag off"
        [ Test.test "with etaExpand off the graph comes back untouched" <|
            \_ ->
                case Pipeline.runToAssigned chainModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( after, _, _ ) =
                                EtaExpand.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal
                            (nodeParamCount assigned.graph "prog")
                            (nodeParamCount after "prog")
        , Test.test "with etaExpand off the census still classifies" <|
            \_ ->
                -- Census mode: the classifier runs, the graph does not move.
                case Pipeline.runToAssigned chainModule of
                    Err msg ->
                        Expect.fail msg

                    Ok assigned ->
                        let
                            ( _, _, m ) =
                                EtaExpand.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal ( 1, 1 ) ( m.defs, m.conts )
        ]



-- ============================================================================
-- HARNESS
-- ============================================================================


etaConfig : Config.InlineConfig
etaConfig =
    { defaultInline | etaExpand = True }


defaultInline : Config.InlineConfig
defaultInline =
    Config.default.inline


{-| The flag-off configuration. `etaExpand` is DEFAULT-ON since 2026-09-11,
so "off" must be spelled explicitly.
-}
offInline : Config.InlineConfig
offInline =
    { defaultInline | etaExpand = False }


withMetrics : Src.Module -> (EtaExpand.Metrics -> Expect.Expectation) -> Expect.Expectation
withMetrics srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            let
                ( _, _, m ) =
                    EtaExpand.run etaConfig assigned.mvarState assigned.graph
            in
            check m


withGraph : Src.Module -> (TOpt.GlobalGraph TypeIds.MVarId -> Expect.Expectation) -> Expect.Expectation
withGraph srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            let
                ( after, _, _ ) =
                    EtaExpand.run etaConfig assigned.mvarState assigned.graph
            in
            check after



-- ====== STRUCTURAL READERS ======


nodeBody : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe (TOpt.Expr TypeIds.MVarId)
nodeBody (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl TOpt.compareGlobal
        (\(TOpt.Global _ n) node acc ->
            if n == name then
                case node of
                    TOpt.Define e _ _ ->
                        Just e

                    TOpt.TrackedDefine _ e _ _ ->
                        Just e

                    _ ->
                        acc

            else
                acc
        )
        Nothing
        nodes


{-| How many parameters the node's top-level lambda has, or `Nothing` when the
body is not a lambda at all (which is what "not expanded" looks like for a
value definition).
-}
nodeParamCount : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe Int
nodeParamCount graph name =
    case nodeBody graph name of
        Just (TOpt.Function _ ps _ _) ->
            Just (List.length ps)

        Just (TOpt.TrackedFunction _ ps _ _) ->
            Just (List.length ps)

        _ ->
            Nothing


{-| Argument counts of every `Call` in the node's body, outermost first.
-}
callArgCounts : TOpt.GlobalGraph TypeIds.MVarId -> Name -> List Int
callArgCounts graph name =
    case nodeBody graph name of
        Just body ->
            collectCalls body

        Nothing ->
            []


collectCalls : TOpt.Expr TypeIds.MVarId -> List Int
collectCalls expr =
    (case expr of
        TOpt.Call _ _ args _ ->
            [ List.length args ]

        _ ->
            []
    )
        ++ List.concatMap collectCalls (children expr)


{-| Parameter counts of every LAMBDA below the node's own top-level lambda.
-}
lambdaParamCounts : TOpt.GlobalGraph TypeIds.MVarId -> Name -> List Int
lambdaParamCounts graph name =
    case nodeBody graph name of
        Just body ->
            List.concatMap collectLambdas (children body)

        Nothing ->
            []


collectLambdas : TOpt.Expr TypeIds.MVarId -> List Int
collectLambdas expr =
    (case expr of
        TOpt.Function _ ps _ _ ->
            [ List.length ps ]

        TOpt.TrackedFunction _ ps _ _ ->
            [ List.length ps ]

        _ ->
            []
    )
        ++ List.concatMap collectLambdas (children expr)


{-| Argument counts of the calls inside the FUNCTION defs of the graph's Cycle
node — the `sequence` fixture's two `case` branches.
-}
cycleBranchArgCounts : TOpt.GlobalGraph TypeIds.MVarId -> List Int
cycleBranchArgCounts (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl TOpt.compareGlobal
        (\_ node acc ->
            case node of
                TOpt.Cycle _ _ funcDefs _ ->
                    acc
                        ++ List.concatMap
                            (\def ->
                                case def of
                                    TOpt.Def _ _ body _ ->
                                        collectCalls body

                                    TOpt.TailDef _ _ _ body _ _ ->
                                        collectCalls body
                            )
                            funcDefs

                _ ->
                    acc
        )
        []
        nodes


children : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
children expr =
    case expr of
        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ f args _ ->
            f :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ bound _ ->
                    [ bound ]

                TOpt.TailDef _ _ _ b _ _ ->
                    [ b ]
            )
                ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderChildren decider ++ List.map Tuple.second jumps

        TOpt.Access inner _ _ _ ->
            [ inner ]

        TOpt.Update _ record fields _ ->
            record :: Data.Map.values A.compareLocated fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            Data.Map.values A.compareLocated fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


deciderChildren : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId)
deciderChildren decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ ok ko ->
            deciderChildren ok ++ deciderChildren ko

        TOpt.FanOut _ branches fallback ->
            List.concatMap (\( _, d ) -> deciderChildren d) branches
                ++ deciderChildren fallback



-- ============================================================================
-- FIXTURES
-- ============================================================================
--
-- Every module is written against a state-monad-shaped alias
--
--     type alias St a = Int -> a
--
-- and its `andThen` is SATURATED in its own definition, exactly as
-- `System.TypeCheck.IO.andThen` is. A one-element state keeps the fixtures
-- free of `Tuple.first`/`Tuple.second` — `Tuple` is not in the test harness's
-- standard imports — without changing anything the transform reads: the arity
-- lives entirely in the alias, which is the whole point.
--
-- `testValue` is mandatory (`TestPipeline.wrapWithMain`) and is what keeps
-- each definition under test reachable.


{-| `type alias St a = Int -> a`
-}
stAlias : AliasDef
stAlias =
    { name = "St"
    , args = [ "a" ]
    , tipe = tLambda (tType "Int" []) (tVar "a")
    }


tSt : Src.Type -> Src.Type
tSt inner =
    tType "St" [ inner ]


tInt : Src.Type
tInt =
    tType "Int" []


{-| `andThen : (a -> St b) -> St a -> St b`, written at DECLARED arity:

    andThen f ma s0 =
        f (ma s0) s0

-}
andThenDef : TypedDef
andThenDef =
    { name = "andThen"
    , args = [ pVar "f", pVar "ma", pVar "s0" ]
    , tipe =
        tLambda (tLambda (tVar "a") (tSt (tVar "b")))
            (tLambda (tSt (tVar "a")) (tSt (tVar "b")))
    , body =
        callExpr (callExpr (varExpr "f") [ callExpr (varExpr "ma") [ varExpr "s0" ] ])
            [ varExpr "s0" ]
    }


{-| `pure : a -> St a` — `pure x s = x`.
-}
pureDef : TypedDef
pureDef =
    { name = "pure"
    , args = [ pVar "x", pVar "s" ]
    , tipe = tLambda (tVar "a") (tSt (tVar "a"))
    , body = varExpr "x"
    }


{-| `tick : St Int` — ALREADY at declared arity, so the pass has nothing to do
to it. It is the `ma` of every chain below.
-}
tickDef : TypedDef
tickDef =
    { name = "tick"
    , args = [ pVar "s" ]
    , tipe = tSt tInt
    , body = varExpr "s"
    }


{-| `plus : Int -> Int -> Int` and `expensive : Int -> Int`, the latter with a
body whose pre-mono `cost` (15) is over the default `inline.threshold` (10).
The cheapness gate's saturated-call arm is the one they exercise.
-}
plusDef : TypedDef
plusDef =
    { name = "plus"
    , args = [ pVar "a", pVar "b" ]
    , tipe = tLambda tInt (tLambda tInt tInt)
    , body = varExpr "a"
    }


expensiveDef : TypedDef
expensiveDef =
    { name = "expensive"
    , args = [ pVar "n" ]
    , tipe = tLambda tInt tInt
    , body =
        callExpr (varExpr "plus")
            [ callExpr (varExpr "plus") [ varExpr "n", varExpr "n" ], varExpr "n" ]
    }


base : List TypedDef
base =
    [ andThenDef, pureDef, tickDef, plusDef, expensiveDef ]


module_ : List TypedDef -> Src.Module
module_ defs =
    makeModuleWithTypedDefsUnionsAliases "Test" (base ++ defs) [] [ stAlias ]


{-| Constructor aliases (§2.6 addendum, 2026-09-11): `type Enc = U8 Int | U32 Int Int`,
`mkU8 = U8`, `mkU32 = U32`, both kept alive through `use`.
-}
ctorAliasModule : Src.Module
ctorAliasModule =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "mkU8"
                 , args = []
                 , tipe = tLambda tInt (tType "Enc" [])
                 , body = ctorExpr "U8"
                 }
               , { name = "mkU32"
                 , args = []
                 , tipe = tLambda tInt (tLambda tInt (tType "Enc" []))
                 , body = ctorExpr "U32"
                 }
               , { name = "use"
                 , args = [ pVar "e" ]
                 , tipe = tLambda (tType "Enc" []) tInt
                 , body = intExpr 1
                 }
               , testValueDef
                    (binopsExpr [ ( callExpr (varExpr "use") [ callExpr (varExpr "mkU8") [ intExpr 3 ] ], "+" ) ]
                        (callExpr (varExpr "use") [ callExpr (varExpr "mkU32") [ intExpr 1, intExpr 2 ] ])
                    )
               ]
        )
        [ { name = "Enc"
          , args = []
          , ctors =
                [ { name = "U8", args = [ tInt ] }
                , { name = "U32", args = [ tInt, tInt ] }
                ]
          }
        ]
        [ stAlias ]


{-| The mandatory entry, and what keeps the definition under test alive.
-}
testValueDef : Src.Expr -> TypedDef
testValueDef body =
    { name = "testValue", args = [], tipe = tInt, body = body }


{-| F1 — `prog : St Int; prog = andThen (\a -> pure a) tick`

Two of three arguments at `andThen`, and a one-parameter continuation whose
declared type `a -> St b` is arity 2. The IO-monad shape in miniature.

-}
chainModule : Src.Module
chainModule =
    module_
        [ { name = "prog"
          , args = []
          , tipe = tSt tInt
          , body =
                callExpr (varExpr "andThen")
                    [ lambdaExpr [ pVar "a" ] (callExpr (varExpr "pure") [ varExpr "a" ])
                    , varExpr "tick"
                    ]
          }
        , testValueDef (callExpr (varExpr "prog") [ intExpr 0 ])
        ]


{-| F2 — `d : St Int; d = tick`, a bare global of alias-arrow type.
-}
bareGlobalModule : Src.Module
bareGlobalModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tSt tInt
          , body = varExpr "tick"
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 0 ])
        ]


{-| F3 — `d : Int -> St Int; d n = tick`: one syntactic parameter of two
declared, so the deficit is topped up rather than the whole lambda replaced.
-}
partialArityModule : Src.Module
partialArityModule =
    module_
        [ { name = "d"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt (tSt tInt)
          , body = varExpr "tick"
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 1, intExpr 0 ])
        ]


{-| F4 — the continuation already writes both of its declared parameters, and
`prog` already writes its own, so nothing here has a deficit.
-}
saturatedContModule : Src.Module
saturatedContModule =
    module_
        [ { name = "prog"
          , args = [ pVar "s0" ]
          , tipe = tSt tInt
          , body =
                callExpr (varExpr "andThen")
                    [ lambdaExpr [ pVar "a", pVar "s1" ] (varExpr "a")
                    , varExpr "tick"
                    , varExpr "s0"
                    ]
          }
        , testValueDef (callExpr (varExpr "prog") [ intExpr 0 ])
        ]


{-| F5 — the `sequence` shape: a RECURSIVE definition at alias arity, so the
front end emits it as a Cycle member and its body is a `case`.

    sequence : List (St Int) -> St (List Int)
    sequence actions =
        case actions of
            [] ->
                pure []

            [ _ ] ->
                pure []

            m :: rest ->
                andThen (\x -> sequence rest) m

The duplicated `pure []` branch is there to give the decision-tree builder the
option of SHARING a branch body through `jumps`; the R8 assertion walks both
the decider's `Inline` leaves and the `jumps` list, so it holds either way.

-}
sequenceModule : Src.Module
sequenceModule =
    module_
        [ { name = "sequence"
          , args = [ pVar "actions" ]
          , tipe =
                tLambda (tType "List" [ tSt tInt ])
                    (tSt (tType "List" [ tInt ]))
          , body =
                caseExpr (varExpr "actions")
                    [ ( pList [], callExpr (varExpr "pure") [ listExpr [] ] )
                    , ( pList [ pVar "one" ], callExpr (varExpr "pure") [ listExpr [] ] )
                    , ( pCons (pVar "m") (pVar "rest")
                      , callExpr (varExpr "andThen")
                            [ lambdaExpr [ pVar "x" ] (callExpr (varExpr "sequence") [ varExpr "rest" ])
                            , varExpr "m"
                            ]
                      )
                    ]
          }
        , testValueDef
            (callExpr (qualVarExpr "List" "length")
                [ callExpr (varExpr "sequence") [ listExpr [], intExpr 0 ] ]
            )
        ]


{-| F6 — a self-TAIL-recursive definition with a deficit. Out in v1: its
`TailCall` sites carry exactly the syntactic parameters, so adding one means
threading it through every jump.
-}
tailDefModule : Src.Module
tailDefModule =
    module_
        [ { name = "loop"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt (tSt tInt)
          , body =
                caseExpr (varExpr "n")
                    [ ( pVar "other", callExpr (varExpr "loop") [ varExpr "other" ] ) ]
          }
        , testValueDef (callExpr (varExpr "loop") [ intExpr 1, intExpr 0 ])
        ]


{-| F7 — `d = let big = expensive 1 in pure big`.

The gate's whole reason for existing: before η, `big` is computed once into a
memoised CAF slot; after, once per call.

-}
expensiveLetModule : Src.Module
expensiveLetModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tSt tInt
          , body =
                letExpr
                    [ define "big" [] (callExpr (varExpr "expensive") [ intExpr 1 ]) ]
                    (callExpr (varExpr "pure") [ varExpr "big" ])
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 0 ])
        ]


{-| F8 — the same refusal reached through an ARGUMENT rather than a `let`:
`d = pure (expensive 1)`, where `expensive` is a saturated call whose body is
over the threshold.

This is the arm that also refuses `Debug.log`: it lowers to a `VarDebug` call,
which no cheap arm admits. The test harness has no `Debug` interface, so the
observable-ORDERING half of that claim is pinned end-to-end by
`test/elm/src/EtaExpandLogOrderTest.elm` instead; what is pinned here is that
the gate refuses the shape at all.

-}
notCheapArgModule : Src.Module
notCheapArgModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tSt tInt
          , body = callExpr (varExpr "pure") [ callExpr (varExpr "expensive") [ intExpr 1 ] ]
          }
        , testValueDef (callExpr (varExpr "d") [ intExpr 0 ])
        ]


{-| F9 — a definition whose type has no arrow spine at all. `main : Html msg`
and `main : Program () Model Msg` are this shape, which is why §2.6 needs no
special case for the entry point.
-}
noSpineModule : Src.Module
noSpineModule =
    module_
        [ { name = "d"
          , args = []
          , tipe = tInt
          , body = intExpr 5
          }
        , testValueDef (varExpr "d")
        ]
