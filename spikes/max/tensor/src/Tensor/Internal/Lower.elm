module Tensor.Internal.Lower exposing (graph, problems)

{-| MAX is handed a graph as ops of its graph dialects, and this module turns a graph's expressions
into those ops (`graph`). It also collects the graph's build errors (`problems`). Lowering reports
nothing itself and assumes that list was empty.

_Lowering_ goes through the expressions the outputs read, each after its operands, and gives each
one a _value number_ in the region being written (`Tensor.Internal.Ir` defines regions and
value numbers). Expressions are told apart by key, so an expression read in several places is
lowered once and its number reused, within the limits regions set, described next. How a primitive
is spelled as ops is `Tensor.Internal.Mo`'s concern; this module deals in value numbers.

A graph is one region, the block of its `mo.graph`. A branch (`If`) becomes an `mo.if` and a loop
(`While`) an `mo.while`, each holding two regions nested in the one being written, so lowering
keeps a stack of _frames_, one per region being written, innermost on top. The nested regions are
open regions: their ops may read values of the regions outside them, up to the graph's region, as
negative operands, which this module assigns (`Tensor.Internal.Ir.outer`, once per region
crossed) and `Tensor.Internal.Ir` resolves. An expression already lowered in an enclosing region is read from
there, however many regions out. One first lowered inside a nested region is forgotten when that
region ends, and is lowered again if it is needed after it.

A `Call` node met directly in a graph's region becomes an `mo.call` of a _subgraph_: a separate
`mo.graph`, marked `isSubgraph` and named after the call's name. Each body called under a name gets
one subgraph, made from it the first time it is met, and every later such `Call` of that body calls
it (`lowerCall` gives the names). This module assumes MAX accepts `mo.call` only directly in a
graph's region, so a `Call` inside a branch or loop is _inlined_ instead: its body is lowered in
place, on the call's arguments.

The _chain_ is a value of type `!mo.chain` that orders the calls. The main graph makes it with
`mo.chain.create` when a call, branch or loop first needs it; a subgraph takes it as its last
argument and returns it as its last result. Each `mo.call` reads the current chain, and its last
result becomes the current chain. An `mo.if` yields the chain from both branches and an `mo.while`
carries it through its regions, but their chain results are never read: only calls advance it.

-}

import Dict exposing (Dict)
import Set exposing (Set)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Key as K exposing (Key)
import Tensor.Internal.Ir as Ir
import Tensor.Internal.Mo as Mo
import Tensor.Internal.Prim as P
import Tensor.Internal.Shape as Shape



-- PROBLEMS


{-| Returns the build errors of a graph whose inputs are `inputs` and whose outputs, each with its
name, are `outputs`. Each message is prefixed with `graphName ++ ": "`, and a message found more
than once is listed once, where it was first found.

The expressions checked are those the outputs reach through operands and, inside each `Call`, `If`
and `While` node met, through its bodies' outputs. For each one it reports:

  - the build error recorded on it (`Tensor.Internal.Expr.problem`);
  - an input that is not one of `inputs`, unless it carries a build error (an input that
    `Tensor.Internal.Expr.failWith` failed is no longer one of `inputs`, and its own error is
    reported instead), and any input at all inside a `Call` body, in branches and loops within
    that body too;
  - a placeholder of no enclosing body, or of one outside the nearest enclosing `Call` body;
  - two expressions sharing a key whose descriptions (`Tensor.Internal.Expr.shallow`) differ. The
    outputs and each body are walked separately, each walk with its own record of keys, so two
    such expressions are compared only when one walk meets both.

It also reports each output, unless poisoned, that still has a pending axis.

An error on an expression that no output reaches is not reported.

-}
problems : String -> List Expr -> List ( String, Expr ) -> List String
problems graphName inputs outputs =
    let
        inputKeys =
            Set.fromList (List.map E.key inputs)

        walk : Bool -> Set Key -> List Expr -> List String
        walk closed scopes roots =
            let
                order =
                    Grad.postorder roots

                own e =
                    case E.op e of
                        E.Input g _ ->
                            if closed then
                                [ "a shared function reads a tensor that is not one of its arguments (pass it in its signature)" ]

                            else if Set.member (E.key e) inputKeys || E.poisoned e then
                                []

                            else
                                [ "uses an input of graph " ++ g ]

                        E.Var scope _ ->
                            if Set.member scope scopes then
                                []

                            else
                                [ "reads a tensor that is not an argument of the function it is used in" ]

                        E.Call _ body _ ->
                            walk True (Set.singleton body.scope) body.outputs

                        E.If _ t f _ ->
                            walk closed (Set.insert t.scope scopes) t.outputs ++ walk closed (Set.insert f.scope scopes) f.outputs

                        E.While c b _ ->
                            walk closed (Set.insert c.scope scopes) c.outputs ++ walk closed (Set.insert b.scope scopes) b.outputs

                        _ ->
                            []
            in
            List.filterMap E.problem order ++ List.concatMap own order ++ collisionCheck order

        unsized =
            List.filterMap
                (\( n, e ) ->
                    if List.isEmpty (E.pending e) || E.poisoned e then
                        Nothing

                    else
                        Just ("output " ++ n ++ ": " ++ Shape.pendingMessage)
                )
                outputs
    in
    List.map (\p -> graphName ++ ": " ++ p) (unique (walk False Set.empty (List.map Tuple.second outputs) ++ unsized))


