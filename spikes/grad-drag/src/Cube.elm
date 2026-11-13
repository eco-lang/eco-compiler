module Cube exposing
    ( State, init, view
    , Vec3, corners, rotate, project, apply, turn, graph, problem, solveCorner
    , faceOn, snap, snapAngle
    )

{-| A cube in perspective. Drag a corner and the cube turns so that the corner stays under the
pointer: the solver finds the smallest rotation (three angles about x, y and z, applied after the
orientation the drag started from) that puts the corner's projection there, by the exact Jacobian
of rotation and perspective division.

The rotation and projection are written once over `Num.Ops`: plain `Float`s draw the cube, scalar
tensors are differentiated.

Let go with a face nearly looking at the camera (within `snapAngle`) and the cube turns it to face
the camera, squaring its edges too if they are nearly level: `Drag.onDrop snap` changes the state
the drag drops into, and evg animates the landing (`Drag.withDropTransition`).

@docs State, init, view
@docs Vec3, corners, rotate, project, apply, turn, graph, problem, solveCorner
@docs faceOn, snap, snapAngle

-}

import Dict
import Evg exposing (Evg)
import Evg.Animate as Animate
import Evg.Drag as Drag
import GradSolve
import Graph exposing (Graph)
import Num exposing (Ops)
import Signature as Sig
import Tensor as T exposing (Dim, F64, R0, R1, Tensor)
import Tensor.Axis as Axis
import Tensor.Eval as Eval
import Transform


type alias Vec3 a =
    ( a, a, a )


{-| The cube's orientation: where its x, y and z axes point (the columns of its rotation matrix).
-}
type alias State =
    { ex : Vec3 Float, ey : Vec3 Float, ez : Vec3 Float }


identity3 : State
identity3 =
    { ex = ( 1, 0, 0 ), ey = ( 0, 1, 0 ), ez = ( 0, 0, 1 ) }


init : State
init =
    turn [ -0.45, 0.6, 0.1 ] identity3


