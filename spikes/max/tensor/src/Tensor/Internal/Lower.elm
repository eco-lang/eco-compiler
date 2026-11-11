module Tensor.Internal.Lower exposing (graph, problems)

{-| Expressions to MAX ops: each expression emitted once (memoised by key), every operation spelled
by `Tensor.Internal.Mo`.

Lowering works on a stack of regions: the graph's body, and the branches and loop bodies of
`mo.if` and `mo.while` nested in it. A region may use its enclosing regions' values (MLIR regions
that are not isolated from above); `MlirBc` numbers those as negative operands. Shared functions
(`Call`) become `isSubgraph` graphs called through `mo.call`, threading a `!mo.chain`; MAX allows a
call only directly in a graph, so a call inside a branch or loop is inlined.

`problems` collects every build error first: errors recorded on expressions, broadcast axes that
reach a graph output unsized, inputs of other graphs, placeholders outside their function, key
collisions, and differentiation through a loop.

-}

import Dict exposing (Dict)
import Set exposing (Set)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Key exposing (Key)
import Tensor.Internal.MlirBc as Bc
import Tensor.Internal.Mo as Mo
import Tensor.Internal.Prim as P
import Tensor.Internal.Shape as Shape



-- PROBLEMS


{-| Every build error of a graph whose inputs are `inputs` and outputs `outputs`.
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

                            else if Set.member (E.key e) inputKeys then
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


{-| Two expressions with one key but a different operation or different operands.
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


{-| One region being written: its ops, the values of expressions lowered in it, the placeholders it
binds, and whether a shared function may be called in it (only directly in a graph).
-}
type alias Frame =
    { block : Mo.Block
    , values : Dict Key Int
    , binds : Dict Key Int
    , isGraph : Bool
    }


type alias St =
    { frames : List Frame
    , chain : Maybe Int
    , subgraphs : Dict String Bc.Op
    , order : List String
    }


{-| The graph as `mo.graph` ops: the graph itself, then one `isSubgraph` graph per shared function
it calls. Assumes `problems` found nothing.
-}
graph : String -> List ( String, Expr ) -> List ( String, Expr ) -> List Bc.Op
graph name inputs outputs =
    let
        frame =
            { block = Mo.emptyBlock (List.length inputs)
            , values = Dict.fromList (List.indexedMap (\i ( _, e ) -> ( E.key e, i )) inputs)
            , binds = Dict.empty
            , isGraph = True
            }

        st0 =
            { frames = [ frame ], chain = Nothing, subgraphs = Dict.empty, order = [] }

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
                (Bc.Region inTypes (List.reverse (output :: top.block.ops)))
    in
    main :: List.filterMap (\n -> Dict.get n st1.subgraphs) (List.reverse st1.order)


chainType : Bc.Type
chainType =
    Bc.OpaqueType "!mo.chain"


{-| The value of `e` as the top region numbers it: its own, or an enclosing region's as a negative
operand (-(1 + v) is value v of the region just outside).
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
                                    go outer |> Maybe.map (\v -> -(1 + v))

                [] ->
                    Nothing
    in
    go st.frames


valueOf : St -> Expr -> Int
valueOf st e =
    lookup st (E.key e) |> Maybe.withDefault -1000000


withTop : (Frame -> Frame) -> St -> St
withTop f st =
    case st.frames of
        top :: rest ->
            { st | frames = f top :: rest }

        [] ->
            st


top_ : St -> Frame
top_ st =
    List.head st.frames |> Maybe.withDefault { block = Mo.emptyBlock 0, values = Dict.empty, binds = Dict.empty, isGraph = True }


emit : (Mo.Block -> ( Mo.Block, Int )) -> Key -> St -> St
emit f k st =
    let
        ( block, v ) =
            f (top_ st).block
    in
    withTop (\fr -> { fr | block = block, values = Dict.insert k v fr.values }) st


lowerAll : List Expr -> St -> St
lowerAll roots st =
    List.foldl lowerOne st (Grad.postorder roots)


{-| The chain, as the top region numbers it (created at the graph's start on first use).
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


chainValue : St -> Int
chainValue st =
    let
        depth =
            List.length st.frames - 1

        base =
            Maybe.withDefault -1 st.chain
    in
    List.foldl (\_ v -> -(1 + v)) base (List.range 1 depth)


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
                    emit (Mo.emit p (List.map (valueOf st) args) (List.map E.meta args) params (E.meta e)) (E.key e) st

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
                    -- inputs and placeholders are bound by their regions; `problems` reports others
                    st


{-| A region's ops: `body` lowered in a new frame (binding its placeholders to `binds`), ended by
`terminator` over the outputs' values.
-}
region : Bool -> List Bc.Type -> Dict Key Int -> List Expr -> (St -> List Int -> Bc.Op) -> St -> ( St, Bc.Region )
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
                Bc.OpenRegion argTypes ops

            else
                Bc.OpenRegion [] ops
    in
    ( { inner | frames = List.drop 1 inner.frames }, r )


varBinds : E.Body -> List Int -> Dict Key Int
varBinds body values =
    Dict.fromList (List.indexedMap (\i v -> ( varKey body i, v )) values)


{-| The key of placeholder `i` of a body: found from the body's own placeholders (their shapes are
those of its arguments).
-}
varKey : E.Body -> Int -> Key
varKey body i =
    Dict.get i (bodyVars body) |> Maybe.withDefault ( -1, -1 )


bodyVars : E.Body -> Dict Int Key
bodyVars body =
    Grad.postorder body.outputs
        |> List.filterMap
            (\x ->
                case E.op x of
                    E.Var scope i ->
                        if scope == body.scope then
                            Just ( i, E.key x )

                        else
                            Nothing

                    _ ->
                        Nothing
            )
        |> Dict.fromList


{-| `mo.if`: two regions with no arguments that read the operands from outside; each yields its
outputs and the chain.
-}
lowerIf : Expr -> Expr -> E.Body -> E.Body -> List Expr -> St -> St
lowerIf e pred t f args st0 =
    let
        st1 =
            lowerAll (pred :: args) st0

        ( st2, _ ) =
            ensureChain st1

        argValues frame0 =
            -- the operands seen from inside a region nested in the current top
            List.map (\a -> -(1 + valueOf frame0 a)) args

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
            [ ( "outputParamDecls", Bc.OpaqueAttr "#kgen<param.decls[]>" ) ]
            [ valueOf st4 pred ]
            results
            [ thenRegion, elseRegion ]
        )
        (E.key e)
        st4


{-| `mo.while`: the carried values and the chain are both regions' arguments; the condition region
ends in `mo.while.condition`, the body in `mo.yield`.
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


{-| A shared function's body in place of a call (inside a region, where MAX forbids `mo.call`):
its placeholders substituted by the arguments, so two inlined calls do not share values.
-}
inlineCall : Expr -> E.Body -> List Expr -> St -> St
inlineCall e body args st0 =
    let
        mapping =
            Dict.fromList (List.filterMap (\( i, a ) -> Dict.get i (bodyVars body) |> Maybe.map (\k -> ( k, a ))) (List.indexedMap Tuple.pair args))

        outs =
            Grad.substitute mapping body.outputs

        st1 =
            lowerAll outs st0
    in
    withTop (\fr -> { fr | values = Dict.insert (E.key e) -1 fr.values }) st1
        |> recordOutputs e (List.map (valueOf st1) outs)


{-| Projections of an inlined call read their output's value directly.
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


{-| `mo.call @name(args..., chain)`, the subgraph lowered once per name.
-}
lowerCall : Expr -> String -> E.Body -> List Expr -> St -> St
lowerCall e name body args st0 =
    let
        st1 =
            lowerAll args st0

        st2 =
            if Dict.member name st1.subgraphs then
                st1

            else
                subgraph name body args st1

        ( st3, chain ) =
            ensureChain st2

        results =
            List.map (E.meta >> Mo.tensorType) body.outputs ++ [ chainType ]

        n =
            List.length body.outputs

        st4 =
            emit
                (Mo.push "mo.call"
                    [ ( "callee", Bc.SymbolRefAttr name ), ( "outputParamDecls", Bc.OpaqueAttr "#kgen<param.decls[]>" ), ( "prefix", Bc.StrAttr "" ) ]
                    (List.map (valueOf st3) args ++ [ chain ])
                    results
                    []
                )
                (E.key e)
                st3
    in
    -- the chain continues from the call's last result
    { st4 | chain = Just (valueOf st4 e + n) }


{-| A shared function as its own graph: the arguments and a chain in, the outputs and the chain
out. Lowered with the caller's table of subgraphs, so calls inside it are collected too.
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

        -- reserve the name first: a body cannot call itself, but its key is now known
        st =
            lowerAll body.outputs { frames = [ frame ], chain = Just n, subgraphs = Dict.insert name placeholderOp caller.subgraphs, order = caller.order }

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
            Mo.graphOp name [ ( "isSubgraph", Bc.UnitAttr ) ] inNames outNames inTypes outTypes (Bc.Region inTypes (List.reverse (output :: top.block.ops)))
    in
    { caller | subgraphs = Dict.insert name op st.subgraphs, order = name :: st.order }


placeholderOp : Bc.Op
placeholderOp =
    { name = "mo.output", attrs = [], results = [], operands = [], regions = [] }
