module Compiler.GlobalOpt.PreMono.LiftClosedArgs exposing
    ( Metrics
    , census
    )

{-| Counts the lambdas that a not-yet-built transform, lifting closed lambda
arguments to top-level globals, would rewrite, so that whether to build it can be
decided on numbers. Nothing here changes the graph: `census` only reports.

**The transform being measured.** A lambda literal passed as an argument to a
global or a kernel would become a top-level `Define` under a fresh global name,
and the argument would become a reference to that global. The point of doing
so is that the lambda-set analysis in `Compiler.MonoSolver.Translate` records a
global passed as an argument under the global's own name. Lifting is only
straightforward for a _closed_ lambda, one with no free local names: a
capturing lambda would need its captures turned into parameters, which changes
what the callee is passed, so capturing lambdas are counted but never
considered liftable.

**What is counted.** A _candidate_ is a `Function` or `TrackedFunction` literal
appearing directly as an argument of a call whose callee is a `VarGlobal` or a
`VarKernel`. Candidates split into `capturing` and `closed`. A closed candidate
is declined first by where it sits: inside a `TailDef` body, even one within a
`Cycle` node; otherwise in a `Cycle` node; otherwise in a port. A closed
candidate in none of these is declined when its body names a `VarCycle`, and
then when the callee is _loopifiable_. Whatever is left is `liftable`.
`Metrics` states the arithmetic.

**Loopifiable callees.** After monomorphization, `MonoInlineSimplify` turns
calls to some recursive higher-order functions into local loops, and a lifted
global argument would stop that happening. Before monomorphization the same
callees can only be approximated: a global counts as loopifiable when it is
recursive and declares a function-typed parameter. Recursion is judged by
membership of a cyclic strongly connected component of the dependency graph,
membership of a `Cycle` node, a reference to itself in its body, or any
`TailCall` in its body. The last test is needed because a self-tail-recursive
definition has already become a `TailDef` loop whose body names neither itself
nor anything in its component, so without it folds such as `List.foldl` would
not count as recursive.

**Free locals.** `TOpt` has no free-variable function, so this module has its
own: a walk that tracks bound names, where the binders are lambda parameters,
`let` definition names, a `TailDef`'s label and arguments, and `Destruct`
names, and the uses are local variables, a path's root, a `TailCall`'s label and
a `Case`'s root.

@docs Metrics
@docs census

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Graph as Graph
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Data.Set as EverySet
import Dict as CoreDict



-- ============================================================================
-- ====== METRICS ======
-- ============================================================================


{-| The census's counts of lambda arguments, each candidate counted once.

`candidates = closed + capturing`, and
`closed = liftable + declinedCycle + declinedPort + declinedTailDef +
declinedVarCycle + declinedLoopifiable`.

`byCallee` and `byCalleeLoopifiable` break `liftable` and
`declinedLoopifiable` down by callee, keyed by the global's comparable name or,
for a kernel, `home.name`. `lambdasSeen` and `callsSeen` count every lambda and
every call walked, whatever its position. `recursiveGlobals` and
`loopifiableGlobals` are the sizes of the two indexes the loopifiable test reads,
so that a zero `declinedLoopifiable` can be told apart from an empty index.

-}
type alias Metrics =
    { candidates : Int
    , closed : Int
    , capturing : Int

    -- How the closed candidates were classified
    , declinedCycle : Int
    , declinedPort : Int
    , declinedTailDef : Int
    , declinedVarCycle : Int
    , declinedLoopifiable : Int
    , liftable : Int

    -- Per-callee breakdowns
    , byCallee : CoreDict.Dict String Int
    , byCalleeLoopifiable : CoreDict.Dict String Int

    -- Totals over the whole walk
    , lambdasSeen : Int
    , callsSeen : Int

    -- Index sizes
    , recursiveGlobals : Int
    , loopifiableGlobals : Int
    }


{-| The metrics before anything has been counted: every count zero and both
breakdowns empty.
-}
emptyMetrics : Metrics
emptyMetrics =
    { candidates = 0
    , closed = 0
    , capturing = 0
    , declinedCycle = 0
    , declinedPort = 0
    , declinedTailDef = 0
    , declinedVarCycle = 0
    , declinedLoopifiable = 0
    , liftable = 0
    , byCallee = CoreDict.empty
    , byCalleeLoopifiable = CoreDict.empty
    , lambdasSeen = 0
    , callsSeen = 0
    , recursiveGlobals = 0
    , loopifiableGlobals = 0
    }


{-| The kind of code the walk is currently inside, which decides whether a closed
lambda found there could be lifted at all.

`InDefine` is the body of an ordinary `Define` or `TrackedDefine`, the only
scope in which a closed lambda can be liftable. `InCycle` is a member of a
`Cycle` node, `InPort` the body of an incoming or outgoing port, and
`InTailDef` the body of a `TailDef`, whether a `let`-bound tail loop or a
`Cycle` member that is one; a nested `TailDef` body inside any scope is
`InTailDef` too.

-}
type Scope
    = InDefine
    | InCycle
    | InPort
    | InTailDef


{-| The state threaded through the walk: the counts so far, the current scope,
and the set of loopifiable callees, keyed as `byCallee` is.
-}
type alias Ctx =
    { metrics : Metrics
    , scope : Scope
    , loopifiable : CoreDict.Dict String ()
    }



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| Returns the counts for every lambda literal passed as an argument to a global
or a kernel in `graph`, classified as the module docstring describes. The
graph is only read.

Only `Define`, `TrackedDefine`, port and `Cycle` nodes are walked; other nodes
hold no expressions to classify.

-}
census : TOpt.GlobalGraph TypeIds.MVarId -> Metrics
census ((TOpt.GlobalGraph nodes _ _ _ _) as graph) =
    let
        rec =
            recursiveNames graph

        loopifiable =
            buildLoopifiable rec graph

        ctx0 : Ctx
        ctx0 =
            { metrics =
                { emptyMetrics
                    | recursiveGlobals = CoreDict.size rec
                    , loopifiableGlobals = CoreDict.size loopifiable
                }
            , scope = InDefine
            , loopifiable = loopifiable
            }
    in
    (Dict.foldl (\_ node c -> walkNode c node) ctx0 nodes).metrics


