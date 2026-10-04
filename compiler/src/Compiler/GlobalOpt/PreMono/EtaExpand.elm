module Compiler.GlobalOpt.PreMono.EtaExpand exposing
    ( Metrics, emptyMetrics
    , run
    )

{-| PRE-MONOMORPHIZATION η-expansion to DECLARED arity
(`plans/pre-mono-lss-transforms-01-eta-expand-to-declared-arity.md`).

**The problem.** `System.TypeCheck.IO` is 55.3 % of the self-compile's generic
dispatch, and it fails for a purely SYNTACTIC reason. `IO a` is a type ALIAS for
`State -> ( State, a )`, so `andThen` and `map` are already SATURATED in their
definitions (`IO.elm:239,254` — three parameters each), while every one of the
169 callers writes the chain at the ALIAS arity:

    prog : IO Int
    prog = tick |> IO.andThen (\a -> …)

`applyOneMore` (`LocalOpt/Typed/Expression.elm:123`) merges `x |> f a` into
`Call f [a, x]`, so `prog`'s body is `Call andThen [k, tick]` — TWO of three
arguments, a PAP. The continuation returns another PAP. Inside `andThen`'s own
body, `f a s1` therefore applies a CALL RESULT, for which no member channel
exists (LSS\_006: arrows have no identity), and every bind in the chain funnels
through that one generic dispatch.

**The fix is saturation, not inlining.** Written out at declared arity the same
program has, at every site, a lambda LITERAL in the callback position (an `l|`
member, singleton) and a GLOBAL in the action position (a `g|` member,
singleton). MEASURED on the `SeqM`/`SeqEta`/`StateEta2` probes: 5 live generic
sites → 1 → 0, output identical. The pre-mono inliner declined `andThen`
(`hofParam`) in the same probe and the expanded arm still reached 0, so the
mechanism is the arity, not the copy.

**Two rules.**

  - DEFINITIONS (§2.2): a `Define`/`TrackedDefine`/Cycle-`Def` whose type
    declares `k` parameters once aliases are expanded but whose body writes only
    `j < k` of them gains `k - j` parameters and applies its body to them.
  - CONTINUATIONS (§2.3): a lambda LITERAL in argument position whose expected
    parameter type (read off the callee's own spine at that position) declares
    more parameters than the lambda writes gains the difference. Its
    `SrcLambdaId` is KEPT — it is the same source lambda with more parameters,
    and that id is the future member key.

Both then NORMALISE the new application (§2.4): merge into an under-applied call
to a known global, push through `Let`/`Destruct`/`If`/`Case` to where the call
actually is, beta a lambda head by LET-BINDING (never substitution).

**Why this survives the pre-mono type-precision ceiling.** Arity is read off the
alias's STRUCTURE, never off a solved type: `IO b = State -> ( State, b )` has
arity 1 whether or not `b` is known. That is why this transform is not capped
the way the inliner's `determines` guard is (864 declined for want of ground
types).

**The cheapness gate (§2.5)** is the whole safety argument. η-expansion moves
everything LEFT of the new binders from once (a memoised CAF slot, or one
closure creation) to once PER CALL. That is free exactly when the work is
building the PAP/closure the call was about to apply anyway, and a disaster for
`d = let big = expensive in \s -> …`. Only bodies whose pre-binder work is
construction, a partial application, a sub-threshold saturated call or a
gc-leaf kernel are expanded.

**Two exclusions that are not obvious and are both load-bearing.** A node whose
whole body is a bare `VarKernel` is a kernel ALIAS, and `LssInfer.kernelAliasOf`
recognises it by exactly that shape to fold the `g|` and `k|` identities into one
(LSS\_016); expanding it splits them into a 2-set and kills every singleton
consumer. And a callee's arity is read from the GRAPH, never from its type: an
arrow chain counts the arrows of its RESULT too, so a combinator's type says six
where the definition writes three — see `calleeArity`.

**Identity discipline (§2.7, item 0's contract).** Every type this pass puts at
a NEW position has its arrow slots CLEARED and is minted by
`Fresh.mintNewNode`: an `ArrowId` is per syntactic OCCURRENCE (LSS\_027), and
splicing a sub-term of an existing type verbatim would put one id at two
occurrences — which `Fresh.assertMinted` rejects as the LSS\_009 impersonation
shape. New wrapper lambdas carry `Nothing` and are minted by the same call;
rebuilt EXISTING lambdas keep the id they had.

@docs Metrics, emptyMetrics
@docs run

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Compiler.GlobalOpt.PreMono.Fresh as Fresh
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Dict as CoreDict



-- ============================================================================
-- ====== METRICS ======
-- ============================================================================


{-| Census counters. `bodiesSeen` is the denominator whose zero is impossible —
the pre-mono inliner's first `buildCandidates` matched almost no node shape and
reported `candidates = 0`, which reads identically to "refused everything".
-}
type alias Metrics =
    { defs : Int
    , cycleDefs : Int
    , conts : Int
    , merged : Int
    , pushed : Int
    , notCheap : Int
    , noDeficit : Int
    , noSpine : Int
    , tailDef : Int
    , cycleValue : Int
    , kernelAlias : Int
    , ctorAlias : Int -- a bare constructor reference (`unsignedInt8 = U8`): expanding it buys no arity and only hides the constructor from later recognisers (bytes fusion)
    , bodiesSeen : Int

    -- deficit histogram over the sites that FIRED plus those refused only by
    -- the cheapness gate: 1, 2, 3-or-more.
    , deficit1 : Int
    , deficit2 : Int
    , deficit3 : Int

    -- `cheapShare` numerator/denominator: how much of what the arity test
    -- admitted the cheapness gate then refused. If the gate refuses most of
    -- the 55 %, the gate is wrong, not the idea (R1).
    , cheapYes : Int
    , cheapSeen : Int

    -- expansions attributed by name: a definition by its own global, a
    -- continuation by the CALLEE whose argument position it sits in.
    , byName : CoreDict.Dict String Int
    , notCheapByName : CoreDict.Dict String Int

    -- a spine that did not peel where the arity test said it should. Zero is
    -- the expected value; a nonzero one means the node meta and the body type
    -- disagree, and the site is declined rather than mis-typed.
    , noPeel : Int
    }


{-| All-zero metrics — what `run` reports when the pass is off.
-}
emptyMetrics : Metrics
emptyMetrics =
    { defs = 0
    , cycleDefs = 0
    , conts = 0
    , merged = 0
    , pushed = 0
    , notCheap = 0
    , noDeficit = 0
    , noSpine = 0
    , tailDef = 0
    , cycleValue = 0
    , kernelAlias = 0
    , ctorAlias = 0
    , bodiesSeen = 0
    , deficit1 = 0
    , deficit2 = 0
    , deficit3 = 0
    , cheapYes = 0
    , cheapSeen = 0
    , byName = CoreDict.empty
    , notCheapByName = CoreDict.empty
    , noPeel = 0
    }


type alias Ctx =
    { state : AssignMVarIds.GlobalMVarState
    , metrics : Metrics
    , fresh : Int

    -- What the cheapness gate and the merge rule read. A global with no entry
    -- answers "unknown", which refuses both — the conservative direction in
    -- each.
    , gate : Gate

    -- the name currently being rewritten, for `byName` attribution.
    , who : String

    -- DIAGNOSTIC module allow-list (`InlineConfig.etaOnly`); [] = every module.
    , only : List String
    }



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| η-expand definitions and continuation lambdas to declared arity.

Returns the ORIGINAL graph and state untouched when `inline.etaExpand` is off,
so `inline.report` alone gives the census (`pre-eta-census:`) with no rewrite —
Step 1 of the plan, and the measurement that decides whether the gate is tuned
before a run is spent on it.

-}
run :
    Config.InlineConfig
    -> AssignMVarIds.GlobalMVarState
    -> TOpt.GlobalGraph TypeIds.MVarId
    -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
run cfg state graph =
    let
        index : CoreDict.Dict String Callee
        index =
            buildIndex graph

        -- Round 0: syntactic arities, straight off the graph.
        gate0 : Gate
        gate0 =
            { threshold = cfg.etaThreshold
            , arity = CoreDict.map (\_ c -> c.arity) index
            , cost = CoreDict.map (\_ c -> c.cost) index
            , aliasCost = buildAliasCost graph
            , ctors = buildCtorSet graph
            }

        -- Round 1: the arity each definition will HAVE once this pass is done.
        gate1 : Gate
        gate1 =
            { gate0 | arity = buildPostArity gate0 graph }

        ctx0 : Ctx
        ctx0 =
            { state = state
            , metrics = emptyMetrics
            , fresh = 0
            , gate = gate1
            , who = ""
            , only = cfg.etaOnly
            }

        ( graph1, ctx1 ) =
            rewriteGraph ctx0 graph
    in
    if cfg.etaExpand then
        ( graph1, ctx1.state, ctx1.metrics )

    else
        ( graph, state, ctx1.metrics )


{-| DIAGNOSTIC: `etaOnly` allow-list — a global is rewritten only when its
`Module.name` starts with one of the configured prefixes. An empty list admits everything.
-}
moduleAllowed : List String -> TOpt.Global -> Bool
moduleAllowed only (TOpt.Global (ModuleName.Canonical _ moduleName) name) =
    let
        -- `Module.Name.def`, so a prefix can name a module OR a definition.
        qualified =
            moduleName ++ "." ++ name
    in
    List.isEmpty only || List.any (\prefix -> String.startsWith prefix qualified) only


rewriteGraph : Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, Ctx )
rewriteGraph ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( newNodes, ctx1 ) =
            Dict.foldl
                (\g node ( acc, c ) ->
                    let
                        ( newNode, c1 ) =
                            if moduleAllowed c.only g then
                                rewriteNode { c | who = TOpt.toComparableGlobal g } g node

                            else
                                ( node, c )
                    in
                    ( Dict.insert TOpt.toComparableGlobal g newNode acc, c1 )
                )
                ( Dict.empty, ctx )
                nodes
    in
    ( TOpt.GlobalGraph newNodes fields annotations schemeRoots varSupers, ctx1 )


