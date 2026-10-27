module Compiler.GlobalOpt.InlineSimplify exposing
    ( Metrics, emptyMetrics
    , optimize
    )

{-| Inlining a small function once, before monomorphization, saves doing it
once per specialization afterwards. This module is that pre-monomorphization
inliner.

The program at this point is the typed-optimized graph (`TOpt`), in which a
polymorphic function still has one body. After monomorphization the same
function is copied once per type it is used at, and an inliner working there
inlines each copy separately. Here a call `f a b` to a small global `f` is
replaced by a copy of `f`'s body, once, wherever it occurs.

A global that may be inlined is a _candidate_. It is a `Define` or
`TrackedDefine` whose value is a function of at least one parameter, that is
not recursive, whose `cost` is at most the configured threshold, and that
passes every guard in `buildCandidates`. Each guard refuses a function that
cannot safely be copied before monomorphization: a polymorphic kernel
reference, an open record type, a function-typed parameter, or a type variable
with a supertype constraint. Only a call with exactly as many arguments as the
candidate has parameters is inlined.

The input already carries the identities `AssignMVarIds` gives it: an `MVarId`
for every type variable, a lambda id for every function and an arrow id for
every function type. A copy that kept them would share them with the original,
so every copy is made with `PreMono.Fresh.freshenCopy`, as that module
describes. The facts this pass adds are about the types the copy is given.

A copy's type variables must end up ground, meaning free of type variables,
because nothing solves them once the call that carried them is gone. So a call
is inlined only if it _determines_ the candidate: matching the candidate's
parameter types against the argument types, and its body type against the
call's type, binds every type variable of the candidate to a ground type
(`determines`). Those bindings are substituted into the copy. A call that does
not determine its candidate is left as it is, while other calls to the same
candidate may still be inlined.

The copy is spliced in as `let p1_piN = arg1 in ... body`, where every local
name of the body, binders and uses alike, gets the suffix `_piN` with `N`
unique to the copy. Binding the arguments, rather than substituting them into
the body, evaluates each argument once in the caller's scope, where no binder
of the body can capture its free variables. The suffix keeps two copies in one
caller from binding the same name twice, and because it is applied uniformly
it preserves shadowing within the body.

Rewriting runs in rounds over every node, up to the configured number of
rounds and stopping after a round that inlines nothing. The bodies copied are
always the candidates' original bodies, so a call inside a copy is not
considered until the next round, if one remains. Much of the file is census
code, the `Metrics` counters, most of which are filled only when inline
reporting is on.

@docs Metrics, emptyMetrics
@docs optimize

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.PreMono.Fresh as Fresh
import Compiler.Graph as Graph
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet
import Dict as CoreDict


{-| Counts of what one run of the pass did and why it declined the rest.

The candidate counts are taken once, when the candidate index is built:
`candidates` is the number admitted, `bodiesSeen` the number of globals whose
`Define` or `TrackedDefine` value is a function, and `recursiveSkipped`,
`overBudget`, `polyKernel`, `rowPoly`, `hofParam` and `superVar` the number
refused by each guard, the first guard that fires being the one counted.
`polymorphic` counts admitted candidates that have any type variable. The call
counts, `inlineCount`, `inlinedByCallee` and `undetermined`, accumulate over
every round, so a call that stays undetermined is counted again in each round
that visits it.

The remaining fields are filled only when inline reporting is on and are zero
or empty otherwise, except `undetermined`, the guard counts and
`inlinedByCallee`, which are always kept. An undetermined call is classed by
the candidate type variables it leaves unbound or non-ground: `undLocal` when
the call site's types for one of them mention a variable that is not in the
caller's own annotation, else `undBodyOnly` when the call site's types offer no
variable at all for one of them, as for a variable that occurs in no parameter
type and not in the result type, else `undCallerPoly`, when every variable
offered is one of the caller's annotation variables. `undLeak` counts
undetermined calls to a candidate whose annotation, if it has one, quantifies
no type variables, although its body's types do.

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
    , undCallerPoly : Int
    , undLocal : Int
    , undBodyOnly : Int
    , undLeak : Int
    , undeterminedByCallee : CoreDict.Dict String Int
    , undCallerPolyByCallee : CoreDict.Dict String Int
    , overBudgetBuckets : ( Int, Int, ( Int, Int ) ) -- over-budget candidates by cost: up to 15, 16-25, 26-50, over 50
    , overBudgetCosts : List ( String, Int )
    , hofArgLambda : Int -- function-typed arguments, at calls to a hofParam-refused global, that are lambdas
    , hofArgGlobal : Int
    , hofArgOther : Int
    , hofNames : List String
    , polyKernelNames : List String
    , superVarNames : List String
    , undLocalByCallee : CoreDict.Dict String Int
    , undBodyOnlyByCallee : CoreDict.Dict String Int
    }


{-| Metrics with every count zero and every collection empty, for a caller
that does not run the pass.
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


{-| The state threaded through the rewrite of the whole graph.

`state` is the id supply every copy's new identities are minted from.
`callerBinders` holds the type variables of the annotation of the node being
rewritten, and is kept only while `censusOn`.

-}
type alias Ctx =
    { candidates : CoreDict.Dict String Candidate
    , metrics : Metrics
    , fresh : Int -- the N of the next copy's `_piN` suffix
    , fuel : Int -- rounds left
    , state : AssignMVarIds.GlobalMVarState
    , censusOn : Bool
    , callerBinders : CoreDict.Dict Int ()
    , hofDeclined : CoreDict.Dict String (List Bool) -- per parameter of a hofParam-refused global, whether it is function-typed
    }


{-| A global admitted for inlining: its parameters and body as they will be
copied, and what the call-site check needs to know about its types.

`typeVars` are the type variables of `params` and `body`, as `candidateTypeVars`
gives them; a call must determine all of them. `annBinders` is the number of
variables the global's annotation quantifies over, zero when it has no
annotation; zero alongside a non-empty
`typeVars` means the global has no annotation or the body's types mention
variables its annotation does not.

-}
type alias Candidate =
    { params : List ( Name, Can.Type TypeIds.MVarId )
    , body : TOpt.Expr TypeIds.MVarId
    , name : String
    , typeVars : List Int
    , annBinders : Int
    }



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| Returns `graph` with calls to candidates inlined, the id state advanced
past every id minted for the copies, and the metrics of the run.

The configuration supplies the cost threshold, the maximum number of rounds
(at least one is always run) and whether the census is on. Whether the pass
runs at all is decided by the caller; this function does not read that flag.

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
            , fuel = max 1 cfg.preMonoFixpointIterations
            , state = state
            , censusOn = cfg.report
            , callerBinders = CoreDict.empty
            , hofDeclined = cands.hofDeclined
            }
    in
    rounds ctx0 graph


{-| Runs rewrite rounds over the graph until the fuel runs out or a round
inlines nothing, and returns the final graph, id state and metrics.
-}
rounds : Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
rounds ctx graph =
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
            ( graph1, ctx1.state, ctx1.metrics )

        else
            rounds { ctx1 | fuel = ctx1.fuel - 1 } graph1



-- ============================================================================
-- ====== CANDIDATE INDEX ======
-- ============================================================================


{-| Builds the candidate index, keyed by `TOpt.toComparableGlobal`, together
with the candidate counts of `Metrics`.

Every `Define` or `TrackedDefine` whose value is a function is considered, and
the guards are tried in this order, the first that applies refusing it:
recursive (`recursiveGlobals`), no parameters (refused without being counted),
`cost` above the threshold, `polyKernel`, `hasOpenRecord`, a function-typed
parameter, and a type variable that has a supertype constraint in the state's
`superVars`. The per-guard name lists, the over-budget buckets and costs and
`hofDeclined` are filled only when the census is on.

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

                        else if cost body > cfg.preMonoThreshold then
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
    Dict.foldl
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


{-| Returns whether a type is a function type, looking through aliases.

A candidate with a function-typed parameter is refused. Before
monomorphization the set of functions that can reach such a parameter, and how
they will be called, is not yet settled.

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


{-| Returns whether a parameter type, or the type of any expression in the
body, contains an open record type `{ r | field : t }`.

Such a candidate is refused. The layout of an open record is that of the record
actually supplied, and `matchType` cannot bind the row variable `r`, so a copy
would keep a record type whose layout is not known.

-}
hasOpenRecord : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Bool
hasOpenRecord params body =
    List.any (\( _, t ) -> openRecordInType t) (List.map identity params)
        || openRecordInExpr body


{-| Returns whether the type of `expr` or of any expression below it contains
an open record type.
-}
openRecordInExpr : TOpt.Expr TypeIds.MVarId -> Bool
openRecordInExpr expr =
    openRecordInType (TOpt.typeOf expr)
        || List.any openRecordInExpr (children expr)


{-| Returns whether a type contains a record type with an extension variable,
looking inside arrows, type arguments, tuples, alias arguments and alias
bodies.
-}
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


{-| Returns whether a candidate has any type variable and its body references
a kernel whose type mentions a type variable.

Such a candidate is refused. A kernel symbol has one signature, whatever type
it is used at, so a copy that substituted the call site's types into the
kernel reference would ask for the same kernel at a different type. A
polymorphic candidate whose kernel references all have ground types is not
refused by this guard.

-}
polyKernel : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Bool
polyKernel params body =
    not (List.isEmpty (candidateTypeVars params body))
        && hasPolymorphicKernel body


{-| Returns whether `expr` contains a kernel reference whose type mentions a
type variable.
-}
hasPolymorphicKernel : TOpt.Expr TypeIds.MVarId -> Bool
hasPolymorphicKernel expr =
    case expr of
        TOpt.VarKernel _ _ _ _ meta ->
            not (CoreDict.isEmpty (typeVarsOfType meta.tipe CoreDict.empty))

        _ ->
            List.any hasPolymorphicKernel (children expr)


{-| A binding of a candidate's type variables to the types a call site gives
them, as `PreMono.Fresh.Subst` describes.
-}
type alias Subst =
    Fresh.Subst


{-| Returns `subst` extended with the bindings that matching the candidate's
type `pattern` against the call site's type `actual` gives its type variables.

The match is one way and permissive. A variable already bound keeps its first
binding, even if a later position gives it a different type. Where the two
types have different shapes, or name different types, nothing is bound there
and no failure is reported. Aliases are expanded when the two sides are not
the same alias. Record fields are matched by name, and a record's extension
variable is never bound. A call whose bindings leave a variable unbound or
non-ground is refused by `determines`; a conflicting binding is not detected.

-}
matchType : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Subst -> Subst
matchType pattern actual subst =
    case ( pattern, actual ) of
        ( Can.TVar n, _ ) ->
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


{-| Returns `subst` extended by matching each pattern against the actual type in
the same position, ignoring the extra elements of the longer list.
-}
matchList : List (Can.Type TypeIds.MVarId) -> List (Can.Type TypeIds.MVarId) -> Subst -> Subst
matchList patterns actuals subst =
    List.foldl (\( p, a ) acc -> matchType p a acc)
        subst
        (List.map2 Tuple.pair patterns actuals)


{-| Returns the type an alias's body stores, `Holey` or `Filled`, without
substituting its parameters.
-}
aliasBody : Can.AliasType TypeIds.MVarId -> Can.Type TypeIds.MVarId
aliasBody alias_ =
    case alias_ of
        Can.Holey t ->
            t

        Can.Filled t ->
            t


{-| Returns the type an alias stands for: a `Holey` body with each parameter
replaced by its argument, or a `Filled` body as it is. Any other type is
returned unchanged.

`matchType` matches against this expansion, never against a `Holey` body,
whose parameters would otherwise be bound as if they were the candidate's own
type variables.

-}
expandAlias : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
expandAlias tipe =
    case tipe of
        Can.TAlias _ _ args (Can.Holey body) ->
            -- Parameter ids are minted by name, so one can equal a same-named
            -- variable of the enclosing definition; only the alias's own pairs
            -- are substituted.
            substTypeVars
                (CoreDict.fromList (List.map (\( pn, t ) -> ( Id.toComparable pn, t )) args))
                body

        Can.TAlias _ _ _ (Can.Filled body) ->
            body

        _ ->
            tipe


{-| Returns `tipe` with each type variable found in `env` replaced by its entry.
A record's extension variable and an alias's stored body are left as they are;
an alias's arguments are substituted.
-}
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


{-| Returns every type variable in a candidate's parameter types and in the
type of every expression of its body, as `Id.toComparable` keys, without
duplicates.

The types of reference nodes, kernel references included, are part of the
result. `polyKernel` depends on that: its first condition is that this list is
non-empty, and a candidate whose only type variables are in a kernel
reference's type would otherwise escape it. The same list is what `determines`
requires to be ground and what the `superVar` guard checks.

-}
candidateTypeVars : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> List Int
candidateTypeVars params body =
    CoreDict.keys
        (List.foldl typeVarsOfType
            (typeVarsOfExpr body CoreDict.empty)
            (List.map Tuple.second params)
        )


{-| Returns `acc` with the type variables of the type of `expr` and of every
expression below it added. Types written elsewhere, such as a `let`
definition's declared type, are not visited.
-}
typeVarsOfExpr : TOpt.Expr TypeIds.MVarId -> CoreDict.Dict Int () -> CoreDict.Dict Int ()
typeVarsOfExpr expr acc =
    List.foldl typeVarsOfExpr
        (typeVarsOfType (TOpt.typeOf expr) acc)
        (children expr)


{-| Returns `acc` with the type variables of a type added, a record's extension
variable included. An alias contributes the variables of its arguments only.
-}
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
            -- Alias parameters are local to the alias, not free variables; the
            -- variables of the type it stands for are those of its arguments.
            List.foldl (\( _, t ) a -> typeVarsOfType t a) acc args


{-| Returns the immediate sub-expressions of an expression, including the
branch bodies held in a `case` decider's `Inline` leaves.
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
            record :: Dict.values fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            Dict.values fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


{-| Returns the expression a `let` definition binds, or a tail definition's
body.
-}
defChildren : TOpt.Def TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
defChildren def =
    case def of
        TOpt.Def _ _ bound _ ->
            [ bound ]

        TOpt.TailDef _ _ _ body _ _ ->
            [ body ]


{-| Returns the expressions in a decider's `Inline` leaves.
-}
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


{-| Returns the parameters and body of a `Define` or `TrackedDefine` node whose
value is a `Function` or `TrackedFunction`, and `Nothing` for any other node.
The parameter list may be empty.

A `TrackedFunction`'s parameter names lose their regions, because the copy
binds them with ordinary `let` definitions, which take a bare name.

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


{-| Returns the globals that are recursive, as `TOpt.toComparableGlobal` keys.

A global is recursive if any of three tests says so, because no one of them
is relied on to be complete. It is in a cyclic strongly connected component of
the graph whose edges are the nodes' dependency sets, which finds mutual
recursion. It is a `Cycle` node. Or the body `bodyOf` gives for it names the
global itself (`namesSelf`), which does not depend on the dependency set
listing the node itself.

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
            Dict.foldl
                (\g node acc ->
                    ( TOpt.toComparableGlobal g
                    , TOpt.toComparableGlobal g
                    , List.map TOpt.toComparableGlobal
                        (EverySet.toList (depsOf node))
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
            Dict.foldl
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


{-| Returns whether an expression refers to the given global anywhere, as a
global, a cycle member, an enum constructor or a box constructor.
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


{-| Returns the name under which a global is reported in the metrics.
-}
qualifiedName : TOpt.Global -> String
qualifiedName g =
    TOpt.toComparableGlobal g



-- ============================================================================
-- ====== COST ======
-- ============================================================================


{-| Returns the size of an expression as the inliner prices it, which is what
is compared with the cost threshold.

A literal, a variable reference of any kind (a kernel reference included), a
unit, an accessor or a shader costs 1. A compound expression costs a fixed
amount for itself, from 1 for a field access to 5 for a function or a call,
plus the cost of its parts.

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
            3 + cost inner + Dict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.Record fields _ ->
            3 + CoreDict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.TrackedRecord _ fields _ ->
            3 + Dict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.Tuple _ a b rest _ ->
            3 + cost a + cost b + sumBy cost rest

        TOpt.Shader _ _ _ _ ->
            1


{-| Returns the cost of a decision tree, including the branch bodies in its
`Inline` leaves. A branch body held in the tree rather than in the `case`'s
list of `Jump` targets is priced only here.
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


{-| Returns the cost of the expression a `let` definition binds, or of a tail
definition's body.
-}
costDef : TOpt.Def TypeIds.MVarId -> Int
costDef def =
    case def of
        TOpt.Def _ _ bound _ ->
            cost bound

        TOpt.TailDef _ _ _ body _ _ ->
            cost body


{-| Returns the sum of `f` over a list.
-}
sumBy : (a -> Int) -> List a -> Int
sumBy f =
    List.foldl (\x acc -> acc + f x) 0



-- ============================================================================
-- ====== REWRITE ======
-- ============================================================================


{-| Runs one round: rewrites every node of the graph, and returns the new graph
with its other parts unchanged, together with the context after the round.
-}
rewriteGraph : Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, Ctx )
rewriteGraph ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( nodes1, ctx1 ) =
            Dict.foldl
                (\g node ( acc, c ) ->
                    let
                        cIn =
                            if c.censusOn then
                                { c
                                    | callerBinders =
                                        -- Read from the annotation's type: its FreeVars are keyed by name, not id.
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


{-| Returns a node with every call in its expression rewritten. Only `Define`,
`TrackedDefine` and port nodes have an expression rewritten; every other node,
a `Cycle` included, is returned unchanged.
-}
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
            ( node, ctx )


{-| Returns an expression with every call to a candidate inlined where the call
has as many arguments as the candidate has parameters and determines it.

The function and arguments of a call are rewritten before the call itself is
tried, and the copy that replaces a call is not rewritten again in the same
round.

-}
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
            ( expr, ctx )


{-| Returns a record's or record update's field expressions, each rewritten.
-}
rewriteLocatedFields :
    Ctx
    -> Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId)
    -> ( Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteLocatedFields ctx fields =
    Dict.foldl
        (\k e ( acc, c ) ->
            let
                ( e1, c2 ) =
                    rewriteExpr c e
            in
            ( Dict.insert A.toValue k e1 acc, c2 )
        )
        ( Dict.empty, ctx )
        fields


{-| Returns a decision tree with the branch bodies in its `Inline` leaves
rewritten. Its tests and paths are unchanged.
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


{-| Rewrites `body` and returns `rebuild` applied to the result.
-}
mapBody : Ctx -> TOpt.Expr TypeIds.MVarId -> (TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId) -> ( TOpt.Expr TypeIds.MVarId, Ctx )
mapBody ctx body rebuild =
    let
        ( body1, c1 ) =
            rewriteExpr ctx body
    in
    ( rebuild body1, c1 )


{-| Returns a list of expressions, each rewritten, in their original order.
-}
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


{-| Returns a `let` definition with its bound expression, or a tail definition's
body, rewritten.
-}
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


{-| Returns the copy that replaces a call, or `Nothing` if the call is not
inlined, together with the updated context.

A call is inlined when its function is a direct reference to a candidate, it
has exactly as many arguments as the candidate has parameters, and it
determines the candidate. A call that fails only the last test is counted as
undetermined; a call to a global refused for a function-typed parameter is
counted in the argument-shape census when the census is on.

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
                            ( Nothing
                            , { ctx
                                | metrics =
                                    censusUndetermined ctx
                                        cand
                                        args
                                        callMeta
                                        subst
                                        (\m -> { m | undetermined = m.undetermined + 1 })
                                        ctx.metrics
                              }
                            )

                Nothing ->
                    ( Nothing, censusHofArgs ctx g args )

        _ ->
            ( Nothing, ctx )


{-| Returns the metrics after one undetermined call: `bump` applied to `m0`,
and, when the census is on, the call classed as the `Metrics` docstring
describes and counted under the candidate's name.
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

            -- The variables the call site's types offer for callee variable `v`.
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


{-| Returns the context with the census of argument shapes updated for a call
to `g`: when the census is on and `g` was refused for a function-typed
parameter, each argument in such a position is counted as a lambda, a global
reference or anything else.
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


{-| Returns what a call site says each of a candidate's type variables is, by
matching each parameter type against its argument's type and then the body's
type against the call's own type.
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


{-| Returns whether `subst` binds every type variable of the candidate to a
ground type.

This is checked per call, not per candidate. Before monomorphization the type
of an argument or of the call is often still a variable that only
monomorphization resolves, and a copy made at such a call would keep
variable-typed nodes with nothing left to resolve them, so the call is left in
place. Another call to the same candidate, with ground types, can still be
inlined.

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


{-| Returns whether a type contains no type variable, by the variables
`typeVarsOfType` collects.
-}
isGroundType : Can.Type TypeIds.MVarId -> Bool
isGroundType tipe =
    CoreDict.isEmpty (typeVarsOfType tipe CoreDict.empty)


{-| Returns the copy that replaces a call: the candidate's freshened body
wrapped in one `let` per parameter, binding the suffixed parameter to its
argument, the first parameter outermost. The inline counts are updated.
-}
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


{-| Returns a candidate's body and parameters as one copy needs them, and the
context with the copy counter and the id state advanced.

The types are freshened by `PreMono.Fresh`: `freshenCopy` for the body and
`freshenType` for each parameter type, with `subst` giving the call site's
types. Because `determines` has accepted the call, every type variable in
`typeVars` is substituted.

Every local name, in the body and in the parameters, gets the suffix `_piN`,
where `N` is this copy's number. Global names are untouched. Because the same
suffix is added to every local name, two names are equal after the rename
exactly when they were before, so shadowing within the body is unchanged.

-}
freshenBody : Ctx -> Subst -> Candidate -> ( TOpt.Expr TypeIds.MVarId, List ( Name, Can.Type TypeIds.MVarId ), Ctx )
freshenBody ctx subst cand =
    let
        suffix =
            "_pi" ++ String.fromInt ctx.fresh

        ( freshBody, state1 ) =
            Fresh.freshenCopy subst ctx.state cand.body

        -- The parameter types become the declared types of the `let`s, so they get fresh arrow ids too.
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


{-| Returns an expression with `sfx` appended to every local name: variable
uses, function parameters, `let`, tail-definition and destructuring binders,
`case` labels and roots, tail-call labels and argument names, and the roots of
destructuring paths. Global names, types and decision-tree tests are left
unchanged.
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


{-| Returns a `let` or tail definition with `sfx` appended to its name, its
parameter names and every local name in its expression.
-}
suffixDef : String -> TOpt.Def TypeIds.MVarId -> TOpt.Def TypeIds.MVarId
suffixDef sfx def =
    case def of
        TOpt.Def region n bound tipe ->
            TOpt.Def region
                (n ++ sfx)
                (suffixExpr sfx bound)
                tipe

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
                tipe
                tvar


{-| Returns a destructuring path with `sfx` appended to the name at its root.
-}
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


{-| Returns a decision tree with `sfx` applied to the expressions in its
`Inline` leaves.
-}
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
