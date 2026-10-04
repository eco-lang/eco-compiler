module Compiler.Monomorphize.AssignMVarIds exposing
    ( GlobalMVarState, assignIds, assignIdsToType
    , freshMVarId, mintLamId, mintArrowId
    )

{-| Assign globally unique MVarIds to all type variables in a TypedOptimized GlobalGraph.

This pass runs once at the start of monomorphization, converting
`GlobalGraph Name` to `GlobalGraph MVarId`. After this pass, all type
variables carry sequential Int-based IDs instead of string names, and
constraint information is recorded in a side table.

@docs GlobalMVarState, assignIds, assignIdsToType
@docs freshMVarId, mintLamId, mintArrowId

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.SolverRoots as SolverRoots
import Data.Map as DMap
import Dict exposing (Dict)


{-| Global state threaded through the entire ID assignment pass.
-}
type alias GlobalMVarState =
    { nextId : TypeIds.MVarId
    , superVars : Dict Int Vars.SuperType
    , rootEnv : Dict ( String, Int ) TypeIds.MVarId
    , nextLam : TypeIds.SrcLambdaId -- LSS: source-lambda id supply; seeds the engine's member interning
    , lamLabels : Dict Int String -- LSS: member id -> "defKey#id" (census rendering only)
    , nextArrow : TypeIds.ArrowId -- Phase 2a: per-OCCURRENCE arrow identity supply (plans/lss-unknown-elimination.md §4.2). No side table: `lamLabels` exists only for census rendering and has no arrow analogue.
    , arrowRootEnv : Dict ( String, Int ) TypeIds.ArrowId -- Phase 2b: (moduleKey, solver root index) -> global ArrowId. EXACT mirror of `rootEnv`, and module-scoped for the same reason: each module's solve numbers its `Pt` from zero, so a raw index is only meaningful with its home module.

    -- STAMPING-WALK CENSUS (plans/lss-provenance-ratio-census.md §8). The walk
    -- in `SolverRoots.stampArrowRoots` abandons a WHOLE SUBTREE on a lockstep
    -- mismatch, so "23,670 arrows lost" could be a few big abandonments or
    -- twenty thousand small ones. These classify each TOP-LEVEL type by whether
    -- the walk stamped all / none / some of its arrows — and "some" is
    -- unambiguous proof the walk ran, descended, and then broke.
    , stampCensusOn : Bool -- §8: gates the per-type classification below (cheap, but not free: two record updates per top-level type)
    , arrowsStamped : Int -- arrows that took the SolverRoot arm
    , typesAll : Int -- every arrow stamped
    , typesNone : Int -- no arrow stamped: never walked, or failed at the root
    , typesPartial : Int -- MID-WALK ABANDONMENT, provably
    , arrowsInNone : Int
    , arrowsUnstampedInPartial : Int
    }


{-| Per-scheme mapping from type variable names to their assigned MVarIds.
Reset for each top-level definition; grows lazily as new names are encountered.
-}
type alias SchemeEnv =
    Dict Name TypeIds.MVarId


{-| Combined context threaded through the rewrite.
-}
type alias Ctx =
    { env : SchemeEnv
    , state : GlobalMVarState
    , schemeRootsForDef : SolverRoots.SchemeRootsForDef
    , varSupers : Dict Name Vars.SuperType
    , moduleKey : String
    , defKey : String -- enclosing global's comparable key (lambda-label rendering)
    , useSolverRoots : Bool -- Phase 2b: resolve `SolverRoot` slots through `arrowRootEnv` instead of minting a fresh occurrence id. True for the SOLVER engine (the flag was fixed at its default 2026-09-18); the subst and diff engines pass False — changing that would move their output. OFF = exactly Phase 2a.
    }


{-| Mint a fresh source-lambda id (LSS member identity), labeling it with the
enclosing def for census rendering. Because `AssignMVarIds` runs on the
merged whole-program graph with a deterministic walk, ids are per-run stable
(LSS\_003) — the same stability class as `MVarId`s.
-}
freshLamId : Ctx -> ( TypeIds.SrcLambdaId, Ctx )
freshLamId ctx =
    let
        st =
            ctx.state

        lamId =
            st.nextLam

        key =
            Id.toComparable lamId
    in
    ( lamId
    , { ctx
        | state =
            { st
                | nextLam = Id.succ lamId

                -- Perf (#6): the value is census-rendering only and is read solely
                -- via `Dict.size` (behind `if lssConfig.report`, default off), so the
                -- per-lambda string build (`defKey ++ "#" ++ fromInt`) was pure garbage.
                -- Keep the key (so the count is unchanged) with a constant value.
                , lamLabels = Dict.insert key "" st.lamLabels
            }
      }
    )


{-| Mint a fresh source-lambda id from the STATE, for the pre-mono passes.

`freshLamId` below is the `Ctx`-level form this pass uses internally; the
pre-mono transforms (`Compiler.GlobalOpt.PreMono.Fresh`) hold only a
`GlobalMVarState`, and they must mint from the SAME supply so that
`Engine.initState`'s `nextMemberId = Id.toComparable state.nextLam` stays past
every id ever minted (LSS\_003). The `lamLabels` key is inserted with the same
constant value `freshLamId` uses, so the census `Dict.size` is unchanged.

-}
mintLamId : GlobalMVarState -> ( TypeIds.SrcLambdaId, GlobalMVarState )
mintLamId st =
    let
        lamId =
            st.nextLam
    in
    ( lamId
    , { st
        | nextLam = Id.succ lamId
        , lamLabels = Dict.insert (Id.toComparable lamId) "" st.lamLabels
      }
    )


{-| Mint a fresh arrow identity from the STATE. The `Ctx`-level `freshArrowId`
below is this pass's internal form; see `mintLamId` for why the pre-mono passes
need the state-level one.
-}
mintArrowId : GlobalMVarState -> ( TypeIds.ArrowId, GlobalMVarState )
mintArrowId st =
    ( st.nextArrow, { st | nextArrow = Id.succ st.nextArrow } )


{-| Mint a fresh arrow identity (Phase 2a,
`plans/lss-unknown-elimination.md` §4.2).

Same `Ctx`-in/`Ctx`-out shape as `freshLamId` so the consuming arm stays a plain
state thread. **This is the ONLY site that mints an `ArrowId`** — every
`Can.Type Name` therefore carries `TypeIds.NoArrow`, which is what makes
`PostSolve`'s whole-tree `existing == t` safe (§4.6c).

-}
freshArrowId : Ctx -> ( TypeIds.ArrowId, Ctx )
freshArrowId ctx =
    let
        st =
            ctx.state

        arrowId =
            st.nextArrow
    in
    ( arrowId, { ctx | state = { st | nextArrow = Id.succ arrowId } } )


{-| Phase 2b: look up or allocate the global `ArrowId` for a solver-rooted
arrow. **Exact mirror of `ensureMVarIdForRoot`, including the module scoping.**

Two arrows the type checker UNIFIED share a union-find root and therefore get
the same `ArrowId` — which is the whole point: a def's annotation arrow and its
body node's arrow are structurally-equal DISTINCT objects (measured: 97.5% of
the time, `plans/lss-unknown-elimination.md` §10.4), so per-occurrence ids
cannot tie them and solver identity can.

`( moduleKey, rootIdx )` because each module's solve numbers its `Pt` from zero;
without scoping, unrelated arrows in different modules collide on a raw index —
which would be a FALSE union of two lambda sets, not merely lost sharing.

-}
ensureArrowIdForRoot : Int -> Ctx -> ( TypeIds.ArrowId, Ctx )
ensureArrowIdForRoot rootIdx ctx =
    let
        key =
            ( ctx.moduleKey, rootIdx )
    in
    case Dict.get key ctx.state.arrowRootEnv of
        Just arrowId ->
            ( arrowId, ctx )

        Nothing ->
            let
                ( arrowId, ctx1 ) =
                    freshArrowId ctx

                st =
                    ctx1.state
            in
            ( arrowId, { ctx1 | state = { st | arrowRootEnv = Dict.insert key arrowId st.arrowRootEnv } } )


{-| Run a function with a fresh binding-local SchemeEnv, then discard the
binding-local env and restore the outer env, keeping only the evolved global state.
-}
withFreshBinding : Ctx -> (Ctx -> ( a, Ctx )) -> ( a, Ctx )
withFreshBinding outerCtx work =
    let
        bindingCtx =
            { outerCtx | env = Dict.empty }

        ( result, bindingCtx1 ) =
            work bindingCtx
    in
    ( result, { outerCtx | state = bindingCtx1.state } )



-- ============================================================================
-- ENTRY POINT
-- ============================================================================


{-| Assign globally unique MVarIds to all type variables in a GlobalGraph.
Returns the rewritten graph and the final allocator state (for initializing MVarEnv).
-}
assignIds : Bool -> Bool -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph TypeIds.MVarId, GlobalMVarState )
assignIds useSolverRoots censusOn (TOpt.GlobalGraph nodes fields annotations allSchemeRoots varSupers) =
    let
        state0 =
            { nextId = TypeIds.firstMVarId
            , superVars = Dict.empty
            , rootEnv = Dict.empty
            , nextLam = TypeIds.firstSrcLambdaId
            , lamLabels = Dict.empty
            , nextArrow = TypeIds.firstArrowId
            , arrowRootEnv = Dict.empty
            , stampCensusOn = censusOn
            , arrowsStamped = 0
            , typesAll = 0
            , typesNone = 0
            , typesPartial = 0
            , arrowsInNone = 0
            , arrowsUnstampedInPartial = 0
            }

        ( newAnnotations, state1 ) =
            rewriteAnnotationsByGlobal useSolverRoots varSupers allSchemeRoots annotations state0

        ( newNodes, state2 ) =
            rewriteNodes useSolverRoots varSupers allSchemeRoots nodes state1
    in
    -- Row 6 (plans/frontend-heap-release.md §7.3): `allSchemeRoots` and
    -- `varSupers` are consumed HERE (they seeded every binder above) and every
    -- later consumer of the assigned graph matches them as `_` (the engines'
    -- entries, the pre-mono passes only pass them through); `rootEnv` and
    -- `arrowRootEnv` are read only by the `ensure*Root` helpers of this pass.
    -- Emitting them would keep them live to the end of monomorphization.
    -- `lamLabels` is still read (census `Dict.size`) and is kept.
    ( TOpt.GlobalGraph newNodes fields newAnnotations DMap.empty Dict.empty
    , { state2 | rootEnv = Dict.empty, arrowRootEnv = Dict.empty }
    )