{-| Returns `l` with each string kept only where it first occurs, in order.
-}
unique : List String -> List String
unique l =
    List.foldl
        (\x ( seen, acc ) ->
            if Set.member x seen then
                ( seen, acc )

            else
                ( Set.insert x seen, x :: acc )
        )
        ( Set.empty, [] )
        l
        |> Tuple.second
        |> List.reverse


{-| Returns a message each time it meets an expression, in `order` or among the operands each of
them reads, whose `Tensor.Internal.Expr.shallow` description differs from that of the first
expression met under the same key.

The operands are looked at too because `order` comes from `Grad.postorder`, which keeps one
expression per key: the second of two expressions sharing a key is met, if at all, only as an
operand of what reads it.

-}
collisionCheck : List Expr -> List String
collisionCheck order =
    let
        step e ( seen, errs ) =
            let
                s =
                    E.shallow e
            in
            case Dict.get (E.key e) seen of
                Just other ->
                    if other /= s then
                        ( seen, "internal: two expressions share a key (please report)" :: errs )

                    else
                        ( seen, errs )

                Nothing ->
                    ( Dict.insert (E.key e) s seen, errs )

        everyOperand =
            List.concatMap (\e -> e :: E.operands e) order
    in
    List.foldl step ( Dict.empty, [] ) everyOperand |> Tuple.second



-- LOWERING


{-| One region being written: its block of ops so far, and the value numbers it gives expressions,
in its own numbering (`Tensor.Internal.Ir.Region`).

`values` holds what was lowered in this region, by key, and in the main graph's frame also its
inputs, as the block's arguments. `binds` holds the placeholders this region's body reads, bound
when the region was opened. `isGraph` is `True` for the region of an `mo.graph`, where a `Call`
becomes an `mo.call`; anywhere else a `Call` is inlined.

-}
type alias Frame =
    { block : Mo.Block
    , values : Dict Key Int
    , binds : Dict Key Int
    , isGraph : Bool
    }


{-| The state of one lowering.

`frames` is the stack of regions being written, innermost first. `chain` is the chain's value
number in the bottom frame, the graph's own region, or `Nothing` before it is made. `subgraphs`
holds the subgraphs made so far, by name, and `placeholderOp` under the name of each one whose
body is still being lowered. `order` holds the names of the finished ones, the most recently
finished first. `symbols` holds, for each call name met, the bodies called under it, each with the
name of its subgraph.

-}
type alias St =
    { frames : List Frame
    , chain : Maybe Int
    , subgraphs : Dict String Ir.Op
    , order : List String
    , symbols : Dict String (List ( BodyId, String ))
    }


{-| What tells two bodies apart when choosing subgraphs (`bodyId`).
-}
type alias BodyId =
    ( Int, List Key )


