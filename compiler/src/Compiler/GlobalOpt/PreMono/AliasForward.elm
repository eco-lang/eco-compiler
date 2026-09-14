module Compiler.GlobalOpt.PreMono.AliasForward exposing
    ( Metrics
    , Target(..)
    , aliasMap
    , emptyMetrics
    , run
    )

{-| PRE-MONOMORPHIZATION alias forwarding
(`plans/pre-mono-lss-transforms-04-alias-forwarding.md`).

**The problem.** 53 % of the post-mono inliner's self-compile inlines land in
callers of parameter-less ALIAS definitions — `Basics.add = Elm.Kernel.Basics.add`,
`List.cons = Elm.Kernel.List.cons`, `Doc.fromChars = P.text`. The pre-mono
inliner never sees them (`InlineSimplify.bodyOf` admits `Function` bodies only),
so in the EARLY arm every `Basics.add x y` stays a call to a one-line wrapper,
and LSS keys the wrapper's `g|` member instead of the target's.

**Forwarding is not inlining.** It is reference substitution: a reference to an
admitted alias `f` becomes the same reference to `f`'s target, carrying the
CALLER's meta unchanged (plan §3.2 — `translateCall` looks the callee's scheme
up BY GLOBAL, and `translateVarRef` reads the reference's own instantiation,
which is the same for `f` and its target up to alias names that `Store.loadType`
expands). No node is minted, no arrow is created, so `Fresh.assertMinted` is
unaffected by construction (R7).

