module TestLogic.GlobalOpt.AliasForwardTest exposing (suite)

{-| Test suite for PRE-monomorphization alias forwarding
(`plans/pre-mono-lss-transforms-04-alias-forwarding.md` §6).

The pass runs on the `TOpt.GlobalGraph MVarId` that
`Builder.Generate.runMonoOptPipeline` hands it, so every fixture goes through
`Pipeline.runToAssigned` and calls `AliasForward.run` directly — the same route
`EtaExpandTest` takes. Assertions are on the returned graph, never on mono
output.

What is pinned (plan §6 table, plus the §3.2 amendment):

  - F1 `f = inc; testValue = f 1`: the call targets `inc`, `f`'s node is
    untouched, and the rewritten reference's meta is `==` the original's (R7 —
    the CALLER's meta is kept, nothing is minted);
  - F2 a three-link chain resolves to its end and `chainsMax` reports it;
  - F3 a kernel alias CALLED at its arity becomes a `VarKernel` call and the
    caller's `deps` gains `toKernelGlobal "Basics"`;
  - F4 a `ToGlobal` alias in ARGUMENT position is forwarded;
  - F5 a kernel alias in ARGUMENT position is NOT forwarded (R6) and counted;
  - F6 an UNDER-applied kernel-alias call is NOT forwarded (§3.2 amendment)
    and counted;
  - F7 an alias referenced from inside a `Cycle` member is forwarded (R8);
  - F8 an alias typed through a type alias (`Doc`) is forwarded in both
    positions with its metas retained (R1);
  - the pass is inert with the flag off, and `bodiesSeen` is never zero.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliasesExtended
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
import Compiler.GlobalOpt.PreMono.AliasForward as AliasForward
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set as EverySet
import Dict as CoreDict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "AliasForward (pre-mono)"
        [ denominatorSuite
        , mapSuite
        , callSuite
        , valueSuite
        , cycleSuite
        , docAliasSuite
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
                withMetrics simpleModule
                    (\m ->
                        if m.bodiesSeen > 0 then
                            Expect.pass

                        else
                            Expect.fail "AliasForward matched no top-level body"
                    )
        ]



-- ============================================================================
-- THE ALIAS MAP (§3.1)
-- ============================================================================


mapSuite : Test
mapSuite =
    Test.describe "aliasMap"
        [ Test.test "F2: a chain resolves every link to its end" <|
            \_ ->
                withAssigned chainModule
                    (\assigned ->
                        let
                            ( aliases, _, _ ) =
                                AliasForward.aliasMap assigned.graph

                            targetOf name =
                                globalNamed assigned.graph name
                                    |> Maybe.andThen (\g -> CoreDict.get (TOpt.toComparableGlobal g) aliases)
                                    |> Maybe.andThen globalTargetName
                        in
                        Expect.equal ( Just "h", Just "h" ) ( targetOf "f", targetOf "g" )
                    )
        , Test.test "F2: chainsMax is the chain depth" <|
            \_ ->
                withMetrics chainModule (\m -> Expect.equal 2 m.chainsMax)
        , Test.test "F2: no cycles are reported" <|
            \_ ->
                withMetrics chainModule (\m -> Expect.equal 0 m.cycles)
        , Test.test "a function definition is not an alias, an alias is" <|
            \_ ->
                -- Absolute counts are not pinned: `TestPipeline.wrapWithMain`
                -- contributes alias-shaped nodes of its own.
                withAssigned simpleModule
                    (\assigned ->
                        let
                            ( aliases, _, _ ) =
                                AliasForward.aliasMap assigned.graph

                            isAlias name =
                                globalNamed assigned.graph name
                                    |> Maybe.map (\g -> CoreDict.member (TOpt.toComparableGlobal g) aliases)
                        in
                        Expect.equal ( Just True, Just False ) ( isAlias "f", isAlias "inc" )
                    )
        , Test.test "F3: a kernel alias is a kernel target" <|
            \_ ->
                withAssigned kernelCallModule
                    (\assigned ->
                        let
                            ( aliases, _, _ ) =
                                AliasForward.aliasMap assigned.graph
                        in
                        case globalNamed assigned.graph "add" |> Maybe.andThen (\g -> CoreDict.get (TOpt.toComparableGlobal g) aliases) of
                            Just (AliasForward.ToKernel _ "Basics" "add" 2 True) ->
                                Expect.pass

                            other ->
                                Expect.fail ("add resolved to " ++ Debug.toString other)
                    )
        ]



-- ============================================================================
-- F1-F3, F6: CALL POSITION
-- ============================================================================


callSuite : Test
callSuite =
    Test.describe "Call position"
        [ Test.test "F1: the call targets the alias's target" <|
            \_ ->
                withGraph simpleModule
                    (\g -> Expect.equal [ "g:inc" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F1: the alias definition itself is untouched" <|
            \_ ->
                withBefore simpleModule
                    (\before after -> Expect.equal (nodeBody before "f") (nodeBody after "f"))
        , Test.test "F1: the rewritten reference keeps the CALLER's meta (R7)" <|
            \_ ->
                withBefore simpleModule
                    (\before after ->
                        Expect.equal
                            (List.concatMap (refMetas "f") (bodyOf before "testValue"))
                            (List.concatMap (refMetas "inc") (bodyOf after "testValue"))
                    )
        , Test.test "F1: one call is counted" <|
            \_ ->
                withMetrics simpleModule (\m -> Expect.equal 1 m.callsRewritten)
        , Test.test "F2: a chained call targets the end of the chain" <|
            \_ ->
                withGraph chainModule
                    (\g -> Expect.equal [ "g:h" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F3: a saturated kernel-alias call becomes a kernel call" <|
            \_ ->
                withGraph kernelCallModule
                    (\g -> Expect.equal [ "k:Basics.add" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F3: the caller's deps gain the kernel global" <|
            \_ ->
                withGraph kernelCallModule
                    (\g ->
                        case nodeDeps g "testValue" of
                            Just deps ->
                                if EverySet.member TOpt.toComparableGlobal (TOpt.toKernelGlobal "Basics") deps then
                                    Expect.pass

                                else
                                    Expect.fail "deps does not contain Elm.Kernel.Basics"

                            Nothing ->
                                Expect.fail "no testValue node"
                    )
        , Test.test "F3: the kernel call is counted" <|
            \_ ->
                withMetrics kernelCallModule
                    (\m -> Expect.equal ( 1, 1, 1 ) ( m.callsRewritten, m.callsRewrittenKernel, m.depsExtended ))
        , Test.test "F6: an under-applied kernel-alias call keeps the alias (§3.2 amendment)" <|
            \_ ->
                withGraph kernelPartialModule
                    (\g ->
                        if List.member "g:add" (List.concatMap calleeNames (bodyOf g "testValue")) then
                            Expect.pass

                        else
                            Expect.fail "the partial call of the kernel alias was forwarded"
                    )
        , Test.test "F6: the kept partial is counted, and not as a value" <|
            \_ ->
                withMetrics kernelPartialModule
                    (\m -> Expect.equal ( 1, 0, 0 ) ( m.callsKeptKernelPartial, m.argRefsKeptKernel, m.callsRewritten ))
        , Test.test "F3-poly: a POLYMORPHIC kernel alias's saturated call keeps the alias (ABI is per-occurrence)" <|
            \_ ->
                -- `Task.succeed : a -> Task x a` shape. Forwarding registered
                -- `i64 -> eco.value` against the one boxed symbol: 44 E2E
                -- failures on 2026-09-14.
                withGraph kernelPolyModule
                    (\g -> Expect.equal [ "g:pick" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        , Test.test "F3-poly: the kept call is counted" <|
            \_ ->
                withMetrics kernelPolyModule
                    (\m -> Expect.equal ( 1, 0 ) ( m.callsKeptKernelPoly, m.callsRewritten ))
        , Test.test "F3-suffix: a polymorphic SUFFIX-SELECTING kernel alias (List.cons) is forwarded" <|
            \_ ->
                withGraph kernelConsModule
                    (\g -> Expect.equal [ "k:List.cons" ] (List.concatMap calleeNames (bodyOf g "testValue")))
        ]



-- ============================================================================
-- F4-F5: ARGUMENT POSITION
-- ============================================================================


valueSuite : Test
valueSuite =
    Test.describe "Argument position"
        [ Test.test "F4: a ToGlobal alias passed as a value is forwarded" <|
            \_ ->
                withGraph valueModule
                    (\g ->
                        let
                            refs =
                                List.concatMap valueRefNames (bodyOf g "testValue")
                        in
                        Expect.equal ( True, False ) ( List.member "inc" refs, List.member "f" refs )
                    )
        , Test.test "F4: the value is counted" <|
            \_ ->
                withMetrics valueModule (\m -> Expect.equal ( 1, 0 ) ( m.argRefsRewritten, m.callsRewritten ))
        , Test.test "F5: a kernel alias passed as a value is NOT forwarded (R6)" <|
            \_ ->
                withGraph kernelValueModule
                    (\g ->
                        if List.member "add" (List.concatMap valueRefNames (bodyOf g "testValue")) then
                            Expect.pass

                        else
                            Expect.fail "the kernel alias value was forwarded"
                    )
        , Test.test "F5: the kept kernel value is counted" <|
            \_ ->
                withMetrics kernelValueModule
                    (\m -> Expect.equal ( 1, 0 ) ( m.argRefsKeptKernel, m.argRefsRewritten ))
        ]



-- ============================================================================
-- F7: CYCLE BODIES (R8)
-- ============================================================================


cycleSuite : Test
cycleSuite =
    Test.describe "Cycle bodies"
        [ Test.test "F7: the fixture produces a Cycle node" <|
            \_ ->
                withGraph cycleModule
                    (\g ->
                        if List.isEmpty (cycleBodies g) then
                            Expect.fail "no Cycle node — the fixture is not recursive"

                        else
                            Expect.pass
                    )
        , Test.test "F7: an alias called from inside a Cycle member is forwarded" <|
            \_ ->
                withGraph cycleModule
                    (\g ->
                        let
                            callees =
                                List.concatMap calleeNames (cycleBodies g)
                        in
                        Expect.equal ( True, False ) ( List.member "g:inc" callees, List.member "g:f" callees )
                    )
        ]



-- ============================================================================
-- F8: A TYPE-ALIAS-TYPED ALIAS (R1)
-- ============================================================================


docAliasSuite : Test
docAliasSuite =
    Test.describe "Alias typed through a type alias"
        [ Test.test "F8: forwarded in call position" <|
            \_ ->
                withGraph docModule
                    (\g ->
                        let
                            callees =
                                List.concatMap calleeNames (bodyOf g "testValue")
                        in
                        Expect.equal ( True, False ) ( List.member "g:mk" callees, List.member "g:fromChars" callees )
                    )
        , Test.test "F8: forwarded in argument position" <|
            \_ ->
                withGraph docModule
                    (\g ->
                        let
                            refs =
                                List.concatMap valueRefNames (bodyOf g "testValue")
                        in
                        Expect.equal ( True, False ) ( List.member "mk" refs, List.member "fromChars" refs )
                    )
        , Test.test "F8: both references keep their metas" <|
            \_ ->
                withBefore docModule
                    (\before after ->
                        Expect.equal
                            (List.concatMap (refMetas "fromChars") (bodyOf before "testValue"))
                            (List.concatMap (refMetas "mk") (bodyOf after "testValue"))
                    )
        , Test.test "F8: the metas were actually compared (two references)" <|
            \_ ->
                withBefore docModule
                    (\before _ -> Expect.equal 2 (List.length (List.concatMap (refMetas "fromChars") (bodyOf before "testValue"))))
        ]



-- ============================================================================
-- INERT WITH THE FLAG OFF
-- ============================================================================


inertSuite : Test
inertSuite =
    Test.describe "Flag off"
        [ Test.test "the graph is returned untouched" <|
            \_ ->
                withAssigned simpleModule
                    (\assigned ->
                        let
                            ( after, _, _ ) =
                                AliasForward.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal (List.concatMap calleeNames (bodyOf assigned.graph "testValue")) (List.concatMap calleeNames (bodyOf after "testValue"))
                    )
        , Test.test "the census is still computed" <|
            \_ ->
                withAssigned simpleModule
                    (\assigned ->
                        let
                            ( _, _, m ) =
                                AliasForward.run offInline assigned.mvarState assigned.graph
                        in
                        Expect.equal 1 m.callsRewritten
                    )
        ]



-- ============================================================================
-- HARNESS
-- ============================================================================


afwdConfig : Config.InlineConfig
afwdConfig =
    { defaultInline | aliasForward = True }


defaultInline : Config.InlineConfig
defaultInline =
    Config.default.inline


{-| The flag-off configuration, spelled explicitly so a later default flip
cannot silently turn this arm into the on-arm.
-}
offInline : Config.InlineConfig
offInline =
    { defaultInline | aliasForward = False }


withAssigned : Src.Module -> (EntryPrep.Assigned -> Expect.Expectation) -> Expect.Expectation
withAssigned srcModule check =
    case Pipeline.runToAssigned srcModule of
        Err msg ->
            Expect.fail msg

        Ok assigned ->
            check assigned


withMetrics : Src.Module -> (AliasForward.Metrics -> Expect.Expectation) -> Expect.Expectation
withMetrics srcModule check =
    withAssigned srcModule
        (\assigned ->
            let
                ( _, _, m ) =
                    AliasForward.run afwdConfig assigned.mvarState assigned.graph
            in
            check m
        )


withGraph : Src.Module -> (TOpt.GlobalGraph TypeIds.MVarId -> Expect.Expectation) -> Expect.Expectation
withGraph srcModule check =
    withBefore srcModule (\_ after -> check after)


withBefore : Src.Module -> (TOpt.GlobalGraph TypeIds.MVarId -> TOpt.GlobalGraph TypeIds.MVarId -> Expect.Expectation) -> Expect.Expectation
withBefore srcModule check =
    withAssigned srcModule
        (\assigned ->
            let
                ( after, _, _ ) =
                    AliasForward.run afwdConfig assigned.mvarState assigned.graph
            in
            check assigned.graph after
        )



-- ====== STRUCTURAL READERS ======


globalTargetName : AliasForward.Target -> Maybe Name
globalTargetName t =
    case t of
        AliasForward.ToGlobal (TOpt.Global _ n) ->
            Just n

        AliasForward.ToKernel _ _ _ _ _ ->
            Nothing


globalNamed : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe TOpt.Global
globalNamed (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl TOpt.compareGlobal
        (\((TOpt.Global _ n) as g) _ acc ->
            if n == name then
                Just g

            else
                acc
        )
        Nothing
        nodes


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


nodeDeps : TOpt.GlobalGraph TypeIds.MVarId -> Name -> Maybe (EverySet.EverySet String TOpt.Global)
nodeDeps (TOpt.GlobalGraph nodes _ _ _ _) name =
    Data.Map.foldl TOpt.compareGlobal
        (\(TOpt.Global _ n) node acc ->
            if n == name then
                case node of
                    TOpt.Define _ deps _ ->
                        Just deps

                    TOpt.TrackedDefine _ _ deps _ ->
                        Just deps

                    _ ->
                        acc

            else
                acc
        )
        Nothing
        nodes


{-| A missing node reads as NO body, so every reader below returns `[]` for
it and the assertion fails on the value rather than on a `Maybe`.
-}
bodyOf : TOpt.GlobalGraph TypeIds.MVarId -> Name -> List (TOpt.Expr TypeIds.MVarId)
bodyOf g name =
    Maybe.withDefault [] (Maybe.map List.singleton (nodeBody g name))


{-| Every expression inside every `Cycle` node: value defs, `Def` bodies and
`TailDef` bodies.
-}
cycleBodies : TOpt.GlobalGraph TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
cycleBodies (TOpt.GlobalGraph nodes _ _ _ _) =
    Data.Map.foldl TOpt.compareGlobal
        (\_ node acc ->
            case node of
                TOpt.Cycle _ values defs _ ->
                    List.map Tuple.second values
                        ++ List.map
                            (\def ->
                                case def of
                                    TOpt.Def _ _ body _ ->
                                        body

                                    TOpt.TailDef _ _ _ body _ _ ->
                                        body
                            )
                            defs
                        ++ acc

                _ ->
                    acc
        )
        []
        nodes


{-| Callees of every `Call` in the expression, in traversal order: `g:name`
for a global, `k:home.name` for a kernel.
-}
calleeNames : TOpt.Expr TypeIds.MVarId -> List String
calleeNames expr =
    (case expr of
        TOpt.Call _ (TOpt.VarGlobal _ (TOpt.Global _ n) _) _ _ ->
            [ "g:" ++ n ]

        TOpt.Call _ (TOpt.VarKernel _ _ home name _) _ _ ->
            [ "k:" ++ home ++ "." ++ name ]

        _ ->
            []
    )
        ++ List.concatMap calleeNames (children expr)


{-| Names of every bare `VarGlobal` NOT in callee position.
-}
valueRefNames : TOpt.Expr TypeIds.MVarId -> List String
valueRefNames expr =
    case expr of
        TOpt.VarGlobal _ (TOpt.Global _ n) _ ->
            [ n ]

        TOpt.Call _ func args _ ->
            (case func of
                TOpt.VarGlobal _ _ _ ->
                    []

                TOpt.VarKernel _ _ _ _ _ ->
                    []

                _ ->
                    valueRefNames func
            )
                ++ List.concatMap valueRefNames args

        _ ->
            List.concatMap valueRefNames (children expr)


{-| The metas of every `VarGlobal` reference to `name`, both positions, in
traversal order.
-}
refMetas : Name -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Meta TypeIds.MVarId)
refMetas name expr =
    (case expr of
        TOpt.VarGlobal _ (TOpt.Global _ n) meta ->
            if n == name then
                [ meta ]

            else
                []

        _ ->
            []
    )
        ++ List.concatMap (refMetas name) (children expr)


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
-- `testValue` is mandatory (`TestPipeline.wrapWithMain`) and is what keeps
-- each definition under test reachable.


tInt : Src.Type
tInt =
    tType "Int" []


tList : Src.Type -> Src.Type
tList inner =
    tType "List" [ inner ]


modOf : List TypedDef -> List AliasDef -> Src.Module
modOf defs aliases =
    makeModuleWithTypedDefsUnionsAliasesExtended "Test" defs [] aliases


{-| `inc : Int -> Int`, `inc x = x`.
-}
incDef : TypedDef
incDef =
    { name = "inc", args = [ pVar "x" ], tipe = tLambda tInt tInt, body = varExpr "x" }


{-| `name : Int -> Int`, `name = target`.
-}
aliasOf : Name -> Name -> TypedDef
aliasOf name target =
    { name = name, args = [], tipe = tLambda tInt tInt, body = varExpr target }


{-| `add : Int -> Int -> Int`, `add = Elm.Kernel.Basics.add` — the shape of
`Basics.add` in `elm/core`.
-}
kernelAddDef : TypedDef
kernelAddDef =
    { name = "add"
    , args = []
    , tipe = tLambda tInt (tLambda tInt tInt)
    , body = qualVarExpr "Elm.Kernel.Basics" "add"
    }


testValueDef : Src.Type -> Src.Expr -> TypedDef
testValueDef tipe body =
    { name = "testValue", args = [], tipe = tipe, body = body }


{-| `f = inc; testValue = f 1`.
-}
simpleModule : Src.Module
simpleModule =
    modOf
        [ incDef
        , aliasOf "f" "inc"
        , testValueDef tInt (callExpr (varExpr "f") [ intExpr 1 ])
        ]
        []


{-| `g = h; f = g; testValue = f 1`.
-}
chainModule : Src.Module
chainModule =
    modOf
        [ { incDef | name = "h" }
        , aliasOf "g" "h"
        , aliasOf "f" "g"
        , testValueDef tInt (callExpr (varExpr "f") [ intExpr 1 ])
        ]
        []


{-| `pick : a -> a; pick = Elm.Kernel.Basics.identity` — a kernel alias whose
ABI is decided per occurrence (`PreserveVars`), not by its declaration.
-}
kernelPolyModule : Src.Module
kernelPolyModule =
    modOf
        [ { name = "pick"
          , args = []
          , tipe = tLambda (tVar "a") (tVar "a")
          , body = qualVarExpr "Elm.Kernel.Basics" "identity"
          }
        , testValueDef tInt (callExpr (varExpr "pick") [ intExpr 1 ])
        ]
        []


{-| `cons : a -> List a -> List a; cons = Elm.Kernel.List.cons` — polymorphic
but suffix-selecting, so its ABI is the caller's concrete instantiation on
BOTH paths.
-}
kernelConsModule : Src.Module
kernelConsModule =
    modOf
        [ { name = "cons"
          , args = []
          , tipe = tLambda (tVar "a") (tLambda (tList (tVar "a")) (tList (tVar "a")))
          , body = qualVarExpr "Elm.Kernel.List" "cons"
          }
        , testValueDef (tList tInt) (callExpr (varExpr "cons") [ intExpr 1, listExpr [ intExpr 2 ] ])
        ]
        []


{-| `testValue = add 1 2`.
-}
kernelCallModule : Src.Module
kernelCallModule =
    modOf
        [ kernelAddDef
        , testValueDef tInt (callExpr (varExpr "add") [ intExpr 1, intExpr 2 ])
        ]
        []


{-| `testValue = List.map (add 1) [ 1 ]` — an under-applied kernel-alias call.
-}
kernelPartialModule : Src.Module
kernelPartialModule =
    modOf
        [ kernelAddDef
        , testValueDef (tList tInt)
            (callExpr (qualVarExpr "List" "map")
                [ callExpr (varExpr "add") [ intExpr 1 ], listExpr [ intExpr 1 ] ]
            )
        ]
        []


{-| `testValue = List.map f [ 1 ]` with `f = inc`.
-}
valueModule : Src.Module
valueModule =
    modOf
        [ incDef
        , aliasOf "f" "inc"
        , testValueDef (tList tInt)
            (callExpr (qualVarExpr "List" "map") [ varExpr "f", listExpr [ intExpr 1 ] ])
        ]
        []


{-| `testValue = List.foldl add 0 [ 1 ]` — a kernel alias as a value.
-}
kernelValueModule : Src.Module
kernelValueModule =
    modOf
        [ kernelAddDef
        , testValueDef tInt
            (callExpr (qualVarExpr "List" "foldl") [ varExpr "add", intExpr 0, listExpr [ intExpr 1 ] ])
        ]
        []


{-| A NON-tail recursive `loop` (so it is a `Def` inside a `Cycle`) that calls
the alias `f = inc` in both branches:

    loop n =
        if n == 0 then
            f n

        else
            f (loop (n - 1))

-}
cycleModule : Src.Module
cycleModule =
    modOf
        [ incDef
        , aliasOf "f" "inc"
        , { name = "loop"
          , args = [ pVar "n" ]
          , tipe = tLambda tInt tInt
          , body =
                ifExpr (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (callExpr (varExpr "f") [ varExpr "n" ])
                    (callExpr (varExpr "f")
                        [ callExpr (varExpr "loop") [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ] ]
                    )
          }
        , testValueDef tInt (callExpr (varExpr "loop") [ intExpr 3 ])
        ]
        []


{-| `type alias Doc = List Int; mk : Int -> Doc; fromChars : Int -> Doc;
fromChars = mk; testValue = fromChars 1 ++ List.concat (List.map fromChars [ 2 ])`
— one CALL and one VALUE reference.
-}
docModule : Src.Module
docModule =
    let
        tDoc =
            tType "Doc" []
    in
    modOf
        [ { name = "mk", args = [ pVar "x" ], tipe = tLambda tInt tDoc, body = listExpr [ varExpr "x" ] }
        , { name = "fromChars", args = [], tipe = tLambda tInt tDoc, body = varExpr "mk" }
        , testValueDef tDoc
            (binopsExpr [ ( callExpr (varExpr "fromChars") [ intExpr 1 ], "++" ) ]
                (callExpr (qualVarExpr "List" "concat")
                    [ callExpr (qualVarExpr "List" "map") [ varExpr "fromChars", listExpr [ intExpr 2 ] ] ]
                )
            )
        ]
        [ { name = "Doc", args = [], tipe = tList tInt } ]