{-| Returns the ops of the graph named `name` whose inputs are `inputs` and whose outputs are
`outputs`, each with the name the graph gives it.

The first op is the graph's `mo.graph`: its block's arguments are the inputs, in order, and it ends
in an `mo.output` of the outputs, in order. After it comes one `isSubgraph` `mo.graph` for each
body of a `Call` met directly in a graph region, in the order their lowering finished, so a
subgraph first called from inside another comes before it.

It assumes `problems` found nothing. An expression that no region has a value for, such as an
input not among `inputs`, is read as the operand 10⁹, which names no value in any region, so
`Tensor.Internal.Ir.unboundOperands` finds it.

-}
graph : String -> List ( String, Expr ) -> List ( String, Expr ) -> List Ir.Op
graph name inputs outputs =
    let
        frame =
            { block = Mo.emptyBlock (List.length inputs)
            , values = Dict.fromList (List.indexedMap (\i ( _, e ) -> ( E.key e, i )) inputs)
            , binds = Dict.empty
            , isGraph = True
            }

        st0 =
            { frames = [ frame ], chain = Nothing, subgraphs = Dict.empty, order = [], symbols = Dict.empty }

        st1 =
            lowerAll (List.map Tuple.second outputs) st0

        outValues =
            List.map (\( _, e ) -> valueOf st1 e) outputs

        top =
            List.head st1.frames |> Maybe.withDefault frame

        output =
            { name = "mo.output", attrs = [], results = [], operands = outValues, regions = [] }

        inTypes =
            List.map (Tuple.second >> E.meta >> Mo.tensorType) inputs

        outTypes =
            List.map (Tuple.second >> E.meta >> Mo.tensorType) outputs

        main =
            Mo.graphOp name
                []
                (List.map (Tuple.mapSecond E.meta) inputs)
                (List.map (Tuple.mapSecond E.meta) outputs)
                inTypes
                outTypes
                (Ir.Region inTypes (List.reverse (output :: top.block.ops)))
    in
    main :: List.filterMap (\n -> Dict.get n st1.subgraphs) (List.reverse st1.order)


{-| The type of the chain, `!mo.chain`.
-}
chainType : Ir.Type
chainType =
    Ir.OpaqueType "!mo.chain"


{-| Returns, for a primitive that `Tensor.Internal.Mo` writes as one result of a two-result op, the
primitive of the other result and the offset of that result's value number from this one's. Only
`TopKValues` and `TopKIndices` have one.
-}
sibling : P.Prim -> Maybe ( P.Prim, Int )
sibling p =
    case p of
        P.TopKValues ->
            Just ( P.TopKIndices, 1 )

        P.TopKIndices ->
            Just ( P.TopKValues, -1 )

        _ ->
            Nothing


{-| Returns the value number of key `k` as the top frame numbers it: the top frame's own value or
bound placeholder, or else the number the nearest enclosing frame has for it, turned by
`Tensor.Internal.Ir.outer` once for each region crossed. `Nothing` when no frame has it.
-}
lookup : St -> Key -> Maybe Int
lookup st k =
    let
        go frames =
            case frames of
                f :: outer ->
                    case Dict.get k f.values of
                        Just v ->
                            Just v

                        Nothing ->
                            case Dict.get k f.binds of
                                Just v ->
                                    Just v

                                Nothing ->
                                    go outer |> Maybe.map Ir.outer

                [] ->
                    Nothing
    in
    go st.frames


{-| Returns the value number of `e` as the top frame numbers it, as `lookup` gives it, or 10⁹ when
no frame has a value for it: an operand that names no value of the region it is read in, nor, once
`Tensor.Internal.Ir.outer` has turned it for an enclosed region, of any region it can reach
from there, so `Tensor.Internal.Ir.unboundOperands` reports it.
-}
valueOf : St -> Expr -> Int
valueOf st e =
    lookup st (E.key e) |> Maybe.withDefault 1000000000


{-| Returns `st` with `f` applied to its top frame.
-}
withTop : (Frame -> Frame) -> St -> St
withTop f st =
    case st.frames of
        top :: rest ->
            { st | frames = f top :: rest }

        [] ->
            st


{-| Returns the top frame, or an empty graph frame when the stack is empty.
-}
top_ : St -> Frame
top_ st =
    List.head st.frames |> Maybe.withDefault { block = Mo.emptyBlock 0, values = Dict.empty, binds = Dict.empty, isGraph = True }


{-| Appends what `f` appends to the top frame's block, and records the number `f` returns as the
value of key `k` there.
-}
emit : (Mo.Block -> ( Mo.Block, Int )) -> Key -> St -> St
emit f k st =
    let
        ( block, v ) =
            f (top_ st).block
    in
    withTop (\fr -> { fr | block = block, values = Dict.insert k v fr.values }) st