{-| Returns `ctx` with every expression in `node` walked under the node's scope.
A `Cycle`'s values and functions are walked as `InCycle`, except that a
function which is a `TailDef` is walked as `InTailDef`.
-}
walkNode : Ctx -> TOpt.Node TypeIds.MVarId -> Ctx
walkNode ctx node =
    case node of
        TOpt.Define body _ _ ->
            walk { ctx | scope = InDefine } body

        TOpt.TrackedDefine _ body _ _ ->
            walk { ctx | scope = InDefine } body

        TOpt.PortIncoming body _ _ ->
            walk { ctx | scope = InPort } body

        TOpt.PortOutgoing body _ _ ->
            walk { ctx | scope = InPort } body

        TOpt.Cycle _ valueDefs funcDefs _ ->
            let
                ctxV =
                    List.foldl (\( _, e ) c -> walk { c | scope = InCycle } e) ctx valueDefs
            in
            List.foldl (\d c -> walkDef { c | scope = InCycle } d) ctxV funcDefs

        _ ->
            ctx



-- ============================================================================
-- ====== THE WALK ======
-- ============================================================================


{-| Returns `ctx` with every call and lambda in `expr` counted, and the lambda
arguments of every call to a global or a kernel classified.

The whole expression is walked, callee and arguments included, so a call
nested inside a lambda argument is classified too. A `let`-bound `TailDef`'s
body is walked as `InTailDef`, and the scope is restored for the `let` body.

-}
walk : Ctx -> TOpt.Expr TypeIds.MVarId -> Ctx
walk ctx expr =
    case expr of
        TOpt.Call _ callee args _ ->
            let
                ctx1 =
                    bumpCalls ctx

                ctx2 =
                    case calleeName callee of
                        Just name ->
                            List.foldl (\a c -> classifyArg name c a) ctx1 args

                        Nothing ->
                            ctx1
            in
            List.foldl (\e c -> walk c e) (walk ctx2 callee) args

        TOpt.Let (TOpt.TailDef _ _ _ tailBody _ _) body _ ->
            let
                ctxT =
                    walk { ctx | scope = InTailDef } tailBody
            in
            walk { ctxT | scope = ctx.scope } body

        TOpt.Function _ _ body _ ->
            walk (bumpLambdas ctx) body

        TOpt.TrackedFunction _ _ body _ ->
            walk (bumpLambdas ctx) body

        _ ->
            List.foldl (\e c -> walk c e) ctx (children expr)


