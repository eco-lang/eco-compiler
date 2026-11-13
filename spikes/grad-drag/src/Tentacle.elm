module Tentacle exposing
    ( State, init, Method(..), view, drawing, handleKey
    , count, limit, positions, graph, problem, solveFor, pinnedProblem, solvePinned, pinWeight
    )

{-| A tentacle of 12 segments. Each joint bends at most `limit` from the one before; the first turns
freely. Drag any joint: the angles of the joints up to it change so it follows the pointer, and the
segments beyond it ride along.

The same drawing is made draggable two ways (`Method`):

  - `BuiltIn`: evg's `Drag.varyN` with `Drag.constrain`. evg finds the angles by
    Levenberg–Marquardt with finite differences: every derivative is a re-render of the drawing.
  - `Gradient`: `Drag.varyWith` and `GradSolve`, with the exact Jacobian of the joint's position
    computed by the tensor package from a model of the tentacle (`graph`).

@docs State, init, Method, view, drawing, handleKey
@docs count, limit, positions, graph, problem, solveFor, pinnedProblem, solvePinned, pinWeight

With the tip pinned (`view`'s second argument), dragging another joint keeps the tip where it was.
The built-in side says so declaratively, `Drag.pin` on the tip's position (a penalty in evg's
solver); the gradient side solves for four targets at once, the joint under the pointer and the tip
where it was, by the exact 4 × 12 Jacobian.

Past the tentacle's reach, the dragged handle floats free under the pointer (`Drag.withFloating`)
and a faded copy marks where it will land; a dashed circle (`Drag.withOverlay`) shows how far that
joint can reach.

-}

import Dict
import Evg exposing (Evg)
import Evg.Drag as Drag
import GradSolve
import Graph exposing (Graph)
import Signature as Sig
import Tensor as T exposing (Dim, F64, R1, Tensor)
import Tensor.Axis as Axis
import Tensor.Eval as Eval
import Transform


{-| The angle of each joint relative to the one before, in radians. The first is relative to
straight up.
-}
type alias State =
    { angles : List Float }


type Method
    = BuiltIn
    | Gradient


count : Int
count =
    12


segment : Float
segment =
    19


base : ( Float, Float )
base =
    ( 160, 262 )


{-| How far a joint may bend from the one before: 40°.
-}
limit : Float
limit =
    degrees 40


init : State
init =
    { angles = 0.35 :: List.repeat (count - 1) -0.12 }


{-| The first joint turns freely, round and round (angles are periodic, so it needs no bound).
-}
lower : List Float
lower =
    -(1 / 0) :: List.repeat (count - 1) -limit


upper : List Float
upper =
    (1 / 0) :: List.repeat (count - 1) limit


{-| The end of every segment, from the angles: plain Elm, for drawing.
-}
positions : List Float -> List ( Float, Float )
positions angles =
    let
        ( bx, by ) =
            base
    in
    List.foldl
        (\a ( heading, ( x, y ), acc ) ->
            let
                h =
                    heading + a

                p =
                    ( x + segment * cos h, y + segment * sin h )
            in
            ( h, p, p :: acc )
        )
        ( -pi / 2, ( bx, by ), [] )
        angles
        |> (\( _, _, acc ) -> List.reverse acc)



-- THE MODEL


type Joints
    = Joints


type Two
    = Two


joints : Dim Joints
joints =
    T.dim Joints count


two : Dim Two
two =
    T.dim Two 2


{-| The picked joint's position: headings are the running sum of the angles, positions the running
sum of the segments. `pick` is one-hot, so one graph serves every joint.
-}
point : Tensor Float F64 (R1 Joints) -> Tensor Float F64 (R1 Joints) -> Tensor Float F64 (R1 Two)
point pick angles =
    let
        ( x, y ) =
            pointXY pick angles
    in
    T.stack Axis.liftRank0 two [ x, y ]


pointXY : Tensor Float F64 (R1 Joints) -> Tensor Float F64 (R1 Joints) -> ( Tensor Float F64 T.R0, Tensor Float F64 T.R0 )
pointXY pick angles =
    let
        ( bx, by ) =
            base

        heading =
            angles |> T.cumsum Axis.last1 |> T.shift (-pi / 2)

        along f origin =
            heading |> f |> T.scale segment |> T.cumsum Axis.last1 |> T.shift origin |> T.times pick |> T.sumAll
    in
    ( along T.cos bx, along T.sin by )


