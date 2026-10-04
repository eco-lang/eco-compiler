module Compiler.MonoSolver.Translate exposing
    ( translate
    , demandUnifyRoot, enumNode, specializeCtorViaScheme, specializeCycle, specializePort, stampSelfSpine
    )

{-| Translate a TypedOptimized expression into a monomorphized expression — the
M1 (monomorphic-spine) arms, ported from `Specialize.specializeExpr`.

Node types come from `Zonk.canTypeToMono` (the pure `applySubstPure`-with-empty-
subst classification, correct for monomorphic globals). Kernel-call ABIs use the
store (`Store.instantiate`-style fresh load + unify param slots with the concrete
arg types + zonk) to reproduce `deriveKernelAbiType` exactly. Everything the M1
spine does not yet cover returns `Engine.crashFailure (Unsupported …)` — never a fallback
to the original engine.

@docs translate
@docs demandUnifyRoot, enumNode, specializeCtorViaScheme, specializeCycle, specializePort, stampSelfSpine

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), Step)
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.MonoSolver.LssInfer as LssInfer
import Compiler.MonoSolver.Store as Store
import Compiler.MonoSolver.Zonk as Zonk
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State
import Compiler.Reporting.Annotation as A
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Map as DMap
import Data.Set as EverySet
import Dict
import Set


{-| `classify`, attributing the ⊤s it stamps to a CALLER CLASS
(plans/lss-ctor-arrow-identity.md §9.3). `classifyGo`'s `Can.TLambda` arm is
the sole manufacturer of surviving decl ⊤s, but it is shared by ~23 call
sites; the kind says WHICH of them, which is what decides whether a
store-aware alternative exists there. Diagnostic only — every semantic reader
is ⊤-kind-blind.
-}
classifyAs : Int -> Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classifyAs topKind canType s =
    Store.classifyDirect topKind canType s


{-| Assert a demanded MonoType against a definition's annotation in the store,
concretizing the annotation's scheme variables (shared with the body via the
item memo). A no-op when the demand equals the annotation (monomorphic case).
-}
demandUnify : Can.Type TypeIds.MVarId -> Mono.MonoType -> Engine.S -> Engine.S
demandUnify annCanType demand s0 =
    Tuple.second (demandUnifyVar annCanType demand s0)


{-| `demandUnify` returning the loaded annotation var. Function-root defs
stash it (`S.lssRootAnn`) so the root lambda's `classifyLambdaHead` can
reuse THE seeded var: `Store.loadType` mints fresh arrow structure per load
(LSS\_006 — only leaf MVarIds are memo-shared), so re-loading a GROUND
annotation shares nothing and the demand's lambda-set content would be
unreachable from the def's binder types.
-}
demandUnifyVar : Can.Type TypeIds.MVarId -> Mono.MonoType -> Engine.S -> ( Vars.Variable, Engine.S )
demandUnifyVar annCanType demand s0 =
    case Store.loadTypeS annCanType s0 of
        ( annVar, s1 ) ->
            case Store.monoTypeToVarS demand s1 of
                ( demandVar, s2 ) ->
                    ( annVar
                    , Store.unifyStrictS
                        (\() -> "demandUnify " ++ canKind annCanType ++ " vs " ++ monoKind demand)
                        annVar
                        demandVar
                        s2
                    )


