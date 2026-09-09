module Compiler.GlobalOpt.InlineSimplify exposing
    ( Metrics, emptyMetrics
    , optimize
    )

{-| PRE-MONOMORPHIZATION inliner (plans/pre-mono-inline-simplify.md).

`MonoInlineSimplify` runs on fully-specialized code, so a small polymorphic
definition is monomorphized into N copies and each copy is inlined
independently. This pass inlines once, before specialization.

**But NOT the polymorphic form** — see `isGround`. Every `TOpt` node carries a
`Meta` holding that node's SOLVER VARIABLE, so two copies of a polymorphic body
share one set of variables and `MonoSolver` meets the two call sites'
instantiations at the same variable. Only fully MONOMORPHIC candidates are
admitted. That guard rejects ~98% of what the pass would otherwise inline, and
it is the reason the shipped inliner sits after monomorphization: the position
difference is one of safety, not only of available information
(plan §11.2).

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
    , bodiesSeen = 0
    , inlinedByCallee = CoreDict.empty
    }


type alias Ctx =
    { candidates : CoreDict.Dict String Candidate
    , metrics : Metrics
    , fresh : Int
    , fuel : Int
    }


type alias Candidate =
    { params : List ( Name, Can.Type Name )
    , body : TOpt.Expr Name
    , name : String
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
                    , bodiesSeen = cands.bodiesSeen
                }
            , fresh = 0
            , fuel = max 1 cfg.fixpointIterations
            }
    in
    rounds cfg ctx0 graph


rounds : Config.InlineConfig -> Ctx -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Metrics )
rounds cfg ctx graph =
    if ctx.fuel <= 0 then
        ( graph, ctx.metrics )

    else
        let
            before =
                ctx.metrics.inlineCount

            ( graph1, ctx1 ) =
                rewriteGraph ctx graph
        in
        if ctx1.metrics.inlineCount == before then
            -- Fixpoint: a round that inlined nothing cannot be improved on.
            ( graph1, ctx1.metrics )

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
    -> TOpt.GlobalGraph Name
    ->
        { index : CoreDict.Dict String Candidate
        , recursiveSkipped : Int
        , overBudget : Int
        , polymorphic : Int
        , bodiesSeen : Int
        }
buildCandidates cfg (TOpt.GlobalGraph nodes _ _ _ _) =
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

                        else if not (isGround params body) then
                            { a | polymorphic = a.polymorphic + 1 }

                        else if cost body > cfg.threshold then
                            { a | overBudget = a.overBudget + 1 }

                        else
                            { a
                                | index =
                                    CoreDict.insert key
                                        { params = params, body = body, name = qualifiedName g }
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
        , bodiesSeen = 0
        }
        nodes


{-| Whether a candidate is fully MONOMORPHIC — no type variable anywhere in
its parameter types or in any expression's `Meta` inside its body.

**This is the load-bearing guard of the whole pass, and it is what makes a
pre-monomorphization inliner different in kind from a post-mono one.**

Copying a body here copies its `Meta`s verbatim, and a `Meta` carries the
node's solver variable. Two copies of a POLYMORPHIC body therefore share one
set of solver variables, so the two call sites' instantiations meet at the same
variable and `MonoSolver` unifies them against each other. Observed, exactly:

    twice : (a -> a) -> a -> a

used once at `Int` and once at `List Int` makes the solver report

    unify-fail ({..} -> List<?a> -> List<?a>) /vs/ ({..} -> Int -> Int)

That is a hard error rather than a silent wrong answer only because the two
types happen to disagree structurally; two DIFFERENT instantiations that
unify would have collapsed onto one silently. `MonoInlineSimplify` has no such
exposure: after monomorphization every body is already ground.

Refreshing the copied types instead of refusing them means minting fresh
solver variables and substituting them through every `Meta` — that is
instantiation, i.e. re-implementing the part of `MonoSolver` this pass runs
before. `plans/pre-mono-inline-simplify.md` §9 records that as the follow-on;
v1 refuses.

-}
isGround : List ( Name, Can.Type Name ) -> TOpt.Expr Name -> Bool
isGround params body =
    List.all (\( _, t ) -> groundType t) params && groundExpr body


groundType : Can.Type Name -> Bool
groundType tipe =
    case tipe of
        Can.TVar _ ->
            False

        Can.TLambda _ a b ->
            groundType a && groundType b

        Can.TType _ _ args ->
            List.all groundType args

        Can.TRecord fields ext ->
            (ext == Nothing)
                && CoreDict.foldl (\_ f acc -> acc && groundField f) True fields

        Can.TUnit ->
            True

        Can.TTuple a b rest ->
            groundType a && groundType b && List.all groundType rest

        Can.TAlias _ _ args real ->
            List.all (\( _, t ) -> groundType t) args && groundAliasType real