{-| Returns `ctx` with `arg` classified if it is a lambda literal, and unchanged
otherwise. `calleeKey` names the callee for the per-callee breakdowns.
-}
classifyArg : String -> Ctx -> TOpt.Expr TypeIds.MVarId -> Ctx
classifyArg calleeKey ctx arg =
    case arg of
        TOpt.Function _ _ body _ ->
            classifyLambda calleeKey ctx arg body

        TOpt.TrackedFunction _ _ body _ ->
            classifyLambda calleeKey ctx arg body

        _ ->
            ctx


{-| Returns `ctx` with the lambda `lam`, whose body is `body`, counted as a
candidate and as exactly one of capturing, declined for one reason, or
liftable. Where the lambda sits decides first, then `VarCycle`, then the
callee, as the module docstring describes.
-}
classifyLambda : String -> Ctx -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Ctx
classifyLambda calleeKey ctx lam body =
    let
        m0 =
            ctx.metrics

        m1 =
            { m0 | candidates = m0.candidates + 1 }
    in
    if not (CoreDict.isEmpty (freeLocals lam)) then
        { ctx | metrics = { m1 | capturing = m1.capturing + 1 } }

    else
        let
            m2 =
                { m1 | closed = m1.closed + 1 }
        in
        case ctx.scope of
            InCycle ->
                { ctx | metrics = { m2 | declinedCycle = m2.declinedCycle + 1 } }

            InPort ->
                { ctx | metrics = { m2 | declinedPort = m2.declinedPort + 1 } }

            InTailDef ->
                { ctx | metrics = { m2 | declinedTailDef = m2.declinedTailDef + 1 } }

            InDefine ->
                if namesCycle body then
                    { ctx | metrics = { m2 | declinedVarCycle = m2.declinedVarCycle + 1 } }

                else if CoreDict.member calleeKey ctx.loopifiable then
                    { ctx
                        | metrics =
                            { m2
                                | declinedLoopifiable = m2.declinedLoopifiable + 1
                                , byCalleeLoopifiable = bump calleeKey m2.byCalleeLoopifiable
                            }
                    }

                else
                    { ctx
                        | metrics =
                            { m2
                                | liftable = m2.liftable + 1
                                , byCallee = bump calleeKey m2.byCallee
                            }
                    }


{-| Returns `ctx` with the body of the definition `def` walked, as `InTailDef`
when it is a `TailDef` and in the current scope otherwise.
-}
walkDef : Ctx -> TOpt.Def TypeIds.MVarId -> Ctx
walkDef ctx def =
    case def of
        TOpt.Def _ _ body _ ->
            walk ctx body

        TOpt.TailDef _ _ _ body _ _ ->
            walk { ctx | scope = InTailDef } body


{-| Returns `ctx` with one more lambda seen.
-}
bumpLambdas : Ctx -> Ctx
bumpLambdas ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | lambdasSeen = m.lambdasSeen + 1 } }


{-| Returns `ctx` with one more call seen.
-}
bumpCalls : Ctx -> Ctx
bumpCalls ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | callsSeen = m.callsSeen + 1 } }


{-| Returns `d` with the count at `k` raised by one, starting from zero.
-}
bump : String -> CoreDict.Dict String Int -> CoreDict.Dict String Int
bump k d =
    CoreDict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d