{-| Applies `lowerOne` to `roots` and the expressions they read through operands, each after its
operands (`Grad.postorder`). Bodies are lowered by the nodes that hold them.
-}
lowerAll : List Expr -> St -> St
lowerAll roots st =
    List.foldl lowerOne st (Grad.postorder roots)


{-| Returns the chain's value number as `chainValue` gives it, first appending
`mo.chain.create` to the bottom frame's block if there is no chain yet.
-}
ensureChain : St -> ( St, Int )
ensureChain st =
    case st.chain of
        Just _ ->
            ( st, chainValue st )

        Nothing ->
            let
                -- created in the graph's own region (the bottom frame)
                frames =
                    List.reverse st.frames

                bottom =
                    List.head frames |> Maybe.withDefault (top_ st)

                ( block, v ) =
                    Mo.push "mo.chain.create" [] [] [ chainType ] [] bottom.block

                st1 =
                    { st | frames = List.reverse ({ bottom | block = block } :: List.drop 1 frames), chain = Just v }
            in
            ( st1, chainValue st1 )


{-| Returns the chain's value number as the top frame numbers it, by applying
`Tensor.Internal.Ir.outer` once for each frame above the bottom one. With no chain, it starts
from −1.
-}
chainValue : St -> Int
chainValue st =
    let
        depth =
            List.length st.frames - 1

        base =
            Maybe.withDefault -1 st.chain
    in
    List.foldl (\_ v -> Ir.outer v) base (List.range 1 depth)


{-| Lowers `e` into the top frame and records its value number, unless some frame already has a
value for its key. Its operands must already have values.

A constant or a primitive appends what `Mo.constant` or `Mo.emit` appends for it. A top-k result
also records the other result of its op, under the key of the sibling primitive with the same
operands and params. A projection appends nothing: its number is that of the projected node's first
result, plus its index. An `If` or `While` is lowered by `lowerIf` or `lowerWhile`, and a `Call`
by `lowerCall` in a graph region and by `inlineCall` anywhere else.

-}
lowerOne : Expr -> St -> St
lowerOne e st =
    case lookup st (E.key e) of
        Just _ ->
            st

        Nothing ->
            case E.op e of
                E.Const values ->
                    emit (Mo.constant (E.dtype e) (E.shape e) values) (E.key e) st

                E.P p args params ->
                    let
                        st1 =
                            emit (Mo.emit p (List.map (valueOf st) args) (List.map E.meta args) params (E.meta e)) (E.key e) st
                    in
                    case sibling p of
                        Just ( other, offset ) ->
                            -- the op's other result: the same node with the sibling primitive
                            withTop (\fr -> { fr | values = Dict.insert (E.key (E.prim other args params)) (valueOf st1 e + offset) fr.values }) st1

                        Nothing ->
                            st1

                E.Proj source i ->
                    let
                        base =
                            valueOf st source
                    in
                    withTop (\fr -> { fr | values = Dict.insert (E.key e) (base + i) fr.values }) st

                E.If pred t f args ->
                    lowerIf e pred t f args st

                E.While c b init ->
                    lowerWhile e c b init st

                E.Call name body args ->
                    if (top_ st).isGraph then
                        lowerCall e name body args st

                    else
                        inlineCall e body args st

                _ ->
                    -- reached only by an input or placeholder that no frame binds: it gets no value
                    st


{-| Lowers `outputs` into a new open region, and returns the state with that region's frame removed,
together with the region.

The region's block has an argument for each of `argTypes`, which the region lists only when
`withArgs` is `True`; this module passes `False` only with `argTypes` empty. `binds` gives the
numbers of the placeholders the region's body reads. The region's last op is `terminator`, given
the state inside the region and the outputs' value numbers.

What was lowered in the region is forgotten when it ends, so an expression first lowered here is
lowered again where it is needed after it.

-}
region : Bool -> List Ir.Type -> Dict Key Int -> List Expr -> (St -> List Int -> Ir.Op) -> St -> ( St, Ir.Region )
region withArgs argTypes binds outputs terminator st =
    let
        frame =
            { block = Mo.emptyBlock (List.length argTypes)
            , values = Dict.empty
            , binds = binds
            , isGraph = False
            }

        inner =
            lowerAll outputs { st | frames = frame :: st.frames }

        term =
            terminator inner (List.map (valueOf inner) outputs)

        top =
            top_ inner

        ops =
            List.reverse (term :: top.block.ops)

        r =
            if withArgs then
                Ir.OpenRegion argTypes ops

            else
                Ir.OpenRegion [] ops
    in
    ( { inner | frames = List.drop 1 inner.frames }, r )


