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
import Compiler.Eco.Config as Config
import Compiler.Graph as Graph
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
    }


type alias Ctx =
    { candidates : CoreDict.Dict String Candidate
    , metrics : Metrics
    , fresh : Int
    , fuel : Int

    -- `( original, renamed )` for every type variable `suffixType` has
    -- renamed. `optimize` turns this into the `varSupers` entries the renamed
    -- names need: `ensureMVarId` reads a variable's supertype constraint from
    -- that dict BY NAME, so `number42_pi3` would otherwise arrive
    -- unconstrained and default differently from `number42`.
    , renamedTypeVars : List ( Name, Name )
    }


type alias Candidate =
    { params : List ( Name, Can.Type Name )
    , body : TOpt.Expr Name
    , name : String

    -- Every type-variable name in `params` and `body`, computed once when the
    -- candidate is built rather than per inline. Two uses: the `polymorphic`
    -- census, and carrying `varSupers` entries across the per-copy rename
    -- (`suffixType`).
    , typeVars : List Name
    }



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| Inline small non-recursive globals across the whole graph, to a fixpoint.
-}
optimize : Config.InlineConfig -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Metrics )
optimize cfg graph =
    let
        cands =
            buildCandidates cfg graph

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
                }
            , fresh = 0
            , fuel = max 1 cfg.fixpointIterations
            , renamedTypeVars = []
            }
    in
    rounds cfg ctx0 graph


rounds : Config.InlineConfig -> Ctx -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Metrics )
rounds cfg ctx graph =
    if ctx.fuel <= 0 then
        ( withRenamedSupers ctx graph, ctx.metrics )

    else
        let
            before =
                ctx.metrics.inlineCount

            ( graph1, ctx1 ) =
                rewriteGraph ctx graph
        in
        if ctx1.metrics.inlineCount == before then
            -- Fixpoint: a round that inlined nothing cannot be improved on.
            ( withRenamedSupers ctx1 graph1, ctx1.metrics )

        else
            rounds cfg { ctx1 | fuel = ctx1.fuel - 1 } graph1


{-| Give every renamed type variable the supertype constraint its original
carried.

`AssignMVarIds.ensureMVarId` looks a variable's constraint up in `varSupers` BY
NAME (`Dict.get name ctx.varSupers`), and `varSupers` is the `GlobalGraph`'s
fifth field. A renamed `number42_pi3` is absent from it, so it would be minted
unconstrained while `number42` is a `number` — a silent difference in
defaulting, not a type error. Applied once at the end rather than per round:
the map only grows, and a later round's rename of an already-renamed name
cannot occur (suffixes are unique per copy).

-}
withRenamedSupers : Ctx -> TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
withRenamedSupers ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    TOpt.GlobalGraph nodes
        fields
        annotations
        schemeRoots
        (List.foldl
            (\( original, renamed ) acc ->
                case CoreDict.get original varSupers of
                    Just super ->
                        CoreDict.insert renamed super acc

                    Nothing ->
                        acc
            )
            varSupers
            ctx.renamedTypeVars
        )



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
    -> TOpt.GlobalGraph Name
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
        }
buildCandidates cfg (TOpt.GlobalGraph nodes _ _ _ varSupers) =
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
                            { a | overBudget = a.overBudget + 1 }

                        else if polyKernel params body then
                            { a | polyKernel = a.polyKernel + 1 }

                        else if hasOpenRecord params body then
                            { a | rowPoly = a.rowPoly + 1 }

                        else if List.any (\( _, t ) -> isFunctionType t) params then
                            { a | hofParam = a.hofParam + 1 }

                        else if
                            List.any
                                (\v -> CoreDict.member v varSupers)
                                (candidateTypeVars params body)
                        then
                            { a | superVar = a.superVar + 1 }

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
isFunctionType : Can.Type Name -> Bool
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
hasOpenRecord : List ( Name, Can.Type Name ) -> TOpt.Expr Name -> Bool
hasOpenRecord params body =
    List.any (\( _, t ) -> openRecordInType t) (List.map identity params)
        || openRecordInExpr body


