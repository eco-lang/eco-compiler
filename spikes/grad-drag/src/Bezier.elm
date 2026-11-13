module Bezier exposing
    ( State, init, view
    , Pts, point, velocity, acceleration, unitTangent, curvature, lowest, nearestU, length
    , curveProblem, tangentProblem, bendProblem, lowestProblem, scaleU, holdWeight, tangentLength, bendScale, comb
    )

{-| A cubic Bézier curve shaped by dragging what it looks like, not its control points:

  - **the curve itself, anywhere**: the grabbed point follows the pointer. Where along the curve it
    is (its parameter u) is one of the solver's unknowns, so a drag along the curve slides the grab
    point and a drag across it reshapes the curve (point, 5 unknowns, nonlinear in u);
  - **the tangent** at the selected point (the last one grabbed on the curve): drag its arrow to
    turn the curve's direction there, the point held (unit tangent: nonlinear);
  - **the curvature** there, by a curvature comb: a handle on the normal at `comb · κ` from the
    point (on the curve where it is straight, on the other side when it bends the other way). Drag
    it out to bend tighter, in to straighten; the point and the direction are held
    (κ = (x′y″ − y′x″) / |B′|³). The dashed circle is the osculating circle, the one that fits the
    curve best there;
  - **the lowest point**: a smooth maximum of screen y over 48 samples (weights exp(0.15 y)), dragged
    anywhere. (If an end is the lowest point, this drag cannot move it: the ends are not its
    unknowns.)

All four move the two inner control points (the ends stay where they are; drag their handles to
move them). Each feature is written once over `Num.Ops`: plain `Float`s draw it, scalar tensors give
its exact Jacobian.

@docs State, init, view
@docs Pts, point, velocity, acceleration, unitTangent, curvature, lowest, nearestU, length
@docs curveProblem, tangentProblem, bendProblem, lowestProblem, scaleU, holdWeight, tangentLength, bendScale, comb

-}

import Dict
import Evg exposing (Evg)
import Evg.Drag as Drag
import GradSolve
import Graph exposing (Graph)
import Num exposing (Ops)
import Signature as Sig
import Tensor as T exposing (Dim, F64, R0, R1, Tensor)
import Tensor.Axis as Axis
import Tensor.Eval as Eval
import Transform


type alias Vec n =
    ( n, n )


{-| The four control points.
-}
type alias Pts n =
    { p0 : Vec n, p1 : Vec n, p2 : Vec n, p3 : Vec n }


{-| The control points, and the selected point's parameter (where the tangent and the osculating
circle are shown).
-}
type alias State =
    { pts : Pts Float, sel : Float }


init : State
init =
    { pts = { p0 = ( 50, 140 ), p1 = ( 130, 30 ), p2 = ( 310, 330 ), p3 = ( 430, 120 ) }, sel = 0.35 }



-- THE CURVE AND ITS FEATURES, OVER ANY NUMBER TYPE


combine : Ops n -> List ( n, Vec n ) -> Vec n
combine o terms =
    ( List.foldl (\( w, ( x, _ ) ) acc -> o.add acc (o.mul w x)) (o.const 0) terms
    , List.foldl (\( w, ( _, y ) ) acc -> o.add acc (o.mul w y)) (o.const 0) terms
    )


sub2 : Ops n -> Vec n -> Vec n -> Vec n
sub2 o ( a, b ) ( c, d ) =
    ( o.sub a c, o.sub b d )


{-| B(u) = (1 − u)³ P₀ + 3(1 − u)² u P₁ + 3(1 − u) u² P₂ + u³ P₃.
-}
point : Ops n -> Pts n -> n -> Vec n
point o p u =
    let
        a =
            o.sub (o.const 1) u
    in
    combine o
        [ ( o.mul a (o.mul a a), p.p0 )
        , ( o.mul (o.const 3) (o.mul (o.mul a a) u), p.p1 )
        , ( o.mul (o.const 3) (o.mul a (o.mul u u)), p.p2 )
        , ( o.mul u (o.mul u u), p.p3 )
        ]


{-| B′(u).
-}
velocity : Ops n -> Pts n -> n -> Vec n
velocity o p u =
    let
        a =
            o.sub (o.const 1) u
    in
    combine o
        [ ( o.mul (o.const 3) (o.mul a a), sub2 o p.p1 p.p0 )
        , ( o.mul (o.const 6) (o.mul a u), sub2 o p.p2 p.p1 )
        , ( o.mul (o.const 3) (o.mul u u), sub2 o p.p3 p.p2 )
        ]