{-| Returns the key of each placeholder `bodyVars` finds in `body`, paired with the element of
`values` at its argument position. A placeholder `body` never reads is not bound.

A placeholder's key mixes the dtype and shape it was traced with, so it is looked up in the body
rather than made again from the arguments.

-}
varBinds : E.Body -> List Int -> Dict Key Int
varBinds body values =
    let
        vars =
            bodyVars body
    in
    List.indexedMap (\i v -> Dict.get i vars |> Maybe.map (\k -> ( k, v ))) values
        |> List.filterMap identity
        |> Dict.fromList


{-| Returns the keys of the placeholders of `body`'s own scope that its outputs read, by argument
position, as `readVars` finds them.
-}
bodyVars : E.Body -> Dict Int Key
bodyVars body =
    Dict.fromList (readVars body.scope body.outputs)


{-| Returns the position and key of each placeholder of `scope` that `roots` read through operands
and, inside each `If` and `While` node met, through its bodies' outputs, at any depth. The body of a
`Call` is not looked into: `problems` reports a placeholder read there.
-}
readVars : Key -> List Expr -> List ( Int, Key )
readVars scope roots =
    Grad.postorder roots
        |> List.concatMap
            (\x ->
                case E.op x of
                    E.Var s i ->
                        if s == scope then
                            [ ( i, E.key x ) ]

                        else
                            []

                    E.If _ t f _ ->
                        readVars scope t.outputs ++ readVars scope f.outputs

                    E.While c b _ ->
                        readVars scope c.outputs ++ readVars scope b.outputs

                    _ ->
                        []
            )


{-| Lowers the `If` node `e` as an `mo.if` in the top frame. `pred` and `args` are lowered there
first, and the op reads only `pred`.

Its two regions have no arguments. Each binds the placeholders `bodyVars` finds in its branch to
`args`, each numbered `Tensor.Internal.Ir.outer v` from the number `v` the top frame gives it,
and ends in an `mo.yield` of its branch's outputs and the chain as `chainValue` gives it. A branch
thus reads its arguments, like any other value from outside, as negative operands. The op's results
are `t`'s outputs and the chain.

-}
lowerIf : Expr -> Expr -> E.Body -> E.Body -> List Expr -> St -> St
lowerIf e pred t f args st0 =
    let
        st1 =
            lowerAll (pred :: args) st0

        ( st2, _ ) =
            ensureChain st1

        argValues frame0 =
            -- the operands as a region nested in the current top names them
            List.map (\a -> Ir.outer (valueOf frame0 a)) args

        yield inner vs =
            { name = "mo.yield", attrs = [], results = [], operands = vs ++ [ chainValue inner ], regions = [] }

        ( st3, thenRegion ) =
            region False [] (varBinds t (argValues st2)) t.outputs yield st2

        ( st4, elseRegion ) =
            region False [] (varBinds f (argValues st3)) f.outputs yield st3

        results =
            List.map (E.meta >> Mo.tensorType) t.outputs ++ [ chainType ]
    in
    emit
        (Mo.push "mo.if"
            [ ( "outputParamDecls", Ir.OpaqueAttr "#kgen<param.decls[]>" ) ]
            [ valueOf st4 pred ]
            results
            [ thenRegion, elseRegion ]
        )
        (E.key e)
        st4