{-| The eight corners, in the cube's own coordinates.
-}
corners : List (Vec3 Float)
corners =
    List.map
        (\i ->
            ( if modBy 2 i == 1 then
                1

              else
                -1
            , if modBy 2 (i // 2) == 1 then
                1

              else
                -1
            , if modBy 2 (i // 4) == 1 then
                1

              else
                -1
            )
        )
        (List.range 0 7)


{-| A point of the cube, in the world.
-}
apply : State -> Vec3 Float -> Vec3 Float
apply s ( x, y, z ) =
    let
        ( ax, ay, az ) =
            s.ex

        ( bx, by, bz ) =
            s.ey

        ( cx, cy, cz ) =
            s.ez
    in
    ( ax * x + bx * y + cx * z, ay * x + by * y + cy * z, az * x + bz * y + cz * z )


{-| The orientation after turning by these angles (about x, then y, then z, in the world).
-}
turn : List Float -> State -> State
turn angles s =
    case angles of
        [ a, b, c ] ->
            let
                r v =
                    rotate Num.floats ( a, b, c ) v
            in
            { ex = r s.ex, ey = r s.ey, ez = r s.ez }

        _ ->
            s


{-| The 24 orientations in which the cube's axes line up with the screen's, so one face looks
straight at the camera: the first axis goes to one of six directions, the second to one of the four
at right angles to it, and the third follows (a right-handed frame).
-}
faceOn : List State
faceOn =
    let
        units =
            [ ( 1, 0, 0 ), ( -1, 0, 0 ), ( 0, 1, 0 ), ( 0, -1, 0 ), ( 0, 0, 1 ), ( 0, 0, -1 ) ]

        dot3 ( a, b, c ) ( x, y, z ) =
            a * x + b * y + c * z

        cross ( a, b, c ) ( x, y, z ) =
            ( b * z - c * y, c * x - a * z, a * y - b * x )
    in
    List.concatMap
        (\ex ->
            List.filterMap
                (\ey ->
                    if dot3 ex ey == 0 then
                        Just { ex = ex, ey = ey, ez = cross ex ey }

                    else
                        Nothing
                )
                units
        )
        units


{-| How near a face must be to looking at the camera for a release to snap it face-on, and how near
its edges must be to the screen's axes to square them too.
-}
snapAngle : Float
snapAngle =
    degrees 25


{-| Squares the cube up if a face nearly looks at the camera. Two steps:

  - **Tilt.** Of the six faces, take the one whose normal points most nearly at the camera (−z). If
    it is within `snapAngle` of it, turn the cube by the smallest rotation that makes it point
    straight at the camera. Otherwise the orientation stays as it is.
  - **Roll.** The face may still be spun in the plane of the screen. If its edges are within
    `snapAngle` of the screen's axes, it lands on the nearest of the 24 `faceOn` orientations
    exactly; if not, it keeps its spin.

The tilt alone decides whether to snap. Measuring the whole rotation to the nearest `faceOn`
orientation would count the spin too, and a face spun 30° on the screen would then never snap.

-}
snap : State -> State
snap s =
    let
        dot3 ( a, b, c ) ( x, y, z ) =
            a * x + b * y + c * z

        cross ( a, b, c ) ( x, y, z ) =
            ( b * z - c * y, c * x - a * z, a * y - b * x )

        neg ( a, b, c ) =
            ( -a, -b, -c )

        zOf ( _, _, z ) =
            z

        toward =
            ( 0, 0, -1 )

        -- the face normals in the world, the one nearest the camera first
        normal =
            [ s.ex, neg s.ex, s.ey, neg s.ey, s.ez, neg s.ez ]
                |> List.sortBy zOf
                |> List.head
                |> Maybe.withDefault toward

        tilt =
            acos (clamp -1 1 (dot3 normal toward))

        -- Rodrigues: turn by `tilt` about the unit axis normal × toward
        straighten v =
            let
                ( ax, ay, az ) =
                    cross normal toward

                len =
                    sqrt (ax * ax + ay * ay + az * az)
            in
            if len < 1.0e-12 then
                v

            else
                let
                    k =
                        ( ax / len, ay / len, az / len )

                    ( vx, vy, vz ) =
                        v

                    ( cx, cy, cz ) =
                        cross k v

                    ( kx, ky, kz ) =
                        k

                    kv =
                        dot3 k v * (1 - cos tilt)
                in
                ( vx * cos tilt + cx * sin tilt + kx * kv
                , vy * cos tilt + cy * sin tilt + ky * kv
                , vz * cos tilt + cz * sin tilt + kz * kv
                )

        upright =
            { ex = straighten s.ex, ey = straighten s.ey, ez = straighten s.ez }

        -- an edge direction of the face: whichever axis now lies flattest in the screen
        ( ux, uy, _ ) =
            [ upright.ex, upright.ey, upright.ez ]
                |> List.sortBy (zOf >> abs)
                |> List.head
                |> Maybe.withDefault ( 1, 0, 0 )

        quarter =
            pi / 2

        roll =
            atan2 uy ux

        spin =
            roll - quarter * toFloat (round (roll / quarter))

        -- the angle of the rotation between two orientations: cos θ = (trace − 1) / 2
        apart p =
            acos (clamp -1 1 ((dot3 p.ex upright.ex + dot3 p.ey upright.ey + dot3 p.ez upright.ez - 1) / 2))

        nearest =
            faceOn
                |> List.sortBy apart
                |> List.head
                |> Maybe.withDefault upright
    in
    if tilt > snapAngle then
        s

    else if abs spin <= snapAngle then
        nearest

    else
        upright



-- THE GEOMETRY, OVER ANY NUMBER TYPE


{-| Rotate about x by `a`, then about y by `b`, then about z by `c`.
-}
rotate : Ops n -> Vec3 n -> Vec3 n -> Vec3 n
rotate o ( a, b, c ) ( x, y, z ) =
    let
        y1 =
            o.sub (o.mul y (o.cos a)) (o.mul z (o.sin a))

        z1 =
            o.add (o.mul y (o.sin a)) (o.mul z (o.cos a))

        x2 =
            o.add (o.mul x (o.cos b)) (o.mul z1 (o.sin b))

        z2 =
            o.sub (o.mul z1 (o.cos b)) (o.mul x (o.sin b))
    in
    ( o.sub (o.mul x2 (o.cos c)) (o.mul y1 (o.sin c)), o.add (o.mul x2 (o.sin c)) (o.mul y1 (o.cos c)), z2 )


{-| Where a world point appears on the panel, in pixels: a camera `distance` in front of the origin,
looking along z.
-}
project : Ops n -> Vec3 n -> ( n, n )
project o ( x, y, z ) =
    let
        s =
            o.div (o.const focal) (o.add z (o.const distance))
    in
    ( o.add (o.const (width / 2)) (o.mul s x), o.sub (o.const (height / 2)) (o.mul s y) )


focal : Float
focal =
    300


distance : Float
distance =
    6



-- THE MODEL


type P
    = P


type Two
    = Two


type One
    = One


pDim : Dim P
pDim =
    T.dim P 3


twoDim : Dim Two
twoDim =
    T.dim Two 2


{-| The projection of the world point `corner` after turning it by `angles`.
-}
point : Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 Two)
point corner angles =
    let
        o =
            Num.tensors (T.fromList T.float64 T.scalar [ 0 ])

        each : Int -> Tensor Float F64 (R1 P) -> Tensor Float F64 R0
        each i v =
            v |> T.slice Axis.retag0of1 i (T.dim One 1) |> T.sumAll

        ( px, py ) =
            project o (rotate o ( each 0 angles, each 1 angles, each 2 angles ) ( each 0 corner, each 1 corner, each 2 corner ))
    in
    T.stack Axis.liftRank0 twoDim [ px, py ]


{-| Inputs the angles and the corner (in the world, before turning); outputs its projection and the
Jacobian (2 × 3).
-}
graph : Result (List String) Graph
graph =
    Graph.build "cube"
        (Sig.pair (Sig.label "angles" (Sig.tensor T.float64 (T.r1 pDim))) (Sig.label "corner" (Sig.tensor T.float64 (T.r1 pDim))))
        (Sig.pair (Sig.label "point" (Sig.tensor T.float64 (T.r1 twoDim))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 twoDim pDim))))
        (\( angles, corner ) -> ( point corner angles, Transform.jacobian (point corner) angles ))