{-| B″(u).
-}
acceleration : Ops n -> Pts n -> n -> Vec n
acceleration o p u =
    let
        a =
            o.sub (o.const 1) u

        second q r s =
            sub2 o (sub2 o s r) (sub2 o r q)
    in
    combine o
        [ ( o.mul (o.const 6) a, second p.p0 p.p1 p.p2 )
        , ( o.mul (o.const 6) u, second p.p1 p.p2 p.p3 )
        ]


unitTangent : Ops n -> Pts n -> n -> Vec n
unitTangent o p u =
    let
        ( vx, vy ) =
            velocity o p u

        speed =
            o.sqrt (o.add (o.mul vx vx) (o.mul vy vy))
    in
    ( o.div vx speed, o.div vy speed )


{-| Signed curvature, κ = (x′y″ − y′x″) / |B′|³ (positive turning towards +y, which is down on the
screen).
-}
curvature : Ops n -> Pts n -> n -> n
curvature o p u =
    let
        ( vx, vy ) =
            velocity o p u

        ( ax, ay ) =
            acceleration o p u

        speed2 =
            o.add (o.mul vx vx) (o.mul vy vy)
    in
    o.div (o.sub (o.mul vx ay) (o.mul vy ax)) (o.mul speed2 (o.sqrt speed2))


samples : List Float
samples =
    List.map (\k -> toFloat k / 47) (List.range 0 47)


{-| The curve's lowest point on the screen (largest y), smoothly: the samples' mean weighted by
exp(0.15 (y − 300)), which keeps only the bottom of the curve.
-}
lowest : Ops n -> Pts n -> Vec n
lowest o p =
    let
        pts =
            List.map (\u -> point o p (o.const u)) samples

        weights =
            List.map (\( _, y ) -> o.exp (o.mul (o.const 0.15) (o.sub y (o.const 300)))) pts

        total =
            List.foldl o.add (o.const 0) weights

        mean f =
            o.div (List.foldl o.add (o.const 0) (List.map2 (\w q -> o.mul w (f q)) weights pts)) total
    in
    ( mean Tuple.first, mean Tuple.second )



-- IN PLAIN ELM


floats : Ops Float
floats =
    Num.floats


{-| The parameter of the curve's point nearest `q` (a fine search, then a few Newton steps on
|B(u) − q|²).
-}
nearestU : Pts Float -> Vec Float -> Float
nearestU p ( qx, qy ) =
    let
        dist2 u =
            let
                ( x, y ) =
                    point floats p u
            in
            (x - qx) ^ 2 + (y - qy) ^ 2

        coarse =
            List.map (\k -> toFloat k / 200) (List.range 0 200)
                |> List.foldl
                    (\u best ->
                        if dist2 u < dist2 best then
                            u

                        else
                            best
                    )
                    0

        newton _ u =
            let
                ( x, y ) =
                    point floats p u

                ( vx, vy ) =
                    velocity floats p u

                ( ax, ay ) =
                    acceleration floats p u

                g =
                    (x - qx) * vx + (y - qy) * vy

                h =
                    vx * vx + vy * vy + (x - qx) * ax + (y - qy) * ay
            in
            if h > 0 then
                clamp 0 1 (u - g / h)

            else
                u
    in
    List.foldl newton coarse (List.range 1 4)


{-| Arc length, by the midpoint rule over 64 pieces.
-}
length : Pts Float -> Float
length p =
    List.range 0 63
        |> List.map
            (\k ->
                let
                    ( vx, vy ) =
                        velocity floats p ((toFloat k + 0.5) / 64)
                in
                sqrt (vx * vx + vy * vy) / 64
            )
        |> List.sum



-- THE MODELS


type P
    = P


type Out
    = Out


type One
    = One


dimP : Int -> Dim P
dimP n =
    T.dim P n


scalars : Tensor Float F64 (R1 n) -> Int -> Tensor Float F64 R0
scalars v i =
    v |> T.slice Axis.retag0of1 i (T.dim One 1) |> T.sumAll


o0 : Ops (Tensor Float F64 R0)
o0 =
    Num.tensors (T.fromList T.float64 T.scalar [ 0 ])


{-| The inner control points from the unknowns (the first four), the ends from the fixed input
`ends` (x₀, y₀, x₃, y₃).
-}
ptsOf : Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 P) -> Pts (Tensor Float F64 R0)
ptsOf ends w =
    let
        e =
            scalars ends

        v =
            scalars w
    in
    { p0 = ( e 0, e 1 ), p1 = ( v 0, v 1 ), p2 = ( v 2, v 3 ), p3 = ( e 2, e 3 ) }