{-| `Define`/`TrackedDefine` bodies and Cycle FUNCTION defs get both rules;
Cycle VALUE defs and `TailDef`s get neither and are counted.

Ports, `Ctor`/`Enum`/`Box`/`Link`/`Manager`/`Kernel` nodes and the synthesized
flags decoder are not touched at all (§2.6). `main` needs no special case: its
type has no arrow spine, so the arity test declines it as `noSpine`.

-}
rewriteNode : Ctx -> TOpt.Global -> TOpt.Node TypeIds.MVarId -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx (TOpt.Global _ nodeName) node =
    if nodeName == EntryPrep.flagsDecoderName then
        ( node, ctx )

    else
        case node of
            TOpt.Define expr deps meta ->
                let
                    ( body1, ctx1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( body2, ctx2 ) =
                        expandDefinition ctx1 TopLevel Nothing meta.tipe body1
                in
                ( TOpt.Define body2 deps meta, ctx2 )

            TOpt.TrackedDefine region expr deps meta ->
                let
                    ( body1, ctx1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( body2, ctx2 ) =
                        expandDefinition ctx1 TopLevel (Just region) meta.tipe body1
                in
                ( TOpt.TrackedDefine region body2 deps meta, ctx2 )

            TOpt.Cycle names values funcDefs deps ->
                let
                    ( newValues, ctxV ) =
                        List.foldl
                            (\( n, e ) ( acc, c ) ->
                                let
                                    -- A recursive CAF. The continuation rule
                                    -- still applies inside it; the definition
                                    -- rule does not (§2.6).
                                    ( e1, c1 ) =
                                        rewriteExpr (seeBody c) e

                                    c2 =
                                        if hasDeficit (TOpt.typeOf e) e then
                                            bump (\m -> { m | cycleValue = m.cycleValue + 1 }) c1

                                        else
                                            c1
                                in
                                ( ( n, e1 ) :: acc, c2 )
                            )
                            ( [], ctx )
                            values

                    ( newFuncs, ctxF ) =
                        List.foldl
                            (\def ( acc, c ) ->
                                let
                                    ( d1, c1 ) =
                                        rewriteCycleDef c def
                                in
                                ( d1 :: acc, c1 )
                            )
                            ( [], ctxV )
                            funcDefs
                in
                ( TOpt.Cycle names (List.reverse newValues) (List.reverse newFuncs) deps, ctxF )

            _ ->
                ( node, ctx )


{-| A Cycle member. `sequence` and every recursive `unify`-style caller lives
here, so the `Def` arm is not optional (§2.6).

`TailDef` is OUT in v1: its `TailCall` sites carry exactly the syntactic
parameters, so adding one means threading it through every jump. The cheapness
gate would refuse the shape anyway (`TailCall` is never cheap) — this arm exists
to COUNT it rather than to rely on that.

-}
rewriteCycleDef : Ctx -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteCycleDef ctx def =
    case def of
        TOpt.Def region name body tipe ->
            let
                ( body1, ctx1 ) =
                    rewriteExpr (seeBody { ctx | who = name }) body

                ( body2, ctx2 ) =
                    expandDefinition ctx1 CycleMember (Just region) tipe body1
            in
            ( TOpt.Def region name body2 tipe, ctx2 )

        TOpt.TailDef region name args body tipe tvar ->
            let
                ( body1, ctx1 ) =
                    rewriteExpr (seeBody { ctx | who = name }) body

                ctx2 =
                    if declaredArity tipe > List.length args then
                        bump (\m -> { m | tailDef = m.tailDef + 1 }) ctx1

                    else
                        ctx1
            in
            ( TOpt.TailDef region name args body1 tipe tvar, ctx2 )



-- ============================================================================
-- ====== RULE 1: DEFINITIONS (§2.2) ======
-- ============================================================================


{-| Give a definition body the parameters its type declares and apply it to
them.

`declType` is the DEFINITION NODE's own type — the inferred node type, which is
always present and equals the annotation after solving. `AnnotationsByGlobal` is
deliberately not consulted (§8).

The new parameters take the LAST `n` spine types. When the body is already a
`Function` with `j` parameters they are appended to it and the args are applied
to its BODY (which is where the under-applied call is); when it is not a
function, `j = 0` and the two coincide.

-}
expandDefinition : Ctx -> Site -> Maybe A.Region -> Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
expandDefinition ctx site maybeRegion declType body =
    let
        ( paramTypes, _ ) =
            spine declType

        declared =
            List.length paramTypes

        ( syntactic, inner ) =
            case body of
                TOpt.Function _ ps b _ ->
                    ( List.length ps, b )

                TOpt.TrackedFunction _ ps b _ ->
                    ( List.length ps, b )

                _ ->
                    ( 0, body )

        deficit =
            declared - syntactic
    in
    if isKernelAlias body then
        -- LSS_016: a kernel-ALIAS node (`cons = Elm.Kernel.List.cons`) IS the
        -- kernel value, and `LssInfer.kernelAliasOf` recognises it by EXACTLY
        -- this shape — `Define (VarKernel …)`. η-expanding it to
        -- `\a b -> Elm_Kernel_List_cons a b` hides the alias, splits the `g|`
        -- and `k|` identities, and joins them to a 2-set that kills every
        -- singleton consumer. elm/core is full of these (`List.cons`,
        -- `List.map2`, …), so this arm is load-bearing, not defensive.
        ( body, bump (\m -> { m | kernelAlias = m.kernelAlias + 1 }) ctx )

    else if isCtorAlias ctx.gate body then
        -- A constructor ALIAS (`unsignedInt8 = U8`, elm/bytes). A constructor
        -- is already saturated-call shaped at every use, so expansion buys no
        -- arity; what it DOES do is turn a non-inlinable CAF-alias call into a
        -- one-line function the post-mono inliner replaces by the bare
        -- constructor, which downstream recognisers keyed on the GLOBAL's name
        -- (bytes fusion's `reifyBytesEncodeCall`) no longer see — the
        -- `FusionGlobalMapFnTest` regression when η shipped default-on.
        ( body, bump (\m -> { m | ctorAlias = m.ctorAlias + 1 }) ctx )

    else if declared == 0 then
        ( body, bump (\m -> { m | noSpine = m.noSpine + 1 }) ctx )

    else if deficit <= 0 then
        ( body, bump (\m -> { m | noDeficit = m.noDeficit + 1 }) ctx )

    else
        let
            ctxD =
                bump (countDeficit deficit) ctx
        in
        case peelType deficit (TOpt.typeOf inner) of
            Nothing ->
                ( body, bump (\m -> { m | noPeel = m.noPeel + 1 }) ctxD )

            Just resultType ->
                if not (cheap ctxD.gate inner) then
                    ( body
                    , bump
                        (\m ->
                            { m
                                | notCheap = m.notCheap + 1
                                , cheapSeen = m.cheapSeen + 1
                                , notCheapByName = tally ctxD.who m.notCheapByName
                            }
                        )
                        ctxD
                    )

                else
                    let
                        newTypes =
                            List.drop syntactic paramTypes

                        ( binders, ctx1 ) =
                            freshBinders ctxD newTypes

                        ( newInner, ctx2 ) =
                            apply ctx1 inner (List.map binderRef binders) resultType

                        region =
                            Maybe.withDefault A.zero maybeRegion

                        rebuilt =
                            case body of
                                TOpt.Function lamId ps _ meta ->
                                    TOpt.Function lamId (ps ++ binders) newInner meta

                                TOpt.TrackedFunction lamId ps _ meta ->
                                    TOpt.TrackedFunction lamId
                                        (ps ++ List.map (\( n, t ) -> ( A.At region n, t )) binders)
                                        newInner
                                        meta

                                _ ->
                                    -- A bare value: the wrapper IS the new node,
                                    -- and the body it wraps STAYS IN THE TREE
                                    -- underneath it. Its type is therefore the
                                    -- same type at TWO occurrences, so the
                                    -- wrapper's copy must have its arrow slots
                                    -- cleared: reusing the value verbatim puts
                                    -- one `ArrowId` at both, which is exactly
                                    -- what `Fresh.assertMinted` rejects (and did
                                    -- reject, at `Bytes.Encode.bytes`, before
                                    -- this clear existed).
                                    --
                                    -- The NODE's own meta is untouched, so the
                                    -- signature-source type LSS_006 reads its
                                    -- arrow ordinals off does not move.
                                    let
                                        wrapperMeta =
                                            { tipe = clearArrows (TOpt.typeOf body)
                                            , tvar = (TOpt.metaOf body).tvar
                                            }
                                    in
                                    case maybeRegion of
                                        Just r ->
                                            TOpt.TrackedFunction Nothing
                                                (List.map (\( n, t ) -> ( A.At r n, t )) binders)
                                                newInner
                                                wrapperMeta

                                        Nothing ->
                                            TOpt.Function Nothing binders newInner wrapperMeta

                        ( minted, state1 ) =
                            Fresh.mintNewNode ctx2.state rebuilt
                    in
                    ( minted
                    , bump
                        (\m0 ->
                            let
                                m =
                                    countSite site m0
                            in
                            { m
                                | cheapYes = m.cheapYes + 1
                                , cheapSeen = m.cheapSeen + 1
                                , byName = tally ctx2.who m.byName
                            }
                        )
                        { ctx2 | state = state1 }
                    )


{-| A node whose whole body is a bare kernel reference — the eta-free kernel
alias shape `LssInfer.kernelAliasOf` matches.
-}
isKernelAlias : TOpt.Expr TypeIds.MVarId -> Bool
isKernelAlias body =
    case body of
        TOpt.VarKernel _ _ _ _ _ ->
            True

        _ ->
            False


{-| A node whose whole body is a bare constructor reference — `VarBox` (a
boxed constructor used as a function) or `VarEnum`.
-}
isCtorAlias : Gate -> TOpt.Expr TypeIds.MVarId -> Bool
isCtorAlias gate body =
    case body of
        TOpt.VarBox _ _ _ ->
            True

        TOpt.VarEnum _ _ _ _ ->
            True

        TOpt.VarGlobal _ g _ ->
            CoreDict.member (TOpt.toComparableGlobal g) gate.ctors

        _ ->
            False


{-| Every `TOpt.Ctor` global in the graph, keyed like `buildIndex`.
-}
buildCtorSet : TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String ()
buildCtorSet (TOpt.GlobalGraph nodes _ _ _ _) =
    Dict.foldl
        (\g node acc ->
            case node of
                TOpt.Ctor _ _ _ ->
                    CoreDict.insert (TOpt.toComparableGlobal g) () acc

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


{-| Does this definition have a deficit at all? Used only to COUNT the shapes
v1 declines (Cycle values), so it must not build anything.
-}
hasDeficit : Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Bool
hasDeficit declType body =
    let
        syntactic =
            case body of
                TOpt.Function _ ps _ _ ->
                    List.length ps

                TOpt.TrackedFunction _ ps _ _ ->
                    List.length ps

                _ ->
                    0
    in
    declaredArity declType > syntactic



-- ============================================================================
-- ====== RULE 2: CONTINUATION LAMBDAS (§2.3) ======
-- ============================================================================


{-| Walk a body BOTTOM-UP, η-expanding every lambda literal in argument
position whose expected type declares more parameters than it writes.

Bottom-up is load-bearing. `andThen (\x -> andThen (\xs -> …) (sequence rest)) m`
expands the INNER continuation first, so by the time the outer one is rebuilt
its body is already `andThen (\xs s2 -> …) (sequence rest)` — two of three — and
the `s1` this rule appends merges straight into it. Top-down would have to
revisit.

-}
rewriteExpr : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.List region items meta ->
            mapExprs ctx items (\xs -> TOpt.List region xs meta)

        TOpt.Function lamId params body meta ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.Function lamId params b meta, ctx1 )

        TOpt.TrackedFunction lamId params body meta ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.TrackedFunction lamId params b meta, ctx1 )

        TOpt.Call region func args meta ->
            let
                ( f1, ctx1 ) =
                    rewriteExpr ctx func

                ( args1, ctx2 ) =
                    mapList ctx1 args rewriteExpr

                ( args2, ctx3 ) =
                    expandArgLambdas ctx2 f1 args1
            in
            ( TOpt.Call region f1 args2 meta, ctx3 )

        TOpt.TailCall name args meta ->
            let
                ( newArgs, ctx1 ) =
                    mapList ctx args (\c ( n, e ) -> Tuple.mapFirst (Tuple.pair n) (rewriteExpr c e))
            in
            ( TOpt.TailCall name newArgs meta, ctx1 )

        TOpt.If branches final meta ->
            let
                ( newBranches, ctx1 ) =
                    mapList ctx
                        branches
                        (\c ( cond, then_ ) ->
                            let
                                ( c1, cx1 ) =
                                    rewriteExpr c cond

                                ( t1, cx2 ) =
                                    rewriteExpr cx1 then_
                            in
                            ( ( c1, t1 ), cx2 )
                        )

                ( newFinal, ctx2 ) =
                    rewriteExpr ctx1 final
            in
            ( TOpt.If newBranches newFinal meta, ctx2 )

        TOpt.Let def body meta ->
            let
                ( newDef, ctx1 ) =
                    rewriteDef ctx def

                ( newBody, ctx2 ) =
                    rewriteExpr ctx1 body
            in
            ( TOpt.Let newDef newBody meta, ctx2 )

        TOpt.Destruct destructor body meta ->
            let
                ( newBody, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.Destruct destructor newBody meta, ctx1 )

        TOpt.Case label root decider jumps meta ->
            let
                ( newDecider, ctx1 ) =
                    rewriteDecider ctx decider

                ( newJumps, ctx2 ) =
                    mapList ctx1 jumps (\c ( i, e ) -> Tuple.mapFirst (Tuple.pair i) (rewriteExpr c e))
            in
            ( TOpt.Case label root newDecider newJumps meta, ctx2 )

        TOpt.Access inner region field meta ->
            let
                ( newInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( TOpt.Access newInner region field meta, ctx1 )

        TOpt.Update region record fields meta ->
            let
                ( newRecord, ctx1 ) =
                    rewriteExpr ctx record

                ( newFields, ctx2 ) =
                    Dict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    rewriteExpr c e
                            in
                            ( Dict.insert A.toValue k e1 acc, c1 )
                        )
                        ( Dict.empty, ctx1 )
                        fields
            in
            ( TOpt.Update region newRecord newFields meta, ctx2 )

        TOpt.Record fields meta ->
            let
                ( newFields, ctx1 ) =
                    CoreDict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    rewriteExpr c e
                            in
                            ( CoreDict.insert k e1 acc, c1 )
                        )
                        ( CoreDict.empty, ctx )
                        fields
            in
            ( TOpt.Record newFields meta, ctx1 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( newFields, ctx1 ) =
                    Dict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    rewriteExpr c e
                            in
                            ( Dict.insert A.toValue k e1 acc, c1 )
                        )
                        ( Dict.empty, ctx )
                        fields
            in
            ( TOpt.TrackedRecord region newFields meta, ctx1 )

        TOpt.Tuple region a b rest meta ->
            let
                ( a1, ctx1 ) =
                    rewriteExpr ctx a

                ( b1, ctx2 ) =
                    rewriteExpr ctx1 b

                ( rest1, ctx3 ) =
                    mapList ctx2 rest rewriteExpr
            in
            ( TOpt.Tuple region a1 b1 rest1 meta, ctx3 )

        _ ->
            ( expr, ctx )


rewriteDef : Ctx -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef ctx def =
    case def of
        TOpt.Def region name bound tipe ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx bound
            in
            ( TOpt.Def region name b tipe, ctx1 )

        TOpt.TailDef region name args body tipe tvar ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.TailDef region name args b tipe tvar, ctx1 )


