module Layout exposing
    ( State, Net, init, view, random
    , nodes, distancesOf, stress, relax, settled, recentre, graph
    )

{-| A graph drawn by minimising stress: every pair of nodes wants to be as far apart on the page as
it is in the graph (the number of edges between them),

    stress = Σ w_ij (|x_i − x_j| − d_ij)²,   w_ij = 1 / d_ij²

summed over all pairs at once as 20 × 20 tensors, and minimised by gradient steps (`Transform.grad`)
run by `Tensor.Eval`. The graph is random (`random`): a random tree on 20 nodes plus a few extra
edges, so it is connected and has some cycles; each seed gives a different one.

  - **Settling**: a few steps every animation frame, until the layout stops moving.
  - **Dragging a node**: `Drag.varyWith` over the whole layout, with a solver that pins the node
    under the pointer and relaxes the others from where they were, so the layout follows live.

@docs State, Net, init, view, random
@docs nodes, distancesOf, stress, relax, settled, recentre, graph

-}

import Array exposing (Array)
import Dict
import Evg exposing (Evg)
import Evg.Drag as Drag
import Graph exposing (Graph)
import Signature as Sig
import Tensor as T exposing (Dim, F64, R0, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Eval as Eval
import Transform


{-| A graph: its edges, and the distance between every pair of nodes (row-major).
-}
type alias Net =
    { edges : List ( Int, Int ), distances : List Float }


{-| The graph, its seed, and each node's position (in edge lengths).
-}
type alias State =
    { net : Net, seed : Int, positions : List ( Float, Float ) }


nodes : Int
nodes =
    20


{-| Extra edges beyond the random tree.
-}
extra : Int
extra =
    7


init : State
init =
    random 1


{-| MINSTD: `next = 48271 x mod (2³¹ − 1)`, exact in JavaScript's 53-bit integers.
-}
next : Int -> Int
next x =
    modBy 2147483647 (48271 * x)


{-| A uniform integer in [0, n), and the generator's next state.
-}
below : Int -> Int -> ( Int, Int )
below n x =
    let
        y =
            next x
    in
    ( modBy n y, y )


{-| The graph and scrambled positions for a seed.
-}
random : Int -> State
random seed =
    let
        start =
            next (seed * 7919 + 1)

        -- node i (1..19) joins a random earlier node: a random tree
        ( tree, afterTree ) =
            List.foldl
                (\i ( acc, g ) ->
                    let
                        ( j, g2 ) =
                            below i g
                    in
                    ( ( j, i ) :: acc, g2 )
                )
                ( [], start )
                (List.range 1 (nodes - 1))

        has es ( a, b ) =
            List.any (\( p, q ) -> ( p, q ) == ( a, b ) || ( p, q ) == ( b, a )) es

        addExtra ( es, g, left ) =
            if left <= 0 then
                ( es, g )

            else
                let
                    ( a, g2 ) =
                        below nodes g

                    ( b, g3 ) =
                        below nodes g2
                in
                if a == b || has es ( a, b ) then
                    addExtra ( es, g3, left )

                else
                    addExtra ( ( a, b ) :: es, g3, left - 1 )

        ( edges, afterEdges ) =
            addExtra ( tree, afterTree, extra )

        ( positions, _ ) =
            List.foldl
                (\_ ( acc, g ) ->
                    let
                        ( a, g2 ) =
                            below 1000 g

                        ( b, g3 ) =
                            below 1000 g2
                    in
                    ( ( 4 * toFloat a / 1000 - 2, 3 * toFloat b / 1000 - 1.5 ) :: acc, g3 )
                )
                ( [], afterEdges )
                (List.range 1 nodes)
    in
    { net = { edges = List.reverse edges, distances = distancesOf edges }, seed = seed, positions = positions }


{-| The graph distance between every pair (breadth-first search), row-major.
-}
distancesOf : List ( Int, Int ) -> List Float
distancesOf edges =
    let
        neighbours i =
            List.filterMap
                (\( a, b ) ->
                    if a == i then
                        Just b

                    else if b == i then
                        Just a

                    else
                        Nothing
                )
                edges

        from source =
            let
                go frontier dist d =
                    if List.isEmpty frontier then
                        dist

                    else
                        let
                            reached =
                                List.concatMap neighbours frontier
                                    |> List.filter (\n -> Array.get n dist == Just -1)
                                    |> List.foldl
                                        (\n acc ->
                                            if List.member n acc then
                                                acc

                                            else
                                                n :: acc
                                        )
                                        []
                        in
                        go reached (List.foldl (\n a -> Array.set n (d + 1) a) dist reached) (d + 1)
            in
            go [ source ] (Array.set source 0 (Array.repeat nodes -1)) 0 |> Array.toList |> List.map toFloat
    in
    List.concatMap from (List.range 0 (nodes - 1))


weightsOf : List Float -> List Float
weightsOf =
    List.map
        (\d ->
            if d <= 0 then
                0

            else
                1 / (d * d)
        )


{-| The stress of a layout, in plain Elm (over all ordered pairs, so each pair twice).
-}
stress : Net -> List ( Float, Float ) -> Float
stress net positions =
    let
        allPairs =
            List.concatMap (\p -> List.map (\q -> ( p, q )) positions) positions
    in
    List.map3
        (\( ( x1, y1 ), ( x2, y2 ) ) d w ->
            let
                gap =
                    sqrt ((x1 - x2) ^ 2 + (y1 - y2) ^ 2 + 1.0e-9) - d
            in
            w * gap * gap
        )
        allPairs
        net.distances
        (weightsOf net.distances)
        |> List.sum



-- THE MODEL


type N
    = N


type Two
    = Two


type One
    = One


nDim : Dim N
nDim =
    T.dim N nodes


twoDim : Dim Two
twoDim =
    T.dim Two 2


stressOf : Tensor Float F64 (R2 N N) -> Tensor Float F64 (R2 N N) -> Tensor Float F64 (R2 N Two) -> Tensor Float F64 R0
stressOf d w x =
    let
        sq =
            x |> T.times x |> T.sum Axis.last2

        squared =
            T.columns sq |> T.plus (T.rows sq) |> T.minus (x |> T.matmul (T.transpose x) |> T.scale 2)

        dist =
            squared |> T.max (T.zerosLike squared) |> T.shift 1.0e-9 |> T.sqrt

        gap =
            dist |> T.minus d
    in
    gap |> T.times gap |> T.times w |> T.sumAll


steps : Int
steps =
    4


rate : Float
rate =
    0.035


{-| Inputs the positions (20 × 2), a pin mask (1 for a pinned node), and the graph's distances and
stress weights (20 × 20); outputs the positions after `steps` gradient steps that leave pinned nodes
where they are, and the stress before them.
-}
graph : Result (List String) Graph
graph =
    Graph.build "layout"
        (Sig.pair
            (Sig.pair (Sig.label "positions" (Sig.tensor T.float64 (T.r2 nDim twoDim))) (Sig.label "pin" (Sig.tensor T.float64 (T.r1 nDim))))
            (Sig.pair (Sig.label "distances" (Sig.tensor T.float64 (T.r2 nDim nDim))) (Sig.label "weights" (Sig.tensor T.float64 (T.r2 nDim nDim))))
        )
        (Sig.pair (Sig.label "relaxed" (Sig.tensor T.float64 (T.r2 nDim twoDim))) (Sig.label "stress" (Sig.tensor T.float64 (T.r1 (T.dim One 1)))))
        (\( ( x0, pin ), ( d, w ) ) ->
            let
                free =
                    pin |> T.scale -1 |> T.shift 1 |> T.columns

                step _ x =
                    x |> T.minus (Transform.grad (stressOf d w) x |> T.times free |> T.scale rate)
            in
            ( List.foldl step x0 (List.range 1 steps), stressOf d w x0 |> T.reshape (T.r1 (T.dim One 1)) )
        )


prepared : Result (List String) Eval.Prepared
prepared =
    Result.map Eval.prepare graph


{-| `steps` gradient steps, with node `pinned` (if any) held in place; and the stress before them.
-}
relax : Maybe Int -> State -> ( State, Float )
relax pinned state =
    case prepared of
        Err _ ->
            ( state, 0 )

        Ok p ->
            let
                square name values =
                    ( name, { dtype = "f64", shape = [ nodes, nodes ], data = Eval.Floats values } )

                inputs =
                    Dict.fromList
                        [ ( "positions", { dtype = "f64", shape = [ nodes, 2 ], data = Eval.Floats (List.concatMap (\( x, y ) -> [ x, y ]) state.positions) } )
                        , ( "pin"
                          , { dtype = "f64"
                            , shape = [ nodes ]
                            , data =
                                Eval.Floats
                                    (List.map
                                        (\i ->
                                            if Just i == pinned then
                                                1

                                            else
                                                0
                                        )
                                        (List.range 0 (nodes - 1))
                                    )
                            }
                          )
                        , square "distances" state.net.distances
                        , square "weights" (weightsOf state.net.distances)
                        ]
            in
            case Eval.runPrepared p inputs of
                Ok outs ->
                    case ( Dict.get "relaxed" outs |> Maybe.map .data, Dict.get "stress" outs |> Maybe.map .data ) of
                        ( Just (Eval.Floats xs), Just (Eval.Floats [ s ]) ) ->
                            ( { state | positions = pairs xs }, s )

                        _ ->
                            ( state, 0 )

                Err _ ->
                    ( state, 0 )


pairs : List Float -> List ( Float, Float )
pairs l =
    case l of
        x :: y :: rest ->
            ( x, y ) :: pairs rest

        _ ->
            []


{-| The layout moved 15% of the way back to the middle of the panel (stress does not care where the
layout is, so a drag can leave it off-centre).
-}
recentre : State -> State
recentre state =
    let
        n =
            toFloat nodes

        ( cx, cy ) =
            ( List.sum (List.map Tuple.first state.positions) / n, List.sum (List.map Tuple.second state.positions) / n )
    in
    { state | positions = List.map (\( x, y ) -> ( x - 0.15 * cx, y - 0.15 * cy )) state.positions }


{-| Whether the layout has stopped moving: no node moved more than a hundredth of an edge.
-}
settled : State -> State -> Bool
settled before after =
    List.all (\( ( x1, y1 ), ( x2, y2 ) ) -> abs (x1 - x2) < 0.01 && abs (y1 - y2) < 0.01) (List.map2 Tuple.pair before.positions after.positions)



-- THE DRAWING


scale : Float
scale =
    42


toScreen : ( Float, Float ) -> ( Float, Float )
toScreen ( x, y ) =
    ( 240 + scale * x, 160 - scale * y )


fromScreen : ( Float, Float ) -> ( Float, Float )
fromScreen ( sx, sy ) =
    ( (sx - 240) / scale, (160 - sy) / scale )


{-| Node `i` under the pointer (keeping the offset from where it was grabbed), the rest relaxed from
the previous layout.
-}
dragNode : State -> Int -> Drag.Solver -> List Float
dragNode state i s =
    let
        ( sx, sy ) =
            pairs s.start |> List.drop i |> List.head |> Maybe.withDefault ( 0, 0 )

        ( gx, gy ) =
            fromScreen s.grab

        ( px, py ) =
            fromScreen s.pointer

        target =
            ( clamp -5.6 5.6 (sx + px - gx), clamp -3.7 3.7 (sy + py - gy) )

        moved =
            List.indexedMap
                (\k p ->
                    if k == i then
                        target

                    else
                        p
                )
                (pairs s.previous)
    in
    relax (Just i) { state | positions = moved } |> Tuple.first |> .positions |> List.concatMap (\( x, y ) -> [ x, y ])


view : Drag.View State msg
view ctx state =
    let
        at =
            Array.fromList state.positions

        pos i =
            Array.get i at |> Maybe.withDefault ( 0, 0 ) |> toScreen

        flat =
            List.concatMap (\( x, y ) -> [ x, y ]) state.positions

        degree i =
            List.length (List.filter (\( a, b ) -> a == i || b == i) state.net.edges)

        node i p =
            Evg.circle
                [ Evg.fillStr
                    (case degree i of
                        1 ->
                            "#74c0fc"

                        2 ->
                            "#1c7ed6"

                        _ ->
                            "#e8590c"
                    )
                , Evg.strokeStr "white"
                , Evg.strokeWidth 2
                , Drag.onDrag ctx ("node" ++ String.fromInt i) (\() -> Drag.varyWith (dragNode state i) flat (\l -> { state | positions = pairs l }))
                ]
                { r = 7, center = toScreen p }
    in
    Evg.group []
        (List.map (\( a, b ) -> Evg.line [ Evg.strokeStr "#868e96", Evg.strokeWidth 1.5 ] (pos a) (pos b)) state.net.edges
            ++ List.indexedMap node state.positions
            ++ [ Evg.text [ Evg.fillStr "#495057", Evg.fontSize 12 ]
                    { x = 10, y = 312, anchor = Evg.Start }
                    ("graph " ++ String.fromInt state.seed ++ "  ·  stress " ++ String.fromFloat (toFloat (round (stress state.net state.positions * 100)) / 100))
               ]
        )