{-| A graph from unknowns to `outs` residuals, with their Jacobian; `ends` and `extra` fixed.
-}
build : String -> Int -> Int -> Int -> (Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 P) -> List (Tensor Float F64 R0)) -> GradSolve.Compiled
build name unknowns extras outs f =
    let
        outDim =
            T.dim Out outs

        model ends extra w =
            T.stack Axis.liftRank0 outDim (f ends extra w)
    in
    GradSolve.compile
        (Graph.build name
            (Sig.pair (Sig.label "params" (Sig.tensor T.float64 (T.r1 (dimP unknowns))))
                (Sig.pair (Sig.label "ends" (Sig.tensor T.float64 (T.r1 (dimP 4)))) (Sig.label "extra" (Sig.tensor T.float64 (T.r1 (dimP extras)))))
            )
            (Sig.pair (Sig.label "point" (Sig.tensor T.float64 (T.r1 outDim))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 outDim (dimP unknowns)))))
            (\( w, ( ends, extra ) ) -> ( model ends extra w, Transform.jacobian (model ends extra) w ))
        )


{-| The curve's parameter is an unknown scaled by this, so that sliding along the curve and moving
the control points cost about the same to the minimum-norm step.
-}
scaleU : Float
scaleU =
    300


{-| How much more a held quantity counts than the dragged one (rows scaled by this).
-}
holdWeight : Float
holdWeight =
    10


{-| The tangent arrow's length, in pixels (the tangent residual is the arrow's tip).
-}
tangentLength : Float
tangentLength =
    50


{-| The curvature comb: the bend handle is `comb · κ` pixels from the point along the normal (κ = 1/100 px
puts it 60 px out). Unlike the osculating circle's centre it stays near the curve, and is on it
where the curve is straight.
-}
comb : Float
comb =
    6000


{-| Curvature residuals are scaled by this (κ is about 1/100 px).
-}
bendScale : Float
bendScale =
    3000


curveCompiled : GradSolve.Compiled
curveCompiled =
    build "bezierCurve" 5 1 2 <|
        \ends _ w ->
            let
                ( x, y ) =
                    point o0 (ptsOf ends w) (o0.div (scalars w 4) (o0.const scaleU))
            in
            [ x, y ]


tangentCompiled : GradSolve.Compiled
tangentCompiled =
    build "bezierTangent" 4 1 4 <|
        \ends extra w ->
            let
                p =
                    ptsOf ends w

                u =
                    scalars extra 0

                ( x, y ) =
                    point o0 p u

                ( tx, ty ) =
                    unitTangent o0 p u

                k =
                    o0.const
            in
            [ o0.mul (k holdWeight) x, o0.mul (k holdWeight) y, o0.mul (k tangentLength) tx, o0.mul (k tangentLength) ty ]


bendCompiled : GradSolve.Compiled
bendCompiled =
    build "bezierBend" 4 1 5 <|
        \ends extra w ->
            let
                p =
                    ptsOf ends w

                u =
                    scalars extra 0

                ( x, y ) =
                    point o0 p u

                ( tx, ty ) =
                    unitTangent o0 p u

                k =
                    o0.const
            in
            [ o0.mul (k holdWeight) x, o0.mul (k holdWeight) y, o0.mul (k (holdWeight * tangentLength)) tx, o0.mul (k (holdWeight * tangentLength)) ty, o0.mul (k bendScale) (curvature o0 p u) ]


lowestCompiled : GradSolve.Compiled
lowestCompiled =
    build "bezierLowest" 4 1 2 <|
        \ends _ w ->
            let
                ( x, y ) =
                    lowest o0 (ptsOf ends w)
            in
            [ x, y ]


problemFor : GradSolve.Compiled -> Int -> Pts Float -> List Float -> GradSolve.Problem
problemFor compiled unknowns p extra =
    let
        ( x0, y0 ) =
            p.p0

        ( x3, y3 ) =
            p.p3
    in
    { compiled = compiled
    , fixed =
        Dict.fromList
            [ ( "ends", { dtype = "f64", shape = [ 4 ], data = Eval.Floats [ x0, y0, x3, y3 ] } )
            , ( "extra", { dtype = "f64", shape = [ 1 ], data = Eval.Floats (extra ++ List.repeat (1 - List.length extra) 0) } )
            ]
    , lower = List.repeat 4 -(1 / 0) ++ List.repeat (unknowns - 4) 0
    , upper = List.repeat 4 (1 / 0) ++ List.repeat (unknowns - 4) scaleU
    }


