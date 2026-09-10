module Compiler.GlobalOpt.InlineSimplify exposing
    ( Metrics, emptyMetrics
    , optimize
    )

{-| PRE-MONOMORPHIZATION inliner (plans/pre-mono-inline-simplify.md).

`MonoInlineSimplify` runs on fully-specialized code, so a small polymorphic
definition is monomorphized into N copies and each copy is inlined
independently. This pass inlines once, before specialization.

**Copying a polymorphic body needs its TYPE VARIABLES freshened** — see
`suffixType`. `AssignMVarIds` keys a type variable's identity on its NAME within
one top-level definition, so two copies spliced into the same caller would both
say `TVar "a"`, receive one `MVarId`, and force the two call sites'
instantiations to meet. Each copy therefore gets the same `_pi<n>` suffix on its
type variables that its term-level binders get. Refusing polymorphic candidates
instead — v1's answer — rejected ~98% of what the pass could inline
(plan §11.2, §12).

Measured motivation (that plan's §8.1): the self-compile performs 65,949
inlines over only 27,130 distinct SOURCE call sites — a redundancy factor of
**2.43x**, which is the ceiling on the work this position change can avoid.

It is also the position at which inlining cannot destroy LSS identity: `TOpt`
has no `ClosureInfo`, no `lssMember` and no `CallInfo`, so the four
identity-clearing sites in `MonoInlineSimplify` have no analogue here
(`plans/lss-inline-member-propagation.md` §7.2 measures those at 863 members
destroyed per self-compile).

**Scope of v1** — deliberately narrower than the post-mono pass
(that plan's §3): exact-arity inlining of small non-recursive globals, plus the
fixpoint. `loopify`, `arityRaise` and the kernel cost classes are
monomorphic-only by nature and stay out. Partial/over-application inlining, let
forwarding and DCE are left to the post-mono pass.

**Why arguments are LET-BOUND rather than substituted.** Splicing an argument
expression into the callee body risks capture: a free variable of the argument
could be captured by a binder inside the body. Binding `p = arg` in the CALLER's
scope and renaming `p` inside the body evaluates every argument outside the
body, so that class of capture cannot arise.

**Why the body's binders are freshened anyway.** Inlining one body at two sites
in one caller would otherwise produce two `let x = …` with the same name, which
the backend rejects as an SSA redefinition (`memory:
eco-inliner-dup-let-names-ssa-redef` — a real shipped bug in the post-mono
pass). `freshenBody` renames every binder, `Destruct` binders included; that is
the exact shape whose omission caused the post-mono pass's destructure-binder
capture bug.

**`SrcLambdaId` duplication is safe here** (that plan's Step 0):
`AssignMVarIds.assignIds` runs INSIDE monomorphization, downstream of this pass,
and its `Function` arm discards the incoming id (`TOpt.Function _ args body
meta ->` then `freshLamId`). Copies are renumbered before any LSS member is
interned. If that ever changes to preserve incoming ids, this pass must freshen
them too.

@docs Metrics, emptyMetrics
@docs optimize

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Data.Id as Id
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.PreMono.Fresh as Fresh
import Compiler.Graph as Graph
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Dict as CoreDict


{-| Census counters, mirroring `MonoInlineSimplify.Metrics` where the two
passes measure the same thing so the A/B arms are directly comparable.
-}
type alias Metrics =
    { inlineCount : Int
    , candidates : Int
    , recursiveSkipped : Int
    , overBudget : Int
    , polymorphic : Int
    , polyKernel : Int
    , rowPoly : Int
    , superVar : Int
    , hofParam : Int
    , undetermined : Int
    , bodiesSeen : Int
    , inlinedByCallee : CoreDict.Dict String Int

    -- Q1 CENSUS (inline.report only; every field stays zero/empty when off).
    -- `undetermined` split by WHY the call site failed to pin the callee's
    -- type variables: every offending free var is a binder of the CALLER's own
    -- annotation scheme (`undCallerPoly`); some offending free var is an
    -- unsolved local that only MonoSolver resolves (`undLocal`); or the callee
    -- var occurs in no parameter and not in the result — a let-polymorphic
    -- inner variable (`undBodyOnly`).
    , undCallerPoly : Int
    , undLocal : Int
    , undBodyOnly : Int
    , undLeak : Int
    , undeterminedByCallee : CoreDict.Dict String Int
    , undCallerPolyByCallee : CoreDict.Dict String Int

    -- overBudget candidates by pre-mono `cost`: (11-15, 16-25, 26-50, >50),
    -- plus every over-budget (callee, cost) so the list can be joined against
    -- the post-mono pass's `inlinedByCallee`.
    , overBudgetBuckets : ( Int, Int, ( Int, Int ) )
    , overBudgetCosts : List ( String, Int )

    -- hofParam candidates, by the SHAPE of the function argument at each call
    -- site's function-typed positions: a syntactic lambda (the shape whose
    -- inlining keeps a singleton lambda set), a global, or anything else.
    , hofArgLambda : Int
    , hofArgGlobal : Int
    , hofArgOther : Int

    -- Names refused by each candidate-level guard, so post-mono's per-callee
    -- inline counts can be attributed to the guard that keeps them out here.
    , hofNames : List String
    , polyKernelNames : List String
    , superVarNames : List String
    , undLocalByCallee : CoreDict.Dict String Int
    , undBodyOnlyByCallee : CoreDict.Dict String Int
    }


{-| All-zero metrics — what `optimize` reports when the pass is off.
-}
emptyMetrics : Metrics
emptyMetrics =
    { inlineCount = 0
    , candidates = 0
    , recursiveSkipped = 0
    , overBudget = 0
    , polymorphic = 0
    , polyKernel = 0
    , rowPoly = 0
    , superVar = 0
    , hofParam = 0
    , undetermined = 0
    , bodiesSeen = 0
    , inlinedByCallee = CoreDict.empty
    , undCallerPoly = 0
    , undLocal = 0
    , undBodyOnly = 0
    , undLeak = 0
    , undeterminedByCallee = CoreDict.empty
    , undCallerPolyByCallee = CoreDict.empty
    , overBudgetBuckets = ( 0, 0, ( 0, 0 ) )
    , overBudgetCosts = []
    , hofArgLambda = 0
    , hofArgGlobal = 0
    , hofArgOther = 0
    , hofNames = []
    , polyKernelNames = []
    , superVarNames = []
    , undLocalByCallee = CoreDict.empty
    , undBodyOnlyByCallee = CoreDict.empty
    }


type alias Ctx =
    { candidates : CoreDict.Dict String Candidate
    , metrics : Metrics
    , fresh : Int
    , fuel : Int

    -- The id allocator. A copied body's lambda ids, arrow ids and
    -- unsubstituted type variables are all minted from it through
    -- `PreMono.Fresh` — which is what replaced the `_pi` TYPE-name suffix and
    -- the `varSupers`-by-name re-keying this pass used before `AssignMVarIds`
    -- moved in front of it.
    , state : AssignMVarIds.GlobalMVarState

    -- Q1 census plumbing. `censusOn` = `inline.report`; when off nothing
    -- below is consulted. `callerBinders` is the free-variable set of the
    -- annotation of the top-level definition currently being rewritten
    -- (`rewriteGraph` sets it per node). `hofDeclined` maps a global refused
    -- by the `hofParam` guard to its per-parameter is-function flags, so the
    -- shape of the arguments at its call sites can be tallied.
    , censusOn : Bool
    , callerBinders : CoreDict.Dict Int ()
    , hofDeclined : CoreDict.Dict String (List Bool)
    }


type alias Candidate =
    { params : List ( Name, Can.Type TypeIds.MVarId )
    , body : TOpt.Expr TypeIds.MVarId
    , name : String

    -- Every type variable in `params` and `body` as `Id.toComparable` keys,
    -- computed once when the candidate is built rather than per inline. Used by
    -- the `polymorphic` census and by `determines`.
    , typeVars : List Int

    -- Number of binders in the callee's OWN annotation (`Can.Forall`). Zero
    -- with a non-empty `typeVars` means the body's node types carry variables
    -- the signature does not — a TYPE_007/POST_010 leak, not polymorphism.
    , annBinders : Int
    }



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| Inline small non-recursive globals across the whole graph, to a fixpoint.
-}
optimize : Config.InlineConfig -> AssignMVarIds.GlobalMVarState -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
optimize cfg state graph =
    let
        cands =
            buildCandidates cfg state graph

        ctx0 =
            { candidates = cands.index
            , metrics =
                { emptyMetrics
                    | candidates = CoreDict.size cands.index
                    , recursiveSkipped = cands.recursiveSkipped
                    , overBudget = cands.overBudget
                    , polymorphic = cands.polymorphic
                    , polyKernel = cands.polyKernel
                    , rowPoly = cands.rowPoly
                    , superVar = cands.superVar
                    , hofParam = cands.hofParam
                    , bodiesSeen = cands.bodiesSeen
                    , overBudgetBuckets = cands.overBudgetBuckets
                    , overBudgetCosts = cands.overBudgetCosts
                    , hofNames = cands.hofNames
                    , polyKernelNames = cands.polyKernelNames
                    , superVarNames = cands.superVarNames
                }
            , fresh = 0
            , fuel = max 1 cfg.fixpointIterations
            , state = state
            , censusOn = cfg.report
            , callerBinders = CoreDict.empty
            , hofDeclined = cands.hofDeclined
            }
    in
    rounds cfg ctx0 graph


rounds : Config.InlineConfig -> Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
rounds cfg ctx graph =
    if ctx.fuel <= 0 then
        ( graph, ctx.state, ctx.metrics )

    else
        let
            before =
                ctx.metrics.inlineCount

            ( graph1, ctx1 ) =
                rewriteGraph ctx graph
        in
        if ctx1.metrics.inlineCount == before then
            -- Fixpoint: a round that inlined nothing cannot be improved on.
            ( graph1, ctx1.state, ctx1.metrics )

        else
            rounds cfg { ctx1 | fuel = ctx1.fuel - 1 } graph1


-- ============================================================================
-- ====== CANDIDATE INDEX ======
-- ============================================================================


{-| Globals whose body is a small, non-recursive `Function`.

Recursion is read straight off `Node.Define`'s dependency set: a global that
reaches itself through the dep graph is refused, which is the same guard
`MonoInlineSimplify` applies via its call graph. Self-reference alone catches
direct recursion; the SCC closure below catches mutual recursion.

-}
buildCandidates :
    Config.InlineConfig
    -> AssignMVarIds.GlobalMVarState
    -> TOpt.GlobalGraph TypeIds.MVarId
    ->
        { index : CoreDict.Dict String Candidate
        , recursiveSkipped : Int
        , overBudget : Int
        , polymorphic : Int
        , polyKernel : Int
        , rowPoly : Int
        , superVar : Int
        , hofParam : Int
        , bodiesSeen : Int
        , overBudgetBuckets : ( Int, Int, ( Int, Int ) )
        , overBudgetCosts : List ( String, Int )
        , hofDeclined : CoreDict.Dict String (List Bool)
        , hofNames : List String
        , polyKernelNames : List String
        , superVarNames : List String
        }
buildCandidates cfg state (TOpt.GlobalGraph nodes _ annotations _ _) =
    let
        recursive =
            recursiveGlobals nodes

        step g node acc =
            let
                key =
                    TOpt.toComparableGlobal g
            in
            case bodyOf node of
                Just ( params, body ) ->
                    (\a ->
                        if CoreDict.member key recursive then
                            { a | recursiveSkipped = a.recursiveSkipped + 1 }

                        else if List.isEmpty params then
                            a

                        else if cost body > cfg.threshold then
                            let
                                c =
                                    cost body

                                ( b1, b2, ( b3, b4 ) ) =
                                    a.overBudgetBuckets
                            in
                            if cfg.report then
                                { a
                                    | overBudget = a.overBudget + 1
                                    , overBudgetBuckets =
                                        if c <= 15 then
                                            ( b1 + 1, b2, ( b3, b4 ) )

                                        else if c <= 25 then
                                            ( b1, b2 + 1, ( b3, b4 ) )

                                        else if c <= 50 then
                                            ( b1, b2, ( b3 + 1, b4 ) )

                                        else
                                            ( b1, b2, ( b3, b4 + 1 ) )
                                    , overBudgetCosts = ( qualifiedName g, c ) :: a.overBudgetCosts
                                }

                            else
                                { a | overBudget = a.overBudget + 1 }

                        else if polyKernel params body then
                            { a
                                | polyKernel = a.polyKernel + 1
                                , polyKernelNames =
                                    if cfg.report then
                                        qualifiedName g :: a.polyKernelNames

                                    else
                                        a.polyKernelNames
                            }

                        else if hasOpenRecord params body then
                            { a | rowPoly = a.rowPoly + 1 }

                        else if List.any (\( _, t ) -> isFunctionType t) params then
                            { a
                                | hofParam = a.hofParam + 1
                                , hofNames =
                                    if cfg.report then
                                        qualifiedName g :: a.hofNames

                                    else
                                        a.hofNames
                                , hofDeclined =
                                    if cfg.report then
                                        CoreDict.insert key
                                            (List.map (\( _, t ) -> isFunctionType t) params)
                                            a.hofDeclined

                                    else
                                        a.hofDeclined
                            }

                        else if
                            List.any
                                (\v -> CoreDict.member v state.superVars)
                                (candidateTypeVars params body)
                        then
                            { a
                                | superVar = a.superVar + 1
                                , superVarNames =
                                    if cfg.report then
                                        qualifiedName g :: a.superVarNames

                                    else
                                        a.superVarNames
                            }

                        else
                            let
                                tvs =
                                    candidateTypeVars params body
                            in
                            { a
                              -- POLYMORPHIC CANDIDATES ARE ADMITTED. This
                              -- counter used to gate a refusal, and refusing
                              -- rejected ~98% of what the pass could inline
                              -- (2,738 of 3,236 on the self-compile). It is
                              -- kept as a census of how much of the admitted
                              -- set `suffixType`'s rename is carrying.
                                | polymorphic =
                                    if List.isEmpty tvs then
                                        a.polymorphic

                                    else
                                        a.polymorphic + 1
                                , index =
                                    CoreDict.insert key
                                        { params = params
                                        , body = body
                                        , name = qualifiedName g
                                        , typeVars = tvs
                                        , annBinders =
                                            case Dict.get TOpt.toComparableGlobal g annotations of
                                                Just (Can.Forall fv _) ->
                                                    CoreDict.size fv

                                                Nothing ->
                                                    0
                                        }
                                        a.index
                            }
                    )
                        { acc | bodiesSeen = acc.bodiesSeen + 1 }

                Nothing ->
                    acc
    in
    Dict.foldl TOpt.compareGlobal
        step
        { index = CoreDict.empty
        , recursiveSkipped = 0
        , overBudget = 0
        , polymorphic = 0
        , polyKernel = 0
        , rowPoly = 0
        , superVar = 0
        , hofParam = 0
        , bodiesSeen = 0
        , overBudgetBuckets = ( 0, 0, ( 0, 0 ) )
        , overBudgetCosts = []
        , hofDeclined = CoreDict.empty
        , hofNames = []
        , polyKernelNames = []
        , superVarNames = []
        }
        nodes


{-| Whether a type is a function type — a parameter this pass will not inline
through.

A higher-order callee's lambda argument has no settled staging or PAP shape
before monomorphization, and its lambda set is exactly what the LSS track spends
its effort deriving. `MonoInlineSimplify` has a whole apparatus for this
(`hofThreshold`, `exactOnly`, `partialHof`, `loopify`) built on
already-specialized code; none of it is available here.

Measured: inlining `List.foldr` pre-mono made `LetNumberFoldrTest` print `0`
instead of `105` — a `List number` whose defaulting depends on which of its uses
survive.

-}
isFunctionType : Can.Type TypeIds.MVarId -> Bool
isFunctionType tipe =
    case tipe of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ real ->
            isFunctionType (aliasBody real)

        _ ->
            False


{-| Whether any type in the candidate is an OPEN (row-polymorphic) record.

`{ r | field : t }` has its layout decided by the ACTUAL record supplied, and
`matchType` binds only the fields it can see — it has no way to bind the row
variable `r`, so a copy keeps an open record whose layout is then wrong.
Measured: the ten `RecordNarrow*` E2E tests SIGSEGV without this guard.

Binding rows properly is the natural successor to this pass, not part of it.

-}
hasOpenRecord : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Bool
hasOpenRecord params body =
    List.any (\( _, t ) -> openRecordInType t) (List.map identity params)
        || openRecordInExpr body


openRecordInExpr : TOpt.Expr TypeIds.MVarId -> Bool
openRecordInExpr expr =
    openRecordInType (TOpt.typeOf expr)
        || List.any openRecordInExpr (children expr)


openRecordInType : Can.Type TypeIds.MVarId -> Bool
openRecordInType tipe =
    case tipe of
        Can.TRecord fields ext ->
            ext
                /= Nothing
                || CoreDict.foldl
                    (\_ (Can.FieldType _ t) acc -> acc || openRecordInType t)
                    False
                    fields

        Can.TLambda _ a b ->
            openRecordInType a || openRecordInType b

        Can.TType _ _ args ->
            List.any openRecordInType args

        Can.TTuple a b rest ->
            openRecordInType a || openRecordInType b || List.any openRecordInType rest

        Can.TAlias _ _ args real ->
            List.any (\( _, t ) -> openRecordInType t) args
                || openRecordInType (aliasBody real)

        _ ->
            False


{-| Whether a candidate's body reaches a KERNEL call whose type mentions a type
variable — in which case it must not be copied, because substituting the call
site's types into the copy changes that kernel's registered signature.

`Eco.Crash.crash : String -> a` is the case that found this. Its body is a
kernel call whose result is the bare variable `a`, so 134 inlines registered
`Eco_Kernel_Crash_crash` at whatever each caller needed:

    Kernel signature mismatch for Eco_Kernel_Crash_crash:
        existing (eco.value -> eco.value) vs new (eco.value -> i16)

A kernel symbol is registered by NAME with one ABI, so a polymorphic kernel
wrapper cannot be instantiated per copy the way ordinary Elm code can. Pure-Elm
polymorphic candidates — the overwhelming majority — are unaffected: only a
kernel node whose own type is still variable declines.

-}
polyKernel : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Bool
polyKernel params body =
    not (List.isEmpty (candidateTypeVars params body))
        && hasPolymorphicKernel body


hasPolymorphicKernel : TOpt.Expr TypeIds.MVarId -> Bool
hasPolymorphicKernel expr =
    case expr of
        TOpt.VarKernel _ _ _ _ meta ->
            not (CoreDict.isEmpty (typeVarsOfType meta.tipe CoreDict.empty))

        _ ->
            List.any hasPolymorphicKernel (children expr)


type alias Subst =
    Fresh.Subst


{-| One-way structural match of a CALLEE type against the ACTUAL type at the
call site, binding the callee's variables.

Renaming a copied body's type variables makes each copy INDEPENDENTLY
polymorphic, which is sound but leaves the copy's nodes variable-typed with
nothing to solve them: the call that carried the demand is exactly what
inlining removed. Measured — `swap : ( a, b ) -> ( b, a )` used at
`( Int, String )` and at `( String, Int )` produced pointer-sized garbage,
because the spliced `Tuple` node's slot kinds were laid out from a type that
was still a variable.

So determine what can be determined, and rename only the rest. Deliberately
PERMISSIVE: a shape mismatch binds nothing rather than failing, because a
missing binding degrades to the (sound) rename while a wrong one would not.

-}
matchType : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Subst -> Subst
matchType pattern actual subst =
    case ( pattern, actual ) of
        ( Can.TVar n, _ ) ->
            -- First binding wins; a second, different one would mean the call
            -- site is inconsistent, and refusing the call is the safe answer.
            if CoreDict.member (Id.toComparable n) subst then
                subst

            else
                CoreDict.insert (Id.toComparable n) actual subst

        ( Can.TLambda _ pa pb, Can.TLambda _ aa ab ) ->
            matchType pb ab (matchType pa aa subst)

        ( Can.TType _ pn pargs, Can.TType _ an aargs ) ->
            if pn == an then
                matchList pargs aargs subst

            else
                subst

        ( Can.TTuple pa pb prest, Can.TTuple aa ab arest ) ->
            matchList prest arest (matchType pb ab (matchType pa aa subst))

        ( Can.TRecord pfields _, Can.TRecord afields _ ) ->
            CoreDict.foldl
                (\field (Can.FieldType _ pt) acc ->
                    case CoreDict.get field afields of
                        Just (Can.FieldType _ at) ->
                            matchType pt at acc

                        Nothing ->
                            acc
                )
                subst
                pfields

        ( Can.TAlias _ pn pargs _, Can.TAlias _ an aargs _ ) ->
            if pn == an then
                matchList (List.map Tuple.second pargs) (List.map Tuple.second aargs) subst

            else
                matchType (expandAlias pattern) (expandAlias actual) subst

        ( Can.TAlias _ _ _ _, _ ) ->
            matchType (expandAlias pattern) actual subst

        ( _, Can.TAlias _ _ _ _ ) ->
            matchType pattern (expandAlias actual) subst

        _ ->
            subst


matchList : List (Can.Type TypeIds.MVarId) -> List (Can.Type TypeIds.MVarId) -> Subst -> Subst
matchList patterns actuals subst =
    List.foldl (\( p, a ) acc -> matchType p a acc)
        subst
        (List.map2 Tuple.pair patterns actuals)


aliasBody : Can.AliasType TypeIds.MVarId -> Can.Type TypeIds.MVarId
aliasBody alias_ =
    case alias_ of
        Can.Holey t ->
            t

        Can.Filled t ->
            t


{-| The alias's body with its parameters replaced by the arguments — the
type the alias stands for. Never matched against with the parameter names
still in it: they would bind as if they were the caller's variables.
-}
expandAlias : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
expandAlias tipe =
    case tipe of
        Can.TAlias _ _ args (Can.Holey body) ->
            -- Alias parameters are alias-LOCAL and are matched BY POSITION, never
            -- by id membership: after assignment a parameter id was minted by
            -- name in the definition's env, so it can share an id with a
            -- same-named scheme binder.
            substTypeVars
                (CoreDict.fromList (List.map (\( pn, t ) -> ( Id.toComparable pn, t )) args))
                body

        Can.TAlias _ _ _ (Can.Filled body) ->
            body

        _ ->
            tipe


substTypeVars : CoreDict.Dict Int (Can.Type TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
substTypeVars env tipe =
    case tipe of
        Can.TVar n ->
            Maybe.withDefault tipe (CoreDict.get (Id.toComparable n) env)

        Can.TLambda slot a b ->
            Can.TLambda slot (substTypeVars env a) (substTypeVars env b)

        Can.TType h n args ->
            Can.TType h n (List.map (substTypeVars env) args)

        Can.TRecord fields ext ->
            Can.TRecord (CoreDict.map (\_ (Can.FieldType i t) -> Can.FieldType i (substTypeVars env t)) fields) ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b rest ->
            Can.TTuple (substTypeVars env a) (substTypeVars env b) (List.map (substTypeVars env) rest)

        Can.TAlias h n args real ->
            Can.TAlias h n (List.map (\( pn, t ) -> ( pn, substTypeVars env t )) args) real


{-| Every type variable reachable from a candidate's parameter types and body,
as `Id.toComparable` keys.

Used by the `polymorphic` census and by `determines`. The supertype constraint
of a variable the copy re-mints is carried across by
`PreMono.Fresh.freshenCopy`, which copies it into `superVars` BY ID — that is
what replaced this pass's old `varSupers`-by-name re-keying.

-}
candidateTypeVars : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> List Int
candidateTypeVars params body =
    CoreDict.keys
        (List.foldl typeVarsOfType
            (typeVarsOfExpr body CoreDict.empty)
            (List.map Tuple.second params)
        )


typeVarsOfExpr : TOpt.Expr TypeIds.MVarId -> CoreDict.Dict Int () -> CoreDict.Dict Int ()
typeVarsOfExpr expr acc =
    List.foldl typeVarsOfExpr
        (typeVarsOfType (TOpt.typeOf expr) acc)
        (children expr)


typeVarsOfType : Can.Type TypeIds.MVarId -> CoreDict.Dict Int () -> CoreDict.Dict Int ()
typeVarsOfType tipe acc =
    case tipe of
        Can.TVar n ->
            CoreDict.insert (Id.toComparable n) () acc

        Can.TLambda _ a b ->
            typeVarsOfType b (typeVarsOfType a acc)

        Can.TType _ _ args ->
            List.foldl typeVarsOfType acc args

        Can.TRecord fields ext ->
            CoreDict.foldl
                (\_ (Can.FieldType _ t) a -> typeVarsOfType t a)
                (case ext of
                    Just n ->
                        CoreDict.insert (Id.toComparable n) () acc

                    Nothing ->
                        acc
                )
                fields

        Can.TUnit ->
            acc

        Can.TTuple a b rest ->
            List.foldl typeVarsOfType (typeVarsOfType b (typeVarsOfType a acc)) rest

        Can.TAlias _ _ args _ ->
            -- ALIAS PARAMETERS ARE NOT FREE VARIABLES. `TAlias`'s list pairs the
            -- alias's own parameter NAMES with the argument types, and a `Holey`
            -- body mentions those names; `MonoSolver.Store` binds each to its
            -- argument's Point and restores afterwards ("params are
            -- alias-local"). Counting them made every `Task`/`IO`-returning
            -- callee look polymorphic and `determines` refuse it — 273 spurious
            -- `undetermined` at `Utils.Main.envLookupEnv` alone. A `Filled`
            -- body's free variables are a subset of the arguments' anyway, so
            -- the arguments are the whole answer in both cases.
            List.foldl (\( _, t ) a -> typeVarsOfType t a) acc args


{-| Immediate sub-expressions, for the ground-type walk. Includes the decider's
`Inline` choices — an unshared `case` branch body lives there.
-}
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
            defChildren def ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderChildren decider ++ List.map Tuple.second jumps

        TOpt.Access inner _ _ _ ->
            [ inner ]

        TOpt.Update _ record fields _ ->
            record :: Dict.values A.compareLocated fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            Dict.values A.compareLocated fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


defChildren : TOpt.Def TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
defChildren def =
    case def of
        TOpt.Def _ _ bound _ ->
            [ bound ]

        TOpt.TailDef _ _ _ body _ _ ->
            [ body ]


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


{-| The inlinable `(params, body)` of a top-level node, if it has one.

Both `Define` and `TrackedDefine` carry bodies, and both `Function` and
`TrackedFunction` are lambda forms — `TrackedFunction` is what the front end
emits for a definition with source-tracked parameter names, which is the
COMMON case for user code. Missing it here is why the first census run
reported a single candidate for the whole program.

`TrackedFunction`'s params are `A.Located Name`; they are stripped to bare
names because the inlined copy binds them as ordinary `Let`s, which take a
bare `Name`.

-}
bodyOf : TOpt.Node TypeIds.MVarId -> Maybe ( List ( Name, Can.Type TypeIds.MVarId ), TOpt.Expr TypeIds.MVarId )
bodyOf node =
    let
        fromExpr expr =
            case expr of
                TOpt.Function _ params body _ ->
                    Just ( params, body )

                TOpt.TrackedFunction _ params body _ ->
                    Just ( List.map (\( n, t ) -> ( A.toValue n, t )) params, body )

                _ ->
                    Nothing
    in
    case node of
        TOpt.Define expr _ _ ->
            fromExpr expr

        TOpt.TrackedDefine _ expr _ _ ->
            fromExpr expr

        _ ->
            Nothing


{-| Globals that must never be inlined because inlining them would not
terminate: anything in a dependency CYCLE, plus anything that names itself.

Three independent sources, unioned, because no one of them is complete:

  - `Compiler.Graph.stronglyConnComp` over the `Define`/`TrackedDefine`/`Cycle`
    dependency sets — this is what catches MUTUAL recursion, `f -> g -> f`,
    which a self-reference test cannot see;
  - membership of a `Cycle` node, which is recursive by construction;
  - a STRUCTURAL scan of the body for a `VarGlobal`/`VarCycle` naming the node
    itself. This is not redundant with the SCC: a self-recursive function's
    `deps` set did not contain itself in the graph the test harness builds, so
    the SCC reported it acyclic and the self-recursive fixture was admitted as
    an inline candidate. The structural scan is the one that cannot be wrong,
    because it reads the body that would actually be copied.

-}
recursiveGlobals : Dict String TOpt.Global (TOpt.Node TypeIds.MVarId) -> CoreDict.Dict String ()
recursiveGlobals nodes =
    let
        depsOf node =
            case node of
                TOpt.Define _ deps _ ->
                    deps

                TOpt.TrackedDefine _ _ deps _ ->
                    deps

                TOpt.Cycle _ _ _ deps ->
                    deps

                TOpt.PortIncoming _ deps _ ->
                    deps

                TOpt.PortOutgoing _ deps _ ->
                    deps

                TOpt.Kernel _ deps ->
                    deps

                _ ->
                    EverySet.empty

        edges =
            Dict.foldl TOpt.compareGlobal
                (\g node acc ->
                    ( TOpt.toComparableGlobal g
                    , TOpt.toComparableGlobal g
                    , List.map TOpt.toComparableGlobal
                        (EverySet.toList TOpt.compareGlobal (depsOf node))
                    )
                        :: acc
                )
                []
                nodes

        inCycle =
            List.foldl
                (\scc acc ->
                    case scc of
                        Graph.CyclicSCC keys ->
                            List.foldl (\k a -> CoreDict.insert k () a) acc keys

                        Graph.AcyclicSCC _ ->
                            acc
                )
                CoreDict.empty
                (Graph.stronglyConnComp edges)

        structural =
            Dict.foldl TOpt.compareGlobal
                (\g node acc ->
                    case node of
                        TOpt.Cycle _ _ _ _ ->
                            CoreDict.insert (TOpt.toComparableGlobal g) () acc

                        _ ->
                            case bodyOf node of
                                Just ( _, body ) ->
                                    if namesSelf g body then
                                        CoreDict.insert (TOpt.toComparableGlobal g) () acc

                                    else
                                        acc

                                Nothing ->
                                    acc
                )
                CoreDict.empty
                nodes
    in
    CoreDict.union inCycle structural


{-| Whether an expression mentions the given global by name, anywhere.
-}
namesSelf : TOpt.Global -> TOpt.Expr TypeIds.MVarId -> Bool
namesSelf ((TOpt.Global home name) as g) expr =
    case expr of
        TOpt.VarGlobal _ g2 _ ->
            TOpt.compareGlobal g g2 == EQ

        TOpt.VarCycle _ home2 name2 _ ->
            home2 == home && name2 == name

        TOpt.VarEnum _ g2 _ _ ->
            TOpt.compareGlobal g g2 == EQ

        TOpt.VarBox _ g2 _ ->
            TOpt.compareGlobal g g2 == EQ

        _ ->
            List.any (namesSelf g) (children expr)


qualifiedName : TOpt.Global -> String
qualifiedName g =
    TOpt.toComparableGlobal g



-- ============================================================================
-- ====== COST ======
-- ============================================================================


{-| Body cost, mirroring `MonoInlineSimplify.computeCost`'s shape with the
kernel arm collapsed to the flat 6 (that plan's §3: pre-mono the kernel is
known but its concrete instance is not, so the cost-class vector cannot apply).
-}
cost : TOpt.Expr TypeIds.MVarId -> Int
cost expr =
    case expr of
        TOpt.Bool _ _ _ ->
            1

        TOpt.Chr _ _ _ ->
            1

        TOpt.Str _ _ _ ->
            1

        TOpt.Int _ _ _ ->
            1

        TOpt.Float _ _ _ ->
            1

        TOpt.VarLocal _ _ ->
            1

        TOpt.TrackedVarLocal _ _ _ ->
            1

        TOpt.VarGlobal _ _ _ ->
            1

        TOpt.VarEnum _ _ _ _ ->
            1

        TOpt.VarBox _ _ _ ->
            1

        TOpt.VarCycle _ _ _ _ ->
            1

        TOpt.VarDebug _ _ _ _ _ ->
            1

        TOpt.VarKernel _ _ _ _ _ ->
            1

        TOpt.Unit _ ->
            1

        TOpt.Accessor _ _ _ ->
            1

        TOpt.List _ items _ ->
            3 + sumBy cost items

        TOpt.Function _ _ body _ ->
            5 + cost body

        TOpt.TrackedFunction _ _ body _ ->
            5 + cost body

        TOpt.Call _ func args _ ->
            5 + cost func + sumBy cost args

        TOpt.TailCall _ args _ ->
            5 + sumBy (\( _, e ) -> cost e) args

        TOpt.If branches final _ ->
            2 + sumBy (\( c, t ) -> cost c + cost t) branches + cost final

        TOpt.Let def body _ ->
            2 + costDef def + cost body

        TOpt.Destruct _ body _ ->
            2 + cost body

        TOpt.Case _ _ decider branches _ ->
            3 + costDecider decider + sumBy (\( _, e ) -> cost e) branches

        TOpt.Access inner _ _ _ ->
            1 + cost inner

        TOpt.Update _ inner fields _ ->
            3 + cost inner + Dict.foldl A.compareLocated (\_ e a -> a + cost e) 0 fields

        TOpt.Record fields _ ->
            3 + CoreDict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.TrackedRecord _ fields _ ->
            3 + Dict.foldl A.compareLocated (\_ e a -> a + cost e) 0 fields

        TOpt.Tuple _ a b rest _ ->
            3 + cost a + cost b + sumBy cost rest

        TOpt.Shader _ _ _ _ ->
            1


{-| The cost of a decider tree. `Case`'s branch list holds only the SHARED
jump targets; an unshared branch body sits in a `Leaf (Inline expr)` inside the
decider. Omitting this arm under-counts a `case`-heavy body by its whole
branch weight, which is how a budget-respecting inliner ends up copying
something enormous.
-}
costDecider : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> Int
costDecider decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            cost e

        TOpt.Leaf (TOpt.Jump _) ->
            1

        TOpt.Chain tests ok ko ->
            1 + List.length tests + costDecider ok + costDecider ko

        TOpt.FanOut _ branches fallback ->
            1 + sumBy (\( _, d ) -> costDecider d) branches + costDecider fallback


costDef : TOpt.Def TypeIds.MVarId -> Int
costDef def =
    case def of
        TOpt.Def _ _ bound _ ->
            cost bound

        TOpt.TailDef _ _ _ body _ _ ->
            cost body


sumBy : (a -> Int) -> List a -> Int
sumBy f =
    List.foldl (\x acc -> acc + f x) 0



-- ============================================================================
-- ====== REWRITE ======
-- ============================================================================


rewriteGraph : Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, Ctx )
rewriteGraph ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( nodes1, ctx1 ) =
            Dict.foldl TOpt.compareGlobal
                (\g node ( acc, c ) ->
                    let
                        cIn =
                            if c.censusOn then
                                { c
                                    | callerBinders =
                                        -- From the annotation's TYPE, not its
                                        -- `FreeVars`: `Can.FreeVars` is
                                        -- `Dict Name ()` and is NOT
                                        -- id-parameterised, so it still carries
                                        -- NAMES after assignment. The two agree
                                        -- by construction —
                                        -- `AssignMVarIds.rewriteAnnotation`
                                        -- seeds every binder through
                                        -- `ensureBinder`, so the type's
                                        -- variables ARE the scheme's binders.
                                        case Dict.get TOpt.toComparableGlobal g annotations of
                                            Just (Can.Forall _ annType) ->
                                                typeVarsOfType annType CoreDict.empty

                                            Nothing ->
                                                CoreDict.empty
                                }

                            else
                                c

                        ( node1, c1 ) =
                            rewriteNode cIn node
                    in
                    ( Dict.insert TOpt.toComparableGlobal g node1 acc, c1 )
                )
                ( Dict.empty, ctx )
                nodes
    in
    ( TOpt.GlobalGraph nodes1 fields annotations schemeRoots varSupers, ctx1 )


rewriteNode : Ctx -> TOpt.Node TypeIds.MVarId -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx node =
    case node of
        TOpt.Define expr deps meta ->
            let
                ( e1, c1 ) =
                    rewriteExpr ctx expr
            in
            ( TOpt.Define e1 deps meta, c1 )

        TOpt.TrackedDefine region expr deps meta ->
            let
                ( e1, c1 ) =
                    rewriteExpr ctx expr
            in
            ( TOpt.TrackedDefine region e1 deps meta, c1 )

        TOpt.PortIncoming expr deps meta ->
            let
                ( e1, c1 ) =
                    rewriteExpr ctx expr
            in
            ( TOpt.PortIncoming e1 deps meta, c1 )

        TOpt.PortOutgoing expr deps meta ->
            let
                ( e1, c1 ) =
                    rewriteExpr ctx expr
            in
            ( TOpt.PortOutgoing e1 deps meta, c1 )

        _ ->
            -- Ctor/Enum/Box/Link/Manager/Kernel/Cycle carry no inlinable body
            -- (Cycle is recursive by construction and refused above).
            ( node, ctx )


rewriteExpr : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.Call region func args meta ->
            let
                ( func1, c1 ) =
                    rewriteExpr ctx func

                ( args1, c2 ) =
                    rewriteList c1 args
            in
            case tryInline c2 region func1 args1 meta of
                ( Just inlined, c3 ) ->
                    ( inlined, c3 )

                ( Nothing, c3 ) ->
                    ( TOpt.Call region func1 args1 meta, c3 )

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
            -- Literals, vars, accessors, shaders: no sub-expressions.
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


{-| Rewrite the expressions hanging off a decider tree. `Leaf (Inline e)` is a
whole unshared `case` branch body, so skipping this loses inlining across every
non-jump branch in the program.
-}
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



-- ============================================================================
-- ====== THE INLINE ITSELF ======
-- ============================================================================


{-| Exact-arity inline of a known global.

`Call (VarGlobal g) args` where `g`'s body is `Function params body` and
`List.length args == List.length params` becomes

    let p1' = arg1 in
    let p2' = arg2 in
    body'

with `p_i'` fresh and `body'` the body with EVERY binder freshened. Arguments
are bound rather than substituted so they evaluate in the caller's scope (see
the module doc).

-}
tryInline : Ctx -> A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> ( Maybe (TOpt.Expr TypeIds.MVarId), Ctx )
tryInline ctx region func args callMeta =
    case func of
        TOpt.VarGlobal _ g _ ->
            case CoreDict.get (TOpt.toComparableGlobal g) ctx.candidates of
                Just cand ->
                    if List.length args /= List.length cand.params then
                        ( Nothing, ctx )

                    else
                        let
                            subst =
                                callSiteSubst cand args callMeta
                        in
                        if determines cand subst then
                            Tuple.mapFirst Just
                                (doInline ctx region cand args subst)

                        else
                            -- The CALL SITE does not pin this callee's types
                            -- down, so decline THIS call rather than the
                            -- candidate. See `determines`.
                            ( Nothing
                            , { ctx
                                | metrics =
                                    censusUndetermined ctx cand args callMeta subst
                                        (\m -> { m | undetermined = m.undetermined + 1 })
                                        ctx.metrics
                              }
                            )

                Nothing ->
                    ( Nothing, censusHofArgs ctx g args )

        _ ->
            ( Nothing, ctx )


{-| Q1 census: why did `determines` fail at this call? Off unless
`inline.report`. A site is `undLocal` if ANY offending free variable is not a
binder of the caller's annotation; else `undBodyOnly` if any callee variable
occurs in no parameter and not in the result; else `undCallerPoly`.
-}
censusUndetermined : Ctx -> Candidate -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Subst -> (Metrics -> Metrics) -> Metrics -> Metrics
censusUndetermined ctx cand args callMeta subst bump m0 =
    let
        m =
            bump m0
    in
    if not ctx.censusOn then
        m

    else
        let
            paramTypes =
                List.map Tuple.second cand.params

            argTypes =
                List.map TOpt.typeOf args

            mentions v t =
                CoreDict.member v (typeVarsOfType t CoreDict.empty)

            freeOf t =
                CoreDict.keys (typeVarsOfType t CoreDict.empty)

            -- The free variables the call site offers for callee var `v`.
            offered v =
                case CoreDict.get v subst of
                    Just t ->
                        freeOf t

                    Nothing ->
                        List.concatMap
                            (\( pt, at ) ->
                                if mentions v pt then
                                    freeOf at

                                else
                                    []
                            )
                            (List.map2 Tuple.pair paramTypes argTypes)
                            ++ (if mentions v (TOpt.typeOf cand.body) then
                                    freeOf callMeta.tipe

                                else
                                    []
                               )

            classes =
                cand.typeVars
                    |> List.filter
                        (\v ->
                            case CoreDict.get v subst of
                                Just t ->
                                    not (isGroundType t)

                                Nothing ->
                                    True
                        )
                    |> List.map
                        (\v ->
                            case offered v of
                                [] ->
                                    1

                                vs ->
                                    if List.all (\x -> CoreDict.member x ctx.callerBinders) vs then
                                        0

                                    else
                                        2
                        )

            site =
                List.foldl max 0 classes

            bumpDict k d =
                CoreDict.update k (\n -> Just (1 + Maybe.withDefault 0 n)) d
        in
        { m
            | undLeak =
                if cand.annBinders == 0 then
                    m.undLeak + 1

                else
                    m.undLeak
            , undeterminedByCallee = bumpDict cand.name m.undeterminedByCallee
            , undCallerPoly =
                if site == 0 then
                    m.undCallerPoly + 1

                else
                    m.undCallerPoly
            , undCallerPolyByCallee =
                if site == 0 then
                    bumpDict cand.name m.undCallerPolyByCallee

                else
                    m.undCallerPolyByCallee
            , undBodyOnly =
                if site == 1 then
                    m.undBodyOnly + 1

                else
                    m.undBodyOnly
            , undBodyOnlyByCallee =
                if site == 1 then
                    bumpDict cand.name m.undBodyOnlyByCallee

                else
                    m.undBodyOnlyByCallee
            , undLocal =
                if site == 2 then
                    m.undLocal + 1

                else
                    m.undLocal
            , undLocalByCallee =
                if site == 2 then
                    bumpDict cand.name m.undLocalByCallee

                else
                    m.undLocalByCallee
        }


{-| Q1 census: at a call to a global refused by the `hofParam` guard, what
shape is each function-typed argument? Off unless `inline.report`.
-}
censusHofArgs : Ctx -> TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Ctx
censusHofArgs ctx g args =
    if not ctx.censusOn then
        ctx

    else
        case CoreDict.get (TOpt.toComparableGlobal g) ctx.hofDeclined of
            Nothing ->
                ctx

            Just flags ->
                let
                    m =
                        List.foldl
                            (\( isFn, arg ) acc ->
                                if not isFn then
                                    acc

                                else
                                    case arg of
                                        TOpt.Function _ _ _ _ ->
                                            { acc | hofArgLambda = acc.hofArgLambda + 1 }

                                        TOpt.TrackedFunction _ _ _ _ ->
                                            { acc | hofArgLambda = acc.hofArgLambda + 1 }

                                        TOpt.VarGlobal _ _ _ ->
                                            { acc | hofArgGlobal = acc.hofArgGlobal + 1 }

                                        _ ->
                                            { acc | hofArgOther = acc.hofArgOther + 1 }
                            )
                            ctx.metrics
                            (List.map2 Tuple.pair flags args)
                in
                { ctx | metrics = m }


{-| What the call site says each of the callee's type variables is: parameters
against the actual arguments, plus the callee's result type against the call's
own type.
-}
callSiteSubst : Candidate -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Subst
callSiteSubst cand args callMeta =
    matchType (TOpt.typeOf cand.body)
        callMeta.tipe
        (List.foldl
            (\( ptype, arg ) acc -> matchType ptype (TOpt.typeOf arg) acc)
            CoreDict.empty
            (List.map2 Tuple.pair (List.map Tuple.second cand.params) args)
        )


{-| Whether the call site determines EVERY one of the callee's type variables,
concretely.

**This is the guard that makes copying a polymorphic body safe, and it has to
be per CALL rather than per candidate.** Renaming a copy's type variables makes
it independently polymorphic, which is sound but leaves its nodes
variable-typed with nothing to solve them — the call that carried the demand is
what inlining removed. The layout decisions then go wrong: `swap` at two tuple
types returned pointer-sized garbage, and `Tuple.second` SIGSEGV'd the ten
`RecordNarrow*` tests.

The tempting reading is that a call site always knows its argument types. It
does not: this pass runs BEFORE monomorphization, so an argument's `meta.tipe`
is frequently still a variable that only `MonoSolver` resolves. Where that
happens the copy would be variable-typed however carefully it is renamed, so
the only safe answer is to leave the call alone.

-}
determines : Candidate -> Subst -> Bool
determines cand subst =
    List.all
        (\v ->
            case CoreDict.get v subst of
                Just t ->
                    isGroundType t

                Nothing ->
                    False
        )
        cand.typeVars


isGroundType : Can.Type TypeIds.MVarId -> Bool
isGroundType tipe =
    CoreDict.isEmpty (typeVarsOfType tipe CoreDict.empty)


doInline : Ctx -> A.Region -> Candidate -> List (TOpt.Expr TypeIds.MVarId) -> Subst -> ( TOpt.Expr TypeIds.MVarId, Ctx )
doInline ctx region cand args subst =
    let
        ( freshBody, freshParams, ctx1 ) =
            freshenBody ctx subst cand

        wrapped =
            List.foldr
                (\( ( pname, ptype ), arg ) acc ->
                    TOpt.Let (TOpt.Def region pname arg ptype) acc (TOpt.metaOf acc)
                )
                freshBody
                (List.map2 Tuple.pair freshParams args)

        m =
            ctx1.metrics
    in
    ( wrapped
    , { ctx1
        | metrics =
            { m
                | inlineCount = m.inlineCount + 1
                , inlinedByCallee =
                    CoreDict.update cand.name
                        (\v -> Just (1 + Maybe.withDefault 0 v))
                        m.inlinedByCallee
            }
      }
    )


{-| Freshen a candidate body before splicing it into the caller: TYPE identity
through `PreMono.Fresh`, TERM names by a uniform per-copy suffix.

**Types.** `Fresh.freshenCopy` mints a new `SrcLambdaId` for every lambda in the
copy, a new `ArrowId` for every arrow, and — for every type variable the call
site did NOT determine — a fresh `MVarId` carrying the original's supertype
constraint. Determined variables are replaced by the call site's own type,
spliced verbatim. This replaced the `_pi` TYPE-name suffix, the
`varSupers`-by-name re-keying and the `SolverRoot -> NoArrow` clearing that this
pass used while it ran before `AssignMVarIds`.

**Terms.** Every LOCAL name in the body — binder or use, `Let`/`TailDef`/
`Destruct` binder, `Function`/`TrackedFunction` parameter, `Case` label and
root, `TailCall` label, `Path` root — gets the same `_pi<n>` suffix, unique to
this copy. Globals are untouched. A uniform suffix is INJECTIVE on names, so it
preserves shadowing exactly and needs no scope tracking: an inner `\x -> x`
under an outer `let x` still shadows, because both become the same `x_pi7` at
the same two depths.

Inlining one body at two sites in one caller would otherwise produce two
`let x = …` with the same name, which the backend rejects as an SSA
redefinition; and the mono pass's destructure-binder capture bug cannot recur
here because the walk has no per-binder-kind opt-out.

-}
freshenBody : Ctx -> Subst -> Candidate -> ( TOpt.Expr TypeIds.MVarId, List ( Name, Can.Type TypeIds.MVarId ), Ctx )
freshenBody ctx subst cand =
    let
        suffix =
            "_pi" ++ String.fromInt ctx.fresh

        -- One `freshenCopy` walk over the body, then the parameter types
        -- through the same allocator. The parameter types are the declared
        -- types of the `let` wrappers `doInline` builds; they are copies of the
        -- candidate's, so they mint their own arrow ids exactly as the body's do.
        ( freshBody, state1 ) =
            Fresh.freshenCopy subst ctx.state cand.body

        ( renamedParams, state2 ) =
            List.foldl
                (\( n, t ) ( acc, st ) ->
                    let
                        ( t1, st1 ) =
                            Fresh.freshenType subst st t
                    in
                    ( ( n ++ suffix, t1 ) :: acc, st1 )
                )
                ( [], state1 )
                cand.params
    in
    ( suffixExpr suffix freshBody
    , List.reverse renamedParams
    , { ctx | fresh = ctx.fresh + 1, state = state2 }
    )


{-| Apply the copy suffix to every local name in an expression. See
`freshenBody` for why a blanket rename is the right thing here.
-}
suffixExpr : String -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId
suffixExpr sfx expr =
    let
        go =
            suffixExpr sfx

        nm n =
            n ++ sfx

        loc ln =
            A.At (A.toRegion ln) (nm (A.toValue ln))
    in
    case expr of
        -- Literals and globals have no local names and no sub-expressions, but
        -- they DO carry a `Meta`, and that type can hold a variable — a numeric
        -- literal is `TVar "number42"`, and a `VarGlobal` carries the callee's
        -- instantiated type. A catch-all `_ -> expr` here silently leaves those
        -- unrenamed, which is the same shared-variable collapse the rename
        -- exists to prevent, just harder to see.
        TOpt.Bool region b meta ->
            TOpt.Bool region b meta

        TOpt.Chr region c meta ->
            TOpt.Chr region c meta

        TOpt.Str region v meta ->
            TOpt.Str region v meta

        TOpt.Int region i meta ->
            TOpt.Int region i meta

        TOpt.Float region f meta ->
            TOpt.Float region f meta

        TOpt.VarLocal n meta ->
            TOpt.VarLocal (nm n) meta

        TOpt.TrackedVarLocal region n meta ->
            TOpt.TrackedVarLocal region (nm n) meta

        TOpt.VarGlobal region g meta ->
            TOpt.VarGlobal region g meta

        TOpt.VarEnum region g idx meta ->
            TOpt.VarEnum region g idx meta

        TOpt.VarBox region g meta ->
            TOpt.VarBox region g meta

        TOpt.VarCycle region home n meta ->
            TOpt.VarCycle region home n meta

        TOpt.VarDebug region n home unqualified meta ->
            TOpt.VarDebug region n home unqualified meta

        TOpt.VarKernel region prefix home n meta ->
            TOpt.VarKernel region prefix home n meta

        TOpt.List region items meta ->
            TOpt.List region (List.map go items) meta

        TOpt.Function srcLam params body meta ->
            TOpt.Function srcLam
                (List.map (\( n, t ) -> ( nm n, t )) params)
                (go body)
                meta

        TOpt.TrackedFunction srcLam params body meta ->
            TOpt.TrackedFunction srcLam
                (List.map (\( ln, t ) -> ( loc ln, t )) params)
                (go body)
                meta

        TOpt.Call region f args meta ->
            TOpt.Call region (go f) (List.map go args) meta

        TOpt.TailCall n args meta ->
            TOpt.TailCall (nm n)
                (List.map (\( an, e ) -> ( nm an, go e )) args)
                meta

        TOpt.If branches final meta ->
            TOpt.If (List.map (\( c, t ) -> ( go c, go t )) branches)
                (go final)
                meta

        TOpt.Let def body meta ->
            TOpt.Let (suffixDef sfx def) (go body) meta

        TOpt.Destruct (TOpt.Destructor n path dmeta) body meta ->
            TOpt.Destruct
                (TOpt.Destructor (nm n) (suffixPath sfx path) dmeta)
                (go body)
                meta

        TOpt.Case label root decider jumps meta ->
            TOpt.Case (nm label)
                (nm root)
                (suffixDecider sfx decider)
                (List.map (\( i, e ) -> ( i, go e )) jumps)
                meta

        TOpt.Accessor region field meta ->
            TOpt.Accessor region field meta

        TOpt.Access inner region field meta ->
            TOpt.Access (go inner) region field meta

        TOpt.Update region record fields meta ->
            TOpt.Update region (go record) (Dict.map (\_ e -> go e) fields) meta

        TOpt.Record fields meta ->
            TOpt.Record (CoreDict.map (\_ e -> go e) fields) meta

        TOpt.TrackedRecord region fields meta ->
            TOpt.TrackedRecord region (Dict.map (\_ e -> go e) fields) meta

        TOpt.Unit meta ->
            TOpt.Unit meta

        TOpt.Tuple region a b rest meta ->
            TOpt.Tuple region (go a) (go b) (List.map go rest) meta

        TOpt.Shader src inputs outputs meta ->
            TOpt.Shader src inputs outputs meta


suffixDef : String -> TOpt.Def TypeIds.MVarId -> TOpt.Def TypeIds.MVarId
suffixDef sfx def =
    case def of
        TOpt.Def region n bound tipe ->
            TOpt.Def region
                (n ++ sfx)
                (suffixExpr sfx bound)
                (tipe)

        TOpt.TailDef region n args body tipe tvar ->
            TOpt.TailDef region
                (n ++ sfx)
                (List.map
                    (\( ln, t ) ->
                        ( A.At (A.toRegion ln) (A.toValue ln ++ sfx)
                        , t
                        )
                    )
                    args
                )
                (suffixExpr sfx body)
                (tipe)
                tvar


suffixPath : String -> TOpt.Path -> TOpt.Path
suffixPath sfx path =
    case path of
        TOpt.Index idx hint sub ->
            TOpt.Index idx hint (suffixPath sfx sub)

        TOpt.ArrayIndex i sub ->
            TOpt.ArrayIndex i (suffixPath sfx sub)

        TOpt.Field f sub ->
            TOpt.Field f (suffixPath sfx sub)

        TOpt.Unbox sub ->
            TOpt.Unbox (suffixPath sfx sub)

        TOpt.Root n ->
            TOpt.Root (n ++ sfx)


suffixDecider : String -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> TOpt.Decider (TOpt.Choice TypeIds.MVarId)
suffixDecider sfx decider =
    case decider of
        TOpt.Leaf choice ->
            TOpt.Leaf
                (case choice of
                    TOpt.Inline e ->
                        TOpt.Inline (suffixExpr sfx e)

                    TOpt.Jump i ->
                        TOpt.Jump i
                )

        TOpt.Chain tests ok ko ->
            TOpt.Chain tests
                (suffixDecider sfx ok)
                (suffixDecider sfx ko)

        TOpt.FanOut path branches fallback ->
            TOpt.FanOut path
                (List.map (\( t, d ) -> ( t, suffixDecider sfx d )) branches)
                (suffixDecider sfx fallback)


locatedName : A.Located Name -> Name
locatedName =
    A.toValue
