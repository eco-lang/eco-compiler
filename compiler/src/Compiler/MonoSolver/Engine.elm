module Compiler.MonoSolver.Engine exposing
    ( S, Step, Failure(..), WorkItem(..)
    , traverse, foldlS, liftIO
    , freshVar, enqueueSpec
    , freshStore, resetItem
    , mvarIdKey, pointKey
    , AliasKey, AliasVerdict(..), ArrowFact, Env, GroundingStats, ItemAux, LayoutQualStats, LssMemberTable, LssSignature, LssStats, MemberSource(..), MonoMemo, NodeResolution, NumberInstance, NumberMultiEntry, QEntry(..), QPre(..), QShadowStats, SettledStats, SigFlowStats, SpecTally, aliasKeyEq, aliasKeyHash, bumpAppliedArrow, bumpArgFlowCensus, bumpArgFlowCensusBy, bumpCompletionJoin, bumpCompletionJoinNoop, bumpEdgeInstalled, bumpFlowDegraded, bumpKernelFactHit, bumpKernelLicensed, bumpTopMixedFlexSig, bumpWidenedByCf, bumpWidenedByKernel, bumpWidenedBySigSize, clearResidualReads, clearedAux, consS, crashFailure, emptyItemAux, emptyLssStats, emptyMemberTable, emptyMonoMemo, groundSetMembers, groundStandaloneMemberIdFor, harvestSuperTableExcept, insertVar, internMemberKey, isLocalMultiTarget, isScalarVar, kernelMemberIdFor, lambdaInstanceMemberId, layoutQualKey, localInstanceTagFor, localVarInfo, lookupCallMemo, lookupSchemeMono, lookupVar, markFlexCtorSpec, memberIdFor, membersClass, memoizedSignatureTrivial, mixTag, numberMultiRootType, papMemberIdFor, papMemberKey, popLocalMulti, popNumberMulti, pushLocalMulti, pushNumberMulti, putAliasVerdict, putCallMemo, putSchemeMono, recordLocalInstance, recordNumberInstance, recordSpecWidenedKey, renderFailure, restoredAux, scoped, specIdsForGlobal, srcLambdaKey, standaloneMemberGlobal, standaloneMemberIdFor, standaloneMemberKernel, trivialSignature, withScratchStore
    )

{-| The state the solver-based monomorphizer threads through all of its work,
and the primitives over that state which the other `Compiler.MonoSolver`
modules share.

Monomorphization turns a polymorphic program into one in which every function
is used at one concrete type. The solver engine does it one _work item_ at a
time. A work item is one specialization, or _spec_: one global definition at
one concrete `MonoType`, named by a `SpecId`. Translating a work item loads the
definition's types into a union-find _point store_ (an `IO.State` from
`System.TypeCheck.IO`), unifies them with the demanded type, and reads the
results back as `MonoType`s. Each work item starts with a fresh store, and every
store numbers its Points from 0, so a Point means nothing outside the store that
minted it.

That fact divides `S` in two. The run-global fields live for the whole run: the
worklist, the specialization registry, the translated nodes, the super table,
the lambda-set signatures and member table, the classification memos and the
hash-cons table `intern`. The per-item fields are replaced by `resetItem`
before each work item: the store, `memo` (MVarId to Point), `revMemo` (Point to
the first MVarId that minted it), the local variable environment, the
multi-instance stacks and `itemAux`. The `itemAux` fields that `clearedAux`
empties are _store-scoped_: `withScratchStore` runs a step against a separate
store, so it clears those fields on the way in and restores them on the way out.
`lssRootAnn` also holds a Point but is carried across the swap unchanged.

`Step a` is `S -> ( a, S )`: plain state passing, with no failure channel. A
construct the engine cannot handle, or a broken internal invariant, aborts the
process through `crashFailure`. A spec watchdog trip in `enqueueSpec` is instead
recorded in `ItemAux.pendingFailure`, for the driver in
`Compiler.MonoSolver.Monomorphize` to report once the item finishes. The few
combinators kept (`traverse`, `foldlS`, `scoped`, `withScratchStore`,
`liftIO`) take the state directly, and callers write their sequencing as
explicit `case ... of ( a, s1 )` chains: a function whose results are tuple
literals can have its multi-result return promoted by the native backend
(`Backend.buildSretPromoted`), and one written as a combinator chain cannot.

**Lambda-set specialization (LSS).** With `env.lss.enabled` on, every function
type carries a _lambda set_: the function values that can reach that position.
Each such value is a _member_, named by an integer _member id_. Member ids come
from one supply, `nextMemberId`, and one key table, `LssMemberTable.byKey`, so
minting a member is get-or-create on its key. The key forms are:

  - `g|<global>`, a reference to a global function, and `c|<global>`, a
    constructor used as a value. These are _provisional_: when a set is read
    back at a concrete arrow, `groundSetMembers` rewrites them to _ground_
    members `g|<global>|<typeKey>`, one per global and instantiation layout.
  - `k|<home>.<name>`, a kernel function, and `a|<field>`, a record accessor.
  - `p|<global>|<n>`, a partial application of a global with `n` arguments
    supplied. It is never grounded and never treated as the global itself,
    because a direct call to the global would drop the supplied arguments.
  - `l|<raw>|<qualifier>`, one instance of a source lambda, where `raw` is the
    lambda's id from `AssignMVarIds` and the qualifier names the spec it was
    translated in (see `lambdaInstanceMemberId`). A definition's root lambda
    uses its global's `g|<global>|<qualifier>` key instead, so that it is the
    same member a grounded reference to the global gives.

The supply is seeded above the source lambda ids, so a raw lambda id and an
interned id never collide. A raw lambda id is used un-interned in signatures,
and wherever LSS is off or no spec is being translated.

Much of the file is census: `LssStats` and its sub-records, and the `bump*`
functions, which count events for the LSS report (`lss.report`). Some count
only when the report is on, and their docstrings say so; the others count
always. Two fields of `LssStats` are also read by the engine (see `LssStats`).

@docs S, Step, Failure, WorkItem
@docs traverse, foldlS, liftIO
@docs freshVar, enqueueSpec
@docs freshStore, resetItem
@docs mvarIdKey, pointKey
@docs AliasKey, AliasVerdict, ArrowFact, Env, GroundingStats, ItemAux, LayoutQualStats, LssMemberTable, LssSignature, LssStats, MemberSource, MonoMemo, NodeResolution, NumberInstance, NumberMultiEntry, QEntry, QPre, QShadowStats, SettledStats, SigFlowStats, SpecTally, aliasKeyEq, aliasKeyHash, bumpAppliedArrow, bumpArgFlowCensus, bumpArgFlowCensusBy, bumpCompletionJoin, bumpCompletionJoinNoop, bumpEdgeInstalled, bumpFlowDegraded, bumpKernelFactHit, bumpKernelLicensed, bumpTopMixedFlexSig, bumpWidenedByCf, bumpWidenedByKernel, bumpWidenedBySigSize, clearResidualReads, clearedAux, consS, crashFailure, emptyItemAux, emptyLssStats, emptyMemberTable, emptyMonoMemo, groundSetMembers, groundStandaloneMemberIdFor, harvestSuperTableExcept, insertVar, internMemberKey, isLocalMultiTarget, isScalarVar, kernelMemberIdFor, lambdaInstanceMemberId, layoutQualKey, localInstanceTagFor, localVarInfo, lookupCallMemo, lookupSchemeMono, lookupVar, markFlexCtorSpec, memberIdFor, membersClass, memoizedSignatureTrivial, mixTag, numberMultiRootType, papMemberIdFor, papMemberKey, popLocalMulti, popNumberMulti, pushLocalMulti, pushNumberMulti, putAliasVerdict, putCallMemo, putSchemeMono, recordLocalInstance, recordNumberInstance, recordSpecWidenedKey, renderFailure, restoredAux, scoped, specIdsForGlobal, srcLambdaKey, standaloneMemberGlobal, standaloneMemberIdFor, standaloneMemberKernel, trivialSignature, withScratchStore

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Intern as Intern exposing (Intern)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Data.Id as Id
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.Registry as Registry
import Compiler.Type.Type as Type
import Compiler.Type.UnionFind as UF
import Data.HashMap as HashMap
import Data.Set as EverySet
import Dict as CoreDict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash as Crash



-- ====== STATE ======


{-| A unit of pending work on the worklist: translate the spec named by this
`SpecId`.
-}
type WorkItem
    = SpecializeGlobal Mono.SpecId


{-| The specs created so far for one global under LSS: how many, for the
per-global spec budget, and their ids, newest first.
-}
type alias SpecTally =
    { count : Int
    , ids : List Int
    }


{-| The tally of a global with no specs.
-}
emptySpecTally : SpecTally
emptySpecTally =
    { count = 0, ids = [] }


{-| Returns the ids of the specs created for the global whose comparable key is
`gkey`, newest first. The list is empty when LSS is off, because the tally is
kept only by the LSS path of `enqueueSpec`.
-}
specIdsForGlobal : String -> S -> List Int
specIdsForGlobal gkey s =
    case CoreDict.get gkey s.specCountByGlobal of
        Just tally ->
            tally.ids

        Nothing ->
            []


{-| What a definition's body says about the lambda set of one arrow in its
annotation, as part of an `LssSignature`.

`rep` is the smallest arrow ordinal whose set the body unified with this one,
so two arrows with equal `rep` share one set (in `twice : (a -> a) -> a -> a`
both arrows are one function value). `members` are the member ids the body
itself puts in this arrow's set. `top` means the body forces the set to ⊤,
the set that may hold anything. `topKind` records the cause of that ⊤ and is
meaningful only when `top` is set. `sources` are ordinals whose sets flow into
this one: an inclusion, not an equality, which a caller installs as directed
edges in its own store.

-}
type alias ArrowFact =
    { rep : Int
    , members : List Int
    , top : Bool
    , topKind : Int
    , sources : List Int
    }


{-| A definition's lambda-set signature: the facts a caller applies to the
arrows of a fresh instantiation of the definition's annotation.

`arrows` is indexed by arrow ordinal, the position of the arrow's set slot in
the slot array that `Store.loadTypeWithArrows` or
`Store.loadTypeIsolatedWithArrows` mints for that same annotation. `trivial`
means every fact is the default one (`trivialSignature`). `residual` restates
the `members` of each arrow as pairs of the arrow's representative ordinal
(`rep`) and its member ids, for a
caller to apply as constraints against a fresh instantiation.

-}
type alias LssSignature =
    { arrows : Array ArrowFact
    , trivial : Bool
    , residual : List ( Int, List Int )
    }