rewriteDecider : Ctx -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
rewriteDecider ctx decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            Tuple.mapFirst (TOpt.Leaf << TOpt.Inline) (rewriteExpr ctx e)

        TOpt.Leaf (TOpt.Jump n) ->
            ( TOpt.Leaf (TOpt.Jump n), ctx )

        TOpt.Chain tests ok ko ->
            let
                ( ok1, ctx1 ) =
                    rewriteDecider ctx ok

                ( ko1, ctx2 ) =
                    rewriteDecider ctx1 ko
            in
            ( TOpt.Chain tests ok1 ko1, ctx2 )

        TOpt.FanOut path branches fallback ->
            let
                ( newBranches, ctx1 ) =
                    mapList ctx branches (\c ( t, d ) -> Tuple.mapFirst (Tuple.pair t) (rewriteDecider c d))

                ( newFallback, ctx2 ) =
                    rewriteDecider ctx1 fallback
            in
            ( TOpt.FanOut path newBranches newFallback, ctx2 )


{-| The continuation rule. `expected` is the callee's OWN parameter type at this
position, aliases expanded: `andThen`'s first parameter `a -> IO b` expands to
`a -> State -> ( State, b )`, arity 2, so a one-parameter callback has a deficit
of 1.

The lambda's `SrcLambdaId` is KEPT (§2.3): it is the same source lambda with
more parameters, no member exists for it yet, and the id stays the future member
key. Only what is BUILT around it is minted.

Over-applied calls have argument positions past the callee's spine; those index
to `Nothing` and are left alone.

**Here the TYPE's full arrow spine is the right answer**, unlike in `calleeArity`.
Adding binders to a lambda is η, which is type-safe at any depth: if the expected
type's result is itself a function, the callback really does take those arguments
too. What `calleeArity` must not do is change a CALL's staging, which is a
different question with a different answer.

Only lambda LITERALS are touched. A PAP in argument position (`applyI (add 5)`)
is deliberately left alone — expanding those MEASURED negative, 17 → 12 stamps,
because LSS\_040 already stamps `p|` members and an `l|` lands in `g1absentl`.

-}
expandArgLambdas : Ctx -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> ( List (TOpt.Expr TypeIds.MVarId), Ctx )
expandArgLambdas ctx func args =
    case calleeName func of
        Nothing ->
            ( args, ctx )

        Just callee ->
            let
                ( expectedTypes, _ ) =
                    spine (TOpt.typeOf func)
            in
            List.foldl
                (\( index, arg ) ( acc, c ) ->
                    let
                        ( arg1, c1 ) =
                            case indexOf index expectedTypes of
                                Just expected ->
                                    expandOneLambda c callee expected arg

                                Nothing ->
                                    ( arg, c )
                    in
                    ( arg1 :: acc, c1 )
                )
                ( [], ctx )
                (List.indexedMap Tuple.pair args)
                |> Tuple.mapFirst List.reverse