openRecordInExpr : TOpt.Expr Name -> Bool
openRecordInExpr expr =
    openRecordInType (TOpt.typeOf expr)
        || List.any openRecordInExpr (children expr)


openRecordInType : Can.Type Name -> Bool
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
polyKernel : List ( Name, Can.Type Name ) -> TOpt.Expr Name -> Bool
polyKernel params body =
    not (List.isEmpty (candidateTypeVars params body))
        && hasPolymorphicKernel body


hasPolymorphicKernel : TOpt.Expr Name -> Bool
hasPolymorphicKernel expr =
    case expr of
        TOpt.VarKernel _ _ _ _ meta ->
            not (CoreDict.isEmpty (typeVarsOfType meta.tipe CoreDict.empty))

        _ ->
            List.any hasPolymorphicKernel (children expr)


{-| Rename every type variable in a type with the copy's suffix, and drop the
arrow slots' solver-root identity.

**Why the rename.** `AssignMVarIds`'s per-definition environment is
`SchemeEnv = Dict Name TypeIds.MVarId`, "reset for each top-level definition" —
so INSIDE ONE top-level definition a type variable's identity is its NAME. Two
copies of a polymorphic body spliced into the same caller would both say
`TVar "a"`, `ensureMVarId` would hand both the same `MVarId`, and the two call
sites' instantiations would meet at that one variable. Measured before this
existed, on `test/elm/src/PreMonoInlineTest.elm`, whose
`twice : (a -> a) -> a -> a` is used at `Int` and at `List Int`:

    unify-fail ({..} -> List<?a> -> List<?a>) /vs/ ({..} -> Int -> Int)

Two instantiations that happened to unify would have collapsed onto one
SILENTLY. Monomorphization reads only `meta.tipe` and never `meta.tvar`
(`MonoSolver/Monomorphize.elm`), so this is a pure `Name` rewrite needing no
solver state and no fresh-variable supply — which is what makes the pre-mono
position workable at all.

**Why the arrow slots are cleared.** A `TypeIds.SolverRoot idx` makes
`AssignMVarIds` mint ONE `ArrowId` for every arrow sharing that root, through
`arrowRootEnv` — which is GLOBAL state, not per-definition. Two copies keep the
same roots, so their arrows and therefore their LSS members merge, even though
the copies now have DIFFERENT types; a member indexing copy A's body could then
be stamped at a call site in copy B, whose spec is a different instantiation.
`NoArrow` falls back to per-occurrence `freshArrowId`, the same path every
post-solve type already takes. This is type-neutral — `ArrowSlot` feeds
`ArrowId`/`rootKey` and never `MVarId` — and costs the LSS root identity that
`lss.arrowSolverRoots` buys, so it is measured rather than assumed
(`plans/pre-mono-inline-simplify.md` §12.3c).

The renamed names are ABSENT from the caller's `schemeRoots`, so
`ensureBinder` falls through to the plain per-name path automatically. That is
correct by construction and must stay that way: `ensureMVarIdForRoot`
deliberately gives two names backed by one solver root the SAME `MVarId`, which
is exactly the merge this rename exists to prevent.

-}
suffixType : Subst -> String -> Can.Type Name -> Can.Type Name
suffixType subst sfx tipe =
    case tipe of
        Can.TVar n ->
            case CoreDict.get n subst of
                -- Determined by the call site. Spliced in VERBATIM: it is the
                -- CALLER's type, already consistent with the caller's own
                -- variables and arrow slots, so it must not be renamed or
                -- walked.
                Just concrete ->
                    concrete

                Nothing ->
                    Can.TVar (n ++ sfx)

        Can.TLambda _ a b ->
            Can.TLambda TypeIds.NoArrow
                (suffixType subst sfx a)
                (suffixType subst sfx b)

        Can.TType home name args ->
            Can.TType home name (List.map (suffixType subst sfx) args)

        Can.TRecord fields ext ->
            Can.TRecord
                (CoreDict.map (\_ f -> suffixFieldType subst sfx f) fields)
                (Maybe.map (\n -> n ++ sfx) ext)

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b rest ->
            Can.TTuple (suffixType subst sfx a)
                (suffixType subst sfx b)
                (List.map (suffixType subst sfx) rest)

        Can.TAlias home name args real ->
            Can.TAlias home
                name
                (List.map (\( n, t ) -> ( n ++ sfx, suffixType subst sfx t )) args)
                (suffixAliasType subst sfx real)