{-| The run's LSS counters and histograms, printed by the LSS report.

Most of them are census only. Two are also read by the engine.
`flexCtorSpecs` holds the constructor specs demanded by a construction whose
translated argument carried an unresolved arrow, and the settle pass
`settleVarCtorRows` reads it. `joinRounds` counts the rounds, after the
worklist drains, that re-translate dirty specs, and the driver stops with an
error when it reaches its cap; `retranslations` counts the specs those rounds
re-translate.

-}
type alias LssStats =
    { setsZonked : Int
    , flexCtorSpecs : CoreDict.Dict Int ()
    , joinRounds : Int
    , retranslations : Int
    , widenedBySize : Int
    , widenedByKernel : Int
    , widenedByBudget : Int
    , devirtDirect : Int -- indirect calls through a one-member set of a constructor or function global, rewritten to direct calls
    , devirtKernel : Int -- calls through a set whose one member is a kernel or a kernel alias, rewritten to direct kernel calls
    , sizeHist : CoreDict.Dict Int Int -- set size at read-back -> count
    , unqualifiedLambdaMints : Int -- lambda instances minted with LSS on and no spec being translated

    -- Why a one-kernel set was not turned into a direct kernel call
    , declinedKernelShape : Int -- the call site's type is not the kernel's expected shape
    , declinedKernelCNumber : Int -- an unresolved number variable remains at the site
    , declinedKernelEmission : Int
    , declinedKernelArity : Int -- the call's arity is not the one the kernel is listed with
    , kernelUnsolvedHist : CoreDict.Dict String Int -- licensed kernels whose check at an occurrence failed -> count
    , kernelMissHist : CoreDict.Dict String Int -- "home.name" of kernels not on the direct-call list -> call sites

    -- How set writes and registry joins went
    , setWriteSkip : Int
    , setWriteFlex : Int
    , setWriteTopJoin : Int
    , setWriteUnion : Int
    , joinIdenticalHit : Int -- registry hit with a demand identical to the stored type
    , joinNoop : Int -- registry hit whose join changed nothing
    , joinChanged : Int -- registry hit whose join widened the stored type
    , completionJoins : Int
    , completionJoinNoop : Int
    , widenedSizeHist : CoreDict.Dict Int Int -- size -> count of sets widened to top for exceeding `maxSetSize`
    , slotsMinted : Int
    , grounding : GroundingStats
    , sigStats : SigFlowStats
    , layoutQual : LayoutQualStats
    }


{-| Census counters for minting lambda-instance members (see
`lambdaInstanceMemberId`).

`mints` counts every qualified lambda mint, including a definition's root
lambda. `shared` counts mints whose id was first minted under a different spec.
`fallback` counts mints whose spec had no recorded widened key and so were
qualified by `SpecId`. `tieBypass` counts mints where the spec's demand already
carried the very id the key gives, so no μ-tie was recorded. `instApplied`
counts mints that carried an instance tag, `instCapped` the instance tags
refused at the `maxInstances` cap, and `instRootSkip` the tags refused because
the lambda is a definition's root lambda.

-}
type alias LayoutQualStats =
    { mints : Int
    , shared : Int
    , fallback : Int
    , tieBypass : Int
    , instApplied : Int
    , instCapped : Int
    , instRootSkip : Int
    }


{-| Census counters for `groundSetMembers`: provisional members rewritten to
ground ones, and provisional members left as they were because the arrow being
read back still contained unresolved type variables.
-}
type alias GroundingStats =
    { grounded : Int
    , deferred : Int
    }


{-| Census counters about how lambda sets flow through signatures, kernel
boundaries and call arguments, plus the two nested census records
`QShadowStats` and `SettledStats`.

`widenedBySigSize`, `topMixedFlexSig` and `topMixedFlexDemand` are policy
counters, bumped whether or not the report is on: the first counts signature
arrows whose member list exceeded `maxSetSize` and became ⊤, the other two
count sets resolved to ⊤ because a source they drew from was never written.
The other counters, and the dictionaries, are filled only under `lss.report`
(`qShadow` and `qInfer` follow the census settings their writers check).
`kernelFactHits` counts kernel boundaries handled by a positional fact row and
`kernelLicensed` those passed through by a license. `multiSetsByArrow` maps an
arrow's `ArrowId` to the union of every set of two or more members read back
there, and `appliedArrows` counts how often each arrow was applied to an
argument. Both are keyed by `ArrowId` and survive `resetItem`, so they gather
across specs.

-}
type alias SigFlowStats =
    { widenedBySigSize : Int
    , widenedByCf : Int
    , kernelFactHits : Int
    , kernelLicensed : Int
    , edgesInstalled : Int
    , flowDegraded : Int -- container subtrees joined both ways, not directed, that could carry a set
    , multiSetsByArrow : CoreDict.Dict Int (List Int)
    , appliedArrows : CoreDict.Dict Int Int
    , topMixedFlexSig : Int
    , topMixedFlexDemand : Int
    , argFlowCensus : CoreDict.Dict String Int -- census key -> count
    , settled : SettledStats
    , qShadow : QShadowStats -- scored per specialized item; a divergence here is expected
    , qInfer : QShadowStats -- scored per signature-inference unit
    }


{-| A census that compares two ways of computing lambda sets, accumulated
across work items.

The store computes each set eagerly, joining members into a slot as they are
written. Alongside that, each write can be recorded as an inclusion constraint
(a `QEntry` in `ItemAux.qLog`), and at the end of an item the least solution of
those constraints is compared, slot class by slot class, with what the store
holds. A slot class is the set of slots the solver unified into one. `agree`
counts classes where the two answers are equal, and the `diverge*` counters
count the ways they differ. `unresolved` counts classes the store still holds
as unconstrained at the end of the item. `reaching` and `internal` split the
constrained classes by whether the definition's root type reaches them, and
are zero for an item without a root (`sigRoots` counts items with one).
`subMerged` and `subUnseen` classify the `divergeSub` classes by whether the
missing member appears elsewhere in the item's constraints. `divergeSamples`
holds a capped list of diverging classes for a person to read.

-}
type alias QShadowStats =
    { items : Int -- items with at least one recorded constraint
    , members : Int -- member constraints recorded
    , tops : Int -- top constraints recorded
    , edges : Int -- edge constraints recorded
    , classes : Int -- slot classes in the recorded constraints at item end
    , agree : Int -- classes where shadow == eager
    , divergeSuper : Int -- shadow ⊋ eager  (the constraint solution over-approximates: a missed absorb)
    , divergeSub : Int -- shadow ⊊ eager  (the constraint solution under-records: a write path not instrumented)
    , divergeTop : Int -- one side is ⊤ and the other is not
    , divergeOther : Int -- incomparable member sets
    , unresolved : Int -- classes still unconstrained at item end (no eager answer to compare)
    , edgeClasses : Int -- classes reached only through an edge, not by a direct member write
    , sigRoots : Int
    , reaching : Int
    , internal : Int
    , scratchDropped : Int -- constraints recorded inside a scratch store and dropped with it
    , subMerged : Int
    , subUnseen : Int
    , internAgree : Int -- `agree`, restricted to the `internal` classes
    , internDiverge : Int
    , divergeSamples : List String
    }


{-| A `QShadowStats` with every counter zero and no samples.
-}
emptyQShadowStats : QShadowStats
emptyQShadowStats =
    { items = 0, members = 0, tops = 0, edges = 0, classes = 0, agree = 0, divergeSuper = 0, divergeSub = 0, divergeTop = 0, divergeOther = 0, unresolved = 0, edgeClasses = 0, sigRoots = 0, reaching = 0, internal = 0, scratchDropped = 0, subMerged = 0, subUnseen = 0, internAgree = 0, internDiverge = 0, divergeSamples = [] }


{-| A census of the same set read-backs made during translation, repeated when
the item finishes, against the same store after every write in the item has
landed. It is filled only under `lss.report`.

`zonked` should equal the `setsZonked` counted during translation, less the
read-backs made inside scratch stores (`scratchDropped`), which cannot be
repeated because their store is gone. `causeTop` counts read-backs that are
still ⊤ and `causeVar` those that are still unresolved. `varArrows` and
`setArrows` count, per `ArrowId`, the read-backs that came out unresolved and
the ones that came out as a concrete set; they are empty unless arrow identity
is recorded (`ItemAux.arrowOfSlot`).

-}
type alias SettledStats =
    { items : Int -- items whose log was replayed
    , zonked : Int
    , hist : CoreDict.Dict Int Int -- set size at item end -> count
    , widenedBySize : Int
    , causeTop : Int
    , causeVar : Int
    , varArrows : CoreDict.Dict Int Int
    , setArrows : CoreDict.Dict Int Int
    , scratchDropped : Int
    }


{-| A `SettledStats` with every counter zero and every table empty.
-}
emptySettledStats : SettledStats
emptySettledStats =
    { items = 0, zonked = 0, hist = CoreDict.empty, widenedBySize = 0, causeTop = 0, causeVar = 0, varArrows = CoreDict.empty, setArrows = CoreDict.empty, scratchDropped = 0 }


{-| What a non-lambda member stands for, recorded in `LssMemberTable.sources`.

`SourceGlobal` is a global function or constructor. It is recorded for `g|`
and `c|` members, for ground `g|<global>|<typeKey>` members, and for a
definition's root lambda (see `lambdaInstanceMemberId`).

`SourceKernel` is a kernel function, as its prefix, home and name.

`SourcePap` is a partial application of a global with the given number of
arguments supplied. It is recorded only so that the member can be named; it is
not the global, and `standaloneMemberGlobal` gives no global for it.

-}
type MemberSource
    = SourceGlobal TOpt.Global
    | SourceKernel ( String, String, String )
    | SourcePap TOpt.Global Int


{-| The run's table of member keys and what is known about each member id.

`byKey` is the interning table: key to member id. `sources` says what a
non-lambda member stands for. `lambdaQualified` maps a qualified lambda member
to the lambda key it was minted from (the raw id, or the raw id mixed with an
instance tag) and the first spec that minted it; several specs can share the
id, so the spec is only the first. `muTied` holds the ids a μ-tie has reused
(see `lambdaInstanceMemberId`). `provisionalStandalone` holds exactly the
provisional `g|`/`c|` ids, with their global, and is what `groundSetMembers`
rewrites; ground ids are never in it. `specWidenedKeys` maps a `SpecId` to the
annotation-widened rendering of its creation type, recorded once when the spec
is created. `rootLamOf` maps a raw lambda id to the global whose definition it
is the root lambda of; a lambda absent from it mints an `l|` key.

-}
type alias LssMemberTable =
    { byKey : CoreDict.Dict String Int
    , sources : CoreDict.Dict Int MemberSource
    , lambdaQualified : CoreDict.Dict Int ( Int, Int )
    , muTied : CoreDict.Dict Int ()
    , provisionalStandalone : CoreDict.Dict Int TOpt.Global
    , specWidenedKeys : CoreDict.Dict Int String
    , rootLamOf : CoreDict.Dict Int TOpt.Global
    }


{-| The run's memos of type classifications that do not depend on the work
item, so they survive `resetItem`.

`schemeMono` holds the mono type of a callee whose type scheme has no type
variables, keyed by the global's comparable key. `callMemo` holds, for a call
to a polymorphic callee at ground argument types, the callee's mono type, the
result's mono type and the `SpecId` it was enqueued as, keyed by a
`Mono.SpecKey`. `aliasMemo` holds what is known about an instantiation of a
type alias (see `AliasKey`).

-}
type alias MonoMemo =
    { schemeMono : CoreDict.Dict String Mono.MonoType
    , callMemo : Mono.SpecKeyMap ( Mono.MonoType, Mono.MonoType, Mono.SpecId )
    , aliasMemo : HashMap.HashMap AliasKey AliasVerdict
    }