{-| Assign MVarIds to a single canonical type. Useful for testing.
Returns the rewritten type and the final state.
-}
assignIdsToType : Can.Type Name -> ( Can.Type TypeIds.MVarId, GlobalMVarState )
assignIdsToType canType =
    let
        ctx =
            { env = Dict.empty
            , state = { nextId = TypeIds.firstMVarId, superVars = Dict.empty, rootEnv = Dict.empty, nextLam = TypeIds.firstSrcLambdaId, lamLabels = Dict.empty, nextArrow = TypeIds.firstArrowId, arrowRootEnv = Dict.empty, stampCensusOn = False, arrowsStamped = 0, typesAll = 0, typesNone = 0, typesPartial = 0, arrowsInNone = 0, arrowsUnstampedInPartial = 0 }
            , schemeRootsForDef = Dict.empty
            , varSupers = TOpt.varSupersOfType canType
            , moduleKey = ""
            , defKey = ""
            , useSolverRoots = False
            }

        ( newType, ctx1 ) =
            rewriteCanTypeTop ctx canType
    in
    ( newType, ctx1.state )



-- ============================================================================
-- ID ALLOCATION
-- ============================================================================


{-| Allocate a fresh MVarId, recording its super constraint (if any) in the
side table. The super comes from the solver (via `RootedVar.super` for rooted
vars, or the `varSupers` export for non-rooted names) — never from a name here.
-}
freshMVarId : Maybe Vars.SuperType -> GlobalMVarState -> ( TypeIds.MVarId, GlobalMVarState )
freshMVarId maybeSuper state =
    let
        currentId =
            state.nextId

        newSuperVars =
            case maybeSuper of
                Just s ->
                    Dict.insert (Id.toComparable currentId) s state.superVars

                Nothing ->
                    state.superVars
    in
    ( currentId
    , { state
        | nextId = Id.succ currentId
        , superVars = newSuperVars
      }
    )


