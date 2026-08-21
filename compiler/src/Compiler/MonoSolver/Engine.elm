module Compiler.MonoSolver.Engine exposing
    ( S, Env, Step, Failure(..), WorkItem(..), NumberMultiEntry, NumberInstance, NodeResolution
    , ArrowFact, LssSignature, LssStats
    , succeed, fail, andThen, map, map2, traverse, foldlS
    , getS, modifyS, liftIO, runStep
    , freshVar, enqueueSpec
    , freshStore, resetItem, harvestSuperTable, harvestSuperTableExcept
    , insertVar, lookupVar, scoped
    , pushNumberMulti, popNumberMulti, isNumberMultiTarget, recordNumberInstance, numberMultiRootType
    , pushLocalMulti, popLocalMulti, isLocalMultiTarget, recordLocalInstance, localVarInfo
    , MonoMemo, emptyMonoMemo
    , lookupSchemeMono, putSchemeMono
    , lookupCallMemo, putCallMemo
    , consS
    , mvarIdKey, pointKey, isScalarVar
    , memberIdFor, standaloneMemberIdFor, standaloneMemberGlobal, kernelMemberIdFor, standaloneMemberKernel, srcLambdaKey, trivialSignature, emptyLssStats
    , lambdaInstanceMemberId, lambdaInstanceMemberMaybe
    , GroundingStats, internMemberKey, groundStandaloneMemberIdFor, groundSetMembers
    , LssMemberTable, MemberSource(..), emptyMemberTable
    , bumpWidenedByKernel, bumpWidenedBySigSize, bumpWidenedByCf, bumpKernelFactHit, bumpKernelLicensed, bumpEdgeInstalled, bumpFlowDegraded, bumpCompletionJoin, bumpCompletionJoinNoop, withScratchStore
    , SigFlowStats
    , markDirty
    , ItemAux, emptyItemAux, clearedAux, restoredAux, clearResidualReads
    )