compiled : GradSolve.Compiled
compiled =
    GradSolve.compile graph


{-| Turning the world point `corner`.
-}
problem : Vec3 Float -> GradSolve.Problem
problem ( x, y, z ) =
    { compiled = compiled
    , fixed = Dict.singleton "corner" { dtype = "f64", shape = [ 3 ], data = Eval.Floats [ x, y, z ] }

    -- angles are periodic: no bounds, so the cube can be spun round and round
    , lower = List.repeat 3 -(1 / 0)
    , upper = List.repeat 3 (1 / 0)
    }


{-| The turn that puts corner `i` (of the cube as it was when the drag began) under the pointer.
-}
solveCorner : State -> Int -> Drag.Solver -> List Float
solveCorner state i s =
    let
        world =
            List.drop i corners |> List.head |> Maybe.withDefault ( 1, 1, 1 ) |> apply state

        ( mx, my ) =
            project Num.floats world

        ( gx, gy ) =
            s.grab

        ( px, py ) =
            s.pointer
    in
    (GradSolve.solve { maxEvaluations = 8, tolerance = 0.05 } (problem world) [ px - (gx - mx), py - (gy - my) ] s.previous).params



-- THE DRAWING


{-| Where turning can take a corner: the outline of the sphere the corners lie on (radius √3), seen
from the camera, `focal · r / √(distance² − r²)` pixels across. Shown while a corner is dragged.
-}
reachable : Evg Never
reachable =
    Evg.circle [ Evg.fillStr "none", Evg.strokeStr "#adb5bd", Evg.strokeWidth 1, Evg.dashPattern [ 4, 4 ] ]
        { r = focal * sqrt 3 / sqrt (distance * distance - 3), center = ( width / 2, height / 2 ) }