{-| Look up or allocate an MVarId for a plain (non-root-backed) type variable
name. Its constraint comes from the `varSupers` export, not the name.
-}
ensureMVarId : Name -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureMVarId name ctx =
    case Dict.get name ctx.env of
        Just mvarId ->
            ( mvarId, ctx )

        Nothing ->
            let
                ( mvarId, newState ) =
                    freshMVarId (Dict.get name ctx.varSupers) ctx.state
            in
            ( mvarId
            , { ctx | env = Dict.insert name mvarId ctx.env, state = newState }
            )


{-| Look up or allocate an MVarId for a solver-root-backed type variable.

Two type-variable names backed by the same solver root get the same MVarId.
The root's super is read from `RootedVar.super` (solver truth about the root),
so a second name claiming the same root cannot disagree — the CNumber
join-upgrade patch that this code used to carry is no longer needed. The
rootEnv key is module-scoped (`(moduleKey, rootIdx)`) because each module's
solve numbers its `Pt` indices from zero; without scoping, unrelated
definitions in different modules could collide on a raw index.

-}
ensureMVarIdForRoot : Vars.RootedVar -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureMVarIdForRoot rooted ctx =
    let
        rootIdx =
            case rooted.var of
                Vars.Pt idx ->
                    idx

        key =
            ( ctx.moduleKey, rootIdx )
    in
    case Dict.get key ctx.state.rootEnv of
        Just mvarId ->
            ( mvarId, ctx )

        Nothing ->
            let
                ( mvarId, newState ) =
                    freshMVarId rooted.super ctx.state

                rootEnv1 =
                    Dict.insert key mvarId newState.rootEnv
            in
            ( mvarId
            , { ctx | state = { newState | rootEnv = rootEnv1 } }
            )


{-| Resolve a type-variable name to an MVarId, dispatching to the root-backed
path when the name has a recorded solver root, else the plain path. This is the
single point of root-vs-plain dispatch (previously duplicated in
`rewriteAnnotation`, which dropped the root super — Bug A).
-}
ensureBinder : Name -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureBinder name ctx =
    case Dict.get name ctx.schemeRootsForDef of
        Just rooted ->
            ensureMVarIdForRoot rooted ctx

        Nothing ->
            ensureMVarId name ctx



-- ============================================================================
-- ANNOTATIONS
-- ============================================================================


{-| Rewrite annotations keyed by Global (for GlobalGraph).
-}
rewriteAnnotationsByGlobal :
    Bool
    -> Dict Name Vars.SuperType
    -> TOpt.SchemeRootsByGlobal
    -> TOpt.AnnotationsByGlobal Name
    -> GlobalMVarState
    -> ( TOpt.AnnotationsByGlobal TypeIds.MVarId, GlobalMVarState )