**The rewrite, by position (§3.2):**

  - CALL of a `ToGlobal` alias: forwarded.
  - CALL of a `ToKernel` alias: forwarded ONLY when exactly saturated
    (`argCount == kernel arrow spine`) AND the kernel's ABI is FIXED by its own
    declared type — `KernelAbi.deriveKernelAbiMode`'s rule, read off the alias
    body's kernel meta: no free type variable, or a suffix-selecting kernel
    (`_Int`/`_Float` variants), never a `Debug` kernel. A polymorphic kernel
    (`Task.succeed : a -> Task x a`, `String.foldl`) derives its ABI from the
    OCCURRENCE type, so a call carrying the caller's concrete instantiation
    would register `i64 -> …` against the one boxed `eco.value -> …` symbol —
    "Kernel signature mismatch", or a SIGSEGV where the register does not
    catch it. MEASURED 2026-09-14 on the flag-on E2E arm: 44 failures (every
    Task/Process/Http fixture) before this rule, the same lesson
    `InlineSimplify.polyKernel` records. Kept calls are counted
    `callsKeptKernelPoly`. AND the caller's reference meta is an arrow of the
    kernel's spine: synthesized references carry PLACEHOLDER metas
    (`Port.elm`'s `encode` registers `Json.Encode.string` at `Can.TVar
    "string"`), harmless through `translateGlobalCallSlow` — which looks the
    scheme up BY GLOBAL — but the ABI source of a kernel call: `OutgoingPortTuple3Test`
    registered `Elm_Kernel_Json_wrap` with ZERO parameters. Kept calls are
    counted `callsKeptKernelMeta`. An under-applied call keeps the alias,
    because the `p|` PRODUCER write (`Translate.injectPapMember`) runs only in
    `translateGlobalCallSlow`; `translateKernelCall` injects nothing, so
    forwarding a partial would delete the residual's only member write (§3.2
    amendment, 2026-09-14). An over-applied call also keeps the alias: a
    written-out kernel call is never over-applied, and `translateKernelCall`
    peels exactly the argument count.
  - VALUE reference to a `ToGlobal` alias: forwarded.
  - VALUE reference to a `ToKernel` alias: KEPT in v1 (§4 R6; v2 is §10) and
    counted (`argRefsKeptKernel`). `LssInfer.kernelAliasOf` folds it to the
    kernel's `k|` identity exactly as today.
  - The alias definition itself: untouched (§3.5 — demand-driven mono never
    specializes an unreferenced global, and a `ToKernel` alias is still
    referenced as a value).

**The one hard rule (§3.3):** every reference to an admitted alias is forwarded
or none is, per position class — so the walk covers EVERY expression-bearing
node kind, `Cycle` bodies included. `InlineSimplify.rewriteNode` skips `Cycle`
because inlining INTO a recursive family is refused; that reason does not
apply to reference substitution and this pass must not inherit the skip (R8).

**`deps` (§3.4):** a node whose body gained a reference to `g` gets `g` inserted
into its `deps` (`toKernelGlobal home` for a kernel target, the way
`Names.registerKernel` records kernel deps); the alias stays in `deps` — a
harmless over-approximation.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Dict as CoreDict



-- ============================================================================
-- ====== METRICS ======
-- ============================================================================


{-| Census counters (plan §7). `bodiesSeen` is the denominator whose zero is
impossible — the pre-mono inliner's lesson: a rewrite count of zero reads
identically whether the pass refused everything or matched no node shape.
-}
type alias Metrics =
    { aliases : Int
    , globalTargets : Int
    , kernelTargets : Int
    , chainsMax : Int
    , cycles : Int
    , callsRewritten : Int
    , callsRewrittenKernel : Int -- the subset of `callsRewritten` whose target is a kernel
    , callsKeptKernelPartial : Int -- §3.2 amendment: under-applied kernel-alias calls, kept
    , callsKeptKernelOver : Int -- over-applied kernel-alias calls, kept
    , callsKeptKernelPoly : Int -- calls of a kernel alias whose ABI is not fixed by its declared type, kept
    , callsKeptKernelMeta : Int -- calls whose reference meta is not an arrow of the kernel's spine (synthesized placeholder), kept
    , argRefsRewritten : Int
    , argRefsKeptKernel : Int -- R6: kernel-alias VALUES, kept in v1
    , depsExtended : Int
    , bodiesSeen : Int

    -- forwarded references attributed by TARGET (`inlinedByCallee`'s rendering).
    , byTarget : CoreDict.Dict String Int
    }


{-| All-zero metrics — what `run` reports when the pass is off and the report
is off too.
-}
emptyMetrics : Metrics
emptyMetrics =
    { aliases = 0
    , globalTargets = 0
    , kernelTargets = 0
    , chainsMax = 0
    , cycles = 0
    , callsRewritten = 0
    , callsRewrittenKernel = 0
    , callsKeptKernelPartial = 0
    , callsKeptKernelOver = 0
    , callsKeptKernelPoly = 0
    , callsKeptKernelMeta = 0
    , argRefsRewritten = 0
    , argRefsKeptKernel = 0
    , depsExtended = 0
    , bodiesSeen = 0
    , byTarget = CoreDict.empty
    }



-- ============================================================================
-- ====== THE ALIAS MAP (§3.1) ======
-- ============================================================================


{-| Where an admitted alias resolves to, after chains are chased.

`ToKernel` carries the kernel's declared arrow spine — the length of the alias
definition's kernel meta type once aliases are expanded, the same count
`LssInfer.declaredArityGo`'s kernel-alias arm reads — because the saturation
test at call sites is made against it; and `abiFixed`, whether the kernel's
ABI is decided by its DECLARED type rather than by each occurrence
(`KernelAbi.deriveKernelAbiMode`: `UseSubstitution` for a variable-free type;
suffix-selecting kernels select a per-instance symbol either way; `Debug`
kernels are always boxed). Only an `abiFixed` kernel can take a forwarded
call: the kernel symbol is registered by NAME with one ABI.

-}
type Target
    = ToGlobal TOpt.Global
    | ToKernel Name Name Name Int Bool -- kernelPrefix home name spine abiFixed


{-| The admitted aliases, resolved to a fixpoint.

Admitted SOURCES: a `Define`/`TrackedDefine` whose body is EXACTLY a bare
`VarGlobal` or `VarKernel`. Not admitted (§3.1): `VarCycle` (a recursive family
behind a `Link`), `VarEnum`/`VarBox` (a constructor node is its own identity),
`VarDebug`, ports, `Manager`/`Kernel`/`Cycle` nodes, the synthesized flags
decoder, and anything whose body is not a bare reference.

Chains (`f = g, g = h`) resolve to their end with a visited set. An alias cycle
cannot appear as two `Define`s — the front end emits a `Cycle` node — but the
visited set refuses it anyway and counts it.

Returns the map with the chain depth maximum (hops from the alias to its
resolved target: `f = inc` is 1, `f = g, g = h` is 2) and the cycle count.

-}
aliasMap : TOpt.GlobalGraph TypeIds.MVarId -> ( CoreDict.Dict String Target, Int, Int )
aliasMap (TOpt.GlobalGraph nodes _ _ _ _) =
    let
        raw : CoreDict.Dict String Target
        raw =
            Dict.foldl TOpt.compareGlobal
                (\g node acc ->
                    case rawTarget g node of
                        Just t ->
                            CoreDict.insert (TOpt.toComparableGlobal g) t acc

                        Nothing ->
                            acc
                )
                CoreDict.empty
                nodes
    in
    CoreDict.foldl
        (\key t0 ( acc, maxDepth, cycles ) ->
            case chase raw (CoreDict.singleton key ()) 1 t0 of
                Just ( t, depth ) ->
                    ( CoreDict.insert key t acc, max maxDepth depth, cycles )

                Nothing ->
                    ( acc, maxDepth, cycles + 1 )
        )
        ( CoreDict.empty, 0, 0 )
        raw


rawTarget : TOpt.Global -> TOpt.Node TypeIds.MVarId -> Maybe Target
rawTarget (TOpt.Global _ nodeName) node =
    if nodeName == EntryPrep.flagsDecoderName then
        Nothing

    else
        case node of
            TOpt.Define body _ _ ->
                bareReference body

            TOpt.TrackedDefine _ body _ _ ->
                bareReference body

            _ ->
                Nothing


bareReference : TOpt.Expr TypeIds.MVarId -> Maybe Target
bareReference body =
    case body of
        TOpt.VarGlobal _ g _ ->
            Just (ToGlobal g)

        TOpt.VarKernel _ kernelPrefix home name meta ->
            Just (ToKernel kernelPrefix home name (arrowSpine meta.tipe) (abiFixedBy home name meta.tipe))

        _ ->
            Nothing


{-| `KernelAbi.deriveKernelAbiMode`'s decision, read off the kernel's own
occurrence type in the alias body, plus the suffix-selecting exemption that
`Translate.deriveKernelAbiTypeWith` applies on top of it.
-}
abiFixedBy : Name -> Name -> Can.Type TypeIds.MVarId -> Bool
abiFixedBy home name tipe =
    not (EverySet.member List.singleton home KernelAbi.alwaysPolymorphicModules)
        && (not (KernelAbi.hasAnyFreeVar tipe)
                || EverySet.member KernelAbi.comparePair ( home, name ) KernelAbi.suffixSelectingKernels
           )


{-| Follow `ToGlobal` links through the raw map. `Nothing` on a cycle.
-}
chase : CoreDict.Dict String Target -> CoreDict.Dict String () -> Int -> Target -> Maybe ( Target, Int )
chase raw visited depth t =
    case t of
        ToKernel _ _ _ _ _ ->
            Just ( t, depth )

        ToGlobal g ->
            let
                key =
                    TOpt.toComparableGlobal g
            in
            if CoreDict.member key visited then
                Nothing

            else
                case CoreDict.get key raw of
                    Just next ->
                        chase raw (CoreDict.insert key () visited) (depth + 1) next

                    Nothing ->
                        Just ( t, depth )


{-| The length of a canonical type's outer arrow spine, aliases followed —
`LssInfer.canTypeArrowSpine`'s twin (that module is not importable from here).
A kernel is uncurried at its declared C++ ABI arity, so the spine IS its
arity.
-}
arrowSpine : Can.Type TypeIds.MVarId -> Int
arrowSpine t =
    case t of
        Can.TLambda _ _ to ->
            1 + arrowSpine to

        Can.TAlias _ _ _ (Can.Filled real) ->
            arrowSpine real

        Can.TAlias _ _ _ (Can.Holey real) ->
            arrowSpine real

        _ ->
            0



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


type alias Ctx =
    { aliases : CoreDict.Dict String Target
    , metrics : Metrics

    -- targets referenced by rewrites in the node being walked, for `deps`.
    , depsAdd : List TOpt.Global
    }


{-| Forward references to alias definitions.

Returns the ORIGINAL graph when `inline.aliasForward` is off, with the census
still computed — so `inline.report` alone reports what the pass WOULD do
(`pre-afwd-census:`). The `GlobalMVarState` passes through untouched: this pass
mints nothing (R7).

-}
run :
    Config.InlineConfig
    -> AssignMVarIds.GlobalMVarState
    -> TOpt.GlobalGraph TypeIds.MVarId
    -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
run cfg state graph =
    let
        ( aliases, chainsMax, cycles ) =
            aliasMap graph

        ( globalTargets, kernelTargets ) =
            CoreDict.foldl
                (\_ t ( gs, ks ) ->
                    case t of
                        ToGlobal _ ->
                            ( gs + 1, ks )

                        ToKernel _ _ _ _ _ ->
                            ( gs, ks + 1 )
                )
                ( 0, 0 )
                aliases

        ctx0 : Ctx
        ctx0 =
            { aliases = aliases
            , metrics =
                { emptyMetrics
                    | aliases = CoreDict.size aliases
                    , globalTargets = globalTargets
                    , kernelTargets = kernelTargets
                    , chainsMax = chainsMax
                    , cycles = cycles
                }
            , depsAdd = []
            }

        ( graph1, ctx1 ) =
            rewriteGraph ctx0 graph
    in
    if cfg.aliasForward then
        ( graph1, state, ctx1.metrics )

    else
        ( graph, state, ctx1.metrics )


rewriteGraph : Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, Ctx )
rewriteGraph ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( newNodes, ctx1 ) =
            Dict.foldl TOpt.compareGlobal
                (\g node ( acc, c ) ->
                    let
                        ( newNode, c1 ) =
                            rewriteNode c g node
                    in
                    ( Dict.insert TOpt.toComparableGlobal g newNode acc, c1 )
                )
                ( Dict.empty, ctx )
                nodes
    in
    ( TOpt.GlobalGraph newNodes fields annotations schemeRoots varSupers, ctx1 )


{-| Every expression-bearing node kind (§3.3): `Define`, `TrackedDefine`,
`Cycle` (value AND function defs), both port kinds. The alias definitions
themselves are left untouched (§3.5).
-}
rewriteNode : Ctx -> TOpt.Global -> TOpt.Node TypeIds.MVarId -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx g node =
    if CoreDict.member (TOpt.toComparableGlobal g) ctx.aliases then
        ( node, ctx )

    else
        case node of
            TOpt.Define expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.Define e1 deps1 meta, c2 )

            TOpt.TrackedDefine region expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.TrackedDefine region e1 deps1 meta, c2 )

            TOpt.PortIncoming expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.PortIncoming e1 deps1 meta, c2 )

            TOpt.PortOutgoing expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.PortOutgoing e1 deps1 meta, c2 )

            TOpt.Cycle names values funcDefs deps ->
                let
                    ( newValues, ctxV ) =
                        List.foldl
                            (\( n, e ) ( acc, c ) ->
                                let
                                    ( e1, c1 ) =
                                        rewriteExpr (seeBody c) e
                                in
                                ( ( n, e1 ) :: acc, c1 )
                            )
                            ( [], ctx )
                            values

                    ( newFuncs, ctxF ) =
                        List.foldl
                            (\def ( acc, c ) ->
                                let
                                    ( d1, c1 ) =
                                        rewriteDef (seeBody c) def
                                in
                                ( d1 :: acc, c1 )
                            )
                            ( [], ctxV )
                            funcDefs

                    ( deps1, ctxD ) =
                        extendDeps ctxF deps
                in
                ( TOpt.Cycle names (List.reverse newValues) (List.reverse newFuncs) deps1, ctxD )

            _ ->
                -- Ctor/Enum/Box/Link/Manager/Kernel: no expression to walk.
                ( node, ctx )


{-| §3.4: insert every target the node's rewrites now reference, then clear the
per-node accumulator.
-}
extendDeps : Ctx -> EverySet String TOpt.Global -> ( EverySet String TOpt.Global, Ctx )
extendDeps ctx deps =
    case ctx.depsAdd of
        [] ->
            ( deps, ctx )

        adds ->
            ( List.foldl (\g acc -> EverySet.insert TOpt.toComparableGlobal g acc) deps adds
            , { ctx
                | depsAdd = []
                , metrics = (\m -> { m | depsExtended = m.depsExtended + 1 }) ctx.metrics
              }
            )



-- ============================================================================
-- ====== THE WALK (§3.2) ======
-- ============================================================================


{-| `InlineSimplify.rewriteExpr`'s shape minus the inlining arm. Two arms do
the work: `Call` with an alias in callee position, and a bare `VarGlobal`
anywhere else.
-}
rewriteExpr : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.Call region func args meta ->
            let
                ( args1, c1 ) =
                    rewriteList ctx args
            in
            case func of
                TOpt.VarGlobal fr f fMeta ->
                    case CoreDict.get (TOpt.toComparableGlobal f) c1.aliases of
                        Just (ToGlobal g) ->
                            ( TOpt.Call region (TOpt.VarGlobal fr g fMeta) args1 meta
                            , forwardedCall g c1
                            )

                        Just (ToKernel kernelPrefix home name spine abiFixed) ->
                            let
                                argCount =
                                    List.length args1
                            in
                            if not abiFixed then
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelPoly = m.callsKeptKernelPoly + 1 }) c1
                                )

                            else if arrowSpine fMeta.tipe /= spine then
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelMeta = m.callsKeptKernelMeta + 1 }) c1
                                )

                            else if argCount == spine then
                                ( TOpt.Call region (TOpt.VarKernel fr kernelPrefix home name fMeta) args1 meta
                                , forwardedKernelCall home name c1
                                )

                            else if argCount < spine then
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelPartial = m.callsKeptKernelPartial + 1 }) c1
                                )

                            else
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelOver = m.callsKeptKernelOver + 1 }) c1
                                )

                        Nothing ->
                            ( TOpt.Call region func args1 meta, c1 )

                _ ->
                    let
                        ( func1, c2 ) =
                            rewriteExpr c1 func
                    in
                    ( TOpt.Call region func1 args1 meta, c2 )

        TOpt.VarGlobal fr f fMeta ->
            case CoreDict.get (TOpt.toComparableGlobal f) ctx.aliases of
                Just (ToGlobal g) ->
                    ( TOpt.VarGlobal fr g fMeta, forwardedValue g ctx )

                Just (ToKernel _ _ _ _ _) ->
                    ( expr, bump (\m -> { m | argRefsKeptKernel = m.argRefsKeptKernel + 1 }) ctx )

                Nothing ->
                    ( expr, ctx )

        TOpt.Function srcLam params body meta ->
            mapBody ctx body (\b -> TOpt.Function srcLam params b meta)

        TOpt.TrackedFunction srcLam params body meta ->
            mapBody ctx body (\b -> TOpt.TrackedFunction srcLam params b meta)

        TOpt.Let def body meta ->
            let
                ( def1, c1 ) =
                    rewriteDef ctx def

                ( body1, c2 ) =
                    rewriteExpr c1 body
            in
            ( TOpt.Let def1 body1 meta, c2 )

        TOpt.Destruct d body meta ->
            mapBody ctx body (\b -> TOpt.Destruct d b meta)

        TOpt.If branches final meta ->
            let
                ( branches1, c1 ) =
                    List.foldl
                        (\( cond, t ) ( acc, c ) ->
                            let
                                ( cond1, ca ) =
                                    rewriteExpr c cond

                                ( t1, cb ) =
                                    rewriteExpr ca t
                            in
                            ( ( cond1, t1 ) :: acc, cb )
                        )
                        ( [], ctx )
                        branches

                ( final1, c2 ) =
                    rewriteExpr c1 final
            in
            ( TOpt.If (List.reverse branches1) final1 meta, c2 )

        TOpt.Case n1 n2 decider branches meta ->
            let
                ( decider1, c0 ) =
                    rewriteDecider ctx decider

                ( branches1, c1 ) =
                    List.foldl
                        (\( i, e ) ( acc, c ) ->
                            let
                                ( e1, c2 ) =
                                    rewriteExpr c e
                            in
                            ( ( i, e1 ) :: acc, c2 )
                        )
                        ( [], c0 )
                        branches
            in
            ( TOpt.Case n1 n2 decider1 (List.reverse branches1) meta, c1 )

        TOpt.List region items meta ->
            let
                ( items1, c1 ) =
                    rewriteList ctx items
            in
            ( TOpt.List region items1 meta, c1 )

        TOpt.Tuple region a b rest meta ->
            let
                ( a1, c1 ) =
                    rewriteExpr ctx a

                ( b1, c2 ) =
                    rewriteExpr c1 b

                ( rest1, c3 ) =
                    rewriteList c2 rest
            in
            ( TOpt.Tuple region a1 b1 rest1 meta, c3 )

        TOpt.Access inner region field meta ->
            mapBody ctx inner (\i -> TOpt.Access i region field meta)

        TOpt.TailCall name args meta ->
            let
                ( args1, c1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c2 ) =
                                    rewriteExpr c e
                            in
                            ( ( n, e1 ) :: acc, c2 )
                        )
                        ( [], ctx )
                        args
            in
            ( TOpt.TailCall name (List.reverse args1) meta, c1 )

        TOpt.Record fields meta ->
            let
                ( fields1, c1 ) =
                    CoreDict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c2 ) =
                                    rewriteExpr c e
                            in
                            ( CoreDict.insert k e1 acc, c2 )
                        )
                        ( CoreDict.empty, ctx )
                        fields
            in
            ( TOpt.Record fields1 meta, c1 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( fields1, c1 ) =
                    rewriteLocatedFields ctx fields
            in
            ( TOpt.TrackedRecord region fields1 meta, c1 )

        TOpt.Update region record fields meta ->
            let
                ( record1, c0 ) =
                    rewriteExpr ctx record

                ( fields1, c1 ) =
                    rewriteLocatedFields c0 fields
            in
            ( TOpt.Update region record1 fields1 meta, c1 )

        _ ->
            -- Literals, locals, ctors, cycle/kernel/debug refs, accessors,
            -- shaders: nothing to forward and no sub-expressions.
            ( expr, ctx )


rewriteLocatedFields :
    Ctx
    -> Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId)
    -> ( Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteLocatedFields ctx fields =
    Dict.foldl A.compareLocated
        (\k e ( acc, c ) ->
            let
                ( e1, c2 ) =
                    rewriteExpr c e
            in
            ( Dict.insert A.toValue k e1 acc, c2 )
        )
        ( Dict.empty, ctx )
        fields


rewriteDecider : Ctx -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
rewriteDecider ctx decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            let
                ( e1, c1 ) =
                    rewriteExpr ctx e
            in
            ( TOpt.Leaf (TOpt.Inline e1), c1 )

        TOpt.Leaf (TOpt.Jump i) ->
            ( TOpt.Leaf (TOpt.Jump i), ctx )

        TOpt.Chain tests ok ko ->
            let
                ( ok1, c1 ) =
                    rewriteDecider ctx ok

                ( ko1, c2 ) =
                    rewriteDecider c1 ko
            in
            ( TOpt.Chain tests ok1 ko1, c2 )

        TOpt.FanOut path branches fallback ->
            let
                ( branches1, c1 ) =
                    List.foldl
                        (\( t, d ) ( acc, c ) ->
                            let
                                ( d1, c2 ) =
                                    rewriteDecider c d
                            in
                            ( ( t, d1 ) :: acc, c2 )
                        )
                        ( [], ctx )
                        branches

                ( fallback1, cf ) =
                    rewriteDecider c1 fallback
            in
            ( TOpt.FanOut path (List.reverse branches1) fallback1, cf )


rewriteDef : Ctx -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef ctx def =
    case def of
        TOpt.Def region name bound tipe ->
            let
                ( b1, c1 ) =
                    rewriteExpr ctx bound
            in
            ( TOpt.Def region name b1 tipe, c1 )

        TOpt.TailDef region name args body tipe tvar ->
            let
                ( b1, c1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.TailDef region name args b1 tipe tvar, c1 )


mapBody : Ctx -> TOpt.Expr TypeIds.MVarId -> (TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId) -> ( TOpt.Expr TypeIds.MVarId, Ctx )
mapBody ctx body rebuild =
    let
        ( body1, c1 ) =
            rewriteExpr ctx body
    in
    ( rebuild body1, c1 )


rewriteList : Ctx -> List (TOpt.Expr TypeIds.MVarId) -> ( List (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteList ctx items =
    let
        ( rev, c ) =
            List.foldl
                (\e ( acc, cc ) ->
                    let
                        ( e1, c1 ) =
                            rewriteExpr cc e
                    in
                    ( e1 :: acc, c1 )
                )
                ( [], ctx )
                items
    in
    ( List.reverse rev, c )



-- ============================================================================
-- ====== COUNTERS ======
-- ============================================================================


forwardedCall : TOpt.Global -> Ctx -> Ctx
forwardedCall g ctx =
    { ctx
        | depsAdd = g :: ctx.depsAdd
        , metrics =
            (\m ->
                { m
                    | callsRewritten = m.callsRewritten + 1
                    , byTarget = tally (TOpt.toComparableGlobal g) m.byTarget
                }
            )
                ctx.metrics
    }


forwardedKernelCall : Name -> Name -> Ctx -> Ctx
forwardedKernelCall home name ctx =
    { ctx
        | depsAdd = TOpt.toKernelGlobal home :: ctx.depsAdd
        , metrics =
            (\m ->
                { m
                    | callsRewritten = m.callsRewritten + 1
                    , callsRewrittenKernel = m.callsRewrittenKernel + 1
                    , byTarget = tally ("k|" ++ home ++ "." ++ name) m.byTarget
                }
            )
                ctx.metrics
    }


forwardedValue : TOpt.Global -> Ctx -> Ctx
forwardedValue g ctx =
    { ctx
        | depsAdd = g :: ctx.depsAdd
        , metrics =
            (\m ->
                { m
                    | argRefsRewritten = m.argRefsRewritten + 1
                    , byTarget = tally (TOpt.toComparableGlobal g) m.byTarget
                }
            )
                ctx.metrics
    }


bump : (Metrics -> Metrics) -> Ctx -> Ctx
bump f ctx =
    { ctx | metrics = f ctx.metrics }


seeBody : Ctx -> Ctx
seeBody =
    bump (\m -> { m | bodiesSeen = m.bodiesSeen + 1 })


tally : String -> CoreDict.Dict String Int -> CoreDict.Dict String Int
tally key d =
    CoreDict.update key (\v -> Just (Maybe.withDefault 0 v + 1)) d
