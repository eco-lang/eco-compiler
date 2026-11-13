module Lens exposing
    ( State, init, view
    , Ray, trace, focus, misses, graph, problem, solveFocus, rays
    , Stock, catalogue, stockName
    )

{-| A lens focusing a bundle of parallel rays, by Snell's law at two spherical surfaces.

The parameters are the curvatures of the lens's two faces and the angle of the incoming bundle. The
edge of the lens keeps a fixed thickness, so its centre thickness follows from the curvatures. Drag
the focus (where the exit rays pass closest together): the solver changes all three so that every
ray passes as near the pointer as it can, a least-squares problem with one residual per ray (9
residuals, 3 parameters).

The optics are written once (`trace`), over any number type: plain `Float`s for the drawing, one ray
at a time, and tensors for the model, all rays at once. The tensor model's Jacobian is exact, by
automatic differentiation through both refractions.

@docs State, init, view
@docs Ray, trace, focus, misses, graph, problem, solveFocus, rays
@docs Stock, catalogue, stockName


# A catalogue

Drag the focus near one of four stock lenses' foci (ringed while you drag) and the lens becomes that
stock lens: evg's `Drag.closest` over the catalogue, inside `Drag.whenFarWith`, which falls back to
designing the lens freely (the gradient solver) once the pointer is more than about 20 px from every
stock focus. Discrete choices from evg, continuous design from the gradients, in one drag.

-}

import Dict
import Evg exposing (Evg)
import Evg.Animate as Animate
import Evg.Drag as Drag
import GradSolve
import Graph exposing (Graph)
import Num exposing (Ops, floats)
import Signature as Sig
import Tensor as T exposing (Dim, F64, R1, Tensor)
import Tensor.Axis as Axis
import Tensor.Eval as Eval
import Transform


{-| The front face's curvature (1/radius; positive bulges towards the light), the back face's
(negative bulges away from it), and the bundle's angle in radians.
-}
type alias State =
    { front : Float, back : Float, angle : Float }


init : State
init =
    { front = 0.35, back = -0.35, angle = 0 }


toList : State -> List Float
toList s =
    [ s.front, s.back, s.angle ]


fromList : List Float -> State
fromList l =
    case l of
        [ f, b, a ] ->
            { front = f, back = b, angle = a }

        _ ->
            init


lower : List Float
lower =
    [ -0.4, -0.8, -0.3 ]


upper : List Float
upper =
    [ 0.8, 0.4, 0.3 ]


{-| The refractive index of the glass.
-}
glass : Float
glass =
    1.5


{-| Half the lens's height, and its thickness at the edge.
-}
aperture : Float
aperture =
    1.15


edge : Float
edge =
    0.12


{-| The rays' offsets across the bundle.
-}
rays : List Float
rays =
    List.map (\i -> -0.85 + 0.2125 * toFloat i) (List.range 0 8)



-- THE OPTICS, OVER ANY NUMBER TYPE


type alias Vec a =
    ( a, a )


{-| A ray's path: where it starts, where it enters and leaves the glass, and its direction after.
-}
type alias Ray a =
    { start : Vec a, enter : Vec a, exit : Vec a, direction : Vec a }


{-| How far a face at curvature `c` is from its vertex at height `y`.
-}
sag : Ops a -> a -> a -> a
sag o c y =
    o.div (o.mul c (o.mul y y)) (o.add (o.const 1) (o.sqrt (o.sub (o.const 1) (o.mul (o.mul c c) (o.mul y y)))))


