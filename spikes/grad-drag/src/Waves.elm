module Waves exposing
    ( State, init, view
    , make, phase, fieldGraph, graph, problem, columns, rows, cell
    )

{-| Two coherent sources of waves, side by side on the left; where their crests meet the waves add
(bright bands), where crest meets trough they cancel (dark bands). A point's brightness depends on
its phase difference: how many wavelengths farther it is from one source than from the other.

  - **The picture** is one tensor graph run over every cell of a 10 px grid, kept in the state and
    recomputed when the spacing or the wavelength change.
  - **Drag any point of the pattern**: the spacing of the sources and the wavelength change so that
    the phase difference at the pointer is what it was where you grabbed, so the band you grabbed
    follows the pointer. The target is a level, not a point (1 residual, 2 parameters).
  - **Drag a source** to change the spacing directly.

The phase difference is written once over `Num.Ops`: over every cell at once for the picture, over
scalars for the drag's derivatives, over `Float`s for the tests.

@docs State, init, view
@docs make, phase, fieldGraph, graph, problem, columns, rows, cell

-}

import Array
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


{-| The distance between the sources and the wavelength, in pixels, and each grid cell's brightness
(0 to 1, row-major).
-}
type alias State =
    { spacing : Float, wavelength : Float, field : List Float }


init : State
init =
    make 70 24


width : Float
width =
    480


height : Float
height =
    300


{-| The sources' x, and the axis's y.
-}
sourceX : Float
sourceX =
    36


axisY : Float
axisY =
    150


cell : Float
cell =
    10


columns : Int
columns =
    round (width / cell)


rows : Int
rows =
    round (height / cell)


{-| A point's phase difference: its distance from the lower source minus its distance from the upper
one, in wavelengths.
-}
phase : Ops n -> n -> n -> ( n, n ) -> n
phase o spacing wavelength ( x, y ) =
    let
        half =
            o.mul (o.const 0.5) spacing

        dx =
            o.sub x (o.const sourceX)

        dist sy =
            o.sqrt (o.add (o.mul dx dx) (o.mul (o.sub y sy) (o.sub y sy)))

        upper =
            dist (o.sub (o.const axisY) half)

        lower =
            dist (o.add (o.const axisY) half)
    in
    o.div (o.sub lower upper) wavelength



-- THE MODELS


type Cells
    = Cells


type P
    = P


type Two
    = Two


type One
    = One


pDim : Dim P
pDim =
    T.dim P 2


cellsDim : Dim Cells
cellsDim =
    T.dim Cells (columns * rows)


scalar : Int -> Tensor Float F64 (R1 n) -> Tensor Float F64 R0
scalar i v =
    v |> T.slice Axis.retag0of1 i (T.dim One 1) |> T.sumAll


{-| Every cell's brightness, (1 + cos 2πφ) / 2, at once: one element per cell.
-}
fieldGraph : Result (List String) Graph
fieldGraph =
    Graph.build "wavesField"
        (Sig.label "params" (Sig.tensor T.float64 (T.r1 pDim)))
        (Sig.label "field" (Sig.tensor T.float64 (T.r1 cellsDim)))
        (\params ->
            let
                centres f =
                    List.concatMap (\j -> List.map (\i -> f i j) (List.range 0 (columns - 1))) (List.range 0 (rows - 1))

                xs =
                    T.fromList T.float64 (T.r1 cellsDim) (centres (\i _ -> cell * (toFloat i + 0.5)))

                ys =
                    T.fromList T.float64 (T.r1 cellsDim) (centres (\_ j -> cell * (toFloat j + 0.5)))

                o =
                    Num.tensors xs

                fill v =
                    T.fillLike v xs

                p =
                    phase o (fill (scalar 0 params)) (fill (scalar 1 params)) ( xs, ys )
            in
            p |> T.scale (2 * pi) |> T.cos |> T.shift 1 |> T.scale 0.5
        )


fieldPrepared : Result (List String) Eval.Prepared
fieldPrepared =
    Result.map Eval.prepare fieldGraph


{-| The state for this spacing and wavelength, its picture computed by the field graph.
-}
make : Float -> Float -> State
make spacing wavelength =
    let
        field =
            case fieldPrepared of
                Ok p ->
                    case Eval.runPrepared p (Dict.singleton "params" { dtype = "f64", shape = [ 2 ], data = Eval.Floats [ spacing, wavelength ] }) |> Result.map (Dict.get "field" >> Maybe.map .data) of
                        Ok (Just (Eval.Floats l)) ->
                            l

                        _ ->
                            []

                Err _ ->
                    []
    in
    { spacing = spacing, wavelength = wavelength, field = field }