expandOneLambda : Ctx -> String -> Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
expandOneLambda ctx callee expected arg =
    let
        maybeLambda =
            case arg of
                TOpt.Function lamId ps b meta ->
                    Just ( List.length ps, b, \newPs newBody -> TOpt.Function lamId (ps ++ newPs) newBody meta )

                TOpt.TrackedFunction lamId ps b meta ->
                    Just
                        ( List.length ps
                        , b
                        , \newPs newBody ->
                            TOpt.TrackedFunction lamId
                                (ps ++ List.map (\( n, t ) -> ( A.At (locatedRegion ps) n, t )) newPs)
                                newBody
                                meta
                        )

                _ ->
                    Nothing
    in
    case maybeLambda of
        Nothing ->
            ( arg, ctx )

        Just ( written, body, rebuild ) ->
            let
                ( expectedParams, expectedResult ) =
                    spine expected

                deficit =
                    List.length expectedParams - written
            in
            if deficit <= 0 then
                ( arg, ctx )

            else
                let
                    ctxD =
                        bump (countDeficit deficit) ctx
                in
                if not (cheap ctxD.gate body) then
                    ( arg
                    , bump
                        (\m ->
                            { m
                                | notCheap = m.notCheap + 1
                                , cheapSeen = m.cheapSeen + 1
                                , notCheapByName = tally callee m.notCheapByName
                            }
                        )
                        ctxD
                    )

                else
                    let
                        ( binders, ctx1 ) =
                            freshBinders ctxD (List.drop written expectedParams)

                        ( newBody, ctx2 ) =
                            apply ctx1 body (List.map binderRef binders) (clearArrows expectedResult)

                        ( minted, state1 ) =
                            Fresh.mintNewNode ctx2.state (rebuild binders newBody)
                    in
                    ( minted
                    , bump
                        (\m ->
                            { m
                                | conts = m.conts + 1
                                , cheapYes = m.cheapYes + 1
                                , cheapSeen = m.cheapSeen + 1
                                , byName = tally callee m.byName
                            }
                        )
                        { ctx2 | state = state1 }
                    )



-- ============================================================================
-- ====== NORMALISING THE NEW APPLICATION (§2.4) ======
-- ============================================================================