{-| `demandUnify` for a def root: when the def's expression is syntactically
a lambda and lss is on, stash the seeded annotation var for the root
`classifyLambdaHead` to consume (see `demandUnifyVar`). Non-function defs
and lss-off behave exactly like `demandUnify`.
-}
demandUnifyRoot : Can.Type TypeIds.MVarId -> Mono.MonoType -> TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
demandUnifyRoot annCanType demand expr s0 =
    case demandUnifyVar annCanType demand s0 of
        ( annVar, s1 ) ->
            let
                -- §5.1: stash the def's root type Point for the shadow-`Q`
                -- partition. Report-gated, and NOT gated on `exprIsLambda` —
                -- a non-lambda def's type still carries arrows (`fns = [incr,
                -- decr]`), and those are exactly the σ the partition is about.
                sQ =
                    if s1.env.lss.enabled && s1.env.lss.qCensus then
                        let
                            auxQ =
                                s1.itemAux
                        in
                        { s1 | itemAux = { auxQ | qSigRoot = Just annVar } }

                    else
                        s1
            in
            if sQ.env.lss.enabled && exprIsLambda expr then
                let
                    aux1 =
                        sQ.itemAux
                in
                { sQ | itemAux = { aux1 | lssRootAnn = Just ( annCanType, annVar ) } }

            else
                sQ


exprIsLambda : TOpt.Expr TypeIds.MVarId -> Bool
exprIsLambda expr =
    case expr of
        TOpt.Function _ _ _ _ ->
            True

        TOpt.TrackedFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Best-effort in-store unification of two canonical types (child vs parent
context): loads both through the item memo and unifies, so a child's fresh
use-var picks up the context's already-concretized demand before the child is
translated. Never fails — the typechecker already proved these compatible; any
residual weirdness just leaves vars unbound.
-}
connectTypes : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
connectTypes childCan parentCan s0 =
    -- Step 9: when BOTH sides are ground and arrow-free there is nothing to
    -- connect. Such a type has no `TVar`, so it touches neither the var memo
    -- nor `revMemo`; no `TLambda`, so it mints no set slot and leaves the
    -- LSS_006 ordinal machinery alone. The two loads would build structures
    -- nothing else references and the unify would merge them with each other.
    -- The only reachable change is Points nobody can name, so skipping is
    -- exact — and it saves two loads, two write-backs and a unify.
    --
    -- The predicate answers an alias occurrence from step 4's verdict map, so
    -- it is O(1) for `S`, `Env` and `ItemAux` after their first classify.
    if Store.groundNoArrowWith s0.monoMemo.aliasMemo childCan && Store.groundNoArrowWith s0.monoMemo.aliasMemo parentCan then
        s0

    else
        -- A1: direct state-passing (desugared andThen) → byte-identical.
        -- Step 10b: `loadTypeS` never fails, so the two `Err` arms this had
        -- were dead; the function returns `S` and allocates nothing at all.
        let
            ( parentVar, s1 ) =
                Store.loadTypeS parentCan s0

            ( childVar, s2 ) =
                Store.loadTypeS childCan s1
        in
        unifyBestEffortS childVar parentVar s2


{-| MONO\_029 R1: unify each TailCall argument's canType with the enclosing
tail-recursive function's matching loop-param canType (frames pushed around
TailDef bodies, matched by function then arg name). Best-effort like every
connect.
-}
connectTailCallArgs : Name -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> Engine.S -> Engine.S
connectTailCallArgs funcName args s0 =
    case lookupLoopFrame funcName s0.itemAux.loopParams of
        Nothing ->
            s0

        Just params ->
            connectTailArgsGo params args s0


connectTailArgsGo : List ( String, Can.Type TypeIds.MVarId ) -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> Engine.S -> Engine.S
connectTailArgsGo params args s0 =
    case args of
        [] ->
            s0

        ( argName, argExpr ) :: rest ->
            case List.filter (\( pn, _ ) -> pn == argName) params of
                ( _, pCan ) :: _ ->
                    connectTailArgsGo params rest (connectTypes (TOpt.typeOf argExpr) pCan s0)

                [] ->
                    connectTailArgsGo params rest s0


lookupLoopFrame : Name -> List ( String, List ( String, Can.Type TypeIds.MVarId ) ) -> Maybe (List ( String, Can.Type TypeIds.MVarId ))
lookupLoopFrame funcName frames =
    case frames of
        [] ->
            Nothing

        ( n, ps ) :: rest ->
            if n == funcName then
                Just ps

            else
                lookupLoopFrame funcName rest


{-| Run a step with a tail-recursion loop-param frame pushed (consumed by the
TailCall arm's `connectTailCallArgs`), restoring the frame stack after.
-}
withLoopFrame : Name -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> Step a -> Step a
withLoopFrame name typedArgs step s0 =
    let
        frame =
            ( name, List.map (\( ln, t ) -> ( A.toValue ln, t )) typedArgs )
    in
    let
        aux0 =
            s0.itemAux
    in
    case step { s0 | itemAux = { aux0 | loopParams = frame :: aux0.loopParams } } of
        ( a, s1 ) ->
            let
                aux1 =
                    s1.itemAux
            in
            ( a, { s1 | itemAux = { aux1 | loopParams = s0.itemAux.loopParams } } )


{-| The element type of a canonical `List a` (through filled aliases).
-}
listElemCanType : Can.Type TypeIds.MVarId -> Maybe (Can.Type TypeIds.MVarId)
listElemCanType t =
    case t of
        Can.TType _ "List" [ elem ] ->
            Just elem

        Can.TAlias _ _ _ (Can.Filled inner) ->
            listElemCanType inner

        _ ->
            Nothing


{-| The slot types of a canonical tuple (through filled aliases).
-}
tupleSlotCanTypes : Can.Type TypeIds.MVarId -> Maybe (List (Can.Type TypeIds.MVarId))
tupleSlotCanTypes t =
    case t of
        Can.TTuple a b rest ->
            Just (a :: b :: rest)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            tupleSlotCanTypes inner

        _ ->
            Nothing


{-| Connect each record-literal field expr's type to the record type's field
slot (through filled aliases); fields without a slot are skipped.
-}
connectRecordFields : List ( Name, TOpt.Expr TypeIds.MVarId ) -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
connectRecordFields fieldExprs recordCanType s0 =
    -- Step 10b: `List.foldl` visits left-to-right exactly as `traverseGo` did,
    -- so the unification order — and therefore every Point index — is unchanged.
    case recordFieldCanTypes recordCanType of
        Just fieldCans ->
            List.foldl
                (\( name, fieldExpr ) sa ->
                    case Dict.get name fieldCans of
                        Just fieldCan ->
                            connectTypes (TOpt.typeOf fieldExpr) fieldCan sa

                        Nothing ->
                            sa
                )
                s0
                fieldExprs

        Nothing ->
            s0


recordFieldCanTypes : Can.Type TypeIds.MVarId -> Maybe (Dict.Dict Name (Can.Type TypeIds.MVarId))
recordFieldCanTypes t =
    case t of
        Can.TRecord fields _ ->
            Just (Dict.map (\_ (Can.FieldType _ ft) -> ft) fields)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            recordFieldCanTypes inner

        _ ->
            Nothing


{-| Perf (#10): read a SINGLE field's canonical type with one `Dict.get`, without
`recordFieldCanTypes`' `Dict.map` that allocates a whole fresh field tree per access.
-}
recordFieldCanType : Name -> Can.Type TypeIds.MVarId -> Maybe (Can.Type TypeIds.MVarId)
recordFieldCanType f t =
    case t of
        Can.TRecord fields _ ->
            Dict.get f fields |> Maybe.map (\(Can.FieldType _ ft) -> ft)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            recordFieldCanType f inner

        _ ->
            Nothing


{-| Translate one typed optimized expression into a monomorphized expression,
resolving its types through the engine state.
-}
translate : TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
translate expr s0 =
    -- Injection-totality census (plans/lss-injection-completeness.md §2.1):
    -- one report-gated classification per translated node. Behavior-free by
    -- construction — `censusProducer` only bumps counters, and reads
    -- signature state without forcing it.
    case translateDispatch expr s0 of
        ( monoExpr, s1 ) ->
            ( monoExpr, censusProducer expr s1 )


{-| Injection-totality census (plans/lss-injection-completeness.md §2.1).
REPORT-GATED; one head-arrow test per node when on, nothing when off.

Classifies every expression whose type's HEAD is an arrow — i.e. every
position holding a function VALUE — by producer form. `inj|papKnown|*` is the
headline: partial applications of known globals, the one producer form that
injects no lambda-set member today (the `arrowSolverRoots` false-singleton
class). Verdicts are FORM-derived, not write-provenance-derived: `papKnown`
IS the none-population by construction, and `callResult|trivial` is the
"totality unproven" bucket (a trivial-signature callee carries no fact at its
result ordinal).

Reads triviality via `Engine.memoizedSignatureTrivial` ONLY — forcing a
signature here would move member-id allocation order, and `report` is
excluded from the config hash (the `censusArgs` lesson above).

-}
censusProducer : TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
censusProducer expr s =
    if not (s.env.lss.report && s.env.lss.enabled && headIsArrow (TOpt.typeOf expr)) then
        s

    else
        Engine.bumpArgFlowCensus ("inj|" ++ producerKey expr s) s


{-| Is the HEAD of this canonical type an arrow (following aliases)?
Head-position only — the type of a value that IS a function — unlike
`canTypeHasArrow`, which finds arrows anywhere inside.
-}
headIsArrow : Can.Type TypeIds.MVarId -> Bool
headIsArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled real) ->
            headIsArrow real

        Can.TAlias _ _ _ (Can.Holey real) ->
            headIsArrow real

        _ ->
            False


producerKey : TOpt.Expr TypeIds.MVarId -> Engine.S -> String
producerKey expr s =
    case expr of
        TOpt.Function _ _ _ _ ->
            "lambda"

        TOpt.TrackedFunction _ _ _ _ ->
            "lambda"

        TOpt.VarGlobal _ _ _ ->
            "ref"

        TOpt.VarEnum _ _ _ _ ->
            "ref"

        TOpt.VarBox _ _ _ ->
            "ref"

        TOpt.VarCycle _ _ _ _ ->
            "ref"

        TOpt.VarKernel _ _ _ _ _ ->
            "kernel"

        TOpt.VarLocal _ _ ->
            "local"

        TOpt.TrackedVarLocal _ _ _ ->
            "local"

        TOpt.Call _ func args _ ->
            censusCallKey func (List.length args) s

        TOpt.If _ _ _ ->
            "branch"

        TOpt.Case _ _ _ _ _ ->
            "branch"

        TOpt.Let _ _ _ ->
            "let"

        TOpt.Destruct _ _ _ ->
            "let"

        TOpt.Accessor _ _ _ ->
            "accessor"

        TOpt.Access _ _ _ _ ->
            "read"

        _ ->
            "other"


censusCallKey : TOpt.Expr TypeIds.MVarId -> Int -> Engine.S -> String
censusCallKey func supplied s =
    case censusCallGlobal func of
        Just g ->
            let
                declared =
                    LssInfer.declaredArityOf g 8 s
            in
            if declared > supplied then
                "papKnown|d" ++ String.fromInt (declared - supplied)

            else
                case Engine.memoizedSignatureTrivial g s of
                    Just True ->
                        "callResult|trivial"

                    Just False ->
                        "callResult|nontrivial"

                    Nothing ->
                        "callResult|unmemoized"

        Nothing ->
            case func of
                TOpt.VarKernel _ _ _ _ _ ->
                    "callKernel"

                _ ->
                    "callUnknownCallee"


censusCallGlobal : TOpt.Expr TypeIds.MVarId -> Maybe TOpt.Global
censusCallGlobal func =
    case func of
        TOpt.VarGlobal _ g _ ->
            Just g

        TOpt.VarEnum _ g _ _ ->
            Just g

        TOpt.VarBox _ g _ ->
            Just g

        TOpt.VarCycle _ home name _ ->
            Just (TOpt.Global home name)

        _ ->
            Nothing


translateDispatch : TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
translateDispatch expr s0 =
    case expr of
        TOpt.Bool _ v _ ->
            ( Mono.MonoLiteral (Mono.LBool v) Mono.MBool, s0 )

        TOpt.Chr _ v _ ->
            ( Mono.MonoLiteral (Mono.LChar v) Mono.MChar, s0 )

        TOpt.Str _ v _ ->
            ( Mono.MonoLiteral (Mono.LStr v) Mono.MString, s0 )

        TOpt.Int _ v meta ->
            -- M6: direct state-passing (desugared map) → byte-identical.
            case classifyAs Mono.tkClassLit meta.tipe s0 of
                ( monoType, s1 ) ->
                    ( case monoType of
                        Mono.MFloat ->
                            Mono.MonoLiteral (Mono.LFloat (toFloat v)) monoType

                        _ ->
                            Mono.MonoLiteral (Mono.LInt v) monoType
                    , s1
                    )

        TOpt.Float _ v meta ->
            -- M6: direct state-passing (desugared map) → byte-identical.
            case classifyAs Mono.tkClassLit meta.tipe s0 of
                ( monoType, s1 ) ->
                    ( Mono.MonoLiteral (Mono.LFloat v) monoType, s1 )

        TOpt.VarLocal name meta ->
            -- D9: read localMulti/numberMulti/varEnv in ONE getS (all pure), then
            -- branch — the former three sequential `getS` andThen-closures on this
            -- hot node collapse to one. Side effects (record*/classify) are
            -- unchanged and still occur only in the taken branch → byte-identical.
            -- M6: direct state-passing (desugared andThen/map). This node fires on
            -- every local-var reference, so eliminating its per-use bind closures is
            -- a broad cut; monad-law-preserving → byte-identical.
            case Engine.localVarInfo name s0 of
                ( ( isLM, isNM, maybeBound ), s1 ) ->
                    if isLM then
                        -- local-multi FUNCTION target: record this use's applied
                        -- type and point at its per-type binding (f / f$1 / …).
                        case classifyAs Mono.tkClassLocal meta.tipe s1 of
                            ( resolvedType, s2 ) ->
                                case Engine.recordLocalInstance name resolvedType s2 of
                                    ( ( freshName, instType, _ ), s3 ) ->
                                        ( Mono.MonoVarLocal freshName instType, s3 )

                    else if isNM then
                        -- number-multi target: record this use's instance and
                        -- point at its per-type binding (n / n$v1 / …).
                        case classifyAs Mono.tkClassLocal meta.tipe s1 of
                            ( resolvedType, s2 ) ->
                                case Engine.recordNumberInstance name resolvedType s2 of
                                    ( ( freshName, instType ), s3 ) ->
                                        ( Mono.MonoVarLocal freshName instType, s3 )

                    else
                        -- Prefer the varEnv-bound type (from an enclosing let/
                        -- lambda/destructor, may be more concrete than the meta).
                        case maybeBound of
                            Just boundType ->
                                ( Mono.MonoVarLocal name boundType, s1 )

                            Nothing ->
                                case classifyAs Mono.tkClassLocal meta.tipe s1 of
                                    ( monoType, s2 ) ->
                                        ( Mono.MonoVarLocal name monoType, s2 )

        TOpt.TrackedVarLocal _ name meta ->
            translate (TOpt.VarLocal name meta) s0

        TOpt.VarGlobal region global meta ->
            translateVarRef expr region global meta.tipe s0

        TOpt.VarEnum region global _ meta ->
            translateVarRef expr region global meta.tipe s0

        TOpt.VarBox region global meta ->
            translateVarRef expr region global meta.tipe s0

        TOpt.VarCycle region canonical name meta ->
            translateVarRef expr region (TOpt.Global canonical name) meta.tipe s0

        TOpt.VarKernel region kernelPrefix home name meta ->
            case deriveKernelAbiTypeRef ( home, name ) meta.tipe s0 of
                ( funcMonoType, s1 ) ->
                    ( Mono.MonoVarKernel region kernelPrefix home name funcMonoType, s1 )

        TOpt.VarDebug region name _ _ meta ->
            case deriveKernelAbiTypeRef ( "Debug", name ) meta.tipe s0 of
                ( funcMonoType, s1 ) ->
                    ( Mono.MonoVarKernel region "Elm" "Debug" name funcMonoType, s1 )

        TOpt.List region exprs meta ->
            -- Connect every element's type var to the list's element slot (or,
            -- lacking one, to the first element) before translating: an element
            -- use of a let-generalized number picks up the shared demand.
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
            let
                connectElems sa =
                    case listElemCanType meta.tipe of
                        Just elemCan ->
                            List.foldl (\e sb -> connectTypes (TOpt.typeOf e) elemCan sb) sa exprs

                        Nothing ->
                            case exprs of
                                first :: restExprs ->
                                    List.foldl (\e sb -> connectTypes (TOpt.typeOf e) (TOpt.typeOf first) sb) sa restExprs

                                [] ->
                                    sa
            in
            case connectElems s0 of
                s1 ->
                    case classifyAs Mono.tkClassMisc meta.tipe s1 of
                        ( monoType0, s2 ) ->
                            case Engine.traverse translate exprs s2 of
                                ( monoExprs, s3 ) ->
                                    let
                                        -- E15 (`lss.flow.accessFlow`, DEFAULT-ON
                                        -- 2026-09-16, unconditional 2026-09-18):
                                        -- a first-element-only element set is a
                                        -- completeness claim the other elements
                                        -- can falsify, so join over all of them.
                                        -- Landing measurement: `var` 852 -> 837,
                                        -- k1 +26, wall flat.
                                        joinElems =
                                            s3.env.lss.enabled

                                        -- F4-lit-list (plans/lss-container-payload-transport.md
                                        -- §12.10.1): the element type is the JOIN over every
                                        -- element (`joinBranchTypes`, the If precedent) — the
                                        -- first element alone is a completeness claim the
                                        -- others can falsify.
                                        joinedElem first rest =
                                            if joinElems then
                                                List.foldl (\e acc -> joinBranchTypes acc (Mono.typeOf e)) (Mono.typeOf first) rest

                                            else
                                                Mono.typeOf first

                                        ( monoType, s3b ) =
                                            if Mono.containsAnyMVar monoType0 then
                                                case monoExprs of
                                                    first :: rest ->
                                                        -- K6: this type is retained on the node.
                                                        Engine.consS (Mono.mList (joinedElem first rest)) s3

                                                    [] ->
                                                        ( monoType0, s3 )

                                            else
                                                case monoExprs of
                                                    first :: rest ->
                                                        if joinElems then
                                                            Engine.consS (Mono.overlayAnnotations monoType0 (Mono.mList (joinedElem first rest))) s3

                                                        else
                                                            ( monoType0, s3 )

                                                    [] ->
                                                        ( monoType0, s3 )
                                    in
                                    ( Mono.MonoList region monoExprs monoType, s3b )

        TOpt.Call region func args meta ->
            translateCall region func args meta.tipe s0

        TOpt.If branches final meta ->
            -- Per branch: translate the CONDITION first (a shared number var used
            -- there stays at its eager type), then connect the branch value's type
            -- var to the If's own var (so a use of a let-generalized number under a
            -- Float context picks up the demand), then translate the branch value.
            -- Interleaved to mirror the original engine's per-use demand recording.
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
            case classifyAs Mono.tkClassIf meta.tipe s0 of
                ( monoType0, s1 ) ->
                    case Engine.traverse (translateIfBranch meta.tipe) branches s1 of
                        ( monoBranches, s2 ) ->
                            case connectTypes (TOpt.typeOf final) meta.tipe s2 of
                                s3 ->
                                    case translate final s3 of
                                        ( monoFinal, s4 ) ->
                                            let
                                                monoType =
                                                    if Mono.containsAnyMVar monoType0 then
                                                        -- Structure from the final branch, lambda-set
                                                        -- annotations JOINED over every branch — see
                                                        -- `joinBranchTypes` (adopting one branch's
                                                        -- annotations verbatim was the 2026-09-11
                                                        -- false-singleton miscompile).
                                                        List.foldl (\( _, b ) acc -> joinBranchTypes acc (Mono.typeOf b))
                                                            (Mono.typeOf monoFinal)
                                                            monoBranches

                                                    else
                                                        monoType0
                                            in
                                            ( Mono.MonoIf monoBranches monoFinal monoType, s4 )

        TOpt.TailCall name args meta ->
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
            -- MONO_029 R1: connect the recursive-call args to the loop params
            -- first — the TCO transform rebuilds this call chain with a fresh
            -- id family that otherwise never joins the annotation component.
            case connectTailCallArgs name args s0 of
                s0c ->
                    case classifyAs Mono.tkClassMisc meta.tipe s0c of
                        ( monoType, s1 ) ->
                            case
                                Engine.traverse
                                    (\( argName, argExpr ) sx ->
                                        case translate argExpr sx of
                                            ( me, sx1 ) ->
                                                ( ( argName, me ), sx1 )
                                    )
                                    args
                                    s1
                            of
                                ( monoArgs, s2 ) ->
                                    ( Mono.MonoTailCall name monoArgs monoType, s2 )

        TOpt.Unit _ ->
            ( Mono.MonoUnit, s0 )

        TOpt.Tuple region a b rest meta ->
            -- Connect each slot's type var to the tuple type's slot before
            -- translating (demand flow into tuple literals).
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
            let
                connectSlots sa =
                    case tupleSlotCanTypes meta.tipe of
                        Just slotCans ->
                            List.foldl (\( e, slotCan ) sb -> connectTypes (TOpt.typeOf e) slotCan sb)
                                sa
                                (List.map2 Tuple.pair (a :: b :: rest) slotCans)

                        Nothing ->
                            sa
            in
            case connectSlots s0 of
                s1 ->
                    case translate a s1 of
                        ( monoA, s2 ) ->
                            case translate b s2 of
                                ( monoB, s3 ) ->
                                    case Engine.traverse translate rest s3 of
                                        ( monoRest, s4 ) ->
                                            let
                                                allExprs =
                                                    monoA :: monoB :: monoRest
                                            in
                                            let
                                                ( tupleType, s5 ) =
                                                    Engine.consS (Mono.mTuple (List.map Mono.typeOf allExprs)) s4
                                            in
                                            ( Mono.MonoTupleCreate region allExprs tupleType, s5 )

        TOpt.Record fields meta ->
            -- Connect each field expr's type var to the record type's field slot
            -- before translating (demand flow into record literals).
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
            case connectRecordFields (Dict.toList fields) meta.tipe s0 of
                s1 ->
                    case
                        Engine.foldlS
                            (\( name, fieldExpr ) acc sx ->
                                case translate fieldExpr sx of
                                    ( me, sx1 ) ->
                                        ( ( name, me ) :: acc, sx1 )
                            )
                            []
                            (Dict.toList fields)
                            s1
                    of
                        ( monoFieldsRev, s2 ) ->
                            let
                                ( recType, s3 ) =
                                    Engine.consS (recordTypeFromFields monoFieldsRev) s2
                            in
                            ( Mono.MonoRecordCreate monoFieldsRev recType, s3 )

        TOpt.TrackedRecord _ fields meta ->
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
            case
                connectRecordFields
                    (List.map (\( locName, e ) -> ( A.toValue locName, e )) (DMap.toList fields))
                    meta.tipe
                    s0
            of
                s1 ->
                    case
                        Engine.foldlS
                            (\( locName, fieldExpr ) acc sx ->
                                case translate fieldExpr sx of
                                    ( me, sx1 ) ->
                                        ( ( A.toValue locName, me ) :: acc, sx1 )
                            )
                            []
                            (DMap.toList fields)
                            s1
                    of
                        ( monoFieldsRev, s2 ) ->
                            let
                                ( recType, s3 ) =
                                    Engine.consS (recordTypeFromFields monoFieldsRev) s2
                            in
                            ( Mono.MonoRecordCreate monoFieldsRev recType, s3 )

        TOpt.Access record _ fieldName meta ->
            translateAccess record fieldName meta s0

        TOpt.Update _ record updates meta ->
            translateUpdate record updates meta.tipe s0

        TOpt.Let def body meta ->
            -- Connect the body's type to the Let node's own type before
            -- translating: the two are one type to the typechecker but carry
            -- DISTINCT per-occurrence arrow slots (LSS_006), and a branch value
            -- reached through this wrapper must reach the enclosing join —
            -- see the `TOpt.Destruct` arm for the miscompile this closes.
            translateLet def body meta.tipe (connectTypes (TOpt.typeOf body) meta.tipe s0)

        TOpt.Case label root decider jumps meta ->
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
            case classifyAs Mono.tkClassCase meta.tipe s0 of
                ( monoTypeFromCan, s1 ) ->
                    case specializeDecider meta.tipe root decider s1 of
                        ( monoDecider, s2 ) ->
                            case specializeJumps meta.tipe jumps s2 of
                                ( monoJumps, s3 ) ->
                                    ( Mono.MonoCase label
                                        root
                                        monoDecider
                                        monoJumps
                                        (if Mono.containsAnyMVar monoTypeFromCan then
                                            inferCaseType monoJumps monoDecider monoTypeFromCan

                                         else
                                            monoTypeFromCan
                                        )
                                    , caseAnnoCensus monoTypeFromCan monoDecider monoJumps s3
                                    )

        TOpt.Destruct destructor body meta ->
            let
                (TOpt.Destructor dname path dmeta) =
                    destructor
            in
            -- Divert (MONO_028): a scalar-number destructor slot projected from a
            -- number-multi root is specialized body-FIRST, so its uses drive one
            -- root instance per demanded numeric type (+ dead-destructor elim).
            -- A1: direct state-passing (desugared andThen; pure getS inlined) → byte-identical.
            --
            -- 2026-09-11 (/work/eta-fixed-point-root-cause.md): connect the
            -- body's type to the Destruct node's own type FIRST, exactly as
            -- `specializeChoice` connects an inline leaf to its case. A
            -- pattern-binding branch (`Just x -> f x`) is `Destruct` around the
            -- value; without this connect the value's arrow slot (the call's
            -- result set) never reaches the case's slot, so a sibling branch
            -- that DOES connect — a PAP of a global, `LSet [p|…]` — read back as
            -- the case's COMPLETE set: a false singleton that E9.5 fast-stamped,
            -- running `succeed`'s evaluator on the other branch's closure and
            -- silently skipping its state effect (`PapStampTest`).
            case connectTypes (TOpt.typeOf body) meta.tipe s0 of
                s0d ->
                    case Engine.numberMultiRootType (pathRootName path) s0d of
                        ( maybeRootType, s1 ) ->
                            case maybeRootType of
                                Just eagerRootType ->
                                    case classifyAs Mono.tkClassDestr dmeta.tipe s1 of
                                        ( eagerLeaf, s2 ) ->
                                            if isScalarNumber eagerLeaf && refineRootInstance s1.env.globalTypeEnv eagerRootType path eagerLeaf /= Nothing then
                                                specializeNumberDestruct dname path dmeta (pathRootName path) eagerRootType body s2

                                            else
                                                generalDestruct destructor body meta s2

                                Nothing ->
                                    generalDestruct destructor body meta s1

        TOpt.Accessor region fieldName meta ->
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
            case classifyAs Mono.tkClassMisc meta.tipe s0 of
                ( monoType, s1 ) ->
                    if ResolveAccessorValues.accessorTypeNeedsDefer monoType then
                        ( Mono.MonoAccessorValue region fieldName monoType, s1 )

                    else
                        case Engine.enqueueSpec (Mono.Accessor fieldName) monoType s1 of
                            ( specId, s2 ) ->
                                ( Mono.MonoVarGlobal region specId monoType, s2 )

        TOpt.Function srcLam params body meta ->
            specializeLambda srcLam params body meta.tipe s0

        TOpt.TrackedFunction srcLam trackedParams body meta ->
            specializeLambda srcLam (List.map (\( locName, pt ) -> ( A.toValue locName, pt )) trackedParams) body meta.tipe s0

        -- Deferred to later milestones:
        _ ->
            ( Engine.crashFailure (Unsupported (nodeKind expr)), s0 )


{-| Translate one If branch: condition first, then connect the branch value's
type to the If's type, then the branch value (see the `TOpt.If` arm).
-}
translateIfBranch : Can.Type TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ) -> Step ( Mono.MonoExpr, Mono.MonoExpr )
translateIfBranch ifCanType ( cond, bodyExpr ) s0 =
    case translate cond s0 of
        ( monoCond, s1 ) ->
            case translate bodyExpr (connectTypes (TOpt.typeOf bodyExpr) ifCanType s1) of
                ( monoBody, s2 ) ->
                    ( ( monoCond, monoBody ), s2 )



-- ====== RECURSIVE CYCLES (single-recursion / SCC-of-1) ======


{-| Specialize the DEMANDED member of a recursive cycle (self- or mutual-
recursive). We produce only the node for `name`; its `VarCycle` references to
itself and to siblings enqueue those members as their own specs (the drain skips
the in-progress self-spec), so an SCC of any size materializes one node per
member across separate work items — no single node holds the whole group.
-}
specializeCycle : Name -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> List (TOpt.Def TypeIds.MVarId) -> Mono.MonoType -> Step Mono.MonoNode
specializeCycle name valueDefs funcDefs demand =
    case listFind (\d -> cycleDefName d == name) funcDefs of
        Just def ->
            specializeCycleFuncDef def demand

        Nothing ->
            case listFind (\( n, _ ) -> n == name) valueDefs of
                Just ( _, vexpr ) ->
                    specializeCycleValue vexpr demand

                Nothing ->
                    -- Name didn't match a member (SCC-of-1 whose enqueued name was
                    -- the group's, not the member's): fall back to the lone def.
                    case ( valueDefs, funcDefs ) of
                        ( [], [ singleDef ] ) ->
                            specializeCycleFuncDef singleDef demand

                        ( [ ( _, vexpr ) ], [] ) ->
                            specializeCycleValue vexpr demand

                        _ ->
                            Engine.crashFailure (EngineBug ("cycle member not found: " ++ name))


cycleDefName : TOpt.Def TypeIds.MVarId -> Name
cycleDefName def =
    case def of
        TOpt.Def _ n _ _ ->
            n

        TOpt.TailDef _ n _ _ _ _ ->
            n


listFind : (a -> Bool) -> List a -> Maybe a
listFind pred xs =
    List.head (List.filter pred xs)


specializeCycleValue : TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCycleValue vexpr demand s0 =
    case translate vexpr (demandUnifyRoot (TOpt.typeOf vexpr) demand vexpr s0) of
        ( monoExpr, s1 ) ->
            ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s1 )



-- ====== PORTS ======


{-| Specialize a port node into a `MonoPortIncoming`/`MonoPortOutgoing` wrapper
closure over `Elm.Platform.leaf name value`. Incoming ports enqueue their decoder
(recorded as the port's `decoderSpecId`); outgoing ports inline their encoder.
Mirrors `Specialize.specializePortNode`.
-}
specializePort : Bool -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializePort incoming expr canType requestedMonoType s0 =
    -- LSS_004: port payload/encoder arrows are kernel-facing — poison their
    -- set slots before the body walks/loads them (no-op when lss is off).
    case poisonPortArrowsIfOn canType s0 of
        s1 ->
            specializePortBody incoming expr canType requestedMonoType s1


poisonPortArrowsIfOn : Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
poisonPortArrowsIfOn canType s =
    if s.env.lss.enabled then
        case Store.loadTypeS canType s of
            ( v, s1 ) ->
                case Store.poisonArrowSets v s1 of
                    s2 ->
                        Engine.bumpWidenedByKernel s2

    else
        s


specializePortBody : Bool -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializePortBody incoming expr canType requestedMonoType s0 =
    case classifyAs Mono.tkClassMisc canType (demandUnify canType requestedMonoType s0) of
        ( classifiedCan, s1 ) ->
            case portGlobalContext s1 of
                ( ( portGlobal, portName ), s2 ) ->
                    -- Usually the demand is a concrete `p -> r`; if it reached
                    -- us erased (a bare MVar), recover the shape from the port's
                    -- own (now-unified) canonical type.
                    let
                        effectiveType =
                            case requestedMonoType of
                                Mono.MFunction _ _ _ _ ->
                                    requestedMonoType

                                _ ->
                                    classifiedCan
                    in
                    case effectiveType of
                        Mono.MFunction _ _ [ paramType ] resultType ->
                            case allocLambdaId s2 of
                                ( lambdaId, s3 ) ->
                                    let
                                        region =
                                            A.zero

                                        paramName =
                                            "_eco_port_arg"

                                        paramVar =
                                            Mono.MonoVarLocal paramName paramType

                                        nameLit =
                                            Mono.MonoLiteral (Mono.LStr portName) Mono.MString

                                        leafKernel valueType =
                                            Mono.MonoVarKernel region "Elm" "Platform" "leaf" (Mono.mFunction Mono.topSynth [ Mono.MString, valueType ] resultType)

                                        closureInfo =
                                            { lambdaId = lambdaId
                                            , srcLambda = Nothing
                                            , lssMember = Nothing
                                            , captures = []
                                            , params = [ ( paramName, paramType ) ]
                                            , closureKind = Nothing
                                            , captureAbi = Nothing
                                            }
                                    in
                                    if incoming then
                                        let
                                            body =
                                                Mono.MonoCall region (leafKernel paramType) [ nameLit, paramVar ] resultType Mono.defaultCallInfo

                                            wrapper =
                                                Mono.MonoClosure closureInfo body effectiveType
                                        in
                                        case classifyAs Mono.tkClassMisc (TOpt.typeOf expr) s3 of
                                            ( decoderMonoType, s4 ) ->
                                                case Engine.enqueueSpec portGlobal decoderMonoType s4 of
                                                    ( decoderSpecId, s5 ) ->
                                                        ( Mono.MonoPortIncoming wrapper effectiveType
                                                        , recordPort { name = portName, key = Mono.toComparableGlobal portGlobal, incoming = True, decoderSpecId = Just decoderSpecId } s5
                                                        )

                                    else
                                        case translate expr (connectEncoderType expr canType s3) of
                                            ( encoderMono, s4 ) ->
                                                let
                                                    encodedType =
                                                        case Mono.typeOf encoderMono of
                                                            Mono.MFunction _ _ _ r ->
                                                                r

                                                            t ->
                                                                t

                                                    encodedExpr =
                                                        Mono.MonoCall region encoderMono [ paramVar ] encodedType Mono.defaultCallInfo

                                                    body =
                                                        Mono.MonoCall region (leafKernel encodedType) [ nameLit, encodedExpr ] resultType Mono.defaultCallInfo

                                                    wrapper =
                                                        Mono.MonoClosure closureInfo body effectiveType
                                                in
                                                ( Mono.MonoPortOutgoing wrapper effectiveType
                                                , recordPort { name = portName, key = Mono.toComparableGlobal portGlobal, incoming = False, decoderSpecId = Nothing } s4
                                                )

                        _ ->
                            ( Engine.crashFailure (EngineBug ("port '" ++ portName ++ "' must have a single-parameter function type; got " ++ monoKind effectiveType)), s2 )


{-| Connect an outgoing port's ENCODER reference to `payload -> fresh` so its
(otherwise free-floating) type var takes the function shape at the payload type
— an erased encoder VG compiles to a 0-operand llvm.call.
-}
connectEncoderType : TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
connectEncoderType expr portCanType s0 =
    case portCanType of
        Can.TLambda _ payloadCan _ ->
            case Store.loadType (TOpt.typeOf expr) s0 of
                ( encVar, s1 ) ->
                    case Store.loadTypeS payloadCan s1 of
                        ( payloadVar, s2 ) ->
                            case Engine.freshVar (Vars.FlexVar Nothing) s2 of
                                ( resVar, s3 ) ->
                                    case Engine.freshVar (Vars.Structure (Vars.Fun1 payloadVar resVar)) s3 of
                                        ( funVar, s4 ) ->
                                            unifyStepBestEffort encVar funVar s4

        _ ->
            s0


portGlobalContext : Step ( Mono.Global, String )
portGlobalContext s =
    case s.currentGlobal of
        Just ((Mono.Global _ nm) as g) ->
            ( ( g, Name.toElmString nm ), s )

        _ ->
            ( Engine.crashFailure (EngineBug "specializePort: currentGlobal must be a Global"), s )


{-| Replace every `MVar _ CEcoValue` in a kernel ABI with a fresh id (one per
distinct source id, sharing preserved), returning the next unused id.
-}
remapEcoVarsFresh : TypeIds.MVarId -> Mono.MonoType -> ( Mono.MonoType, TypeIds.MVarId )
remapEcoVarsFresh nextId0 abiType =
    let
        go t ( mapping, nextId ) =
            case t of
                Mono.MVar mid Mono.CEcoValue ->
                    case Dict.get (Engine.mvarIdKey mid) mapping of
                        Just fresh ->
                            ( Mono.MVar fresh Mono.CEcoValue, ( mapping, nextId ) )

                        Nothing ->
                            ( Mono.MVar nextId Mono.CEcoValue
                            , ( Dict.insert (Engine.mvarIdKey mid) nextId mapping, Id.succ nextId )
                            )

                Mono.MVar _ _ ->
                    ( t, ( mapping, nextId ) )

                Mono.MFunction _ anno args r ->
                    let
                        ( args1, acc1 ) =
                            List.foldr
                                (\a ( accL, accS ) ->
                                    let
                                        ( a1, accS1 ) =
                                            go a accS
                                    in
                                    ( a1 :: accL, accS1 )
                                )
                                ( [], ( mapping, nextId ) )
                                args

                        ( r1, acc2 ) =
                            go r acc1
                    in
                    ( Mono.mFunction anno args1 r1, acc2 )

                Mono.MList _ e ->
                    let
                        ( e1, acc1 ) =
                            go e ( mapping, nextId )
                    in
                    ( Mono.mList e1, acc1 )

                Mono.MTuple _ es ->
                    let
                        ( es1, acc1 ) =
                            List.foldr
                                (\a ( accL, accS ) ->
                                    let
                                        ( a1, accS1 ) =
                                            go a accS
                                    in
                                    ( a1 :: accL, accS1 )
                                )
                                ( [], ( mapping, nextId ) )
                                es
                    in
                    ( Mono.mTuple es1, acc1 )

                Mono.MCustom _ h n args ->
                    let
                        ( args1, acc1 ) =
                            List.foldr
                                (\a ( accL, accS ) ->
                                    let
                                        ( a1, accS1 ) =
                                            go a accS
                                    in
                                    ( a1 :: accL, accS1 )
                                )
                                ( [], ( mapping, nextId ) )
                                args
                    in
                    ( Mono.mCustom h n args1, acc1 )

                Mono.MRecord _ fields ->
                    let
                        ( fields1, acc1 ) =
                            Dict.foldr
                                (\k v ( accD, accS ) ->
                                    let
                                        ( v1, accS1 ) =
                                            go v accS
                                    in
                                    ( Dict.insert k v1 accD, accS1 )
                                )
                                ( Dict.empty, ( mapping, nextId ) )
                                fields
                    in
                    ( Mono.mRecord fields1, acc1 )

                _ ->
                    ( t, ( mapping, nextId ) )

        ( result, ( _, finalNext ) ) =
            go abiType ( Dict.empty, nextId0 )
    in
    ( result, finalNext )


monoKind : Mono.MonoType -> String
monoKind mt =
    case mt of
        Mono.MFunction _ _ ps r ->
            "(" ++ String.join "," (List.map monoKind ps) ++ "->" ++ monoKind r ++ ")"

        Mono.MCustom _ _ n args ->
            n
                ++ (if List.isEmpty args then
                        ""

                    else
                        "<" ++ String.join "," (List.map monoKind args) ++ ">"
                   )

        Mono.MVar _ Mono.CNumber ->
            "num"

        Mono.MVar _ Mono.CEcoValue ->
            "eco"

        Mono.MInt ->
            "I"

        Mono.MFloat ->
            "F"

        Mono.MList _ e ->
            "[" ++ monoKind e ++ "]"

        Mono.MTuple _ es ->
            "T(" ++ String.join "," (List.map monoKind es) ++ ")"

        Mono.MRecord _ fields ->
            "R{" ++ String.join "," (List.map (\( k, v ) -> k ++ ":" ++ monoKind v) (Dict.toList fields)) ++ "}"

        Mono.MString ->
            "S"

        Mono.MBool ->
            "B"

        _ ->
            "other"


recordPort : Mono.PortRegistration -> Engine.S -> Engine.S
recordPort reg s =
    if List.any (\p -> p.key == reg.key) s.ports then
        s

    else
        { s | ports = reg :: s.ports }


specializeCycleFuncDef : TOpt.Def TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCycleFuncDef def demand =
    case def of
        TOpt.Def _ _ body defType ->
            \sIn ->
                case translate body (demandUnifyRoot defType demand body sIn) of
                    ( monoExpr, s1 ) ->
                        ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), s1 )

        TOpt.TailDef _ tailName typedArgs body defType _ ->
            \sIn ->
                if sIn.env.lss.enabled then
                    -- lss on: the node/param types must come from a zonk of THE
                    -- demand-seeded annotation var — a storeless classify (or a
                    -- fresh re-load) cannot see the transported lambda sets
                    -- (LSS_006: set slots live on per-load arrow structure).
                    case demandUnifyVar defType demand sIn of
                        ( annVar, s1 ) ->
                            case Store.zonkToMono annVar s1 of
                                ( zonkedType, s1b ) ->
                                    case classifyAs Mono.tkClassLet defType s1b of
                                        ( classifiedType, s2 ) ->
                                            let
                                                -- ABI guard (overlayAnnotations doc): classify
                                                -- structure + zonk annotations. The zonk alone
                                                -- diverged from the byte path on loop-param
                                                -- ABIs (eco.case i64 vs !eco.value yields).
                                                funcType =
                                                    Mono.overlayAnnotations classifiedType zonkedType

                                                peeled =
                                                    extractFieldTypes (List.length typedArgs) funcType
                                            in
                                            case
                                                -- Params: per-param classify is the byte-path
                                                -- STRUCTURE truth (peeling defType can diverge on
                                                -- alias/number resolution); the peeled zonk
                                                -- contributes only annotations.
                                                if List.length peeled == List.length typedArgs then
                                                    Engine.traverse
                                                        (\( ( locName, argType ), peeledType ) sx ->
                                                            case classifyAs Mono.tkClassParam argType sx of
                                                                ( mt, sx1 ) ->
                                                                    ( ( A.toValue locName, Mono.overlayAnnotations mt peeledType ), sx1 )
                                                        )
                                                        (List.map2 Tuple.pair typedArgs peeled)
                                                        s2

                                                else
                                                    -- Shape fallback: annotation stages don't
                                                    -- cover the params — classify as before.
                                                    Engine.traverse
                                                        (\( locName, argType ) sx ->
                                                            case classifyAs Mono.tkClassParam argType sx of
                                                                ( mt, sx1 ) ->
                                                                    ( ( A.toValue locName, mt ), sx1 )
                                                        )
                                                        typedArgs
                                                        s2
                                            of
                                                ( monoParams, s3 ) ->
                                                    case withLoopFrame tailName typedArgs (Engine.scoped (\sx -> translate body (insertVars monoParams sx))) s3 of
                                                        ( monoBody, s4 ) ->
                                                            ( Mono.MonoTailFunc monoParams monoBody funcType, s4 )

                else
                    case
                        Engine.traverse
                            (\( locName, argType ) sx ->
                                case classifyAs Mono.tkClassParam argType sx of
                                    ( mt, sx1 ) ->
                                        ( ( A.toValue locName, mt ), sx1 )
                            )
                            typedArgs
                            (demandUnify defType demand sIn)
                    of
                        ( monoParams, s1 ) ->
                            case classifyAs Mono.tkClassLet defType s1 of
                                ( funcType, s2 ) ->
                                    case withLoopFrame tailName typedArgs (Engine.scoped (\sx -> translate body (insertVars monoParams sx))) s2 of
                                        ( monoBody, s3 ) ->
                                            ( Mono.MonoTailFunc monoParams monoBody funcType, s3 )



-- ====== CONSTRUCTOR / ENUM NODES ======


{-| Specialize a constructor node into `MonoCtor`. Unify the ctor's scheme type
with the demanded type, zonk to the substituted function type, and peel `arity`
field types off it; the result type is peeled off the demand. Mirrors
`Specialize.specializeCtorViaScheme` (Box uses tag 0, arity 1).
-}
specializeCtorViaScheme : Name -> Int -> Int -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCtorViaScheme name tag arity canType demand s0 =
    case Store.loadTypeS canType s0 of
        ( annVar, s1 ) ->
            case Store.monoTypeToVarS demand s1 of
                ( demandVar, s2 ) ->
                    case Store.unifyStrict annVar demandVar s2 of
                        ( _, s3 ) ->
                            case Store.zonkToMono annVar s3 of
                                ( ctorMonoType, s4 ) ->
                                    ( Mono.MonoCtor
                                        { name = name, tag = tag, fieldTypes = extractFieldTypes arity ctorMonoType }
                                        (extractCtorResultType arity demand)
                                    , s4
                                    )


{-| Specialize an enum (nullary ctor) node into `MonoEnum tag <type>`.
-}
enumNode : Int -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
enumNode tag canType demand s0 =
    case Store.loadTypeS canType s0 of
        ( annVar, s1 ) ->
            case Store.monoTypeToVarS demand s1 of
                ( demandVar, s2 ) ->
                    case Store.unifyStrict annVar demandVar s2 of
                        ( _, s3 ) ->
                            case Store.zonkToMono annVar s3 of
                                ( monoType, s4 ) ->
                                    ( Mono.MonoEnum tag monoType, s4 )


extractFieldTypes : Int -> Mono.MonoType -> List Mono.MonoType
extractFieldTypes n monoType =
    if n <= 0 then
        []

    else
        case monoType of
            Mono.MFunction _ _ args result ->
                args ++ extractFieldTypes (n - List.length args) result

            _ ->
                []


extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ _ result ->
                extractCtorResultType (n - 1) result

            _ ->
                monoType



-- ====== CLOSURES ======


{-| Specialize a lambda into `MonoClosure`. Mirrors `Specialize.specializeLambda`:
classify the (curried, un-flattened) function type, specialize each param type,
allocate `AnonymousLambda currentModule counter++`, translate the body, and
compute captures via the shared `Closure.computeClosureCaptures`. `closureKind`
and `captureAbi` are placeholder `Nothing` at mono time (filled by GlobalOpt).
-}
specializeLambda : Maybe TypeIds.SrcLambdaId -> List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
specializeLambda srcLam params body canType s0 =
    case classifyLambdaHead (List.length params) srcLam canType (m2ShapeCensus params body s0) of
        ( ( monoType0, maybeMember ), s1 ) ->
            let
                -- Step 22(a): the param types are PEELED from the (possibly
                -- re-translated, hence concretized) head type whenever the peel
                -- has the right arity, and only the NAMES of the classified
                -- params were used in that case — so classifying every param
                -- and then discarding the result was the common path, not the
                -- fallback. Classify only when the peel does not line up.
                --
                -- `classify` is compositional, so peeled and per-param
                -- classification agree in the normal case; the peel stays
                -- concrete when only the function type's vars were unified,
                -- which is why it was preferred in the first place.
                peeled =
                    extractFieldTypes (List.length params) monoType0

                ( monoParams, s2 ) =
                    if List.length peeled == List.length params then
                        ( List.map2 (\( nm, _ ) pt -> ( nm, pt )) params peeled, s1 )

                    else
                        Engine.traverse
                            (\( name, paramCanType ) sx ->
                                case classifyAs Mono.tkClassParam paramCanType sx of
                                    ( mt, sx1 ) ->
                                        ( ( name, mt ), sx1 )
                            )
                            params
                            s1
            in
            case allocLambdaId s2 of
                ( lambdaId, s3 ) ->
                    case Engine.scoped (\sx -> translate body (insertVars monoParams sx)) s3 of
                        ( monoBody, s4 ) ->
                            -- `monoType0` is the head type as zonked
                            -- BEFORE the body was translated. The M1
                            -- flowConnect producer half used to unify the
                            -- body's solved type back into the kept head
                            -- variable's RESULT slot here; it was measured
                            -- inert on this corpus (byte-identical
                            -- artifact, -32.6 M dispatches when OFF) and
                            -- was removed with its flag on 2026-09-18.
                            ( Mono.MonoClosure
                                { lambdaId = lambdaId
                                , srcLambda = srcLam

                                -- Fix B (LSS_017): the id this instance was
                                -- minted under (spec-qualified when
                                -- keyed-routed). Step 22(b): it now comes
                                -- back FROM `classifyLambdaHead`'s single
                                -- mint instead of being re-derived by a
                                -- second `Engine.lambdaInstanceMemberMaybe`
                                -- — that call was state-idempotent but ran
                                -- `instanceQualTagFor`, the `rootLamOf`
                                -- fold, `layoutQualKey` (a multi-kilobyte
                                -- string concat) and a `byKey` probe every
                                -- time. One mint, one id: LSS_017's
                                -- "stamped IDENTICALLY in its set injection
                                -- and its ClosureInfo.lssMember" now holds
                                -- by construction.
                                , lssMember = maybeMember
                                , captures = Closure.computeClosureCaptures monoParams monoBody
                                , params = monoParams
                                , closureKind = Nothing
                                , captureAbi = Nothing
                                }
                                monoBody
                                monoType0
                            , s4
                            )


{-| The lambda's head type. lss off: exactly the storeless `classify` (the
byte-identical path). lss on: LOAD the lambda's type (arrows slotted, through
the ITEM memo so demand concretization is visible), inject the lambda's own
member into the first `arity` result-spine arrows (LSS\_013 spine injection,
bounded by the parameter count so a function-returning body never stamps its
returned closure's arrows), and zonk — the closure's MonoType then carries
`LSet [self, …demand-joined members]` on those arrows (design §8.2).

Def-root lambdas consume the stashed `demandUnifyVar` annotation var
(matched by canonical type) instead of a fresh load: the fresh load of a
GROUND annotation shares no vars with the demand-seeded one (LSS\_006), so
without the reuse the demand's transported lambda sets never reach the
def's binder/param types and every param-use call site zonks LTop. The
zonked structure is identical either way (leaf demand flow is memo-shared);
only annotations gain content — lss-off byte-identity untouched.

-}
classifyLambdaHead : Int -> Maybe TypeIds.SrcLambdaId -> Can.Type TypeIds.MVarId -> Step ( Mono.MonoType, Maybe Int )
classifyLambdaHead arity srcLam canType s0 =
    if s0.env.lss.enabled then
        let
            ( maybeRootVar, s0b ) =
                case s0.itemAux.lssRootAnn of
                    Just ( annCanType, annVar ) ->
                        -- Phase 2a §4.6(a): the guard is ID-BLIND. It used to
                        -- be a whole-tree `annCanType == canType`, which under
                        -- per-occurrence arrow identity would go always-false
                        -- and switch `lssRootAnn` off silently.
                        if sameCanTypeIgnoringArrows annCanType canType then
                            let
                                aux0 =
                                    s0.itemAux
                            in
                            -- EXP-2a (plans/lss-unknown-elimination.md §4.8):
                            -- `hit` counts the id-blind match (the behaviour);
                            -- `hitExact` additionally counts the raw `==`.
                            --
                            -- The question EXP-2a answers is whether a def's
                            -- stashed `defType` and its body `Function`'s
                            -- `meta.tipe` are structurally-equal DISTINCT
                            -- objects or literally the same value. Elm has no
                            -- reference equality, so only the measurement can
                            -- say. Pre-2a, `hitExact == hit` by construction
                            -- (there are no ids yet). Post-2a:
                            --   hitExact ≈ hit  -> ONE object, so 2a's
                            --                      per-occurrence ids already
                            --                      agree and artifacts
                            --                      #1/#2/#4a are reachable
                            --                      from 2a;
                            --   hitExact ≈ 0    -> two objects, 2a cannot
                            --                      reach them, and #1/#2/#4a
                            --                      need 2b (solver-root ids).
                            --
                            -- Report-gated on both counters, so this is
                            -- byte-neutral. Splitting the counter (rather than
                            -- keeping the raw `==` as the guard, which is what
                            -- the plan's §4.8 sketch did) answers the same
                            -- question without risking the regression it
                            -- describes.
                            ( Just annVar
                            , Engine.bumpArgFlowCensus "rootAnn|hit"
                                (if annCanType == canType then
                                    Engine.bumpArgFlowCensus "rootAnn|hitExact" { s0 | itemAux = { aux0 | lssRootAnn = Nothing } }

                                 else
                                    { s0 | itemAux = { aux0 | lssRootAnn = Nothing } }
                                )
                            )

                        else
                            ( Nothing, Engine.bumpArgFlowCensus "rootAnn|missType" s0 )

                    Nothing ->
                        ( Nothing, Engine.bumpArgFlowCensus "rootAnn|absent" s0 )

            -- ROOT-MEMBER FOLD (plans/lss-root-member-fold.md §1.2): the
            -- stashed-root path IS the def's root lambda — record
            -- `srcLam -> global` so the mint moments below folds it to the
            -- ground standalone key. Kernel-alias globals are skipped HERE
            -- (Engine cannot import `kernelAliasOf` — the import cycle):
            -- folding one would re-create the g|/k| split E9.2 removes.
            s0c =
                case ( maybeRootVar, ( srcLam, s0b.currentGlobal ) ) of
                    ( Just _, ( Just lamId, Just (Mono.Global home name) ) ) ->
                        let
                            g =
                                TOpt.Global home name
                        in
                        if s0b.itemAux.retranslating /= Nothing then
                            -- F2 (plans/lss-container-payload-transport.md
                            -- §12.9.4, found by LssLocalMultiUseInjectTest):
                            -- a LOCAL-multi instance RHS is re-translated
                            -- through `demandUnifyRoot`, so its lambda
                            -- matches the root stash too — and folding it
                            -- onto the ENCLOSING global's ground key is
                            -- wrong twice over: the id names a different
                            -- value (`SourceGlobal` of the enclosing def),
                            -- and `instanceQualTagFor` then drops the
                            -- instance tag, so every instance of the
                            -- let-function shares one id (the LSS_038
                            -- collapse, live for lambda RHSs). Skip the
                            -- fold; the lambda keeps its own `l|` identity,
                            -- instance-qualified, and equals the use-site
                            -- mint.
                            Engine.bumpArgFlowCensus "rootFold|localSkip" s0b

                        else
                            case LssInfer.kernelAliasOf g s0b of
                                Just _ ->
                                    Engine.bumpArgFlowCensus "rootFold|kernelSkip" s0b

                                Nothing ->
                                    let
                                        tbl =
                                            s0b.lssMemberTable
                                    in
                                    { s0b | lssMemberTable = { tbl | rootLamOf = Dict.insert (Engine.srcLambdaKey lamId) g tbl.rootLamOf } }

                    _ ->
                        s0b
        in
        case
            case maybeRootVar of
                Just annVar ->
                    ( annVar, s0c )

                Nothing ->
                    Store.loadType canType s0c
        of
            ( funcVar, s1 ) ->
                -- Fix B (LSS_017): translation-phase mint — spec-qualified.
                -- Step 22(b): take the member id FROM the mint instead of
                -- re-deriving it with a second `lambdaInstanceMemberMaybe`.
                case LssInfer.injectLambdaMemberQualifiedId arity srcLam funcVar s1 of
                    ( maybeMid, s2 ) ->
                        case Store.zonkToMono funcVar s2 of
                            ( zonked, s3 ) ->
                                -- ABI guard (overlayAnnotations doc): the
                                -- storeless classification is the structure
                                -- truth; the store zonk contributes ONLY the
                                -- lambda-set annotations. Letting the zonk
                                -- decide structure diverged from the byte
                                -- path on demand-concretized leaves.
                                case classifyAs Mono.tkClassLambda canType s3 of
                                    ( classified, s4 ) ->
                                        ( ( Mono.overlayAnnotations classified zonked, maybeMid ), s4 )

    else
        case classifyAs Mono.tkClassLambda canType s0 of
            ( classified, s1 ) ->
                -- lss off: exactly what `lambdaInstanceMemberMaybe` answered
                -- here (its own `enabled` guard), so `ClosureInfo.lssMember`
                -- is unchanged in this regime too.
                ( ( classified, Nothing ), s1 )


allocLambdaId : Step Mono.LambdaId
allocLambdaId =
    \s -> ( Mono.AnonymousLambda s.env.currentModule s.lambdaCounter, { s | lambdaCounter = s.lambdaCounter + 1 } )



-- ====== VAR REFERENCES ======


{-| A standalone reference to a global value/ctor/box → `MonoVarGlobal SpecId`.
Mirrors the VarGlobal/VarEnum/VarBox arms (enqueue with the node's own type).
-}
translateVarRef : TOpt.Expr TypeIds.MVarId -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateVarRef refExpr region global canType s0 =
    -- M6: direct state-passing (desugared andThen/map). Fires on every global
    -- reference; monad-law-preserving → byte-identical.
    case classifyRef refExpr canType s0 of
        ( monoType, s1 ) ->
            case enqueueSpecStamped global monoType s1 of
                ( specId, s2 ) ->
                    ( Mono.MonoVarGlobal region specId monoType, s2 )


{-| §5.4 (GAP-A): classify a bare global reference's type.

`classify` is `Store.classifyDirect` — read-only, no store minting — and its
`Can.TLambda` arm stamps `Mono.LTop` on EVERY arrow by construction
("storeless classification stamps LTop"). `translateGlobalCall` knows this and
GATES its storeless fast path on `lssFastOk`; `translateVarRef` did not, so a
bare reference's arrows came back ⊤ unconditionally — poisoned before any
member could reach them. That, not a missing injection, is why
`[ incr, decr ]` and `( incr, decr )` produced no set while
`[ \x -> x+1, … ]` (which goes through `classifyLambdaHead`) and
`[ idf incr, … ]` (a call ARGUMENT, behind the gate) both did.

Flag-on takes the store-aware route for exactly the references that can carry
a set: load the type, inject the referent's identity — via
`injectArgLambdaMember`, so the `g|`/`c|`/`k|` dispatch and the kernel-alias
fold stay identical to the argument path (LSS\_016: a split `g|`/`k|` identity
joins to a 2-set and kills every singleton consumer) — then read the answer
back out of the store.

The guard is `canTypeMentionsArrow`: an arrow-free reference cannot inhabit a
lambda set, so it keeps the cheap path and stays byte-identical.

-}
classifyRef : TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classifyRef refExpr canType s0 =
    -- Step 10c: straight-line. `loadType` never fails, `injectArgLambdaMember`
    -- cannot fail after step 6 removed the slow set-write arm, and
    -- `zonkToMono` fails only on its two `EngineBug` invariants — which the
    -- crash policy says abort rather than recover. So all three `Err` arms
    -- here were recovering conditions that either cannot arise or must not be
    -- recovered, and the chain is three plain steps.
    if not (s0.env.lss.enabled && LssInfer.canTypeMentionsArrow canType) then
        classifyAs Mono.tkClassMisc canType s0

    else
        case Store.loadTypeS canType s0 of
            ( canVar, s1 ) ->
                Store.zonkToMono canVar (injectArgLambdaMember refExpr canVar s1)


monoTypeMentionsEco : Mono.MonoType -> Bool
monoTypeMentionsEco mt =
    case mt of
        Mono.MVar _ Mono.CEcoValue ->
            True

        Mono.MFunction _ _ args r ->
            List.any monoTypeMentionsEco args || monoTypeMentionsEco r

        Mono.MList _ t ->
            monoTypeMentionsEco t

        Mono.MTuple _ ts ->
            List.any monoTypeMentionsEco ts

        Mono.MCustom _ _ _ args ->
            List.any monoTypeMentionsEco args

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || monoTypeMentionsEco t) False fields

        _ ->
            False



-- ====== CALLS ======


translateCall : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateCall region func args callCanType =
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            -- M6: direct state-passing (desugared andThen) → byte-identical.
            \s0 ->
                case lookupAnnotation global s0 of
                    ( maybeAnn, s1 ) ->
                        let
                            funcCanType =
                                case maybeAnn of
                                    Just (Can.Forall _ annType) ->
                                        annType

                                    Nothing ->
                                        funcMeta.tipe
                        in
                        translateGlobalCall region funcRegion global funcCanType args callCanType s1

        TOpt.VarKernel funcRegion kernelPrefix home name funcMeta ->
            translateKernelCall region funcRegion kernelPrefix home name ( home, name ) funcMeta.tipe args callCanType

        TOpt.VarDebug funcRegion name _ _ funcMeta ->
            translateKernelCall region funcRegion "Elm" "Debug" name ( "Debug", name ) funcMeta.tipe args callCanType

        TOpt.VarLocal name funcMeta ->
            localCalleeCall region func name funcMeta args callCanType

        TOpt.TrackedVarLocal _ name funcMeta ->
            localCalleeCall region func name funcMeta args callCanType

        _ ->
            translateIndirectCall region func args callCanType


{-| A call whose callee is a direct local reference (tracked or not). If the
local is a multi-instance FUNCTION, concretize its type from the call args
(solver-native, like the global path) and record its instance at that concrete
type — so `applyTwo (\x y->x) 1 2` specializes the callee's params to Int
rather than leaving them CEcoValue.
-}
localCalleeCall : A.Region -> TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
localCalleeCall region func name funcMeta args callCanType s0 =
    -- M6: direct state-passing (desugared andThen) → byte-identical.
    case Engine.isLocalMultiTarget name s0 of
        ( isLM, s1 ) ->
            if isLM then
                translateLocalMultiCall region name funcMeta.tipe args callCanType s1

            else
                translateIndirectCall region func args callCanType s1


{-| Specialize a call to a local-multi function: instantiate its type, unify its
params/result against the arg types (concretizing shared vars), translate the
args, then record the callee's instance at the zonked concrete type (`f`/`f$1`).
Mirrors `translateGlobalCall` but records a local instance instead of enqueueing
a global spec.
-}
translateLocalMultiCall : A.Region -> Name -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLocalMultiCall region name funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    -- M6: direct state-passing (desugared 7-deep andThen/map nest, mirrors the
    -- D11 rewrite of translateGlobalCallSlow) → byte-identical.
    case instantiate funcCanType s0 of
        ( funcVar, s1 ) ->
            case unifyParamsCollect funcVar args s1 of
                ( argStash, s2 ) ->
                    case unifyResultWithExpected funcVar argCount callCanType s2 of
                        s3 ->
                            case translateArgsWith argStash args s3 of
                                ( monoArgs, s3b ) ->
                                    -- LSS_026 Phase-0 census: the LOCAL-MULTI
                                    -- consumer class (D1 connects these too,
                                    -- via this function's own
                                    -- `unifyResultWithExpected`). Same
                                    -- report-gated, read-only fold.
                                    case censusArgs (TOpt.Global (ModuleName.Canonical ( "local", "local" ) "local") name) args s3b of
                                        s4 ->
                                            case Store.zonkToMono funcVar s4 of
                                                ( funcMonoType, s5 ) ->
                                                    case callResultType argCount funcMonoType callCanType s5 of
                                                        ( resultMonoType, s6 ) ->
                                                            case Engine.recordLocalInstance name funcMonoType s6 of
                                                                ( ( freshName, instType, _ ), s7 ) ->
                                                                    ( Mono.MonoCall region
                                                                        (Mono.MonoVarLocal freshName instType)
                                                                        monoArgs
                                                                        resultMonoType
                                                                        Mono.defaultCallInfo
                                                                    , s7
                                                                    )


{-| A call whose callee is not a direct global/kernel/debug (a local holding a
function, an `Access`, a nested `Call`): translate the args, translate the callee
as an ordinary expression, and take the result type from the call node. Mirrors
the generic fallback in `Specialize` (recursively specialize the callee expr).
-}
translateIndirectCall : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateIndirectCall region func args callCanType s0 =
    -- Connect the callee's type var to `arg1 -> … -> result` first: a call to
    -- a destructor-derived local function (`getter rec`) is the only place its
    -- type meets concrete arguments, and the connection flows back through the
    -- destructor root into the case/tuple the function came from.
    -- M6: direct state-passing (desugared andThen) → byte-identical.
    case appShapeConnect func args callCanType s0 of
        s1 ->
            let
                -- M2 route-(ii) tracker (lss-var-chain-roots §9.14 —
                -- M2 closed UNBUILT): an INDIRECT call applying fewer
                -- args than the callee's arrow depth constructs a PAP of
                -- a non-global value. Kept as the class tracker for the
                -- construction-anchored repair that could one day reach
                -- the 142 stage holes. Report-gated.
                s1b =
                    if not s1.env.lss.report then
                        s1

                    else if List.length args < LssInfer.canTypeArrowDepth (TOpt.typeOf func) then
                        Engine.bumpArgFlowCensus "m2|lamPartialApp" s1

                    else
                        Engine.bumpArgFlowCensus "m2|indirectSat" s1
            in
            translateIndirectCallBody region func args callCanType s1b


appShapeConnect : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
appShapeConnect func args callCanType s0 =
    case Store.loadType (TOpt.typeOf func) s0 of
        ( funcUseVar, s1 ) ->
            -- MONO_029 root fix (R1): also unify the callee's use var with
            -- its varEnv-bound MonoType. The use/arg/result canTypes of a
            -- TCO/TailDef-REBUILT call node form a fresh id family that is
            -- only internally consistent; the varEnv binding (a classified
            -- param/let type) carries the demand-seeded annotation family.
            -- Without this, the call-result element zonks to an erased
            -- residual while the destructure leaf stays concrete — the
            -- layout disagreement behind the foldMGo miscompile
            -- (SolverLayoutFoldMTest / SolverLayoutFoldMCycleTest).
            -- enrichFromEnv is best-effort and skips local-multi targets
            -- (their varEnv entry is only the declared classify).
            case buildAppVar args callCanType (enrichFromEnv func funcUseVar s1) of
                ( appVar, s2 ) ->
                    let
                        s3 =
                            unifyStepBestEffort funcUseVar appVar s2
                    in
                    -- Bridge into the destructor's own type ids (and through
                    -- them, the root case/tuple type) for derived functions.
                    case accessedLocalName func of
                        Just localName ->
                            case Dict.get localName s3.derivedDestructors of
                                Just dCan ->
                                    case Store.loadTypeS dCan s3 of
                                        ( dVar, s4 ) ->
                                            unifyStepBestEffort dVar appVar s4

                                Nothing ->
                                    s3

                        Nothing ->
                            s3


buildAppVar : List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Vars.Variable
buildAppVar args callCanType s0 =
    case args of
        [] ->
            Store.loadType callCanType s0

        arg :: rest ->
            case Store.loadType (TOpt.typeOf arg) s0 of
                ( argVar, s1 ) ->
                    case buildAppVar rest callCanType s1 of
                        ( restVar, s2 ) ->
                            Engine.freshVar (Vars.Structure (Vars.Fun1 argVar restVar)) s2


translateIndirectCallBody : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateIndirectCallBody region func args callCanType s0 =
    case Engine.traverse translate args s0 of
        ( monoArgs, s1 ) ->
            case translate func s1 of
                ( monoFunc, s2 ) ->
                    case devirtDirectTarget func args monoFunc s2 of
                        ( Just (DevirtGlobal ctorGlobal), s3 ) ->
                            -- E9 (LSS_015): the callee value is provably
                            -- ONE ctor — rewrite the callee to the ctor
                            -- reference at the site's own type (enqueues
                            -- the ctor spec at this layout); downstream
                            -- staging/codegen emit a DIRECT ctor call,
                            -- removing the dispatch. monoFunc's own
                            -- translation (a var read) already happened,
                            -- so state effects are identical.
                            case translateVarRef func region ctorGlobal (TOpt.typeOf func) (bumpDevirtDirect s3) of
                                ( ctorRef, s4 ) ->
                                    case classifyAs Mono.tkClassCall callCanType s4 of
                                        ( classifiedResult, s5 ) ->
                                            case indirectResultAnno (Mono.typeOf monoFunc) (List.length args) classifiedResult s5 of
                                                ( resultMonoType, s6 ) ->
                                                    ( Mono.MonoCall region ctorRef monoArgs resultMonoType Mono.defaultCallInfo, s6 )

                        ( Just (DevirtKernel kernelPrefix home name), s3 ) ->
                            -- E9.2 (LSS_016): the callee value is provably
                            -- ONE whitelisted kernel — build the same
                            -- direct form a written-out call produces
                            -- (`translateKernelCall`'s shape), but on the
                            -- ALREADY-translated monoArgs: re-invoking the
                            -- full kernel path would translate the args a
                            -- second time (doubled state effects). The ABI
                            -- derives post-hoc, and the SITE type can be
                            -- IMPRECISE: deep shared specs (combinator
                            -- soups) reach the devirt with unresolved
                            -- tvars defaulted to Int, and deriving cons
                            -- over (Int, Int -> Int) would mint a
                            -- poisonous cons_Int ABI (i64 tail/result —
                            -- a list pointer reinterpreted as raw i64;
                            -- caught by the CGEN_038 kernel-decl
                            -- registry as a signature mismatch). GUARD:
                            -- the derived type must have the whitelist
                            -- entry's true shape or the devirt is
                            -- DECLINED and the site falls back to the
                            -- always-correct indirect call.
                            case deriveKernelAbiTypeCall ( home, name ) (TOpt.typeOf func) args s3 of
                                ( funcMonoType, s4 ) ->
                                    case callResultType (List.length args) funcMonoType callCanType s4 of
                                        ( resultMonoType, s5 ) ->
                                            if not (kernelDevirtShapeOk home name funcMonoType) then
                                                -- census (E10.0): shape-guard decline.
                                                indirectCallFallback region monoFunc monoArgs (List.length args) callCanType (bumpKernelDeclineShape () s5)

                                            else if not (kernelDevirtEmissionOk home name monoArgs resultMonoType) then
                                                -- census (E10.0): emission-guard decline, split
                                                -- CNumber (unsettled site — the declinedUnsettled
                                                -- proxy) vs other (scalar tail/result, arg shape).
                                                indirectCallFallback region monoFunc monoArgs (List.length args) callCanType (bumpKernelDeclineEmission home name monoArgs resultMonoType s5)

                                            else
                                                ( Mono.MonoCall region
                                                    (Mono.MonoVarKernel region kernelPrefix home name funcMonoType)
                                                    monoArgs
                                                    resultMonoType
                                                    Mono.defaultCallInfo
                                                , bumpDevirtKernel s5
                                                )

                        ( Nothing, s3 ) ->
                            indirectCallFallback region monoFunc monoArgs (List.length args) callCanType s3


{-| E9 (LSS\_015) / E9.2 (LSS\_016): what a devirtualized indirect call
rewrites to — a standalone global (ctor or fn-global), or a whitelisted
kernel (prefix, home, name).
-}
type DevirtTarget
    = DevirtGlobal TOpt.Global
    | DevirtKernel Name Name Name


{-| E9.2 (LSS\_016): the Elm-visible arity a singleton `{k|home.name}` must
exactly saturate before it may devirtualize, or `Nothing` for an unregistered
kernel (which keeps its indirect call).

The registration itself lives in `KernelFacts` — beside the purity evidence
that devirt makes load-bearing — rather than in an if-else chain here; see
`KernelFacts.DevirtPolicy` and plans/kernel-devirt-arity-table.md.

-}
kernelDevirtArity : Name -> Name -> Maybe Int
kernelDevirtArity home name =
    case KernelFacts.devirtOf ( home, name ) of
        KernelFacts.DevirtAt arity _ ->
            Just arity

        KernelFacts.DevirtNo ->
            Nothing


{-| E9.2 (LSS\_016) shape guard: the DERIVED site ABI type must be sane for
the whitelist entry before the devirt may emit the direct kernel call. For
`List.cons : a -> List a -> List a` the tail arg and the result are BOXED
slots in every legal ABI variant (`eco.value` — only the HEAD is ever
unboxed, REP rules), so they derive as `MVar CEcoValue` (preserved-vars
mode) or a list type (substitution mode) — never as an unboxed SCALAR. An
imprecise site (unresolved tvars defaulted to Int in a deep shared
combinator spec) derives `(Int, Int) -> Int`, whose cons\_Int ABI would
treat the tail list pointer as a raw i64 (caught as a CGEN\_038 kernel-decl
mismatch pre-guard). Decline on scalar tail/result ⇒ the site stays an
indirect call, which is layout-agnostic and always correct.
-}
kernelDevirtShapeOk : Name -> Name -> Mono.MonoType -> Bool
kernelDevirtShapeOk home name funcMonoType =
    case KernelFacts.devirtOf ( home, name ) of
        KernelFacts.DevirtNo ->
            False

        KernelFacts.DevirtAt arity guard ->
            case guard of
                KernelFacts.ShapeAny ->
                    True

                KernelFacts.ShapeNoUnboxedScalarAt positions ->
                    case peelArrow arity funcMonoType of
                        Just ( argTypes, resultType ) ->
                            List.all (\pos -> not (unboxedScalar (atPosition pos argTypes resultType))) positions

                        Nothing ->
                            False


{-| The type at a guard position: `-1` is the result, otherwise the 0-based
argument. An out-of-range index yields the RESULT, which is the conservative
answer — a malformed guard declines rather than waving a site through.
`validationErrors` rejects such rows anyway.
-}
atPosition : Int -> List Mono.MonoType -> Mono.MonoType -> Mono.MonoType
atPosition pos argTypes resultType =
    if pos < 0 then
        resultType

    else
        case List.drop pos argTypes of
            t :: _ ->
                t

            [] ->
                resultType


{-| Peel `n` arguments off a derived kernel arrow, which arrives CURRIED (one
arg per `MFunction` level, from the `Can.tLambda` spine) or FLAT (the
site-substituted classify form), or any mixture. Anything that does not yield
exactly `n` args declines (safe). Generalizes the v1 `consTailAndResult`.
-}
peelArrow : Int -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelArrow n tipe =
    peelArrowGo n tipe []


peelArrowGo : Int -> Mono.MonoType -> List Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelArrowGo remaining tipe acc =
    if remaining == 0 then
        Just ( List.reverse acc, tipe )

    else
        case tipe of
            Mono.MFunction _ _ argTypes result ->
                let
                    taken =
                        List.length argTypes
                in
                if taken <= remaining then
                    peelArrowGo (remaining - taken) result (List.reverse argTypes ++ acc)

                else
                    Nothing

            _ ->
                Nothing


{-| E9.2 (LSS\_016) EMISSION guard — the decisive one: codegen derives the
kernel DECLARATION from the actual argument/result mono types (not the
callee type), so those are what must be sane. In preserved-vars mode the
DERIVED callee type is all boxed placeholders and passes the shape guard,
while the site's real args are scalar-typed (an Int-layout `List.foldl`
spec whose `func` slot wrongly carries {k|List.cons}) — emitting would
register `Elm_Kernel_List_cons_Int : (i64, i64) -> i64` and collide with
the true declaration (CGEN\_038). For cons: the TAIL arg's and the
RESULT's mono types must not be unboxed scalars.
-}
kernelDevirtEmissionOk : Name -> Name -> List Mono.MonoExpr -> Mono.MonoType -> Bool
kernelDevirtEmissionOk home name monoArgs resultMonoType =
    case KernelFacts.devirtOf ( home, name ) of
        KernelFacts.DevirtNo ->
            False

        KernelFacts.DevirtAt arity guard ->
            let
                argTypes =
                    List.map Mono.typeOf monoArgs

                shapeOk =
                    case guard of
                        KernelFacts.ShapeAny ->
                            True

                        KernelFacts.ShapeNoUnboxedScalarAt positions ->
                            List.all (\pos -> not (unboxedScalar (atPosition pos argTypes resultMonoType))) positions
            in
            (List.length monoArgs == arity)
                && shapeOk
                -- DEEP CNumber-freedom, applied to EVERY registered kernel
                -- rather than just to cons. A residual number var anywhere in
                -- the site's types (observed live: tail `MList (MVar CNumber)`
                -- in a generic foldl translation) means the layout is not
                -- settled — the demand-closing rewrite can later collapse those
                -- positions for a different instantiation (b := Int), leaving
                -- this frozen kernel call ill-typed (the (i64,i64)->i64
                -- cons_Int CGEN_038 collision). The hazard is sharpest for
                -- suffix-selecting kernels, but declining an unsettled site
                -- costs only a dispatch and the `declinedKernelCNumber` census
                -- measures what it costs. Devirt only fully-settled sites.
                && not (List.any containsCNumber argTypes)
                && not (containsCNumber resultMonoType)


containsCNumber : Mono.MonoType -> Bool
containsCNumber t =
    case t of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MFunction _ _ argTypes result ->
            List.any containsCNumber argTypes || containsCNumber result

        Mono.MList _ elem ->
            containsCNumber elem

        Mono.MTuple _ elems ->
            List.any containsCNumber elems

        Mono.MCustom _ _ _ typeArgs ->
            List.any containsCNumber typeArgs

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc || containsCNumber ft) False fields

        _ ->
            False


unboxedScalar : Mono.MonoType -> Bool
unboxedScalar t =
    case t of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MChar ->
            True

        Mono.MVar _ Mono.CNumber ->
            -- The Prune taint the deriveKernelAbiTypeWith comment warns
            -- about: a residual CNumber var looks boxed at translate time
            -- but Prune CLOSES it to MInt before emission — the derived
            -- cons ABI then carries an i64 tail/result after all. Only
            -- CEcoValue residuals are guaranteed to stay boxed.
            True

        _ ->
            False


{-| The plain indirect-call emission (LSS\_013 result-anno transport) — the
no-devirt path, shared with devirt arms that must DECLINE at rewrite time
(the E9.2 shape guard).
-}
indirectCallFallback : A.Region -> Mono.MonoExpr -> List Mono.MonoExpr -> Int -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
indirectCallFallback region monoFunc monoArgs argCount callCanType s0 =
    case classifyAs Mono.tkClassCall callCanType s0 of
        ( classifiedResult, s1 ) ->
            case indirectResultAnno (Mono.typeOf monoFunc) argCount classifiedResult s1 of
                ( resultMonoType, s2 ) ->
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, s2 )


{-| E9 (LSS\_015): decide whether this indirect call devirtualizes to a
direct call. All of: lss on; the callee EXPR is a plain var (purity — the
rewrite drops the callee computation, and only a var read is guaranteed
effect-and-bottom-free); the translated callee's head anno is a singleton
whose member is a STANDALONE GLOBAL ("g|" named function/ctor — `Can.Normal`
ctors like `List.::` are VarGlobal — or "c|" box/enum ctor) or an E9.2
whitelisted KERNEL ("k|"); and the site EXACTLY saturates the target's
declared annotation arity (a partial application is a PAP — out of scope;
kernel arity is pinned by the whitelist).
Provisional-singleton soundness rides LSS\_010: if the spec's demand widens
later, the dirty flush re-translates this node with the joined set and the
devirt re-decides.
-}
devirtDirectTarget : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Mono.MonoExpr -> Step (Maybe DevirtTarget)
devirtDirectTarget func args monoFunc s0 =
    if not s0.env.lss.enabled then
        ( Nothing, s0 )

    else if not (calleeIsPlainVar func) then
        ( Nothing, s0 )

    else
        case Mono.headAnno (Mono.typeOf monoFunc) of
            Mono.LSet [ m ] ->
                case Engine.standaloneMemberGlobal m s0 of
                    ( Nothing, s1 ) ->
                        devirtKernelTarget m (List.length args) s1

                    ( Just ctorGlobal, s1 ) ->
                        case LssInfer.kernelAliasOf ctorGlobal s1 of
                            Just ( kernelPrefix, home, name ) ->
                                -- E9.2/Tier-1 hardening: a KERNEL-ALIAS global
                                -- (`cons = Elm.Kernel.List.cons`) must devirt
                                -- ONLY via the kernel whitelist + guards, never
                                -- via the E9.1 fn-global path: DevirtGlobal
                                -- would enqueue the alias spec at the SITE's
                                -- type and the inliner then plants the raw
                                -- kernel call there — at an imprecise site
                                -- (an Int-layout foldl spec whose slot wrongly
                                -- carries the cons member) that emits a
                                -- poisonous i64-tail cons ABI (CGEN_038
                                -- collision). The g| mint for such globals is
                                -- normally identity-folded to k|, but any
                                -- unfolded mint path lands here — route it to
                                -- the same whitelist decision.
                                case kernelDevirtArity home name of
                                    Just arity ->
                                        if arity == List.length args then
                                            ( Just (DevirtKernel kernelPrefix home name), s1 )

                                        else
                                            ( Nothing, recordKernelArityMiss s1 )

                                    Nothing ->
                                        ( Nothing, recordKernelMiss home name s1 )

                            Nothing ->
                                devirtGlobalTarget ctorGlobal (List.length args) s1

            _ ->
                ( Nothing, s0 )


{-| The ctor / fn-global leg of the devirt decision — the singleton's
standalone global is NOT a kernel alias (those route through the kernel
whitelist above).
-}
devirtGlobalTarget : TOpt.Global -> Int -> Step (Maybe DevirtTarget)
devirtGlobalTarget ctorGlobal argCount s1 =
    if not (isCtorNode ctorGlobal s1 || isBodyNode ctorGlobal s1) then
        -- CTORS + body-bearing FUNCTION globals. Direct CTOR calls have no
        -- body and are never inlined — no inliner surface; the fn-global
        -- class unlocks inlining (E9.1, after the BytesFusion walked-past-let
        -- seam fix).
        ( Nothing, s1 )

    else
        case lookupAnnotation ctorGlobal s1 of
            ( Just (Can.Forall _ annType), s2 ) ->
                let
                    arity =
                        arrowSpineLength annType
                in
                if arity >= 1 && arity == argCount then
                    ( Just (DevirtGlobal ctorGlobal), s2 )

                else
                    ( Nothing, s2 )

            ( Nothing, s2 ) ->
                ( Nothing, s2 )


{-| E9.2 (LSS\_016): the kernel leg of the devirt decision — the singleton
member is not a standalone global; if it is a WHITELISTED kernel and the
site exactly saturates the whitelist-pinned arity, devirtualize.
-}
devirtKernelTarget : Int -> Int -> Step (Maybe DevirtTarget)
devirtKernelTarget m argCount s0 =
    case Engine.standaloneMemberKernel m s0 of
        ( Nothing, s1 ) ->
            ( Nothing, s1 )

        ( Just ( kernelPrefix, home, name ), s1 ) ->
            case kernelDevirtArity home name of
                Just arity ->
                    if arity == argCount then
                        ( Just (DevirtKernel kernelPrefix home name), s1 )

                    else
                        ( Nothing, recordKernelArityMiss s1 )

                Nothing ->
                    ( Nothing, recordKernelMiss home name s1 )


{-| Census (whitelist growth): a kernel-member SINGLETON call site whose
kernel is not on the E9.2 whitelist — the histogram is the shopping list
for whitelist growth, weighted later by the runtime dispatch census.
Stats-only.
-}
recordKernelMiss : Name -> Name -> Engine.S -> Engine.S
recordKernelMiss home name s =
    let
        stats =
            s.lssStats

        key =
            home ++ "." ++ name
    in
    { s
        | lssStats =
            { stats
                | kernelMissHist =
                    Dict.update key (\v -> Just (Maybe.withDefault 0 v + 1)) stats.kernelMissHist
            }
    }


{-| Census helper for the above. Separated so nothing but a flag test runs on
the default path.
-}
recordRefusedLicense : ( String, String ) -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
recordRefusedLicense ( kHome, kName ) canFuncType s =
    case KernelSetFacts.factFor kHome kName of
        Just (KernelSetFacts.TypeFaithful license) ->
            if KernelSetFacts.licenseApplies (Engine.isScalarVar s) license canFuncType then
                s

            else
                let
                    stats =
                        s.lssStats
                in
                { s
                    | lssStats =
                        { stats
                            | kernelUnsolvedHist =
                                Dict.update (kHome ++ "." ++ kName)
                                    (\v -> Just (Maybe.withDefault 0 v + 1))
                                    stats.kernelUnsolvedHist
                        }
                }

        _ ->
            s


{-| Census: a WHITELISTED kernel singleton consulted at a site that does
not saturate the whitelist-pinned arity. Stats-only.
-}
recordKernelArityMiss : Engine.S -> Engine.S
recordKernelArityMiss s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | declinedKernelArity = stats.declinedKernelArity + 1 } }


{-| Is the global's node an actual CONSTRUCTOR (Ctor/Box, chasing Links)?
Enum ctors are nullary and excluded by the arity guard anyway.
-}
isCtorNode : TOpt.Global -> Engine.S -> Bool
isCtorNode g s =
    case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
        Just (TOpt.Ctor _ _ _) ->
            True

        Just (TOpt.Box _) ->
            True

        Just (TOpt.Link target) ->
            isCtorNode target s

        _ ->
            False


{-| E9.1: is the global a body-bearing FUNCTION node? Devirtualizing these
unlocks INLINING of previously-indirect calls — the class E9 v1 excluded
because the new inline shapes tripped the `lookupVar: unbound mono_inline_N`
codegen seam. Behind `lss.devirtFnGlobals` until that seam fix was proven at
self-compile scale; default-ON since Tier 1 (2026-07-20), unconditional since
2026-09-18.
-}
isBodyNode : TOpt.Global -> Engine.S -> Bool
isBodyNode g s =
    case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
        Just (TOpt.Define _ _ _) ->
            True

        Just (TOpt.TrackedDefine _ _ _ _) ->
            True

        Just (TOpt.Cycle _ _ _ _) ->
            True

        Just (TOpt.Link target) ->
            isBodyNode target s

        _ ->
            False


calleeIsPlainVar : TOpt.Expr TypeIds.MVarId -> Bool
calleeIsPlainVar func =
    case func of
        TOpt.VarLocal _ _ ->
            True

        TOpt.TrackedVarLocal _ _ _ ->
            True

        _ ->
            False


arrowSpineLength : Can.Type TypeIds.MVarId -> Int
arrowSpineLength t =
    case t of
        Can.TLambda _ _ rest ->
            1 + arrowSpineLength rest

        _ ->
            0


bumpDevirtDirect : Engine.S -> Engine.S
bumpDevirtDirect s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | devirtDirect = stats.devirtDirect + 1 } }


bumpDevirtKernel : Engine.S -> Engine.S
bumpDevirtKernel s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | devirtKernel = stats.devirtKernel + 1 } }


{-| Census (E10.0): the kernel-devirt SHAPE guard declined. Stats-only.
-}
bumpKernelDeclineShape : () -> Engine.S -> Engine.S
bumpKernelDeclineShape () s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | declinedKernelShape = stats.declinedKernelShape + 1 } }


{-| Census (E10.0): the kernel-devirt EMISSION guard declined — classify
CNumber (residual number var anywhere in the site types = the site is
UNSETTLED; the `declinedUnsettled` population E10's commit-after-settle
relocation would capture) vs other (unboxed-scalar tail/result, arg
shape). The classification re-runs only the cheap non-CNumber clauses:
if they all pass, the failing clause was one of the deep-CNumber checks.
Stats-only.
-}
bumpKernelDeclineEmission : Name -> Name -> List Mono.MonoExpr -> Mono.MonoType -> Engine.S -> Engine.S
bumpKernelDeclineEmission home name monoArgs resultMonoType s =
    let
        stats =
            s.lssStats

        isCNumber =
            if home == "List" && name == "cons" then
                case monoArgs of
                    [ _, tailArg ] ->
                        not (unboxedScalar (Mono.typeOf tailArg))
                            && not (unboxedScalar resultMonoType)

                    _ ->
                        False

            else
                False
    in
    if isCNumber then
        { s | lssStats = { stats | declinedKernelCNumber = stats.declinedKernelCNumber + 1 } }

    else
        { s | lssStats = { stats | declinedKernelEmission = stats.declinedKernelEmission + 1 } }


{-| LSS\_013 transport: an indirect call's result type carries the CALLEE's
peeled inner-arrow lambda sets. `classify callCanType` gives the byte-path
result STRUCTURE (LTop annos); flag-on we overlay the annotations from the
already-translated callee's own MonoType (which carries the transported sets on
its arrows — spine injection + demand seeding), peeled by the arg count. This is
what moves a member from `f`'s inner arrow to `let g = f 10`'s type. GATED on
`lss.enabled` so flag-off is a pure passthrough → byte-identical (the overlay
would be a no-op there anyway, since flag-off callee arrows are slotless, but the
guard makes byte-identity independent of any structural subtlety in the peel).
-}
indirectResultAnno : Mono.MonoType -> Int -> Mono.MonoType -> Step Mono.MonoType
indirectResultAnno funcMono argCount classifiedResult s0 =
    if s0.env.lss.enabled then
        ( Mono.overlayAnnotations classifiedResult (peelResultAnno argCount funcMono), s0 )

    else
        ( classifiedResult, s0 )


{-| Peel `n` argument positions off a (possibly multi-param-per-arrow) function
MonoType, returning the residual result type (for annotation overlay only). A
partial peel within a multi-param arrow keeps the arrow's own annotation on the
remaining params (a PAP of member m is m — OQ4 / LSS\_013).
-}
peelResultAnno : Int -> Mono.MonoType -> Mono.MonoType
peelResultAnno n t =
    if n <= 0 then
        t

    else
        case t of
            Mono.MFunction _ anno params ret ->
                let
                    np =
                        List.length params
                in
                if n >= np then
                    peelResultAnno (n - np) ret

                else
                    Mono.mFunction anno (List.drop n params) ret

            _ ->
                t


{-| Specialize a call to a top-level global (monomorphic or polymorphic). The
callee's demanded type is derived by instantiating its scheme with fresh vars,
unifying the parameter slots with the concrete argument types and the result
with the expected call type, then zonking — the store equivalent of the original
engine's `applySubstPure` (monomorphic) / `unifyCallSiteDirectWithExpected`
(polymorphic).
-}
translateGlobalCall : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCall region funcRegion global funcCanType args callCanType s =
    -- Fast paths are guarded to no multi-instance recording in flight (that
    -- path has side effects they must not skip).
    if List.isEmpty s.numberMulti && List.isEmpty s.localMulti then
        -- LSS gate: the cached/storeless fast classifications stamp LTop,
        -- which is exact only when the callee's signature is trivial AND
        -- no argument type mentions an arrow (an arrow-free ground call
        -- cannot transport sets). lss off ⇒ trivially permitted.
        case lssFastOk global args s of
            ( fastOk, s0 ) ->
                if not fastOk || needsPapSlow global args callCanType s0 then
                    translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0

                else if groundCanType funcCanType then
                    -- M2a: a CLOSED (var-free) scheme instantiates to a fully-ground
                    -- structure — its classification is item-independent (cached) and
                    -- unifying params against args is a no-op on the scheme, so only
                    -- flow demand INTO non-ground args.
                    translateGlobalCallFast region funcRegion global funcCanType args callCanType s0

                else if groundCanType callCanType && List.all (groundCanType << TOpt.typeOf) args then
                    -- M2b: an OPEN scheme called with all-ground args and result. The
                    -- instantiate+unify+zonk outcome is then a pure function of
                    -- (global, argMonos, resultMono) — memoize it. Ground args carry
                    -- no vars, so there is no demand to flow into them or back.
                    translateGlobalCallGroundMemo region funcRegion global funcCanType args callCanType s0

                else
                    translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0

    else
        translateGlobalCallSlow region funcRegion global funcCanType args callCanType s


{-| Injection completeness (plans/lss-injection-completeness.md §2.3): must
this call take the SLOW path so its residual arrows can carry the callee's
member?

`lssFastOk` inspects the ARGUMENTS for arrows but never the RESULT, so a
partial application with ground args — `(::) x` exactly, the shape that
manufactured the `arrowSolverRoots` false singleton — takes the M2b
ground-memo fast path today. The fast paths never mint store structure, so
there is no slot to inject into: the injection would silently never fire on
its motivating case. Route partials to the slow path instead.

The `canTypeHasArrow callCanType` pre-filter runs first and is cheap: a call
whose RESULT mentions no arrow cannot be a partial application of a
function-typed residual, so the arity walk only runs on candidate sites.
Flag-off this is one Bool test.

-}
needsPapSlow : TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Engine.S -> Bool
needsPapSlow global args callCanType s =
    s.env.lss.enabled
        && canTypeHasArrow callCanType
        && LssInfer.declaredArityOf global 8 s
        > List.length args


{-| May this call take the cached fast paths under LSS? `sigTrivial` forces
the signature computation on first use — the memo makes that a one-time cost
per global.
-}
lssFastOk : TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Step Bool
lssFastOk global args s =
    if not s.env.lss.enabled then
        ( True, s )

    else if List.any (canTypeHasArrow << TOpt.typeOf) args then
        ( False, s )

    else
        case LssInfer.signatureFor global s of
            ( sig, s1 ) ->
                ( sig.trivial, s1 )


{-| Does a canonical type mention an arrow anywhere? (Syntactic; aliases
followed when filled.)
-}
canTypeHasArrow : Can.Type TypeIds.MVarId -> Bool
canTypeHasArrow t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TVar _ ->
            False

        Can.TType _ _ typeArgs ->
            List.any canTypeHasArrow typeArgs

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> acc || canTypeHasArrow ft) False fields

        Can.TUnit ->
            False

        Can.TTuple a b rest ->
            canTypeHasArrow a || canTypeHasArrow b || List.any canTypeHasArrow rest

        Can.TAlias _ _ aliasArgs (Can.Filled real) ->
            canTypeHasArrow real || List.any (\( _, at ) -> canTypeHasArrow at) aliasArgs

        Can.TAlias _ _ aliasArgs (Can.Holey real) ->
            canTypeHasArrow real || List.any (\( _, at ) -> canTypeHasArrow at) aliasArgs


{-| Equality of two canonical types **ignoring arrow ids** (Phase 2a §4.6a,
`plans/lss-unknown-elimination.md`).

`classifyLambdaHead`'s def-root reuse used to test `annCanType == canType` — a
whole-tree Elm `==` over `Can.Type MVarId`. Under per-occurrence arrow identity
the stashed annotation and the body node's type carry DIFFERENT ids for the same
shape, so that equality would silently become always-false, `lssRootAnn` would
switch off, and the change would regress exactly the case the mechanism exists
to fix — a green build with a large precision loss, and the likeliest way to
land Phase 2a badly.

**Implemented as strip-then-`==`, not as a hand-written structural walk, and
that is deliberate.** Elm's `==` on `Dict` is structural over the red-black
TREE, so two field maps with identical contents but different insertion orders
compare unequal (the hazard `Intern.widenSets` documents). A hand-written
size-plus-probe comparator would make MORE records compare equal than `==`
does, which is a behaviour change flag-off — and Phase 2a is required to be
byte-identical flag-off. `stripArrowIds` rebuilds records with `Dict.map`,
which PRESERVES the input tree shape, so this reproduces the old `==` exactly.

The `a == b` short-circuit keeps the common case allocation-free: when the two
sides really are one object (or agree on ids), no copy is built. The strip is
only paid on a genuine id-only difference, at most once per def root.

-}
sameCanTypeIgnoringArrows : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Bool
sameCanTypeIgnoringArrows a b =
    (a == b) || (stripArrowIds a == stripArrowIds b)


{-| Rewrite every arrow id in a canonical type to `noArrowId`, preserving
everything else INCLUDING record field-map tree shape (`Dict.map`). Enumerates
all seven arms: arrows hide under `TType`, `TRecord`, `TTuple` and BOTH
`TAlias` forms, so a two-arm version with an `_ -> t` fallback would be wrong.
-}
stripArrowIds : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
stripArrowIds t =
    case t of
        Can.TLambda _ from to ->
            Can.tLambda (stripArrowIds from) (stripArrowIds to)

        Can.TVar _ ->
            t

        Can.TType home name args ->
            Can.TType home name (List.map stripArrowIds args)

        Can.TRecord fields ext ->
            Can.TRecord (Dict.map (\_ (Can.FieldType i ft) -> Can.FieldType i (stripArrowIds ft)) fields) ext

        Can.TUnit ->
            t

        Can.TTuple x y rest ->
            Can.TTuple (stripArrowIds x) (stripArrowIds y) (List.map stripArrowIds rest)

        Can.TAlias home name args (Can.Filled inner) ->
            Can.TAlias home name (List.map (Tuple.mapSecond stripArrowIds) args) (Can.Filled (stripArrowIds inner))

        Can.TAlias home name args (Can.Holey inner) ->
            Can.TAlias home name (List.map (Tuple.mapSecond stripArrowIds) args) (Can.Holey (stripArrowIds inner))


{-| True when a canonical type has no free type variable (a closed scheme).
Conservative: never True for a type carrying a var, so the fast path is only
taken when instantiation would be a pure no-op.
-}
groundCanType : Can.Type TypeIds.MVarId -> Bool
groundCanType canType =
    case canType of
        Can.TVar _ ->
            False

        Can.TLambda _ a b ->
            groundCanType a && groundCanType b

        Can.TType _ _ args ->
            List.all groundCanType args

        Can.TRecord fields maybeExt ->
            case maybeExt of
                Just _ ->
                    False

                Nothing ->
                    List.all (\( _, Can.FieldType _ t ) -> groundCanType t) (Dict.toList fields)

        Can.TUnit ->
            True

        Can.TTuple a b rest ->
            groundCanType a && groundCanType b && List.all groundCanType rest

        Can.TAlias _ _ _ (Can.Filled inner) ->
            groundCanType inner

        Can.TAlias _ _ aliasArgs (Can.Holey _) ->
            -- Holey body's only vars are the params, bound to args → ground iff
            -- every arg is ground.
            List.all (\( _, t ) -> groundCanType t) aliasArgs


{-| Peel `n` leading parameter MonoTypes off a single-arg-per-arrow function
MonoType — one per `MFunction` node, matching `peelResult`'s peeling.
-}
mFunctionParams : Int -> Mono.MonoType -> List Mono.MonoType
mFunctionParams n mt =
    if n <= 0 then
        []

    else
        case mt of
            Mono.MFunction _ _ (p :: _) result ->
                p :: mFunctionParams (n - 1) result

            _ ->
                []


{-| Closed-scheme classification, from the global cache or computed purely
(`Zonk.canTypeToMono`, which equals the slow path's zonk of a fully-ground
instantiated scheme) and cached.
-}
cachedSchemeMono : String -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
cachedSchemeMono key funcCanType s0 =
    case Engine.lookupSchemeMono key s0 of
        ( Just mt, s1 ) ->
            ( mt, s1 )

        ( Nothing, s1 ) ->
            computeSchemeMono key funcCanType s1


{-| The `cachedSchemeMono` miss path, as a direct state function so the K6
hash-cons table threads through the classification (a scheme's MonoType is
retained by the memo and reused at every call site of that global, so
canonicalising it is what lets those uses share one object).
-}
computeSchemeMono : String -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
computeSchemeMono key funcCanType s0 =
    let
        ( mt, intern1 ) =
            Zonk.canTypeToMonoI s0.env.superStatic funcCanType s0.intern
    in
    case Engine.putSchemeMono key mt { s0 | intern = intern1 } of
        s1 ->
            ( mt, s1 )


{-| Flow the closed callee's ground parameter types into the args: a ground arg
already matches its ground param (a no-op unify), so skip it; a var-carrying arg
gets its vars concretized to the ground param via `demandUnify` (the store
equivalent of the slow path's per-arg param↔arg unification — enrichment is
redundant against a fully-ground param).
-}
flowArgDemands : List ( Mono.MonoType, Can.Type TypeIds.MVarId ) -> Engine.S -> Engine.S
flowArgDemands pairs s0 =
    List.foldl
        (\( paramMono, argCanType ) sAcc ->
            if groundCanType argCanType then
                sAcc

            else
                demandUnify argCanType paramMono sAcc
        )
        s0
        pairs


translateGlobalCallFast : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallFast region funcRegion global funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    case cachedSchemeMono (TOpt.toComparableGlobal global) funcCanType s0 of
        ( funcMonoType, s1 ) ->
            let
                paramMonos =
                    mFunctionParams argCount funcMonoType
            in
            if List.length paramMonos < argCount then
                -- Over-applied relative to the scheme's arrows: the slow path's
                -- Fun1 peeling handles this; fall back.
                translateGlobalCallSlow region funcRegion global funcCanType args callCanType s1

            else
                let
                    resultMonoType =
                        peelResult argCount funcMonoType

                    s2 =
                        flowArgDemands (List.map2 Tuple.pair paramMonos (List.map TOpt.typeOf args)) s1

                    s3 =
                        if groundCanType callCanType then
                            s2

                        else
                            demandUnify callCanType resultMonoType s2
                in
                case Engine.traverse translate args s3 of
                    ( monoArgs, s4 ) ->
                        case enqueueSpecStamped global funcMonoType s4 of
                            ( specId, s5 ) ->
                                ( Mono.MonoCall region
                                    (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                    monoArgs
                                    resultMonoType
                                    Mono.defaultCallInfo
                                , s5
                                )


{-| M2b: memoized open-scheme call at all-ground args/result. The key is
`(global, ground arg MonoTypes, expected result MonoType)`; the cached value is
the slow path's `(funcMonoType, resultMonoType)`. Because ground args carry no
type variables, they touch neither the item memo nor demand flow, so on a hit
the whole instantiate+unify+zonk is skipped and only the args are translated and
the spec enqueued — byte-identical to the slow path.
-}
translateGlobalCallGroundMemo : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallGroundMemo region funcRegion global funcCanType args callCanType s0 =
    let
        key =
            -- Phase 3 site 1 (plans/speckey-optimization.md §10.2): the
            -- key is the callee Global plus the synthetic `args ->
            -- result` arrow these types already denote. The probe reads
            -- the `specHashOf` Int stored IN the type node and confirms
            -- with `eqKeySpec`, which partitions IDENTICALLY to the
            -- `toComparableMonoType` concatenation this replaces —
            -- pinned by ComparableKeyEncodingTest
            -- (`eqKeySpec a b == (toComparableMonoType a == toComparableMonoType b)`).
            -- The arg/result MonoTypes were already being built here
            -- purely to be rendered; only the rendering is deleted.
            --
            -- Annotation-neutral by construction (M4 == audit):
            -- canTypeToMono stamps LTop on every arrow AND the wrapper
            -- arrow is built at LTop, and lssFastOk gates this memo to
            -- trivial-signature callees with arrow-free args, so no set
            -- can differ under one key and the cached (funcMonoType,
            -- resultMonoType, specId) replay is exact.
            Mono.SpecKey (toptToMonoGlobal global)
                (Mono.mFunction Mono.topDeclOther
                    (List.map (Zonk.canTypeToMono s0.env.superStatic << TOpt.typeOf) args)
                    (Zonk.canTypeToMono s0.env.superStatic callCanType)
                )
    in
    case Engine.lookupCallMemo key s0 of
        ( Just ( funcMonoType, resultMonoType, specId ), s1 ) ->
            -- D10 HIT: the spec was scheduled on the first miss
            -- (scheduled is monotonic), so skip enqueue entirely —
            -- no `getOrCreateSpecId` re-serialization — and emit
            -- the cached specId directly. Args still translate.
            case Engine.traverse translate args s1 of
                ( monoArgs, s2 ) ->
                    ( Mono.MonoCall region
                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                        monoArgs
                        resultMonoType
                        Mono.defaultCallInfo
                    , s2
                    )

        ( Nothing, s1 ) ->
            -- Compute exactly as the slow path does; enqueue to get
            -- the specId; cache (funcMono, resultMono, specId).
            case instantiate funcCanType s1 of
                ( funcVar, s2 ) ->
                    let
                        s3 =
                            unifyResultWithExpected funcVar
                                (List.length args)
                                callCanType
                                (unifyParamsWithArgExprs funcVar args s2)
                    in
                    case Store.zonkToMono funcVar s3 of
                        ( funcMonoType, s4 ) ->
                            case callResultType (List.length args) funcMonoType callCanType s4 of
                                ( resultMonoType, s5 ) ->
                                    case Engine.traverse translate args s5 of
                                        ( monoArgs, s6 ) ->
                                            case enqueueSpecStamped global funcMonoType s6 of
                                                ( specId, s7 ) ->
                                                    ( Mono.MonoCall region
                                                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                                        monoArgs
                                                        resultMonoType
                                                        Mono.defaultCallInfo
                                                    , Engine.putCallMemo key ( funcMonoType, resultMonoType, specId ) s7
                                                    )


translateGlobalCallSlow : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    -- Instantiate the callee and unify its params/result against the arg types
    -- FIRST, concretizing shared vars in the item memo, THEN translate the args
    -- so their VarLocal uses see the demanded type (solver-native demand flow;
    -- needed for number-multi and for a faithful funcMonoType).
    -- D11: direct state-passing (desugared 7-deep andThen/map nest). Eliminates
    -- the seven per-call monad closures; monad-law-preserving → byte-identical.
    case instantiateLss global funcCanType s0 of
        ( funcVar, s1 ) ->
            case unifyParamsCollect funcVar args s1 of
                ( argStash, s2 ) ->
                    case unifyResultThenInjectPap funcVar argCount callCanType global s2 of
                        s3 ->
                            case translateArgsWith argStash args s3 of
                                ( monoArgs, s3b ) ->
                                    -- LSS_026 Phase-0 census (plan §2.1
                                    -- rows 1/4/5). AFTER the args are
                                    -- translated, so every arg-callee's
                                    -- signature is already memoized and
                                    -- the census can READ triviality
                                    -- without forcing it (forcing would
                                    -- move member-id allocation order,
                                    -- and `report` is excluded from the
                                    -- config hash). Report-gated.
                                    case censusArgs global args s3b of
                                        s4 ->
                                            case Store.zonkToMono funcVar s4 of
                                                ( funcMonoType, s5 ) ->
                                                    case callResultType argCount funcMonoType callCanType s5 of
                                                        ( resultMonoType, s6 ) ->
                                                            case enqueueSpecStamped global funcMonoType s6 of
                                                                ( specId, s7pre ) ->
                                                                    let
                                                                        -- Phase 2b flex-construction mark
                                                                        -- (plans/lss-var-chain-roots.md §3): a ctor
                                                                        -- construction transporting an UNRESOLVED
                                                                        -- flex arrow may hide a real inhabitant
                                                                        -- behind this spec's var payload row.
                                                                        s7 =
                                                                            if
                                                                                s7pre.env.lss.enabled
                                                                                    && not (List.isEmpty monoArgs)
                                                                                    && List.any (Mono.hasVarAnno << Mono.typeOf) monoArgs
                                                                                    && isCtorNode global s7pre
                                                                            then
                                                                                Engine.markFlexCtorSpec specId s7pre

                                                                            else
                                                                                s7pre
                                                                    in
                                                                    ( Mono.MonoCall region
                                                                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                                                        monoArgs
                                                                        resultMonoType
                                                                        Mono.defaultCallInfo
                                                                    , s7
                                                                    )


{-| LSS\_026 Phase-0 census (plans/lss-gap2-callarg-transport.md §2.1 rows
1/4/5). REPORT-GATED — the whole fold is skipped when `lss.report` is off, so
the default path pays one branch per slow global call. Pure with respect to
the artifact: it only READS (`memoizedSignatureTrivial`), never forces.

Rows:

  - `pop|*` — the transport population: CALL-shaped arguments whose type
    mentions an arrow (exactly GAP-2's hole), split by consumer global
    (`pop|hof=`), by arg-callee class (`pop|callee=`) and by whether the
    arg-callee's signature is trivial (`pop|calleeTrivial=`). A trivial
    arg-callee has nothing to transport, so `calleeTrivial=1` is the share
    of the population the repair cannot help.
  - `fan|<hof>|<callee>|<layout>` — one key per distinct
    (consumer × arg-callee × argument layout) triple: counting DISTINCT
    keys per consumer is the keyed-spec fan-out forecast (§2.1 row 4).
  - `shape|*` — arrow-mentioning arguments that are NOT calls: the classes
    already transported today (lambda literals, standalone globals) plus
    the wrapped/blind shapes this plan's v1 declines (§8) and D2's poison
    forecast (`shape|blind`).

-}
censusArgs : TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
censusArgs global args s0 =
    if not s0.env.lss.report then
        s0

    else
        censusArgsGo (TOpt.toComparableGlobal global) args s0


censusArgsGo : String -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
censusArgsGo hofKey args s0 =
    case args of
        [] ->
            s0

        arg :: rest ->
            if not (canTypeHasArrow (TOpt.typeOf arg)) then
                -- No set positions to transport: not part of any population.
                censusArgsGo hofKey rest s0

            else
                censusArgsGo hofKey rest (censusOneArg hofKey arg s0)


censusOneArg : String -> TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
censusOneArg hofKey arg s0 =
    case arg of
        TOpt.Call _ func innerArgs _ ->
            let
                calleeKey =
                    argCalleeKey func

                trivialTag =
                    case func of
                        TOpt.VarGlobal _ g _ ->
                            case Engine.memoizedSignatureTrivial g s0 of
                                Just True ->
                                    "1"

                                Just False ->
                                    "0"

                                Nothing ->
                                    -- Not memoized even after the arg was
                                    -- translated: keeps the partition honest.
                                    "?"

                        _ ->
                            "n/a"

                supplied =
                    List.length innerArgs

                -- Saturation: a PARTIAL application's value is a PAP of the
                -- callee, whose identity B.1.f `selfIdOf` filters out of the
                -- signature on the premise that the `g|` standalone channel
                -- delivers it — true for a bare VarGlobal arg, FALSE for a
                -- call-shaped one. A SATURATED empty callee genuinely
                -- contributed nothing (e.g. flow through a type-VARIABLE
                -- position the loader mints no slot for). Arity resolved by
                -- `declaredArityOf`; the `arity|` row publishes it so this
                -- split stays auditable (the first cut of the census was
                -- invalidated by the TrackedFunction arity-walk bug).
                maybeDeclared =
                    case func of
                        TOpt.VarGlobal _ g _ ->
                            Just (LssInfer.declaredArityOf g 8 s0)

                        _ ->
                            Nothing

                satTag =
                    case maybeDeclared of
                        Nothing ->
                            "unknown"

                        Just d ->
                            if d <= 0 then
                                "unknown"

                            else if supplied < d then
                                "partial"

                            else if supplied == d then
                                "saturated"

                            else
                                "over"

                -- Distinct `encl|` keys, joined offline against the
                -- `sig|allflex` producer list, bound how much of the empty
                -- mass D2's arg-connection could plausibly convert.
                enclKey =
                    case s0.currentGlobal of
                        Just g ->
                            Mono.toComparableGlobal g

                        Nothing ->
                            "(none)"

                base =
                    s0
                        |> Engine.bumpArgFlowCensus "pop|all"
                        |> Engine.bumpArgFlowCensus ("pop|hof=" ++ hofKey)
                        |> Engine.bumpArgFlowCensus ("pop|callee=" ++ calleeKey)
                        |> Engine.bumpArgFlowCensus ("pop|calleeTrivial=" ++ trivialTag)
                        |> Engine.bumpArgFlowCensus ("sat|" ++ satTag)
                        |> Engine.bumpArgFlowCensus ("sat|" ++ calleeKey ++ "|" ++ satTag)
                        |> Engine.bumpArgFlowCensus ("arity|" ++ calleeKey ++ "|d=" ++ Maybe.withDefault "?" (Maybe.map String.fromInt maybeDeclared) ++ "|s=" ++ String.fromInt supplied)
                        |> Engine.bumpArgFlowCensus ("encl|" ++ enclKey)
                        -- The decision cross-tab: is the REACHABLE population
                        -- concentrated at the HOT consumers?
                        |> Engine.bumpArgFlowCensus ("popt|" ++ hofKey ++ "|triv=" ++ trivialTag)
                        |> Engine.bumpArgFlowCensus ("calleeTriv|" ++ calleeKey ++ "|triv=" ++ trivialTag)
                        |> Engine.bumpArgFlowCensus ("fan|" ++ hofKey ++ "|" ++ calleeKey ++ "|" ++ canKind (TOpt.typeOf arg))
            in
            case ( satTag, maybeDeclared ) of
                ( "partial", Just d ) ->
                    -- The injection depth the PAP lever would need (residual
                    -- arrows between supplied and declared).
                    Engine.bumpArgFlowCensus ("sat|partialDepth=" ++ String.fromInt (d - supplied)) base

                _ ->
                    base

        _ ->
            Engine.bumpArgFlowCensus ("shape|" ++ argShapeName arg) s0


{-| LSS\_026 census: which CLASS of callee an argument call targets. Globals
are named individually (the transport's own population); everything else is
bucketed by class — those are the declined classes of §3.3/§8.
-}
argCalleeKey : TOpt.Expr TypeIds.MVarId -> String
argCalleeKey func =
    case func of
        TOpt.VarGlobal _ g _ ->
            "g:" ++ TOpt.toComparableGlobal g

        TOpt.VarCycle _ home name _ ->
            "cycle:" ++ TOpt.toComparableGlobal (TOpt.Global home name)

        TOpt.VarKernel _ _ home name _ ->
            "kernel:" ++ home ++ "." ++ name

        TOpt.VarDebug _ _ _ _ _ ->
            "debug"

        TOpt.VarLocal _ _ ->
            "local"

        TOpt.TrackedVarLocal _ _ _ ->
            "local"

        _ ->
            "indirect"


{-| LSS\_026 census: the shape of an arrow-mentioning argument that is NOT a
call. `lambda`/`standalone` are the classes `injectArgLambdaMember` already
transports; `letWrapped`/`branchWrapped` are the v1 non-goals; `blind` is
D2's poison forecast (a point the inference walk cannot see honestly).
-}
argShapeName : TOpt.Expr TypeIds.MVarId -> String
argShapeName arg =
    case arg of
        TOpt.Function _ _ _ _ ->
            "lambda"

        TOpt.TrackedFunction _ _ _ _ ->
            "lambda"

        TOpt.VarGlobal _ _ _ ->
            "standalone"

        TOpt.VarEnum _ _ _ _ ->
            "standalone"

        TOpt.VarBox _ _ _ ->
            "standalone"

        TOpt.VarCycle _ _ _ _ ->
            "standalone"

        TOpt.VarKernel _ _ _ _ _ ->
            "kernel"

        TOpt.Accessor _ _ _ ->
            "accessor"

        TOpt.VarLocal _ _ ->
            "local"

        TOpt.TrackedVarLocal _ _ _ ->
            "local"

        TOpt.Let _ _ _ ->
            "letWrapped"

        TOpt.If _ _ _ ->
            "branchWrapped"

        TOpt.Case _ _ _ _ _ ->
            "branchWrapped"

        _ ->
            "blind"


translateKernelCall : A.Region -> A.Region -> Name -> Name -> Name -> ( String, String ) -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateKernelCall region funcRegion kernelPrefix home name kernelId funcCanType args callCanType s0 =
    -- D5: no `argCanTypes` list — it was built only for its length.
    -- Derive the kernel ABI FIRST: this unifies the kernel's param slots with the
    -- argument types, concretizing shared vars in the item memo (e.g. `1.4 * n`
    -- forces `n`'s number var to Float) BEFORE the args are translated — so an
    -- arg's VarLocal use sees the demanded type (needed for number-multi).
    -- D11: direct state-passing (desugared andThen/map) → byte-identical.
    case deriveKernelAbiTypeCall kernelId funcCanType args s0 of
        ( funcMonoType, s1 ) ->
            case Engine.traverse translate args s1 of
                ( monoArgs, s2 ) ->
                    case callResultType (List.length args) funcMonoType callCanType s2 of
                        ( resultMonoType, s3 ) ->
                            ( Mono.MonoCall region
                                (Mono.MonoVarKernel funcRegion kernelPrefix home name funcMonoType)
                                monoArgs
                                resultMonoType
                                Mono.defaultCallInfo
                            , s3
                            )


{-| The MonoCall result type: peel the applied-arg count off the callee's type;
if that still has a var, fall back to the call node's type. Mirrors
`abiResultType`/`peelCallResult` in the original engine.
-}
callResultType : Int -> Mono.MonoType -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
callResultType argCount funcMonoType callCanType s0 =
    let
        abiResultType =
            peelResult argCount funcMonoType
    in
    if Mono.containsAnyMVar abiResultType then
        classifyAs Mono.tkClassCall callCanType s0

    else
        ( abiResultType, s0 )


peelResult : Int -> Mono.MonoType -> Mono.MonoType
peelResult n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ _ result ->
                peelResult (n - 1) result

            _ ->
                monoType



-- ====== KERNEL ABI ======


{-| Kernel ABI for a CALL: instantiate the kernel type fresh, unify its param
slots with the concrete argument types, zonk, then apply the ABI-mode policy.
-}
deriveKernelAbiTypeCall : ( String, String ) -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Step Mono.MonoType
deriveKernelAbiTypeCall kernelId canFuncType args =
    deriveKernelAbiTypeWith kernelId canFuncType <|
        \s0 ->
            case instantiate canFuncType s0 of
                ( funcVar, s1 ) ->
                    ( funcVar, unifyParamsWithArgExprs funcVar args s1 )


{-| Unify each parameter slot of a function Point from the argument EXPRS: the
slot is
unified with the arg's canonical type AND, when the arg is a local with a varEnv
binding, with that bound MonoType too. The env binding carries the CONCRETE type
(a lambda param or destructor-bound local peeled from a concretized instance),
where the use's canonical type may still be a narrow/row-polymorphic
generalization — without this, a body-internal call like `Tuple.second tup`
inside a re-translated local function keys its callee at the NARROW record type
and mis-lays-out fields (RecordNarrow).
-}
unifyParamsWithArgExprs : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
unifyParamsWithArgExprs funcVar args s0 =
    Tuple.second (unifyParamsCollect funcVar args s0)


{-| What `unifyParamsCollect` recorded about one argument position, consumed
by `translateArgsWith`.

  - `StashLocalMulti v`: the FRESH store var minted for a LOCAL-MULTI
    FUNCTION arg (the historical `Just`). Such an arg's canonical type is
    instantiated FRESH (per-call-site) rather than loaded through the shared
    memo: an annotation with crossed var ids (LocalOpt-rebuilt) would
    otherwise poison the function's own type via id sharing
    (TupleSlotBoxingClosure). The caller zonks it to record the instance the
    call actually demanded.
  - `StashNone`: everything else — plain `translate`.

-}
type ArgStash
    = StashNone
    | StashLocalMulti Vars.Variable


{-| Like `unifyParamsWithArgExprs` but returns, per arg, what the argument's
translation needs to know about the position it was unified into (see
`ArgStash`).
-}
unifyParamsCollect : Vars.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Step (List ArgStash)
unifyParamsCollect funcVar args s0 =
    case args of
        [] ->
            ( [], s0 )

        arg :: rest ->
            -- M6/A1: direct state-passing over an explicit trailing S; fires once
            -- per call argument. Monad-law-preserving → byte-identical.
            case Engine.liftIO (UF.get funcVar) s0 of
                ( desc, s1 ) ->
                    case Store.arrowParts desc.content of
                        Just ( pParam, pRest ) ->
                            -- Liveness census (§7): one arrow peeled per
                            -- call argument — this IS the application.
                            case localMultiArgName arg (noteAppliedS desc.content s1) of
                                ( maybeLM, s2 ) ->
                                    case maybeLM of
                                        Just _ ->
                                            -- GAP-9b: fresh-instantiates a local-multi
                                            -- FUNCTION arg, skipping injectArgLambdaMember
                                            -- ("no member, no stamp"). One-shot census
                                            -- 2026-08-18 (Run J): 469 events on the
                                            -- self-compile — minor vs local-⊤ 7,361; the
                                            -- per-event counter was removed after the
                                            -- measurement (plan lss-fidelity-1 §7).
                                            case instantiate (TOpt.typeOf arg) s2 of
                                                ( freshVar0, s3 ) ->
                                                    case unifyStepBestEffort pParam freshVar0 s3 of
                                                        s4 ->
                                                            case unifyParamsCollect pRest rest s4 of
                                                                ( restStash, s5 ) ->
                                                                    ( StashLocalMulti freshVar0 :: restStash, s5 )

                                        Nothing ->
                                            case argUnifyVar arg s2 of
                                                ( argVar, s3 ) ->
                                                    case unifyStepBestEffort pParam argVar s3 of
                                                        s4 ->
                                                            case unifyParamsCollect pRest rest s4 of
                                                                ( restStash, s5 ) ->
                                                                    ( StashNone :: restStash, s5 )

                        Nothing ->
                            -- Over-applied or opaque callee spine: no
                            -- param slot exists for the remaining args.
                            -- LSS_026 census: any Call-shaped arrow args
                            -- left here are STRUCTURALLY unreachable for
                            -- D1's connect (no stash entry is ever made)
                            -- — the `dropped`-vs-population gap.
                            ( List.map (\_ -> StashNone) args, censusStashMiss args s1 )


{-| LSS\_026 census (plan §2.6 "stash gap"): attribute the args that fall out
of `unifyParamsCollect`'s early exit. Joined offline against `calleeTriv|`
rows: a stash-missed site whose arg-callee carries facts is a site D1
cannot serve without first fixing the spine walk. Report-gated.
-}
censusStashMiss : List (TOpt.Expr TypeIds.MVarId) -> Engine.S -> Engine.S
censusStashMiss args s0 =
    if not s0.env.lss.report then
        s0

    else
        let
            qualifying =
                List.filter (\a -> isDirectCallShape a && canTypeHasArrow (TOpt.typeOf a)) args
        in
        if List.isEmpty qualifying then
            s0

        else
            List.foldl
                (\a acc ->
                    acc
                        |> Engine.bumpArgFlowCensus "stashmiss|all"
                        |> Engine.bumpArgFlowCensus
                            ("stashmiss|callee="
                                ++ (case a of
                                        TOpt.Call _ f _ _ ->
                                            argCalleeKey f

                                        _ ->
                                            "?"
                                   )
                            )
                )
                (Engine.bumpArgFlowCensus ("stashmiss|remaining=" ++ String.fromInt (List.length args)) s0)
                qualifying


{-| LSS\_026: is this argument expression itself a CALL? (v1 transport scope —
wrapped shapes like `Let`/`If` around a call are a recorded non-goal, sized
by the `leak|` census rows.)
-}
isDirectCallShape : TOpt.Expr TypeIds.MVarId -> Bool
isDirectCallShape arg =
    case arg of
        TOpt.Call _ _ _ _ ->
            True

        _ ->
            False


{-| Translate call args, using the per-call-site stash for local-multi function
args: zonk the fresh instantiation the params were unified against, record the
instance at THAT type, and emit its per-instance local ref.
-}
translateArgsWith : List ArgStash -> List (TOpt.Expr TypeIds.MVarId) -> Step (List Mono.MonoExpr)
translateArgsWith stash args s0 =
    -- D4: `unifyParamsCollect` always returns exactly `List.length args` stash
    -- entries (every arm produces one per arg), so the former `stash ++
    -- List.repeat 0 Nothing` padding was a no-op that still copied `stash`.
    -- Pair directly.
    Engine.traverse
        (\( entry, arg ) ->
            case ( entry, accessedLocalName arg ) of
                ( StashLocalMulti v, Just localName ) ->
                    -- M6: direct state-passing (desugared andThen/map) → byte-identical.
                    \sa ->
                        case Store.zonkToMono v sa of
                            ( instType0, s1 ) ->
                                case Engine.recordLocalInstance localName instType0 s1 of
                                    ( ( freshName, instType, ord ), s2 ) ->
                                        -- F2 (plans/lss-container-payload-transport.md
                                        -- §12.9.4): the instance is recorded — now
                                        -- write ITS member into the stashed var.
                                        -- `v` is unified with the callee's param
                                        -- slot and the callee is zonked/enqueued
                                        -- only after every argument is translated,
                                        -- so the demand carries the singleton.
                                        -- Record FIRST, inject SECOND: the instance
                                        -- key stays the demand-side type (two uses
                                        -- at one type share an ordinal and an id);
                                        -- injecting first would make the key depend
                                        -- on the ordinal for ord >= 1.
                                        case injectLocalMultiUseMember localName ord v s2 of
                                            s3 ->
                                                ( Mono.MonoVarLocal freshName instType, s3 )

                _ ->
                    translate arg
        )
        (List.map2 Tuple.pair stash args)
        s0


{-| F2 (plans/lss-container-payload-transport.md §12.9.4): the let-function's
RHS source lambda id and param count when the RHS is a lambda literal — what a
use site injects; `Nothing` for tail defs and non-lambda RHSs.
-}
rhsLamOf : TOpt.Expr TypeIds.MVarId -> Maybe ( TypeIds.SrcLambdaId, Int )
rhsLamOf defBody =
    case defBody of
        TOpt.Function (Just lam) params _ _ ->
            Just ( lam, List.length params )

        TOpt.TrackedFunction (Just lam) params _ _ ->
            Just ( lam, List.length params )

        _ ->
            Nothing


{-| F2.c: `Just ( g, supplied )` when the RHS is a call of global `g` with fewer
arguments than `g`'s declared arity (the same test `injectPapMember` makes on
the producer side; `VarGlobal` callees only — the shape the census found).
-}
rhsPapOf : TOpt.Expr TypeIds.MVarId -> Engine.S -> Maybe ( TOpt.Global, Int )
rhsPapOf defBody s =
    case defBody of
        TOpt.Call _ (TOpt.VarGlobal _ g _) args _ ->
            if not (List.isEmpty args) && List.length args < LssInfer.declaredArityOf g 8 s then
                Just ( g, List.length args )

            else
                Nothing

        _ ->
            Nothing


{-| F2 use-site member injection (plans/lss-container-payload-transport.md
§12.9.4). Mint the id the instance's RHS re-translation WILL mint for its
lambda — `injectLambdaMemberQualified` under the instance's own tag
(`localInstanceTagFor ord`, exactly what `retranslateAtInstance` sets) — and
write it into the first `arity` result-spine arrows of the stashed var
(LSS\_013 bounds: a function-returning body's returned closure keeps its own
arrow). The id is a deterministic function of (source lambda, instance tag,
spec id, item-static tables), and interning is get-or-create by key, so the
two mints agree by construction (the v4 join measured it: one id per (def,
ordinal) on every both-sided pair). Ordinal 0 is never tagged. RHSs without a
`SrcLambdaId` take the PAP route (`injectLocalMultiUsePap`) or inject nothing.
-}
injectLocalMultiUseMember : Name -> Int -> Vars.Variable -> Engine.S -> Engine.S
injectLocalMultiUseMember localName ord v s0 =
    if not s0.env.lss.enabled then
        s0

    else
        case List.head (List.filter (\e -> e.defName == localName) s0.localMulti) |> Maybe.andThen .rhsLam of
            Nothing ->
                injectLocalMultiUsePap localName v s0

            Just ( lam, arity ) ->
                case Engine.localInstanceTagFor ord s0 of
                    ( instTag, s1 ) ->
                        let
                            aux1 =
                                s1.itemAux

                            outerTag =
                                aux1.currentLocalInstance
                        in
                        case LssInfer.injectLambdaMemberQualified arity (Just lam) v { s1 | itemAux = { aux1 | currentLocalInstance = instTag } } of
                            s2 ->
                                let
                                    aux2 =
                                        s2.itemAux
                                in
                                Engine.bumpArgFlowCensus "lmInject|use" { s2 | itemAux = { aux2 | currentLocalInstance = outerTag } }


{-| F2.c (plans/lss-container-payload-transport.md §12.10.1): the local's RHS
is a PARTIAL APPLICATION of a global — write the PAP member the RHS
re-translation will mint (`injectPapMember` → `papMemberKey g k`) into the
stashed var, HEAD-ONLY: one arrow deeper is a different PAP (the `p|` law),
and `injectPapMember` writes exactly one position too. Instance-blind by
construction, so ordinals and tags play no part in the agreement.
-}
injectLocalMultiUsePap : Name -> Vars.Variable -> Engine.S -> Engine.S
injectLocalMultiUsePap localName v s0 =
    case List.head (List.filter (\e -> e.defName == localName) s0.localMulti) |> Maybe.andThen .rhsPap of
        Nothing ->
            Engine.bumpArgFlowCensus "lmInject|noLam" s0

        Just ( g, k ) ->
            case Engine.papMemberIdFor g k s0 of
                ( mid, s1 ) ->
                    Engine.bumpArgFlowCensus "lmInject|pap"
                        (LssInfer.injectSpineMemberId 1 mid v s1)


{-| Is the argument a lambda literal? (The M1 flowConnect trigger — only
literals carry a body whose translation solves interior sets in-item.)
-}
isLambdaLiteral : TOpt.Expr TypeIds.MVarId -> Bool
isLambdaLiteral arg =
    case arg of
        TOpt.Function _ _ _ _ ->
            True

        TOpt.TrackedFunction _ _ _ _ ->
            True

        _ ->
            False


{-| M2 P0 shape census (lss-var-chain-roots §9.7 / lss-lpartial follow-on):
classify every lambda literal by the AR-F7 predicate — COLLAPSED multi-param
lambdas (stage identities needed; the §9.1 producer hole) vs NESTED bodies
(the inner λ keeps its own `l|` mid; minting a stage id there would split
identity). Report-gated. Historical: this census decided the M2 GO that
§9.13/§9.14 then overturned (LSS\_013 already names collapsed stages; the
24k here are translations of ALREADY-NAMED stages) — kept as the
population tracker, with that reading correction attached.
-}
m2ShapeCensus : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
m2ShapeCensus params body s =
    if not s.env.lss.report then
        s

    else
        let
            nested =
                isLambdaLiteral body

            key =
                if List.length params >= 2 then
                    if nested then
                        "m2|stagedNested"

                    else
                        "m2|stagedLam"

                else if nested then
                    "m2|nestedLam"

                else
                    "m2|plainLam"
        in
        Engine.bumpArgFlowCensus key s


{-| `Just name` when the arg is a direct reference to a local-multi FUNCTION.
-}
localMultiArgName : TOpt.Expr TypeIds.MVarId -> Step (Maybe Name)
localMultiArgName arg s0 =
    case accessedLocalName arg of
        Just localName ->
            -- M6/A1: direct state-passing over explicit trailing S → byte-identical.
            case Engine.isLocalMultiTarget localName s0 of
                ( isLM, s1 ) ->
                    ( if isLM then
                        Just localName

                      else
                        Nothing
                    , s1
                    )

        Nothing ->
            ( Nothing, s0 )


{-| The store var to unify a call argument against: the arg's canonical type
loaded through the memo, ENRICHED at local leaves with the varEnv binding (the
concrete type of a lambda param / destructor-bound / let-bound local — the use's
canonical type may still be a narrow row-polymorphic generalization). Tuple
literals recurse so a `( 0, outer )` arg carries `outer`'s full record type.
-}
argUnifyVar : TOpt.Expr TypeIds.MVarId -> Step Vars.Variable
argUnifyVar arg s0 =
    -- M6: direct state-passing (desugared andThen) → byte-identical.
    case Store.loadTypeS (TOpt.typeOf arg) s0 of
        ( canVar, s1 ) ->
            case enrichFromEnv arg canVar s1 of
                s2 ->
                    case injectArgLambdaMember arg canVar s2 of
                        s3 ->
                            ( canVar, s3 )


{-| P0 sizing instrument (plans/lss-ctor-arrow-identity.md §8.1): classify
every argument by FORM and by whether a nameable position exists DEEPER than
the depth this injection covers. `argdeep|<form>|<deep|flat>` — the `deep`
rows are the `/a0/r`-class the census says holds 64.6 % of the remaining var.
Report-gated inside `bumpArgFlowCensus`; the type walks are cheap (leading
arrows only) but still guarded.
-}
argDeepCensus : TOpt.Expr TypeIds.MVarId -> Engine.S -> Engine.S
argDeepCensus arg s =
    if not s.env.lss.report then
        s

    else
        let
            depth =
                LssInfer.canTypeArrowDepth (TOpt.typeOf arg)

            ( form, covered ) =
                case arg of
                    TOpt.Function _ params _ _ ->
                        ( "fn", List.length params )

                    TOpt.TrackedFunction _ params _ _ ->
                        ( "fn", List.length params )

                    TOpt.VarGlobal _ g _ ->
                        ( "ref", LssInfer.declaredArityOf g 8 s )

                    TOpt.VarBox _ g _ ->
                        ( "ref", LssInfer.declaredArityOf g 8 s )

                    TOpt.VarCycle _ home name _ ->
                        ( "ref", LssInfer.declaredArityOf (TOpt.Global home name) 8 s )

                    TOpt.VarKernel _ _ _ _ _ ->
                        ( "kernel", 1 )

                    TOpt.Accessor _ _ _ ->
                        ( "accessor", 1 )

                    TOpt.VarLocal _ _ ->
                        ( "local", 0 )

                    TOpt.TrackedVarLocal _ _ _ ->
                        ( "local", 0 )

                    TOpt.Call _ _ _ _ ->
                        ( "call", 0 )

                    _ ->
                        ( "other", 0 )
        in
        if depth == 0 then
            s

        else if depth > covered then
            Engine.bumpArgFlowCensus ("argdeep|" ++ form ++ "|deep") s

        else
            Engine.bumpArgFlowCensus ("argdeep|" ++ form ++ "|flat") s


{-| F2.b (plans/lss-container-payload-transport.md §12.9.4): a local-multi
function referenced INSIDE its own instance re-translation (`Array.foldl`'s
`helper` passing `helper` to `JsArray.foldl`). The stack entry is popped and
the binding scope closed by then (`enrich|unbound`), so `enrichFromEnv` finds
nothing; the value IS the instance being built, whose id is
`injectLambdaMemberQualified` under the tag `retranslateWithTag` already set.
Any other local injects nothing here (its members arrive via `enrichFromEnv`).
-}
injectRetranslatingSelf : Name -> Vars.Variable -> Engine.S -> Engine.S
injectRetranslatingSelf name canVar s0 =
    if not s0.env.lss.enabled then
        s0

    else
        case s0.itemAux.retranslating of
            Just ( selfName, lam, arity ) ->
                if selfName == name then
                    Engine.bumpArgFlowCensus "lmInject|self"
                        (LssInfer.injectLambdaMemberQualified arity (Just lam) canVar s0)

                else
                    s0

            Nothing ->
                s0


injectArgLambdaMember : TOpt.Expr TypeIds.MVarId -> Vars.Variable -> Engine.S -> Engine.S
injectArgLambdaMember arg canVar s0 =
    injectArgLambdaMemberGo arg canVar (argDeepCensus arg s0)


{-| M3 arg-side member transport: a lambda LITERAL passed directly as an
argument must contribute its member to the callee's param arrow slot.

`Store.loadType` mints fresh arrow structure per load (LSS\_006 — only leaf
MVarIds are memo-shared), so the set slot `classifyLambdaHead` injects into
when the lambda is TRANSLATED is a different slot from `canVar`'s — the one
unified with the callee's param. Without this injection the member never
reaches the callee's demand, every downstream call-site annotation zonks to
LTop, and AbiCloning finds nothing to upgrade.

Locals referencing a closure transport through `enrichFromEnv` (the bound
MonoType carries the closure's annotation) when they are not local-multi
targets; local-multi args (fresh-instantiated stash vars) remain a known
precision gap in v1 — safe: no member, no stamp.

-}
injectArgLambdaMemberGo : TOpt.Expr TypeIds.MVarId -> Vars.Variable -> Engine.S -> Engine.S
injectArgLambdaMemberGo arg canVar s =
    case arg of
        TOpt.Function srcLam params _ _ ->
            -- Fix B (LSS_017): translation-phase mint — spec-qualified.
            LssInfer.injectLambdaMemberQualified (List.length params) srcLam canVar s

        TOpt.TrackedFunction srcLam params _ _ ->
            LssInfer.injectLambdaMemberQualified (List.length params) srcLam canVar s

        TOpt.VarGlobal _ g _ ->
            -- E9: standalone globals/ctors passed as function args contribute
            -- their member the same way lambda literals do (head-only, like
            -- standaloneMember — no local arity). Makes the global inhabitant
            -- VISIBLE at the callee's param arrow, which both enables the
            -- devirt (singleton {g|X}) and honestly widens joins where a
            -- global flows alongside lambdas. Flag-off: slotless arrows, the
            -- injection no-ops (spineGo's `_` arm).
            -- E9.2 (LSS_016) identity fold: a kernel-ALIAS global (`(::)` →
            -- VarGlobal List.cons, node = Define (VarKernel …)) IS the kernel
            -- value — mint the kernel member (one identity; a split g|/k|
            -- identity would join to a 2-set and kill singleton consumers),
            -- registered for the kernel devirt's reverse lookup.
            -- refPapSpine (plans/lss-ref-pap-spine.md): after the head
            -- member, the PAP successors p|g|d ride the result spine. The
            -- kernel-alias HEAD stays k| (kernelToSig's inner-arrow hazard is
            -- a k|-member hazard); the successors key by the ALIAS global,
            -- matching injectPapMember's producer key for the same values.
            case
                case LssInfer.kernelAliasOf g s of
                    Just ( kernelPrefix, home, name ) ->
                        standaloneArgKernelMember ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name ) canVar s

                    Nothing ->
                        standaloneArgMember ("g|" ++ TOpt.toComparableGlobal g) g canVar s
            of
                s1 ->
                    LssInfer.injectPapSuccessors g canVar s1

        TOpt.VarEnum _ g _ _ ->
            LssInfer.injectPapSuccessors g
                canVar
                (standaloneArgMember ("c|" ++ TOpt.toComparableGlobal g) g canVar s)

        TOpt.VarBox _ g _ ->
            LssInfer.injectPapSuccessors g
                canVar
                (standaloneArgMember ("c|" ++ TOpt.toComparableGlobal g) g canVar s)

        TOpt.VarCycle _ home name _ ->
            -- GAP-7 seam 2 (LSS_020 plan Phase E.2): a cycle member passed as
            -- a function argument transports its member like any global
            -- (mirrors the VarGlobal arm WITHOUT the kernel-alias fold —
            -- `kernelAliasOf` can never return Just for a cycle member:
            -- Link→Cycle→wildcard). The provisional `g|` id grounds at zonk
            -- per LSS_019, and lands HEAD-ONLY in lockstep with the inference
            -- side; `injectPapSuccessors` owns everything deeper.
            LssInfer.injectPapSuccessors (TOpt.Global home name)
                canVar
                (standaloneArgMember ("g|" ++ TOpt.toComparableGlobal (TOpt.Global home name)) (TOpt.Global home name) canVar s)

        TOpt.Accessor _ field _ ->
            -- L3 (plans/lss-coverage-four-levers.md §1.3): the
            -- inference side has minted `a|<field>` for accessor references
            -- since POST-001; the translate side silently no-op'd — the S.10
            -- lockstep asymmetry. Head-only (".field" is an arity-1 chomper).
            case Engine.memberIdFor ("a|" ++ field) (Engine.bumpArgFlowCensus "argArm|accessor" s) of
                ( mid, s1 ) ->
                    LssInfer.injectSpineMemberId 1 mid canVar s1

        TOpt.VarLocal name _ ->
            injectRetranslatingSelf name canVar s

        TOpt.TrackedVarLocal _ name _ ->
            injectRetranslatingSelf name canVar s

        TOpt.VarKernel _ kernelPrefix home name _ ->
            -- L3: a BARE kernel reference as a function argument (kernel shim
            -- modules) — the same k| identity the kernel-ALIAS VarGlobal arm
            -- mints, head-only per the kernelToSig rule.
            standaloneArgKernelMember ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name ) canVar (Engine.bumpArgFlowCensus "argArm|kernel" s)

        _ ->
            s


{-| S.10 (F-5C): the translation-side twin of `LssInfer`'s `g|`/`c|` mints.
The depth must match its LssInfer counterpart exactly — a member injected to
different depths on the two sides would name different arrow sets for the same
value.
-}
standaloneArgMember : String -> TOpt.Global -> Vars.Variable -> Engine.S -> Engine.S
standaloneArgMember key g canVar s =
    case Engine.standaloneMemberIdFor key g s of
        ( mid, s1 ) ->
            LssInfer.injectSpineMemberId 1 mid canVar s1


{-| Kernels stay HEAD-ONLY (see `LssInfer`'s kernel arms): `kernelToSig`
misaligns at inner arrows, and keeping `k|` members off them makes that
hazard unreachable.
-}
standaloneArgKernelMember : String -> ( Name, Name, Name ) -> Vars.Variable -> Engine.S -> Engine.S
standaloneArgKernelMember key k canVar s =
    case Engine.kernelMemberIdFor key k s of
        ( mid, s1 ) ->
            LssInfer.injectSpineMemberId 1 mid canVar s1


{-| `unifyResultWithExpected` followed by the PAP residual injection, in that
order, as one step — so the injection lands after the call's result has been
unified with the expected type (the residual Points are then the ones the
demand will be read from) and BEFORE `Store.zonkToMono funcVar`. Sequenced as
a composed step rather than another level of case-nesting purely for
readability; the ordering is the load-bearing part.
-}
unifyResultThenInjectPap : Vars.Variable -> Int -> Can.Type TypeIds.MVarId -> TOpt.Global -> Engine.S -> Engine.S
unifyResultThenInjectPap funcVar argCount callCanType global s0 =
    case unifyResultWithExpected funcVar argCount callCanType s0 of
        s1 ->
            injectPapMember global funcVar argCount s1


{-| INJECTION COMPLETENESS (plans/lss-injection-completeness.md §2.3): a
PARTIAL application of a known global is a PAP of that global, so the callee's
member is SOUND on the residual arrows — LSS\_013's arity bound licenses
exactly this ("a PAP of member m is m", design OQ4). Every residual arrow
within the declared arity holds a further partial application of the SAME
global, which is why the member is valid at depth `declared - supplied` and
not merely at the head.

This is the one producer form that injected nothing before: P0's
injection-totality census measured 3,624 such positions on the self-compile
(83 % at residual depth 1), and that hole is what let a one-sided branch join
publish `{identity}` as a COMPLETE set — the false singleton behind the
`arrowSolverRoots` miscompile. The paper has no such hole: L^src is
curry-free, so `(::) x` is necessarily a λ there and `𝒬` injects every λ.

**IDENTITY: a PAP gets its OWN member id, NEVER the callee's `g|`/`k|` one.**
This is the correction that made the first implementation of this function a
MISCOMPILE, and it is a fidelity point, not a workaround. `g|X` is registered
as `SourceGlobal X` (`Engine.standaloneMemberIdFor`), which puts it in the
STAMPABLE class: devirt reads it as "this value IS X" and rewrites the site to
a direct call of X's spec. A partial application is NOT X — it is X with `k`
arguments already bound — so that rewrite drops the captured arguments. The
observed failure was exactly this: `IO.traverseList (IO.traverseTuple f) args`
made devirt call `traverseTuple`'s 2-arity spec with one argument, and
monomorphization died on `demandUnify` with an arity mismatch.

The paper has no such conflation: L^src is curry-free, so `(::) x` is its own
λ with its OWN set element, distinct from `cons`'s. `p|<global>|<supplied>`
is that element. It is minted through `Engine.memberIdFor` WITHOUT a
`SourceGlobal`/`SourceKernel` registration (now `SourcePap`, whose
`memberClassOf` arm is an EXPLICIT `"l"`), so no DIRECT devirt arm can act on
it — while it still occupies
the set, which is the entire point: a one-sided join becomes an honest >=2 set
and the FALSE SINGLETON that motivated this plan cannot form.

The fence is on DIRECT rewrites only. LSS\_040 (plans/lss-pap-fast-stamp.md)
FAST-stamps a singleton `p|` site: the heap object is kept and the `supplied`
bound arguments are loaded back out of it exactly as captures are, so nothing
is reconstructed at the site and nothing is dropped.

**Depth is HEAD-ONLY, and that is also identity-driven.** At the residual head
the value is the PAP with `supplied` args bound; one arrow deeper it is a
DIFFERENT PAP (`supplied + 1` bound) and therefore a different element, which
`p|<global>|<supplied>` would misname. Injecting one id down a spine is what
`g|` may do (every residual of an unapplied global is still that global) and
what a PAP may not. Deeper residual arrows are left uninjected and COUNTED
(`papInject|deep`) — honest residue; 83 % of sites are depth 1 (P0 census), and
a per-arrow `p|<global>|<supplied+i>` walk is the clean generalization if the
residue justifies it.

No-ops when lss or the flag is off, when the call is saturated or
over-applied, or when the residual Point is opaque at that depth — an
uninjected position is exactly today's behaviour, so every fallback is sound.

-}
injectPapMember : TOpt.Global -> Vars.Variable -> Int -> Engine.S -> Engine.S
injectPapMember global funcVar argCount s0 =
    if not s0.env.lss.enabled then
        s0

    else
        let
            declared =
                LssInfer.declaredArityOf global 8 s0
        in
        if declared <= argCount then
            s0

        else
            case resultVarAfter funcVar argCount s0 of
                ( Nothing, s1 ) ->
                    -- Opaque at this depth (over-applied or not an arrow
                    -- spine): nothing to inject into. COUNTED, not silently
                    -- absorbed — this is the honest residue of the totality
                    -- claim, and a form census cannot see it.
                    Engine.bumpArgFlowCensus "papInject|opaque" s1

                ( Just residualVar, s1 ) ->
                    -- The injection-FIRED counters. The P0 form census counts
                    -- syntactic partial applications and cannot fall once they
                    -- start injecting; only the write site can answer "did the
                    -- member actually land". Gate: `papInject|pap` against the
                    -- form census's `papKnown`, with `opaque`/`deep` reported
                    -- as the residue.
                    let
                        residualDepth =
                            declared - argCount

                        s2 =
                            Engine.bumpArgFlowCensus "papInject|pap" s1

                        s3 =
                            if residualDepth > 1 && s2.env.lss.report then
                                Engine.bumpArgFlowCensus
                                    ("papInject|deep|d" ++ String.fromInt residualDepth)
                                    s2

                            else
                                s2
                    in
                    case Engine.papMemberIdFor global argCount s3 of
                        ( mid, s3a ) ->
                            -- L2 (plans/lss-coverage-four-levers.md §1.2):
                            -- finish the counted papInject|deep residue —
                            -- p|g|d for the depths past the residual head.
                            LssInfer.injectPapSuccessorsFrom global
                                (argCount + 1)
                                residualVar
                                (LssInfer.injectSpineMemberId 1 mid residualVar s3a)


{-| Registration self-identity (plans/lss-registration-self-identity.md §1.1):
the member id for depth d of global g's spine — the SAME ids every other
injection path mints, which is the whole soundness story:

  - depth 0 follows the E9.2 reference-path chooser exactly: kernel-alias fold
    to the k| kernel member (ONE identity — "a split g|/k| identity would join
    to a 2-set and kill singleton consumers"), Ctor/Enum/Box to c|, everything
    else (Define/TrackedDefine/Link/Cycle) to g|.
  - depth d > 0 is the p|<g>|<d> PAP member `papMembers` mints (LSS\_013: a PAP
    of member m IS m, at its own DISTINCT declining identity per depth).

`Nothing` = this global has no standalone identity here (raw kernels, managers,
ports) — the stamp skips the whole global and the census counts it.

-}
memberIdForDepth : TOpt.Global -> Int -> Maybe (() -> String) -> Step (Maybe Int)
memberIdForDepth g d groundKey s0 =
    if d > 0 then
        case Engine.papMemberIdFor g d s0 of
            ( mid, s1 ) ->
                ( Just mid, s1 )

    else
        case LssInfer.kernelAliasOf g s0 of
            Just ( kernelPrefix, home, name ) ->
                case Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name ) s0 of
                    ( mid, s1 ) ->
                        ( Just mid, s1 )

            Nothing ->
                case HashMap.get TOpt.globalHash (==) g s0.env.toptNodes of
                    Just (TOpt.Ctor _ _ _) ->
                        case Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g s0 of
                            ( mid, s1 ) ->
                                ( Just mid, s1 )

                    Just (TOpt.Enum _ _) ->
                        case Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g s0 of
                            ( mid, s1 ) ->
                                ( Just mid, s1 )

                    Just (TOpt.Box _) ->
                        case Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g s0 of
                            ( mid, s1 ) ->
                                ( Just mid, s1 )

                    Just (TOpt.Kernel _ _) ->
                        ( Nothing, s0 )

                    Just (TOpt.Manager _) ->
                        ( Nothing, s0 )

                    Just (TOpt.PortIncoming _ _ _) ->
                        ( Nothing, s0 )

                    Just (TOpt.PortOutgoing _ _ _) ->
                        ( Nothing, s0 )

                    Just _ ->
                        case groundKey of
                            Just groundKeyOf ->
                                -- Root-member fold §1.3: mint the GROUND id
                                -- directly — the same string the folded root
                                -- mint and LSS_019 reference grounding
                                -- produce, so all three converge on one id.
                                let
                                    -- Forced HERE, which is the only place it
                                    -- is read. See `stampSelfSpine`.
                                    ( mid, table1, next1 ) =
                                        Engine.groundStandaloneMemberIdFor g (groundKeyOf ()) s0.lssMemberTable s0.nextMemberId
                                in
                                ( Just mid, { s0 | lssMemberTable = table1, nextMemberId = next1 } )

                            Nothing ->
                                case Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g s0 of
                                    ( mid, s1 ) ->
                                        ( Just mid, s1 )

                    Nothing ->
                        ( Nothing, s0 )


{-| Registration self-identity: stamp the leading spine of a DEMAND for
global g with g's own tautological members, depths 0..declaredArity-1.

Stamps onto ⊤ and `LVar` only — NEVER over an existing `LSet` (AR-4: an
existing set is either the same id, making the join idempotent anyway, or a
defect signal that overwriting would hide). Applied to EVERY demand before it
reaches the registry, because the LSS\_010 join collapses LSet-vs-LVar to ⊤
(`Monomorphized.unionAnno`, AR-11) — a single unstamped demand would erase
the benefit for every caller of the spec.

Depth is bounded by `declaredArityOf`, not spine length: arrow
`declaredArity + 1` belongs to the RETURNED value (LSS\_013), which is body
dataflow this plan must not claim.

-}
stampSelfSpine : TOpt.Global -> Mono.MonoType -> Step Mono.MonoType
stampSelfSpine g monoType s0 =
    if not s0.env.lss.enabled then
        ( monoType, s0 )

    else
        let
            -- §1.3: the head's ground qualifier is the widened whole type —
            -- pure `Mono.widenSets`, string-equal to the spec's captured
            -- creation key (`widenSets` ⊤-widens every anno, so stamped and
            -- unstamped demands render identically).
            -- Step 11a: a THUNK. This is a full pure rebuild of the demand
            -- type followed by a multi-kilobyte string render, and it runs per
            -- global reference and per global call — about 141,000 times a
            -- run. It is READ in one arm only: a depth-0 Define, TrackedDefine,
            -- Link or Cycle head with a declared arity above zero on an arrow
            -- demand. Arity-0 globals, kernel aliases, constructors, enums,
            -- boxes, kernel, manager and port nodes, and every non-arrow
            -- demand never look at it. Deferring it does not change WHICH
            -- string is produced, only whether it is produced.
            groundKey =
                Just (\() -> Mono.toComparableMonoType (Mono.widenSets monoType))
        in
        stampSpineGo g groundKey (LssInfer.declaredArityOf g 8 s0) 0 monoType s0


stampSpineGo : TOpt.Global -> Maybe (() -> String) -> Int -> Int -> Mono.MonoType -> Step Mono.MonoType
stampSpineGo g groundKey arity d monoType s0 =
    if d >= arity then
        ( monoType, s0 )

    else
        case monoType of
            Mono.MFunction _ anno args ret ->
                case
                    memberIdForDepth g
                        d
                        (if d == 0 then
                            groundKey

                         else
                            Nothing
                        )
                        s0
                of
                    ( Nothing, s1 ) ->
                        ( monoType, Engine.bumpArgFlowCensus "regid|noId" s1 )

                    ( Just mid, s1 ) ->
                        let
                            ( anno2, s2 ) =
                                case anno of
                                    Mono.LSet _ ->
                                        ( anno, Engine.bumpArgFlowCensus "regid|alreadySet" s1 )

                                    _ ->
                                        ( Mono.LSet [ mid ], Engine.bumpArgFlowCensus "regid|stamped" s1 )
                        in
                        case stampSpineGo g groundKey arity (d + 1) ret s2 of
                            ( ret2, s3 ) ->
                                ( Mono.mFunction anno2 args ret2, s3 )

            _ ->
                ( monoType, s0 )


{-| `Engine.enqueueSpec` with the registration self-identity stamp applied
first, so the keyed path's key, the LSS\_010 join, and the stored type all see
the same stamped demand.
-}
enqueueSpecStamped : TOpt.Global -> Mono.MonoType -> Engine.S -> ( Mono.SpecId, Engine.S )
enqueueSpecStamped global monoType s0 =
    -- Step 10c: `stampSelfSpine` never fails (its only callees are Engine
    -- mints, and Engine raises nothing but the enqueue watchdog, which is now
    -- `pendingFailure`), so its `Err` arm was dead.
    case stampSelfSpine global monoType s0 of
        ( stamped, s1 ) ->
            case Engine.enqueueSpec (toptToMonoGlobal global) stamped s1 of
                ( specId, s2 ) ->
                    ( specId, s2 )


{-| The `enrich|bare` / `enrich|withSets` census row (P0.a,
plans/lss-ctor-arrow-identity.md §8.1): does the varEnv type this transport
carries actually HAVE members? `monoTypeToVar` encodes nested annotations
faithfully, so a bare bound type is the laundering suspect.

Hoisted to a helper by step 9 so that the arm which SKIPS the transport still
counts the same row — the skip must not change report output. Off report it is
one Bool read.

-}
enrichCensusRow : Mono.MonoType -> Engine.S -> Engine.S
enrichCensusRow boundType s =
    if not s.env.lss.report then
        s

    else if List.isEmpty (Mono.collectAnnoMembers boundType) then
        Engine.bumpArgFlowCensus "enrich|bare" s

    else
        Engine.bumpArgFlowCensus "enrich|withSets" s


{-| Best-effort unify `canVar` with environment-derived structure for `arg`.
-}
enrichFromEnv : TOpt.Expr TypeIds.MVarId -> Vars.Variable -> Engine.S -> Engine.S
enrichFromEnv arg canVar s0 =
    case accessedLocalName arg of
        Just localName ->
            -- Never enrich from a local-multi target: its varEnv entry is only
            -- the DECLARED classify (possibly a closed-narrow row type), and
            -- forcing it here would block the full type flowing from the other
            -- call args. Its typing is owned by the instance-recording path.
            -- M6/A1: direct state-passing over explicit trailing S → byte-identical.
            case Engine.isLocalMultiTarget localName s0 of
                ( isLM, s1 ) ->
                    if isLM then
                        Engine.bumpArgFlowCensus "enrich|localMulti" s1

                    else
                        case Engine.lookupVar localName s1 of
                            ( maybeBound, s2 ) ->
                                case maybeBound of
                                    Just boundType ->
                                        -- Step 9: a ground, arrow-free USE type has
                                        -- nothing to receive — no memo var to
                                        -- concretise and no set slot to carry members
                                        -- into. Re-encoding `boundType` (hundreds of
                                        -- Points for `s : S`) and unifying it into an
                                        -- unreferenced structure is a no-op. The census
                                        -- row is still counted, so report output is
                                        -- unchanged.
                                        if Store.groundNoArrowWith s2.monoMemo.aliasMemo (TOpt.typeOf arg) then
                                            enrichCensusRow boundType s2

                                        else
                                            case Store.monoTypeToVarS boundType s2 of
                                                ( boundVar, s3 ) ->
                                                    -- P0.a (plans/lss-ctor-arrow-identity.md
                                                    -- §8.1): does the varEnv type this
                                                    -- transport actually CARRY members?
                                                    -- `monoTypeToVar` encodes nested
                                                    -- annotations faithfully, so a bare
                                                    -- bound type is the laundering
                                                    -- suspect (leak|letAnno's downstream
                                                    -- consequence). Report-gated walk.
                                                    unifyStepBestEffort canVar boundVar (enrichCensusRow boundType s3)

                                    Nothing ->
                                        Engine.bumpArgFlowCensus "enrich|unbound" s2

        Nothing ->
            case arg of
                TOpt.Tuple _ a b rest _ ->
                    -- Step 9: a ground tuple has ground elements, so every leaf
                    -- below would skip anyway. Skipping here saves the `UF.get`
                    -- and the three recursions at once.
                    if Store.groundNoArrowWith s0.monoMemo.aliasMemo (TOpt.typeOf arg) then
                        s0

                    else
                        -- M6/A1: direct state-passing over explicit trailing S → byte-identical.
                        case Engine.liftIO (UF.get canVar) s0 of
                            ( desc, s1 ) ->
                                case desc.content of
                                    Vars.Structure (Vars.Tuple1 pa pb pRest) ->
                                        case enrichFromEnv a pa s1 of
                                            s2 ->
                                                case enrichFromEnv b pb s2 of
                                                    s3 ->
                                                        List.foldl
                                                            (\( e, pt ) sAcc -> enrichFromEnv e pt sAcc)
                                                            s3
                                                            (List.map2 Tuple.pair rest pRest)

                                    _ ->
                                        s1

                TOpt.Access record _ fieldName _ ->
                    -- E15 (plans/lss-container-payload-transport.md §12.10.1):
                    -- a `r.f` ARGUMENT or CALLEE used to enrich nothing — the
                    -- record's bound type knows the field's set, so project it
                    -- (the `VarLocal` arm one projection deeper). Shipped as
                    -- `lss.flow.accessFlow`, DEFAULT-ON 2026-09-16
                    -- (`enrich|access|ofLocal` 5,785 joins), unconditional
                    -- 2026-09-18.
                    case accessedLocalName record of
                        Just rname ->
                            if not s0.env.lss.enabled then
                                s0

                            else
                                case Engine.isLocalMultiTarget rname s0 of
                                    ( isLM, s1 ) ->
                                        if isLM then
                                            Engine.bumpArgFlowCensus "enrich|access|localMulti" s1

                                        else
                                            case Engine.lookupVar rname s1 of
                                                ( Just (Mono.MRecord _ fields), s2 ) ->
                                                    case Dict.get fieldName fields of
                                                        Just fieldType ->
                                                            -- Step 9: same argument as the local
                                                            -- arm — a ground use type has nothing
                                                            -- to receive. The census row is still
                                                            -- counted.
                                                            if Store.groundNoArrowWith s2.monoMemo.aliasMemo (TOpt.typeOf arg) then
                                                                Engine.bumpArgFlowCensus "enrich|access|ofLocal" s2

                                                            else
                                                                case Store.monoTypeToVarS fieldType s2 of
                                                                    ( fieldVar, s3 ) ->
                                                                        unifyStepBestEffort canVar fieldVar (Engine.bumpArgFlowCensus "enrich|access|ofLocal" s3)

                                                        Nothing ->
                                                            Engine.bumpArgFlowCensus "enrich|access|noField" s2

                                                ( _, s2 ) ->
                                                    Engine.bumpArgFlowCensus "enrich|access|noRecord" s2

                        Nothing ->
                            s0

                _ ->
                    s0


{-| Kernel ABI for a STANDALONE reference (`eq = Utils.equal`): load the type
through the ITEM memo so the item's demand concretization (unified against the
enclosing definition's annotation) is visible — a fresh instantiation would
isolate the vars and lose it.
-}
deriveKernelAbiTypeRef : ( String, String ) -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
deriveKernelAbiTypeRef kernelId canFuncType =
    deriveKernelAbiTypeWith kernelId canFuncType (Store.loadTypeS canFuncType)


deriveKernelAbiTypeWith : ( String, String ) -> Can.Type TypeIds.MVarId -> Step Vars.Variable -> Step Mono.MonoType
deriveKernelAbiTypeWith kernelId canFuncType funcVarStep s0 =
    case funcVarStep s0 of
        ( funcVar0, sA ) ->
            case poisonKernelArrowsThen kernelId canFuncType funcVar0 sA of
                ( funcVar, sB ) ->
                    case Store.zonkToMono funcVar sB of
                        ( monoAfterSubst, sC ) ->
                            case currentMVarEnv sC of
                                ( mvarEnv, sD ) ->
                                    case KernelAbi.deriveKernelAbiMode kernelId canFuncType of
                                        KernelAbi.UseSubstitution ->
                                            ( monoAfterSubst, sD )

                                        KernelAbi.PreserveVars ->
                                            if
                                                EverySet.member KernelAbi.comparePair kernelId KernelAbi.suffixSelectingKernels
                                                    && not (Mono.containsAnyMVar monoAfterSubst)
                                            then
                                                ( monoAfterSubst, sD )

                                            else if EverySet.member KernelAbi.comparePair kernelId KernelAbi.suffixSelectingKernels then
                                                -- Suffix-selecting kernel with residual vars in the
                                                -- store truth: use the STORE-TRUTH zonk (not a canType
                                                -- re-derivation), remapping its CEcoValue residuals to
                                                -- fresh, taint-proof engine ids (ConsNumberTaintTest,
                                                -- the Stage-7a bootstrap SIGSEGV):
                                                --
                                                --   * A structurally CONCRETE param whose FIELDS carry
                                                --     erased residuals (e.g. a `(Name, MonoExpr, Bool)`
                                                --     cons element zonking `T(eco,MonoExpr,eco)`) fails
                                                --     the whole-type `containsAnyMVar` gate above, but
                                                --     its top-level shape — all the suffix selection
                                                --     reads — is exact. The former canType re-derivation
                                                --     DISCARDED that shape for the kernel scheme's
                                                --     annotation var (e.g. `List.cons`'s `a`), whose id
                                                --     is SHARED by every use of the kernel in the whole
                                                --     program.
                                                --
                                                --   * A shared annotation id can be Number-stamped by a
                                                --     FOREIGN item (`harvestSuperTable` covers only the
                                                --     finishing item's own annIds, not callee-scheme
                                                --     vars left at `FlexSuper Number` — e.g. an
                                                --     unresolved-number `1 :: 2 :: []`). Prune then
                                                --     closes `MVar a CEcoValue -> MInt` behind this
                                                --     spec's back and the kernel selects `_Int` over a
                                                --     BOXED element — `eco.unbox` of a heap pointer.
                                                --
                                                -- Store-truth params align the ABI with the spec's own
                                                -- body/param types (same zonk source); the fresh eco
                                                -- ids make genuinely-erased elements immune to foreign
                                                -- stamps (they stay boxed, matching the subst engine).
                                                -- CNumber residuals keep their unconditional
                                                -- close-to-MInt — the intended same-item taint.
                                                let
                                                    ( abi2, nextId2 ) =
                                                        remapEcoVarsFresh sD.nextMVarId monoAfterSubst
                                                in
                                                ( abi2, { sD | nextMVarId = nextId2 } )

                                            else
                                                -- The preserved-vars ABI keeps the canType's var ids,
                                                -- which THIS item's demand unification may have Join-R
                                                -- number-tainted (e.g. `Decode.null 0` keys the spec at
                                                -- CNumber and demandUnify taints the annotation vars) —
                                                -- Prune would then close the honest eco ABI to MInt and
                                                -- pass an unboxed i64 to a kernel expecting a boxed
                                                -- value. The erased vars are layout placeholders, so
                                                -- REMAP them to fresh, taint-proof engine ids (one per
                                                -- distinct source id, preserving sharing) and advance
                                                -- the id counter past everything minted.
                                                let
                                                    ( abiType, env1 ) =
                                                        KernelAbi.canTypeToMonoType_preserveVars mvarEnv canFuncType

                                                    -- Debug WANTS the taint (it closes to Int like
                                                    -- the original refreshConstraints); only
                                                    -- genuinely-generic kernels get taint-proof
                                                    -- fresh ids. (Suffix-selecting kernels take the
                                                    -- store-truth branch above and never reach
                                                    -- here.)
                                                    remapWanted =
                                                        Tuple.first kernelId /= "Debug"

                                                    ( finalAbi, nextId2 ) =
                                                        if remapWanted then
                                                            remapEcoVarsFresh env1.nextId abiType

                                                        else
                                                            ( abiType, env1.nextId )
                                                in
                                                ( finalAbi, { sD | nextMVarId = nextId2 } )


{-| LSS\_004, refined by LSS\_021 and LSS\_022 (KernelSetFacts): a ROWLESS
kernel poisons its whole loaded scheme's set slots (today's behavior); a
`TypeFaithful` (LICENSED) kernel poisons NOTHING and passes the loaded scheme
straight through; a `Positional` kernel poisons per-param — `PSFApplies`
positions keep their slots (the caller's knowledge survives the boundary; the
kernel only calls the value), `PSFTunnels` positions set-slot-join the
result, everything else poisons. Both sides of the boundary consult ONE table
(`KernelSetFacts` — the LSS\_006-style two-sided discipline; the inference
twin is `LssInfer.kernelCallBoundary`).

The licensed pass-through is load-bearing precisely BECAUSE of the ordering
note below: the arg unification has already run, so the unpoisoned shared
slots carry the caller's real per-site member knowledge into the zonk. That
is where the license's precision actually lands.

Ordering note (corrected 2026-08-20, was stale): on the CALL path this runs
AFTER `unifyParamsWithArgExprs` — `Engine.andThen f step` runs `step` first,
and `deriveKernelAbiTypeCall`'s step already contains the arg unification —
so an opaque position's poison deliberately reaches the arg-shared item-memo
Points, and a skipped position is simply never poisoned (the skip needs no
ordering assumption). It still runs before the zonk that reads the slots.
No-op when lss is off.

-}
poisonKernelArrowsThen : ( String, String ) -> Can.Type TypeIds.MVarId -> Vars.Variable -> Step Vars.Variable
poisonKernelArrowsThen ( kHome, kName ) canFuncType funcVar s0 =
    let
        -- CENSUS (report-gated, so the default path carries only the flag
        -- test): which LICENSED kernels had their occurrence verification
        -- REFUSED? That is precisely the population an intrinsic annotation
        -- would pay for — see plans/kernel-intrinsic-annotations.md. Kept
        -- rather than deleted after its first run because it is the targeting
        -- instrument for every future row: without it, "annotate the rest"
        -- means annotating blind, and annotations are fail-stop.
        s =
            if s0.env.lss.report then
                recordRefusedLicense ( kHome, kName ) canFuncType s0

            else
                s0
    in
    if s.env.lss.enabled then
        case KernelSetFacts.factFor kHome kName of
            Nothing ->
                case Store.poisonArrowSets funcVar s of
                    s1 ->
                        ( funcVar, Engine.bumpWidenedByKernel s1 )

            Just (KernelSetFacts.TypeFaithful license) ->
                if not (KernelSetFacts.licenseApplies (Engine.isScalarVar s) license canFuncType) then
                    -- LSS_022 occurrence verification. This side is where the
                    -- check EARNS its cost: the arg unification has already
                    -- run (see the ordering note), so a wrongly-applied
                    -- license would leave the caller's real members standing
                    -- in a slot the kernel may not honour — the
                    -- populated-but-incomplete hazard, i.e. a false singleton.
                    -- Skipping verification here would make the whole tier
                    -- rest on the Elm annotation never drifting, which the rot
                    -- manifest cannot see. Fail SAFE to full poison.
                    case Store.poisonArrowSets funcVar s of
                        s1 ->
                            ( funcVar, Engine.bumpWidenedByKernel s1 )

                else
                    -- Licensed — pass-through. No spine descent, so no
                    -- arity/shape precondition either: whatever the scheme's
                    -- shape, leaving every slot alone is exactly "the type IS
                    -- the flow graph". Unlike the inference twin this arm
                    -- needs no `scope` split — doing nothing is already the
                    -- whole implementation, and for an `Inert` row there are
                    -- no set slots for it to have done anything to.
                    ( funcVar, Engine.bumpKernelLicensed s )

            Just (KernelSetFacts.Positional plan) ->
                case poisonKernelPerParam plan.params [] funcVar False s of
                    ( maybeOutcome, s1 ) ->
                        case maybeOutcome of
                            Nothing ->
                                -- The spine ended before the row's params ran
                                -- out (partial/reshaped scheme, or an Alias
                                -- head — `arrowParts` does not chase them,
                                -- matching `unifyParamsCollect`): structural
                                -- arity mismatch ⇒ LSS_004 full poison.
                                case Store.poisonArrowSets funcVar s1 of
                                    s2 ->
                                        ( funcVar, Engine.bumpWidenedByKernel s2 )

                            Just ( resVar, tunnelVars, argPoisoned ) ->
                                let
                                    resultStep =
                                        case plan.result of
                                            KernelSetFacts.PSFOpaque ->
                                                case Store.poisonArrowSets resVar s1 of
                                                    s2 ->
                                                        ( True, s2 )

                                            _ ->
                                                ( False, s1 )
                                in
                                case resultStep of
                                    ( resPoisoned, s2 ) ->
                                        case joinKernelTunnels resVar tunnelVars s2 of
                                            s3 ->
                                                ( funcVar
                                                , Engine.bumpKernelFactHit
                                                    (if argPoisoned || resPoisoned then
                                                        Engine.bumpWidenedByKernel s3

                                                     else
                                                        s3
                                                    )
                                                )

    else
        ( funcVar, s )


{-| Descend the kernel scheme's arrow spine one arrow per declared param,
applying the row's per-position policy. Returns `Nothing` on an early spine
end (the caller falls back to full poison). No Alias chase — matches the
`unifyParamsCollect` precedent (mono stores are alias-expanded at load).
-}
poisonKernelPerParam : List KernelSetFacts.ParamSetFlow -> List Vars.Variable -> Vars.Variable -> Bool -> Step (Maybe ( Vars.Variable, List Vars.Variable, Bool ))
poisonKernelPerParam flows tunnelsRev v poisoned s0 =
    case flows of
        [] ->
            ( Just ( v, List.reverse tunnelsRev, poisoned ), s0 )

        flow :: rest ->
            case Engine.liftIO (UF.get v) s0 of
                ( desc, s1 ) ->
                    case Store.arrowParts desc.content of
                        Nothing ->
                            ( Nothing, s1 )

                        Just ( pParam, pRest ) ->
                            case flow of
                                KernelSetFacts.PSFOpaque ->
                                    case Store.poisonArrowSets pParam s1 of
                                        s2 ->
                                            poisonKernelPerParam rest tunnelsRev pRest True s2

                                KernelSetFacts.PSFApplies ->
                                    poisonKernelPerParam rest tunnelsRev pRest poisoned s1


joinKernelTunnels : Vars.Variable -> List Vars.Variable -> Engine.S -> Engine.S
joinKernelTunnels resVar vars s0 =
    case vars of
        [] ->
            s0

        v :: rest ->
            -- LSS_023 — the translation twin of LssInfer's `joinTunnels`;
            -- see the comment there. Also a `lss.sigFlow` selector until that
            -- flag was fixed at its default and removed 2026-09-18.
            case LssInfer.flowArrowSetsPlain v resVar s0 of
                s1 ->
                    joinKernelTunnels resVar rest s1


{-| Load a type with a fresh, isolated memo so its vars do not share Points with
the surrounding item (a fresh scheme instantiation). The minted Points persist
in the store; the item memo is restored afterward.
-}
instantiate : Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
instantiate canType =
    -- D8: one S-write instead of three (see Store.loadTypeIsolated).
    Store.loadTypeIsolated canType


{-| `instantiate` with the callee's LSS signature facts applied to the fresh
instantiation's arrow slots (design §8.4). lss-off = exactly `instantiate`.
`funcCanType` is already annotation-sourced by `translateCall` (LSS\_006's
other half — the signature side enumerates the same source).
-}
instantiateLss : TOpt.Global -> Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
instantiateLss global funcCanType s =
    if s.env.lss.enabled then
        LssInfer.instantiateWithSignature global funcCanType s

    else
        instantiate funcCanType s


{-| Unify but never abort: on failure the store is restored to its pre-unify
state. For polymorphic-call result/param unification where a higher-order arg's
curried shape needn't line up (the residual then boxes to CEcoValue, matching
the erased ABI).

Only the store goes back on failure, as in `Store.unifyBestEffortStoreS`.

-}
unifyBestEffortS : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyBestEffortS v1 v2 s =
    case Store.unifyStep v1 v2 s of
        ( True, s1 ) ->
            s1

        ( False, s1 ) ->
            { s1 | store = s.store }


unifyStepBestEffort : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyStepBestEffort v1 v2 s =
    unifyBestEffortS v1 v2 s


canKind : Can.Type TypeIds.MVarId -> String
canKind canType =
    case canType of
        Can.TVar _ ->
            "var"

        Can.TLambda _ a b ->
            "(" ++ canKind a ++ "->" ++ canKind b ++ ")"

        Can.TType _ name args ->
            name
                ++ (if List.isEmpty args then
                        ""

                    else
                        "<" ++ String.join "," (List.map canKind args) ++ ">"
                   )

        Can.TRecord _ _ ->
            "record"

        Can.TUnit ->
            "unit"

        Can.TTuple _ _ _ ->
            "tuple"

        Can.TAlias _ name _ _ ->
            "alias:" ++ name


{-| Unify the callee's result (after peeling `argCount` parameters) with the
expected call type — the "WithExpected" part of the original poly call path,
needed for return-polymorphic callees.
-}
unifyResultWithExpected : Vars.Variable -> Int -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
unifyResultWithExpected funcVar argCount callCanType s0 =
    case resultVarAfter funcVar argCount s0 of
        ( Just resultVar, s1 ) ->
            case Store.loadTypeS callCanType s1 of
                ( expectedVar, s2 ) ->
                    unifyStepBestEffort resultVar expectedVar s2

        ( Nothing, s1 ) ->
            s1


resultVarAfter : Vars.Variable -> Int -> Engine.S -> ( Maybe Vars.Variable, Engine.S )
resultVarAfter funcVar n s0 =
    if n <= 0 then
        ( Just funcVar, s0 )

    else
        case Engine.liftIO (UF.get funcVar) s0 of
            ( desc, s1 ) ->
                case Store.arrowParts desc.content of
                    Just ( _, pRest ) ->
                        -- Liveness census: peeling to find the result of an
                        -- n-argument application is an APPLICATION of this
                        -- arrow (plans/lss-provenance-ratio-census.md §7).
                        resultVarAfter pRest (n - 1) (noteAppliedS desc.content s1)

                    Nothing ->
                        ( Nothing, s1 )


{-| Liveness census (plans/lss-provenance-ratio-census.md §7) — the `Step`-typed
twin of `LssInfer.noteApplied`, for the Translate-side application paths.

`LssInfer`'s copy hooks `localCalleeJoin`, which turned out to serve exactly ONE
call shape (a letEnv-bound local callee); measured alone it saw only 10.76 % of
concrete arrows, which is why the control ratio exists and why it is read before
the finding. The general paths are here.

The `ArrowId` lookup goes through the union-find CLASS for `noteMultiSet`'s
reason: the surviving slot after a unification is often not the minted one, and
only the loaded side carries an ArrowId.

-}
noteAppliedS : Vars.Content -> Engine.S -> Engine.S
noteAppliedS =
    LssInfer.noteApplied


{-| Build an `MVarEnv` for the KernelAbi helpers (which read super info; they
never mutate it here). Uses the engine's current allocator + super table.
-}
currentMVarEnv : Step State.MVarEnv
currentMVarEnv =
    -- STATIC supers only: the kernel-ABI preserveVars computation must not see
    -- cross-item Join-R taint (a call like `Decode.null 0` elsewhere would stamp
    -- the kernel's `a` as CNumber → Prune closes it to MInt → unboxed i64 passed
    -- to a kernel expecting a boxed value). Same principle as Store.loadVar.
    \s -> ( State.initMVarEnv s.nextMVarId s.env.superStatic, s )



-- ====== RECORDS ======


recordTypeFromFields : List ( Name, Mono.MonoExpr ) -> Mono.MonoType
recordTypeFromFields fields =
    Mono.mRecord (List.foldl (\( name, me ) acc -> Dict.insert name (Mono.typeOf me) acc) Dict.empty fields)


{-| Prefer the record's own field type when it is more concrete than the
access node's classified type (mirrors the original `isMoreConcrete` guard,
approximated: use the field type only when the classified type still has a var).
-}
refineAccessType : Bool -> Mono.MonoType -> Mono.MonoType -> Name -> Mono.MonoType
refineAccessType overlay classified recordType fieldName =
    case recordType of
        Mono.MRecord _ fields ->
            case Dict.get fieldName fields of
                Just fieldType ->
                    if Mono.containsAnyMVar classified then
                        fieldType

                    else if recordKeySubset classified fieldType then
                        -- The classified type is a NARROWED (row-poly, closed at
                        -- zonk) view of the record's actual field: the record side
                        -- is authoritative for layout (field indices).
                        fieldType

                    else if overlay && Mono.eqLayout classified fieldType then
                        -- E15 / F4-acc-node: the classify's STRUCTURE with the
                        -- record's ANNOTATIONS — never worse than the storeless
                        -- `clsMisc` ⊤ this used to keep.
                        Mono.overlayAnnotations classified fieldType

                    else
                        classified

                Nothing ->
                    classified

        _ ->
            classified


{-| Do the two types have the SAME shape, differing only at numeric leaves
(MInt vs MFloat)? The signature of shared-number-var memo pollution.
-}
numericLeafOnlyDiff : Mono.MonoType -> Mono.MonoType -> Bool
numericLeafOnlyDiff a b =
    -- `eqModuloTopLabel`, not `==` (Phase 1a): `a` is a storeless `classify`
    -- result, whose arrows are all `LTop` by design (§3.2), and `b` is
    -- store-zonked, so `b` carries `LVar` wherever an arrow was never
    -- written. A plain `==` reports those two as DIFFERENT and then
    -- `sameShapeModuloNumeric` — which ignores annotations entirely — answers
    -- True, flipping `useBodyType` at 14 `Let`s on the self-compile. Byte
    -- neutral there (the labels are one key point), but a real behaviour drift
    -- at a def-type SELECTION site, and Phase 1a is a pure relabel.
    if Mono.eqModuloTopLabel a b then
        False

    else
        sameShapeModuloNumeric a b


sameShapeModuloNumeric : Mono.MonoType -> Mono.MonoType -> Bool
sameShapeModuloNumeric a b =
    case ( a, b ) of
        ( Mono.MInt, Mono.MFloat ) ->
            True

        ( Mono.MFloat, Mono.MInt ) ->
            True

        ( Mono.MVar _ Mono.CNumber, Mono.MInt ) ->
            True

        ( Mono.MVar _ Mono.CNumber, Mono.MFloat ) ->
            True

        ( Mono.MInt, Mono.MVar _ Mono.CNumber ) ->
            True

        ( Mono.MFloat, Mono.MVar _ Mono.CNumber ) ->
            True

        ( Mono.MFunction _ _ args1 r1, Mono.MFunction _ _ args2 r2 ) ->
            allPairs sameShapeModuloNumeric args1 args2 && sameShapeModuloNumeric r1 r2

        ( Mono.MList _ e1, Mono.MList _ e2 ) ->
            sameShapeModuloNumeric e1 e2

        ( Mono.MTuple _ es1, Mono.MTuple _ es2 ) ->
            allPairs sameShapeModuloNumeric es1 es2

        ( Mono.MCustom _ h1 n1 args1, Mono.MCustom _ h2 n2 args2 ) ->
            h1 == h2 && n1 == n2 && allPairs sameShapeModuloNumeric args1 args2

        ( Mono.MRecord _ f1, Mono.MRecord _ f2 ) ->
            (Dict.size f1 == Dict.size f2)
                && Dict.foldl
                    (\name t1 ok ->
                        ok
                            && (case Dict.get name f2 of
                                    Just t2 ->
                                        sameShapeModuloNumeric t1 t2

                                    Nothing ->
                                        False
                               )
                    )
                    True
                    f1

        _ ->
            a == b


{-| Pairwise `&&` over two lists, `False` when their lengths differ.

Replaces `List.length xs == List.length ys && List.all identity (List.map2 f xs ys)`,
which measured both lists, allocated a `List Bool` at full length, and — the
part that actually cost — evaluated the recursive `f` for every pair even after
the first mismatch. The length check cannot just be dropped from that form,
because `List.map2` truncates silently; matching the two spines together
subsumes it.

-}
allPairs : (a -> b -> Bool) -> List a -> List b -> Bool
allPairs f xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            f x y && allPairs f restX restY

        _ ->
            False


{-| Is `narrow` a record whose keys are a STRICT subset of record `full`'s keys?
(The signature of row-polymorphic narrowing.)
-}
recordKeySubset : Mono.MonoType -> Mono.MonoType -> Bool
recordKeySubset narrow full =
    case ( narrow, full ) of
        ( Mono.MRecord _ nf, Mono.MRecord _ ff ) ->
            Dict.size nf < Dict.size ff && List.all (\k -> Dict.member k ff) (Dict.keys nf)

        _ ->
            False


translateUpdate : TOpt.Expr TypeIds.MVarId -> DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateUpdate record updates canType s0 =
    -- M6: direct state-passing (desugared andThen/map) → byte-identical.
    case classifyAs Mono.tkClassLet canType s0 of
        ( monoType, s1 ) ->
            case translate record s1 of
                ( monoRecord, s2 ) ->
                    case
                        Engine.foldlS
                            (\( locName, updateExpr ) acc sx ->
                                case translate updateExpr sx of
                                    ( me, sx1 ) ->
                                        ( ( A.toValue locName, me ) :: acc, sx1 )
                            )
                            []
                            (DMap.toList updates)
                            s2
                    of
                        ( monoUpdatesRev, s3 ) ->
                            let
                                recordMonoType =
                                    Mono.typeOf monoRecord

                                resultMonoType =
                                    unionRecordTypes monoType recordMonoType
                            in
                            ( Mono.MonoRecordUpdate monoRecord monoUpdatesRev resultMonoType, s3 )


{-| `Mono.mRecord (Dict.union resultFields recordFields)` from the two record types,
matching the original Update result-type computation.
-}
unionRecordTypes : Mono.MonoType -> Mono.MonoType -> Mono.MonoType
unionRecordTypes classified recordType =
    case ( classified, recordType ) of
        ( Mono.MRecord _ resultFields, Mono.MRecord _ recordFields ) ->
            Mono.mRecord (Dict.union resultFields recordFields)

        ( Mono.MRecord _ _, _ ) ->
            classified

        _ ->
            classified



-- ====== LET ======


translateLet : TOpt.Def TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLet def body letCanType sTop =
    case def of
        TOpt.Def _ name defBody defCanType ->
            if isFunctionType defCanType || (typeContainsCanLambda defCanType && KernelAbi.hasAnyFreeVar defCanType) then
                -- Function-typed lets AND lambda-CONTAINING lets with unresolved
                -- vars (a list/record of closures — the original engine's
                -- value-multi gate `typeContainsLambda && hasVar`) route through
                -- body-first discovery + per-instance re-translation, so a use at
                -- a concrete type re-specializes the closures inside.
                translateLocalMultiLet name defBody body letCanType sTop

            else
                -- M6: direct state-passing (desugared andThen; plain-let path is the
                -- common case). The number-multi/local-multi sub-paths keep their own
                -- shapes. Monad-law-preserving → byte-identical.
                case isNumberMultiEligible defCanType sTop of
                    ( eligible, s1 ) ->
                        if eligible then
                            translateNumberMultiLet name defBody body letCanType s1

                        else
                            -- Plain non-function, non-number value let.
                            case translate defBody s1 of
                                ( monoDefBody, s2 ) ->
                                    case classifyAs Mono.tkClassLet defCanType s2 of
                                        ( defMonoType0, s3 ) ->
                                            let
                                                bodyType =
                                                    Mono.typeOf monoDefBody

                                                useBodyType =
                                                    Mono.containsAnyMVar defMonoType0
                                                        -- A closed-narrow (row-poly) classified type defers
                                                        -- to the body's actual/full record type (layout).
                                                        || recordKeySubset defMonoType0 bodyType
                                                        -- Same shape differing ONLY in numeric leaves:
                                                        -- the classify carries Float pollution from a
                                                        -- sibling use of a shared number var; the body IS
                                                        -- the value (LetNumberIndirectDual).
                                                        || (not (monoTypeMentionsEco bodyType) && numericLeafOnlyDiff defMonoType0 bodyType)

                                                -- F3-b (`lss.flow.letOverlay`,
                                                -- DEFAULT-ON 2026-09-16,
                                                -- unconditional 2026-09-18):
                                                -- `leak|letAnno` 58 -> 0,
                                                -- ⊤ 698 -> 668, `var` +30 —
                                                -- a ⊤-manufacturer removal.
                                                letOverlay =
                                                    s3.env.lss.enabled

                                                defType =
                                                    if useBodyType then
                                                        bodyType

                                                    else if letOverlay then
                                                        -- F3-b (plans/lss-container-payload-transport.md
                                                        -- §12.9.5): the classify's STRUCTURE (the ABI
                                                        -- guard) with the translated RHS's ANNOTATIONS —
                                                        -- the top-level `TailDef` precedent. Closes the
                                                        -- `leak|letAnno` class below.
                                                        Mono.overlayAnnotations defMonoType0 bodyType

                                                    else
                                                        defMonoType0

                                                -- LSS_026 census (plan §2.1 row 5): the annotation-DROP leak.
                                                -- When the classify wins over an arrow-bearing RHS, any set
                                                -- annotations on `bodyType` never reach the varEnv, so
                                                -- `enrichFromEnv` later enriches uses of this local from an
                                                -- annotation-free type. Report-gated; cheap check first.
                                                s3b =
                                                    if not s3.env.lss.report || useBodyType || letOverlay || not (canTypeHasArrow defCanType) then
                                                        s3

                                                    else
                                                        Engine.bumpArgFlowCensus "leak|letAnno" s3
                                            in
                                            Engine.scoped
                                                (\sx -> finishLet (Mono.MonoDef name monoDefBody) body letCanType (Engine.insertVar name defType sx))
                                                s3b

        TOpt.TailDef _ name typedArgs tailBody defCanType _ ->
            -- Local tail-recursive function: BODY-FIRST discovery (uses record the
            -- applied type via the local-multi stack), then — for the single-instance
            -- case — demand-unify the def's type with the recorded instance IN the
            -- item store and translate the def ONCE under the bare name (the
            -- TailCall self-reference needs no renaming). Multi-instance falls back
            -- to the declared type (rare; would need renamed self-calls).
            case classifyAs Mono.tkClassLet defCanType (Engine.pushLocalMulti Nothing Nothing name sTop) of
                ( declType, s1 ) ->
                    case Engine.scoped (\sx -> translate body (Engine.insertVar name declType sx)) s1 of
                        ( monoBody0, s2 ) ->
                            -- E4a deferral: let-functions nested in this body owe their
                            -- use-site overlay to the outermost let-function; a tail def
                            -- pushes the same stack, so it must flush (or pass up) too.
                            case Engine.popLocalMulti s2 of
                                ( maybeEntry, s3 ) ->
                                    case flushLocalMultiEnrich name maybeEntry [] monoBody0 s3 of
                                        ( monoBody, s4 ) ->
                                            let
                                                singleInstance =
                                                    case maybeEntry of
                                                        Just entry ->
                                                            case Mono.specMapValues entry.instances of
                                                                [ inst ] ->
                                                                    Just inst.monoType

                                                                _ ->
                                                                    Nothing

                                                        Nothing ->
                                                            Nothing

                                                ( maybeAnnVar, s5 ) =
                                                    case singleInstance of
                                                        Just instType ->
                                                            -- Bind the def's vars to the single recorded
                                                            -- demand (best-effort, shared store). The seeded
                                                            -- var is handed on: F3-b reads the binding types
                                                            -- from its zonk.
                                                            case Store.loadTypeS defCanType s4 of
                                                                ( annVar, sL1 ) ->
                                                                    case Store.monoTypeToVarS instType sL1 of
                                                                        ( demandVar, sL2 ) ->
                                                                            ( Just annVar, unifyStepBestEffort annVar demandVar sL2 )

                                                        Nothing ->
                                                            ( Nothing, s4 )
                                            in
                                            case tailDefBindingTypes maybeAnnVar typedArgs defCanType s5 of
                                                ( ( monoParams, defType ), s6 ) ->
                                                    case
                                                        withLoopFrame name
                                                            typedArgs
                                                            (Engine.scoped
                                                                (\sx -> translate tailBody (insertVars monoParams (Engine.insertVar name defType sx)))
                                                            )
                                                            s6
                                                    of
                                                        ( monoTailBody, s7 ) ->
                                                            case classifyAs Mono.tkClassLet letCanType s7 of
                                                                ( letType0, s8 ) ->
                                                                    let
                                                                        letType =
                                                                            if
                                                                                Mono.containsAnyMVar letType0
                                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                                            then
                                                                                Mono.typeOf monoBody

                                                                            else
                                                                                letType0
                                                                    in
                                                                    ( Mono.MonoLet (Mono.MonoTailDef name monoParams monoTailBody) monoBody letType, s8 )


{-| F3-b (plans/lss-container-payload-transport.md §12.9.5): a local tail-def's
param and binding types. lss off, flag off, or no single-instance demand var:
exactly the storeless classifies. Otherwise the top-level `TailDef` recipe
(`specializeCycleFuncDef`): classify for STRUCTURE, the zonk of the
demand-seeded annotation var for ANNOTATIONS, params peeled from the overlaid
function type when the arity matches.
-}
tailDefBindingTypes : Maybe Vars.Variable -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> Can.Type TypeIds.MVarId -> Step ( List ( Name, Mono.MonoType ), Mono.MonoType )
tailDefBindingTypes maybeAnnVar typedArgs defCanType s0 =
    case
        Engine.traverse
            (\( locName, argType ) sx ->
                case classifyAs Mono.tkClassParam argType sx of
                    ( mt, sx1 ) ->
                        ( ( A.toValue locName, mt ), sx1 )
            )
            typedArgs
            s0
    of
        ( classifiedParams, s1 ) ->
            case classifyAs Mono.tkClassLet defCanType s1 of
                ( classifiedType, s2 ) ->
                    case ( s2.env.lss.enabled, maybeAnnVar ) of
                        ( True, Just annVar ) ->
                            case Store.zonkToMono annVar s2 of
                                ( zonkedType, s3 ) ->
                                    let
                                        funcType =
                                            Mono.overlayAnnotations classifiedType zonkedType

                                        peeled =
                                            extractFieldTypes (List.length typedArgs) funcType

                                        monoParams =
                                            if List.length peeled == List.length classifiedParams then
                                                List.map2 (\( nm, mt ) pt -> ( nm, Mono.overlayAnnotations mt pt )) classifiedParams peeled

                                            else
                                                classifiedParams
                                    in
                                    ( ( monoParams, funcType ), Engine.bumpArgFlowCensus "letOverlay|tailFn" s3 )

                        _ ->
                            ( ( classifiedParams, classifiedType ), s2 )


finishLet : Mono.MonoDef -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
finishLet monoDef body letCanType s0 =
    case translate body s0 of
        ( monoBody, s1 ) ->
            case classifyAs Mono.tkClassLet letCanType s1 of
                ( letType0, s2 ) ->
                    let
                        letType =
                            if
                                Mono.containsAnyMVar letType0
                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                            then
                                Mono.typeOf monoBody

                            else
                                letType0
                    in
                    ( Mono.MonoLet monoDef monoBody letType, s2 )


insertVars : List ( Name, Mono.MonoType ) -> Engine.S -> Engine.S
insertVars pairs s0 =
    List.foldl (\( name, t ) sAcc -> Engine.insertVar name t sAcc) s0 pairs



-- ====== NUMBER-MULTI (a let-bound `number` used at Int AND Float) ======


{-| A `let n = <number>` whose type carries an unresolved `number` var and a
numeric-fixable shape gets multi-specialized: one binding per distinct
monomorphic type it is used at (the first/Int keeps the bare name, later ones
get `n$v<idx>`). Discovery is body-first (each use records its instance), then
the eager Int def is emitted outermost, the extra copies nested inside.
-}
translateNumberMultiLet : Name -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateNumberMultiLet name defBody body letCanType s0 =
    case translate defBody s0 of
        ( eagerBody, s1 ) ->
            case Engine.recordNumberInstance name (Mono.typeOf eagerBody) (Engine.pushNumberMulti name s1) of
                ( _, s2 ) ->
                    -- Bind the eager name in varEnv (scoped to the body) so
                    -- destructor roots (`let (a,b) = (1,2)` => root `_v0`) and
                    -- any non-VarLocal consumer resolve it. VarLocal uses still
                    -- take the recordNumberInstance path (isTarget wins first).
                    case Engine.scoped (\sx -> translate body (Engine.insertVar name (Mono.typeOf eagerBody) sx)) s2 of
                        ( monoBody, s3 ) ->
                            case Engine.popNumberMulti s3 of
                                ( maybeEntry, s4 ) ->
                                    case buildFloatDefs name defBody maybeEntry s4 of
                                        ( floatDefs, s5 ) ->
                                            case classifyAs Mono.tkClassLet letCanType s5 of
                                                ( letType0, s6 ) ->
                                                    let
                                                        letType =
                                                            if
                                                                Mono.containsAnyMVar letType0
                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                            then
                                                                Mono.typeOf monoBody

                                                            else
                                                                letType0

                                                        bodyWithFloats =
                                                            List.foldl (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc)) monoBody (List.reverse floatDefs)
                                                    in
                                                    ( Mono.MonoLet (Mono.MonoDef name eagerBody) bodyWithFloats letType, s6 )


{-| Build the per-type extra copies (`n$v1`, …), each by re-translating the RHS
under a demand of the instance type (so e.g. `10 + 20` becomes the Float add).
Excludes the eager/first instance (which keeps the bare name).
-}
buildFloatDefs : Name -> TOpt.Expr TypeIds.MVarId -> Maybe Engine.NumberMultiEntry -> Step (List Mono.MonoDef)
buildFloatDefs name defBody maybeEntry s0 =
    case maybeEntry of
        Just entry ->
            Engine.traverse
                (\inst sx ->
                    case retranslateAt defBody inst.monoType sx of
                        ( e, sx1 ) ->
                            ( Mono.MonoDef inst.freshName e, sx1 )
                )
                (Mono.specMapValues entry.instances |> List.filter (\inst -> inst.freshName /= name))
                s0

        Nothing ->
            ( [], s0 )


{-| Re-translate an expression under a demanded type, in a fresh solver store
(so the demand's concretization doesn't contaminate the surrounding item);
`varEnv` and global state (registry/worklist) are kept so it can reference outer
locals and enqueue its callees.

Carries the enclosing instance tag unchanged — this is the NUMBER-multi entry
point (`buildFloatDefs`), which deliberately does NOT instance-qualify
(plans/lss-instance-qualified-members.md §3.7): Int and Float instances differ
in LAYOUT, so AbiCloning already separates them into different buckets and
already stamps them. Qualifying them would mint member ids and split specs for
nothing.

-}
retranslateAt : TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoExpr
retranslateAt defBody instType s0 =
    retranslateWithTag s0.itemAux.currentLocalInstance s0.itemAux.retranslating defBody instType s0


{-| `retranslateAt` for a LOCAL-multi instance: the re-translation runs under
the instance's own composed tag, so lambdas minted inside it carry member ids
distinct from the same source lambda's ids in sibling instances
(plans/lss-instance-qualified-members.md §3). Flag-off, and past the §3.3 cap,
this is exactly `retranslateAt`.
-}
retranslateAtInstance : Name -> Int -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoExpr
retranslateAtInstance name ord defBody instType s0 =
    case Engine.localInstanceTagFor ord s0 of
        ( instTag, s1 ) ->
            -- F2.b: the def's own name resolves to THIS instance's id inside
            -- the re-translation (`injectRetranslatingSelf`).
            retranslateWithTag instTag (Maybe.map (\( lam, arity ) -> ( name, lam, arity )) (rhsLamOf defBody)) defBody instType s1


retranslateWithTag : Int -> Maybe ( Name, TypeIds.SrcLambdaId, Int ) -> TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoExpr
retranslateWithTag instTag retranslating defBody instType s0 =
    let
        clearedA =
            Engine.clearedAux s0.itemAux

        sFresh =
            -- The MONO_029 read lists are stashed like the store: scratch
            -- Point indices are meaningless against the restored item store
            -- (leaking them aliases low outer point indices and livelocks the
            -- saturation loop — found by the R0 census on elm-parser).
            { s0 | store = Engine.freshStore, memo = Dict.empty, revMemo = Array.empty, itemAux = { clearedA | currentLocalInstance = instTag, retranslating = retranslating } }

        step =
            \sx -> translate defBody (demandUnifyRoot (TOpt.typeOf defBody) instType defBody sx)
    in
    case step sFresh of
        ( monoExpr, s1 ) ->
            -- Drop the scratch store and reinstate the stashed one.
            ( monoExpr, { s1 | store = s0.store, memo = s0.memo, revMemo = s0.revMemo, itemAux = Engine.restoredAux s0.itemAux s1.itemAux } )


isNumberMultiEligible : Can.Type TypeIds.MVarId -> Step Bool
isNumberMultiEligible defCanType s0 =
    case hasNumberVar defCanType s0 of
        ( True, s1 ) ->
            case classifyAs Mono.tkClassLet defCanType s1 of
                ( t, s2 ) ->
                    ( isNumericFixableShape t, s2 )

        ( False, s1 ) ->
            ( False, s1 )


hasNumberVar : Can.Type TypeIds.MVarId -> Step Bool
hasNumberVar defCanType s =
    ( List.any (\id -> Dict.get (Id.toComparable id) s.superTable == Just Vars.Number) (KernelAbi.freeVarIds defCanType [])
    , s
    )


isNumericFixableShape : Mono.MonoType -> Bool
isNumericFixableShape monoType =
    case monoType of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MTuple _ elems ->
            not (List.isEmpty elems) && List.all isNumericFixableShape elems

        Mono.MRecord _ fields ->
            not (Dict.isEmpty fields) && List.all isNumericFixableShape (Dict.values fields)

        Mono.MList _ elem ->
            isNumericFixableShape elem

        Mono.MCustom _ _ _ args ->
            -- A custom type with at least one numeric-fixable arg and no arg the
            -- recording couldn't re-type (mirrors the original engine's rule).
            List.any isNumericFixableShape args
                && List.all (\a -> isNumericFixableShape a || not (monoTypeMentionsNumeric a)) args

        _ ->
            False


monoTypeMentionsNumeric : Mono.MonoType -> Bool
monoTypeMentionsNumeric mt =
    case mt of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList _ t ->
            monoTypeMentionsNumeric t

        Mono.MTuple _ ts ->
            List.any monoTypeMentionsNumeric ts

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t acc -> acc || monoTypeMentionsNumeric t) False fields

        Mono.MCustom _ _ _ args ->
            List.any monoTypeMentionsNumeric args

        Mono.MFunction _ _ args r ->
            List.any monoTypeMentionsNumeric args || monoTypeMentionsNumeric r

        _ ->
            False



-- ====== RECORD ACCESS ======


{-| Translate a record access. When the record is a direct use of a number-multi
target and the access result is demanded at a CONCRETE scalar number, this is the
access-analogue of the destructor divert: overlay ONLY the accessed field onto the
root's eager type, record that root instance (`r$vN`), and point the access at it
— each access site refines its own slot independently (sibling uses share solved
type vars, so flowing the demand through the store would cross-pollute them).
Otherwise: generic path, connecting the access result's var to the record-use
type's field slot (demand flow for single-owner shapes).
-}
translateAccess : TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
translateAccess record fieldName meta s0 =
    case accessedLocalName record of
        Just rname ->
            case Engine.numberMultiRootType rname s0 of
                ( Just eagerRootType, s1 ) ->
                    case classifyAs Mono.tkClassMisc meta.tipe s1 of
                        ( demand, s2 ) ->
                            if demand == Mono.MFloat || demand == Mono.MInt then
                                case refineRootInstance s2.env.globalTypeEnv eagerRootType (TOpt.Field fieldName (TOpt.Root rname)) demand of
                                    Just refinedRootType ->
                                        case Engine.recordNumberInstance rname refinedRootType s2 of
                                            ( ( freshName, instType ), s3 ) ->
                                                ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName instType) fieldName demand, s3 )

                                    Nothing ->
                                        genericAccess record fieldName meta s2

                            else
                                genericAccess record fieldName meta s2

                ( Nothing, s1 ) ->
                    genericAccess record fieldName meta s1

        Nothing ->
            genericAccess record fieldName meta s0


{-| The local name a record-access scrutinee refers to (if it is a direct local
reference, tracked or not).
-}
accessedLocalName : TOpt.Expr TypeIds.MVarId -> Maybe Name
accessedLocalName record =
    case record of
        TOpt.VarLocal rname _ ->
            Just rname

        TOpt.TrackedVarLocal _ rname _ ->
            Just rname

        _ ->
            Nothing


genericAccess : TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
genericAccess record fieldName meta s0 =
    let
        sConn =
            case recordFieldCanType fieldName (TOpt.typeOf record) of
                Just fieldCan ->
                    connectTypes meta.tipe fieldCan s0

                Nothing ->
                    s0
    in
    case classifyAs Mono.tkClassMisc meta.tipe sConn of
        ( monoType, s1 ) ->
            case translate record s1 of
                ( monoRecord, s2 ) ->
                    ( Mono.MonoRecordAccess monoRecord
                        fieldName
                        (refineAccessType s2.env.lss.enabled monoType (Mono.typeOf monoRecord) fieldName)
                    , s2
                    )



-- ====== DESTRUCTOR-DERIVED MULTI-INSTANCE (MONO_028) ======


{-| Original eager destructor handling (bind then translate body, always emit).
-}
generalDestruct : TOpt.Destructor TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
generalDestruct ((TOpt.Destructor dname0 _ dmeta0) as destructor) body meta s0 =
    let
        (TOpt.Destructor _ dpath0 _) =
            destructor

        -- Remember the derived name -> destructor canType, AND connect the
        -- destructor's (freshly-rebuilt) type ids to the ROOT's canonical slot
        -- type: a later CALL of a derived FUNCTION (`getter rec`) then flows its
        -- concreteness back into the root case/tuple's own vars.
        s1 =
            { s0 | derivedDestructors = Dict.insert dname0 dmeta0.tipe s0.derivedDestructors }

        s2 =
            case Dict.get (pathRootName dpath0) s1.localCanTypes |> Maybe.andThen (\rootCan -> canSlotForPath rootCan dpath0) of
                Just slotCan ->
                    connectTypes dmeta0.tipe slotCan s1

                Nothing ->
                    s1
    in
    generalDestructBody destructor body meta s2


generalDestructBody : TOpt.Destructor TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
generalDestructBody destructor body meta s0 =
    case classifyAs Mono.tkClassDestr meta.tipe s0 of
        ( monoType0, s1 ) ->
            case specializeDestructor destructor s1 of
                ( monoDestructor, s2 ) ->
                    let
                        (Mono.MonoDestructor destructorName _ destructorType) =
                            monoDestructor
                    in
                    Engine.scoped
                        (\sx ->
                            case translate body (Engine.insertVar destructorName destructorType sx) of
                                ( monoBody, sx1 ) ->
                                    ( Mono.MonoDestruct monoDestructor
                                        monoBody
                                        (if Mono.containsAnyMVar monoType0 then
                                            Mono.typeOf monoBody

                                         else
                                            monoType0
                                        )
                                    , sx1
                                    )
                        )
                        s2


{-| Body-first specialization of a `Destruct` whose root is a number-multi target.
Seed `dname` as a number-multi target, specialize the body FIRST so its uses
record one instance per demanded numeric type, then for each instance materialise
a slot-refined root instance (`recordNumberInstance rootName` — the root's own
`translateNumberMultiLet` emits it) and emit a renamed destructor. The eager Int
destructor is emitted only if the bare `dname` is actually referenced.
-}
specializeNumberDestruct : Name -> TOpt.Path -> TOpt.Meta TypeIds.MVarId -> Name -> Mono.MonoType -> TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
specializeNumberDestruct dname path dmeta rootName eagerRootType body s0 =
    case classifyAs Mono.tkClassDestr dmeta.tipe s0 of
        ( eagerLeaf, s1 ) ->
            case Engine.recordNumberInstance dname eagerLeaf (Engine.pushNumberMulti dname s1) of
                ( _, s2 ) ->
                    case Engine.scoped (\sx -> translate body (Engine.insertVar dname eagerLeaf sx)) s2 of
                        ( monoBody, s3 ) ->
                            case Engine.popNumberMulti s3 of
                                ( maybeEntry, s4 ) ->
                                    let
                                        dnameUsed =
                                            exprReferencesLocal dname monoBody

                                        instances =
                                            case maybeEntry of
                                                Just e ->
                                                    List.filter (\i -> i.freshName /= dname || dnameUsed) (Mono.specMapValues e.instances)

                                                Nothing ->
                                                    []
                                    in
                                    case Engine.traverse (buildRefinedDestructor rootName eagerRootType path) instances s4 of
                                        ( maybeDestructors, s5 ) ->
                                            let
                                                destructors =
                                                    List.filterMap identity maybeDestructors
                                            in
                                            ( List.foldl (\md acc -> Mono.MonoDestruct md acc (Mono.typeOf acc)) monoBody (List.reverse destructors)
                                            , s5
                                            )


{-| For one recorded instance of the destructor name, materialise the root value
instance with only this slot refined (overlay the leaf onto the eager root type),
register it on the root's multi-entry, and build the renamed destructor pointing
at that fresh root instance. Returns Nothing if the slot can't be refined.
-}
buildRefinedDestructor : Name -> Mono.MonoType -> TOpt.Path -> Engine.NumberInstance -> Step (Maybe Mono.MonoDestructor)
buildRefinedDestructor rootName eagerRootType path inst s0 =
    buildRefinedDestructorWith s0.env.globalTypeEnv rootName eagerRootType path inst s0


buildRefinedDestructorWith : TypeEnv.GlobalTypeEnv -> Name -> Mono.MonoType -> TOpt.Path -> Engine.NumberInstance -> Step (Maybe Mono.MonoDestructor)
buildRefinedDestructorWith gte rootName eagerRootType path inst s0 =
    case refineRootInstance gte eagerRootType path inst.monoType of
        Just refinedRootType ->
            case Engine.recordNumberInstance rootName refinedRootType s0 of
                ( ( freshRootName, _ ), s1 ) ->
                    case specializePath (rewriteRootInPath rootName freshRootName path) (Engine.insertVar freshRootName refinedRootType s1) of
                        ( monoPath, s2 ) ->
                            let
                                dtype =
                                    Mono.getMonoPathType monoPath
                            in
                            ( Just (Mono.MonoDestructor inst.freshName monoPath dtype)
                            , Engine.insertVar inst.freshName dtype s2
                            )

        Nothing ->
            ( Nothing, s0 )


{-| Overlay `leaf` onto the eager root container at the slot selected by `path`
(tuple index / record field / custom-type payload / unbox wrapper), leaving
other slots as they were. Nothing for list/array paths (those stay on the
general destructor path).
-}
refineRootInstance : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> TOpt.Path -> Mono.MonoType -> Maybe Mono.MonoType
refineRootInstance gte container path leaf =
    case path of
        TOpt.Root _ ->
            Just leaf

        TOpt.Index idx hint subPath ->
            navigateType gte container subPath
                |> Maybe.andThen
                    (\subC ->
                        case hint of
                            TOpt.HintCustom ctorName ->
                                replaceCustomSlot gte ctorName (Index.toMachine idx) subC leaf

                            TOpt.HintList ->
                                Nothing

                            _ ->
                                replaceIndexSlot subC (Index.toMachine idx) leaf
                    )
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        TOpt.Field fieldName subPath ->
            navigateType gte container subPath
                |> Maybe.andThen (\subC -> replaceRecordSlot subC fieldName leaf)
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        TOpt.Unbox subPath ->
            navigateType gte container subPath
                |> Maybe.andThen (\subC -> replaceUnboxSlot gte subC leaf)
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        _ ->
            Nothing


{-| Set the union type-arg selected by ctor `ctorName`'s field `idx` to `leaf`
(only when that field's declared type is a bare union type-param).
-}
replaceCustomSlot : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType -> Maybe Mono.MonoType
replaceCustomSlot gte ctorName idx container leaf =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    findCtorArg ctorName idx unionData.alts
                        |> Maybe.andThen
                            (\fieldCanType ->
                                case fieldCanType of
                                    Can.TVar paramName ->
                                        paramPosition paramName unionData.vars
                                            |> Maybe.map
                                                (\pos ->
                                                    Mono.mCustom home
                                                        typeName
                                                        (List.indexedMap
                                                            (\i t ->
                                                                if i == pos then
                                                                    leaf

                                                                else
                                                                    t
                                                            )
                                                            typeArgs
                                                        )
                                                )

                                    _ ->
                                        Nothing
                            )

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Set the single type-arg of an @unbox wrapper's payload to `leaf` (only when
the single ctor's single field is a bare union type-param).
-}
replaceUnboxSlot : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType -> Maybe Mono.MonoType
replaceUnboxSlot gte container leaf =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ Can.TVar paramName ] ->
                                    paramPosition paramName unionData.vars
                                        |> Maybe.map
                                            (\pos ->
                                                Mono.mCustom home
                                                    typeName
                                                    (List.indexedMap
                                                        (\i t ->
                                                            if i == pos then
                                                                leaf

                                                            else
                                                                t
                                                        )
                                                        typeArgs
                                                    )
                                            )

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


paramPosition : Name -> List Name -> Maybe Int
paramPosition name vars =
    List.indexedMap Tuple.pair vars
        |> List.filter (\( _, v ) -> v == name)
        |> List.head
        |> Maybe.map Tuple.first


navigateType : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> TOpt.Path -> Maybe Mono.MonoType
navigateType gte container path =
    case path of
        TOpt.Root _ ->
            Just container

        TOpt.Index idx hint subPath ->
            navigateType gte container subPath
                |> Maybe.andThen
                    (\c ->
                        case hint of
                            TOpt.HintCustom ctorName ->
                                customSlot gte ctorName (Index.toMachine idx) c

                            TOpt.HintList ->
                                Nothing

                            _ ->
                                tupleSlot c (Index.toMachine idx)
                    )

        TOpt.Field fieldName subPath ->
            navigateType gte container subPath |> Maybe.andThen (recordSlot fieldName)

        TOpt.Unbox subPath ->
            navigateType gte container subPath |> Maybe.andThen (unboxSlot gte)

        _ ->
            Nothing


{-| Read the type of ctor `ctorName`'s field `idx` from a custom container
(only when the field's declared type is a bare union type-param).
-}
customSlot : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Maybe Mono.MonoType
customSlot gte ctorName idx container =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    findCtorArg ctorName idx unionData.alts
                        |> Maybe.andThen
                            (\fieldCanType ->
                                case fieldCanType of
                                    Can.TVar paramName ->
                                        paramPosition paramName unionData.vars
                                            |> Maybe.andThen (\pos -> List.head (List.drop pos typeArgs))

                                    _ ->
                                        Nothing
                            )

                Nothing ->
                    Nothing

        _ ->
            Nothing


unboxSlot : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Maybe Mono.MonoType
unboxSlot gte container =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ Can.TVar paramName ] ->
                                    paramPosition paramName unionData.vars
                                        |> Maybe.andThen (\pos -> List.head (List.drop pos typeArgs))

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


tupleSlot : Mono.MonoType -> Int -> Maybe Mono.MonoType
tupleSlot t i =
    case t of
        Mono.MTuple _ elems ->
            List.head (List.drop i elems)

        _ ->
            Nothing


recordSlot : String -> Mono.MonoType -> Maybe Mono.MonoType
recordSlot f t =
    case t of
        Mono.MRecord _ fields ->
            Dict.get f fields

        _ ->
            Nothing


replaceIndexSlot : Mono.MonoType -> Int -> Mono.MonoType -> Maybe Mono.MonoType
replaceIndexSlot t i leaf =
    case t of
        Mono.MTuple _ elems ->
            if i >= 0 && i < List.length elems then
                Just
                    (Mono.mTuple
                        (List.indexedMap
                            (\j x ->
                                if j == i then
                                    leaf

                                else
                                    x
                            )
                            elems
                        )
                    )

            else
                Nothing

        _ ->
            Nothing


replaceRecordSlot : Mono.MonoType -> String -> Mono.MonoType -> Maybe Mono.MonoType
replaceRecordSlot t f leaf =
    case t of
        Mono.MRecord _ fields ->
            Just (Mono.mRecord (Dict.insert f leaf fields))

        _ ->
            Nothing


{-| Navigate a destructor path over the CANONICAL type (tuple/record slots).
-}
canSlotForPath : Can.Type TypeIds.MVarId -> TOpt.Path -> Maybe (Can.Type TypeIds.MVarId)
canSlotForPath rootCan path =
    case path of
        TOpt.Root _ ->
            Just rootCan

        TOpt.Index idx _ sub ->
            canSlotForPath rootCan sub
                |> Maybe.andThen tupleSlotCanTypes
                |> Maybe.andThen (\slots -> List.head (List.drop (Index.toMachine idx) slots))

        TOpt.Field f sub ->
            canSlotForPath rootCan sub
                |> Maybe.andThen (recordFieldCanType f)

        _ ->
            Nothing


pathRootName : TOpt.Path -> Name
pathRootName path =
    case path of
        TOpt.Root name ->
            name

        TOpt.Index _ _ sub ->
            pathRootName sub

        TOpt.ArrayIndex _ sub ->
            pathRootName sub

        TOpt.Field _ sub ->
            pathRootName sub

        TOpt.Unbox sub ->
            pathRootName sub


rewriteRootInPath : Name -> Name -> TOpt.Path -> TOpt.Path
rewriteRootInPath oldName newName path =
    case path of
        TOpt.Root name ->
            TOpt.Root
                (if name == oldName then
                    newName

                 else
                    name
                )

        TOpt.Index i h sub ->
            TOpt.Index i h (rewriteRootInPath oldName newName sub)

        TOpt.ArrayIndex i sub ->
            TOpt.ArrayIndex i (rewriteRootInPath oldName newName sub)

        TOpt.Field f sub ->
            TOpt.Field f (rewriteRootInPath oldName newName sub)

        TOpt.Unbox sub ->
            TOpt.Unbox (rewriteRootInPath oldName newName sub)


isScalarNumber : Mono.MonoType -> Bool
isScalarNumber t =
    case t of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        _ ->
            False


exprReferencesLocal : Name -> Mono.MonoExpr -> Bool
exprReferencesLocal name expr =
    List.member name (Closure.findFreeLocals Set.empty expr)



-- ====== LOCAL-MULTI (a let-bound function used at multiple types) ======


{-| Does the canonical type CONTAIN a lambda anywhere (through aliases)?
-}
typeContainsCanLambda : Can.Type TypeIds.MVarId -> Bool
typeContainsCanLambda t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TType _ _ args ->
            List.any typeContainsCanLambda args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> acc || typeContainsCanLambda ft) False fields

        Can.TTuple a b rest ->
            List.any typeContainsCanLambda (a :: b :: rest)

        Can.TAlias _ _ args (Can.Filled inner) ->
            typeContainsCanLambda inner || List.any (\( _, at ) -> typeContainsCanLambda at) args

        Can.TAlias _ _ args (Can.Holey inner) ->
            typeContainsCanLambda inner || List.any (\( _, at ) -> typeContainsCanLambda at) args

        _ ->
            False


{-| Is this a function type (possibly through aliases)? Every let-bound function
routes through local-multi (a single use collapses to the bare name; N distinct
applied types produce `f`, `f$1`, …).
-}
isFunctionType : Can.Type TypeIds.MVarId -> Bool
isFunctionType t =
    case t of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled inner) ->
            isFunctionType inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            isFunctionType inner

        _ ->
            False


{-| Specialize a let-bound function per distinct type it is applied at. Discovery
is body-first (each use records its applied type), then each recorded instance is
produced by re-translating the RHS under that type (in a fresh store), renamed to
its per-instance name. An unused function emits its bare def once.
-}
translateLocalMultiLet : Name -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLocalMultiLet name defBody body letCanType s0 =
    let
        sA =
            { s0 | localCanTypes = Dict.insert name (TOpt.typeOf defBody) s0.localCanTypes }

        sB =
            Engine.pushLocalMulti (rhsLamOf defBody) (rhsPapOf defBody sA) name sA
    in
    case classifyAs Mono.tkClassLet (TOpt.typeOf defBody) sB of
        ( declType, s1 ) ->
            -- Bind the name (scoped) so non-VarLocal consumers — e.g. a
            -- destructor root over a tuple-of-functions binding — resolve.
            case Engine.scoped (\sx -> translate body (Engine.insertVar name declType sx)) s1 of
                ( monoBody, s2 ) ->
                    case Engine.popLocalMulti s2 of
                        ( maybeEntry, s3 ) ->
                            case buildLocalDefs name defBody maybeEntry s3 of
                                ( instanceDefs, s4 ) ->
                                    -- E4a (plan §9.1): transport the per-instance re-translated
                                    -- defs' lambda-set annos to the already-emitted USE sites —
                                    -- walked now if this is the outermost let-function of the
                                    -- item, else owed to the enclosing one's single walk
                                    -- (`flushLocalMultiEnrich`).
                                    case flushLocalMultiEnrich name maybeEntry instanceDefs monoBody s4 of
                                        ( monoBody1, s5 ) ->
                                            case classifyAs Mono.tkClassLet letCanType s5 of
                                                ( letType0, s6 ) ->
                                                    let
                                                        -- letType stays computed from the UN-enriched
                                                        -- body (its branch choice must not move flag-on).
                                                        letType =
                                                            if
                                                                Mono.containsAnyMVar letType0
                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                            then
                                                                Mono.typeOf monoBody

                                                            else
                                                                letType0
                                                    in
                                                    ( List.foldl (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc)) monoBody1 (List.reverse instanceDefs)
                                                        |> retypeLet letType
                                                    , s6
                                                    )


{-| Overwrite the outermost `MonoLet`'s carried type with the let's own type
(the fold seeds from the body's type; the whole expression's type is the let
type). No-op for a bare body.
-}
retypeLet : Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr
retypeLet letType expr =
    case expr of
        Mono.MonoLet d inner _ ->
            Mono.MonoLet d inner letType

        _ ->
            expr


{-| E4a (plan §9.1): transport the defs' lambda-set annotations to the
local-multi USE sites. Uses are emitted during body translation with MonoTypes
from fresh per-use instantiations — all-`LTop` annos — while the per-instance
re-translated def RHS (`buildLocalDefs`, carrying S's spine + indirect-result
transport) holds the concrete sets. The runtime values reaching a use ARE the
values that instance's RHS produces, so overlaying the def's annos onto each
`MonoVarLocal` of the instance binding is the graph-level image of the §7.4
def→use set join (union over uses at one layout; per-layout instances carry
their own re-translated type, so precision is per-instance).
`Mono.overlayAnnotations` is shape-guarded (keeps the use's structure, falls
back on mismatch — worst case an untransported `LTop`, sound widening), and
Elm's no-shadowing rule plus `$`-suffixed freshNames make the name-keyed
rewrite safe. lss-off: identity, so flag-off output is byte-identical.

DEFERRED TO THE OUTERMOST LET-FUNCTION (2026-09-04, the Aug-26 → Sep-3
self-compile regression). The overlay used to run at EVERY let-function's
completion as a generic `MonoTraverse.traverseExpr` over the whole let body —
a PAP, a tuple and a rebuilt node per visited node, and a body nested under
k let-functions rebuilt k times over. On the Sep-3 self-compile that was
3.34e9 traversal dispatches (68 % of the program's dispatch) from 764 calls,
at a 2.47 % hit rate. Now:

  - a let-function whose completion finds an ENCLOSING let-function on the
    `localMulti` stack does not walk: it records its instance names in the
    enclosing entry's `pendingEnrich` (inherited pendings cascade upward);
  - the OUTERMOST let-function walks its body ONCE (`overlayLocalMultiUses`):
    a direct walk that allocates nothing on unchanged paths, binds each
    recorded group's `instance -> typeOf rhs` at the group's own `MonoLet`
    chain (lexically scoped, so a sibling scope reusing a name binds its own
    value) and overlays exactly the uses the per-let walks used to.

The tree is the SAME one the per-let scheme built: own-group names are not
overlaid inside the group's own RHSs (the old walk covered the body only),
inherited names are (the old enclosing walk covered everything), and the
non-outermost members of a chain carry `typeOf` of the own-overlaid body
exactly as the completion-time fold computed it.

-}
flushLocalMultiEnrich : Name -> Maybe Engine.NumberMultiEntry -> List Mono.MonoDef -> Mono.MonoExpr -> Step Mono.MonoExpr
flushLocalMultiEnrich defName maybeEntry instanceDefs monoBody s0 =
    if not s0.env.lss.enabled then
        ( monoBody, s0 )

    else
        let
            inherited =
                case maybeEntry of
                    Just entry ->
                        entry.pendingEnrich

                    Nothing ->
                        Dict.empty

            -- This let's own instance bindings (`f`, `f$1`, …). Walking now,
            -- they seed the environment directly (the chain is not wrapped
            -- around `monoBody` yet); deferring, the enclosing walk finds
            -- them at the chain.
            own =
                List.foldl
                    (\d acc ->
                        case d of
                            Mono.MonoDef n rhs ->
                                Dict.insert n ( defName, Mono.typeOf rhs ) acc

                            Mono.MonoTailDef _ _ _ ->
                                acc
                    )
                    Dict.empty
                    instanceDefs

            pending =
                Dict.union own inherited
        in
        if Dict.isEmpty pending then
            ( monoBody, s0 )

        else
            case s0.localMulti of
                top :: rest ->
                    -- Nested: the enclosing let-function's walk covers this body.
                    ( monoBody, { s0 | localMulti = { top | pendingEnrich = Dict.union pending top.pendingEnrich } :: rest } )

                [] ->
                    let
                        rootEnv =
                            Dict.map (\_ ( _, t ) -> t) own
                    in
                    ( overlayLocalMultiUses pending rootEnv monoBody, enrichCensus pending rootEnv monoBody s0 )


{-| The single walk. `groups`: recorded instance name -> (its let's defName,
the instance RHS type as recorded); `env`: the bindings in scope at the root.
-}
overlayLocalMultiUses : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr
overlayLocalMultiUses groups env root =
    Maybe.withDefault root (olmExpr groups env root)


{-| One node. `Nothing` = the subtree is unchanged (nothing is allocated on
that path); `Just` = a rebuilt subtree.
-}
olmExpr : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Maybe Mono.MonoExpr
olmExpr groups env expr =
    case expr of
        Mono.MonoVarLocal n t ->
            case Dict.get n env of
                Just src ->
                    Just (Mono.MonoVarLocal n (Mono.overlayAnnotations t src))

                Nothing ->
                    Nothing

        Mono.MonoLet def body t ->
            case olmChain groups expr of
                Just ( members, innerBody ) ->
                    Just (olmGroup groups env members innerBody)

                Nothing ->
                    case ( olmDef groups env def, olmExpr groups env body ) of
                        ( Nothing, Nothing ) ->
                            Nothing

                        ( md, mb ) ->
                            Just (Mono.MonoLet (Maybe.withDefault def md) (Maybe.withDefault body mb) t)

        Mono.MonoClosure info body t ->
            case ( olmCaptures groups env info.captures, olmExpr groups env body ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mc, mb ) ->
                    Just (Mono.MonoClosure { info | captures = Maybe.withDefault info.captures mc } (Maybe.withDefault body mb) t)

        Mono.MonoCall region func args t info ->
            case ( olmExpr groups env func, olmList groups env args ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mf, ma ) ->
                    Just (Mono.MonoCall region (Maybe.withDefault func mf) (Maybe.withDefault args ma) t info)

        Mono.MonoTailCall name args t ->
            Maybe.map (\a -> Mono.MonoTailCall name a t) (olmNamed groups env args)

        Mono.MonoIf branches final t ->
            case ( olmBranches groups env branches, olmExpr groups env final ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mb, mf ) ->
                    Just (Mono.MonoIf (Maybe.withDefault branches mb) (Maybe.withDefault final mf) t)

        Mono.MonoDestruct path inner t ->
            Maybe.map (\i -> Mono.MonoDestruct path i t) (olmExpr groups env inner)

        Mono.MonoCase label scrutinee decider jumps t ->
            case ( olmDecider groups env decider, olmNamed groups env jumps ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( md, mj ) ->
                    Just (Mono.MonoCase label scrutinee (Maybe.withDefault decider md) (Maybe.withDefault jumps mj) t)

        Mono.MonoList region items t ->
            Maybe.map (\i -> Mono.MonoList region i t) (olmList groups env items)

        Mono.MonoRecordCreate fields t ->
            Maybe.map (\f -> Mono.MonoRecordCreate f t) (olmNamed groups env fields)

        Mono.MonoRecordAccess inner field t ->
            Maybe.map (\i -> Mono.MonoRecordAccess i field t) (olmExpr groups env inner)

        Mono.MonoRecordUpdate record updates t ->
            case ( olmExpr groups env record, olmNamed groups env updates ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mr, mu ) ->
                    Just (Mono.MonoRecordUpdate (Maybe.withDefault record mr) (Maybe.withDefault updates mu) t)

        Mono.MonoTupleCreate region elements t ->
            Maybe.map (\e -> Mono.MonoTupleCreate region e t) (olmList groups env elements)

        Mono.MonoLiteral _ _ ->
            Nothing

        Mono.MonoVarGlobal _ _ _ ->
            Nothing

        Mono.MonoVarKernel _ _ _ _ _ ->
            Nothing

        Mono.MonoUnit ->
            Nothing

        Mono.MonoAccessorValue _ _ _ ->
            Nothing


{-| The maximal chain of instance-def `MonoLet`s of ONE recorded group
starting at this node (top-first), with the body under the chain. A `MonoLet`
is a member when its def name is a recorded instance of the same group AND
its RHS type is the very type recorded at completion (a name reused in a
sibling scope binds its own, different value). `Nothing`: no chain here.
-}
olmChain : Dict.Dict String ( String, Mono.MonoType ) -> Mono.MonoExpr -> Maybe ( List ( Name, Mono.MonoExpr, Mono.MonoType ), Mono.MonoExpr )
olmChain groups expr =
    case expr of
        Mono.MonoLet (Mono.MonoDef n rhs) body t ->
            case Dict.get n groups of
                Just ( group, recordedType ) ->
                    if Mono.typeOf rhs == recordedType then
                        Just (olmChainGo groups group body [ ( n, rhs, t ) ])

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


olmChainGo : Dict.Dict String ( String, Mono.MonoType ) -> String -> Mono.MonoExpr -> List ( Name, Mono.MonoExpr, Mono.MonoType ) -> ( List ( Name, Mono.MonoExpr, Mono.MonoType ), Mono.MonoExpr )
olmChainGo groups group expr acc =
    case expr of
        Mono.MonoLet (Mono.MonoDef n rhs) body t ->
            case Dict.get n groups of
                Just ( g, recordedType ) ->
                    if g == group && Mono.typeOf rhs == recordedType then
                        olmChainGo groups group body (( n, rhs, t ) :: acc)

                    else
                        ( List.reverse acc, expr )

                Nothing ->
                    ( List.reverse acc, expr )

        _ ->
            ( List.reverse acc, expr )


{-| Rebuild one group's chain: the RHSs see the OUTER bindings only (the
per-let walk never covered its own instance RHSs), the body sees the group's
own bindings too; non-top members carry `typeOf` of the own-overlaid body,
as the completion-time fold computed it.
-}
olmGroup : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Name, Mono.MonoExpr, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoExpr
olmGroup groups env members innerBody =
    let
        own =
            List.foldl (\( n, rhs, _ ) acc -> Dict.insert n (Mono.typeOf rhs) acc) Dict.empty members

        newBody =
            Maybe.withDefault innerBody (olmExpr groups (Dict.union own env) innerBody)

        memberType =
            case innerBody of
                Mono.MonoVarLocal n t ->
                    case Dict.get n own of
                        Just src ->
                            Mono.overlayAnnotations t src

                        Nothing ->
                            t

                other ->
                    Mono.typeOf other
    in
    olmRebuild groups env members newBody memberType True


olmRebuild : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Name, Mono.MonoExpr, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> Bool -> Mono.MonoExpr
olmRebuild groups env members body memberType isTop =
    case members of
        [] ->
            body

        ( n, rhs, tOrig ) :: rest ->
            Mono.MonoLet
                (Mono.MonoDef n (Maybe.withDefault rhs (olmExpr groups env rhs)))
                (olmRebuild groups env rest body memberType False)
                (if isTop then
                    tOrig

                 else
                    memberType
                )


olmDef : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoDef -> Maybe Mono.MonoDef
olmDef groups env def =
    case def of
        Mono.MonoDef n rhs ->
            Maybe.map (Mono.MonoDef n) (olmExpr groups env rhs)

        Mono.MonoTailDef n params rhs ->
            Maybe.map (Mono.MonoTailDef n params) (olmExpr groups env rhs)


olmList : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List Mono.MonoExpr -> Maybe (List Mono.MonoExpr)
olmList groups env items =
    case items of
        [] ->
            Nothing

        x :: xs ->
            case ( olmExpr groups env x, olmList groups env xs ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mx, mxs ) ->
                    Just (Maybe.withDefault x mx :: Maybe.withDefault xs mxs)


olmNamed : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( k, Mono.MonoExpr ) -> Maybe (List ( k, Mono.MonoExpr ))
olmNamed groups env items =
    case items of
        [] ->
            Nothing

        ( k, x ) :: xs ->
            case ( olmExpr groups env x, olmNamed groups env xs ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mx, mxs ) ->
                    Just (( k, Maybe.withDefault x mx ) :: Maybe.withDefault xs mxs)


olmCaptures : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Name, Mono.MonoExpr, a ) -> Maybe (List ( Name, Mono.MonoExpr, a ))
olmCaptures groups env items =
    case items of
        [] ->
            Nothing

        ( n, x, t ) :: xs ->
            case ( olmExpr groups env x, olmCaptures groups env xs ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( mx, mxs ) ->
                    Just (( n, Maybe.withDefault x mx, t ) :: Maybe.withDefault xs mxs)


olmBranches : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Maybe (List ( Mono.MonoExpr, Mono.MonoExpr ))
olmBranches groups env items =
    case items of
        [] ->
            Nothing

        ( c, x ) :: xs ->
            case ( olmExpr groups env c, olmExpr groups env x, olmBranches groups env xs ) of
                ( Nothing, Nothing, Nothing ) ->
                    Nothing

                ( mc, mx, mxs ) ->
                    Just (( Maybe.withDefault c mc, Maybe.withDefault x mx ) :: Maybe.withDefault xs mxs)


olmDecider : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.Decider Mono.MonoChoice -> Maybe (Mono.Decider Mono.MonoChoice)
olmDecider groups env decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Maybe.map (\e1 -> Mono.Leaf (Mono.Inline e1)) (olmExpr groups env e)

        Mono.Leaf (Mono.Jump _) ->
            Nothing

        Mono.Chain test success failure ->
            case ( olmDecider groups env success, olmDecider groups env failure ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( ms, mf ) ->
                    Just (Mono.Chain test (Maybe.withDefault success ms) (Maybe.withDefault failure mf))

        Mono.FanOut path edges fallback ->
            case ( olmEdges groups env edges, olmDecider groups env fallback ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( me, mf ) ->
                    Just (Mono.FanOut path (Maybe.withDefault edges me) (Maybe.withDefault fallback mf))


olmEdges : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> List ( a, Mono.Decider Mono.MonoChoice ) -> Maybe (List ( a, Mono.Decider Mono.MonoChoice ))
olmEdges groups env edges =
    case edges of
        [] ->
            Nothing

        ( test, d ) :: rest ->
            case ( olmDecider groups env d, olmEdges groups env rest ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( md, mr ) ->
                    Just (( test, Maybe.withDefault d md ) :: Maybe.withDefault rest mr)


{-| Report-gated (`lss.report`) census of what the single walk replaced —
the mechanism behind the Aug-26 → Sep-3 regression:

    e4a|walks       outermost walks
    e4a|nodes       nodes those walks visited (the new cost)
    e4a|oldVisits   nodes the per-let scheme visited: Σ over every group
                    of its body size (each body once per enclosing group)
    e4a|groups      instance-def chains covered
    e4a|depth|<d>   walks whose deepest chain nesting is d
    e4a|item|<g>    oldVisits per global for the worst offenders (≥ 1e6)

-}
enrichCensus : Dict.Dict String ( String, Mono.MonoType ) -> Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Engine.S -> Engine.S
enrichCensus groups rootEnv body s =
    if not s.env.lss.report then
        s

    else
        let
            ownGroup =
                if Dict.isEmpty rootEnv then
                    0

                else
                    1

            ( size, st ) =
                enrichCensusGo groups (1 + ownGroup) body { old = 0, groups = 0, maxDepth = 0 }

            -- the flushing let is itself a group whose old walk covered `body`
            old =
                st.old + ownGroup * size

            depth =
                max st.maxDepth ownGroup

            itemKey =
                case s.currentGlobal of
                    Just g ->
                        Mono.toComparableGlobal g

                    Nothing ->
                        "?"
        in
        s
            |> Engine.bumpArgFlowCensusBy "e4a|walks" 1
            |> Engine.bumpArgFlowCensusBy "e4a|nodes" size
            |> Engine.bumpArgFlowCensusBy "e4a|oldVisits" old
            |> Engine.bumpArgFlowCensusBy "e4a|groups" (st.groups + ownGroup)
            |> Engine.bumpArgFlowCensusBy ("e4a|depth|" ++ String.fromInt depth) 1
            |> (if old >= 1000000 then
                    Engine.bumpArgFlowCensusBy ("e4a|item|" ++ itemKey) old

                else
                    identity
               )


type alias EnrichCensus =
    { old : Int, groups : Int, maxDepth : Int }


{-| Subtree size (MonoExpr nodes, as `traverseExpr` counted them) plus the
census over the chains inside; `depth` = chains enclosing this node + 1.
-}
enrichCensusGo : Dict.Dict String ( String, Mono.MonoType ) -> Int -> Mono.MonoExpr -> EnrichCensus -> ( Int, EnrichCensus )
enrichCensusGo groups depth expr st =
    case olmChain groups expr of
        Just ( members, innerBody ) ->
            let
                ( rhsSize, st1 ) =
                    List.foldl
                        (\( _, rhs, _ ) ( n, a ) ->
                            let
                                ( m, a1 ) =
                                    enrichCensusGo groups depth rhs a
                            in
                            ( n + m, a1 )
                        )
                        ( 0, st )
                        members

                ( bodySize, st2 ) =
                    enrichCensusGo groups (depth + 1) innerBody st1
            in
            ( List.length members + rhsSize + bodySize
            , { st2 | old = st2.old + bodySize, groups = st2.groups + 1, maxDepth = max st2.maxDepth depth }
            )

        Nothing ->
            let
                ( childSum, st1 ) =
                    List.foldl
                        (\c ( n, a ) ->
                            let
                                ( m, a1 ) =
                                    enrichCensusGo groups depth c a
                            in
                            ( n + m, a1 )
                        )
                        ( 0, st )
                        (MonoTraverse.childrenOf expr)
            in
            ( 1 + childSum, st1 )


buildLocalDefs : Name -> TOpt.Expr TypeIds.MVarId -> Maybe Engine.NumberMultiEntry -> Step (List Mono.MonoDef)
buildLocalDefs name defBody maybeEntry s0 =
    case maybeEntry of
        Just entry ->
            if Mono.specMapIsEmpty entry.instances then
                -- Unused function: emit its bare def once, at its declared type.
                case translate defBody s0 of
                    ( e, s1 ) ->
                        ( [ Mono.MonoDef name e ], s1 )

            else
                -- The ORDINAL is the discriminator
                -- (plans/lss-instance-qualified-members.md §3.1). `SpecMap`
                -- iterates in INSERTION order and `freshName` is assigned from
                -- `specMapSize` at insert, so this index is exactly the `$N`
                -- already in the emitted binding name — if it were unstable the
                -- def names would already be unstable, which is the whole
                -- stability argument, and it costs nothing new.
                Engine.traverse
                    (\( ord, inst ) sx ->
                        case retranslateAtInstance name ord defBody inst.monoType sx of
                            ( e, sx1 ) ->
                                ( Mono.MonoDef inst.freshName e, sx1 )
                    )
                    (List.indexedMap Tuple.pair (Mono.specMapValues entry.instances))
                    s0

        Nothing ->
            ( [], s0 )



-- ====== CASE / DECISION TREE ======


specializeDecider : Can.Type TypeIds.MVarId -> Name -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> Step (Mono.Decider Mono.MonoChoice)
specializeDecider caseCanType root decider s0 =
    case decider of
        TOpt.Leaf choice ->
            case specializeChoice caseCanType choice s0 of
                ( mc, s1 ) ->
                    ( Mono.Leaf mc, s1 )

        TOpt.Chain testChain success failure ->
            case
                Engine.traverse
                    (\( path, test ) sx ->
                        case specializeDtPath root path sx of
                            ( mp, sx1 ) ->
                                ( ( mp, test ), sx1 )
                    )
                    testChain
                    s0
            of
                ( monoTestChain, s1 ) ->
                    case Engine.scoped (specializeDecider caseCanType root success) s1 of
                        ( monoSuccess, s2 ) ->
                            case Engine.scoped (specializeDecider caseCanType root failure) s2 of
                                ( monoFailure, s3 ) ->
                                    ( Mono.Chain monoTestChain monoSuccess monoFailure, s3 )

        TOpt.FanOut path edges fallback ->
            case specializeDtPath root path s0 of
                ( monoPath, s1 ) ->
                    case
                        Engine.traverse
                            (\( test, dec ) sx ->
                                case Engine.scoped (specializeDecider caseCanType root dec) sx of
                                    ( md, sx1 ) ->
                                        ( ( test, md ), sx1 )
                            )
                            edges
                            s1
                    of
                        ( monoEdges, s2 ) ->
                            case Engine.scoped (specializeDecider caseCanType root fallback) s2 of
                                ( monoFallback, s3 ) ->
                                    ( Mono.FanOut monoPath monoEdges monoFallback, s3 )


specializeChoice : Can.Type TypeIds.MVarId -> TOpt.Choice TypeIds.MVarId -> Step Mono.MonoChoice
specializeChoice caseCanType choice s0 =
    case choice of
        TOpt.Inline expr ->
            -- Connect the result's type to the case's own type first (demand flow
            -- into branch results, as in the If arm).
            case translate expr (connectTypes (TOpt.typeOf expr) caseCanType s0) of
                ( me, s1 ) ->
                    ( Mono.Inline me, s1 )

        TOpt.Jump index ->
            ( Mono.Jump index, s0 )


specializeJumps : Can.Type TypeIds.MVarId -> List ( Int, TOpt.Expr TypeIds.MVarId ) -> Step (List ( Int, Mono.MonoExpr ))
specializeJumps caseCanType jumps s0 =
    Engine.traverse
        (\( idx, expr ) sx ->
            case Engine.scoped (\sy -> translate expr (connectTypes (TOpt.typeOf expr) caseCanType sy)) sx of
                ( me, sx1 ) ->
                    ( ( idx, me ), sx1 )
        )
        jumps
        s0


{-| SHADOW MEASUREMENT (plans/lss-ctor-arrow-identity.md §9.2): at a `case`,
does anyone actually KNOW what the storeless classification stamped ⊤?

`classify` (Store.classifyGo's `Can.TLambda` arm) stamps ⊤ on every arrow by
construction, and that is the sole manufacturer of the whole `declStoreS`
class — 1,233 positions, 58 % of the residual ⊤. Whether repairing it is
worth anything depends entirely on whether a BETTER answer exists at that
moment: a ⊤ that becomes `var` is still uncovered, only relabelled.

The branches are the candidate source — `specializeJumps` already
`connectTypes`-es each branch to the case's canonical type, and
`inferCaseType` already prefers a branch's type when the classification
carries residual MVars. This census asks the annotation-level version of the
same question, comparing the classified type against each translated branch
position-wise: `caseanno|<classified>|<branch>` cells, e.g. `top|k1` = the
branch NAMES a single inhabitant the case result threw away.

Pure and report-gated: it reads two MonoTypes that already exist, mints
nothing, and cannot perturb the compile.

-}
caseAnnoCensus : Mono.MonoType -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Engine.S -> Engine.S
caseAnnoCensus classified decider jumps s =
    if not s.env.lss.report then
        s

    else
        -- BOTH branch homes: a simple case inlines its arms into the DECIDER
        -- (`Mono.Inline`) and leaves `jumps` empty, so a jumps-only walk sees
        -- almost nothing (measured: 2 cells across the whole self-compile).
        deciderAnnoFold classified
            decider
            (List.foldl (\( _, e ) acc -> annoPairFold classified (Mono.typeOf e) acc) s jumps)


deciderAnnoFold : Mono.MonoType -> Mono.Decider Mono.MonoChoice -> Engine.S -> Engine.S
deciderAnnoFold classified decider s =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            annoPairFold classified (Mono.typeOf e) s

        Mono.Leaf (Mono.Jump _) ->
            s

        Mono.Chain _ yes no ->
            deciderAnnoFold classified no (deciderAnnoFold classified yes s)

        Mono.FanOut _ edges def ->
            List.foldl (\( _, d ) acc -> deciderAnnoFold classified d acc)
                (deciderAnnoFold classified def s)
                edges


annoPairFold : Mono.MonoType -> Mono.MonoType -> Engine.S -> Engine.S
annoPairFold =
    annoPairFoldWith "caseanno"


annoPairFoldWith : String -> Mono.MonoType -> Mono.MonoType -> Engine.S -> Engine.S
annoPairFoldWith prefix a b s =
    case ( a, b ) of
        ( Mono.MFunction _ annoA argsA retA, Mono.MFunction _ annoB argsB retB ) ->
            if List.length argsA == List.length argsB then
                List.foldl (\( x, y ) acc -> annoPairFoldWith prefix x y acc)
                    (annoPairFoldWith prefix retA retB (bumpAnnoCell prefix annoA annoB s))
                    (List.map2 Tuple.pair argsA argsB)

            else
                s

        ( Mono.MList _ xa, Mono.MList _ xb ) ->
            annoPairFoldWith prefix xa xb s

        ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
            if List.length xsa == List.length xsb then
                List.foldl (\( x, y ) acc -> annoPairFoldWith prefix x y acc) s (List.map2 Tuple.pair xsa xsb)

            else
                s

        ( Mono.MRecord _ fa, Mono.MRecord _ fb ) ->
            Dict.foldl
                (\k va acc ->
                    case Dict.get k fb of
                        Just vb ->
                            annoPairFoldWith prefix va vb acc

                        Nothing ->
                            acc
                )
                s
                fa

        ( Mono.MCustom _ _ _ xsa, Mono.MCustom _ _ _ xsb ) ->
            if List.length xsa == List.length xsb then
                List.foldl (\( x, y ) acc -> annoPairFoldWith prefix x y acc) s (List.map2 Tuple.pair xsa xsb)

            else
                s

        _ ->
            s


bumpAnnoCell : String -> Mono.LambdaSetAnno -> Mono.LambdaSetAnno -> Engine.S -> Engine.S
bumpAnnoCell prefix a b s =
    Engine.bumpArgFlowCensus (prefix ++ "|" ++ annoCellLabel a ++ "|" ++ annoCellLabel b) s


{-| §9.4: THE destructor measurement. `specializeDestructor` computes two
types for the same position side by side —

  - `classified` = `classifyAs tkClassDestr meta.tipe`, the storeless answer,
    ⊤ at every arrow by construction. This is the one it keeps, and §9.3
    attributes 82 % of all surviving decl ⊤ to it.
  - `projected` = `Mono.getMonoPathType monoPath`, the destructured position
    reached by projecting the ROOT local's `varEnv`-bound MonoType down the
    path (`projIndexType` / field lookup). The root's bound type is whatever
    its binder recorded — which for a value constructed in this item carries
    real members.

If `projected` names inhabitants where `classified` says ⊤, the information
is present at the exact moment it is discarded and a repair is worth
building. If both are ⊤/var, the destructor is innocent and the loss is
upstream. Cells: `destranno|<classified>|<projected>`. Pure, report-gated.

-}
destrAnnoCensus : Mono.MonoType -> Mono.MonoType -> Engine.S -> Engine.S
destrAnnoCensus classified projected s =
    if not s.env.lss.report then
        s

    else
        annoPairFoldWith "destranno" classified projected s


{-| §9.6 step 4 — Fix B's P0, the TRANSLATION-TIME half. At a destructor
whose outermost step projects a ctor field, compare the classified type
against the UNION (set-biased, `enrichAnnotations`-folded — a ⊤ contributes
nothing) of the SAME field position across every registry entry of that ctor
global. `destrBnow|top|k1` = a translation-time read of the sibling demands
would already recover a singleton here; the end-of-run half (`destrBend:`
in the census report) gives the order-free ceiling, and the gap between the
two is the price of reading early. Report-gated; the registry scan runs only
at ⊤-carrying ctor-field destructors.
-}
destrBNowCensus : Mono.MonoType -> Mono.MonoPath -> Engine.S -> Engine.S
destrBNowCensus classified monoPath s =
    if not (s.env.lss.report && Mono.hasTopAnno classified) then
        s

    else
        case monoPath of
            Mono.MonoIndex fieldIx (Mono.CustomContainer ctorName) _ subPath ->
                case Mono.getMonoPathType subPath of
                    Mono.MCustom _ ctorHome _ _ ->
                        case ctorFieldUnion ctorHome ctorName fieldIx s of
                            Just unionT ->
                                annoPairFoldWith "destrBnow" classified unionT s

                            Nothing ->
                                Engine.bumpArgFlowCensus "destrBnow|noEntries" s

                    _ ->
                        s

            _ ->
                s


{-| Set-biased union of field `i`'s type across every registry entry keyed by
the ctor global. Ctor demand types are curried (one arrow per MFunction), so
field `i` is the head argument after peeling `i` arrows. Shape mismatches
between differently-instantiated specs fall back to the accumulator
(`enrichAnnotations` keeps the structural side) — an UNDER-approximation,
which is the safe direction for a GO/NO-GO floor.
-}
ctorFieldUnion : ModuleName.Canonical -> Name -> Int -> Engine.S -> Maybe Mono.MonoType
ctorFieldUnion ctorHome ctorName fieldIx s =
    let
        gkey =
            Mono.toComparableGlobal (Mono.Global ctorHome ctorName)
    in
    List.foldl
        (\specId acc ->
            case Array.get specId s.registry.reverseMapping of
                Just (Just ( _, t )) ->
                    case ctorFieldAt fieldIx t of
                        Just ft ->
                            case acc of
                                Just u ->
                                    Just (Mono.enrichAnnotations u ft)

                                Nothing ->
                                    Just ft

                        Nothing ->
                            acc

                _ ->
                    acc
        )
        Nothing
        (Engine.specIdsForGlobal gkey s)


ctorFieldAt : Int -> Mono.MonoType -> Maybe Mono.MonoType
ctorFieldAt i t =
    case t of
        Mono.MFunction _ _ (a :: _) r ->
            if i <= 0 then
                Just a

            else
                ctorFieldAt (i - 1) r

        _ ->
            Nothing


annoCellLabel : Mono.LambdaSetAnno -> String
annoCellLabel anno =
    case anno of
        Mono.LSet [ _ ] ->
            "k1"

        Mono.LSet _ ->
            "kN"

        Mono.LVar _ ->
            "var"

        Mono.LTop _ ->
            "top"

        Mono.LPartial _ ->
            "part"


{-| The case's MonoType when the storeless classification carries residual
MVars: the STRUCTURE of the first branch (jumps first, then the decider's
inline leaves, then the fallback), with the lambda-set annotations JOINED over
every branch by `joinBranchTypes`.

Before 2026-09-11 this returned the first branch's MonoType verbatim,
annotations included. That is a soundness hole (/work/eta-fixed-point-root-cause.md):
a `case` whose branches are `succeed ()` — a PAP of a global, `LSet [p|…]` —
and an `andThen … (loadType …)` call whose result arrow reads back ⊤/var made
the whole case `LSet [p|…]`, the consumer keyed its `andThen` instance on that
singleton, and E9.5 fast-stamped `step s` to `succeed`'s evaluator — which then
ran on the other branch's closure and silently skipped its state effect (the
census cell `caseanno|top|k1` next to `caseanno|top|top` is exactly this shape).
The store cannot catch it: each branch is unified INTO the case's slot, so the
class content is whatever the set-bearing branch wrote.

-}
inferCaseType : List ( Int, Mono.MonoExpr ) -> Mono.Decider Mono.MonoChoice -> Mono.MonoType -> Mono.MonoType
inferCaseType jumps decider fallback =
    case List.map (\( _, e ) -> Mono.typeOf e) jumps ++ deciderLeafTypes decider of
        first :: rest ->
            List.foldl (\t acc -> joinBranchTypes acc t) first rest

        [] ->
            fallback


{-| Every `Inline` leaf's MonoType, in decider order (yes before no, edges
before the default) — the same homes `caseAnnoCensus` walks.
-}
deciderLeafTypes : Mono.Decider Mono.MonoChoice -> List Mono.MonoType
deciderLeafTypes decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            [ Mono.typeOf e ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ yes no ->
            deciderLeafTypes yes ++ deciderLeafTypes no

        Mono.FanOut _ edges def ->
            List.concatMap (\( _, d ) -> deciderLeafTypes d) edges ++ deciderLeafTypes def


{-| Join the lambda-set annotations of two branch MonoTypes position-wise,
keeping `acc`'s structure (the branches' structures agree by typing; on any
shape disagreement `acc` is kept as-is, exactly as `Mono.overlayAnnotations`
does).

Per position the rule is `Mono.unionAnno` — set ∪ set = union, set ∪ var =
`LPartial` (a lower bound, refused by every stamp guard and re-entering the
store as flex), ⊤ absorbs — EXCEPT that two non-set labels keep the first
branch's label rather than joining: `LVar i ∪ LVar j` would manufacture a
conflict-⊤ out of two zonks' independent var numbering, and neither var nor ⊤
is stampable, so nothing is gained by widening them. The only labels this join
ever changes are the stampable ones, and it only ever weakens them.

-}
joinBranchTypes : Mono.MonoType -> Mono.MonoType -> Mono.MonoType
joinBranchTypes acc next =
    case ( acc, next ) of
        ( Mono.MFunction _ annoA argsA retA, Mono.MFunction _ annoB argsB retB ) ->
            if List.length argsA == List.length argsB then
                Mono.mFunction (joinBranchAnno annoA annoB) (List.map2 joinBranchTypes argsA argsB) (joinBranchTypes retA retB)

            else
                acc

        ( Mono.MList _ xa, Mono.MList _ xb ) ->
            Mono.mList (joinBranchTypes xa xb)

        ( Mono.MTuple _ xsa, Mono.MTuple _ xsb ) ->
            if List.length xsa == List.length xsb then
                Mono.mTuple (List.map2 joinBranchTypes xsa xsb)

            else
                acc

        ( Mono.MRecord _ fieldsA, Mono.MRecord _ fieldsB ) ->
            if Dict.keys fieldsA == Dict.keys fieldsB then
                Mono.mRecord (Dict.map (\k ta -> joinBranchTypes ta (Maybe.withDefault ta (Dict.get k fieldsB))) fieldsA)

            else
                acc

        ( Mono.MCustom _ homeA nameA argsA, Mono.MCustom _ homeB nameB argsB ) ->
            if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                Mono.mCustom homeA nameA (List.map2 joinBranchTypes argsA argsB)

            else
                acc

        _ ->
            acc


joinBranchAnno : Mono.LambdaSetAnno -> Mono.LambdaSetAnno -> Mono.LambdaSetAnno
joinBranchAnno acc next =
    case ( acc, next ) of
        ( Mono.LSet _, _ ) ->
            Mono.unionAnno acc next

        ( _, Mono.LSet _ ) ->
            Mono.unionAnno acc next

        ( Mono.LPartial _, _ ) ->
            Mono.unionAnno acc next

        ( _, Mono.LPartial _ ) ->
            Mono.unionAnno acc next

        _ ->
            -- (var | ⊤) × (var | ⊤): the first branch's label, as before.
            acc


specializeDtPath : Name -> TypedPath.Path -> Step Mono.MonoDtPath
specializeDtPath root path s0 =
    case path of
        TypedPath.Empty ->
            case Engine.lookupVar root s0 of
                ( Just t, s1 ) ->
                    ( Mono.DtRoot root t, s1 )

                ( Nothing, s1 ) ->
                    ( Engine.crashFailure (EngineBug ("case root not in varEnv: " ++ root)), s1 )

        TypedPath.Index index hint subPath ->
            case specializeDtPath root subPath s0 of
                ( monoSubPath, s1 ) ->
                    let
                        i =
                            Index.toMachine index
                    in
                    case projIndexType (dtHintToProj hint) i (Mono.dtPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.DtIndex i (dtHintToKind hint) resultType monoSubPath, s2 )

        TypedPath.Unbox subPath ->
            case specializeDtPath root subPath s0 of
                ( monoSubPath, s1 ) ->
                    case computeUnboxResultType (Mono.dtPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.DtUnbox resultType monoSubPath, s2 )



-- ====== DESTRUCTURE ======


specializeDestructor : TOpt.Destructor TypeIds.MVarId -> Step Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path meta) s0 =
    case specializePath path s0 of
        ( monoPath, sP ) ->
            case classifyAs Mono.tkClassDestr meta.tipe sP of
                ( monoType0, sD ) ->
                    let
                        -- Destructor annotations
                        -- (plans/lss-ctor-arrow-identity.md §9.5). Shipped as
                        -- `lss.destrAnno`, default-ON 2026-08-31, and
                        -- unconditional since 2026-09-18:
                        --
                        -- FIX A: the projected type (the root's varEnv type
                        -- pushed down the path) carries type-argument-borne
                        -- sets the storeless classify discards — the
                        -- paper's TIU substitution through the ctor's
                        -- instantiated scheme. FIX B: syntactic payload
                        -- arrows (invisible to the projection) recover from
                        -- the set-biased union of the ctor global's spec
                        -- demands — the paper's single global-store
                        -- solution, reassembled; union can only WIDEN
                        -- (AR-D2), and the P0 measured the translation-time
                        -- read at 98.6 % of the order-free ceiling.
                        -- Both merges are precision-monotone
                        -- (`enrichAnnotations`): sets win, sets union, ⊤
                        -- never absorbs, structure untouched (MONO_029).
                        -- An early read that misses leaves today's ⊤ —
                        -- sound, monotone across the fixpoint.
                        -- FIX A ONLY here. The union read (Fix B) was
                        -- originally at this site and is now at the
                        -- POST-DRAIN settle (Monomorphize.settleCtorRows):
                        -- the fixture differential caught a translation-time
                        -- read seeing a PARTIAL union — a set stamped from
                        -- it EXCLUDES constructions that have not happened
                        -- yet, i.e. the arrowSolverRoots false-singleton
                        -- class (§9.8). AR-D2's soundness argument requires
                        -- the COMPLETE union, which only the settle has.
                        -- The projection (Fix A) is per-value — the root's
                        -- own flow — and stays.
                        monoType =
                            if not (sD.env.lss.enabled && Mono.hasTopAnno monoType0) then
                                monoType0

                            else
                                Mono.enrichAnnotations monoType0 (Mono.getMonoPathType monoPath)

                        sD1 =
                            destrBNowCensus monoType0
                                monoPath
                                (destrAnnoCensus monoType0 (Mono.getMonoPathType monoPath) sD)
                    in
                    ( Mono.MonoDestructor name monoPath monoType, sD1 )


specializePath : TOpt.Path -> Step Mono.MonoPath
specializePath path s0 =
    case path of
        TOpt.Root name ->
            case Engine.lookupVar name s0 of
                ( Just t, s1 ) ->
                    ( Mono.MonoRoot name t, s1 )

                ( Nothing, s1 ) ->
                    ( Engine.crashFailure (EngineBug ("destruct root not in varEnv: " ++ name)), s1 )

        TOpt.Index index hint subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    let
                        i =
                            Index.toMachine index
                    in
                    case projIndexType (hintToProj hint) i (Mono.getMonoPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.MonoIndex i (hintToKind hint) resultType monoSubPath, s2 )

        TOpt.ArrayIndex idx subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    case computeArrayElementType (Mono.getMonoPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath, s2 )

        TOpt.Field fieldName subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    case Mono.getMonoPathType monoSubPath of
                        Mono.MRecord _ fields ->
                            case Dict.get fieldName fields of
                                Just t ->
                                    ( Mono.MonoField fieldName t monoSubPath, s1 )

                                Nothing ->
                                    ( Engine.crashFailure (EngineBug ("field not in record: " ++ fieldName)), s1 )

                        _ ->
                            ( Engine.crashFailure (EngineBug "field projection: container not Mono.mRecord"), s1 )

        TOpt.Unbox subPath ->
            case specializePath subPath s0 of
                ( monoSubPath, s1 ) ->
                    case computeUnboxResultType (Mono.getMonoPathType monoSubPath) s1 of
                        ( resultType, s2 ) ->
                            ( Mono.MonoUnbox resultType monoSubPath, s2 )



-- ====== PROJECTION-TYPE COMPUTATION ======


type ProjKind
    = PList
    | PTuple
    | PCustom Name


projIndexType : ProjKind -> Int -> Mono.MonoType -> Step Mono.MonoType
projIndexType kind index container s0 =
    case kind of
        PList ->
            case container of
                Mono.MList _ elem ->
                    -- index 0 = head → element; otherwise = tail → the list itself
                    if index == 0 then
                        ( elem, s0 )

                    else
                        ( container, s0 )

                _ ->
                    ( Engine.crashFailure (EngineBug "list projection: container not Mono.mList"), s0 )

        PTuple ->
            case container of
                Mono.MTuple _ elems ->
                    case List.head (List.drop index elems) of
                        Just t ->
                            ( t, s0 )

                        Nothing ->
                            ( Engine.crashFailure (EngineBug "tuple projection: index out of range"), s0 )

                _ ->
                    ( Engine.crashFailure (EngineBug "tuple projection: container not Mono.mTuple"), s0 )

        PCustom ctorName ->
            computeCustomFieldType ctorName index container s0


computeArrayElementType : Mono.MonoType -> Step Mono.MonoType
computeArrayElementType container s0 =
    case container of
        Mono.MCustom _ _ "Array" [ elem ] ->
            ( elem, s0 )

        _ ->
            ( Engine.crashFailure (EngineBug "array projection: container not Array"), s0 )


computeCustomFieldType : Name -> Int -> Mono.MonoType -> Step Mono.MonoType
computeCustomFieldType ctorName index container s0 =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion s0.env.globalTypeEnv home typeName of
                Just (Can.Union unionData) ->
                    case findCtorArg ctorName index unionData.alts of
                        Just canArgType ->
                            instantiateUnionType unionData.vars typeArgs canArgType s0

                        Nothing ->
                            ( Engine.crashFailure (EngineBug ("ctor field not found: " ++ ctorName ++ "@" ++ String.fromInt index)), s0 )

                Nothing ->
                    ( Engine.crashFailure (EngineBug ("union not found: " ++ typeName)), s0 )

        _ ->
            ( Engine.crashFailure (EngineBug "custom field projection: container not Mono.mCustom"), s0 )


computeUnboxResultType : Mono.MonoType -> Step Mono.MonoType
computeUnboxResultType container s0 =
    case container of
        Mono.MCustom _ home typeName typeArgs ->
            case Analysis.lookupUnion s0.env.globalTypeEnv home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ canArgType ] ->
                                    instantiateUnionType unionData.vars typeArgs canArgType s0

                                _ ->
                                    ( Engine.crashFailure (EngineBug "unbox: constructor is not single-arg"), s0 )

                        _ ->
                            ( Engine.crashFailure (EngineBug "unbox: type is not single-constructor"), s0 )

                Nothing ->
                    ( Engine.crashFailure (EngineBug ("unbox: union not found: " ++ typeName)), s0 )

        _ ->
            ( Engine.crashFailure (EngineBug "unbox: container not Mono.mCustom"), s0 )


findCtorArg : Name -> Int -> List Can.Ctor -> Maybe (Can.Type Name)
findCtorArg ctorName index alts =
    case List.filter (\(Can.Ctor c) -> c.name == ctorName) alts of
        (Can.Ctor c) :: _ ->
            List.head (List.drop index c.args)

        [] ->
            Nothing


{-| Instantiate a union constructor's declared field type: map the union's
type-param names to the container's concrete type args, convert to MVarIds, and
classify. Mirrors the original engine's field-type computation without importing
its `applySubstPure`.
-}
instantiateUnionType : List Name -> List Mono.MonoType -> Can.Type Name -> Step Mono.MonoType
instantiateUnionType vars typeArgs canArgType s0 =
    case allocFreshIds (List.length vars) s0 of
        ( ids, s1 ) ->
            let
                nameToId =
                    Dict.fromList (List.map2 Tuple.pair vars ids)

                subst =
                    Dict.fromList (List.map2 (\id t -> ( Id.toComparable id, t )) ids typeArgs)

                convertedArg =
                    Analysis.convertCanTypeNameToMVarId nameToId canArgType

                ( mt, intern1 ) =
                    Zonk.canTypeToMonoWithI s1.superTable subst convertedArg s1.intern
            in
            ( mt, { s1 | intern = intern1 } )


allocFreshIds : Int -> Step (List TypeIds.MVarId)
allocFreshIds n s0 =
    Engine.traverse (\_ -> allocFreshId) (List.repeat n ()) s0


allocFreshId : Step TypeIds.MVarId
allocFreshId =
    \s -> ( s.nextMVarId, { s | nextMVarId = Id.succ s.nextMVarId } )


hintToKind : TOpt.ContainerHint -> Mono.ContainerKind
hintToKind hint =
    case hint of
        TOpt.HintList ->
            Mono.ListContainer

        TOpt.HintTuple2 ->
            Mono.Tuple2Container

        TOpt.HintTuple3 ->
            Mono.Tuple3Container

        TOpt.HintCustom name ->
            Mono.CustomContainer name


hintToProj : TOpt.ContainerHint -> ProjKind
hintToProj hint =
    case hint of
        TOpt.HintList ->
            PList

        TOpt.HintTuple2 ->
            PTuple

        TOpt.HintTuple3 ->
            PTuple

        TOpt.HintCustom name ->
            PCustom name


dtHintToKind : TypedPath.ContainerHint -> Mono.ContainerKind
dtHintToKind hint =
    case hint of
        TypedPath.HintList ->
            Mono.ListContainer

        TypedPath.HintTuple2 ->
            Mono.Tuple2Container

        TypedPath.HintTuple3 ->
            Mono.Tuple3Container

        TypedPath.HintCustom name ->
            Mono.CustomContainer name

        TypedPath.HintUnknown ->
            Mono.CustomContainer ""


dtHintToProj : TypedPath.ContainerHint -> ProjKind
dtHintToProj hint =
    case hint of
        TypedPath.HintList ->
            PList

        TypedPath.HintTuple2 ->
            PTuple

        TypedPath.HintTuple3 ->
            PTuple

        TypedPath.HintCustom name ->
            PCustom name

        TypedPath.HintUnknown ->
            PCustom ""



-- ====== HELPERS ======


lookupAnnotation : TOpt.Global -> Step (Maybe (Can.Annotation TypeIds.MVarId))
lookupAnnotation global s =
    ( DMap.get TOpt.toComparableGlobal global s.env.annotations, s )


toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


nodeKind : TOpt.Expr TypeIds.MVarId -> String
nodeKind expr =
    case expr of
        TOpt.Function _ _ _ _ ->
            "closure/lambda (M4)"

        TOpt.TrackedFunction _ _ _ _ ->
            "closure/lambda (M4)"

        TOpt.Case _ _ _ _ _ ->
            "case/decision-tree (M3)"

        TOpt.Accessor _ _ _ ->
            "accessor (M3)"

        TOpt.Destruct _ _ _ ->
            "destructure (M3)"

        TOpt.VarDebug _ _ _ _ _ ->
            "Debug reference (M6)"

        TOpt.VarCycle _ _ _ _ ->
            "cycle reference (M6)"

        TOpt.Shader _ _ _ _ ->
            "shader (M6)"

        _ ->
            "expression"