suffixFieldType : Subst -> String -> Can.FieldType Name -> Can.FieldType Name
suffixFieldType subst sfx (Can.FieldType i t) =
    Can.FieldType i (suffixType subst sfx t)


suffixAliasType : Subst -> String -> Can.AliasType Name -> Can.AliasType Name
suffixAliasType subst sfx alias_ =
    case alias_ of
        Can.Holey t ->
            Can.Holey (suffixType subst sfx t)

        Can.Filled t ->
            Can.Filled (suffixType subst sfx t)


suffixMeta : Subst -> String -> TOpt.Meta Name -> TOpt.Meta Name
suffixMeta subst sfx meta =
    { meta | tipe = suffixType subst sfx meta.tipe }


{-| What the call site says each of the callee's type variables is.
-}
type alias Subst =
    CoreDict.Dict Name (Can.Type Name)


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
matchType : Can.Type Name -> Can.Type Name -> Subst -> Subst
matchType pattern actual subst =
    case ( pattern, actual ) of
        ( Can.TVar n, _ ) ->
            -- First binding wins; a second, different one would mean the call
            -- site is inconsistent, and the rename is the safe answer there.
            if CoreDict.member n subst then
                subst

            else
                CoreDict.insert n actual subst

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

        ( Can.TAlias _ _ _ preal, _ ) ->
            matchType (aliasBody preal) actual subst

        ( _, Can.TAlias _ _ _ areal ) ->
            matchType pattern (aliasBody areal) subst

        _ ->
            subst


matchList : List (Can.Type Name) -> List (Can.Type Name) -> Subst -> Subst
matchList patterns actuals subst =
    List.foldl (\( p, a ) acc -> matchType p a acc)
        subst
        (List.map2 Tuple.pair patterns actuals)


aliasBody : Can.AliasType Name -> Can.Type Name
aliasBody alias_ =
    case alias_ of
        Can.Holey t ->
            t

        Can.Filled t ->
            t


{-| Every type-variable name reachable from a candidate's parameter types and
body. Used for two things: the `polymorphic` census, and carrying the SUPERTYPE
constraints across the rename.

`ensureMVarId` reads a variable's constraint from `varSupers`, the
`GlobalGraph`'s fifth field, keyed by NAME — so `number42` renamed to
`number42_pi3` would lose its `number` constraint and default differently.
`optimize` extends that dict for every renamed name that had an entry, which is
the only reason this pass touches the graph's non-node fields.

-}
candidateTypeVars : List ( Name, Can.Type Name ) -> TOpt.Expr Name -> List Name
candidateTypeVars params body =
    CoreDict.keys
        (List.foldl typeVarsOfType
            (typeVarsOfExpr body CoreDict.empty)
            (List.map Tuple.second params)
        )


typeVarsOfExpr : TOpt.Expr Name -> CoreDict.Dict Name () -> CoreDict.Dict Name ()
typeVarsOfExpr expr acc =
    List.foldl typeVarsOfExpr
        (typeVarsOfType (TOpt.typeOf expr) acc)
        (children expr)


typeVarsOfType : Can.Type Name -> CoreDict.Dict Name () -> CoreDict.Dict Name ()
typeVarsOfType tipe acc =
    case tipe of
        Can.TVar n ->
            CoreDict.insert n () acc

        Can.TLambda _ a b ->
            typeVarsOfType b (typeVarsOfType a acc)

        Can.TType _ _ args ->
            List.foldl typeVarsOfType acc args

        Can.TRecord fields ext ->
            CoreDict.foldl
                (\_ (Can.FieldType _ t) a -> typeVarsOfType t a)
                (case ext of
                    Just n ->
                        CoreDict.insert n () acc

                    Nothing ->
                        acc
                )
                fields

        Can.TUnit ->
            acc

        Can.TTuple a b rest ->
            List.foldl typeVarsOfType (typeVarsOfType b (typeVarsOfType a acc)) rest

        Can.TAlias _ _ args real ->
            let
                withArgs =
                    List.foldl
                        (\( n, t ) a -> typeVarsOfType t (CoreDict.insert n () a))
                        acc
                        args
            in
            case real of
                Can.Holey t ->
                    typeVarsOfType t withArgs

                Can.Filled t ->
                    typeVarsOfType t withArgs