{-| Core state + step monad for the solver-based monomorphizer.

`S` is one record threading BOTH the global monomorphization state (worklist,
registry, nodes, …) and the per-work-item solver state (the union-find `store`
plus the `memo` mapping MVarIds to union-find Points). `Step a = S -> Result
Failure (a, S)` is a state monad with a failure short-circuit: a `Failure`
aborts the whole monomorphization with a loud `Err` (no fallback to the
original engine — see the module doc of `Compiler.MonoSolver.Monomorphize`).

@docs S, Step, Failure, WorkItem
@docs succeed, fail, andThen, map, map2, traverse, foldlS
@docs getS, modifyS, liftIO, runStep
@docs freshVar, enqueueSpec
@docs freshStore, resetItem
@docs mvarIdKey, pointKey

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern exposing (Intern)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.Registry as Registry
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Map as DMap
import Data.Set as EverySet
import Dict as CoreDict exposing (Dict)
import System.TypeCheck.IO as IO



-- ====== STATE ======


{-| A unit of pending work: specialize the definition behind this SpecId.
-}
type WorkItem
    = SpecializeGlobal Mono.SpecId


{-| One annotation arrow's LSS facts (design §7.1):

  - `rep`: smallest ordinal whose set slot the body unified with this one
    (the "same α at two positions" linkage, e.g. `twice : (a -> a) -> a -> a`
    sharing its two arrows).
  - `members`: ids the body itself injects into this arrow's set.
  - `top`: the body forces ⊤ (e.g. the arrow reaches a kernel boundary).
  - `sources` (LSS_023): ordinals whose sets flow INTO this one — the
    DIRECTED half of the fact language. `rep` stays genuine UF-equality
    (same-value chains: for `pass f = f` the param and result ARE one
    value); `sources` is inclusion, applied by the caller as deferred
    `Store.addSlotSource` edges and resolved at read. This is the paper's
    promoted-`ᾱ` half of promote-or-internalize (Fig. 7): a reached
    signature ordinal is PROMOTED here; a reached non-signature slot is
    INTERNALIZED into `members`.

-}
type alias ArrowFact =
    { rep : Int
    , members : List Int
    , top : Bool
    , sources : List Int
    }


{-| Per-definition lambda-set signature: the facts a caller must apply to the
arrows of a fresh instantiation of the def's annotation type, indexed by
ARROW ORDINAL — position in the slot array minted by
`Store.loadTypeIsolatedWithArrows`/`loadTypeWithArrows` over the SAME
annotation type (LSS_006).
-}
type alias LssSignature =
    { arrows : Array ArrowFact
    , trivial : Bool -- every fact is {rep=self, members=[], top=False}
    }


{-| LSS census counters (rendered by the report, `lss.report`).
-}
type alias LssStats =
    { setsZonked : Int
    , joinRounds : Int -- LSS_010 drain-end flush rounds
    , retranslations : Int -- specs re-translated across all flush rounds
    , widenedBySize : Int
    , widenedByKernel : Int
    , widenedByBudget : Int
    , devirtDirect : Int -- E9 (LSS_015): singleton-ctor indirect calls rewritten to direct ctor calls
    , devirtKernel : Int -- E9.2 (LSS_016): singleton whitelisted-kernel indirect calls rewritten to direct kernel calls
    , sizeHist : CoreDict.Dict Int Int -- set size -> count (post-zonk)
    , unqualifiedLambdaMints : Int -- Fix B (LSS_017): translation-phase lambda-instance mints under keyed routing with no current spec id (expected 0; nonzero = a mint site outside any work item)

    -- Census (2026-07-21, plans/lss-dispatch-value-extraction.md open
    -- questions): the E9.2 kernel-devirt guard-decline split (E10.0's
    -- `declinedUnsettled` proxy = the CNumber bucket) + the whitelist-growth
    -- shopping list. Stats-only — never touches the graph.
    , declinedKernelShape : Int -- kernel devirt declined by the SHAPE guard (site type not the whitelist entry's true shape)
    , declinedKernelCNumber : Int -- declined by the deep-CNumber emission checks (residual number vars = UNSETTLED site; the E10.0 population)
    , declinedKernelEmission : Int -- declined by the non-CNumber emission checks (unboxed-scalar tail/result, arg shape)
    , declinedKernelArity : Int -- whitelisted kernel singleton consulted at a non-whitelist-arity site
    , kernelUnsolvedHist : CoreDict.Dict String Int -- ONE-SHOT CENSUS (kernel-intrinsic-annotations): LICENSED kernels whose occurrence verification was REFUSED — i.e. exactly where an intrinsic annotation would pay
    , kernelMissHist : CoreDict.Dict String Int -- NON-whitelisted kernel singleton call sites, "home.name" -> count (whitelist growth)

    -- Substrate census (Phase 1 of plans/lss-set-write-substrate.md). Stats
    -- only — never touches the graph. These size the substrate work: the
    -- set-write split says how much of the write path the E9.3 fast paths
    -- already cover (`setWriteSlow` ≈ 0 is the evidence to delete the
    -- defensive slow arm), the join split separates the wasted rebuild-and-
    -- discard population from real widening, and `widenedSizeHist` records
    -- the magnitudes the `widenedBySize` counter throws away.
    , setWriteSkip : Int -- unifySlotWithSet: no-op (⊤-absorb, or members already ⊆ slot)
    , setWriteFlex : Int -- unifySlotWithSet: adopted content into an unconstrained FlexVar slot
    , setWriteTopJoin : Int -- unifySlotWithSet: ⊤ write onto an LsMembers slot — direct set of the shared constant (Phase 2; was slow)
    , setWriteUnion : Int -- unifySlotWithSet: real member union onto an LsMembers slot — direct root join (Phase 2; was slow)
    , setWriteSlow : Int -- unifySlotWithSet: the DEFENSIVE arm only (non-FlexVar, non-LambdaSet1 content) — expected 0; sustained 0 is the licence to delete it
    , joinIdenticalHit : Int -- keyed registry hit, demand bit-identical to the stored type (no join ran)
    , joinNoop : Int -- keyed registry hit, join ran and changed nothing (rebuilt tree discarded)
    , joinChanged : Int -- keyed registry hit, join widened the stored type (drives markDirty)
    , completionJoins : Int -- processItem completion joins (one per body-bearing spec)
    , completionJoinNoop : Int -- Phase 4a: the subset of those that added nothing (changed flag False — no rebuild)
    , widenedSizeHist : CoreDict.Dict Int Int -- SIZE -> count for sets widened by size at zonk (sizeHist is blind on that branch)
    , slotsMinted : Int -- Phase 3 rider: unconstrained FunL slot mints in loadTypeC (LSS_006 population; demand-encoded slots excluded by design — they are born written). Sizes Phase 5's dead-slot case against writes/zonk-visits.
    , grounding : GroundingStats -- LSS_019 census (plans/lss-fidelity-2-standalone-member-grounding.md §5); sub-record to stay clear of the 32-slot record GC-scan cap
    , sigStats : SigFlowStats -- LSS_020 signature-flow census (plans/lss-fidelity-3-signature-flow-completion.md §B.4); sub-record per the same 32-slot rationale
    }


{-| LSS_019 grounding census: `grounded` counts provisional→ground member
rewrites at zonk; `deferred` counts provisional members kept because the
arrow being read still carried residual MVars (the recorded precision
frontier — §3.2 detail 1 of the plan). Stats only — never touches the graph.
-}
type alias GroundingStats =
    { grounded : Int
    , deferred : Int
    }


{-| LSS_020 signature-flow census (plan lss-fidelity-3 §B.4).

`widenedBySigSize` is a POLICY counter (a signature arrow's member list
exceeded `maxSetSize` at readback and widened to ⊤) — bumped
unconditionally, same class as `widenedBySize`/`widenedByKernel`.
`widenedByCf` counts poison events inside the sigFlow joins (hub poisons +
divergence in the new member-root/result/rhs/call-shape joins),
`kernelFactHits` counts Phase F POSITIONAL fact-row applications and
`kernelLicensed` (LSS_022) counts boundaries that took the licensed
`TypeFaithful` pass-through — all census-only and therefore REPORT-GATED per
plan 1 §7.6 (the bump helpers check `env.lss.report`; the default path
carries only a branch).

The two kernel counters partition the fact-bearing boundaries: a boundary
bumps `kernelFactHits` (positional tier) or `kernelLicensed` (license tier),
never both, and a rowless boundary bumps neither. `widenedByKernel` keeps its
own meaning — boundaries that actually poisoned — so licensed boundaries
stop bumping it entirely (plan §3.4).
-}
type alias SigFlowStats =
    { widenedBySigSize : Int
    , widenedByCf : Int
    , kernelFactHits : Int
    , kernelLicensed : Int
    , edgesInstalled : Int -- LSS_023 directed edges installed (report-gated)
    , flowDegraded : Int -- LSS_023 container subtrees degraded to symmetric AND capable of carrying a set (report-gated)
    }



-- The lss-fidelity-1 one-shot census counters (fidelity.muTied /
-- widenedByLet / localMultiBypass) were REMOVED 2026-08-18 after their
-- deliverable run (benchmarks/lss-opt.md Run J: 0 / 672 / 469) so the
-- default path carries only implementation cost. The μ-tie's live
-- monitoring signal is derived free at report time from
-- lssMemberTable.muTied (set size) + AbiCloning's declinedBlocked.
-- Re-instrument per plans/lss-fidelity-1-watchdogs-budget-accounting.md §7
-- if a new census is ever needed.


{-| What a standalone member REFERS to. A member id is a global/ctor or a
kernel, never both, so the two reverse maps are arms of one sum rather than
two dicts over the same id space — one tree, and `buildMemberOrigins`'s
prefix dispatch reads it with a single lookup.
-}
type MemberSource
    = SourceGlobal TOpt.Global
    | SourceKernel ( String, String, String )


{-| Interned non-lambda member ids (§3.3 keys) + the E9/E9.2 standalone
reverse map. One S field for both: the engine self-hosts and `S` must stay
within the native runtime's 32-slot record GC-scan cap (HEAP invariant) —
adding a 33rd top-level field to `S` fails the backend verifier on the
self-compile.
-}
type alias LssMemberTable =
    { byKey : CoreDict.Dict String Int
    , sources : CoreDict.Dict Int MemberSource
    , lambdaQualified : CoreDict.Dict Int ( Int, Int ) -- LSS_018: qualified mid -> (raw lambda id, minting SpecId); written at the Q(L,S) intern
    , muTied : CoreDict.Dict Int () -- LSS_018: member ids ever the target of a μ-tie — exported as MonoGraph.lssBlockedMembers (AbiCloning force-blocks them)
    , provisionalStandalone : CoreDict.Dict Int TOpt.Global -- LSS_019: ids minted by standaloneMemberIdFor with a "g|"/"c|" key (NOT kernel-alias-folded, NOT ground). Written at the same intern site; the zonk grounding rewrite consults this to decide "rewrite" vs "pass through". Ground ids are NEVER in this dict — that is what makes grounding idempotent.
    }


{-| The M2 classification memos, GLOBAL (they survive `resetItem`; a
ground/closed classification is item-independent):

  - `schemeMono` — a CLOSED (var-free) callee scheme's classification, keyed by
    `TOpt.toComparableGlobal`;
  - `callMemo` — an open-scheme call at all-ground args:
    `(funcMonoType, resultMonoType, specId)`. D10 caches the specId so a hit
    skips re-enqueue/re-serialize. Keyed by the callee `Global` plus the
    synthetic `args -> result` arrow those types already denote
    (`Mono.SpecKey`), so the probe reads the `specHashOf` Int the node already
    carries and confirms with `eqKeySpec` — NO string is built
    (plans/speckey-optimization.md §10.2).

These are ONE `S` field for the same reason `LssMemberTable` is: the engine
self-hosts and `S` must stay within the native runtime's 32-slot record GC-scan
cap. Grouping them made room for `S.intern` (K6).

-}
type alias MonoMemo =
    { schemeMono : CoreDict.Dict String Mono.MonoType
    , callMemo : Mono.SpecKeyMap ( Mono.MonoType, Mono.MonoType, Mono.SpecId )
    }


emptyMonoMemo : MonoMemo
emptyMonoMemo =
    { schemeMono = CoreDict.empty, callMemo = Mono.specKeyMapEmpty }


emptyMemberTable : LssMemberTable
emptyMemberTable =
    { byKey = CoreDict.empty, sources = CoreDict.empty, lambdaQualified = CoreDict.empty, muTied = CoreDict.empty, provisionalStandalone = CoreDict.empty }


insertMemberKey : String -> Int -> LssMemberTable -> LssMemberTable
insertMemberKey key mid t =
    { t | byKey = CoreDict.insert key mid t.byKey }


insertMemberGlobal : Int -> TOpt.Global -> LssMemberTable -> LssMemberTable
insertMemberGlobal mid g t =
    { t | sources = CoreDict.insert mid (SourceGlobal g) t.sources }


insertMemberKernel : Int -> ( String, String, String ) -> LssMemberTable -> LssMemberTable
insertMemberKernel mid k t =
    { t | sources = CoreDict.insert mid (SourceKernel k) t.sources }


insertMemberProvisional : Int -> TOpt.Global -> LssMemberTable -> LssMemberTable
insertMemberProvisional mid g t =
    { t | provisionalStandalone = CoreDict.insert mid g t.provisionalStandalone }


emptyLssStats : LssStats
emptyLssStats =
    { setsZonked = 0, joinRounds = 0, retranslations = 0, widenedBySize = 0, widenedByKernel = 0, widenedByBudget = 0, devirtDirect = 0, devirtKernel = 0, sizeHist = CoreDict.empty, unqualifiedLambdaMints = 0, declinedKernelShape = 0, declinedKernelCNumber = 0, declinedKernelEmission = 0, declinedKernelArity = 0, kernelUnsolvedHist = CoreDict.empty, kernelMissHist = CoreDict.empty, setWriteSkip = 0, setWriteFlex = 0, setWriteTopJoin = 0, setWriteUnion = 0, setWriteSlow = 0, joinIdenticalHit = 0, joinNoop = 0, joinChanged = 0, completionJoins = 0, completionJoinNoop = 0, widenedSizeHist = CoreDict.empty, slotsMinted = 0, grounding = { grounded = 0, deferred = 0 }, sigStats = { widenedBySigSize = 0, widenedByCf = 0, kernelFactHits = 0, kernelLicensed = 0, edgesInstalled = 0, flowDegraded = 0 } }


{-| The all-defaults signature for an annotation with `n` arrows.
-}
trivialSignature : Int -> LssSignature
trivialSignature n =
    { arrows = Array.initialize n (\i -> { rep = i, members = [], top = False, sources = [] })
    , trivial = True
    }


{-| A source lambda's member id IS its stamped id (the engine's interning
supply is seeded past `GlobalMVarState.nextLam`, so the two never collide).
-}
srcLambdaKey : TypeIds.SrcLambdaId -> Int
srcLambdaKey =
    Id.toComparable


{-| Fix B (LSS_017): the member id for a lambda INSTANCE minted during
translation. When the defining global routes through the keyed spec path
(the same predicate `enqueueSpec` uses), the id is qualified by the
enclosing SpecId — interned as `l|<lam>|<spec>` — so keyed clones of one
source lambda carry DISTINCT members and can never impersonate each other
at singleton consumers (the §11.6 representative-hijack root cause:
`plans/lss-fork-qualified-members.md`). Non-keyed-routed globals keep the
raw id: their spec keys are annotation-insensitive (`widenSets` /
lss-off), so same-layout duplicate instances are impossible and raw stays
sound AND byte-identical. Interning is idempotent, so LSS_010 dirty-flush
re-translations of a spec re-mint the same id.

A translation-phase mint under keyed routing with no current spec falls
back to the raw id and bumps `unqualifiedLambdaMints` (expected 0 —
visible in the census, never a silent mis-qualification).

Inference-phase signature mints (`LssInfer.walkExpr`) deliberately do NOT
use this: signatures are per-unit and pre-spec; their raw members carry no
instances post-Fix-B, so signature-transported singletons decline at
AbiCloning (unstampable-but-sound).
-}
lambdaInstanceMemberId : TypeIds.SrcLambdaId -> Step Int
lambdaInstanceMemberId lamId s0 =
    let
        raw =
            srcLambdaKey lamId
    in
    if not s0.env.lss.enabled then
        Ok ( raw, s0 )

    else
        let
            routed =
                case s0.currentGlobal of
                    Just g ->
                        s0.env.lss.keyed
                            || (not (CoreDict.isEmpty s0.env.lssKeyedSet)
                                    && CoreDict.member (Mono.toComparableGlobal g) s0.env.lssKeyedSet
                               )

                    Nothing ->
                        -- Outside any item: under all-globals keying treat as
                        -- routed so the missing spec id is COUNTED, not
                        -- silently raw-minted.
                        s0.env.lss.keyed
        in
        if not routed then
            Ok ( raw, s0 )

        else
            case s0.itemAux.currentSpecId of
                Just specId ->
                    -- LSS_018 μ-tie: if this spec's own STORED demand already
                    -- carries a qualified member of the same raw lambda, the
                    -- value being minted IS the value that arrived in the
                    -- demand — one recursive family. Minting Q(L,S) fresh
                    -- would only spawn the next family member (the
                    -- specs→qualified-members→keys spiral); reusing the
                    -- family id closes it at its second member. Tied ids are
                    -- recorded in `muTied` and AbiCloning-blocked (plan §2.4 —
                    -- multi-demand instances are behaviorally divergent and
                    -- must never rep-stamp). `demandQualified` is built (and
                    -- `lambdaQualified` recorded) only under `lss.muTie`, so
                    -- the flag-off path carries zero scan/table cost; the
                    -- Just arm is unreachable flag-off. The one-shot eligible
                    -- census measured 0 on the self-compile (Run J).
                    case CoreDict.get raw s0.itemAux.demandQualified of
                        Just tiedId ->
                            Ok ( tiedId, recordMuTied tiedId s0 )

                        Nothing ->
                            mintQualifiedLambda raw specId s0

                Nothing ->
                    let
                        stats =
                            s0.lssStats
                    in
                    Ok ( raw, { s0 | lssStats = { stats | unqualifiedLambdaMints = stats.unqualifiedLambdaMints + 1 } } )


{-| Intern the spec-qualified lambda member `Q(L,S)` and — under `lss.muTie`
only — record its (raw, spec) identity in `lambdaQualified`, the LSS_018
reverse map that `processItem`'s demand scan consults. Flag-off skips the
recording entirely (no map growth on the default path); the insert is
idempotent (the key encodes both components), so LSS_010 re-translations
re-record the same pair.
-}
mintQualifiedLambda : Int -> Int -> Step Int
mintQualifiedLambda raw specId s0 =
    case memberIdFor ("l|" ++ String.fromInt raw ++ "|" ++ String.fromInt specId) s0 of
        Err e ->
            Err e

        Ok ( mid, s1 ) ->
            let
                table =
                    s1.lssMemberTable
            in
            if not s1.env.lss.muTie || CoreDict.member mid table.lambdaQualified then
                Ok ( mid, s1 )

            else
                Ok ( mid, { s1 | lssMemberTable = { table | lambdaQualified = CoreDict.insert mid ( raw, specId ) table.lambdaQualified } } )


{-| LSS_018: record a member id as μ-tied (idempotent). The set is exported
as `MonoGraph.lssBlockedMembers` at assembly.
-}
recordMuTied : Int -> S -> S
recordMuTied tiedId s =
    let
        table =
            s.lssMemberTable
    in
    if CoreDict.member tiedId table.muTied then
        s

    else
        { s | lssMemberTable = { table | muTied = CoreDict.insert tiedId () table.muTied } }


{-| `lambdaInstanceMemberId` lifted over the optional provenance stamp, for
the `ClosureInfo.lssMember` field: `Nothing` for untagged lambdas and on
the lss-off path (where AbiCloning is inert and the field is never read).
-}
lambdaInstanceMemberMaybe : Maybe TypeIds.SrcLambdaId -> Step (Maybe Int)
lambdaInstanceMemberMaybe srcLam s0 =
    if s0.env.lss.enabled then
        case srcLam of
            Just lamId ->
                case lambdaInstanceMemberId lamId s0 of
                    Err e ->
                        Err e

                    Ok ( mid, s1 ) ->
                        Ok ( Just mid, s1 )

            Nothing ->
                Ok ( Nothing, s0 )

    else
        Ok ( Nothing, s0 )


bumpWidenedByKernel : S -> S
bumpWidenedByKernel s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | widenedByKernel = stats.widenedByKernel + 1 } }