phaseAt : Tensor Float F64 (R1 Two) -> Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 One)
phaseAt at params =
    phase (Num.tensors (T.fromList T.float64 T.scalar [ 0 ])) (scalar 0 params) (scalar 1 params) ( scalar 0 at, scalar 1 at )
        |> T.reshape (T.r1 (T.dim One 1))


{-| Inputs the spacing and wavelength and a point; outputs the phase difference there and its
gradient (as a 1 × 2 Jacobian).
-}
graph : Result (List String) Graph
graph =
    Graph.build "wavesPhase"
        (Sig.pair (Sig.label "params" (Sig.tensor T.float64 (T.r1 pDim))) (Sig.label "at" (Sig.tensor T.float64 (T.r1 (T.dim Two 2)))))
        (Sig.pair (Sig.label "phase" (Sig.tensor T.float64 (T.r1 (T.dim One 1)))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 (T.dim One 1) pDim))))
        (\( params, at ) -> ( phaseAt at params, Transform.jacobian (phaseAt at) params ))


compiled : GradSolve.Compiled
compiled =
    GradSolve.compile graph


problem : ( Float, Float ) -> GradSolve.Problem
problem ( x, y ) =
    { compiled = compiled
    , fixed = Dict.singleton "at" { dtype = "f64", shape = [ 2 ], data = Eval.Floats [ x, y ] }
    , lower = [ 12, 10 ]
    , upper = [ 220, 80 ]
    }


solveBand : Drag.Solver -> List Float
solveBand s =
    case s.start of
        [ sp, wl ] ->
            let
                level =
                    phase Num.floats sp wl s.grab
            in
            (GradSolve.solve { maxEvaluations = 5, tolerance = 1.0e-4 } (problem s.pointer) [ level ] s.previous).params

        _ ->
            s.previous


moveSource : Float -> Drag.Solver -> List Float
moveSource sign s =
    case s.start of
        [ sp ] ->
            [ clamp 12 220 (sp + 2 * sign * (Tuple.second s.pointer - Tuple.second s.grab)) ]

        _ ->
            s.previous



-- THE DRAWING


colour : Float -> String
colour v =
    let
        mix a b =
            String.fromInt (round (a + v * (b - a)))
    in
    "rgb(" ++ mix 16 165 ++ "," ++ mix 32 216 ++ "," ++ mix 60 255 ++ ")"


view : Drag.View State msg
view ctx state =
    let
        field =
            Array.fromList state.field

        cells =
            List.concatMap
                (\j ->
                    List.map
                        (\i ->
                            Evg.rect [ Evg.fillStr (colour (Array.get (j * columns + i) field |> Maybe.withDefault 0)) ]
                                { x = cell * toFloat i, y = cell * toFloat j, width = cell + 0.5, height = cell + 0.5 }
                        )
                        (List.range 0 (columns - 1))
                )
                (List.range 0 (rows - 1))

        source sign =
            Evg.circle
                [ Evg.fillStr "#e8590c"
                , Evg.strokeStr "white"
                , Evg.strokeWidth 2
                , Drag.onDrag ctx
                    (if sign < 0 then
                        "upper"

                     else
                        "lower"
                    )
                    (\() ->
                        Drag.varyWith (moveSource sign)
                            [ state.spacing ]
                            (\l -> make (List.head l |> Maybe.withDefault state.spacing) state.wavelength)
                    )
                ]
                { r = 7, center = ( sourceX, axisY + sign * state.spacing / 2 ) }
    in
    Evg.group []
        (cells
            ++ [ Evg.rect
                    [ Evg.fillStr "white"
                    , Evg.fillOpacity 0
                    , Drag.onDrag ctx
                        "field"
                        (\() ->
                            Drag.varyWith solveBand
                                [ state.spacing, state.wavelength ]
                                (\l ->
                                    case l of
                                        [ sp, wl ] ->
                                            make sp wl

                                        _ ->
                                            state
                                )
                        )
                    ]
                    { x = 0, y = 0, width = width, height = height }
               , source -1
               , source 1
               , Evg.text [ Evg.fillStr "white", Evg.fontSize 12 ]
                    { x = width - 10, y = height - 10, anchor = Evg.End }
                    ("spacing " ++ String.fromInt (round state.spacing) ++ " px   wavelength " ++ String.fromFloat (toFloat (round (state.wavelength * 10)) / 10) ++ " px")
               ]
        )