{-| Dragging the curve: unknowns x₁, y₁, x₂, y₂ and scaleU · u.
-}
curveProblem : Pts Float -> GradSolve.Problem
curveProblem p =
    problemFor curveCompiled 5 p []


{-| Turning the tangent at u: residuals the held point (×holdWeight) and the arrow's tip.
-}
tangentProblem : Pts Float -> Float -> GradSolve.Problem
tangentProblem p u =
    problemFor tangentCompiled 4 p [ u ]


{-| Bending at u: the held point and direction (×holdWeight) and the curvature (×bendScale).
-}
bendProblem : Pts Float -> Float -> GradSolve.Problem
bendProblem p u =
    problemFor bendCompiled 4 p [ u ]


lowestProblem : Pts Float -> GradSolve.Problem
lowestProblem p =
    problemFor lowestCompiled 4 p []



-- SOLVERS FOR THE DRAGS


inner : Pts Float -> List Float
inner p =
    [ Tuple.first p.p1, Tuple.second p.p1, Tuple.first p.p2, Tuple.second p.p2 ]


withInner : Pts Float -> List Float -> Pts Float
withInner p l =
    case l of
        x1 :: y1 :: x2 :: y2 :: _ ->
            { p | p1 = ( x1, y1 ), p2 = ( x2, y2 ) }

        _ ->
            p


solve : GradSolve.Problem -> List Float -> List Float -> List Float
solve problem target previous =
    (GradSolve.solve { maxEvaluations = 6, tolerance = 0.05 } problem target previous).params