{-| Lowers the `While` node `e` as an `mo.while` in the top frame, reading the initial state
`init`, lowered there first, and the chain as `chainValue` gives it.

Both regions take the state and then the chain as arguments, and bind the placeholders `bodyVars`
finds in their body to the state arguments. The condition region ends in `mo.while.condition` of
`c`'s outputs followed by every argument, and the body region in an `mo.yield` of `b`'s outputs
followed by the chain argument. The op's results are the final state and the chain.

-}
lowerWhile : Expr -> E.Body -> E.Body -> List Expr -> St -> St
lowerWhile e c b init st0 =
    let
        st1 =
            lowerAll init st0

        ( st2, chain ) =
            ensureChain st1

        n =
            List.length init

        argTypes =
            List.map (E.meta >> Mo.tensorType) init ++ [ chainType ]

        args =
            List.range 0 (n - 1)

        ( st3, condRegion ) =
            region True
                argTypes
                (varBinds c args)
                c.outputs
                (\_ vs -> { name = "mo.while.condition", attrs = [], results = [], operands = vs ++ List.range 0 n, regions = [] })
                st2

        ( st4, bodyRegion ) =
            region True
                argTypes
                (varBinds b args)
                b.outputs
                (\_ vs -> { name = "mo.yield", attrs = [], results = [], operands = vs ++ [ n ], regions = [] })
                st3
    in
    emit
        (Mo.push "mo.while" [] (List.map (valueOf st4) init ++ [ chain ]) argTypes [ condRegion, bodyRegion ])
        (E.key e)
        st4


{-| Lowers the `Call` node `e` by lowering its body into the top frame in place of a call.

The body's placeholders are replaced by `args` (`Grad.substitute`, which also replaces them inside
the bodies of nested nodes) before lowering, so the expressions that read them are keyed by these
arguments, and two calls of one body on different arguments do not share those expressions'
values.

Each projection of `e` is recorded with its output's value, and `e` itself, which appends no op,
is recorded as −1 so that it counts as lowered.

-}
inlineCall : Expr -> E.Body -> List Expr -> St -> St
inlineCall e body args st0 =
    let
        vars =
            bodyVars body

        mapping =
            Dict.fromList (List.filterMap (\( i, a ) -> Dict.get i vars |> Maybe.map (\k -> ( k, a ))) (List.indexedMap Tuple.pair args))

        outs =
            Grad.substitute mapping body.outputs

        st1 =
            lowerAll outs st0
    in
    withTop (\fr -> { fr | values = Dict.insert (E.key e) -1 fr.values }) st1
        |> recordOutputs e (List.map (valueOf st1) outs)


{-| Records in the top frame, for each element `i` of `values`, that projection `i` of `e` has the
value number `i` of `values`.
-}
recordOutputs : Expr -> List Int -> St -> St
recordOutputs e values st =
    withTop
        (\fr ->
            { fr
                | values =
                    List.foldl
                        (\( i, v ) acc -> Dict.insert (E.key (E.proj e i)) v acc)
                        fr.values
                        (List.indexedMap Tuple.pair values)
            }
        )
        st


{-| Lowers the `Call` node `e`, in a graph region, as an `mo.call` of the subgraph made from
`body`.

`args` are lowered first. Each body called under `name`, told apart by `bodyId`, has a subgraph of
its own, made from it the first time it is met and named by `freshSymbol name` at that point:
`name` itself unless a subgraph already has that name. The call reads `args` and the current chain and
gives `body`'s outputs and a new chain, which becomes the current one.

-}
lowerCall : Expr -> String -> E.Body -> List Expr -> St -> St
lowerCall e name body args st0 =
    let
        st1 =
            lowerAll args st0

        id =
            bodyId body

        known =
            Dict.get name st1.symbols |> Maybe.withDefault []

        ( symbol, st2 ) =
            case List.filter (\( k, _ ) -> k == id) known of
                ( _, s ) :: _ ->
                    ( s, st1 )

                [] ->
                    let
                        s =
                            freshSymbol name st1.subgraphs
                    in
                    ( s, subgraph s body args { st1 | symbols = Dict.insert name (known ++ [ ( id, s ) ]) st1.symbols } )

        ( st3, chain ) =
            ensureChain st2

        results =
            List.map (E.meta >> Mo.tensorType) body.outputs ++ [ chainType ]

        n =
            List.length body.outputs

        st4 =
            emit
                (Mo.push "mo.call"
                    [ ( "callee", Ir.SymbolRefAttr symbol ), ( "outputParamDecls", Ir.OpaqueAttr "#kgen<param.decls[]>" ), ( "prefix", Ir.StrAttr "" ) ]
                    (List.map (valueOf st3) args ++ [ chain ])
                    results
                    []
                )
                (E.key e)
                st3
    in
    -- the chain continues from the call's last result
    { st4 | chain = Just (valueOf st4 e + n) }


