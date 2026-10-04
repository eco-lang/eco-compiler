module Compiler.GlobalOpt.PreMono.LiftClosedArgs exposing
    ( Metrics
    , census
    )

{-| PRE-MONOMORPHIZATION lambda-lifting of CLOSED lambda arguments — CENSUS ONLY
(`plans/pre-mono-lss-transforms-03-lift-closed-lambda-args.md` §5 layer C).

The plan is CENSUS-GATED and this module is the census. Nothing here rewrites
anything: `census` runs the §3.1 scope predicate over the graph and reports what
the pass WOULD touch, so the §5 build gate (≥ 100 closed sites, and ≥ 1 % of
generic dispatch at them) can be decided before any transform exists.

**What the transform would do.** A closed `Function` literal in ARGUMENT
position of a call to a global or kernel becomes a top-level `Define` under a
fresh global, and the argument becomes a reference to it. LSS resolves globals
completely — `injectArgLambdaMemberGo`'s `VarGlobal` arm mints a `g|` member at
the callee's parameter arrow — where an `l|` member whose closure the post-mono
passes reshaped resolves to nothing (`g1absentl`).

**Why the census exists at all.** §1.2's probe says the premise may not survive
it: on the shape the item was designed for, the `g1absentl` was manufactured by
`tryLoopify` in the POST-mono inliner, not by a missing member, and the lift's
mechanism there is loopify DEFEAT rather than member repair. Site counts have
mispredicted dynamic weight four times in this arc, so nothing is built until
the closed population and its dispatch weight are both measured.

**The four numbers.** `candidates` is every lambda literal in argument position
of a global/kernel callee — the denominator whose zero is impossible.
`closed`/`capturing` split it on the free-local test, because capturing lambdas
are OUT of v1 by construction (lifting them turns captures into parameters and
changes the callee's interface). `declinedLoopifiable` is R1's exclusion: a
recursive callee with a function-typed parameter is loopify's own territory, and
a lifted `VarGlobal` argument would simply stop `tryLoopify` firing. `liftable`
is what is left.

**Free locals.** `TOpt` has no `freeVars` (`Monomorphize/Closure.findFreeLocals`
is `MonoExpr`-only), so §3.1 specifies one: a binders-vs-uses walk where binders
are `Function`/`TrackedFunction` params, `Let` def names, `TailDef` labels and
args, and `Destruct` destructor names, and uses are
`VarLocal`/`TrackedVarLocal`, a `Path`'s `Root`, a `TailCall` label and a
`Case`'s root (its LABEL is neither).

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


{-| §5 layer C. `candidates` is the denominator; everything else partitions it.

`candidates = closed + capturing`, and
`closed = liftable + declinedCycle + declinedPort + declinedTailDef +
declinedVarCycle + declinedLoopifiable`.

-}
type alias Metrics =
    { candidates : Int
    , closed : Int
    , capturing : Int

    -- §3.1 scope exclusions, counted over the CLOSED population only.
    , declinedCycle : Int
    , declinedPort : Int
    , declinedTailDef : Int
    , declinedVarCycle : Int

    -- R1: the callee is recursive AND takes a function-typed parameter, i.e.
    -- `buildLoopifiables` is likely to admit it post-mono. Lifting there trades
    -- a local loop for a keyed spec and is a dispatch question, not a stamping
    -- one — so v1 skips it and the census sizes what that costs.
    , declinedLoopifiable : Int
    , liftable : Int

    -- attribution: which HOFs the population sits at.
    , byCallee : CoreDict.Dict String Int
    , byCalleeLoopifiable : CoreDict.Dict String Int

    -- denominators that cannot be zero if the walk ran at all.
    , lambdasSeen : Int
    , callsSeen : Int

    -- index sizes, so a zero in `declinedLoopifiable` can be read: it is the
    -- R1 predicate finding nothing, or the population simply not sitting at
    -- those callees.
    , recursiveGlobals : Int
    , loopifiableGlobals : Int
    }


{-| All-zero metrics.
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


{-| Where the walk currently is. A lambda's eligibility depends on its ENCLOSING
node, not on itself, so the scope travels with the walk.
-}
type Scope
    = InDefine
    | InCycle
    | InPort
    | InTailDef


type alias Ctx =
    { metrics : Metrics
    , scope : Scope

    -- callee name -> True when the callee is recursive and takes a
    -- function-typed parameter (R1's pre-mono approximation of
    -- `buildLoopifiables`).
    , loopifiable : CoreDict.Dict String ()
    }



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| Classify every lambda literal in argument position. Returns metrics only —
the graph is never touched, so this is safe to run unconditionally behind
`inline.report`.
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


{-| Every call whose callee names a global or a kernel has its ARGUMENTS
classified; everything is then walked normally, so a lambda nested inside
another lambda's body is reached too.
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
            -- A `TailDef` body's jump labels are local to it, so a lambda
            -- lifted out of one would reference a label that does not exist
            -- in the lifted global (§3.1).
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


{-| One argument of a call to a named callee.
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


walkDef : Ctx -> TOpt.Def TypeIds.MVarId -> Ctx
walkDef ctx def =
    case def of
        TOpt.Def _ _ body _ ->
            walk ctx body

        TOpt.TailDef _ _ _ body _ _ ->
            walk { ctx | scope = InTailDef } body


bumpLambdas : Ctx -> Ctx
bumpLambdas ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | lambdasSeen = m.lambdasSeen + 1 } }


bumpCalls : Ctx -> Ctx
bumpCalls ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | callsSeen = m.callsSeen + 1 } }


bump : String -> CoreDict.Dict String Int -> CoreDict.Dict String Int
bump k d =
    CoreDict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d


{-| A `VarCycle` anywhere in the body: referencing a cycle member from a lifted
global would need the cycle's placeholder machinery (§3.1).
-}
namesCycle : TOpt.Expr TypeIds.MVarId -> Bool
namesCycle expr =
    case expr of
        TOpt.VarCycle _ _ _ _ ->
            True

        _ ->
            List.any namesCycle (children expr)


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
-- ====== R1: WHICH CALLEES LOOPIFY WOULD CLAIM ======
-- ============================================================================


{-| The pre-mono approximation of `MonoInlineSimplify.buildLoopifiables`: a
global that is RECURSIVE and declares a function-typed parameter. Post-mono the
real test is a `MonoTailFunc` spec with a `paramLoopifiable` function param;
neither the spec nor the tail shape exists yet here, and recursion plus a
function parameter is what produces both.

Recursion is decided as `InlineSimplify.recursiveGlobals` decides it — an SCC
over the dependency sets, membership of a `Cycle`, and a structural scan of the
body for a self-reference, because a self-recursive definition's `deps` need not
contain itself — PLUS one test that pass does not need: a `TailCall` anywhere in
the body. A self-tail-recursive definition is rewritten into a `TailDef` loop
before this point, so `List.foldl`'s body names neither itself nor anything in
its own SCC, and the first three tests all say "not recursive" for precisely the
folds loopify exists to claim (MEASURED: without this, `declinedLoopifiable` is
0 and `List.foldl`/`Dict.foldr` appear as liftable). A `TailCall` is also the
shape that becomes the `MonoTailFunc` spec `buildLoopifiables` reads.

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


{-| Every global this node defines, with whether it declares a function-typed
parameter. A `Cycle` defines one global PER MEMBER, which is what call sites
name; its own key names nothing callable.
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


{-| The declared type is peeled to the parameter count the BODY writes — the
graph's arity, never the type's full arrow spine, which counts a curried
result's arrows too (`EtaExpand.calleeArity`'s recorded miscompile).
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


isArrow : Can.Type TypeIds.MVarId -> Bool
isArrow tipe =
    case tipe of
        Can.TLambda _ _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled actual) ->
            isArrow actual

        _ ->
            False


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
                            -- A cycle's MEMBERS are what call sites name, and
                            -- they are recursive by construction; the cycle's
                            -- own key is never a callee. `EtaExpand.buildIndex`
                            -- keys them the same way.
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


{-| Self-reference by name, or a tail loop. See `buildLoopifiable`.
-}
loops : TOpt.Global -> TOpt.Expr TypeIds.MVarId -> Bool
loops g body =
    namesGlobal g body || hasTailCall body


hasTailCall : TOpt.Expr TypeIds.MVarId -> Bool
hasTailCall expr =
    case expr of
        TOpt.TailCall _ _ _ ->
            True

        _ ->
            List.any hasTailCall (children expr)


{-| A cycle member's own global: the cycle node's home plus the def's name.
-}
memberGlobal : TOpt.Global -> TOpt.Def TypeIds.MVarId -> TOpt.Global
memberGlobal (TOpt.Global home _) def =
    case def of
        TOpt.Def _ name _ _ ->
            TOpt.Global home name

        TOpt.TailDef _ name _ _ _ _ ->
            TOpt.Global home name


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


{-| The free LOCAL names of an expression (§3.1). Globals, kernels, cycle
members and constructors are not locals and never appear.
-}
freeLocals : TOpt.Expr TypeIds.MVarId -> CoreDict.Dict String ()
freeLocals expr =
    freeGo CoreDict.empty expr CoreDict.empty


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
                    -- Elm's non-recursive `let`: the name is in scope in the
                    -- BODY only (recursion travels through `Cycle`/`TailDef`).
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
            -- The LABEL binds nothing and is not a use; the ROOT is a use.
            List.foldl (\( _, e ) a -> freeGo bound e a)
                (freeDecider bound decider (use bound root acc))
                jumps

        TOpt.TailCall label args _ ->
            List.foldl (\( _, e ) a -> freeGo bound e a) (use bound label acc) args

        _ ->
            List.foldl (\e a -> freeGo bound e a) acc (children expr)


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


use : CoreDict.Dict String () -> Name -> CoreDict.Dict String () -> CoreDict.Dict String ()
use bound n acc =
    if CoreDict.member n bound then
        acc

    else
        CoreDict.insert n () acc


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


{-| Immediate sub-expressions, including the decider's `Inline` choices. Mirrors
`InlineSimplify.children`; the two walks want the same constructor set.
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