{-| Immediate sub-expressions, for the ground-type walk. Includes the decider's
`Inline` choices — an unshared `case` branch body lives there.
-}
children : TOpt.Expr Name -> List (TOpt.Expr Name)
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


defChildren : TOpt.Def Name -> List (TOpt.Expr Name)
defChildren def =
    case def of
        TOpt.Def _ _ bound _ ->
            [ bound ]

        TOpt.TailDef _ _ _ body _ _ ->
            [ body ]


deciderChildren : TOpt.Decider (TOpt.Choice Name) -> List (TOpt.Expr Name)
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
bodyOf : TOpt.Node Name -> Maybe ( List ( Name, Can.Type Name ), TOpt.Expr Name )
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
recursiveGlobals : Dict String TOpt.Global (TOpt.Node Name) -> CoreDict.Dict String ()
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
namesSelf : TOpt.Global -> TOpt.Expr Name -> Bool
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
cost : TOpt.Expr Name -> Int
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
costDecider : TOpt.Decider (TOpt.Choice Name) -> Int
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


costDef : TOpt.Def Name -> Int
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


rewriteGraph : Ctx -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Ctx )
rewriteGraph ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( nodes1, ctx1 ) =
            Dict.foldl TOpt.compareGlobal
                (\g node ( acc, c ) ->
                    let
                        ( node1, c1 ) =
                            rewriteNode c node
                    in
                    ( Dict.insert TOpt.toComparableGlobal g node1 acc, c1 )
                )
                ( Dict.empty, ctx )
                nodes
    in
    ( TOpt.GlobalGraph nodes1 fields annotations schemeRoots varSupers, ctx1 )


rewriteNode : Ctx -> TOpt.Node Name -> ( TOpt.Node Name, Ctx )
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


rewriteExpr : Ctx -> TOpt.Expr Name -> ( TOpt.Expr Name, Ctx )
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
    -> Dict String (A.Located Name) (TOpt.Expr Name)
    -> ( Dict String (A.Located Name) (TOpt.Expr Name), Ctx )
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
rewriteDecider : Ctx -> TOpt.Decider (TOpt.Choice Name) -> ( TOpt.Decider (TOpt.Choice Name), Ctx )
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


mapBody : Ctx -> TOpt.Expr Name -> (TOpt.Expr Name -> TOpt.Expr Name) -> ( TOpt.Expr Name, Ctx )
mapBody ctx body rebuild =
    let
        ( body1, c1 ) =
            rewriteExpr ctx body
    in
    ( rebuild body1, c1 )


rewriteList : Ctx -> List (TOpt.Expr Name) -> ( List (TOpt.Expr Name), Ctx )
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


rewriteDef : Ctx -> TOpt.Def Name -> ( TOpt.Def Name, Ctx )
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
tryInline : Ctx -> A.Region -> TOpt.Expr Name -> List (TOpt.Expr Name) -> TOpt.Meta Name -> ( Maybe (TOpt.Expr Name), Ctx )
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
                                    (\m -> { m | undetermined = m.undetermined + 1 })
                                        ctx.metrics
                              }
                            )

                Nothing ->
                    ( Nothing, ctx )

        _ ->
            ( Nothing, ctx )


{-| What the call site says each of the callee's type variables is: parameters
against the actual arguments, plus the callee's result type against the call's
own type.
-}
callSiteSubst : Candidate -> List (TOpt.Expr Name) -> TOpt.Meta Name -> Subst
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


isGroundType : Can.Type Name -> Bool
isGroundType tipe =
    CoreDict.isEmpty (typeVarsOfType tipe CoreDict.empty)


doInline : Ctx -> A.Region -> Candidate -> List (TOpt.Expr Name) -> Subst -> ( TOpt.Expr Name, Ctx )
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