{-| LSS_020 (B.4): a signature arrow's member list exceeded `maxSetSize` at
readback and widened to ⊤. Policy counter — unconditional.
-}
bumpWidenedBySigSize : S -> S
bumpWidenedBySigSize s =
    let
        stats =
            s.lssStats

        sig =
            stats.sigStats
    in
    { s | lssStats = { stats | sigStats = { sig | widenedBySigSize = sig.widenedBySigSize + 1 } } }


{-| LSS_020 (B.4): a poison event inside a sigFlow join (hub poison or
divergence in the new joins). Census-only — REPORT-GATED (plan 1 §7.6).
-}
bumpWidenedByCf : S -> S
bumpWidenedByCf s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats
        in
        { s | lssStats = { stats | sigStats = { sig | widenedByCf = sig.widenedByCf + 1 } } }

    else
        s


{-| LSS_021 (Phase F): a POSITIONAL KernelSetFacts row applied at a kernel
boundary. Census-only — REPORT-GATED (plan 1 §7.6).
-}
bumpKernelFactHit : S -> S
bumpKernelFactHit s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats
        in
        { s | lssStats = { stats | sigStats = { sig | kernelFactHits = sig.kernelFactHits + 1 } } }

    else
        s


{-| LSS_023: a directed inclusion edge was installed (`Store.addSlotSource`).
Census-only — REPORT-GATED.
-}
bumpEdgeInstalled : S -> S
bumpEdgeInstalled s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats
        in
        { s | lssStats = { stats | sigStats = { sig | edgesInstalled = sig.edgesInstalled + 1 } } }

    else
        s


{-| LSS_023: a directed structural walk degraded a container subtree to the
symmetric join, and the subtree can carry a set. Census-only — REPORT-GATED.
-}
bumpFlowDegraded : S -> S
bumpFlowDegraded s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats
        in
        { s | lssStats = { stats | sigStats = { sig | flowDegraded = sig.flowDegraded + 1 } } }

    else
        s


{-| LSS_022: a kernel boundary took the LICENSED (`TypeFaithful`)
pass-through — no LSS_004 poison on either side. Census-only —
REPORT-GATED, and disjoint from `bumpKernelFactHit` by construction (one
boundary takes one tier).
-}
bumpKernelLicensed : S -> S
bumpKernelLicensed s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats
        in
        { s | lssStats = { stats | sigStats = { sig | kernelLicensed = sig.kernelLicensed + 1 } } }

    else
        s


{-| MONO_030 (solver arm): validate a just-CREATED spec against the breadth
and key-size watchdogs. `Nothing` = fine; `Just` = the loud failure that
replaces a silent hang/OOM (poly-rec through annotated mutual cycles is
legal Elm — plan §1.1). Callers gate on the created path only, so this
never runs on registry probe hits. A limit of 0 disables its check.
-}
checkSpecWatchdogs : Mono.Global -> Mono.MonoType -> Mono.SpecializationRegistry -> S -> Maybe Failure
checkSpecWatchdogs global monoType reg s =
    let
        limits =
            s.env.limits

        -- THUNKED DELIBERATELY. This function runs on every CREATED spec
        -- (~41k on a self-compile) and the message is emitted essentially
        -- never, so the context string must not be built on the passing path.
        -- Same discipline as `Translate.unifyStepCtx`'s `() -> String`.
        context : () -> String
        context =
            \() ->
                case s.currentGlobal of
                    Just g ->
                        "\n  (reached while specializing " ++ Registry.prettyGlobal g ++ ")"

                    Nothing ->
                        ""

        count =
            Registry.createdCount global reg
    in
    if limits.specBreadth > 0 && count > limits.specBreadth then
        Just (LimitExceeded (Registry.breadthLimitMessage global count limits.specBreadth ++ context ()))

    else if limits.specTypeNodes > 0 && not (Mono.typeNodesWithin limits.specTypeNodes monoType) then
        Just (LimitExceeded (Registry.typeNodesLimitMessage global limits.specTypeNodes ++ context ()))

    else
        Nothing


{-| M7: the immutable Reader-style context — set once at `initState`, never
updated. Grouped so `S` updates copy one `env` ref rather than five dead ones.
-}
type alias Env =
    { toptNodes : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId) -- 4c: hash-keyed, NOT DMap — `Data.Map` rebuilds `toComparableGlobal` on every probe, and this map is read per occurrence
    , annotations : TOpt.AnnotationsByGlobal TypeIds.MVarId
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , currentModule : IO.Canonical -- entry module; home of every AnonymousLambda
    , superStatic : Dict Int IO.SuperType -- static solver truth ONLY (loadVar)
    , lss : Config.LssConfig -- lambda-set specialization knobs; enabled=False is byte-identical off
    , lssKeyedSet : CoreDict.Dict String () -- E5: comparable gkeys of lss.keyedGlobals (parsed once at initState)
    , lamLabels : CoreDict.Dict Int String -- member id -> "defKey#id" (census rendering only)
    , limits : Config.SpecLimits -- MONO_030 spec watchdogs (0 = a check disabled); failure-only, hash-excluded
    }