{-| Apply `e` to `args` (always plain `VarLocal` references to the freshly bound
η parameters) and normalise, so the arguments reach the call that was under
applied instead of stacking an outer application on top of the PAP it built.

  - MERGE into `Call (VarGlobal|VarCycle) as` while the callee's own arity has
    room (`calleeArity` — the GRAPH's parameter count, not the type's arrow
    count; kernels have no graph node and are not merged into). This is the step that pays: `Call andThen [k, tick]`
    plus `[s0]` collapses to the three-argument call, where `f` is a lambda
    literal and `ma` a global — two singleton members instead of a PAP applied
    through `generic_apply`. Past the arity the call is saturated exactly and
    the remainder becomes an outer `Call` (mono handles over-application; LSS
    wants the exact call).
  - PUSH through `Let`/`Destruct`, into every `If` branch, and into BOTH the
    decider's `Inline` choices and every `jumps` entry of a `Case`. Missing
    `jumps` would leave a shared branch holding the un-applied PAP while its
    siblings are saturated (R8). Duplicating a VARIABLE reference is free, which
    is why the arguments are required to be variables.
  - BETA a lambda head by LET-BINDING the arguments, never by substitution —
    the same discipline `InlineSimplify.doInline` uses.

`resultType` is the type after ALL of `args` have been applied; every rebuilt
node in the push rules has exactly that type, because a `Let`/`Case`/`If` has
the type of its branches.

-}
apply : Ctx -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
apply ctx e args resultType =
    if List.isEmpty args then
        ( e, ctx )

    else
        let
            newMeta =
                { tipe = resultType, tvar = Nothing }
        in
        case e of
            TOpt.Call region func callArgs _ ->
                case calleeArity ctx func of
                    Just arity ->
                        let
                            have =
                                List.length callArgs

                            want =
                                have + List.length args
                        in
                        if want <= arity then
                            ( TOpt.Call region func (callArgs ++ args) newMeta
                            , bump (\m -> { m | merged = m.merged + 1 }) ctx
                            )

                        else
                            case ( arity > have, peelType arity (TOpt.typeOf func) ) of
                                ( True, Just innerType ) ->
                                    -- More arguments than the callee's first
                                    -- stage takes: saturate it EXACTLY and make
                                    -- the remainder an outer application. Mono
                                    -- handles over-application either way, but
                                    -- LSS wants the exact call, and the inner
                                    -- node's type has to be the callee's type
                                    -- peeled by its own arity — never
                                    -- `resultType`, which is the type after ALL
                                    -- the arguments.
                                    let
                                        take =
                                            arity - have

                                        inner =
                                            TOpt.Call region
                                                func
                                                (callArgs ++ List.take take args)
                                                { tipe = innerType, tvar = Nothing }
                                    in
                                    ( TOpt.Call region inner (List.drop take args) newMeta
                                    , bump (\m -> { m | merged = m.merged + 1 }) ctx
                                    )

                                _ ->
                                    -- Already saturated, or the callee's type
                                    -- has fewer arrows than its arity claims.
                                    -- Stack an outer application rather than
                                    -- emit something mistyped.
                                    ( TOpt.Call region e args newMeta, ctx )

                    Nothing ->
                        ( TOpt.Call region e args newMeta, ctx )

            TOpt.Function _ params body _ ->
                betaLambda ctx params body args resultType

            TOpt.TrackedFunction _ params body _ ->
                betaLambda ctx (List.map (\( n, t ) -> ( A.toValue n, t )) params) body args resultType

            TOpt.Let def body _ ->
                let
                    ( newBody, ctx1 ) =
                        apply ctx body args resultType
                in
                ( TOpt.Let def newBody newMeta, bump (\m -> { m | pushed = m.pushed + 1 }) ctx1 )

            TOpt.Destruct destructor body _ ->
                let
                    ( newBody, ctx1 ) =
                        apply ctx body args resultType
                in
                ( TOpt.Destruct destructor newBody newMeta, bump (\m -> { m | pushed = m.pushed + 1 }) ctx1 )

            TOpt.If branches final _ ->
                let
                    ( newBranches, ctx1 ) =
                        mapList ctx
                            branches
                            (\c ( cond, then_ ) ->
                                Tuple.mapFirst (Tuple.pair cond) (apply c then_ args resultType)
                            )

                    ( newFinal, ctx2 ) =
                        apply ctx1 final args resultType
                in
                ( TOpt.If newBranches newFinal newMeta, bump (\m -> { m | pushed = m.pushed + 1 }) ctx2 )

            TOpt.Case label root decider jumps _ ->
                let
                    ( newDecider, ctx1 ) =
                        applyDecider ctx decider args resultType

                    ( newJumps, ctx2 ) =
                        mapList ctx1 jumps (\c ( i, j ) -> Tuple.mapFirst (Tuple.pair i) (apply c j args resultType))
                in
                ( TOpt.Case label root newDecider newJumps newMeta
                , bump (\m -> { m | pushed = m.pushed + 1 }) ctx2
                )

            _ ->
                ( TOpt.Call (regionOf e) e args newMeta, ctx )


applyDecider : Ctx -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
applyDecider ctx decider args resultType =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            Tuple.mapFirst (TOpt.Leaf << TOpt.Inline) (apply ctx e args resultType)

        TOpt.Leaf (TOpt.Jump n) ->
            ( TOpt.Leaf (TOpt.Jump n), ctx )

        TOpt.Chain tests ok ko ->
            let
                ( ok1, ctx1 ) =
                    applyDecider ctx ok args resultType

                ( ko1, ctx2 ) =
                    applyDecider ctx1 ko args resultType
            in
            ( TOpt.Chain tests ok1 ko1, ctx2 )

        TOpt.FanOut path branches fallback ->
            let
                ( newBranches, ctx1 ) =
                    mapList ctx branches (\c ( t, d ) -> Tuple.mapFirst (Tuple.pair t) (applyDecider c d args resultType))

                ( newFallback, ctx2 ) =
                    applyDecider ctx1 fallback args resultType
            in
            ( TOpt.FanOut path newBranches newFallback, ctx2 )


{-| Beta by LET-BINDING. The arguments are `_eta<n>` variable references and the
binders are the lambda's own parameter names, so there is no capture and no
scope tracking: `_eta<n>` cannot be written in Elm source and is minted from one
per-pass counter, so it can be shadowed by nothing.

Fewer arguments than parameters cannot arise from either rule (a lambda in
argument position is expanded, not applied), so that case falls back to a plain
`Call` rather than re-arranging the lambda.

-}
betaLambda : Ctx -> List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
betaLambda ctx params body args resultType =
    let
        arity =
            List.length params
    in
    if List.length args < arity then
        ( TOpt.Call A.zero
            (TOpt.Function Nothing params body (TOpt.metaOf body))
            args
            { tipe = resultType, tvar = Nothing }
        , ctx
        )

    else
        let
            ( newBody, ctx1 ) =
                apply ctx body (List.drop arity args) resultType

            wrapped =
                List.foldr
                    (\( ( pname, ptype ), arg ) acc ->
                        -- Same identity rule as the definition wrapper: the
                        -- `Let` and the body it wraps are two occurrences of one
                        -- type, so the `Let`'s copy is cleared and re-minted.
                        TOpt.Let (TOpt.Def A.zero pname arg ptype)
                            acc
                            { tipe = clearArrows (TOpt.typeOf acc)
                            , tvar = (TOpt.metaOf acc).tvar
                            }
                    )
                    newBody
                    (List.map2 Tuple.pair params (List.take arity args))
        in
        ( wrapped, bump (\m -> { m | pushed = m.pushed + 1 }) ctx1 )



-- ============================================================================
-- ====== THE CHEAPNESS GATE (§2.5) ======
-- ============================================================================