{-| Freshen every binder in a candidate body before splicing it into the
caller, returning the renamed body and the renamed parameter list.

**Method: one uniform suffix per inlined copy.** Every LOCAL name in the body —
binder or use, `Let`/`TailDef`/`Destruct` binder, `Function`/`TrackedFunction`
parameter, `Case` label and root, `TailCall` label, `Path` root — gets the same
`_pi<n>` suffix, where `n` is unique to this inline. Globals
(`VarGlobal`/`VarCycle`/`VarKernel`) are untouched.

A uniform suffix is INJECTIVE on names, so it preserves shadowing exactly: a
body's inner `\x -> x` under an outer `let x` still shadows after renaming,
because both `x`s become the same `x_pi7` at the same two nesting depths. That
is why no scope tracking and no rename environment are needed here — and why
this does NOT reuse `NormalizeLambdaBoundaries.renameExpr`, which renames
`Def`/`Destructor`/`Case` binders and variable USES but leaves
`Function`/`TrackedFunction` parameters and `TailDef` names and arguments
alone. Those gaps are silent: uses get renamed while the binder does not, which
is an unbound local, not a type error.

A candidate is a top-level `Define`/`TrackedDefine` body, so its only free
locals are its own parameters — which are renamed here too. Nothing in the
caller can therefore be captured.

The mono pass's destructure-binder capture bug (`MonoDestruct` binders passed
through verbatim while `MonoDef` binders were renamed) cannot recur here: the
walk below has no per-binder-kind opt-out.

-}
freshenBody : Ctx -> Subst -> Candidate -> ( TOpt.Expr Name, List ( Name, Can.Type Name ), Ctx )
freshenBody ctx subst cand =
    let
        suffix =
            "_pi" ++ String.fromInt ctx.fresh

        renamedParams =
            List.map
                (\( n, t ) -> ( n ++ suffix, suffixType subst suffix t ))
                cand.params
    in
    ( suffixExpr subst suffix cand.body
    , renamedParams
    , { ctx
        | fresh = ctx.fresh + 1
        , renamedTypeVars =
            List.foldl
                (\v acc ->
                    if CoreDict.member v subst then
                        -- Determined by the call site, so it is gone from the
                        -- copy entirely and needs no constraint carried over.
                        acc

                    else
                        ( v, v ++ suffix ) :: acc
                )
                ctx.renamedTypeVars
                cand.typeVars
      }
    )