{-| Returns what tells `body` apart from other bodies: its arity and the keys of its outputs once
each placeholder of its scope that they read through operands is replaced by a placeholder of one
fixed scope, with the same position and meta. Two bodies that differ only in their scope
thus get the same answer, unless a placeholder is read only inside a nested body (the mapping is
made from what the outputs read through operands): what reads it keeps its scope, so such bodies
are told apart.
-}
bodyId : E.Body -> BodyId
bodyId body =
    let
        canonical =
            K.start "lower-canonical-scope"

        mapping =
            Grad.postorder body.outputs
                |> List.filterMap
                    (\x ->
                        case E.op x of
                            E.Var s i ->
                                if s == body.scope then
                                    Just ( E.key x, E.varMeta canonical i (E.meta x) )

                                else
                                    Nothing

                            _ ->
                                Nothing
                    )
                |> Dict.fromList
    in
    ( body.arity, List.map E.key (Grad.substitute mapping body.outputs) )


{-| Returns `name` when no subgraph in `subgraphs` has it, and otherwise the first of
`name ++ "_c1"`, `name ++ "_c2"`, … that none has.
-}
freshSymbol : String -> Dict String Ir.Op -> String
freshSymbol name subgraphs =
    let
        go k =
            let
                s =
                    name ++ "_c" ++ String.fromInt k
            in
            if Dict.member s subgraphs then
                go (k + 1)

            else
                s
    in
    if Dict.member name subgraphs then
        go 1

    else
        name


{-| Returns `caller` with `body` added to its subgraphs as an `isSubgraph` `mo.graph` named
`name`.

The subgraph's block takes the arguments and then the chain, and its `mo.output` gives `body`'s
outputs and then the last chain. Its argument types are those of `args`, the arguments of the call
that made it, not those `body` was traced with.

The body is lowered in a state of its own, whose one frame is the subgraph's isolated region: it
shares no values with `caller`, only the table of subgraphs, their order and the symbols chosen for
bodies (`lowerCall`). While it is lowered, `name` is already in that table as `placeholderOp`, so a
call of this body met directly in its region becomes an `mo.call` of this subgraph rather than
being lowered again. `caller`'s frames and chain are returned unchanged.

-}
subgraph : String -> E.Body -> List Expr -> St -> St
subgraph name body args caller =
    let
        n =
            List.length args

        frame =
            { block = Mo.emptyBlock (n + 1)
            , values = Dict.empty
            , binds = varBinds body (List.range 0 (n - 1))
            , isGraph = True
            }

        st =
            lowerAll body.outputs { frames = [ frame ], chain = Just n, subgraphs = Dict.insert name placeholderOp caller.subgraphs, order = caller.order, symbols = caller.symbols }

        top =
            top_ st

        output =
            { name = "mo.output", attrs = [], results = [], operands = List.map (valueOf st) body.outputs ++ [ Maybe.withDefault n st.chain ], regions = [] }

        inTypes =
            List.map (E.meta >> Mo.tensorType) args ++ [ chainType ]

        outTypes =
            List.map (E.meta >> Mo.tensorType) body.outputs ++ [ chainType ]

        inNames =
            List.indexedMap (\i a -> ( "input" ++ String.fromInt i, E.meta a )) args

        outNames =
            List.indexedMap (\i o -> ( "output" ++ String.fromInt i, E.meta o )) body.outputs ++ [ ( "output" ++ String.fromInt (List.length body.outputs), { shape = [], pending = [], dtype = P.F32 } ) ]

        op =
            Mo.graphOp name [ ( "isSubgraph", Ir.UnitAttr ) ] inNames outNames inTypes outTypes (Ir.Region inTypes (List.reverse (output :: top.block.ops)))
    in
    { caller | subgraphs = Dict.insert name op st.subgraphs, order = name :: st.order, symbols = st.symbols }


{-| An empty `mo.output` op that holds a subgraph's place in the table while its body is lowered.
`subgraph` replaces it once the body is done, so it is never among the ops `graph` returns.
-}
placeholderOp : Ir.Op
placeholderOp =
    { name = "mo.output", attrs = [], results = [], operands = [], regions = [] }