{-| The whole engine state: global fields persist across work items; the
per-item fields (`store`, `memo`, `revMemo`) are reset by `resetItem`.
-}
type alias S =
    { -- Global accumulators (mirror State.SpecAccum minus the subst machinery)
      worklist : List WorkItem
    , nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet
    , scheduled : BitSet
    , dirtySpecs : BitSet -- LSS_010: specs whose stored type was annotation-JOINED after scheduling; re-translated at drain-end flush rounds (flag-off: never set)
    , dirtyList : List Mono.SpecId -- enumeration twin of dirtySpecs (BitSet has no iteration); duplicate-free via the bit check; consumed by the drain-end flush
    , specCountByGlobal : CoreDict.Dict String Int -- M4 keyed budget: specs created per global (only maintained under lss.keyed; consulted by underBudget)
    , registry : Mono.SpecializationRegistry
    , ports : List Mono.PortRegistration
    , lambdaCounter : Int

    -- Number/super truth: seeded from AssignMVarIds' superVars, read by
    -- loadType when minting a var, and fed to shared Prune at the end.
    , superTable : Dict Int IO.SuperType -- static solver truth + Join-R harvested number-taint (zonk/key/Prune)
    , nextMVarId : TypeIds.MVarId

    -- LSS (all GLOBAL — survive resetItem; signatures/members are per-run facts)
    , lssSignatures : CoreDict.Dict String LssSignature -- TOpt.toComparableGlobal -> signature
    , lssInProgress : CoreDict.Dict String () -- in-flight inference units (re-entry = EngineBug)
    , lssMemberTable : LssMemberTable -- interned non-lambda member ids + E9 devirt reverse map (ONE field: S self-hosts and must stay within the runtime's 32-slot record scan cap)
    , nextMemberId : Int -- shared supply, seeded past GlobalMVarState.nextLam
    , lssStats : LssStats

    , monoMemo : MonoMemo -- the three classification memos (ONE field: see `MonoMemo` — S is at the runtime's 32-slot record scan cap)
    , nodeResolution : CoreDict.Dict String NodeResolution -- D13: per-GLOBAL node lookup + annotation-id set, keyed by TOpt.toComparableGlobal. Depends only on the immutable toptNodes, so it survives resetItem; a global with N specs resolves once instead of N times.

    -- K6 (plans/mono-comparable-key-optimization.md §15): construction-time
    -- hash-consing for MonoType. GLOBAL — survives resetItem, so every type the
    -- run builds shares one canonical object per distinct structure. Threaded
    -- into `Store.classifyGo` (which already carries S), `Store.zonkToMono`'s
    -- `ZonkCtx`, and `Zonk.canTypeToMonoWithI`.
    , intern : Intern

    -- M7: the 5 IMMUTABLE context fields (never updated after initState) live in
    -- one `env` sub-record, so each `{ s | … }` copies one `env` ref instead of
    -- five refs it never changes.
    , env : Env
    , currentGlobal : Maybe Mono.Global -- (changes per item — stays top-level)

    -- Per-work-item solver state
    , store : IO.State
    , memo : Dict Int IO.Variable -- MVarId (Id.toComparable) -> Point
    , revMemo : Array (Maybe TypeIds.MVarId) -- A2: Point index -> first MVarId that minted it. Point indices are DENSE from 0 in a fresh per-item store, so an Array (indexed by point) replaces the former Dict Int — O(log32) point-keyed reads with no `_Utils_cmp`, sparse structure-point slots hold Nothing.
    , varEnv : CoreDict.Dict String Mono.MonoType -- local variable name -> monomorphized type
    , numberMulti : List NumberMultiEntry -- stack of let-bound number vars being multi-specialized
    , localMulti : List NumberMultiEntry -- stack of let-bound FUNCTIONS being multi-specialized (f, f$1, …)
    , derivedDestructors : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- destructor-bound name -> the destructor's canType (bridges a derived fn's call back to its root's type vars)
    , localCanTypes : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- let-bound name -> its RHS canType (destructor root slot lookup)
    -- Per-item auxiliary state, grouped into ONE field: compiled Record heap
    -- objects have a 32-slot GC scan limit and S sits exactly at it — adding
    -- a top-level field to S breaks the native self-compile at MLIR parse
    -- ("field_count exceeds Record's 32-slot GC scan limit"). Group new
    -- per-item state here.
    --
    --   lssRootAnn: lss on, function-root defs only — the demandUnify-seeded
    --   annotation var, consumed ONCE by the def-root classifyLambdaHead so
    --   binder/param types zonk demand-transported lambda sets (LSS_006).
    --
    --   ecoResidualReads/ecoResidualKeyReads (MONO_029 R2 stale-read
    --   barrier): every zonk/classify that PRODUCES an erased CEcoValue
    --   residual records what it read — a canonical-backed store var or a
    --   never-loaded MVarId. At item end, a recorded read whose var/memo
    --   entry has since been BOUND (or Number-tainted) in the SHARED memo
    --   component proves the recorded output was a stale snapshot;
    --   specializeNodeSaturating re-translates against the saturated store.
    --   CNumber residuals are NOT tracked (eager-Int number-multi reads them
    --   stale by design; Prune's number close owns them).
    --
    --   loopParams (MONO_029 R1): enclosing tail-recursive functions'
    --   (name, typedArgs) frames, innermost first; the TailCall arm connects
    --   recursive-call args to loop params (the TCO transform rebuilds that
    --   call chain with a fresh id family).
    , itemAux : ItemAux
    }


type alias ItemAux =
    { lssRootAnn : Maybe ( Can.Type TypeIds.MVarId, IO.Variable )
    , ecoResidualReads : List IO.Variable
    , ecoResidualKeyReads : List Int
    , loopParams : List ( String, List ( String, Can.Type TypeIds.MVarId ) )
    , currentSpecId : Maybe Int -- Fix B (LSS_017): the SpecId being translated; set by processItem after resetItem, cleared at finishNode. Qualifies lambda-instance member ids for keyed-routed globals.
    , demandQualified : CoreDict.Dict Int Int -- LSS_018: raw lambda id -> SMALLEST qualified member id present in this spec's STORED demand (built by processItem from the registry type; consulted by lambdaInstanceMemberId's μ-tie)
    }


emptyItemAux : ItemAux
emptyItemAux =
    { lssRootAnn = Nothing, ecoResidualReads = [], ecoResidualKeyReads = [], loopParams = [], currentSpecId = Nothing, demandQualified = CoreDict.empty }


{-| Scratch-store entry: clear ONLY the read lists (scratch Point indices are
meaningless against the restored item store); other aux fields flow through.
-}
clearedAux : ItemAux -> ItemAux
clearedAux aux =
    { aux | ecoResidualReads = [], ecoResidualKeyReads = [] }


{-| Scratch-store exit: restore the outer read lists, keep everything else
from the inner state (matches the pre-pack behavior field for field).
-}
restoredAux : ItemAux -> ItemAux -> ItemAux
restoredAux outer inner =
    { inner | ecoResidualReads = outer.ecoResidualReads, ecoResidualKeyReads = outer.ecoResidualKeyReads }


{-| Saturation-pass reset (MONO_029 R2): drop the recorded reads before
re-translating against the same store.
-}
clearResidualReads : S -> S
clearResidualReads s =
    let
        aux =
            s.itemAux
    in
    { s | itemAux = { aux | ecoResidualReads = [], ecoResidualKeyReads = [] } }


{-| D13: the per-global result of resolving a `Mono.Global` against `toptNodes`,
plus the annotation-id set harvested from the resolved node. Both depend only on
the immutable node map, so they are computed once per global and reused across
every specialization of that global (memoized in `S.nodeResolution`).
-}
type alias NodeResolution =
    { node : Maybe (TOpt.Node TypeIds.MVarId)
    , annIds : EverySet.EverySet Int Int
    }


{-| A let-bound value being specialized at multiple monomorphic types
(number-multi / value-multi). `instances` is keyed by the demanded `MonoType`
ITSELF (`Mono.SpecMap` — `specHashOf` + `eqKeySpec`, no string built; Phase 3
site 2, plans/speckey-optimization.md §10.3); index 0 keeps the bare name,
later ones get `$v<idx>`.

**Iteration order is insertion order**, not the rendered-type lexicographic
order the old `Dict String` gave. That is observable: `Translate`'s
`buildLocalDefs` and the two destructor sites emit one def per instance in
iteration order, so emitted-def order — and therefore SpecId assignment
order — changes. Accepted by decision (§10.4); names are unaffected because
`freshName` is assigned from `specMapSize` at INSERT time.
-}
type alias NumberMultiEntry =
    { defName : String
    , instances : Mono.SpecMap NumberInstance
    }


type alias NumberInstance =
    { freshName : String
    , monoType : Mono.MonoType
    }


{-| Why a work item was abandoned. All are surfaced as a top-level `Err`
(never a fallback): `Unsupported` = feature not yet built; `UnifyMismatch` =
the real unifier rejected something the old engine absorbed silently;
`EngineBug` = an invariant the engine believes cannot happen;
`LimitExceeded` = a MONO_030 resource watchdog tripped — a diagnosable
program/limit condition, NOT a compiler bug (renderFailure must not frame it
as one).
-}
type Failure
    = Unsupported String
    | UnifyMismatch String
    | EngineBug String
    | LimitExceeded String



-- ====== STEP MONAD ======


{-| A state transition that may fail. Failure aborts the whole pass.
-}
type alias Step a =
    S -> Result Failure ( a, S )


succeed : a -> Step a
succeed a =
    \s -> Ok ( a, s )


fail : Failure -> Step a
fail f =
    \_ -> Err f


andThen : (a -> Step b) -> Step a -> Step b
andThen f step =
    \s ->
        case step s of
            Err e ->
                Err e

            Ok ( a, s1 ) ->
                f a s1


{-| D1: direct form. The former `andThen (\a -> succeed (f a)) step` allocated the
`\a -> …` closure PLUS the `succeed (f a)` closure on every run; `map` fires on
essentially every zonk/encode node, so the direct `case` form (one closure) is a
broad cut to the monad-closure bucket. Monad-law-preserving → byte-identical.
-}
map : (a -> b) -> Step a -> Step b
map f step =
    \s ->
        case step s of
            Err e ->
                Err e

            Ok ( a, s1 ) ->
                Ok ( f a, s1 )


map2 : (a -> b -> c) -> Step a -> Step b -> Step c
map2 f sa sb =
    \s ->
        case sa s of
            Err e ->
                Err e

            Ok ( a, s1 ) ->
                case sb s1 of
                    Err e ->
                        Err e

                    Ok ( b, s2 ) ->
                        Ok ( f a b, s2 )


{-| Thread a step over a list, preserving order. Direct order-preserving
recursion (no intermediate reversed list, no per-element `map` closure); the
lists here are short (type arities / tuple slots / record fields), matching the
non-tail shape already used by `Store.loadListC`/`Translate.classifyList`.
-}
traverse : (a -> Step b) -> List a -> Step (List b)
traverse f items =
    \s -> traverseGo f items s


traverseGo : (a -> Step b) -> List a -> S -> Result Failure ( List b, S )
traverseGo f items s =
    case items of
        [] ->
            Ok ( [], s )

        x :: rest ->
            case f x s of
                Err e ->
                    Err e

                Ok ( b, s1 ) ->
                    case traverseGo f rest s1 of
                        Err e ->
                            Err e

                        Ok ( bs, s2 ) ->
                            Ok ( b :: bs, s2 )


{-| Left fold in the Step monad.
-}
foldlS : (a -> b -> Step b) -> b -> List a -> Step b
foldlS f acc items =
    case items of
        [] ->
            succeed acc

        x :: rest ->
            andThen (\acc1 -> foldlS f acc1 rest) (f x acc)


runStep : Step a -> S -> Result Failure ( a, S )
runStep step s =
    step s


getS : (S -> a) -> Step a
getS f =
    \s -> Ok ( f s, s )


modifyS : (S -> S) -> Step ()
modifyS f =
    \s -> Ok ( (), f s )


{-| Run a solver `IO` action against the item's store.
-}
liftIO : IO.IO a -> Step a
liftIO io =
    \s ->
        let
            ( store1, a ) =
                io s.store
        in
        Ok ( a, { s | store = store1 } )



-- ====== SOLVER-STORE HELPERS ======


{-| Mint a fresh union-find Point with the given content, at the single fixed
engine rank (`outermostRank`). No generalization happens, so any fixed rank is
safe (`Unify.merge` uses `min`, `Occurs` ignores rank).
-}
freshVar : IO.Content -> Step IO.Variable
freshVar content =
    liftIO (UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing))


{-| The one member-interning code path (LSS_019 made it pure so `Store`'s
zonk grounding and the `Step`-level mints share it): key → (id, table',
nextId'). A hit returns the table and supply UNCHANGED (same pointers), so
callers can detect the fresh-intern branch as `nextId' /= nextId`.
-}
internMemberKey : String -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )
internMemberKey key table nextId =
    case CoreDict.get key table.byKey of
        Just mid ->
            ( mid, table, nextId )

        Nothing ->
            ( nextId, insertMemberKey key nextId table, nextId + 1 )


{-| Member id for a non-lambda function value, interned by kind+identity.
Keys: "g|<global>" (global function ref), "c|<global>" (ctor used as a
function), "k|home.name" (kernel ref), "a|field" (accessor value),
"g|<global>|<typeKey>" (LSS_019 ground standalone). Ids come from the same
supply as Phase-0 lambda ids (`nextMemberId` is seeded past
`GlobalMVarState.nextLam`), so member ids never collide (LSS_003).
-}
memberIdFor : String -> Step Int
memberIdFor key s =
    let
        ( mid, table1, next1 ) =
            internMemberKey key s.lssMemberTable s.nextMemberId
    in
    if next1 == s.nextMemberId then
        Ok ( mid, s )

    else
        Ok ( mid, { s | lssMemberTable = table1, nextMemberId = next1 } )


{-| E9: intern a STANDALONE-GLOBAL member ("g|" or "c|" key — named
globals, ctors incl. `Can.Normal` ones like `List.::`, box/enum ctors) and
record its Global in the reverse map the devirt consults
(`standaloneMemberGlobal`) AND in `provisionalStandalone` (LSS_019 — these
ids are PROVISIONAL: family names awaiting type-keyed grounding at zonk).
Same interning as `memberIdFor`; the reverse inserts are idempotent.
-}
standaloneMemberIdFor : String -> TOpt.Global -> Step Int
standaloneMemberIdFor key g s0 =
    case memberIdFor key s0 of
        Err e ->
            Err e

        Ok ( mid, s1 ) ->
            if CoreDict.member mid s1.lssMemberTable.sources then
                Ok ( mid, s1 )

            else
                Ok ( mid, { s1 | lssMemberTable = insertMemberProvisional mid g (insertMemberGlobal mid g s1.lssMemberTable) } )


{-| E9: the Global behind a member id, when the member is a standalone
global/ctor reference.
-}
standaloneMemberGlobal : Int -> Step (Maybe TOpt.Global)
standaloneMemberGlobal mid s =
    Ok
        ( case CoreDict.get mid s.lssMemberTable.sources of
            Just (SourceGlobal g) ->
                Just g

            _ ->
                Nothing
        , s
        )


{-| LSS_019: intern a GROUND standalone member — `g|<global>|<typeKey>`,
one id per (global × instantiation layout). Pure (callable from `Store`'s
zonk, which threads no `Step`). Writes `sources` ONLY, never
`provisionalStandalone`: ground ids pass through the grounding rewrite
untouched, which is what makes zonk∘encode∘zonk idempotent — the stability
LSS_010's finite-lattice termination argument consumes. The `typeKey` must
be the ANNOTATION-WIDENED arrow key (`groundSetMembers` builds it), so a
set never participates in its own members' identity (μ-severing).
-}
groundStandaloneMemberIdFor : TOpt.Global -> String -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )
groundStandaloneMemberIdFor g typeKey table nextId =
    let
        ( mid, table1, next1 ) =
            internMemberKey ("g|" ++ TOpt.toComparableGlobal g ++ "|" ++ typeKey) table nextId
    in
    if next1 == nextId then
        ( mid, table1, next1 )

    else
        ( mid, insertMemberGlobal mid g table1, next1 )