{-| Where the ray from `p` along the unit vector `d` meets the face with vertex at x = `v` and
curvature `c`, written to stay finite as `c` goes to 0 (a flat face).
-}
hit : Ops a -> a -> a -> Vec a -> Vec a -> Vec a
hit o v c ( px, py ) ( dx, dy ) =
    let
        u =
            o.sub px v

        b =
            o.mul (o.const 2) (o.sub (o.mul c (o.add (o.mul u dx) (o.mul py dy))) dx)

        q =
            o.sub (o.mul c (o.add (o.mul u u) (o.mul py py))) (o.mul (o.const 2) u)

        disc =
            o.sub (o.mul b b) (o.mul (o.const 4) (o.mul c q))

        s =
            o.div (o.mul (o.const 2) q) (o.sub (o.sqrt disc) b)
    in
    ( o.add px (o.mul s dx), o.add py (o.mul s dy) )


{-| The direction of `d` after crossing the face (vertex `v`, curvature `c`) at `p`, from index
ratio `eta` = n₁/n₂ (Snell's law in vector form). The face's unit normal there is
(c(x − v) − 1, c y), facing the incoming ray.
-}
refract : Ops a -> a -> a -> a -> Vec a -> Vec a -> Vec a
refract o eta v c ( px, py ) ( dx, dy ) =
    let
        nx =
            o.sub (o.mul c (o.sub px v)) (o.const 1)

        ny =
            o.mul c py

        cosi =
            o.sub (o.const 0) (o.add (o.mul nx dx) (o.mul ny dy))

        k =
            o.sub (o.const 1) (o.mul (o.mul eta eta) (o.sub (o.const 1) (o.mul cosi cosi)))

        f =
            o.sub (o.mul eta cosi) (o.sqrt k)
    in
    ( o.add (o.mul eta dx) (o.mul f nx), o.add (o.mul eta dy) (o.mul f ny) )


{-| The ray at offset `h` through a lens with these curvatures, its bundle at `angle`.
-}
trace : Ops a -> { front : a, back : a, angle : a } -> a -> Ray a
trace o s h =
    let
        thickness =
            o.add (o.const edge) (o.sub (sag o s.front (o.const aperture)) (sag o s.back (o.const aperture)))

        v1 =
            o.mul (o.const -0.5) thickness

        v2 =
            o.mul (o.const 0.5) thickness

        d0 =
            ( o.cos s.angle, o.sin s.angle )

        start =
            ( o.sub (o.mul (o.const -3) (Tuple.first d0)) (o.mul h (Tuple.second d0))
            , o.add (o.mul (o.const -3) (Tuple.second d0)) (o.mul h (Tuple.first d0))
            )

        enter =
            hit o v1 s.front start d0

        d1 =
            refract o (o.const (1 / glass)) v1 s.front enter d0

        exit =
            hit o v2 s.back enter d1
    in
    { start = start, enter = enter, exit = exit, direction = refract o (o.const glass) v2 s.back exit d1 }


{-| How far a ray passes from a point, signed.
-}
miss : Ops a -> Vec a -> Ray a -> a
miss o ( fx, fy ) r =
    let
        ( px, py ) =
            r.exit

        ( dx, dy ) =
            r.direction
    in
    o.sub (o.mul dx (o.sub fy py)) (o.mul dy (o.sub fx px))



-- IN PLAIN ELM


paths : State -> List (Ray Float)
paths s =
    List.map (trace floats s) rays


{-| Where the exit rays pass closest together: the point minimising the sum of their squared misses.
-}
focus : State -> ( Float, Float )
focus s =
    let
        -- each miss is a·F − b, with a = (−dy, dx) and b = dx py − dy px
        terms =
            List.map
                (\r ->
                    let
                        ( px, py ) =
                            r.exit

                        ( dx, dy ) =
                            r.direction
                    in
                    ( ( -dy, dx ), dx * py - dy * px )
                )
                (paths s)

        sum f =
            List.sum (List.map f terms)

        a11 =
            sum (\( ( ax, _ ), _ ) -> ax * ax)

        a12 =
            sum (\( ( ax, ay ), _ ) -> ax * ay)

        a22 =
            sum (\( ( _, ay ), _ ) -> ay * ay)

        b1 =
            sum (\( ( ax, _ ), b ) -> ax * b)

        b2 =
            sum (\( ( _, ay ), b ) -> ay * b)

        det =
            a11 * a22 - a12 * a12
    in
    ( (a22 * b1 - a12 * b2) / det, (a11 * b2 - a12 * b1) / det )



-- THE MODEL


type P
    = P


type Two
    = Two


type Rays
    = Rays


type One
    = One


pDim : Dim P
pDim =
    T.dim P 3


twoDim : Dim Two
twoDim =
    T.dim Two 2


raysDim : Dim Rays
raysDim =
    T.dim Rays (List.length rays)


{-| Every ray's miss of the point `f`, all rays at once: `trace` over tensors of one element per ray,
the parameters broadcast across them.
-}
misses : Tensor Float F64 (R1 Two) -> Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 Rays)
misses f w =
    let
        offsets =
            T.fromList T.float64 (T.r1 raysDim) rays

        each : Int -> Tensor Float F64 (R1 n) -> Tensor Float F64 (R1 Rays)
        each i v =
            T.fillLike (v |> T.slice Axis.retag0of1 i (T.dim One 1) |> T.sumAll) offsets

        o =
            Num.tensors offsets
    in
    miss o ( each 0 f, each 1 f ) (trace o { front = each 0 w, back = each 1 w, angle = each 2 w } offsets)