{-| Apply the copy suffix to every local name in an expression. See
`freshenBody` for why a blanket rename is the right thing here.
-}
suffixExpr : Subst -> String -> TOpt.Expr Name -> TOpt.Expr Name
suffixExpr subst sfx expr =
    let
        go =
            suffixExpr subst sfx

        nm n =
            n ++ sfx

        mt =
            suffixMeta subst sfx

        ty =
            suffixType subst sfx

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
            TOpt.Bool region b (mt meta)

        TOpt.Chr region c meta ->
            TOpt.Chr region c (mt meta)

        TOpt.Str region v meta ->
            TOpt.Str region v (mt meta)

        TOpt.Int region i meta ->
            TOpt.Int region i (mt meta)

        TOpt.Float region f meta ->
            TOpt.Float region f (mt meta)

        TOpt.VarLocal n meta ->
            TOpt.VarLocal (nm n) (mt meta)

        TOpt.TrackedVarLocal region n meta ->
            TOpt.TrackedVarLocal region (nm n) (mt meta)

        TOpt.VarGlobal region g meta ->
            TOpt.VarGlobal region g (mt meta)

        TOpt.VarEnum region g idx meta ->
            TOpt.VarEnum region g idx (mt meta)

        TOpt.VarBox region g meta ->
            TOpt.VarBox region g (mt meta)

        TOpt.VarCycle region home n meta ->
            TOpt.VarCycle region home n (mt meta)

        TOpt.VarDebug region n home unqualified meta ->
            TOpt.VarDebug region n home unqualified (mt meta)

        TOpt.VarKernel region prefix home n meta ->
            TOpt.VarKernel region prefix home n (mt meta)

        TOpt.List region items meta ->
            TOpt.List region (List.map go items) (mt meta)

        TOpt.Function srcLam params body meta ->
            TOpt.Function srcLam
                (List.map (\( n, t ) -> ( nm n, ty t )) params)
                (go body)
                (mt meta)

        TOpt.TrackedFunction srcLam params body meta ->
            TOpt.TrackedFunction srcLam
                (List.map (\( ln, t ) -> ( loc ln, ty t )) params)
                (go body)
                (mt meta)

        TOpt.Call region f args meta ->
            TOpt.Call region (go f) (List.map go args) (mt meta)

        TOpt.TailCall n args meta ->
            TOpt.TailCall (nm n)
                (List.map (\( an, e ) -> ( nm an, go e )) args)
                (mt meta)

        TOpt.If branches final meta ->
            TOpt.If (List.map (\( c, t ) -> ( go c, go t )) branches)
                (go final)
                (mt meta)

        TOpt.Let def body meta ->
            TOpt.Let (suffixDef subst sfx def) (go body) (mt meta)

        TOpt.Destruct (TOpt.Destructor n path dmeta) body meta ->
            TOpt.Destruct
                (TOpt.Destructor (nm n) (suffixPath sfx path) (mt dmeta))
                (go body)
                (mt meta)

        TOpt.Case label root decider jumps meta ->
            TOpt.Case (nm label)
                (nm root)
                (suffixDecider subst sfx decider)
                (List.map (\( i, e ) -> ( i, go e )) jumps)
                (mt meta)

        TOpt.Accessor region field meta ->
            TOpt.Accessor region field (mt meta)

        TOpt.Access inner region field meta ->
            TOpt.Access (go inner) region field (mt meta)

        TOpt.Update region record fields meta ->
            TOpt.Update region (go record) (Dict.map (\_ e -> go e) fields) (mt meta)

        TOpt.Record fields meta ->
            TOpt.Record (CoreDict.map (\_ e -> go e) fields) (mt meta)

        TOpt.TrackedRecord region fields meta ->
            TOpt.TrackedRecord region (Dict.map (\_ e -> go e) fields) (mt meta)

        TOpt.Unit meta ->
            TOpt.Unit (mt meta)

        TOpt.Tuple region a b rest meta ->
            TOpt.Tuple region (go a) (go b) (List.map go rest) (mt meta)

        TOpt.Shader src inputs outputs meta ->
            TOpt.Shader src inputs outputs (mt meta)


suffixDef : Subst -> String -> TOpt.Def Name -> TOpt.Def Name
suffixDef subst sfx def =
    case def of
        TOpt.Def region n bound tipe ->
            TOpt.Def region
                (n ++ sfx)
                (suffixExpr subst sfx bound)
                (suffixType subst sfx tipe)

        TOpt.TailDef region n args body tipe tvar ->
            TOpt.TailDef region
                (n ++ sfx)
                (List.map
                    (\( ln, t ) ->
                        ( A.At (A.toRegion ln) (A.toValue ln ++ sfx)
                        , suffixType subst sfx t
                        )
                    )
                    args
                )
                (suffixExpr subst sfx body)
                (suffixType subst sfx tipe)
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


suffixDecider : Subst -> String -> TOpt.Decider (TOpt.Choice Name) -> TOpt.Decider (TOpt.Choice Name)
suffixDecider subst sfx decider =
    case decider of
        TOpt.Leaf choice ->
            TOpt.Leaf
                (case choice of
                    TOpt.Inline e ->
                        TOpt.Inline (suffixExpr subst sfx e)

                    TOpt.Jump i ->
                        TOpt.Jump i
                )

        TOpt.Chain tests ok ko ->
            TOpt.Chain tests
                (suffixDecider subst sfx ok)
                (suffixDecider subst sfx ko)

        TOpt.FanOut path branches fallback ->
            TOpt.FanOut path
                (List.map (\( t, d ) -> ( t, suffixDecider subst sfx d )) branches)
                (suffixDecider subst sfx fallback)


locatedName : A.Located Name -> Name
locatedName =
    A.toValue