{-| LSS_019 (GAP-1 element grounding, plans/lss-fidelity-2-standalone-member-grounding.md §3):
rewrite each PROVISIONAL standalone member (`g|`/`c|`, recorded in
`provisionalStandalone`) of a set slot being read back at the arrow
`paramT -> resultT` to its GROUND member `g|<global>|<widened-arrow-typeKey>`.
Element identity becomes (global × instantiation layout) — the id-space
image of the paper's μ-aware substitution for `d⟨σ̄⟩` occurrences in sets.

Three load-bearing details (plan §3.2):

1.  DEFERRAL: a residual-carrying arrow (`containsAnyMVar`) keeps the
    provisional ids — grounding there would embed per-item residual MVar
    ids in the key, minting different ids for the same value in different
    specs (spurious 2-sets). Deferral equals the pre-plan semantics and is
    convergent under LSS_010 re-translation (a later, more concrete demand
    grounds it then). Counted as the census's `deferred` — the explicit
    precision frontier.
2.  The key is ANNOTATION-WIDENED (`widenSets` before `toComparable`): an
    arrow's own set cannot participate in its members' identity — that is
    the μ-circularity, severed by construction.
3.  The caller applies the maxSetSize policy to the REWRITTEN list (dedup
    only shrinks; within one slot a provisional maps to exactly one ground
    id, so per-slot size never grows — cap semantics never regress).

Lambda (`l|`), kernel (`k|`), accessor (`a|`) and already-ground members
pass through untouched (not in `provisionalStandalone`). Mixed
provisional/ground sets are legal mid-run; rewrite+dedup at every zonk
keeps annotations canonical.
-}
groundSetMembers : Mono.MonoType -> Mono.MonoType -> List Int -> LssMemberTable -> Int -> { members : List Int, table : LssMemberTable, nextId : Int, grounded : Int, deferred : Int }
groundSetMembers paramT resultT members table0 nextId0 =
    if not (List.any (\mid -> CoreDict.member mid table0.provisionalStandalone) members) then
        -- Fast path (the common case): no provisional member in the slot.
        { members = members, table = table0, nextId = nextId0, grounded = 0, deferred = 0 }

    else if Mono.containsAnyMVar paramT || Mono.containsAnyMVar resultT then
        -- Detail 1: deferral at a residual-carrying arrow.
        { members = members
        , table = table0
        , nextId = nextId0
        , grounded = 0
        , deferred =
            List.foldl
                (\mid n ->
                    if CoreDict.member mid table0.provisionalStandalone then
                        n + 1

                    else
                        n
                )
                0
                members
        }

    else
        let
            -- Detail 2: the annotation-widened arrow key, built ONCE per slot.
            typeKey =
                Mono.toComparableMonoType (Mono.widenSets (Mono.mFunction Mono.LTop [ paramT ] resultT))

            rewritten =
                List.foldl
                    (\mid acc ->
                        case CoreDict.get mid acc.table.provisionalStandalone of
                            Nothing ->
                                { acc | members = mid :: acc.members }

                            Just g ->
                                let
                                    ( mid2, table1, next1 ) =
                                        groundStandaloneMemberIdFor g typeKey acc.table acc.nextId
                                in
                                { members = mid2 :: acc.members
                                , table = table1
                                , nextId = next1
                                , grounded = acc.grounded + 1
                                , deferred = acc.deferred
                                }
                    )
                    { members = [], table = table0, nextId = nextId0, grounded = 0, deferred = 0 }
                    members
        in
        -- Re-establish LSS_001's ascending-sorted, duplicate-free shape.
        { members = dedupAscending (List.sort rewritten.members)
        , table = rewritten.table
        , nextId = rewritten.nextId
        , grounded = rewritten.grounded
        , deferred = rewritten.deferred
        }