{-| Inputs the parameters and the focus point; outputs every ray's miss and their Jacobian with
respect to the parameters (9 × 3).
-}
graph : Result (List String) Graph
graph =
    Graph.build "lens"
        (Sig.pair (Sig.label "params" (Sig.tensor T.float64 (T.r1 pDim))) (Sig.label "focus" (Sig.tensor T.float64 (T.r1 twoDim))))
        (Sig.pair (Sig.label "misses" (Sig.tensor T.float64 (T.r1 raysDim))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 raysDim pDim))))
        (\( w, f ) -> ( misses f w, Transform.jacobian (misses f) w ))


compiled : GradSolve.Compiled
compiled =
    GradSolve.compile graph


{-| Focusing on the point `f`.
-}
problem : ( Float, Float ) -> GradSolve.Problem
problem ( fx, fy ) =
    { compiled = compiled
    , fixed = Dict.singleton "focus" { dtype = "f64", shape = [ 2 ], data = Eval.Floats [ fx, fy ] }
    , lower = lower
    , upper = upper
    }


{-| The parameters that focus the rays under the pointer, keeping the offset between the pointer and
the focus from where the drag began.
-}
solveFocus : Drag.Solver -> List Float
solveFocus s =
    let
        ( gx, gy ) =
            fromScreen s.grab

        ( fx, fy ) =
            focus (fromList s.start)

        ( px, py ) =
            fromScreen s.pointer
    in
    (GradSolve.solve { maxEvaluations = 3, tolerance = 1.0e-6 } (problem ( px - (gx - fx), py - (gy - fy) )) (List.map (\_ -> 0) rays) s.previous).params



-- THE CATALOGUE


{-| A stock lens: its name and its faces' curvatures.
-}
type alias Stock =
    { name : String, front : Float, back : Float }


catalogue : List Stock
catalogue =
    [ { name = "strong biconvex", front = 0.6, back = -0.6 }
    , { name = "plano-convex", front = 0.75, back = 0 }
    , { name = "meniscus", front = 0.7, back = 0.25 }
    , { name = "weak biconvex", front = 0.2, back = -0.2 }
    ]


{-| The stock lens this is, if it is one.
-}
stockName : State -> Maybe String
stockName s =
    List.filter (\st -> st.front == s.front && st.back == s.back) catalogue |> List.head |> Maybe.map .name