{-| Is everything LEFT of the new binders nothing but construction?

η-expansion moves that work from once — a memoised CAF slot
(`Generate/MLIR/Expr.elm:707`) or one closure creation — to once per call. For
an IO action the CAF's VALUE was a PAP, so caching it bought nothing and the
move is free; for `let big = expensive in \s -> …` it is a per-call recomputation
of `big`. This predicate is the whole difference.

What it PERMITS, deliberately: a `crash` or `Debug.log` reachable only through a
PAP that a cheap body builds fires at application time instead of at CAF init —
the same observable-ordering class `arityRaise` accepts (H6.2). Nothing else is
observable in Elm.

`Debug.log` is a `VarDebug` call, which no arm admits, so a body containing one
is refused. That is also the ordering pin (fixture F8).

-}
cheap : Gate -> TOpt.Expr TypeIds.MVarId -> Bool
cheap ctx expr =
    case expr of
        TOpt.Bool _ _ _ ->
            True

        TOpt.Chr _ _ _ ->
            True

        TOpt.Str _ _ _ ->
            True

        TOpt.Int _ _ _ ->
            True

        TOpt.Float _ _ _ ->
            True

        TOpt.VarLocal _ _ ->
            True

        TOpt.TrackedVarLocal _ _ _ ->
            True

        TOpt.VarGlobal _ _ _ ->
            True

        TOpt.VarEnum _ _ _ _ ->
            True

        TOpt.VarBox _ _ _ ->
            True

        TOpt.VarCycle _ _ _ _ ->
            True

        TOpt.VarKernel _ _ _ _ _ ->
            True

        TOpt.Unit _ ->
            True

        TOpt.Accessor _ _ _ ->
            True

        TOpt.Function _ _ _ _ ->
            True

        TOpt.TrackedFunction _ _ _ _ ->
            True

        TOpt.List _ items _ ->
            List.all (cheap ctx) items

        TOpt.Tuple _ a b rest _ ->
            cheap ctx a && cheap ctx b && List.all (cheap ctx) rest

        TOpt.Record fields _ ->
            List.all (cheap ctx) (CoreDict.values fields)

        TOpt.TrackedRecord _ fields _ ->
            List.all (cheap ctx) (Dict.values fields)

        TOpt.Update _ record fields _ ->
            cheap ctx record && List.all (cheap ctx) (Dict.values fields)

        TOpt.Access inner _ _ _ ->
            cheap ctx inner

        TOpt.Let def body _ ->
            cheapDef ctx def && cheap ctx body

        TOpt.Destruct _ body _ ->
            cheap ctx body

        TOpt.If branches final _ ->
            List.all (\( c, t ) -> cheap ctx c && cheap ctx t) branches && cheap ctx final

        TOpt.Case _ _ decider jumps _ ->
            cheapDecider ctx decider && List.all (\( _, e ) -> cheap ctx e) jumps

        TOpt.Call _ func args _ ->
            List.all (cheap ctx) args && cheapCallee ctx func (List.length args)

        _ ->
            -- TailCall, Shader, VarDebug, and any head this pass does not
            -- reason about. A `TailCall` in particular is why `TailDef` needs
            -- no separate refusal inside a body.
            False


{-| A call is cheap when it BUILDS rather than works: an under-applied call to a
known global is a PAP, and a saturated one is cheap only if the callee's body is
under `inline.etaThreshold`. A kernel is cheap only in the `gcLeaf` cost class.

The `inline` cost class of `MonoInlineSimplify.kernelCallCost` cannot be read
here: `KernelIntrinsics.kernelIntrinsic` keys on MONO types, which do not exist yet.
`CGcLeaf` is the pre-mono approximation and it is conservative in the safe
direction — it declines sites, never admits extra ones.

-}
cheapCallee : Gate -> TOpt.Expr TypeIds.MVarId -> Int -> Bool
cheapCallee ctx func argCount =
    case func of
        TOpt.VarKernel _ _ home name _ ->
            case KernelFacts.lookup ( home, name ) of
                Just facts ->
                    KernelFacts.costClass facts == KernelFacts.CGcLeaf

                Nothing ->
                    False

        TOpt.VarGlobal _ g _ ->
            cheapGlobalCall ctx (TOpt.toComparableGlobal g) argCount

        TOpt.VarCycle _ home name _ ->
            cheapGlobalCall ctx (TOpt.toComparableGlobal (TOpt.Global home name)) argCount

        _ ->
            False


cheapGlobalCall : Gate -> String -> Int -> Bool
cheapGlobalCall ctx key argCount =
    case CoreDict.get key ctx.arity of
        Nothing ->
            -- No node in the graph: nothing here knows whether this call does
            -- work or builds a PAP. Refuse.
            False

        Just arity ->
            if arity <= 0 then
                -- A bare-value body. Only a kernel ALIAS is judged here, by the
                -- cost of the value it evaluates to — `x :: xs` reaches
                -- `List.cons` this way and must stay cheap. Anything else with
                -- no parameters is refused; see `Gate.aliasCost`.
                case CoreDict.get key ctx.aliasCost of
                    Just c ->
                        c <= ctx.threshold

                    Nothing ->
                        False

            else if argCount < arity then
                -- A PAP: it builds, it does no work.
                True

            else if argCount == arity then
                Maybe.withDefault (ctx.threshold + 1) (CoreDict.get key ctx.cost) <= ctx.threshold

            else
                False


cheapDef : Gate -> TOpt.Def TypeIds.MVarId -> Bool
cheapDef ctx def =
    case def of
        TOpt.Def _ _ bound _ ->
            cheap ctx bound

        TOpt.TailDef _ _ _ body _ _ ->
            cheap ctx body


cheapDecider : Gate -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> Bool
cheapDecider ctx decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            cheap ctx e

        TOpt.Leaf (TOpt.Jump _) ->
            True

        TOpt.Chain _ ok ko ->
            cheapDecider ctx ok && cheapDecider ctx ko

        TOpt.FanOut _ branches fallback ->
            List.all (\( _, d ) -> cheapDecider ctx d) branches && cheapDecider ctx fallback



-- ============================================================================
-- ====== BODY COST INDEX ======
-- ============================================================================


{-| What the merge rule and the cheapness gate need to know about a callee:
where its first stage ENDS (`arity`, its syntactic parameter count) and how
much work its body is (`cost`).

Both are read from the graph, once, before anything is rewritten. Neither can be
read off a type: an arrow chain counts the arrows of its RESULT too, so a
combinator's type says six where the definition writes three, and a saturated
call would be merged into as if it were a partial one.

-}
type alias Callee =
    { arity : Int
    , cost : Int
    }


{-| Everything the cheapness gate and the merge rule consult, and nothing else,
so the "will this definition be expanded?" walk can run BEFORE any `Ctx` exists.

`arity` is where the subtlety lives. It is a per-global parameter count, and it
is used for TWO questions that want the same answer: "is this call a PAP or does
it do work?" (the gate) and "how many arguments may one flat call carry?" (the
merge). Both want the arity the callee has AFTER this pass, which is circular —
the pass decides it. `run` breaks the circle in one step:

  - `arity0` = the SYNTACTIC counts read off the graph;
  - `arity1` = `buildPostArity` under `arity0` — for each definition, its
    DECLARED arity if the pass will expand it, else its syntactic count;
  - the rewrite uses `arity1` for both questions.

That is sound in the direction that matters. `cheap` is monotone in `arity` (a
larger arity turns saturated calls into PAPs, which only ADDS verdicts), so
`arity0 ≤ arity1` means every definition `arity1` predicts will expand really
does expand under `arity1`. The merge therefore never outruns the callee's real
first stage — the failure that miscompiled `CombinatorTest` — while a definition
`arity1` missed only costs an unmerged call.

One step and not a fixed point on purpose: a second round could only add
expansions, and an under-estimate is free.

-}
type alias Gate =
    { threshold : Int
    , arity : CoreDict.Dict String Int
    , cost : CoreDict.Dict String Int

    -- Body cost of the KERNEL-ALIAS globals only (`cons = Elm.Kernel.List.cons`).
    -- Their graph arity is 0 — the body is a bare value — which would make the
    -- gate refuse every call to one, including `x :: xs`. That refusal cost a
    -- real continuation expansion in the `SeqM` probe (`conts` 2 -> 1), and
    -- with it the line-for-line match against the hand rewrite.
    --
    -- Only aliases, and not bare-value definitions generally, because this map
    -- must read the SAME in both rounds. A kernel alias is refused by §2.6 in
    -- every round, so its arity is 0 in both; a bare-value DEFINITION's arity
    -- grows from 0 to its declared arity between them, and a rule that answered
    -- "cheap" at arity 0 could answer "not cheap" at the larger one — which
    -- breaks the monotonicity `Gate.arity`'s soundness argument rests on.
    , aliasCost : CoreDict.Dict String Int

    -- Constructor globals (`TOpt.Ctor` nodes): a definition whose whole body is
    -- a bare reference to one is a constructor ALIAS and is never expanded.
    , ctors : CoreDict.Dict String ()
    }