dedupAscending : List Int -> List Int
dedupAscending xs =
    case xs of
        a :: ((b :: _) as rest) ->
            if a == b then
                dedupAscending rest

            else
                a :: dedupAscending rest

        _ ->
            xs


{-| E9.2 (LSS_016): intern a KERNEL member ("k|home.name" key — unchanged,
so member ids are identical to the pre-E9.2 mint) and record its
(prefix, home, name) identity in the reverse map the kernel devirt
consults (`standaloneMemberKernel`). Mirrors `standaloneMemberIdFor`.
-}
kernelMemberIdFor : String -> ( String, String, String ) -> Step Int
kernelMemberIdFor key k s0 =
    case memberIdFor key s0 of
        Err e ->
            Err e

        Ok ( mid, s1 ) ->
            if CoreDict.member mid s1.lssMemberTable.sources then
                Ok ( mid, s1 )

            else
                Ok ( mid, { s1 | lssMemberTable = insertMemberKernel mid k s1.lssMemberTable } )


{-| E9.2: the kernel (prefix, home, name) behind a member id, when the
member is a kernel-value reference.
-}
standaloneMemberKernel : Int -> Step (Maybe ( String, String, String ))
standaloneMemberKernel mid s =
    Ok
        ( case CoreDict.get mid s.lssMemberTable.sources of
            Just (SourceKernel k) ->
                Just k

            _ ->
                Nothing
        , s
        )


{-| Run a Step against a fresh scratch store, restoring the item's
store/memo/revMemo afterward. This is `Translate.retranslateAt`'s
stash/restore promoted to a combinator — the scratch store's Points never
leak into the surrounding item, and vice versa.
-}
withScratchStore : Step a -> Step a
withScratchStore step s0 =
    let
        sFresh =
            -- The stale-read barrier's read lists are stashed too: scratch
            -- Points are meaningless against the restored item store, so
            -- residual reads made inside the scratch must not be scanned at
            -- item end (scratch re-translation is itself a re-translation
            -- mechanism; its staleness is out of scope for MONO_029 v1).
            { s0 | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty, itemAux = clearedAux s0.itemAux }
    in
    case step sFresh of
        Err e ->
            Err e

        Ok ( a, s1 ) ->
            Ok ( a, { s1 | store = s0.store, memo = s0.memo, revMemo = s0.revMemo, itemAux = restoredAux s0.itemAux s1.itemAux } )



-- ====== WORKLIST / REGISTRY ======


{-| Allocate or reuse the SpecId for a specialization, scheduling it if new.
Mirrors the original `enqueueSpec`: LIFO worklist (cons), `scheduled` dedups.
-}
enqueueSpec : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpec global monoType s0 =
    -- A1: explicit trailing-S param (was `\s -> …`) → saturated callers avoid the
    -- per-call closure; body unchanged → byte-identical.
    -- E5: a global listed in lss.keyedGlobals routes into the budgeted keyed
    -- path even when global keying is off. The isEmpty short-circuit keeps
    -- the empty-config hot path free of the per-enqueue gkey string build.
    if
        s0.env.lss.enabled
            && (s0.env.lss.keyed
                    || (not (CoreDict.isEmpty s0.env.lssKeyedSet)
                            && CoreDict.member (Mono.toComparableGlobal global) s0.env.lssKeyedSet
                       )
               )
    then
        enqueueSpecKeyed global monoType s0

    else
    let
        ( ( specId, reg1, hit ), s2 ) =
            if s0.env.lss.enabled then
                -- §8.5, keyed=False (M2/M3): keys are today's keys — lambda
                -- sets never fan out specializations; the stored demand is the
                -- annotation JOIN of every admitted demand (LSS_010).
                -- K6: the widened KEY is hash-consed, so `eqKeySpec`'s
                -- `identicalOr` can settle the registry probe on pointer
                -- identity instead of walking the tree.
                let
                    ( keyType, intern1 ) =
                        Intern.widenSets monoType s0.intern
                in
                ( Registry.getOrCreateSpecIdKeyed global keyType monoType s0.registry
                , withIntern intern1 s0
                )

            else
                -- lss off (byte-identical path — no widenSets allocation).
                let
                    ( sid, r ) =
                        Registry.getOrCreateSpecId global monoType s0.registry
                in
                ( ( sid, r, Registry.CreatedNew ), s0 )

        s =
            bumpKeyedHit hit s2

        storedChanged =
            hit == Registry.HitChangedJoin

        -- MONO_030: `hit == CreatedNew` is NOT a reliable created signal on
        -- the lss-off arm (it labels every probe CreatedNew) — nextId growth
        -- is, on both arms.
        watchdog =
            if reg1.nextId > s0.registry.nextId then
                checkSpecWatchdogs global monoType reg1 s

            else
                Nothing
    in
    case watchdog of
        Just failure ->
            Err failure

        Nothing ->
            enqueueSpecCommit specId reg1 storedChanged s


{-| The post-watchdog commit tail shared by `enqueueSpec`'s unkeyed/off arm
and `enqueueSpecKeyed`.

On an already-scheduled hit with a CHANGED join (LSS_010): a later demand
widened the stored annotations of an already-scheduled spec. The node
(translated, in flight, or pending) was/will be seeded from a NARROWER
demand — its body annotations could claim a singleton set that lies about
this caller's values, and a fast-dispatch stamp on such a site is a silent
miscompile. Mark dirty ONLY — re-translation happens in drain-end flush
rounds (markDirty), so a spec re-translates once per round with its
FULLY-joined demand instead of once per join (the per-join immediate
re-push cascaded into hour-scale churn on the self-compile).

On an unchanged hit (D2): the registry is the SAME value, so
`{ s | registry = reg1 }` would copy the whole S to change nothing —
return S unaltered.
-}
enqueueSpecCommit : Mono.SpecId -> Mono.SpecializationRegistry -> Bool -> S -> Result Failure ( Mono.SpecId, S )
enqueueSpecCommit specId reg1 storedChanged s =
    if BitSet.member specId s.scheduled then
        if storedChanged then
            Ok ( specId, markDirty specId reg1 s )

        else
            Ok ( specId, s )

    else
        Ok
            ( specId
            , { s
                | registry = reg1
                , scheduled = BitSet.insertGrowing specId s.scheduled
                , worklist = SpecializeGlobal specId :: s.worklist
              }
            )