view : Drag.View State msg
view ctx state =
    let
        p =
            state.pts

        u =
            state.sel

        ( sx, sy ) =
            point floats p u

        ( tx, ty ) =
            unitTangent floats p u

        k =
            curvature floats p u

        -- the osculating circle's centre: 1/κ along the normal (κ > 0 turns towards +y)
        centre =
            ( sx - ty / k, sy + tx / k )

        curve =
            List.map (\i -> point floats p (toFloat i / 120)) (List.range 0 120)

        floating spec =
            spec |> Drag.withFloatingWith { ghost = Just 0.35, tether = Nothing }

        -- grabbing the curve: the grab's parameter from where it was grabbed; the unknowns also
        -- carry it (scaled), so the grab point can slide
        dragCurve =
            Drag.varyWith
                (\s ->
                    let
                        start =
                            withInner p s.start

                        ug =
                            nearestU start s.grab

                        ( bx, by ) =
                            point floats start ug

                        ( gx, gy ) =
                            s.grab

                        ( px, py ) =
                            s.pointer

                        previous =
                            if List.length s.previous == 5 then
                                s.previous

                            else
                                inner p ++ [ scaleU * ug ]
                    in
                    solve (curveProblem p) [ px - (gx - bx), py - (gy - by) ] previous
                )
                (inner p)
                (\l -> { pts = withInner p l, sel = List.drop 4 l |> List.head |> Maybe.map (\s -> s / scaleU) |> Maybe.withDefault state.sel })

        dragTangent =
            Drag.varyWith
                (\s ->
                    let
                        ( px, py ) =
                            s.pointer

                        d =
                            sqrt ((px - sx) ^ 2 + (py - sy) ^ 2) |> max 1.0e-6
                    in
                    solve (tangentProblem p u) [ holdWeight * sx, holdWeight * sy, tangentLength * (px - sx) / d, tangentLength * (py - sy) / d ] s.previous
                )
                (inner p)
                (\l -> { state | pts = withInner p l })

        -- the normal κ > 0 bends towards
        ( nx, ny ) =
            ( -ty, tx )

        combHandle =
            ( sx + comb * k * nx, sy + comb * k * ny )

        dragBend =
            Drag.varyWith
                (\s ->
                    let
                        -- how far along the normal the pointer has moved the handle
                        ( dx, dy ) =
                            ( Tuple.first s.pointer - Tuple.first s.grab, Tuple.second s.pointer - Tuple.second s.grab )

                        wanted =
                            k + (dx * nx + dy * ny) / comb
                    in
                    solve (bendProblem p u) [ holdWeight * sx, holdWeight * sy, holdWeight * tangentLength * tx, holdWeight * tangentLength * ty, bendScale * wanted ] s.previous
                )
                (inner p)
                (\l -> { state | pts = withInner p l })

        ( lx, ly ) =
            lowest floats p

        dragLowest =
            Drag.varyWith
                (\s ->
                    let
                        ( mx, my ) =
                            lowest floats (withInner p s.start)

                        ( gx, gy ) =
                            s.grab

                        ( px, py ) =
                            s.pointer
                    in
                    solve (lowestProblem p) [ px - (gx - mx), py - (gy - my) ] s.previous
                )
                (inner p)
                (\l -> { state | pts = withInner p l })

        moveControl which =
            Drag.varyWith
                (\s ->
                    case s.start of
                        [ x, y ] ->
                            [ x + Tuple.first s.pointer - Tuple.first s.grab, y + Tuple.second s.pointer - Tuple.second s.grab ]

                        _ ->
                            s.previous
                )
                (let
                    ( x, y ) =
                        which p
                 in
                 [ x, y ]
                )

        control name which set =
            let
                ( x, y ) =
                    which p
            in
            Evg.circle
                [ Evg.fillStr "white"
                , Evg.strokeStr "#868e96"
                , Evg.strokeWidth 1.5
                , Drag.onDrag ctx
                    name
                    (\() ->
                        moveControl which
                            (\l ->
                                case l of
                                    [ cx, cy ] ->
                                        { state | pts = set ( cx, cy ) }

                                    _ ->
                                        state
                            )
                    )
                ]
                { r = 5, center = ( x, y ) }

        bendCircle =
            (if abs k > 1 / 2000 then
                [ Evg.circle [ Evg.fillStr "none", Evg.strokeStr "#2f9e44", Evg.strokeWidth 1, Evg.dashPattern [ 3, 4 ] ] { r = 1 / abs k, center = centre } ]

             else
                []
            )
                ++ [ Evg.line [ Evg.strokeStr "#2f9e44", Evg.strokeWidth 1.5 ] ( sx, sy ) combHandle
                   , Evg.circle [ Evg.fillStr "#2f9e44", Evg.strokeStr "white", Evg.strokeWidth 2, Drag.onDrag ctx "bend" (\() -> floating dragBend) ] { r = 6, center = combHandle }
                   ]

        label =
            "length "
                ++ String.fromInt (round (length p))
                ++ " px  ·  radius of curvature "
                ++ (if abs k > 1 / 2000 then
                        String.fromInt (round (1 / abs k)) ++ " px"

                    else
                        "∞"
                   )
    in
    Evg.group []
        ([ Evg.polyline [ Evg.strokeStr "#dee2e6", Evg.strokeWidth 1, Evg.fillStr "none", Evg.dashPattern [ 4, 4 ] ] [ p.p0, p.p1, p.p2, p.p3 ]
         , Evg.polyline [ Evg.strokeStr "#1c7ed6", Evg.strokeWidth 3, Evg.fillStr "none", Evg.linejoinRound, Evg.linecapRound ] curve
         , Evg.polyline
            [ Evg.strokeStr "#1c7ed6"
            , Evg.strokeOpacity 0
            , Evg.strokeWidth 22
            , Evg.fillStr "none"
            , Drag.onDrag ctx "curve" (\() -> floating dragCurve)
            ]
            curve
         ]
            ++ bendCircle
            ++ [ Evg.line [ Evg.strokeStr "#e8590c", Evg.strokeWidth 2 ] ( sx, sy ) ( sx + tangentLength * tx, sy + tangentLength * ty )
               , Evg.circle [ Evg.fillStr "#1c7ed6", Evg.strokeStr "white", Evg.strokeWidth 2 ] { r = 5, center = ( sx, sy ) }
               , Evg.circle [ Evg.fillStr "#e8590c", Evg.strokeStr "white", Evg.strokeWidth 2, Drag.onDrag ctx "tangent" (\() -> floating dragTangent) ] { r = 6, center = ( sx + tangentLength * tx, sy + tangentLength * ty ) }
               , Evg.rect [ Evg.fillStr "#7048e8", Evg.strokeStr "white", Evg.strokeWidth 2, Drag.onDrag ctx "lowest" (\() -> floating dragLowest) ] { x = lx - 6, y = ly - 6, width = 12, height = 12 }
               , control "p0" .p0 (\q -> { p | p0 = q })
               , control "p1" .p1 (\q -> { p | p1 = q })
               , control "p2" .p2 (\q -> { p | p2 = q })
               , control "p3" .p3 (\q -> { p | p3 = q })
               , Evg.text [ Evg.fillStr "#495057", Evg.fontSize 12 ] { x = 10, y = 312, anchor = Evg.Start } label
               ]
        )