rewriteAnnotationsByGlobal useSolverRoots varSupers allSchemeRoots annotations state =
    DMap.foldl
        (\global ann ( acc, st ) ->
            let
                schemeRootsForDef =
                    DMap.get TOpt.toComparableGlobal global allSchemeRoots
                        |> Maybe.withDefault Dict.empty

                ( newAnn, st1 ) =
                    rewriteAnnotation useSolverRoots varSupers (moduleKeyOf global) schemeRootsForDef ann st
            in
            ( DMap.insert TOpt.toComparableGlobal global newAnn acc, st1 )
        )
        ( DMap.empty, state )
        annotations


{-| The module-scoping key for a Global's home, used to key the solver-root
environment so per-module `Pt` indices cannot collide across modules.
-}
moduleKeyOf : TOpt.Global -> String
moduleKeyOf global =
    case global of
        TOpt.Global home _ ->
            ModuleName.toComparableCanonical home


rewriteAnnotation :
    Bool
    -> Dict Name Vars.SuperType
    -> String
    -> SolverRoots.SchemeRootsForDef
    -> Can.Annotation Name
    -> GlobalMVarState
    -> ( Can.Annotation TypeIds.MVarId, GlobalMVarState )
rewriteAnnotation useSolverRoots varSupers moduleKey schemeRootsForDef (Can.Forall freeVars tipe) state =
    let
        ctx0 =
            { env = Dict.empty
            , state = state
            , schemeRootsForDef = schemeRootsForDef
            , varSupers = varSupers
            , moduleKey = moduleKey
            , defKey = "" -- annotations contain no lambdas; label context unused
            , useSolverRoots = useSolverRoots
            }

        -- Pre-seed the binder env (and rootEnv) via the shared dispatch so the
        -- annotation and this def's nodes agree on every binder's MVarId.
        ctxSeeded =
            Dict.foldl (\name _ c -> Tuple.second (ensureBinder name c)) ctx0 freeVars

        ( newType, ctx1 ) =
            rewriteCanTypeTop ctxSeeded tipe
    in
    ( Can.Forall freeVars newType, ctx1.state )



-- ============================================================================
-- NODES
-- ============================================================================


rewriteNodes :
    Bool
    -> Dict Name Vars.SuperType
    -> TOpt.SchemeRootsByGlobal
    -> DMap.Dict String TOpt.Global (TOpt.Node Name)
    -> GlobalMVarState
    -> ( DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId), GlobalMVarState )
rewriteNodes useSolverRoots varSupers allSchemeRoots nodes state =
    DMap.foldl
        (\global node ( acc, st ) ->
            let
                -- Look up scheme roots for this definition by Global key
                schemeRootsForDef =
                    DMap.get TOpt.toComparableGlobal global allSchemeRoots
                        |> Maybe.withDefault Dict.empty

                -- Fresh SchemeEnv per node, with solver roots
                ctx =
                    { env = Dict.empty
                    , state = st
                    , schemeRootsForDef = schemeRootsForDef
                    , varSupers = varSupers
                    , moduleKey = moduleKeyOf global
                    , defKey = TOpt.toComparableGlobal global
                    , useSolverRoots = useSolverRoots
                    }

                ( newNode, ctx1 ) =
                    rewriteNode ctx node
            in
            ( DMap.insert TOpt.toComparableGlobal global newNode acc, ctx1.state )
        )
        ( DMap.empty, state )
        nodes


rewriteNode : Ctx -> TOpt.Node Name -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx node =
    case node of
        TOpt.Define expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.Define newExpr deps newMeta, ctx2 )

        TOpt.TrackedDefine region expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.TrackedDefine region newExpr deps newMeta, ctx2 )

        TOpt.Ctor index arity canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanTypeTop ctx canType
            in
            ( TOpt.Ctor index arity newType, ctx1 )

        TOpt.Enum index canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanTypeTop ctx canType
            in
            ( TOpt.Enum index newType, ctx1 )

        TOpt.Box canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanTypeTop ctx canType
            in
            ( TOpt.Box newType, ctx1 )

        TOpt.Link global ->
            ( TOpt.Link global, ctx )

        TOpt.Cycle names valueDefs funcDefs deps ->
            let
                ( newValueDefs, ctx1 ) =
                    rewriteValueDefs ctx valueDefs

                ( newFuncDefs, ctx2 ) =
                    rewriteDefs ctx1 funcDefs
            in
            ( TOpt.Cycle names newValueDefs newFuncDefs deps, ctx2 )

        TOpt.Manager effectsType ->
            ( TOpt.Manager effectsType, ctx )

        TOpt.Kernel chunks deps ->
            ( TOpt.Kernel chunks deps, ctx )

        TOpt.PortIncoming expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.PortIncoming newExpr deps newMeta, ctx2 )

        TOpt.PortOutgoing expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.PortOutgoing newExpr deps newMeta, ctx2 )