{-| Returns whether `expr` contains a `VarCycle` anywhere.

A `VarCycle` refers to a value defined in a `Cycle` node; a reference to a
recursive function in a cycle is a `VarGlobal` and does not count here.

-}
namesCycle : TOpt.Expr TypeIds.MVarId -> Bool
namesCycle expr =
    case expr of
        TOpt.VarCycle _ _ _ _ ->
            True

        _ ->
            List.any namesCycle (children expr)


{-| Returns the key a callee is counted under: the comparable name of a
`VarGlobal`, or `home.name` for a `VarKernel`. Any other callee gives
`Nothing`, and its arguments are not classified.
-}
calleeName : TOpt.Expr TypeIds.MVarId -> Maybe String
calleeName func =
    case func of
        TOpt.VarGlobal _ g _ ->
            Just (TOpt.toComparableGlobal g)

        TOpt.VarKernel _ _ home name _ ->
            Just (home ++ "." ++ name)

        _ ->
            Nothing



-- ============================================================================
-- ====== LOOPIFIABLE CALLEES ======
-- ============================================================================


{-| Returns the keys of the globals in the graph that are loopifiable: those in
`rec`, the recursive globals, that declare a function-typed parameter.

This approximates, before monomorphization, the callees that
`MonoInlineSimplify.buildLoopifiables` admits afterwards, because the
specializations and tail-call shapes it reads do not exist yet. A `Cycle`
contributes one entry per member.

-}
buildLoopifiable : CoreDict.Dict String () -> TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String ()
buildLoopifiable rec (TOpt.GlobalGraph nodes _ _ _ _) =
    Dict.foldl
        (\g node acc ->
            List.foldl
                (\( key, hasFn ) a ->
                    if hasFn && CoreDict.member key rec then
                        CoreDict.insert key () a

                    else
                        a
                )
                acc
                (nodeFunctionParams g node)
        )
        CoreDict.empty
        nodes


{-| Returns the key of every global `node` defines, stored under `g`, each paired
with whether it declares a function-typed parameter.

A `Cycle` gives one entry per function member, keyed by the member's own global,
because that is what call sites name. A `TailDef` member is tested on its
argument types. Nodes other than `Define`, `TrackedDefine` and `Cycle` give
nothing.

-}
nodeFunctionParams : TOpt.Global -> TOpt.Node TypeIds.MVarId -> List ( String, Bool )
nodeFunctionParams g node =
    case node of
        TOpt.Define body _ meta ->
            [ ( TOpt.toComparableGlobal g, bodyHasFunctionParam body meta.tipe ) ]

        TOpt.TrackedDefine _ body _ meta ->
            [ ( TOpt.toComparableGlobal g, bodyHasFunctionParam body meta.tipe ) ]

        TOpt.Cycle _ _ funcDefs _ ->
            List.map
                (\d ->
                    ( TOpt.toComparableGlobal (memberGlobal g d)
                    , case d of
                        TOpt.Def _ _ body tipe ->
                            bodyHasFunctionParam body tipe

                        TOpt.TailDef _ _ args _ _ _ ->
                            List.any (\( _, t ) -> isArrow t) args
                    )
                )
                funcDefs

        _ ->
            []


{-| Returns whether any of the parameters `body` declares has a function type in
`tipe`.

Only as many arrows of `tipe` are examined as `body` has parameters, so an arrow
in the result of a function returning a function does not count. A body that
is not a lambda has no parameters and gives `False`.

-}
bodyHasFunctionParam : TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Bool
bodyHasFunctionParam body tipe =
    let
        arity =
            case body of
                TOpt.Function _ params _ _ ->
                    List.length params

                TOpt.TrackedFunction _ params _ _ ->
                    List.length params

                _ ->
                    0
    in
    anyParamIsArrow arity tipe