{-| Phase 1 census (`plans/lss-set-write-substrate.md`): attribute a keyed
registry probe. `CreatedNew` costs nothing — it is the miss path, which
always rebuilds `S` anyway, and a counter there would only re-count what
`registry.nextId` already tracks.

The two HIT-without-change outcomes are the ones worth the record copy: they
land on the D2 "return S unaltered" path, so this is the one place
instrumentation adds a copy the un-instrumented compiler does not make. That
cost is deliberate and bounded — it is exactly the population Phase 4
removes, and Run B measures it against Run A.

-}
bumpKeyedHit : Registry.KeyedHit -> S -> S
bumpKeyedHit hit s =
    let
        stats =
            s.lssStats
    in
    case hit of
        Registry.CreatedNew ->
            s

        Registry.HitIdentical ->
            { s | lssStats = { stats | joinIdenticalHit = stats.joinIdenticalHit + 1 } }

        Registry.HitNoopJoin ->
            { s | lssStats = { stats | joinNoop = stats.joinNoop + 1 } }

        Registry.HitChangedJoin ->
            { s | lssStats = { stats | joinChanged = stats.joinChanged + 1 } }


{-| Phase 1 census: one processItem completion join ran (one per completed
body-bearing spec). Phase 4a: this is now the CHANGED half of that population.
-}
bumpCompletionJoin : S -> S
bumpCompletionJoin s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | completionJoins = stats.completionJoins + 1 } }


{-| Phase 4a census: a completion join that added nothing — the changed flag
came back `False`, so no tree was rebuilt. Bumps the total too, keeping
`completionJoins` the invocation count Phase 1 defined it as.
-}
bumpCompletionJoinNoop : S -> S
bumpCompletionJoinNoop s =
    let
        stats =
            s.lssStats
    in
    { s
        | lssStats =
            { stats
                | completionJoins = stats.completionJoins + 1
                , completionJoinNoop = stats.completionJoinNoop + 1
            }
    }


{-| LSS_010: record that a scheduled spec's stored type was join-widened.
Duplicate-free: the BitSet guards the list. The drain-end flush re-pushes
and `processItem` consumes the bit when it re-translates.
-}
markDirty : Mono.SpecId -> Mono.SpecializationRegistry -> S -> S
markDirty specId reg1 s =
    if BitSet.member specId s.dirtySpecs then
        { s | registry = reg1 }

    else
        { s
            | registry = reg1
            , dirtySpecs = BitSet.insertGrowing specId s.dirtySpecs
            , dirtyList = specId :: s.dirtyList
        }


{-| M4 (`keyed = True`, design §8.5): the dedup KEY is the fully annotated
type while this global is under its spec budget — lambda sets fan out
specializations, giving each caller's member its own copy of the callee
(the precondition for fast dispatch inside shared HOF bodies). Past the
budget, new demands fall back to the widened key (types never widen —
MONO_020/021/024) and the event is counted in `widenedByBudget`.

BOTH branches go through the JOINING variant (LSS_010): an annotated key
can collide with a widened one when the demand is all-`LTop` (an escaping
reference's storeless classify keys exactly like a widened set-bearing
type), and a plain first-demand-wins hit there would resurrect the shared
-spec miscompile through the keyed path. Under-budget hits with identical
annotations short-circuit inside `getOrCreateSpecIdKeyed` (equal stored
type, or a join that changes nothing).

`specCountByGlobal` counts CREATED specs per global (detected by
`registry.nextId` advancing), so budget checks are O(log n) and reuse of
an existing spec never burns budget.
-}
enqueueSpecKeyed : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpecKeyed global monoType s0 =
    let
        gkey =
            Mono.toComparableGlobal global

        count =
            Maybe.withDefault 0 (CoreDict.get gkey s0.specCountByGlobal)

        underBudget =
            count < s0.env.lss.maxSpecsPerGlobal

        ( ( specId, reg1, hit ), sProbe ) =
            if underBudget then
                ( Registry.getOrCreateSpecIdKeyed global monoType monoType s0.registry, s0 )

            else
                -- K6: hash-cons the budget-widened key (see `enqueueSpec`).
                let
                    ( keyType, intern1 ) =
                        Intern.widenSets monoType s0.intern
                in
                ( Registry.getOrCreateSpecIdKeyed global keyType monoType s0.registry
                , withIntern intern1 s0
                )

        storedChanged =
            hit == Registry.HitChangedJoin

        s =
            bumpKeyedHit hit sProbe

        created =
            reg1.nextId > s.registry.nextId

        stats0 =
            s.lssStats

        s1 =
            { s
                | registry = reg1
                , specCountByGlobal =
                    if created then
                        CoreDict.insert gkey (count + 1) s.specCountByGlobal

                    else
                        s.specCountByGlobal
                , lssStats =
                    if underBudget then
                        stats0

                    else
                        { stats0 | widenedByBudget = stats0.widenedByBudget + 1 }
            }
    in
    -- MONO_030: watchdogs on the created path only (probe hits never check).
    case
        (if created then
            checkSpecWatchdogs global monoType reg1 s1

         else
            Nothing
        )
    of
        Just failure ->
            Err failure

        Nothing ->
            -- LSS_010 dirty machinery on a changed join — mark only; the
            -- drain-end flush re-pushes.
            enqueueSpecCommit specId s1.registry storedChanged s1



-- ====== PER-ITEM RESET ======


{-| A fresh, empty solver store. Built here (rather than via a private IO.elm
seed) so the engine touches zero lines of the type checker.
-}
freshStore : IO.State
freshStore =
    { ioRefsPoint = Array.empty
    , ioRefsMVector = Array.empty
    , names =
        { taken = CoreDict.empty
        , normals = 0
        , numbers = 0
        , comparables = 0
        , appendables = 0
        , compAppends = 0
        }
    , nodeIds =
        { mapping = Array.empty
        , syntheticExprIds = EverySet.empty
        , schemeBinderVars = CoreDict.empty
        , recording = False
        }
    }


{-| Reset the per-work-item solver state before specializing a node.
-}
resetItem : S -> S
resetItem s =
    { s | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty, varEnv = CoreDict.empty, numberMulti = [], localMulti = [], derivedDestructors = CoreDict.empty, localCanTypes = CoreDict.empty, itemAux = emptyItemAux }


{-| Bind a local variable's monomorphized type.
-}
insertVar : String -> Mono.MonoType -> Step ()
insertVar name monoType s =
    Ok ( (), { s | varEnv = CoreDict.insert name monoType s.varEnv } )


{-| Look up a local variable's type (populated by let/lambda/destructor bindings).
-}
lookupVar : String -> Step (Maybe Mono.MonoType)
lookupVar name s =
    Ok ( CoreDict.get name s.varEnv, s )


{-| Push an empty number-multi entry for a let-bound number var before walking
its body (instance discovery is body-first).
-}
pushNumberMulti : String -> Step ()
pushNumberMulti defName s =
    Ok ( (), { s | numberMulti = { defName = defName, instances = Mono.specMapEmpty } :: s.numberMulti } )


{-| Pop the top number-multi entry after the body is specialized.
-}
popNumberMulti : Step (Maybe NumberMultiEntry)
popNumberMulti s =
    case s.numberMulti of
        top :: rest ->
            Ok ( Just top, { s | numberMulti = rest } )

        [] ->
            Ok ( Nothing, s )


{-| Is `name` a let-bound number var currently being multi-specialized?
-}
isNumberMultiTarget : String -> Step Bool
isNumberMultiTarget name s =
    Ok ( List.any (\e -> e.defName == name) s.numberMulti, s )


{-| The eager (index-0, bare-name) instance monoType of a number-multi target,
or Nothing if `name` is not one. Used by the destructor-derived divert to
overlay a refined slot onto the root container's type.
-}
numberMultiRootType : String -> Step (Maybe Mono.MonoType)
numberMultiRootType name s =
    Ok
        ( case List.head (List.filter (\e -> e.defName == name) s.numberMulti) of
            Just entry ->
                List.head (List.filter (\i -> i.freshName == name) (Mono.specMapValues entry.instances))
                    |> Maybe.map .monoType

            Nothing ->
                Nothing
        , s
        )


{-| Record (or reuse) an instance of a number-multi var at the demanded type,
returning its per-instance name (`defName` for the first/Int instance, then
`defName$v<idx>`). Keyed structurally on the demanded type (`Mono.SpecMap`).
-}
recordNumberInstance : String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordNumberInstance name monoType s =
    recordMultiInstance .numberMulti (\stk st -> { st | numberMulti = stk }) "$v" name monoType s


{-| Push an empty local-multi entry for a let-bound function before walking its
body (each use records the concrete type it is applied at).
-}
pushLocalMulti : String -> Step ()
pushLocalMulti defName s =
    Ok ( (), { s | localMulti = { defName = defName, instances = Mono.specMapEmpty } :: s.localMulti } )


popLocalMulti : Step (Maybe NumberMultiEntry)
popLocalMulti s =
    case s.localMulti of
        top :: rest ->
            Ok ( Just top, { s | localMulti = rest } )

        [] ->
            Ok ( Nothing, s )


isLocalMultiTarget : String -> Step Bool
isLocalMultiTarget name s =
    Ok ( List.any (\e -> e.defName == name) s.localMulti, s )