groundField : Can.FieldType Name -> Bool
groundField (Can.FieldType _ t) =
    groundType t


groundAliasType : Can.AliasType Name -> Bool
groundAliasType alias_ =
    case alias_ of
        Can.Holey t ->
            groundType t

        Can.Filled t ->
            groundType t


{-| Every `Meta` in an expression carries a ground type. Walked in full rather
than trusting the top-level signature: let-polymorphism inside a
ground-signature body would otherwise slip a shared type variable through.
-}
groundExpr : TOpt.Expr Name -> Bool
groundExpr expr =
    groundType (TOpt.typeOf expr) && List.all groundExpr (children expr)


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
                Just ( inlined, c3 ) ->
                    ( inlined, c3 )

                Nothing ->
                    ( TOpt.Call region func1 args1 meta, c2 )

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
tryInline : Ctx -> A.Region -> TOpt.Expr Name -> List (TOpt.Expr Name) -> TOpt.Meta Name -> Maybe ( TOpt.Expr Name, Ctx )
tryInline ctx region func args _ =
    case func of
        TOpt.VarGlobal _ g _ ->
            case CoreDict.get (TOpt.toComparableGlobal g) ctx.candidates of
                Just cand ->
                    if List.length args == List.length cand.params then
                        Just (doInline ctx region cand args)

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


doInline : Ctx -> A.Region -> Candidate -> List (TOpt.Expr Name) -> ( TOpt.Expr Name, Ctx )
doInline ctx region cand args =
    let
        ( freshBody, freshParams, ctx1 ) =
            freshenBody ctx cand

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
freshenBody : Ctx -> Candidate -> ( TOpt.Expr Name, List ( Name, Can.Type Name ), Ctx )
freshenBody ctx cand =
    let
        suffix =
            "_pi" ++ String.fromInt ctx.fresh

        renamedParams =
            List.map (\( n, t ) -> ( n ++ suffix, t )) cand.params
    in
    ( suffixExpr suffix cand.body, renamedParams, { ctx | fresh = ctx.fresh + 1 } )


{-| Apply the copy suffix to every local name in an expression. See
`freshenBody` for why a blanket rename is the right thing here.
-}
suffixExpr : String -> TOpt.Expr Name -> TOpt.Expr Name
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
        TOpt.VarLocal n meta ->
            TOpt.VarLocal (nm n) meta

        TOpt.TrackedVarLocal region n meta ->
            TOpt.TrackedVarLocal region (nm n) meta

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
            TOpt.TailCall (nm n) (List.map (\( an, e ) -> ( nm an, go e )) args) meta

        TOpt.If branches final meta ->
            TOpt.If (List.map (\( c, t ) -> ( go c, go t )) branches) (go final) meta

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

        TOpt.Access inner region field meta ->
            TOpt.Access (go inner) region field meta

        TOpt.Update region record fields meta ->
            TOpt.Update region (go record) (Dict.map (\_ e -> go e) fields) meta

        TOpt.Record fields meta ->
            TOpt.Record (CoreDict.map (\_ e -> go e) fields) meta

        TOpt.TrackedRecord region fields meta ->
            TOpt.TrackedRecord region (Dict.map (\_ e -> go e) fields) meta

        TOpt.Tuple region a b rest meta ->
            TOpt.Tuple region (go a) (go b) (List.map go rest) meta

        _ ->
            -- Literals, globals, enums, boxes, cycles, kernels, accessors,
            -- debug vars, shaders: no local names, no sub-expressions.
            expr


suffixDef : String -> TOpt.Def Name -> TOpt.Def Name
suffixDef sfx def =
    case def of
        TOpt.Def region n bound tipe ->
            TOpt.Def region (n ++ sfx) (suffixExpr sfx bound) tipe

        TOpt.TailDef region n args body tipe tvar ->
            TOpt.TailDef region
                (n ++ sfx)
                (List.map
                    (\( ln, t ) -> ( A.At (A.toRegion ln) (A.toValue ln ++ sfx), t ))
                    args
                )
                (suffixExpr sfx body)
                tipe
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


suffixDecider : String -> TOpt.Decider (TOpt.Choice Name) -> TOpt.Decider (TOpt.Choice Name)
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
            TOpt.Chain tests (suffixDecider sfx ok) (suffixDecider sfx ko)

        TOpt.FanOut path branches fallback ->
            TOpt.FanOut path
                (List.map (\( t, d ) -> ( t, suffixDecider sfx d )) branches)
                (suffixDecider sfx fallback)


locatedName : A.Located Name -> Name
locatedName =
    A.toValue