{-| A `MonoMemo` with all three memo tables empty.
-}
emptyMonoMemo : MonoMemo
emptyMonoMemo =
    { schemeMono = CoreDict.empty, callMemo = Mono.specKeyMapEmpty, aliasMemo = HashMap.empty }


{-| The identity of one instantiation of a type alias, for `MonoMemo.aliasMemo`.

An alias is defined once in its module, so its home, its name and its argument
types determine what it expands to. `args` holds the argument types only: the
ids paired with them in `Can.TAlias` are not part of the identity. `hash` is
stored so that it is computed once, by whoever builds the key.

-}
type alias AliasKey =
    { hash : Int
    , home : ModuleName.Canonical
    , name : String
    , args : List (Can.Type TypeIds.MVarId)
    }


{-| What the run has learned about one alias instantiation.

`AliasIneligible` means the instantiation is not memoised. `AliasGround`
carries its classification as a mono type, the interned copy from `S.intern`.

-}
type AliasVerdict
    = AliasIneligible
    | AliasGround Mono.MonoType


{-| Returns the hash stored in an `AliasKey`.
-}
aliasKeyHash : AliasKey -> Int
aliasKeyHash k =
    k.hash


{-| Tells whether two `AliasKey`s have the same name, home and argument types.
The stored hashes are not compared.
-}
aliasKeyEq : AliasKey -> AliasKey -> Bool
aliasKeyEq a b =
    a.name == b.name && a.home == b.home && a.args == b.args


{-| Records a verdict for an alias instantiation in `MonoMemo.aliasMemo`,
replacing any earlier one. Entries are never removed.
-}
putAliasVerdict : AliasKey -> AliasVerdict -> S -> S
putAliasVerdict key v s =
    let
        m =
            s.monoMemo
    in
    { s | monoMemo = { m | aliasMemo = HashMap.insert aliasKeyHash aliasKeyEq key v m.aliasMemo } }


{-| An `LssMemberTable` with no members registered.
-}
emptyMemberTable : LssMemberTable
emptyMemberTable =
    { byKey = CoreDict.empty, sources = CoreDict.empty, lambdaQualified = CoreDict.empty, muTied = CoreDict.empty, provisionalStandalone = CoreDict.empty, specWidenedKeys = CoreDict.empty, rootLamOf = CoreDict.empty }


{-| Adds a key and its member id to the interning table.
-}
insertMemberKey : String -> Int -> LssMemberTable -> LssMemberTable
insertMemberKey key mid t =
    { t | byKey = CoreDict.insert key mid t.byKey }


{-| Records that a member id stands for a global, replacing any earlier source.
-}
insertMemberGlobal : Int -> TOpt.Global -> LssMemberTable -> LssMemberTable
insertMemberGlobal mid g t =
    { t | sources = CoreDict.insert mid (SourceGlobal g) t.sources }


{-| Records that a member id stands for a kernel function, replacing any earlier
source.
-}
insertMemberKernel : Int -> ( String, String, String ) -> LssMemberTable -> LssMemberTable
insertMemberKernel mid k t =
    { t | sources = CoreDict.insert mid (SourceKernel k) t.sources }


{-| Marks a member id as a provisional member of the given global.
-}
insertMemberProvisional : Int -> TOpt.Global -> LssMemberTable -> LssMemberTable
insertMemberProvisional mid g t =
    { t | provisionalStandalone = CoreDict.insert mid g t.provisionalStandalone }


{-| An `LssStats` with every counter zero and every histogram empty.
-}
emptyLssStats : LssStats
emptyLssStats =
    { setsZonked = 0, flexCtorSpecs = CoreDict.empty, joinRounds = 0, retranslations = 0, widenedBySize = 0, widenedByKernel = 0, widenedByBudget = 0, devirtDirect = 0, devirtKernel = 0, sizeHist = CoreDict.empty, unqualifiedLambdaMints = 0, declinedKernelShape = 0, declinedKernelCNumber = 0, declinedKernelEmission = 0, declinedKernelArity = 0, kernelUnsolvedHist = CoreDict.empty, kernelMissHist = CoreDict.empty, setWriteSkip = 0, setWriteFlex = 0, setWriteTopJoin = 0, setWriteUnion = 0, joinIdenticalHit = 0, joinNoop = 0, joinChanged = 0, completionJoins = 0, completionJoinNoop = 0, widenedSizeHist = CoreDict.empty, slotsMinted = 0, grounding = { grounded = 0, deferred = 0 }, sigStats = { widenedBySigSize = 0, widenedByCf = 0, kernelFactHits = 0, kernelLicensed = 0, edgesInstalled = 0, flowDegraded = 0, multiSetsByArrow = CoreDict.empty, appliedArrows = CoreDict.empty, topMixedFlexSig = 0, topMixedFlexDemand = 0, argFlowCensus = CoreDict.empty, settled = emptySettledStats, qShadow = emptyQShadowStats, qInfer = emptyQShadowStats }, layoutQual = { mints = 0, shared = 0, fallback = 0, tieBypass = 0, instApplied = 0, instCapped = 0, instRootSkip = 0 } }


{-| Returns the signature that says nothing, for an annotation with `n`
arrows: each arrow its own representative, with no members, no ⊤ and no
sources.
-}
trivialSignature : Int -> LssSignature
trivialSignature n =
    { arrows = Array.initialize n (\i -> { rep = i, members = [], top = False, topKind = Mono.tkLegacy, sources = [] })
    , trivial = True
    , residual = []
    }


{-| Returns a source lambda's raw member id: its `SrcLambdaId` as an integer.
This is the id used for a lambda where no qualified id is minted (see
`lambdaInstanceMemberId`).
-}
srcLambdaKey : TypeIds.SrcLambdaId -> Int
srcLambdaKey =
    Id.toComparable


{-| Returns the instance tag for ordinal `ord` nested inside the enclosing tag
`tag`, so that the same ordinal inside two different enclosing instances gets
two different tags.

An instance tag of 0 means "not inside any instance". The `+ 1` keeps
`mixTag 0 ord` away from 0 for small ordinals, but the result is a hash and can
still be 0 by collision, in which case the instance is treated as untagged.

-}
mixTag : Int -> Int -> Int
mixTag tag ord =
    modBy 1073741789 (tag * 1000003 + ord + 1)


{-| Returns the instance tag under which instance `ord` of a let-bound
function is re-translated, given the enclosing tag in
`ItemAux.currentLocalInstance`.

A let-bound function used at several types is translated once per type, and
each translation is an _instance_ with an ordinal, 0 for the first. Lambdas
minted inside instance `ord` are tagged so that their member ids differ from
those of the other instances (see `lambdaInstanceMemberId`).

With LSS off the enclosing tag is returned unchanged. Ordinal 0 gets the
enclosing level's shared tag: 0 when the enclosing tag is 0, so a function with
one instance mints the same ids as if it had none, and `mixTag tag 0`
otherwise. Ordinal 0 must be composed under a non-zero tag because a lambda's
tag stands for the whole path of ordinals enclosing it: if a 0 after a
non-zero ordinal were dropped, (outer 0, inner 1) and (outer 1, inner 0) would
both get `mixTag 0 1`. Any other ordinal gets the enclosing tag composed with
`ord`, unless `stamp.maxInstances` is positive and `ord` is at or above it: then
the instance gets the shared tag and `instCapped` is counted. So a cap of `k`
gives at most `k` distinct tags per level, and a cap of 1 tags nothing.

-}
localInstanceTagFor : Int -> S -> ( Int, S )
localInstanceTagFor ord s =
    let
        cfg =
            s.env.lss.stamp

        outer =
            s.itemAux.currentLocalInstance

        -- The tag of this level's shared (ordinal-0 / capped) class.
        sharedTag =
            if outer == 0 then
                0

            else
                mixTag outer 0
    in
    if not s.env.lss.enabled then
        ( outer, s )

    else if ord == 0 then
        ( sharedTag, s )

    else if cfg.maxInstances > 0 && ord >= cfg.maxInstances then
        ( sharedTag, bumpInstanceQual (\lq -> { lq | instCapped = lq.instCapped + 1 }) s )

    else
        ( mixTag outer ord, s )


{-| Applies `f` to the `layoutQual` census counters.
-}
bumpInstanceQual : (LayoutQualStats -> LayoutQualStats) -> S -> S
bumpInstanceQual f s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | layoutQual = f stats.layoutQual } }


{-| Returns the instance tag for a mint of source lambda `raw`: the current
instance tag, or 0 when there is none or when `raw` is a definition's root
lambda.

A root lambda mints its global's ground key, which grounding also produces
from a plain reference to the global, and a reference carries no tag. A tag
would make the two ids differ, so it is refused and `instRootSkip` is counted.

-}
instanceQualTagFor : Int -> S -> ( Int, S )
instanceQualTagFor raw s =
    if s.itemAux.currentLocalInstance == 0 then
        ( 0, s )

    else if CoreDict.member raw s.lssMemberTable.rootLamOf then
        ( 0, bumpInstanceQual (\lq -> { lq | instRootSkip = lq.instRootSkip + 1 }) s )

    else
        ( s.itemAux.currentLocalInstance, s )


{-| Returns the key that names a lambda within one instance: the raw lambda id
when `instTag` is 0, otherwise the raw id mixed with the tag. It keys
`ItemAux.demandQualified` and the first component of
`LssMemberTable.lambdaQualified`.
-}
qualifiedRawKey : Int -> Int -> Int
qualifiedRawKey raw instTag =
    if instTag == 0 then
        raw

    else
        mixTag raw instTag


{-| Returns `key` with `|#<instTag>` appended, or `key` unchanged when
`instTag` is 0.
-}
withInstTag : Int -> String -> String
withInstTag instTag key =
    if instTag == 0 then
        key

    else
        key ++ "|#" ++ String.fromInt instTag


{-| Returns the member id for one instance of source lambda `lamId`, minted
while translating a spec.

One source lambda is translated once per spec of its enclosing definition, and
those copies can capture values of different layouts, so they must not all be
one member. With LSS on and a spec being translated
(`ItemAux.currentSpecId`), the id is interned under a key qualified by that
spec, as `lambdaMemberLayoutQualified` describes: by the spec's
annotation-widened creation key, so that specs differing only in lambda sets
share the id, and by the instance tag when the lambda is inside an instance of
a let-bound function. A definition's root lambda uses its global's `g|` key
instead. Interning is get-or-create, so the same key always gives the same id.

With LSS off the raw id (`srcLambdaKey`) is returned. With LSS on and no spec
being translated the raw id is returned too, and `unqualifiedLambdaMints` is
counted.

-}
lambdaInstanceMemberId : TypeIds.SrcLambdaId -> S -> ( Int, S )
lambdaInstanceMemberId lamId s0 =
    let
        raw =
            srcLambdaKey lamId
    in
    if not s0.env.lss.enabled then
        ( raw, s0 )

    else
        case s0.itemAux.currentSpecId of
            Just specId ->
                case instanceQualTagFor raw s0 of
                    ( instTag, s0i ) ->
                        lambdaInstanceMemberGo raw instTag specId s0i

            Nothing ->
                let
                    stats =
                        s0.lssStats
                in
                ( raw, { s0 | lssStats = { stats | unqualifiedLambdaMints = stats.unqualifiedLambdaMints + 1 } } )