{-| D9: read all three `VarLocal` classifiers in one `getS` (is-local-multi,
is-number-multi, varEnv binding) — collapses three sequential `getS` andThen
closures on the hot local-ref node into one.
-}
localVarInfo : String -> Step ( Bool, Bool, Maybe Mono.MonoType )
localVarInfo name s =
    Ok
        ( ( List.any (\e -> e.defName == name) s.localMulti
          , List.any (\e -> e.defName == name) s.numberMulti
          , CoreDict.get name s.varEnv
          )
        , s
        )


{-| Record (or reuse) an instance of a local-multi FUNCTION at a demanded type;
per-instance name is `defName` (first) then `defName$<idx>`.
-}
recordLocalInstance : String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordLocalInstance name monoType s =
    recordMultiInstance .localMulti (\stk st -> { st | localMulti = stk }) "$" name monoType s


{-| Shared machinery behind `recordNumberInstance` / `recordLocalInstance`:
find the entry for `name` in the given stack, get-or-create an instance keyed
by the demanded `MonoType` (`Mono.SpecMap`), and name it `defName` for index 0
else `defName ++ sep ++ idx`.
-}
recordMultiInstance : (S -> List NumberMultiEntry) -> (List NumberMultiEntry -> S -> S) -> String -> String -> Mono.MonoType -> Step ( String, Mono.MonoType )
recordMultiInstance getStack setStack sep name monoType s =
        let
            update entry =
                -- Deliberately annotation-SENSITIVE (M4 == audit): local-multi
                -- instances are specialization-intent — differing lambda sets
                -- mint separate per-instance bindings (f / f$1), never share.
                -- `Mono.SpecMap` is the spec flavour (`specHashOf`/`eqKeySpec`),
                -- which is exactly the `toComparableMonoType` equivalence the
                -- string key used to give (§10.1).
                case Mono.specMapGet monoType entry.instances of
                    Just inst ->
                        ( entry, ( inst.freshName, inst.monoType ) )

                    Nothing ->
                        let
                            idx =
                                Mono.specMapSize entry.instances

                            freshName =
                                if idx == 0 then
                                    name

                                else
                                    name ++ sep ++ String.fromInt idx

                            inst =
                                { freshName = freshName, monoType = monoType }
                        in
                        ( { entry | instances = Mono.specMapInsert monoType inst entry.instances }
                        , ( freshName, monoType )
                        )

            go entries =
                case entries of
                    [] ->
                        ( [], ( name, monoType ) )

                    e :: rest ->
                        if e.defName == name then
                            let
                                ( e1, result ) =
                                    update e
                            in
                            ( e1 :: rest, result )

                        else
                            let
                                ( rest1, result ) =
                                    go rest
                            in
                            ( e :: rest1, result )

            ( newStack, res ) =
                go (getStack s)
        in
        Ok ( res, setStack newStack s )


{-| Run a step in a nested variable scope: bindings introduced inside are
discarded afterward (so they don't leak to sibling expressions). Mirrors the
original engine's varEnv push/pop.
-}
scoped : Step a -> Step a
scoped step s0 =
    case step s0 of
        Err e ->
            Err e

        Ok ( a, s1 ) ->
            Ok ( a, { s1 | varEnv = s0.varEnv } )


{-| Harvest number-taint (Join-R, §5.5) from the finished item's store into the
global super table: every Point that resolved to a `Number` super marks its
originating MVarId as `Number`. The shared Prune then closes any `MVar id
CEcoValue` whose `id` became a number through unification (e.g. a call argument
threading a `number` into a polymorphic parameter) to `MInt`, matching the
original engine's taint-then-close behaviour. Runs before the store is discarded.
-}
harvestSuperTable : S -> S
harvestSuperTable s =
    harvestSuperTableExcept EverySet.empty s


{-| Harvest, excluding the given MVarId keys. Annotation vars of the item's own
global MUST be excluded: they are re-instantiated at a different type by every
specialization of that global, and a Number binding from one spec would make
another spec's residuals stamp CNumber (→ closed to MInt) behind an
erased-typed call site — an ABI break (ListConcatMap empty-call crash).
-}
harvestSuperTableExcept : EverySet.EverySet Int Int -> S -> S
harvestSuperTableExcept excluded s =
    let
        -- A2: revMemo is now an Array indexed by point index; Array.foldl visits
        -- indices 0,1,2,… ascending (== the former Dict.foldl ascending-key order)
        -- with a threaded index counter, skipping empty (Nothing) structure-point
        -- slots (== keys the Dict never had). Byte-identical harvest.
        step maybeMvarId ( pointIdx, ( store, super ) ) =
            ( pointIdx + 1
            , case maybeMvarId of
                Nothing ->
                    ( store, super )

                Just mvarId ->
                    if EverySet.member identity (mvarIdKey mvarId) excluded then
                        ( store, super )

                    else
                        let
                            ( store1, desc ) =
                                UF.get (IO.Pt pointIdx) store
                        in
                        case desc.content of
                            IO.FlexSuper IO.Number _ ->
                                ( store1, CoreDict.insert (mvarIdKey mvarId) IO.Number super )

                            IO.RigidSuper IO.Number _ ->
                                ( store1, CoreDict.insert (mvarIdKey mvarId) IO.Number super )

                            _ ->
                                ( store1, super )
            )

        ( _, ( _, superTable1 ) ) =
            Array.foldl step ( 0, ( s.store, s.superTable ) ) s.revMemo
    in
    { s | superTable = superTable1 }



-- ====== M2 CACHES ======


lookupSchemeMono : String -> Step (Maybe Mono.MonoType)
lookupSchemeMono key =
    getS (\s -> CoreDict.get key s.monoMemo.schemeMono)


putSchemeMono : String -> Mono.MonoType -> Step ()
putSchemeMono key monoType =
    modifyS
        (\s ->
            let
                m =
                    s.monoMemo
            in
            { s | monoMemo = { m | schemeMono = CoreDict.insert key monoType m.schemeMono } }
        )


lookupCallMemo : Mono.SpecKey -> Step (Maybe ( Mono.MonoType, Mono.MonoType, Mono.SpecId ))
lookupCallMemo key =
    getS (\s -> Mono.specKeyMapGet key s.monoMemo.callMemo)


putCallMemo : Mono.SpecKey -> ( Mono.MonoType, Mono.MonoType, Mono.SpecId ) -> Step ()
putCallMemo key entry =
    modifyS
        (\s ->
            let
                m =
                    s.monoMemo
            in
            { s | monoMemo = { m | callMemo = Mono.specKeyMapInsert key entry m.callMemo } }
        )



-- ====== K6 INTERN TABLE ======


{-| Canonicalise one already-built type against `S.intern`.

Use it where a producer builds a single composite over children that are already
canonical — only the top node needs a probe. The RECURSIVE producers
(`Store.classifyGo`, `Store.zonkFlatC`, `Zonk.canTypeToMonoWithI`,
`Intern.widenSets`) hash-cons bottom-up instead, which is what keeps each bucket
confirm O(arity) rather than O(tree).

Direct state in/out rather than a `Step`: every call site is in the engine's
desugared direct-state style, where a `Result`-wrapped step would only have to be
unwrapped again.

-}
consS : Mono.MonoType -> S -> ( Mono.MonoType, S )
consS mt s =
    let
        ( mt1, intern1 ) =
            Intern.hashCons mt s.intern
    in
    ( mt1, withIntern intern1 s )


{-| Write a table back into `S` **only if it actually grew.**

This guard is not a micro-optimization, it is what makes S-threaded
hash-consing affordable. `consS` runs once per composite — order 10^7 times on a
self-compile — and an unconditional `{ s | intern = … }` would put a 31-slot
record copy on every one of them. It would also defeat `enqueueSpec`'s D2 path,
whose entire purpose is to return `S` untouched when nothing changed. (The subst
engine sidesteps this by threading a bare `Intern` through
`applySubstPureI`'s recursion; the solver's producers already thread `S`, so it
needs the guard instead.)

Size is an EXACT test for "unchanged", not an approximation: `Intern.hashCons`
either hits — returning the very table it was given — or inserts, and every
insert increments the count `Data.HashMap` carries. So equal counts imply the
same table value. `HashMap.size` reads that stored count, O(1).

-}
withIntern : Intern -> S -> S
withIntern intern1 s =
    if Intern.size intern1 == Intern.size s.intern then
        s

    else
        { s | intern = intern1 }



-- ====== KEYS ======


mvarIdKey : TypeIds.MVarId -> Int
mvarIdKey =
    Id.toComparable


{-| Ruling R1, operational: can NO function ever occur inside this type
variable? True only for `number` (Int | Float) and `comparable` (scalars, and
lists/tuples bottoming out in scalars). `appendable`/`compappend` reach a bare
element variable through their `List a` arm, so they answer False, as does any
variable the super table does not know — a miss is conservative, and the
failure direction is a missing license rather than a wrong one.

Read from the solver's own super table, so this is the typechecker's truth, not
a guess from a variable's spelling.
-}
isScalarVar : S -> TypeIds.MVarId -> Bool
isScalarVar s mid =
    case CoreDict.get (mvarIdKey mid) s.superTable of
        Just IO.Number ->
            True

        Just IO.Comparable ->
            True

        _ ->
            False

pointKey : IO.Variable -> Int
pointKey (IO.Pt n) =
    n