type Four
    = Four


{-| How much more the tip's place counts than the dragged joint's when both cannot be had: the
tip's two rows are scaled by this, so in the squared error it weighs `pinWeight²` times as much,
and an impossible drag moves the joint, not the tip (evg's `pin` is a penalty too).
-}
pinWeight : Float
pinWeight =
    10


{-| The picked joint's position and the tip's (scaled by `pinWeight`), as one 4-vector.
-}
pointAndTip : Tensor Float F64 (R1 Joints) -> Tensor Float F64 (R1 Joints) -> Tensor Float F64 (R1 Four)
pointAndTip pick angles =
    let
        ( x, y ) =
            pointXY pick angles

        ( tx, ty ) =
            pointXY (T.fromList T.float64 (T.r1 joints) (oneHot (count - 1))) angles
    in
    T.stack Axis.liftRank0 (T.dim Four 4) [ x, y, T.scale pinWeight tx, T.scale pinWeight ty ]


oneHot : Int -> List Float
oneHot i =
    List.map
        (\j ->
            if j == i then
                1

            else
                0
        )
        (List.range 0 (count - 1))


{-| Like `graph`, with the tip's position as well: outputs 4 values and their Jacobian (4 × 12).
-}
pinnedGraph : Result (List String) Graph
pinnedGraph =
    Graph.build "tentaclePinned"
        (Sig.pair (Sig.label "theta" (Sig.tensor T.float64 (T.r1 joints))) (Sig.label "pick" (Sig.tensor T.float64 (T.r1 joints))))
        (Sig.pair (Sig.label "point" (Sig.tensor T.float64 (T.r1 (T.dim Four 4)))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 (T.dim Four 4) joints))))
        (\( theta, pick ) -> ( pointAndTip pick theta, Transform.jacobian (pointAndTip pick) theta ))


pinnedCompiled : GradSolve.Compiled
pinnedCompiled =
    GradSolve.compile pinnedGraph


{-| Moving joint `i` with the tip held.
-}
pinnedProblem : Int -> GradSolve.Problem
pinnedProblem i =
    { compiled = pinnedCompiled
    , fixed = Dict.singleton "pick" { dtype = "f64", shape = [ count ], data = Eval.Floats (oneHot i) }
    , lower = lower
    , upper = upper
    }


{-| Inputs `theta` (the angles) and `pick` (which joint, one-hot); outputs the joint's position and
its Jacobian with respect to the angles (2 × 12).
-}
graph : Result (List String) Graph
graph =
    Graph.build "tentacle"
        (Sig.pair (Sig.label "theta" (Sig.tensor T.float64 (T.r1 joints))) (Sig.label "pick" (Sig.tensor T.float64 (T.r1 joints))))
        (Sig.pair (Sig.label "point" (Sig.tensor T.float64 (T.r1 two))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 two joints))))
        (\( theta, pick ) -> ( point pick theta, Transform.jacobian (point pick) theta ))


{-| `graph`, prepared once.
-}
compiled : GradSolve.Compiled
compiled =
    GradSolve.compile graph


{-| Moving joint `i`.
-}
problem : Int -> GradSolve.Problem
problem i =
    { compiled = compiled
    , fixed =
        Dict.singleton "pick"
            { dtype = "f64"
            , shape = [ count ]
            , data =
                Eval.Floats
                    (List.indexedMap
                        (\j _ ->
                            if j == i then
                                1

                            else
                                0
                        )
                        (List.repeat count ())
                    )
            }
    , lower = lower
    , upper = upper
    }


{-| The angles that put joint `i`, grabbed at `grab` when the angles were `start`, under the
pointer: the gradient solver for `Drag.varyWith`.
-}
solveFor : Int -> Drag.Solver -> List Float
solveFor i s =
    let
        ( gx, gy ) =
            s.grab

        ( mx, my ) =
            List.drop i (positions s.start) |> List.head |> Maybe.withDefault base

        ( px, py ) =
            s.pointer
    in
    (GradSolve.solve { maxEvaluations = 12, tolerance = 0.05 } (problem i) [ px - (gx - mx), py - (gy - my) ] s.previous).params