-- ============================================================================
-- META
-- ============================================================================


rewriteMeta : Ctx -> TOpt.Meta Name -> ( TOpt.Meta TypeIds.MVarId, Ctx )
rewriteMeta ctx meta =
    let
        ( newType, ctx1 ) =
            rewriteCanTypeTop ctx meta.tipe
    in
    ( { tipe = newType, tvar = meta.tvar }, ctx1 )



-- ============================================================================
-- EXPRESSIONS
-- ============================================================================


rewriteExpr : Ctx -> TOpt.Expr Name -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.Bool region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Bool region val newMeta, ctx1 )

        TOpt.Chr region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Chr region val newMeta, ctx1 )

        TOpt.Str region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Str region val newMeta, ctx1 )

        TOpt.Int region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Int region val newMeta, ctx1 )

        TOpt.Float region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Float region val newMeta, ctx1 )

        TOpt.VarLocal name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarLocal name newMeta, ctx1 )

        TOpt.TrackedVarLocal region name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.TrackedVarLocal region name newMeta, ctx1 )

        TOpt.VarGlobal region global meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarGlobal region global newMeta, ctx1 )

        TOpt.VarEnum region global index meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarEnum region global index newMeta, ctx1 )

        TOpt.VarBox region global meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarBox region global newMeta, ctx1 )

        TOpt.VarCycle region canonical name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarCycle region canonical name newMeta, ctx1 )

        TOpt.VarDebug region name canonical maybeName meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarDebug region name canonical maybeName newMeta, ctx1 )

        TOpt.VarKernel region home name1 name2 meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarKernel region home name1 name2 newMeta, ctx1 )

        TOpt.List region items meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newItems, ctx2 ) =
                    rewriteExprList ctx1 items
            in
            ( TOpt.List region newItems newMeta, ctx2 )

        TOpt.Function _ args body meta ->
            let
                ( lamId, ctx0a ) =
                    freshLamId ctx

                ( newMeta, ctx1 ) =
                    rewriteMeta ctx0a meta

                ( newArgs, ctx2 ) =
                    rewriteTypedArgs ctx1 args

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.Function (Just lamId) newArgs newBody newMeta, ctx3 )

        TOpt.TrackedFunction _ args body meta ->
            let
                ( lamId, ctx0a ) =
                    freshLamId ctx

                ( newMeta, ctx1 ) =
                    rewriteMeta ctx0a meta

                ( newArgs, ctx2 ) =
                    rewriteTrackedArgs ctx1 args

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.TrackedFunction (Just lamId) newArgs newBody newMeta, ctx3 )

        TOpt.Call region func args meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newFunc, ctx2 ) =
                    rewriteExpr ctx1 func

                ( newArgs, ctx3 ) =
                    rewriteExprList ctx2 args
            in
            ( TOpt.Call region newFunc newArgs newMeta, ctx3 )

        TOpt.TailCall name args meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newArgs, ctx2 ) =
                    rewriteNamedExprList ctx1 args
            in
            ( TOpt.TailCall name newArgs newMeta, ctx2 )

        TOpt.If branches final meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newBranches, ctx2 ) =
                    rewriteBranches ctx1 branches

                ( newFinal, ctx3 ) =
                    rewriteExpr ctx2 final
            in
            ( TOpt.If newBranches newFinal newMeta, ctx3 )

        TOpt.Let def body meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newDef, ctx2 ) =
                    rewriteDef ctx1 def

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.Let newDef newBody newMeta, ctx3 )

        TOpt.Destruct destructor body meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newDestructor, ctx2 ) =
                    rewriteDestructor ctx1 destructor

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.Destruct newDestructor newBody newMeta, ctx3 )

        TOpt.Case scrutName scrutVarName decider jumps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newDecider, ctx2 ) =
                    rewriteDecider ctx1 decider

                ( newJumps, ctx3 ) =
                    rewriteJumps ctx2 jumps
            in
            ( TOpt.Case scrutName scrutVarName newDecider newJumps newMeta, ctx3 )

        TOpt.Accessor region name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Accessor region name newMeta, ctx1 )

        TOpt.Access subExpr region name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newSubExpr, ctx2 ) =
                    rewriteExpr ctx1 subExpr
            in
            ( TOpt.Access newSubExpr region name newMeta, ctx2 )

        TOpt.Update region subExpr updates meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newSubExpr, ctx2 ) =
                    rewriteExpr ctx1 subExpr

                ( newUpdates, ctx3 ) =
                    rewriteDataMapExprs ctx2 updates
            in
            ( TOpt.Update region newSubExpr newUpdates newMeta, ctx3 )

        TOpt.Record fields meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newFields, ctx2 ) =
                    rewriteDictExprs ctx1 fields
            in
            ( TOpt.Record newFields newMeta, ctx2 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newFields, ctx2 ) =
                    rewriteDataMapExprs ctx1 fields
            in
            ( TOpt.TrackedRecord region newFields newMeta, ctx2 )

        TOpt.Unit meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Unit newMeta, ctx1 )

        TOpt.Tuple region a b rest meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newA, ctx2 ) =
                    rewriteExpr ctx1 a

                ( newB, ctx3 ) =
                    rewriteExpr ctx2 b

                ( newRest, ctx4 ) =
                    rewriteExprList ctx3 rest
            in
            ( TOpt.Tuple region newA newB newRest newMeta, ctx4 )

        TOpt.Shader src attributes uniforms meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Shader src attributes uniforms newMeta, ctx1 )