{-| Returns whether any of the first `n` parameter types of `tipe` is a function
type. Only `Filled` aliases are looked through; any other type ends the search.
-}
anyParamIsArrow : Int -> Can.Type TypeIds.MVarId -> Bool
anyParamIsArrow n tipe =
    if n <= 0 then
        False

    else
        case tipe of
            Can.TLambda _ from to ->
                isArrow from || anyParamIsArrow (n - 1) to

            Can.TAlias _ _ _ (Can.Filled actual) ->
                anyParamIsArrow n actual

            _ ->
                False


{-| Returns whether `tipe` is a function type, looking through `Filled` aliases
but not `Holey` ones.
-}
isArrow : Can.Type TypeIds.MVarId -> Bool
isArrow tipe =
    case tipe of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled actual) ->
            isArrow actual

        _ ->
            False


{-| Returns the keys of the recursive globals in the graph.

A global is recursive when it is in a cyclic strongly connected component of
the dependency graph, when it is a `Cycle` node or one of its function
members, or when it is a `Define` or `TrackedDefine` whose body `loops`. The
structural tests are needed because a definition's dependency set need not
contain the definition itself.

-}
recursiveNames : TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String ()
recursiveNames (TOpt.GlobalGraph nodes _ _ _ _) =
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
                        TOpt.Cycle _ _ funcDefs _ ->
                            -- Call sites name the members, not the cycle's own key.
                            List.foldl
                                (\d a -> CoreDict.insert (TOpt.toComparableGlobal (memberGlobal g d)) () a)
                                (CoreDict.insert (TOpt.toComparableGlobal g) () acc)
                                funcDefs

                        TOpt.Define body _ _ ->
                            if loops g body then
                                CoreDict.insert (TOpt.toComparableGlobal g) () acc

                            else
                                acc

                        TOpt.TrackedDefine _ body _ _ ->
                            if loops g body then
                                CoreDict.insert (TOpt.toComparableGlobal g) () acc

                            else
                                acc

                        _ ->
                            acc
                )
                CoreDict.empty
                nodes
    in
    CoreDict.union inCycle structural


{-| Returns whether `body` refers to the global `g` or contains a `TailCall`.

A self-tail-recursive definition has already become a `TailDef` loop whose body
names neither itself nor anything in its component, so the `TailCall` test is
what makes folds such as `List.foldl` count as recursive.

-}
loops : TOpt.Global -> TOpt.Expr TypeIds.MVarId -> Bool
loops g body =
    namesGlobal g body || hasTailCall body


{-| Returns whether `expr` contains a `TailCall` anywhere.
-}
hasTailCall : TOpt.Expr TypeIds.MVarId -> Bool
hasTailCall expr =
    case expr of
        TOpt.TailCall _ _ _ ->
            True

        _ ->
            List.any hasTailCall (children expr)


{-| Returns the global of the `Cycle` member `def`: the cycle node's home
module with the definition's name.
-}
memberGlobal : TOpt.Global -> TOpt.Def TypeIds.MVarId -> TOpt.Global
memberGlobal (TOpt.Global home _) def =
    case def of
        TOpt.Def _ name _ _ ->
            TOpt.Global home name

        TOpt.TailDef _ name _ _ _ _ ->
            TOpt.Global home name


{-| Returns whether `expr` refers to the global `g`, as a `VarGlobal`,
`VarEnum`, `VarBox` or `VarCycle`.
-}
namesGlobal : TOpt.Global -> TOpt.Expr TypeIds.MVarId -> Bool
namesGlobal ((TOpt.Global home name) as g) expr =
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
            List.any (namesGlobal g) (children expr)



-- ============================================================================
-- ====== FREE LOCALS ======
-- ============================================================================


{-| Returns the local names `expr` uses without binding them. References to
globals, kernels, cycle values and constructors are not local and never
appear.
-}
freeLocals : TOpt.Expr TypeIds.MVarId -> CoreDict.Dict String ()
freeLocals expr =
    freeGo CoreDict.empty expr CoreDict.empty