width : Float
width =
    480


height : Float
height =
    300


{-| Each face: the axis it is across, its side, and its corners in order around it.
-}
faces : List { normal : Vec3 Float, corners : List Int }
faces =
    [ { normal = ( -1, 0, 0 ), corners = [ 0, 2, 6, 4 ] }
    , { normal = ( 1, 0, 0 ), corners = [ 1, 5, 7, 3 ] }
    , { normal = ( 0, -1, 0 ), corners = [ 0, 4, 5, 1 ] }
    , { normal = ( 0, 1, 0 ), corners = [ 2, 3, 7, 6 ] }
    , { normal = ( 0, 0, -1 ), corners = [ 0, 1, 3, 2 ] }
    , { normal = ( 0, 0, 1 ), corners = [ 4, 6, 7, 5 ] }
    ]


view : Drag.View State msg
view ctx state =
    let
        world =
            List.map (apply state) corners

        at i =
            List.drop i world |> List.head |> Maybe.withDefault ( 0, 0, 0 )

        dot ( a, b, c ) ( x, y, z ) =
            a * x + b * y + c * z

        visible face =
            let
                n =
                    apply state face.normal

                ( cx, cy, cz ) =
                    apply state face.normal
            in
            -- the face's centre is its normal; the camera is at (0, 0, −distance)
            dot n ( cx, cy, cz + distance ) < 0

        light =
            ( -0.45, 0.55, -0.7 )

        shade face =
            let
                l =
                    0.35 + 0.6 * max 0 (dot (apply state face.normal) light / 1.0)
            in
            "hsl(212, 55%, " ++ String.fromInt (round (35 + 45 * l)) ++ "%)"

        shown =
            List.filter visible faces

        -- Every face and every corner is always drawn, in the same order, the hidden ones
        -- transparent: evg animates a drop by blending the two drawings shape by shape, so the shapes
        -- must line up.
        drawFace face =
            let
                opacity =
                    if visible face then
                        1

                    else
                        0
            in
            Evg.polygon [ Evg.fillStr (shade face), Evg.fillOpacity opacity, Evg.strokeStr "#1c3d5a", Evg.strokeOpacity opacity, Evg.strokeWidth 1.5, Evg.linejoinRound ]
                (List.map (at >> project Num.floats) face.corners)

        seen i =
            List.any (\face -> List.member i face.corners) shown

        handle i =
            Evg.circle
                ([ Evg.fillStr "#e8590c"
                 , Evg.strokeStr "white"
                 , Evg.strokeWidth 2
                 , Drag.onDrag ctx
                    ("corner" ++ String.fromInt i)
                    (\() ->
                        Drag.varyWith (solveCorner state i) [ 0, 0, 0 ] (\angles -> turn angles state)
                            |> Drag.onDrop snap
                            |> Drag.withFloatingWith { ghost = Just 0.35, tether = Nothing }
                            |> Drag.withDropTransition 0.4 Animate.easeOut
                            |> Drag.withOverlay reachable
                    )
                 ]
                    ++ (if seen i then
                            []

                        else
                            [ Evg.opacity 0, Evg.style "pointer-events: none" ]
                       )
                )
                { r = 7, center = project Num.floats (at i) }
    in
    Evg.group [] (List.map drawFace faces ++ List.map handle (List.range 0 7))