{-| Returns the member id for lambda `raw` under instance tag `instTag` in spec
`specId`; it is `lambdaMemberLayoutQualified`.
-}
lambdaInstanceMemberGo : Int -> Int -> Int -> S -> ( Int, S )
lambdaInstanceMemberGo raw instTag specId s0 =
    lambdaMemberLayoutQualified raw instTag specId s0


{-| Returns the member id for lambda `raw`, under instance tag `instTag`,
minted while translating spec `specId`.

The key is `layoutQualKey`'s: `l|<raw>|<widened key>` from the spec's
annotation-widened creation key in `specWidenedKeys`, or `l|<raw>|<specId>`
when none was recorded, with the instance tag appended when it is not 0. Two
specs whose types differ only in their lambda sets have equal widened keys, so
the lambda gets one id in both. When `raw` is a definition's root lambda
(`rootLamOf`), the `l|<raw>` head of the key is replaced by `g|<global>`, so
the id is the one grounding gives a reference to that global at the same
layout, and the id is recorded as a `SourceGlobal`.

Before minting, the spec's stored demand is consulted (`ItemAux.demandQualified`,
keyed by `qualifiedRawKey`). If the demand already carries an id for this
lambda and that id differs from the one the key has interned, the demand's id
is returned instead and recorded in `muTied`: this is the _μ-tie_. It stops a
recursive function whose specs keep feeding their own lambda back into their
demand from minting a new id, and so a new spec, at every step. When the
demand's id is the one the key has interned, nothing is recorded in `muTied`
and the mint is counted as a `tieBypass`. So one lambda in two same-layout
specs can still get two ids, when a demand carries a different one.

-}
lambdaMemberLayoutQualified : Int -> Int -> Int -> S -> ( Int, S )
lambdaMemberLayoutQualified raw instTag specId s0 =
    let
        ( plainKey, isFallback ) =
            layoutQualKey s0.lssMemberTable.specWidenedKeys raw instTag specId

        ( key, foldedTo ) =
            case CoreDict.get raw s0.lssMemberTable.rootLamOf of
                Just g ->
                    ( "g|"
                        ++ TOpt.toComparableGlobal g
                        ++ String.dropLeft (String.length ("l|" ++ String.fromInt raw)) plainKey
                    , Just g
                    )

                Nothing ->
                    ( plainKey, Nothing )
    in
    case CoreDict.get (qualifiedRawKey raw instTag) s0.itemAux.demandQualified of
        Just tiedId ->
            if CoreDict.get key s0.lssMemberTable.byKey == Just tiedId then
                mintLayoutQualifiedFold foldedTo key raw instTag specId isFallback True s0

            else
                ( tiedId, recordMuTied tiedId s0 )

        Nothing ->
            mintLayoutQualifiedFold foldedTo key raw instTag specId isFallback False s0


{-| Returns the key a lambda mint interns, and whether it fell back to the
`SpecId`.

Given the table of recorded widened keys, the key for lambda `raw` in spec
`specId` is `l|<raw>|<widened key>` when that spec has a recorded key, and
`l|<raw>|<specId>` with `True` when it has none. A non-zero `instTag` is
appended as `|#<instTag>`.

-}
layoutQualKey : CoreDict.Dict Int String -> Int -> Int -> Int -> ( String, Bool )
layoutQualKey specWidenedKeys raw instTag specId =
    case CoreDict.get specId specWidenedKeys of
        Just wkey ->
            ( withInstTag instTag ("l|" ++ String.fromInt raw ++ "|" ++ wkey), False )

        Nothing ->
            ( withInstTag instTag ("l|" ++ String.fromInt raw ++ "|" ++ String.fromInt specId), True )


{-| Mints `key` as `mintLayoutQualified` does and, when the key is a root
lambda's (`foldedTo` is the global), records the id as a `SourceGlobal` of that
global unless it already has a source. The id is not marked provisional.
Under `lss.report`, each root-lambda mint is counted as `rootFold|folded`.
-}
mintLayoutQualifiedFold : Maybe TOpt.Global -> String -> Int -> Int -> Int -> Bool -> Bool -> S -> ( Int, S )
mintLayoutQualifiedFold foldedTo key raw instTag specId isFallback isTieBypass s0 =
    case mintLayoutQualified key raw instTag specId isFallback isTieBypass s0 of
        ( mid, s1 ) ->
            case foldedTo of
                Just g ->
                    if CoreDict.member mid s1.lssMemberTable.sources then
                        ( mid, bumpArgFlowCensus "rootFold|folded" s1 )

                    else
                        ( mid
                        , bumpArgFlowCensus "rootFold|folded"
                            { s1 | lssMemberTable = insertMemberGlobal mid g s1.lssMemberTable }
                        )

                Nothing ->
                    ( mid, s1 )


{-| Interns `key` and returns its id, recording in `lambdaQualified` the
lambda key and spec of the first mint of that id, and counting the mint in the
`layoutQual` census. `shared` is counted when the id's first mint was in a
different spec.
-}
mintLayoutQualified : String -> Int -> Int -> Int -> Bool -> Bool -> S -> ( Int, S )
mintLayoutQualified key raw instTag specId isFallback isTieBypass s0 =
    case memberIdFor key s0 of
        ( mid, s1 ) ->
            let
                sharedInc =
                    case CoreDict.get mid s1.lssMemberTable.lambdaQualified of
                        Just ( _, firstSpec ) ->
                            if firstSpec /= specId then
                                1

                            else
                                0

                        Nothing ->
                            0

                stats =
                    s1.lssStats

                lq =
                    stats.layoutQual

                s2 =
                    { s1
                        | lssStats =
                            { stats
                                | layoutQual =
                                    { mints = lq.mints + 1
                                    , shared = lq.shared + sharedInc
                                    , fallback =
                                        lq.fallback
                                            + (if isFallback then
                                                1

                                               else
                                                0
                                              )
                                    , tieBypass =
                                        lq.tieBypass
                                            + (if isTieBypass then
                                                1

                                               else
                                                0
                                              )
                                    , instApplied =
                                        lq.instApplied
                                            + (if instTag /= 0 then
                                                1

                                               else
                                                0
                                              )
                                    , instCapped = lq.instCapped
                                    , instRootSkip = lq.instRootSkip
                                    }
                            }
                    }

                table =
                    s2.lssMemberTable
            in
            if CoreDict.member mid table.lambdaQualified then
                ( mid, s2 )

            else
                ( mid, { s2 | lssMemberTable = { table | lambdaQualified = CoreDict.insert mid ( qualifiedRawKey raw instTag, specId ) table.lambdaQualified } } )


{-| Records `wkey` as the annotation-widened creation key of spec `specId`,
unless the spec already has one, which is kept.
-}
recordSpecWidenedKey : Int -> String -> S -> S
recordSpecWidenedKey specId wkey s =
    let
        table =
            s.lssMemberTable
    in
    if CoreDict.member specId table.specWidenedKeys then
        s

    else
        { s | lssMemberTable = { table | specWidenedKeys = CoreDict.insert specId wkey table.specWidenedKeys } }


{-| Adds a member id to the set of μ-tied ids, `LssMemberTable.muTied`.
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


{-| Counts one kernel boundary that forced a lambda set to ⊤ in
`widenedByKernel`. A policy counter: it counts whether or not the report is on.
-}
bumpWidenedByKernel : S -> S
bumpWidenedByKernel s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | widenedByKernel = stats.widenedByKernel + 1 } }