{-| Per-global `Callee`, `toComparableGlobal`-keyed.

Cycle members are keyed under their OWN `Global` (the `Link` node the graph
holds for each of them points at the cycle, which is keyed under the joined
name), so `sequence` and every recursive `unify`-style callee is found by the
same lookup as a plain `Define`.

`cost` duplicates `InlineSimplify.cost`'s arithmetic rather than importing it:
that module exposes only `optimize`, and this pass must not depend on the
inliner having run.

-}
buildIndex : TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String Callee
buildIndex (TOpt.GlobalGraph nodes _ _ _ _) =
    Dict.foldl
        (\g node acc ->
            case node of
                TOpt.Define e _ _ ->
                    CoreDict.insert (TOpt.toComparableGlobal g) (calleeOfBody e) acc

                TOpt.TrackedDefine _ e _ _ ->
                    CoreDict.insert (TOpt.toComparableGlobal g) (calleeOfBody e) acc

                TOpt.Ctor _ arity _ ->
                    -- A constructor's arity is stated outright, and its "body"
                    -- is construction: always under any threshold.
                    CoreDict.insert (TOpt.toComparableGlobal g) { arity = arity, cost = 1 } acc

                TOpt.Cycle _ _ funcDefs _ ->
                    let
                        home =
                            case g of
                                TOpt.Global h _ ->
                                    h
                    in
                    List.foldl
                        (\def inner ->
                            case def of
                                TOpt.Def _ name body _ ->
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        (calleeOfBody body)
                                        inner

                                TOpt.TailDef _ name args body _ _ ->
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        { arity = List.length args, cost = cost body }
                                        inner
                        )
                        acc
                        funcDefs

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


{-| Per-global arity as this pass will LEAVE it.

A definition the pass expands ends up with the declared arity of its own node
type; everything else keeps the syntactic count. Deciding this needs a walk
that mirrors `expandDefinition`'s guards WITHOUT building anything, so the
answer is available before the first rewrite and does not depend on the order
nodes are visited in.

The `cheap` test here reads whatever `Gate` it is handed; `run` hands it the
round-0 (syntactic) arities. See `Gate` for why one round is enough and why the
result can only UNDER-estimate.

Note the callee's OWN node type is what is peeled, never a call site's
instantiated one: `s bf uf x`'s own type is `(a -> b -> c) -> (a -> b) -> a -> c`
whose spine is 3, while at `b = s (k s) k` the instantiation makes `c` an arrow
and the spine 6. That difference is the miscompile in `calleeArity`'s comment.

-}
buildPostArity : Gate -> TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String Int
buildPostArity gate (TOpt.GlobalGraph nodes _ _ _ _) =
    let
        arityAfter ctx declType body =
            let
                base =
                    syntacticArityOf body
            in
            if willExpand ctx declType body then
                declaredArity declType

            else
                base
    in
    Dict.foldl
        (\g node acc ->
            let
                key =
                    TOpt.toComparableGlobal g

                ctx =
                    gate
            in
            case node of
                TOpt.Define e _ meta ->
                    CoreDict.insert key (arityAfter ctx meta.tipe e) acc

                TOpt.TrackedDefine _ e _ meta ->
                    CoreDict.insert key (arityAfter ctx meta.tipe e) acc

                TOpt.Ctor _ arity _ ->
                    CoreDict.insert key arity acc

                TOpt.Cycle _ _ funcDefs _ ->
                    let
                        home =
                            case g of
                                TOpt.Global h _ ->
                                    h
                    in
                    List.foldl
                        (\def inner ->
                            case def of
                                TOpt.Def _ name body tipe ->
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        (arityAfter ctx tipe body)
                                        inner

                                TOpt.TailDef _ name args _ _ _ ->
                                    -- Out of scope in v1, so its arity does not move.
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        (List.length args)
                                        inner
                        )
                        acc
                        funcDefs

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


{-| `expandDefinition`'s guards, decided without building. Kept adjacent to it
so the two cannot drift: if one grows a refusal, so must the other.
-}
willExpand : Gate -> Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Bool
willExpand ctx declType body =
    let
        declared =
            declaredArity declType

        syntactic =
            syntacticArityOf body

        inner =
            innerBodyOf body
    in
    not (isKernelAlias body)
        && (declared > 0)
        && (declared - syntactic > 0)
        && (peelType (declared - syntactic) (TOpt.typeOf inner) /= Nothing)
        && cheap ctx inner


syntacticArityOf : TOpt.Expr TypeIds.MVarId -> Int
syntacticArityOf body =
    case body of
        TOpt.Function _ ps _ _ ->
            List.length ps

        TOpt.TrackedFunction _ ps _ _ ->
            List.length ps

        _ ->
            0


innerBodyOf : TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId
innerBodyOf body =
    case body of
        TOpt.Function _ _ b _ ->
            b

        TOpt.TrackedFunction _ _ b _ ->
            b

        _ ->
            body


{-| Body cost of every kernel-ALIAS global — the ones §2.6 refuses to expand and
whose graph arity is therefore 0 forever. See `Gate.aliasCost`.
-}
buildAliasCost : TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String Int
buildAliasCost (TOpt.GlobalGraph nodes _ _ _ _) =
    Dict.foldl
        (\g node acc ->
            case node of
                TOpt.Define e _ _ ->
                    if isKernelAlias e then
                        CoreDict.insert (TOpt.toComparableGlobal g) (cost e) acc

                    else
                        acc

                TOpt.TrackedDefine _ e _ _ ->
                    if isKernelAlias e then
                        CoreDict.insert (TOpt.toComparableGlobal g) (cost e) acc

                    else
                        acc

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


calleeOfBody : TOpt.Expr TypeIds.MVarId -> Callee
calleeOfBody expr =
    case expr of
        TOpt.Function _ ps body _ ->
            { arity = List.length ps, cost = cost body }

        TOpt.TrackedFunction _ ps body _ ->
            { arity = List.length ps, cost = cost body }

        _ ->
            -- A bare value. Arity 0 refuses the merge outright, which is right:
            -- nothing here knows how many arguments the value it evaluates to
            -- will accept.
            { arity = 0, cost = cost expr }


cost : TOpt.Expr TypeIds.MVarId -> Int
cost expr =
    case expr of
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
            3 + Dict.foldl (\_ e a -> a + cost e) (cost inner) fields

        TOpt.Record fields _ ->
            3 + CoreDict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.TrackedRecord _ fields _ ->
            3 + Dict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.Tuple _ a b rest _ ->
            3 + cost a + cost b + sumBy cost rest

        _ ->
            1


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
-- ====== TYPES: DECLARED ARITY FROM ALIAS STRUCTURE (§2.1) ======
-- ============================================================================


{-| The parameter types of the fully expanded arrow chain, and what is left
after them.

Aliases are expanded because that is the WHOLE POINT: `IO a` is
`State -> ( State, a )` and declares one parameter, which no syntactic reading
of `prog : IO Int` can see. `Holey` bodies substitute the alias's arguments for
its parameters — alias parameters are alias-LOCAL and matched by position, the
same rule `TypeSubst.applySubstPureI` and `InlineSimplify.expandAlias` follow.

The arity is read off STRUCTURE, so it is immune to the pre-mono type-precision
limit (Fact 2): `a -> b` with `b` a variable has arity exactly 1, and a bare
variable has arity 0 and is declined as `noSpine` (R3).

Elm forbids recursive aliases, so this terminates.

-}
spine : Can.Type TypeIds.MVarId -> ( List (Can.Type TypeIds.MVarId), Can.Type TypeIds.MVarId )
spine tipe =
    case unAlias tipe of
        Can.TLambda _ from to ->
            let
                ( rest, residual ) =
                    spine to
            in
            ( from :: rest, residual )

        other ->
            ( [], other )


declaredArity : Can.Type TypeIds.MVarId -> Int
declaredArity tipe =
    List.length (Tuple.first (spine tipe))


{-| Expand alias layers until the head is not an alias.
-}
unAlias : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
unAlias tipe =
    case tipe of
        Can.TAlias _ _ args (Can.Holey body) ->
            unAlias
                (substTypeVars
                    (CoreDict.fromList (List.map (\( pn, t ) -> ( Id.toComparable pn, t )) args))
                    body
                )

        Can.TAlias _ _ _ (Can.Filled body) ->
            unAlias body

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


{-| The result type after applying `n` arguments, or `Nothing` when the type
does not have that many arrows once aliases are expanded.
-}
peelType : Int -> Can.Type TypeIds.MVarId -> Maybe (Can.Type TypeIds.MVarId)
peelType n tipe =
    if n <= 0 then
        Just (clearArrows tipe)

    else
        case unAlias tipe of
            Can.TLambda _ _ to ->
                peelType (n - 1) to

            _ ->
                Nothing


{-| Strip every arrow slot, so `Fresh.mintNewNode` assigns a fresh `ArrowId` to
each one.

An `ArrowId` names one syntactic arrow OCCURRENCE (LSS\_027). A type this pass
puts at a NEW position — a new parameter's declared type, a rebuilt `Call`'s
result type — is a new occurrence, so re-minting is the FAITHFUL choice, not a
loss: keeping the id would place one identity at two occurrences, which is the
shape `Fresh.assertMinted` rejects and the shape AbiCloning would read as two
interchangeable instances.

-}
clearArrows : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
clearArrows tipe =
    case tipe of
        Can.TVar _ ->
            tipe

        Can.TLambda _ a b ->
            Can.TLambda Can.noArrow (clearArrows a) (clearArrows b)

        Can.TType h n args ->
            Can.TType h n (List.map clearArrows args)

        Can.TRecord fields ext ->
            Can.TRecord (CoreDict.map (\_ (Can.FieldType i t) -> Can.FieldType i (clearArrows t)) fields) ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b rest ->
            Can.TTuple (clearArrows a) (clearArrows b) (List.map clearArrows rest)

        Can.TAlias h n args real ->
            Can.TAlias h
                n
                (List.map (\( pn, t ) -> ( pn, clearArrows t )) args)
                (case real of
                    Can.Holey t ->
                        Can.Holey (clearArrows t)

                    Can.Filled t ->
                        Can.Filled (clearArrows t)
                )



-- ============================================================================
-- ====== SMALL HELPERS ======
-- ============================================================================


{-| How many arguments one flat call to this callee may carry.

**Not the arrow count of its type.** An arrow chain counts the arrows of the
RESULT too, and a combinator whose result is itself a function has far more of
them than it has parameters: at `b = s (k s) k`, `s`'s instantiated type has six
arrows while `s bf uf x` takes three. Merging to the type's count produced a
six-argument call to a three-parameter global and MISCOMPILED
`test/elm/src/CombinatorTest.elm` — `b square inc 4` printed 64 instead of 25.

So the arity is the callee's parameter count AS THIS PASS WILL LEAVE IT
(`Gate.arity` — the syntactic count, or the DECLARED arity for a definition
the pass expands; see `Gate` for how that is computed without circularity),
capped by the number of arrows the site's own reference type
actually has. The cap matters because the merge must never outrun the type it is
building a result type from; the graph count matters because it is the only
thing that says where the callee's first stage ENDS.

The POST-pass count and not the pre-expansion one, because the two differ exactly at
the definitions this transform is FOR: `sequence` is a Cycle member written at
alias arity, so the pre-expansion index says 1 while the expanded definition
takes 2, and merging to 1 leaves `sequence rest` a PAP that the new state
argument then applies generically — the dispatch this pass exists to remove,
reintroduced against the pass's own output. The unit suite's R8 fixture caught
it as an unsaturated branch.

-}
calleeArity : Ctx -> TOpt.Expr TypeIds.MVarId -> Maybe Int
calleeArity ctx func =
    let
        capped key meta =
            case CoreDict.get key ctx.gate.arity of
                Just arity ->
                    if arity <= 0 then
                        Nothing

                    else
                        Just (min arity (declaredArity meta.tipe))

                Nothing ->
                    Nothing
    in
    case func of
        TOpt.VarGlobal _ g meta ->
            capped (TOpt.toComparableGlobal g) meta

        TOpt.VarCycle _ home name meta ->
            capped (TOpt.toComparableGlobal (TOpt.Global home name)) meta

        _ ->
            -- Kernels included, deliberately. A kernel has no graph node, so
            -- nothing here knows where its first stage ends, and the same
            -- result-arrow over-count that broke the combinators would apply.
            -- Merging into a kernel call is not what this plan is for.
            Nothing


calleeName : TOpt.Expr TypeIds.MVarId -> Maybe String
calleeName func =
    case func of
        TOpt.VarGlobal _ g _ ->
            Just (TOpt.toComparableGlobal g)

        TOpt.VarCycle _ home name _ ->
            Just (TOpt.toComparableGlobal (TOpt.Global home name))

        TOpt.VarKernel _ _ home name _ ->
            Just (home ++ "." ++ name)

        _ ->
            Nothing


{-| Fresh `_eta<n>` binders for the given types, with the types' arrow slots
cleared for `mintNewNode`.

Elm identifiers cannot begin with `_`, and the counter is per-pass, so these
names cannot collide with a source binder or with each other and no scope
tracking is needed.

-}
freshBinders : Ctx -> List (Can.Type TypeIds.MVarId) -> ( List ( Name, Can.Type TypeIds.MVarId ), Ctx )
freshBinders ctx types =
    let
        ( acc, next ) =
            List.foldl
                (\t ( out, n ) ->
                    ( ( "_eta" ++ String.fromInt n, clearArrows t ) :: out, n + 1 )
                )
                ( [], ctx.fresh )
                types
    in
    ( List.reverse acc, { ctx | fresh = next } )


binderRef : ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId
binderRef ( name, tipe ) =
    TOpt.VarLocal name { tipe = tipe, tvar = Nothing }


regionOf : TOpt.Expr TypeIds.MVarId -> A.Region
regionOf expr =
    case expr of
        TOpt.Call region _ _ _ ->
            region

        TOpt.VarGlobal region _ _ ->
            region

        TOpt.VarCycle region _ _ _ ->
            region

        TOpt.TrackedVarLocal region _ _ ->
            region

        _ ->
            A.zero


locatedRegion : List ( A.Located Name, Can.Type TypeIds.MVarId ) -> A.Region
locatedRegion params =
    case params of
        ( located, _ ) :: _ ->
            A.toRegion located

        [] ->
            A.zero


indexOf : Int -> List a -> Maybe a
indexOf i xs =
    List.head (List.drop i xs)


mapList : Ctx -> List a -> (Ctx -> a -> ( b, Ctx )) -> ( List b, Ctx )
mapList ctx xs f =
    let
        ( acc, ctx1 ) =
            List.foldl
                (\x ( out, c ) ->
                    let
                        ( y, c1 ) =
                            f c x
                    in
                    ( y :: out, c1 )
                )
                ( [], ctx )
                xs
    in
    ( List.reverse acc, ctx1 )


mapExprs : Ctx -> List (TOpt.Expr TypeIds.MVarId) -> (List (TOpt.Expr TypeIds.MVarId) -> TOpt.Expr TypeIds.MVarId) -> ( TOpt.Expr TypeIds.MVarId, Ctx )
mapExprs ctx xs rebuild =
    Tuple.mapFirst rebuild (mapList ctx xs rewriteExpr)


bump : (Metrics -> Metrics) -> Ctx -> Ctx
bump f ctx =
    { ctx | metrics = f ctx.metrics }


seeBody : Ctx -> Ctx
seeBody =
    bump (\m -> { m | bodiesSeen = m.bodiesSeen + 1 })


countDeficit : Int -> Metrics -> Metrics
countDeficit n m =
    if n == 1 then
        { m | deficit1 = m.deficit1 + 1 }

    else if n == 2 then
        { m | deficit2 = m.deficit2 + 1 }

    else
        { m | deficit3 = m.deficit3 + 1 }


tally : String -> CoreDict.Dict String Int -> CoreDict.Dict String Int
tally key d =
    CoreDict.update key (\v -> Just (1 + Maybe.withDefault 0 v)) d


{-| Which counter a definition-rule expansion lands in. A Cycle member is
tallied apart because `sequence` and every recursive `unify`-style caller is
one, and "the definition rule reached zero recursive definitions" is a distinct
failure from "it reached none at all".
-}
type Site
    = TopLevel
    | CycleMember


countSite : Site -> Metrics -> Metrics
countSite site m =
    case site of
        TopLevel ->
            { m | defs = m.defs + 1 }

        CycleMember ->
            { m | cycleDefs = m.cycleDefs + 1 }