-- ============================================================================
-- HELPERS: Lists and collections
-- ============================================================================


rewriteExprList : Ctx -> List (TOpt.Expr Name) -> ( List (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteExprList ctx exprs =
    List.foldl
        (\e ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( newE :: acc, c1 )
        )
        ( [], ctx )
        exprs
        |> Tuple.mapFirst List.reverse


rewriteNamedExprList : Ctx -> List ( Name, TOpt.Expr Name ) -> ( List ( Name, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteNamedExprList ctx pairs =
    List.foldl
        (\( name, e ) ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( ( name, newE ) :: acc, c1 )
        )
        ( [], ctx )
        pairs
        |> Tuple.mapFirst List.reverse


rewriteBranches : Ctx -> List ( TOpt.Expr Name, TOpt.Expr Name ) -> ( List ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteBranches ctx branches =
    List.foldl
        (\( cond, body ) ( acc, c ) ->
            let
                ( newCond, c1 ) =
                    rewriteExpr c cond

                ( newBody, c2 ) =
                    rewriteExpr c1 body
            in
            ( ( newCond, newBody ) :: acc, c2 )
        )
        ( [], ctx )
        branches
        |> Tuple.mapFirst List.reverse


rewriteTypedArgs : Ctx -> List ( Name, Can.Type Name ) -> ( List ( Name, Can.Type TypeIds.MVarId ), Ctx )
rewriteTypedArgs ctx args =
    List.foldl
        (\( name, tipe ) ( acc, c ) ->
            let
                ( newType, c1 ) =
                    rewriteCanTypeTop c tipe
            in
            ( ( name, newType ) :: acc, c1 )
        )
        ( [], ctx )
        args
        |> Tuple.mapFirst List.reverse


rewriteTrackedArgs : Ctx -> List ( A.Located Name, Can.Type Name ) -> ( List ( A.Located Name, Can.Type TypeIds.MVarId ), Ctx )
rewriteTrackedArgs ctx args =
    List.foldl
        (\( locName, tipe ) ( acc, c ) ->
            let
                ( newType, c1 ) =
                    rewriteCanTypeTop c tipe
            in
            ( ( locName, newType ) :: acc, c1 )
        )
        ( [], ctx )
        args
        |> Tuple.mapFirst List.reverse


rewriteDictExprs : Ctx -> Dict Name (TOpt.Expr Name) -> ( Dict Name (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteDictExprs ctx dict =
    Dict.foldl
        (\key e ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( Dict.insert key newE acc, c1 )
        )
        ( Dict.empty, ctx )
        dict


rewriteDataMapExprs : Ctx -> DMap.Dict String (A.Located Name) (TOpt.Expr Name) -> ( DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteDataMapExprs ctx dmap =
    let
        toComparable (A.At _ name) =
            name
    in
    DMap.foldl
        (\key e ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( DMap.insert toComparable key newE acc, c1 )
        )
        ( DMap.empty, ctx )
        dmap


rewriteValueDefs : Ctx -> List ( Name, TOpt.Expr Name ) -> ( List ( Name, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteValueDefs ctx defs =
    List.foldl
        (\( name, expr ) ( acc, outerCtx ) ->
            let
                ( newExpr, outerCtx1 ) =
                    withFreshBinding outerCtx (\bindingCtx -> rewriteExpr bindingCtx expr)
            in
            ( ( name, newExpr ) :: acc, outerCtx1 )
        )
        ( [], ctx )
        defs
        |> Tuple.mapFirst List.reverse


rewriteDefs : Ctx -> List (TOpt.Def Name) -> ( List (TOpt.Def TypeIds.MVarId), Ctx )
rewriteDefs ctx defs =
    List.foldl
        (\d ( acc, c ) ->
            let
                ( newD, c1 ) =
                    rewriteDef c d
            in
            ( newD :: acc, c1 )
        )
        ( [], ctx )
        defs
        |> Tuple.mapFirst List.reverse


rewriteDef : Ctx -> TOpt.Def Name -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef outerCtx def =
    case def of
        TOpt.Def region name body canType ->
            withFreshBinding outerCtx
                (\bindingCtx ->
                    let
                        ( newType, bindingCtx1 ) =
                            rewriteCanTypeTop bindingCtx canType

                        ( newBody, bindingCtx2 ) =
                            rewriteExpr bindingCtx1 body
                    in
                    ( TOpt.Def region name newBody newType, bindingCtx2 )
                )

        TOpt.TailDef region name args body canType maybeTvar ->
            withFreshBinding outerCtx
                (\bindingCtx ->
                    let
                        ( newType, bindingCtx1 ) =
                            rewriteCanTypeTop bindingCtx canType

                        ( newArgs, bindingCtx2 ) =
                            rewriteTrackedArgs bindingCtx1 args

                        ( newBody, bindingCtx3 ) =
                            rewriteExpr bindingCtx2 body
                    in
                    ( TOpt.TailDef region name newArgs newBody newType maybeTvar, bindingCtx3 )
                )


rewriteDestructor : Ctx -> TOpt.Destructor Name -> ( TOpt.Destructor TypeIds.MVarId, Ctx )
rewriteDestructor ctx (TOpt.Destructor name path meta) =
    let
        ( newMeta, ctx1 ) =
            rewriteMeta ctx meta
    in
    ( TOpt.Destructor name path newMeta, ctx1 )


rewriteDecider : Ctx -> TOpt.Decider (TOpt.Choice Name) -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
rewriteDecider ctx decider =
    case decider of
        TOpt.Leaf choice ->
            let
                ( newChoice, ctx1 ) =
                    rewriteChoice ctx choice
            in
            ( TOpt.Leaf newChoice, ctx1 )

        TOpt.Chain tests yes no ->
            let
                ( newYes, ctx1 ) =
                    rewriteDecider ctx yes

                ( newNo, ctx2 ) =
                    rewriteDecider ctx1 no
            in
            ( TOpt.Chain tests newYes newNo, ctx2 )

        TOpt.FanOut path options fallback ->
            let
                ( newOptions, ctx1 ) =
                    List.foldl
                        (\( test, dec ) ( acc, c ) ->
                            let
                                ( newDec, c1 ) =
                                    rewriteDecider c dec
                            in
                            ( ( test, newDec ) :: acc, c1 )
                        )
                        ( [], ctx )
                        options
                        |> Tuple.mapFirst List.reverse

                ( newFallback, ctx2 ) =
                    rewriteDecider ctx1 fallback
            in
            ( TOpt.FanOut path newOptions newFallback, ctx2 )


rewriteChoice : Ctx -> TOpt.Choice Name -> ( TOpt.Choice TypeIds.MVarId, Ctx )
rewriteChoice ctx choice =
    case choice of
        TOpt.Inline expr ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr ctx expr
            in
            ( TOpt.Inline newExpr, ctx1 )

        TOpt.Jump idx ->
            ( TOpt.Jump idx, ctx )


rewriteJumps : Ctx -> List ( Int, TOpt.Expr Name ) -> ( List ( Int, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteJumps ctx jumps =
    List.foldl
        (\( idx, e ) ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( ( idx, newE ) :: acc, c1 )
        )
        ( [], ctx )
        jumps
        |> Tuple.mapFirst List.reverse



-- ============================================================================
-- CANONICAL TYPE REWRITING
-- ============================================================================


{-| Stamping-walk census (plans/lss-provenance-ratio-census.md §8): classify one
TOP-LEVEL type by how much of it `SolverRoots.stampArrowRoots` managed to stamp.

The walk returns a node unstamped AND unrecursed on a lockstep mismatch, so a
single failure sheds an entire subtree. Reading the stamped OUTPUT recovers the
split that matters without any cross-phase plumbing:

  - some stamped, some not => the walk RAN, DESCENDED, and then BROKE. Provable
    mid-walk abandonment.
  - none stamped => never walked, or failed at the very root. No repair to the
    walk can help this population.

Deltas come from `nextArrow` and `arrowsStamped`, never a `Dict.size` — that is
O(n) in Elm and would make the pass quadratic.

MUST wrap only the EXTERNAL call sites. Wrapping the recursive calls inside
`rewriteCanType` would count every subtree as its own "type" and the
`RECONCILES` check would still pass, silently measuring the wrong population.

-}
rewriteCanTypeTop : Ctx -> Can.Type Name -> ( Can.Type TypeIds.MVarId, Ctx )
rewriteCanTypeTop ctx canType =
    let
        arrowsBefore =
            Id.toComparable ctx.state.nextArrow

        stampedBefore =
            ctx.state.arrowsStamped

        ( out, ctx1 ) =
            rewriteCanType ctx canType

        st =
            ctx1.state

        arrows =
            Id.toComparable st.nextArrow - arrowsBefore

        stamped =
            st.arrowsStamped - stampedBefore
    in
    if not st.stampCensusOn || arrows == 0 then
        -- Census off, or no arrows at all: not part of the population.
        ( out, ctx1 )

    else if stamped == arrows then
        ( out, { ctx1 | state = { st | typesAll = st.typesAll + 1 } } )

    else if stamped == 0 then
        ( out
        , { ctx1
            | state =
                { st
                    | typesNone = st.typesNone + 1
                    , arrowsInNone = st.arrowsInNone + arrows
                }
          }
        )

    else
        ( out
        , { ctx1
            | state =
                { st
                    | typesPartial = st.typesPartial + 1
                    , arrowsUnstampedInPartial =
                        st.arrowsUnstampedInPartial + (arrows - stamped)
                }
          }
        )


rewriteCanType : Ctx -> Can.Type Name -> ( Can.Type TypeIds.MVarId, Ctx )
rewriteCanType ctx canType =
    case canType of
        Can.TVar name ->
            let
                ( mvarId, ctx1 ) =
                    ensureBinder name ctx
            in
            ( Can.TVar mvarId, ctx1 )

        Can.TLambda slot from to ->
            -- Resolve this arrow's identity in PRE-order (before descending).
            -- `Store.loadTypeC` consumes its SLOTS post-order; the two orders
            -- are independent — the ordinal contract is defined by
            -- `arrowSlots`, not by id order — but one is picked deliberately
            -- and written down, because an id-keyed `ArrowFact` wants a stable
            -- walkable order.
            let
                ( arrowId, ctx0 ) =
                    case slot of
                        TypeIds.SolverRoot rootIdx ->
                            -- Phase 2b: the type checker's own identity. Two
                            -- arrows it unified land on one ArrowId.
                            if ctx.useSolverRoots then
                                ensureArrowIdForRoot rootIdx ctx

                            else
                                -- Phase 2b off: per syntactic OCCURRENCE, the
                                -- Phase 2a identity.
                                freshArrowId ctx

                        _ ->
                            -- Phase 2a fallback: per syntactic OCCURRENCE.
                            -- Also the only path for types built after the
                            -- solve (they carry `NoArrow`), and the reason
                            -- 2b degrades rather than breaks where the
                            -- lockstep stamp walk lost the solver var.
                            freshArrowId ctx

                ( newFrom, ctx1 ) =
                    rewriteCanType ctx0 from

                ( newTo, ctx2 ) =
                    rewriteCanType ctx1 to
            in
            ( Can.TLambda (TypeIds.Arrow arrowId) newFrom newTo, ctx2 )

        Can.TType canonical name args ->
            let
                ( newArgs, ctx1 ) =
                    rewriteCanTypeList ctx args
            in
            ( Can.TType canonical name newArgs, ctx1 )

        Can.TRecord fields maybeExt ->
            let
                ( newFields, ctx1 ) =
                    rewriteFieldTypes ctx fields

                ( newExt, ctx2 ) =
                    case maybeExt of
                        Just extName ->
                            let
                                ( mvarId, c ) =
                                    ensureBinder extName ctx1
                            in
                            ( Just mvarId, c )

                        Nothing ->
                            ( Nothing, ctx1 )
            in
            ( Can.TRecord newFields newExt, ctx2 )

        Can.TUnit ->
            ( Can.TUnit, ctx )

        Can.TTuple a b rest ->
            let
                ( newA, ctx1 ) =
                    rewriteCanType ctx a

                ( newB, ctx2 ) =
                    rewriteCanType ctx1 b

                ( newRest, ctx3 ) =
                    rewriteCanTypeList ctx2 rest
            in
            ( Can.TTuple newA newB newRest, ctx3 )

        Can.TAlias canonical name args aliasType ->
            let
                ( newArgs, ctx1 ) =
                    List.foldl
                        (\( argName, t ) ( acc, c ) ->
                            let
                                -- Convert alias parameter name to MVarId, using root if available
                                ( paramId, c0 ) =
                                    ensureBinder argName c

                                ( newT, c1 ) =
                                    rewriteCanType c0 t
                            in
                            ( ( paramId, newT ) :: acc, c1 )
                        )
                        ( [], ctx )
                        args
                        |> Tuple.mapFirst List.reverse

                ( newAliasType, ctx2 ) =
                    rewriteAliasType ctx1 aliasType
            in
            ( Can.TAlias canonical name newArgs newAliasType, ctx2 )


rewriteCanTypeList : Ctx -> List (Can.Type Name) -> ( List (Can.Type TypeIds.MVarId), Ctx )
rewriteCanTypeList ctx types =
    List.foldl
        (\t ( acc, c ) ->
            let
                ( newT, c1 ) =
                    rewriteCanType c t
            in
            ( newT :: acc, c1 )
        )
        ( [], ctx )
        types
        |> Tuple.mapFirst List.reverse


rewriteFieldTypes : Ctx -> Dict Name (Can.FieldType Name) -> ( Dict Name (Can.FieldType TypeIds.MVarId), Ctx )
rewriteFieldTypes ctx fields =
    Dict.foldl
        (\fieldName (Can.FieldType idx t) ( acc, c ) ->
            let
                ( newT, c1 ) =
                    rewriteCanType c t
            in
            ( Dict.insert fieldName (Can.FieldType idx newT) acc, c1 )
        )
        ( Dict.empty, ctx )
        fields


rewriteAliasType : Ctx -> Can.AliasType Name -> ( Can.AliasType TypeIds.MVarId, Ctx )
rewriteAliasType ctx aliasType =
    case aliasType of
        Can.Holey t ->
            let
                ( newT, ctx1 ) =
                    rewriteCanType ctx t
            in
            ( Can.Holey newT, ctx1 )

        Can.Filled t ->
            let
                ( newT, ctx1 ) =
                    rewriteCanType ctx t
            in
            ( Can.Filled newT, ctx1 )