{-| Counts one signature arrow whose member list exceeded `maxSetSize` and
became ⊤. A policy counter: it counts whether or not the report is on.
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


{-| Counts, under `lss.report`, one lambda set forced to ⊤ while joining sets
along a signature's flow.
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


{-| Counts, under `lss.report`, one kernel boundary handled by a positional
row of kernel set facts.
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


{-| Counts, under `lss.report`, one directed inclusion edge installed between
two set slots.
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


{-| Counts, under `lss.report`, one container subtree that a directed walk
joined both ways instead, where the subtree can carry a lambda set.
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


{-| Counts, under `lss.report`, one kernel boundary passed through without
forcing ⊤ because the kernel is licensed as type-faithful.
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


{-| Counts one signature-side set that drew on a source never written and so
was resolved to ⊤ rather than to its known members. A policy counter: it counts
whether or not the report is on.
-}
bumpTopMixedFlexSig : S -> S
bumpTopMixedFlexSig s =
    let
        stats =
            s.lssStats

        sig =
            stats.sigStats
    in
    { s | lssStats = { stats | sigStats = { sig | topMixedFlexSig = sig.topMixedFlexSig + 1 } } }


{-| Records constructor spec `specId` in `LssStats.flexCtorSpecs`: a
construction whose translated argument carried an unresolved arrow demanded it.
Unlike the census counters this is recorded whether or not the report is on,
because the settle pass `settleVarCtorRows` reads it.
-}
markFlexCtorSpec : Int -> S -> S
markFlexCtorSpec specId s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | flexCtorSpecs = CoreDict.insert specId () stats.flexCtorSpecs } }


{-| Adds one, under `lss.report`, to the census row `key` of
`argFlowCensus`.
-}
bumpArgFlowCensus : String -> S -> S
bumpArgFlowCensus key s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats

            n =
                Maybe.withDefault 0 (CoreDict.get key sig.argFlowCensus)
        in
        { s | lssStats = { stats | sigStats = { sig | argFlowCensus = CoreDict.insert key (n + 1) sig.argFlowCensus } } }

    else
        s


{-| Adds `delta`, under `lss.report`, to the census row `key` of
`argFlowCensus`.
-}
bumpArgFlowCensusBy : String -> Int -> S -> S
bumpArgFlowCensusBy key delta s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats

            n =
                Maybe.withDefault 0 (CoreDict.get key sig.argFlowCensus)
        in
        { s | lssStats = { stats | sigStats = { sig | argFlowCensus = CoreDict.insert key (n + delta) sig.argFlowCensus } } }

    else
        s


{-| Counts, under `lss.report`, one application of the arrow with `ArrowId`
`aid` to an argument, in `appliedArrows`.
-}
bumpAppliedArrow : Int -> S -> S
bumpAppliedArrow aid s =
    if s.env.lss.report then
        let
            stats =
                s.lssStats

            sig =
                stats.sigStats

            n =
                Maybe.withDefault 0 (CoreDict.get aid sig.appliedArrows)
        in
        { s | lssStats = { stats | sigStats = { sig | appliedArrows = CoreDict.insert aid (n + 1) sig.appliedArrows } } }

    else
        s


{-| Tells whether the global's signature, if it has already been inferred, is
trivial; `Nothing` when it has not been inferred.

It only reads the memo, so a census can call it without causing inference.
Inferring a signature mints member ids from the shared supply, so a census
that did so would change the ids, and the output, of a run with the report on.

-}
memoizedSignatureTrivial : TOpt.Global -> S -> Maybe Bool
memoizedSignatureTrivial g s =
    Maybe.map .trivial (HashMap.get TOpt.globalHash (==) g s.lssSignatures)


{-| Returns the census class of a member id: `"gc"` for a `SourceGlobal`
member, `"k"` for a kernel, and `"l"` for anything else, which includes lambda
instances and partial applications.

Only census counters read it. Whether a member may become a direct call is
decided elsewhere, from `standaloneMemberGlobal`.

-}
memberClassOf : Int -> LssMemberTable -> String
memberClassOf mid table =
    case CoreDict.get mid table.sources of
        Just (SourceGlobal _) ->
            "gc"

        Just (SourceKernel _) ->
            "k"

        Just (SourcePap _ _) ->
            -- A partial application is not its global: classed with lambdas.
            "l"

        _ ->
            "l"


{-| Returns the census class of a member list: `"gc"` if any member is `"gc"`
(see `memberClassOf`), else `"k"` if any is a kernel, else `"none"` for an
empty list and `"l"` otherwise.
-}
membersClass : List Int -> LssMemberTable -> String
membersClass members table =
    if List.any (\m -> memberClassOf m table == "gc") members then
        "gc"

    else if List.any (\m -> memberClassOf m table == "k") members then
        "k"

    else if List.isEmpty members then
        "none"

    else
        "l"


{-| Records a spec watchdog failure in `ItemAux.pendingFailure`, unless one is
already recorded, which is kept.

The failure does not stop the current item: the spec that tripped the
watchdog is still created and scheduled, and the driver reads the failure
after the item finishes.

-}
notePendingFailure : Failure -> S -> S
notePendingFailure f s =
    let
        aux =
            s.itemAux
    in
    case aux.pendingFailure of
        Just _ ->
            s

        Nothing ->
            { s | itemAux = { aux | pendingFailure = Just f } }


{-| Checks a newly created spec of `global` at `monoType` against the spec
watchdogs in `env.limits`, returning a `LimitExceeded` failure when one trips.

The breadth watchdog trips when the registry has created more than
`specBreadth` specs of the global; the size watchdog trips when `monoType` has
more than `specTypeNodes` nodes. A limit of 0 or less disables its check. The
watchdogs exist because polymorphic recursion through annotated mutually
recursive definitions is legal Elm and can demand ever larger types without
end. The message names the global being specialized when there is one.

-}
checkSpecWatchdogs : Mono.Global -> Mono.MonoType -> Mono.SpecializationRegistry -> S -> Maybe Failure
checkSpecWatchdogs global monoType reg s =
    let
        limits =
            s.env.limits

        -- A thunk, so the string is built only when a watchdog trips.
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


{-| The run's fixed inputs and settings, kept in `S.env` and never changed
after the initial state is built.

`currentModule` is the entry module, the home given to every anonymous lambda.
`superStatic` holds the type checker's constraints on type variables
(`number`, `comparable` and so on), as against `S.superTable`, which also
gains what work items discover. `lamLabels` and the `arrowTotal` and `stamp*`
counts are read only by the LSS report: they describe the arrows that
`AssignMVarIds` gave ids to. `limits` holds the spec watchdog limits.

-}
type alias Env =
    { toptNodes : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId)
    , annotations : TOpt.AnnotationsByGlobal TypeIds.MVarId
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , currentModule : ModuleName.Canonical
    , superStatic : Dict Int Vars.SuperType
    , lss : Config.LssConfig
    , lamLabels : CoreDict.Dict Int String -- source-lambda id -> label; every label is the empty string
    , arrowTotal : Int
    , stampTypesAll : Int
    , stampTypesNone : Int
    , stampTypesPartial : Int
    , stampArrowsInNone : Int
    , stampArrowsUnstampedInPartial : Int
    , limits : Config.SpecLimits
    }


{-| The whole state of a monomorphization run, threaded through every `Step`.

The fields above `store` are run-global and survive `resetItem`; `store` and
the fields after it belong to the current work item and are replaced by
`resetItem` (see the module docstring). `superTable` starts as the type
checker's constraints on type variables and gains the `number` constraints that
finished items discover (`harvestSuperTableExcept`). `dirtySpecs` holds the
scheduled specs whose stored type a later demand widened, which must be
translated again; `dirtyList` holds the same specs as a list, because a
`BitSet` cannot be enumerated. `specCountByGlobal` is kept only with LSS on.
`intern` is the hash-cons table for `MonoType`s, so that equal types built
anywhere in the run share one value. `currentGlobal` is the global whose spec
is being translated.

-}
type alias S =
    { -- Run-global
      worklist : List WorkItem
    , nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet
    , scheduled : BitSet
    , dirtySpecs : BitSet
    , dirtyList : List Mono.SpecId
    , specCountByGlobal : CoreDict.Dict String SpecTally -- keyed by the global's comparable key
    , registry : Mono.SpecializationRegistry
    , ports : List Mono.PortRegistration
    , lambdaCounter : Int
    , superTable : Dict Int Vars.SuperType
    , nextMVarId : TypeIds.MVarId
    , lssSignatures : HashMap.HashMap TOpt.Global LssSignature
    , lssInProgress : HashMap.HashMap TOpt.Global () -- globals whose signature is being inferred
    , lssMemberTable : LssMemberTable
    , nextMemberId : Int
    , lssStats : LssStats
    , monoMemo : MonoMemo
    , nodeResolution : CoreDict.Dict String NodeResolution -- keyed by the global's comparable key
    , intern : Intern
    , env : Env
    , currentGlobal : Maybe Mono.Global

    -- Per work item
    , store : IO.State
    , memo : Dict Int Vars.Variable -- MVarId (as an Int) -> Point
    , revMemo : Array (Maybe TypeIds.MVarId) -- indexed by Point; Nothing for a Point no MVarId minted
    , varEnv : CoreDict.Dict String Mono.MonoType -- local variable name -> its mono type
    , numberMulti : List NumberMultiEntry -- innermost first
    , localMulti : List NumberMultiEntry -- innermost first
    , derivedDestructors : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- name bound by a destructor -> the destructor's type
    , localCanTypes : CoreDict.Dict String (Can.Type TypeIds.MVarId) -- let-bound name -> the type of its right-hand side
    , itemAux : ItemAux
    }


{-| One recorded inclusion constraint on a lambda-set slot, kept only for the
census that `QShadowStats` describes; translation never reads it.

`QMembers` says the slot includes the listed member ids. `QTop` says the slot
is ⊤. `QEdge` says the first slot includes the second, and carries the
pre-state of both. Each constraint carries the pre-state of its slot as it was
just before the write, because a slot can start out with members from an
annotation, and the comparison must start from that seed. An edge also carries
its source's pre-state, because a seeded slot that only ever appears as a
source receives no constraint of its own.

-}
type QEntry
    = QMembers Vars.Variable (List Int) QPre
    | QTop Vars.Variable QPre
    | QEdge Vars.Variable Vars.Variable QPre QPre


{-| The content of a lambda-set slot just before a `QEntry` was recorded
against it: unconstrained, ⊤, or holding the listed members.
-}
type QPre
    = PreFlex
    | PreTop
    | PreMembers (List Int)


{-| The rest of a work item's state, reset by `resetItem`.

The store-scoped fields are the ones `clearedAux` empties, which hold Points or
Point indices of the item's store: `ecoResidualReads`, `ecoResidualKeyReads`,
`arrowMemo`, `groundLoads`, `arrowOfSlot`, `zonkLog`, `qLog` and `qSigRoot`.
`withScratchStore` clears them for the scratch store and restores them
afterwards (`clearedAux`, `restoredAux`). A Point leaking across that swap names
an unrelated Point of the other store, and can end up in a signature, which is
run-global. `lssRootAnn` also holds a Point, but is not in that list: it is
carried across the swap unchanged.

`lssRootAnn` is the annotation of a definition whose body is a lambda, with the
Point it was loaded as, consumed by the translation of that root lambda.
`ecoResidualReads` and `ecoResidualKeyReads` record what each read-back that
produced an erased residual type read; when one of those has since been bound,
the read-back was stale and the item is translated again against the same
store. `loopParams` holds the parameters of the enclosing tail-recursive
functions, innermost first. `currentSpecId` is the spec being translated.
`demandQualified` maps a lambda key (`qualifiedRawKey`) to the smallest member
id the spec's stored demand carries for it, for the μ-tie. `currentLocalInstance`
is the instance tag of the code being translated, 0 outside any instance.
`retranslating` names the let-bound function whose instance is being
re-translated, with its lambda id and arity. `arrowMemo` maps an arrow's id to
its lambda-set slot. `arrowOfSlot`, `zonkLog`, `qLog` and `qSigRoot` are census
logs, filled only when their census is on. `pendingFailure` is a spec watchdog
failure waiting for the driver.

-}
type alias ItemAux =
    { lssRootAnn : Maybe ( Can.Type TypeIds.MVarId, Vars.Variable )
    , ecoResidualReads : List Vars.Variable
    , ecoResidualKeyReads : List Int
    , loopParams : List ( String, List ( String, Can.Type TypeIds.MVarId ) )
    , currentSpecId : Maybe Int
    , demandQualified : CoreDict.Dict Int Int
    , currentLocalInstance : Int
    , retranslating : Maybe ( String, TypeIds.SrcLambdaId, Int )
    , arrowMemo : CoreDict.Dict Int Vars.Variable
    , groundLoads : HashMap.HashMap AliasKey Vars.FlatType
    , arrowOfSlot : CoreDict.Dict Int Int -- set slot's pointKey -> the ArrowId that minted it
    , zonkLog : List Vars.Variable -- every type read back in this item, newest first
    , qLog : List QEntry -- newest first
    , qSigRoot : Maybe Vars.Variable -- the definition's root type, unified with the demand
    , pendingFailure : Maybe Failure
    }


{-| An `ItemAux` with every field empty or unset, and instance tag 0.
-}
emptyItemAux : ItemAux
emptyItemAux =
    { lssRootAnn = Nothing, ecoResidualReads = [], ecoResidualKeyReads = [], loopParams = [], currentSpecId = Nothing, demandQualified = CoreDict.empty, currentLocalInstance = 0, retranslating = Nothing, arrowMemo = CoreDict.empty, groundLoads = HashMap.empty, arrowOfSlot = CoreDict.empty, zonkLog = [], qLog = [], qSigRoot = Nothing, pendingFailure = Nothing }


{-| Returns `aux` with every store-scoped field emptied (see `ItemAux`), for
use on entering a scratch store. The other fields are kept.

The emptied fields are the store-scoped ones listed in `ItemAux`. `lssRootAnn`
also holds a Point but is kept. A field emptied here must also be restored in
`restoredAux`.

-}
clearedAux : ItemAux -> ItemAux
clearedAux aux =
    { aux | ecoResidualReads = [], ecoResidualKeyReads = [], arrowMemo = CoreDict.empty, groundLoads = HashMap.empty, arrowOfSlot = CoreDict.empty, zonkLog = [], qLog = [], qSigRoot = Nothing }


{-| Returns the `ItemAux` to continue with on leaving a scratch store: `inner`,
with every store-scoped field, and also `currentLocalInstance` and
`retranslating`, taken from `outer`. The other fields, including
`pendingFailure`, `currentSpecId` and `demandQualified`, keep their values from
`inner`.
-}
restoredAux : ItemAux -> ItemAux -> ItemAux
restoredAux outer inner =
    { inner | ecoResidualReads = outer.ecoResidualReads, ecoResidualKeyReads = outer.ecoResidualKeyReads, arrowMemo = outer.arrowMemo, groundLoads = outer.groundLoads, arrowOfSlot = outer.arrowOfSlot, zonkLog = outer.zonkLog, qLog = outer.qLog, qSigRoot = outer.qSigRoot, currentLocalInstance = outer.currentLocalInstance, retranslating = outer.retranslating }


{-| Empties the recorded residual reads, before an item is translated again
against the same store. The other store-scoped fields are kept, because their
Points are still valid in that store.
-}
clearResidualReads : S -> S
clearResidualReads s =
    let
        aux =
            s.itemAux
    in
    { s | itemAux = { aux | ecoResidualReads = [], ecoResidualKeyReads = [] } }


{-| A global's node in `Env.toptNodes`, if it has one, and the set of
annotation variable ids found in that node. Both depend only on the node map,
so they are computed once per global and kept in `S.nodeResolution` for all of
its specs.
-}
type alias NodeResolution =
    { node : Maybe (TOpt.Node TypeIds.MVarId)
    , annIds : EverySet.EverySet Int Int
    }


{-| A let-bound definition being translated once per type it is used at, with
the instances found so far.

The same record serves both stacks of `S`. On `numberMulti` it is a let-bound
value whose type involves `number`; on `localMulti` it is a let-bound function.
The body of the `let` is translated first, and each use records the type it
needs (`recordNumberInstance`, `recordLocalInstance`). `instances` is keyed by
that `MonoType`, lambda sets included, and is iterated in insertion order. The
first instance keeps the definition's name.

`rhsLam` is the lambda id and parameter count of the right-hand side when it is
a lambda; `rhsPap` is the global and supplied argument count when it is a
partial application. Both are `Nothing` on the `numberMulti` stack.
`pendingEnrich` is always empty on that stack.

-}
type alias NumberMultiEntry =
    { defName : String
    , instances : Mono.SpecMap NumberInstance
    , rhsLam : Maybe ( TypeIds.SrcLambdaId, Int )
    , rhsPap : Maybe ( TOpt.Global, Int )
    , pendingEnrich : CoreDict.Dict String ( String, Mono.MonoType ) -- instance name -> (its definition's name, the instance's type)
    }


{-| One instance of a `NumberMultiEntry`: the name it is emitted under, the
type it is used at, and its ordinal, which is its insertion index and, from 1
on, the number in its name.
-}
type alias NumberInstance =
    { freshName : String
    , monoType : Mono.MonoType
    , ordinal : Int
    }


{-| A reason monomorphization cannot go on.

`Unsupported` is a construct the engine does not handle. `UnifyMismatch` is a
unification that had to succeed and failed. `EngineBug` is a broken internal
invariant. Inside a `Step` these three abort the process through
`crashFailure`; the driver in `Compiler.MonoSolver.Monomorphize` also returns
some `EngineBug`s as an `Err`.

`LimitExceeded` is a spec watchdog trip (see `checkSpecWatchdogs`). It is a
limit the program reached, not a compiler bug, so it never goes through
`crashFailure`: it is recorded in `ItemAux.pendingFailure`, and the driver
returns it as an `Err` once the current item finishes.

-}
type Failure
    = Unsupported String
    | UnifyMismatch String
    | EngineBug String
    | LimitExceeded String



-- ====== STEPS ======


{-| A computation over the engine state, returning a result and the new state.
It has no failure channel (see the module docstring).
-}
type alias Step a =
    S -> ( a, S )


{-| Returns the message for a `Failure`: a `MonoSolver.` prefix naming the
kind, then the text, except that a `LimitExceeded` message is returned as it
is, without a prefix that would present it as a compiler fault.
-}
renderFailure : Failure -> String
renderFailure failure =
    case failure of
        Unsupported msg ->
            "MonoSolver.unsupported: " ++ msg

        UnifyMismatch msg ->
            "MonoSolver.unify-mismatch: " ++ msg

        EngineBug msg ->
            "MonoSolver.bug: " ++ msg

        LimitExceeded msg ->
            msg


{-| Aborts the process with the `renderFailure` message of `f`. Its result type
is free, so it can stand wherever a value or a `Step` is expected.

It is for `Unsupported`, `UnifyMismatch` and `EngineBug`. A `LimitExceeded`
failure is recorded with `ItemAux.pendingFailure` instead, so that it reaches
the user as an ordinary error.

-}
crashFailure : Failure -> a
crashFailure f =
    Crash.crash (renderFailure f)


{-| Runs `f` on each element of `items` in order, threading the state, and
returns the results in the same order.
-}
traverse : (a -> Step b) -> List a -> Step (List b)
traverse f items =
    \s -> traverseGo f items s


{-| Runs `f` on each element in order, threading the state; the body of
`traverse`.
-}
traverseGo : (a -> Step b) -> List a -> S -> ( List b, S )
traverseGo f items s =
    case items of
        [] ->
            ( [], s )

        x :: rest ->
            case f x s of
                ( b, s1 ) ->
                    case traverseGo f rest s1 of
                        ( bs, s2 ) ->
                            ( b :: bs, s2 )


{-| Folds `f` over `items` from the left, starting from `acc` and threading the
state.
-}
foldlS : (a -> b -> Step b) -> b -> List a -> Step b
foldlS f acc items s =
    case items of
        [] ->
            ( acc, s )

        x :: rest ->
            case f x acc s of
                ( acc1, s1 ) ->
                    foldlS f acc1 rest s1


{-| Runs a solver `IO` action against the item's store, keeping the store it
returns.
-}
liftIO : IO.IO a -> S -> ( a, S )
liftIO io s =
    let
        ( store1, a ) =
            io s.store
    in
    ( a, { s | store = store1 } )



-- ====== SOLVER-STORE HELPERS ======


{-| Mints a new Point in the item's store with the given content.

Every Point the engine mints gets the same rank, `Type.outermostRank`. Rank
matters to the type checker only for generalization, which the engine never
does.

-}
freshVar : Vars.Content -> S -> ( Vars.Variable, S )
freshVar content =
    liftIO (UF.fresh (IO.makeDescriptor content Type.outermostRank Type.noMark Nothing))


{-| Returns the member id for `key`, with the table and next free id to
continue with. A key already in the table gives its id with the table and
`nextId` unchanged, so a caller can tell a new key by the returned next id
differing from `nextId`. A new key is given `nextId`.

Every member is interned through this function. It takes the table and supply
rather than `S` so that read-back code holding them outside `S` can use it.

-}
internMemberKey : String -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )
internMemberKey key table nextId =
    case CoreDict.get key table.byKey of
        Just mid ->
            ( mid, table, nextId )

        Nothing ->
            ( nextId, insertMemberKey key nextId table, nextId + 1 )


{-| Returns the member id for `key`, interning it in `S.lssMemberTable` if it
is new. The key forms are listed in the module docstring. This records nothing
about what the member stands for; the `*MemberIdFor` functions below add that.
-}
memberIdFor : String -> S -> ( Int, S )
memberIdFor key s =
    let
        ( mid, table1, next1 ) =
            internMemberKey key s.lssMemberTable s.nextMemberId
    in
    if next1 == s.nextMemberId then
        ( mid, s )

    else
        ( mid, { s | lssMemberTable = table1, nextMemberId = next1 } )


{-| Returns the member key for a partial application of `global` with
`argCount` arguments supplied, `p|<global>|<argCount>`. Every place that names
such a member builds the key here, so that they all agree.
-}
papMemberKey : TOpt.Global -> Int -> String
papMemberKey global argCount =
    "p|" ++ TOpt.toComparableGlobal global ++ "|" ++ String.fromInt argCount


{-| Returns the member id for a partial application of `global` with
`argCount` arguments supplied, recording it as a `SourcePap` unless the id
already has a source.

The id is not marked provisional, so grounding never rewrites it: the same
global with one more argument supplied is a different partial application.

-}
papMemberIdFor : TOpt.Global -> Int -> S -> ( Int, S )
papMemberIdFor global argCount s0 =
    case memberIdFor (papMemberKey global argCount) s0 of
        ( mid, s1 ) ->
            if CoreDict.member mid s1.lssMemberTable.sources then
                ( mid, s1 )

            else
                let
                    t =
                        s1.lssMemberTable
                in
                ( mid, { s1 | lssMemberTable = { t | sources = CoreDict.insert mid (SourcePap global argCount) t.sources } } )


{-| Returns the member id for `key`, a `g|` or `c|` key for global `g`, and,
unless the id already has a source, records it as a `SourceGlobal` of `g` and
marks it provisional, so that `groundSetMembers` will rewrite it.

The check is on the id's source, not on whether the key is new: a key interned
earlier without a source is still recorded and marked.

-}
standaloneMemberIdFor : String -> TOpt.Global -> S -> ( Int, S )
standaloneMemberIdFor key g s0 =
    case memberIdFor key s0 of
        ( mid, s1 ) ->
            if CoreDict.member mid s1.lssMemberTable.sources then
                ( mid, s1 )

            else
                ( mid, { s1 | lssMemberTable = insertMemberProvisional mid g (insertMemberGlobal mid g s1.lssMemberTable) } )


{-| Returns the global a member id stands for when its source is
`SourceGlobal`, and `Nothing` for any other member, including a partial
application.
-}
standaloneMemberGlobal : Int -> S -> ( Maybe TOpt.Global, S )
standaloneMemberGlobal mid s =
    ( case CoreDict.get mid s.lssMemberTable.sources of
        Just (SourceGlobal g) ->
            Just g

        _ ->
            Nothing
    , s
    )


{-| Returns the ground member id `g|<global>|<typeKey>` for global `g`, with the
table and next free id to continue with, recording a newly interned id as a
`SourceGlobal` of `g`.

Ground ids are never marked provisional, so grounding a set a second time
leaves them as they are. `typeKey` is expected to be the annotation-widened
rendering of the arrow type (`groundSetMembers` builds it that way), so that
the lambda set of the arrow is not part of its own members' identity.

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


{-| Returns the members of a lambda set read back at the arrow
`paramT -> resultT`, with each provisional member rewritten to its ground
member, together with the table and next free id to continue with and the
counts for the grounding census.

A ground member is `g|<global>|<typeKey>`, where `typeKey` renders the arrow
type with its own lambda sets widened, so one global gets one ground id per
layout it is instantiated at. Members that are not provisional are kept as
they are.

Three cases. With no provisional member, `members` is returned unchanged. When
`paramT` or `resultT` still contains an unresolved type variable, nothing is
rewritten, because the key would contain item-specific variable ids, and each
provisional member is counted as `deferred`. Otherwise every provisional member
is rewritten and counted as `grounded`, and the result is sorted ascending
with duplicates removed. Rewriting never makes a set larger.

-}
groundSetMembers : Mono.MonoType -> Mono.MonoType -> List Int -> LssMemberTable -> Int -> { members : List Int, table : LssMemberTable, nextId : Int, grounded : Int, deferred : Int }
groundSetMembers paramT resultT members table0 nextId0 =
    if not (List.any (\mid -> CoreDict.member mid table0.provisionalStandalone) members) then
        { members = members, table = table0, nextId = nextId0, grounded = 0, deferred = 0 }

    else if Mono.containsAnyMVar paramT || Mono.containsAnyMVar resultT then
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
            typeKey =
                Mono.toComparableMonoType (Mono.widenSets (Mono.mFunction Mono.topWiden [ paramT ] resultT))

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
        { members = dedupAscending (List.sort rewritten.members)
        , table = rewritten.table
        , nextId = rewritten.nextId
        , grounded = rewritten.grounded
        , deferred = rewritten.deferred
        }


{-| Removes adjacent duplicates, which in a sorted list are all duplicates.
-}
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


{-| Returns the member id for a kernel's `k|` key and, unless the id already has
a source, records it as a `SourceKernel` with the kernel's prefix, home and
name.
-}
kernelMemberIdFor : String -> ( String, String, String ) -> S -> ( Int, S )
kernelMemberIdFor key k s0 =
    case memberIdFor key s0 of
        ( mid, s1 ) ->
            if CoreDict.member mid s1.lssMemberTable.sources then
                ( mid, s1 )

            else
                ( mid, { s1 | lssMemberTable = insertMemberKernel mid k s1.lssMemberTable } )


{-| Returns the kernel a member id stands for, as prefix, home and name, when
its source is `SourceKernel`, and `Nothing` otherwise.
-}
standaloneMemberKernel : Int -> S -> ( Maybe ( String, String, String ), S )
standaloneMemberKernel mid s =
    ( case CoreDict.get mid s.lssMemberTable.sources of
        Just (SourceKernel k) ->
            Just k

        _ ->
            Nothing
    , s
    )


{-| Runs `step` against an empty scratch store, then goes back to the item's
own store.

The step starts with an empty store, `memo` and `revMemo`, and with the
store-scoped `ItemAux` fields emptied (`clearedAux`). Afterwards the item's
store, `memo` and `revMemo` are put back and `ItemAux` is restored as
`restoredAux` describes. Everything else the step changed is kept, including
run-global state such as member ids and signatures, and the per-item
`varEnv` and multi-instance stacks.

Read-backs and constraints the step logged in the scratch store are dropped
with it. When there were any, their number is counted in `settled` (under
`lss.report`) and in `qShadow` (under `lss.qCensus`), as `scratchDropped`.

-}
withScratchStore : (S -> ( a, S )) -> S -> ( a, S )
withScratchStore step s0 =
    let
        sFresh =
            { s0 | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty, itemAux = clearedAux s0.itemAux }
    in
    case step sFresh of
        ( a, s1 ) ->
            let
                -- Counts logged read-back calls, not set slots.
                s2 =
                    if s1.env.lss.report && not (List.isEmpty s1.itemAux.zonkLog) then
                        let
                            stats =
                                s1.lssStats

                            sig =
                                stats.sigStats

                            prev =
                                sig.settled
                        in
                        { s1 | lssStats = { stats | sigStats = { sig | settled = { prev | scratchDropped = prev.scratchDropped + List.length s1.itemAux.zonkLog } } } }

                    else
                        s1

                s3 =
                    if s2.env.lss.qCensus && not (List.isEmpty s2.itemAux.qLog) then
                        let
                            statsQ =
                                s2.lssStats

                            sigQ =
                                statsQ.sigStats

                            prevQ =
                                sigQ.qShadow
                        in
                        { s2 | lssStats = { statsQ | sigStats = { sigQ | qShadow = { prevQ | scratchDropped = prevQ.scratchDropped + List.length s2.itemAux.qLog } } } }

                    else
                        s2
            in
            ( a, { s3 | store = s0.store, memo = s0.memo, revMemo = s0.revMemo, itemAux = restoredAux s0.itemAux s3.itemAux } )



-- ====== WORKLIST / REGISTRY ======


{-| Returns the `SpecId` for `global` at `monoType`, creating the spec in the
registry and scheduling it if it is new.

A newly scheduled spec is pushed on the front of the worklist, so the worklist
is last in, first out, and `scheduled` keeps a spec from being pushed twice.
With LSS on the work is done by `enqueueSpecKeyed`, whose docstring says how
lambda sets take part in the key; with LSS off the registry is keyed on the
type as given. In both cases a newly created spec is checked against the spec
watchdogs, and a trip is recorded with `ItemAux.pendingFailure` while the spec
is still created and scheduled.

-}
enqueueSpec : Mono.Global -> Mono.MonoType -> S -> ( Mono.SpecId, S )
enqueueSpec global monoType s0 =
    if s0.env.lss.enabled then
        enqueueSpecKeyed global monoType s0

    else
        let
            ( ( specId, reg1, hit ), s2 ) =
                let
                    ( sid, r ) =
                        Registry.getOrCreateSpecId global monoType s0.registry
                in
                ( ( sid, r, Registry.CreatedNew ), s0 )

            s =
                bumpKeyedHit hit s2

            storedChanged =
                hit == Registry.HitChangedJoin

            -- `hit` is always `CreatedNew` here, so creation is detected by the
            -- registry's next id advancing.
            watchdog =
                if reg1.nextId > s0.registry.nextId then
                    checkSpecWatchdogs global monoType reg1 s

                else
                    Nothing
        in
        case watchdog of
            Just failure ->
                enqueueSpecCommit specId reg1 storedChanged (notePendingFailure failure s)

            Nothing ->
                enqueueSpecCommit specId reg1 storedChanged s


{-| Finishes an enqueue of spec `specId`, given the registry `reg1` the probe
returned and whether the probe widened the spec's stored type.

A spec not yet scheduled is scheduled: `reg1` is installed and the spec is
pushed on the worklist. A scheduled spec whose stored type was widened is
marked dirty (`markDirty`) rather than pushed again. Its translation may have
started from a narrower type, so its lambda sets could leave out values this
demand brings, and it must be translated again; the dirty specs are
re-translated together after the worklist drains, once per round instead of
once per widening. A scheduled spec whose type did not change is returned with
`s` unchanged, so `reg1` is not installed in that case.

-}
enqueueSpecCommit : Mono.SpecId -> Mono.SpecializationRegistry -> Bool -> S -> ( Mono.SpecId, S )
enqueueSpecCommit specId reg1 storedChanged s =
    if BitSet.member specId s.scheduled then
        if storedChanged then
            ( specId, markDirty specId reg1 s )

        else
            ( specId, s )

    else
        ( specId
        , { s
            | registry = reg1
            , scheduled = BitSet.insertGrowing specId s.scheduled
            , worklist = SpecializeGlobal specId :: s.worklist
          }
        )


{-| Counts the outcome of a registry probe in the census: an identical hit, a
hit whose join changed nothing, or a hit whose join widened the stored type.
A `CreatedNew` outcome is not counted. These counters are not gated on the
report.
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


{-| Counts one completion join, the join of a finished spec's result into its
stored type, that changed the stored type.
-}
bumpCompletionJoin : S -> S
bumpCompletionJoin s =
    let
        stats =
            s.lssStats
    in
    { s | lssStats = { stats | completionJoins = stats.completionJoins + 1 } }


{-| Counts one completion join that changed nothing, in both
`completionJoinNoop` and `completionJoins`, so that `completionJoins` counts
every completion join.
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


{-| Installs registry `reg1` and marks `specId` dirty: its stored type was
widened after it was scheduled. A spec already dirty is not added to
`dirtyList` again.
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


{-| Does `enqueueSpec` with LSS on.

The registry key depends on how many specs the global already has. While the
global is under its budget, `lss.maxSpecsPerGlobal` (0 or less means no
limit, the default), the key is `monoType` with its lambda sets, so demands
that differ only in lambda sets get separate specs and each body sees only
the functions that can reach it. Past the budget the key is `monoType` with
its lambda sets widened, and the demand is counted in `widenedByBudget`. A
widened key does not match a spec created under the budget unless every set
in that spec's type was ⊤, so the first demand past the budget can still
create a new spec.

Either way the probe joins the demand into the spec's stored type
(`Registry.getOrCreateSpecIdKeyed`), and a join that widens the stored type of
a scheduled spec marks it dirty (see `enqueueSpecCommit`). Only creation
counts against the budget. A newly created spec has its annotation-widened
key recorded (`recordSpecWidenedKey`), which is what its lambda mints are
qualified by, and is checked against the spec watchdogs.

-}
enqueueSpecKeyed : Mono.Global -> Mono.MonoType -> S -> ( Mono.SpecId, S )
enqueueSpecKeyed global monoType s0 =
    let
        gkey =
            Mono.toComparableGlobal global

        tally =
            Maybe.withDefault emptySpecTally (CoreDict.get gkey s0.specCountByGlobal)

        count =
            tally.count

        underBudget =
            s0.env.lss.maxSpecsPerGlobal <= 0 || count < s0.env.lss.maxSpecsPerGlobal

        -- Needed on both arms: the key past the budget, and the recorded
        -- creation key of a new spec.
        ( maybeWidened, sPre ) =
            let
                ( keyType, intern1 ) =
                    Intern.widenSets monoType s0.intern
            in
            ( Just keyType, withIntern intern1 s0 )

        ( ( specId, reg1, hit ), sProbe ) =
            if underBudget then
                ( Registry.getOrCreateSpecIdKeyed global monoType monoType sPre.registry, sPre )

            else
                ( Registry.getOrCreateSpecIdKeyed global (Maybe.withDefault monoType maybeWidened) monoType sPre.registry
                , sPre
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
                        CoreDict.insert gkey { count = count + 1, ids = specId :: tally.ids } s.specCountByGlobal

                    else
                        s.specCountByGlobal
                , lssStats =
                    if underBudget then
                        stats0

                    else
                        { stats0 | widenedByBudget = stats0.widenedByBudget + 1 }
            }

        s2 =
            case ( created, maybeWidened ) of
                ( True, Just keyType ) ->
                    recordSpecWidenedKey specId (Mono.toComparableMonoType keyType) s1

                _ ->
                    s1
    in
    case
        if created then
            checkSpecWatchdogs global monoType reg1 s2

        else
            Nothing
    of
        Just failure ->
            enqueueSpecCommit specId s2.registry storedChanged (notePendingFailure failure s2)

        Nothing ->
            enqueueSpecCommit specId s2.registry storedChanged s2



-- ====== PER-ITEM RESET ======


{-| An empty point store, with no Points and node-id recording off.
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
        , canMemo = CoreDict.empty
        }
    , nodeIds =
        { mapping = Array.empty
        , syntheticExprIds = EverySet.empty
        , schemeBinderVars = CoreDict.empty
        , recording = False
        }
    }


{-| Replaces every per-item field with its empty value, before a work item is
translated: an empty store, empty memos, an empty variable environment and
multi-instance stacks, and an empty `ItemAux`, which also clears any pending
failure. Anything still needed from the previous item's store must have been
read out before this.
-}
resetItem : S -> S
resetItem s =
    { s | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty, varEnv = CoreDict.empty, numberMulti = [], localMulti = [], derivedDestructors = CoreDict.empty, localCanTypes = CoreDict.empty, itemAux = emptyItemAux }


{-| Binds a local variable's name to its mono type in `varEnv`.
-}
insertVar : String -> Mono.MonoType -> S -> S
insertVar name monoType s =
    { s | varEnv = CoreDict.insert name monoType s.varEnv }


{-| Returns the mono type `varEnv` binds a local variable's name to.
-}
lookupVar : String -> S -> ( Maybe Mono.MonoType, S )
lookupVar name s =
    ( CoreDict.get name s.varEnv, s )


{-| Pushes an entry with no instances for the let-bound value `defName` onto
`numberMulti`, before the `let` body is translated and records its uses.
-}
pushNumberMulti : String -> S -> S
pushNumberMulti defName s =
    { s | numberMulti = { defName = defName, instances = Mono.specMapEmpty, rhsLam = Nothing, rhsPap = Nothing, pendingEnrich = CoreDict.empty } :: s.numberMulti }


{-| Pops the innermost `numberMulti` entry, or returns `Nothing` when the stack
is empty.
-}
popNumberMulti : S -> ( Maybe NumberMultiEntry, S )
popNumberMulti s =
    case s.numberMulti of
        top :: rest ->
            ( Just top, { s | numberMulti = rest } )

        [] ->
            ( Nothing, s )


{-| Returns the type of the first instance, the one named `name` itself, of the
innermost `numberMulti` entry for `name`; `Nothing` when there is no such entry
or it has no such instance yet.
-}
numberMultiRootType : String -> S -> ( Maybe Mono.MonoType, S )
numberMultiRootType name s =
    ( case List.head (List.filter (\e -> e.defName == name) s.numberMulti) of
        Just entry ->
            List.head (List.filter (\i -> i.freshName == name) (Mono.specMapValues entry.instances))
                |> Maybe.map .monoType

        Nothing ->
            Nothing
    , s
    )


{-| Returns the name and type of the instance of the `numberMulti` entry `name`
at `monoType`, recording a new instance if there is none: the first instance
is named `name`, later ones `name$v1`, `name$v2` and so on. See
`recordMultiInstance` for the case where `name` has no entry.
-}
recordNumberInstance : String -> Mono.MonoType -> S -> ( ( String, Mono.MonoType ), S )
recordNumberInstance name monoType s =
    case recordNumberInstanceOrd name monoType s of
        ( ( freshName, instType, _ ), s1 ) ->
            ( ( freshName, instType ), s1 )


{-| Does `recordNumberInstance`, also returning the instance's ordinal.
-}
recordNumberInstanceOrd : String -> Mono.MonoType -> S -> ( ( String, Mono.MonoType, Int ), S )
recordNumberInstanceOrd name monoType s =
    recordMultiInstance .numberMulti (\stk st -> { st | numberMulti = stk }) "$v" name monoType s


{-| Pushes an entry with no instances for the let-bound function `defName` onto
`localMulti`, with its right-hand side's lambda or partial application if it is
one, before the `let` body is translated and records the types it is used at.
-}
pushLocalMulti : Maybe ( TypeIds.SrcLambdaId, Int ) -> Maybe ( TOpt.Global, Int ) -> String -> S -> S
pushLocalMulti rhsLam rhsPap defName s =
    { s | localMulti = { defName = defName, instances = Mono.specMapEmpty, rhsLam = rhsLam, rhsPap = rhsPap, pendingEnrich = CoreDict.empty } :: s.localMulti }


{-| Pops the innermost `localMulti` entry, or returns `Nothing` when the stack
is empty.
-}
popLocalMulti : S -> ( Maybe NumberMultiEntry, S )
popLocalMulti s =
    case s.localMulti of
        top :: rest ->
            ( Just top, { s | localMulti = rest } )

        [] ->
            ( Nothing, s )


{-| Tells whether some `localMulti` entry is for `name`.
-}
isLocalMultiTarget : String -> S -> ( Bool, S )
isLocalMultiTarget name s =
    ( List.any (\e -> e.defName == name) s.localMulti, s )


{-| Returns what is known about a local name, in one call: whether a
`localMulti` entry is for it, whether a `numberMulti` entry is for it, and its
binding in `varEnv`.
-}
localVarInfo : String -> S -> ( ( Bool, Bool, Maybe Mono.MonoType ), S )
localVarInfo name s =
    ( ( List.any (\e -> e.defName == name) s.localMulti
      , List.any (\e -> e.defName == name) s.numberMulti
      , CoreDict.get name s.varEnv
      )
    , s
    )


{-| Returns the name, type and ordinal of the instance of the `localMulti` entry
`name` at `monoType`, recording a new instance if there is none: the first
instance is named `name`, later ones `name$1`, `name$2` and so on. See
`recordMultiInstance` for the case where `name` has no entry.
-}
recordLocalInstance : String -> Mono.MonoType -> S -> ( ( String, Mono.MonoType, Int ), S )
recordLocalInstance name monoType s =
    recordMultiInstance .localMulti (\stk st -> { st | localMulti = stk }) "$" name monoType s


{-| Returns the name, type and ordinal of the instance at `monoType` of the
innermost entry for `name` in the stack that `getStack` reads, recording a new
instance there if the entry has none at that type.

A new instance's ordinal is the number of instances the entry already had; it
is named `name` for ordinal 0 and `name ++ sep ++ ordinal` otherwise. Instances
are keyed by `monoType` with its lambda sets, so two uses that differ only in
lambda sets are two instances. When the stack has no entry for `name`, the
result is `name`, `monoType` and ordinal 0, and nothing is recorded.

-}
recordMultiInstance : (S -> List NumberMultiEntry) -> (List NumberMultiEntry -> S -> S) -> String -> String -> Mono.MonoType -> S -> ( ( String, Mono.MonoType, Int ), S )
recordMultiInstance getStack setStack sep name monoType s =
    let
        update entry =
            case Mono.specMapGet monoType entry.instances of
                Just inst ->
                    ( entry, ( inst.freshName, inst.monoType, inst.ordinal ) )

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
                            { freshName = freshName, monoType = monoType, ordinal = idx }
                    in
                    ( { entry | instances = Mono.specMapInsert monoType inst entry.instances }
                    , ( freshName, monoType, idx )
                    )

        go entries =
            case entries of
                [] ->
                    ( [], ( name, monoType, 0 ) )

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
    ( res, setStack newStack s )


{-| Runs `step` and then puts `varEnv` back as it was, so local variables the
step binds do not reach sibling expressions. Every other change the step makes
is kept.
-}
scoped : (S -> ( a, S )) -> S -> ( a, S )
scoped step s0 =
    case step s0 of
        ( a, s1 ) ->
            ( a, { s1 | varEnv = s0.varEnv } )


{-| Adds to `superTable` a `number` constraint for every MVarId whose Point in
the item's store is constrained to `number`, except the MVarIds in `excluded`.
Only the first MVarId to mint each Point (`revMemo`) is considered.

The caller excludes the annotation variables of the item's own global. Each
spec of that global instantiates them at a different type, so a `number`
constraint learnt in one spec does not hold in another, and recording it would
make another spec's unresolved variables default to `Int` at a call site that
expects a boxed value.

-}
harvestSuperTableExcept : EverySet.EverySet Int Int -> S -> S
harvestSuperTableExcept excluded s =
    let
        -- The fold carries the Point index alongside the store and the table.
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
                            -- The store a read returns differs only by path
                            -- compression, so it is dropped.
                            ( _, desc ) =
                                UF.get (Vars.Pt pointIdx) store
                        in
                        case desc.content of
                            Vars.FlexSuper Vars.Number _ ->
                                ( store, CoreDict.insert (mvarIdKey mvarId) Vars.Number super )

                            Vars.RigidSuper Vars.Number _ ->
                                ( store, CoreDict.insert (mvarIdKey mvarId) Vars.Number super )

                            _ ->
                                ( store, super )
            )

        ( _, ( _, superTable1 ) ) =
            Array.foldl step ( 0, ( s.store, s.superTable ) ) s.revMemo
    in
    { s | superTable = superTable1 }



-- ====== CLASSIFICATION MEMOS ======


{-| Returns the mono type `MonoMemo.schemeMono` holds for a global's
comparable key.
-}
lookupSchemeMono : String -> S -> ( Maybe Mono.MonoType, S )
lookupSchemeMono key s =
    ( CoreDict.get key s.monoMemo.schemeMono, s )


{-| Records the mono type of a global with a variable-free scheme in
`MonoMemo.schemeMono`, under the global's comparable key.
-}
putSchemeMono : String -> Mono.MonoType -> S -> S
putSchemeMono key monoType s =
    let
        m =
            s.monoMemo
    in
    { s | monoMemo = { m | schemeMono = CoreDict.insert key monoType m.schemeMono } }


{-| Returns the callee type, result type and `SpecId` that `MonoMemo.callMemo`
holds for a call key.
-}
lookupCallMemo : Mono.SpecKey -> S -> ( Maybe ( Mono.MonoType, Mono.MonoType, Mono.SpecId ), S )
lookupCallMemo key s =
    ( Mono.specKeyMapGet key s.monoMemo.callMemo, s )


{-| Records the callee type, result type and `SpecId` of a call in
`MonoMemo.callMemo`.
-}
putCallMemo : Mono.SpecKey -> ( Mono.MonoType, Mono.MonoType, Mono.SpecId ) -> S -> S
putCallMemo key entry s =
    let
        m =
            s.monoMemo
    in
    { s | monoMemo = { m | callMemo = Mono.specKeyMapInsert key entry m.callMemo } }



-- ====== INTERN TABLE ======


{-| Returns the canonical copy of `mt` from `S.intern`, adding `mt` to the table
if it is new.

Only the top node is looked up, so this is for a type whose children are
already canonical, such as one built from a single constructor over canonical
parts. Code that builds whole types interns each node as it builds it.

-}
consS : Mono.MonoType -> S -> ( Mono.MonoType, S )
consS mt s =
    let
        ( mt1, intern1 ) =
            Intern.hashCons mt s.intern
    in
    ( mt1, withIntern intern1 s )


{-| Installs `intern1` as `S.intern`, unless its `Intern.entries` count equals
the current table's, in which case `s` is returned unchanged.

`intern1` is expected to be the current table after zero or more additions, so
an equal count means nothing was added. Returning `s` itself then saves
copying the whole state record, which matters because a table is offered back
after every interned node. The test is on `Intern.entries` rather than on the
size of the canonical table because the table's memo of widened types can grow
without a new canonical type being added.

-}
withIntern : Intern -> S -> S
withIntern intern1 s =
    if Intern.entries intern1 == Intern.entries s.intern then
        s

    else
        { s | intern = intern1 }



-- ====== KEYS ======


{-| Returns an `MVarId` as an integer, for use as a `Dict` key.
-}
mvarIdKey : TypeIds.MVarId -> Int
mvarIdKey =
    Id.toComparable


{-| Tells whether `superTable` constrains the type variable `mid` to `number`
or `comparable`, so that no value of its type can contain a function.

It answers `False` for every other variable, including one the table does not
know. That includes `compappend`, whose values cannot contain a function
either, and `appendable`, whose values can. A `False` is therefore only "not
known to be function-free".

-}
isScalarVar : S -> TypeIds.MVarId -> Bool
isScalarVar s mid =
    case CoreDict.get (mvarIdKey mid) s.superTable of
        Just Vars.Number ->
            True

        Just Vars.Comparable ->
            True

        _ ->
            False


{-| Returns the index of a Point in its store, for use as a `Dict` key. Two
stores give the same index to different Points.
-}
pointKey : Vars.Variable -> Int
pointKey (Vars.Pt n) =
    n