{-| Each stock lens's focus for rays at this angle, ringed and lettered: shown while the focus is
dragged.
-}
stockMarks : Float -> Evg Never
stockMarks angle =
    Evg.group []
        (List.indexedMap
            (\k st ->
                let
                    ( x, y ) =
                        toScreen (focus { front = st.front, back = st.back, angle = angle })
                in
                Evg.group []
                    [ Evg.circle [ Evg.fillStr "none", Evg.strokeStr "#1c7ed6", Evg.strokeWidth 1.5, Evg.dashPattern [ 3, 3 ] ] { r = 12, center = ( x, y ) }
                    , Evg.text [ Evg.fillStr "#1c7ed6", Evg.fontSize 11 ] { x = x, y = y - 16, anchor = Evg.Middle } (String.fromChar (Char.fromCode (65 + k)))
                    ]
            )
            catalogue
        )



-- THE DRAWING


width : Float
width =
    480


height : Float
height =
    300


scale : Float
scale =
    60


toScreen : ( Float, Float ) -> ( Float, Float )
toScreen ( x, y ) =
    ( 130 + scale * x, height / 2 - scale * y )


fromScreen : ( Float, Float ) -> ( Float, Float )
fromScreen ( sx, sy ) =
    ( (sx - 130) / scale, (height / 2 - sy) / scale )


view : Drag.View State msg
view ctx state =
    let
        thickness =
            edge + sag floats state.front aperture - sag floats state.back aperture

        face v c sign =
            List.map
                (\k ->
                    let
                        y =
                            sign * aperture * (1 - toFloat k / 10)
                    in
                    toScreen ( v + sag floats c y, y )
                )
                (List.range 0 20)

        lens =
            Evg.polygon [ Evg.fillStr "#d0ebff", Evg.strokeStr "#1c7ed6", Evg.strokeWidth 1.5, Evg.fillOpacity 0.8 ]
                (face (-thickness / 2) state.front 1 ++ face (thickness / 2) state.back -1)

        rayLine r =
            let
                ( px, py ) =
                    r.exit

                ( dx, dy ) =
                    r.direction

                reach =
                    if dx > 0.05 then
                        (8.5 - px) / dx

                    else
                        3
            in
            Evg.polyline [ Evg.strokeStr "#f08c00", Evg.strokeWidth 1.2, Evg.fillStr "none", Evg.strokeOpacity 0.85 ]
                (List.map toScreen [ r.start, r.enter, r.exit, ( px + reach * dx, py + reach * dy ) ])

        f =
            focus state

        label =
            (case stockName state of
                Just name ->
                    "stock lens: " ++ name

                Nothing ->
                    "front "
                        ++ String.fromFloat (toFloat (round (state.front * 100)) / 100)
                        ++ "  ·  back "
                        ++ String.fromFloat (toFloat (round (state.back * 100)) / 100)
            )
                ++ "  ·  bundle "
                ++ String.fromInt (round (state.angle * 180 / pi))
                ++ "°"

        spec () =
            Drag.closest (List.map (\st -> { front = st.front, back = st.back, angle = state.angle }) catalogue)
                |> Drag.whenFarWith { gapIn = 14, gapOut = 22 } (Drag.varyWith solveFocus (toList state) fromList)
                |> Drag.withFloatingWith { ghost = Just 0.35, tether = Nothing }
                |> Drag.withBranchTransition 0.25 Animate.easeOut
                |> Drag.withOverlay (stockMarks state.angle)
    in
    Evg.group []
        ([ Evg.line [ Evg.strokeStr "#dee2e6" ] ( 0, height / 2 ) ( width, height / 2 )
         , lens
         ]
            ++ List.map rayLine (paths state)
            ++ [ Evg.circle [ Evg.fillStr "#e8590c", Evg.strokeStr "white", Evg.strokeWidth 2, Drag.onDrag ctx "focus" spec ] { r = 8, center = toScreen f }
               , Evg.text [ Evg.fillStr "#495057", Evg.fontSize 12 ] { x = 10, y = height - 10, anchor = Evg.Start } label
               ]
        )