{-| Joint `i` under the pointer and the tip where it was when the drag began: four targets.
-}
solvePinned : Int -> Drag.Solver -> List Float
solvePinned i s =
    let
        at k angles =
            List.drop k (positions angles) |> List.head |> Maybe.withDefault base

        ( gx, gy ) =
            s.grab

        ( mx, my ) =
            at i s.start

        ( tx, ty ) =
            at (count - 1) s.start

        ( px, py ) =
            s.pointer
    in
    (GradSolve.solve { maxEvaluations = 12, tolerance = 0.05 } (pinnedProblem i) [ px - (gx - mx), py - (gy - my), pinWeight * tx, pinWeight * ty ] s.previous).params



-- THE DRAWING


view : Method -> Bool -> Drag.View State msg
view method pinTip ctx state =
    let
        pinning i =
            pinTip && i < count - 1

        tipOf st =
            List.drop (count - 1) (positions st.angles) |> List.head |> Maybe.map (\( x, y ) -> [ x, y ]) |> Maybe.withDefault []

        bends n st =
            Drag.all (List.map (\a -> Drag.inOrder [ -limit, a, limit ]) (List.drop 1 (List.take n st.angles)))

        solve i =
            case method of
                BuiltIn ->
                    if pinning i then
                        -- every joint may move, the tip may not
                        Drag.varyN state.angles (\all -> { angles = all })
                            |> Drag.constrain (bends count)
                            |> Drag.pin tipOf

                    else
                        Drag.varyN (List.take (i + 1) state.angles) (\pre -> { angles = pre ++ List.drop (i + 1) state.angles })
                            |> Drag.constrain (bends (i + 1))

                Gradient ->
                    if pinning i then
                        Drag.varyWith (solvePinned i) state.angles (\angles -> { angles = angles })

                    else
                        Drag.varyWith (solveFor i) state.angles (\angles -> { angles = angles })

        reach i =
            Evg.circle [ Evg.fillStr "none", Evg.strokeStr "#adb5bd", Evg.strokeWidth 1, Evg.dashPattern [ 4, 4 ] ]
                { r = segment * toFloat (i + 1), center = base }

        spec i () =
            solve i
                |> Drag.withFloatingWith { ghost = Just 0.35, tether = Nothing }
                |> Drag.withOverlay (reach i)

        pinMark =
            case ( pinTip, List.drop (count - 1) (positions state.angles) |> List.head ) of
                ( True, Just tip ) ->
                    [ Evg.circle [ Evg.fillStr "none", Evg.strokeStr "#212529", Evg.strokeWidth 2 ] { r = 9, center = tip } ]

                _ ->
                    []
    in
    Evg.group []
        (drawing
            (case method of
                BuiltIn ->
                    "#1c7ed6"

                Gradient ->
                    "#e8590c"
            )
            (\i -> Drag.onDrag ctx (handleKey i) (spec i))
            state
            :: pinMark
        )


handleKey : Int -> String
handleKey i =
    "joint" ++ String.fromInt i


{-| The tentacle in a colour, with these attributes on joint i's handle.
-}
drawing : String -> (Int -> Evg.Attribute { fill : Evg.Supported, stroke : Evg.Supported, opacity : Evg.Supported, filter : Evg.Supported, transform : Evg.Supported, events : Evg.Supported } msg) -> State -> Evg msg
drawing colour handle state =
    let
        ps =
            positions state.angles

        chain =
            base :: ps

        width i =
            13 - 9 * toFloat i / toFloat count

        segments =
            List.indexedMap
                (\i ( a, b ) -> Evg.line [ Evg.strokeStr "#adb5bd", Evg.strokeWidth (width i), Evg.linecapRound ] a b)
                (List.map2 Tuple.pair chain ps)

        handles =
            List.indexedMap
                (\i p ->
                    Evg.circle
                        [ Evg.fillStr colour
                        , Evg.strokeStr "white"
                        , Evg.strokeWidth 1.5
                        , handle i
                        ]
                        { r = 7.5 - 3 * toFloat i / toFloat count, center = p }
                )
                ps
    in
    Evg.group []
        (Evg.rect [ Evg.fillStr "#495057", Evg.cornerRadius 4 ] { x = Tuple.first base - 26, y = Tuple.second base, width = 52, height = 12 }
            :: segments
            ++ handles
        )