{-| Returns `acc` with every local name used in `expr` and bound neither in
`expr` nor in `bound` added.

A `let` definition's name is bound in the `let` body only, not in its own
definition. A `TailDef`'s label is bound in its loop body and in the `let`
body, its arguments only in the loop body. A `Case`'s root is a use; its label
is neither a use nor a binder.

-}
freeGo : CoreDict.Dict String () -> TOpt.Expr TypeIds.MVarId -> CoreDict.Dict String () -> CoreDict.Dict String ()
freeGo bound expr acc =
    case expr of
        TOpt.VarLocal n _ ->
            use bound n acc

        TOpt.TrackedVarLocal _ n _ ->
            use bound n acc

        TOpt.Function _ params body _ ->
            freeGo (List.foldl (\( n, _ ) b -> CoreDict.insert n () b) bound params) body acc

        TOpt.TrackedFunction _ params body _ ->
            freeGo (List.foldl (\( n, _ ) b -> CoreDict.insert (A.toValue n) () b) bound params) body acc

        TOpt.Let def body _ ->
            case def of
                TOpt.Def _ n bound1 _ ->
                    freeGo (CoreDict.insert n () bound) body (freeGo bound bound1 acc)

                TOpt.TailDef _ n args tailBody _ _ ->
                    let
                        inner =
                            List.foldl (\( a, _ ) b -> CoreDict.insert (A.toValue a) () b)
                                (CoreDict.insert n () bound)
                                args
                    in
                    freeGo (CoreDict.insert n () bound) body (freeGo inner tailBody acc)

        TOpt.Destruct (TOpt.Destructor n path _) body _ ->
            freeGo (CoreDict.insert n () bound) body (use bound (pathRoot path) acc)

        TOpt.Case _ root decider jumps _ ->
            List.foldl (\( _, e ) a -> freeGo bound e a)
                (freeDecider bound decider (use bound root acc))
                jumps

        TOpt.TailCall label args _ ->
            List.foldl (\( _, e ) a -> freeGo bound e a) (use bound label acc) args

        _ ->
            List.foldl (\e a -> freeGo bound e a) acc (children expr)


{-| Returns `acc` with the free locals of every `Inline` choice in `decider` added.
`Jump` choices add nothing here; their bodies are the `Case`'s jumps.
-}
freeDecider : CoreDict.Dict String () -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> CoreDict.Dict String () -> CoreDict.Dict String ()
freeDecider bound decider acc =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            freeGo bound e acc

        TOpt.Leaf (TOpt.Jump _) ->
            acc

        TOpt.Chain _ ok ko ->
            freeDecider bound ko (freeDecider bound ok acc)

        TOpt.FanOut _ branches fallback ->
            freeDecider bound fallback (List.foldl (\( _, d ) a -> freeDecider bound d a) acc branches)


{-| Returns `acc` with `n` added, unless `n` is in `bound`.
-}
use : CoreDict.Dict String () -> Name -> CoreDict.Dict String () -> CoreDict.Dict String ()
use bound n acc =
    if CoreDict.member n bound then
        acc

    else
        CoreDict.insert n () acc


{-| Returns the local name a destructuring path starts from.
-}
pathRoot : TOpt.Path -> Name
pathRoot path =
    case path of
        TOpt.Root n ->
            n

        TOpt.Index _ _ inner ->
            pathRoot inner

        TOpt.ArrayIndex _ inner ->
            pathRoot inner

        TOpt.Field _ inner ->
            pathRoot inner

        TOpt.Unbox inner ->
            pathRoot inner



-- ============================================================================
-- ====== CHILDREN ======
-- ============================================================================


{-| Returns the immediate sub-expressions of `expr`, including a `Case`'s
`Inline` choices and jump bodies and a `let` definition's body.
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


{-| Returns the expression a `let` definition binds, or a `TailDef`'s loop body.
-}
defChildren : TOpt.Def TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
defChildren def =
    case def of
        TOpt.Def _ _ bound _ ->
            [ bound ]

        TOpt.TailDef _ _ _ body _ _ ->
            [ body ]


{-| Returns the expressions of every `Inline` choice in `decider`.
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
