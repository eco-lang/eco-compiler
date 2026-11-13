module Main exposing (main)

{-| Dragging through gradients: evg's declarative dragging (`Evg.Drag`) with solvers that use exact
derivatives from the eco-lab/tensor package, evaluated in the browser by `Tensor.Eval`.
-}

import Bezier
import Browser
import Browser.Events
import Cannon
import Classify
import Cube
import Epidemic
import Evg
import Evg.Drag as Drag
import Fit
import Html exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Html.Lazy
import Layout
import Lens
import Tentacle
import Training
import Waves


type alias Model =
    { builtIn : Drag.Model Tentacle.State
    , gradient : Drag.Model Tentacle.State
    , pinTip : Bool
    , cannon : Drag.Model Cannon.State
    , lens : Drag.Model Lens.State
    , cube : Drag.Model Cube.State
    , bezier : Drag.Model Bezier.State
    , waves : Drag.Model Waves.State
    , epidemic : Drag.Model Epidemic.State
    , layout : Drag.Model Layout.State
    , layoutSettling : Bool
    , fit : Trained Fit.State
    , classify : Trained Classify.State
    }


{-| A panel that trains: its drawing, the training step's buffers, and whether training runs.
-}
type alias Trained s =
    { drag : Drag.Model s, trainer : Training.Trainer, training : Training }


{-| Training runs until the loss is below the panel's threshold, then waits for a drag to change the
fit. A pause from the button stays until the button is pressed again.
-}
type Training
    = Running { stopWhenFitted : Bool }
    | Paused
    | Fitted


type Control
    = Toggle
    | Reset


type Msg
    = BuiltInMsg (Drag.Msg Tentacle.State)
    | GradientMsg (Drag.Msg Tentacle.State)
    | TogglePin
    | CannonMsg (Drag.Msg Cannon.State)
    | LensMsg (Drag.Msg Lens.State)
    | CubeMsg (Drag.Msg Cube.State)
    | BezierMsg (Drag.Msg Bezier.State)
    | WavesMsg (Drag.Msg Waves.State)
    | EpidemicMsg (Drag.Msg Epidemic.State)
    | LayoutMsg (Drag.Msg Layout.State)
    | NewGraph
    | FitMsg (Drag.Msg Fit.State)
    | ClassifyMsg (Drag.Msg Classify.State)
    | Frame
    | FitControl Control
    | ClassifyControl Control


main : Program () Model Msg
main =
    Browser.element
        { init = \_ -> ( init, Cmd.none )
        , update = \msg model -> ( update msg model, Cmd.none )
        , subscriptions = subscriptions
        , view = view
        }


init : Model
init =
    { builtIn = Drag.init Tentacle.init
    , gradient = Drag.init Tentacle.init
    , pinTip = False
    , cannon = Drag.init Cannon.init
    , lens = Drag.init Lens.init
    , cube = Drag.init Cube.init
    , bezier = Drag.init Bezier.init
    , waves = Drag.init Waves.init
    , epidemic = Drag.init Epidemic.init
    , layout = Drag.init Layout.init
    , layoutSettling = True
    , fit = trained Fit.init Fit.trainer
    , classify = trained Classify.init Classify.trainer
    }


trained : s -> Training.Trainer -> Trained s
trained s t =
    { drag = Drag.init s, trainer = t, training = Running { stopWhenFitted = True } }


{-| The losses at which training stops by itself: the fit's curve then passes through its points,
and the classifier is 99% sure of every point.
-}
fitThreshold : Float
fitThreshold =
    1.0e-3


classifyThreshold : Float
classifyThreshold =
    1.0e-2


update : Msg -> Model -> Model
update msg model =
    case msg of
        BuiltInMsg m ->
            { model | builtIn = Drag.update (Tentacle.view Tentacle.BuiltIn model.pinTip) m model.builtIn }

        GradientMsg m ->
            { model | gradient = Drag.update (Tentacle.view Tentacle.Gradient model.pinTip) m model.gradient }

        TogglePin ->
            { model | pinTip = not model.pinTip }

        CannonMsg m ->
            { model | cannon = Drag.update Cannon.view m model.cannon }

        LensMsg m ->
            { model | lens = Drag.update Lens.view m model.lens }

        CubeMsg m ->
            { model | cube = Drag.update Cube.view m model.cube }

        BezierMsg m ->
            { model | bezier = Drag.update Bezier.view m model.bezier }

        WavesMsg m ->
            { model | waves = Drag.update Waves.view m model.waves }

        EpidemicMsg m ->
            { model | epidemic = Drag.update Epidemic.view m model.epidemic }

        LayoutMsg m ->
            let
                layout =
                    Drag.update Layout.view m model.layout
            in
            -- a drag moves the layout: let it settle again afterwards
            { model | layout = layout, layoutSettling = model.layoutSettling || Drag.state layout /= Drag.state model.layout }

        FitMsg m ->
            { model | fit = dragTrained Fit.view m model.fit }

        ClassifyMsg m ->
            { model | classify = dragTrained Classify.view m model.classify }

        NewGraph ->
            { model | layout = Drag.setState (Layout.random ((Drag.state model.layout).seed + 1)) model.layout, layoutSettling = True }

        Frame ->
            settleLayout
                { model
                    | fit = trainFrame fitThreshold Fit.train model.fit
                    , classify = trainFrame classifyThreshold Classify.train model.classify
                }

        FitControl c ->
            { model | fit = control Fit.init Fit.trainer c model.fit }

        ClassifyControl c ->
            { model | classify = control Classify.init Classify.trainer c model.classify }


{-| A few gradient steps on the layout, unless a node is being dragged (the drag relaxes it then).
-}
settleLayout : Model -> Model
settleLayout model =
    if not model.layoutSettling || Drag.isDragging model.layout then
        model

    else
        let
            before =
                Drag.state model.layout

            after =
                Layout.relax Nothing before |> Tuple.first |> Layout.recentre
        in
        { model | layout = Drag.setState after model.layout, layoutSettling = not (Layout.settled before after) }


{-| A drag message for a training panel: a drag that changes the drawing starts training again if it
had stopped by itself.
-}
dragTrained : Drag.View s Msg -> Drag.Msg s -> Trained s -> Trained s
dragTrained v m t =
    let
        d =
            Drag.update v m t.drag
    in
    { t
        | drag = d
        , training =
            if t.training == Fitted && Drag.state d /= Drag.state t.drag then
                Running { stopWhenFitted = True }

            else
                t.training
    }


{-| Three training steps, unless training is paused or a drag is in progress.
-}
trainFrame : Float -> (Int -> s -> Training.Trainer -> ( s, Training.Trainer )) -> Trained s -> Trained s
trainFrame threshold train t =
    case t.training of
        Running { stopWhenFitted } ->
            if Drag.isDragging t.drag then
                t

            else
                let
                    ( state, trainer ) =
                        train 3 (Drag.state t.drag) t.trainer
                in
                { drag = Drag.setState state t.drag
                , trainer = trainer
                , training =
                    case trainer.loss of
                        Just loss ->
                            if stopWhenFitted && loss < threshold then
                                Fitted

                            else
                                t.training

                        Nothing ->
                            t.training
                }

        _ ->
            t


control : s -> Training.Trainer -> Control -> Trained s -> Trained s
control initial fresh c t =
    case c of
        Toggle ->
            { t
                | training =
                    case t.training of
                        Running _ ->
                            Paused

                        Paused ->
                            Running { stopWhenFitted = True }

                        Fitted ->
                            Running { stopWhenFitted = False }
            }

        Reset ->
            { drag = Drag.setState initial t.drag, trainer = fresh, training = Running { stopWhenFitted = True } }


running : Training -> Bool
running t =
    case t of
        Running _ ->
            True

        _ ->
            False


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Sub.map BuiltInMsg (Drag.subscriptions model.builtIn)
        , Sub.map GradientMsg (Drag.subscriptions model.gradient)
        , Sub.map CannonMsg (Drag.subscriptions model.cannon)
        , Sub.map LensMsg (Drag.subscriptions model.lens)
        , Sub.map CubeMsg (Drag.subscriptions model.cube)
        , Sub.map BezierMsg (Drag.subscriptions model.bezier)
        , Sub.map WavesMsg (Drag.subscriptions model.waves)
        , Sub.map EpidemicMsg (Drag.subscriptions model.epidemic)
        , Sub.map LayoutMsg (Drag.subscriptions model.layout)
        , Sub.map FitMsg (Drag.subscriptions model.fit.drag)
        , Sub.map ClassifyMsg (Drag.subscriptions model.classify.drag)
        , if running model.fit.training || running model.classify.training || model.layoutSettling then
            Browser.Events.onAnimationFrame (\_ -> Frame)

          else
            Sub.none
        ]



-- VIEW


view : Model -> Html Msg
view model =
    Html.div [ A.style "font-family" "system-ui, -apple-system, sans-serif", A.style "color" "#212529", A.style "max-width" "1000px", A.style "margin" "0 auto", A.style "padding" "16px", A.style "line-height" "1.5" ]
        [ Html.h1 [ A.style "margin-bottom" "4px" ] [ Html.text "Dragging through gradients" ]
        , para
            [ Html.text "Each drawing below is draggable the declarative way ("
            , link "https://declarative-dragging.github.io/" "Declarative Dragging"
            , Html.text ", in Elm as evg's "
            , code "Evg.Drag"
            , Html.text "): it says which numbers a drag may change, and a solver finds the values that put the grabbed point under the pointer. evg's own solver tries values and re-renders the drawing for every derivative. Here, a model of the drawing written with the "
            , code "eco-lab/tensor"
            , Html.text " package gives exact derivatives instead, computed by its automatic differentiation and evaluated in your browser by "
            , code "Tensor.Eval"
            , Html.text ", in plain Elm."
            ]
        , section "1. A tentacle with twelve joints"
            [ Html.text "Drag any joint. Each joint bends at most 40° from the one before. Left: evg's built-in "
            , code "Drag.varyN"
            , Html.text ", finite differences over re-renders (up to 13 renders per iteration, 20 iterations per move). Right: "
            , code "Drag.varyWith"
            , Html.text " and Levenberg–Marquardt on the exact Jacobian, one graph evaluation per iteration. Pull a joint past its reach (the dashed circle) and its handle floats free under the pointer ("
            , code "Drag.withFloating"
            , Html.text "), a faded copy marking where it will land. Pin the tip, then drag another joint: the tip stays put. On the left evg's "
            , code "Drag.pin"
            , Html.text " holds it, as a penalty in evg's solver; on the right the gradient solver has four targets, the joint under the pointer and the tip where it was."
            ]
            [ panel "builtin" "evg built-in (finite differences)" (Html.Lazy.lazy2 builtInPanel model.pinTip model.builtIn)
            , panel "gradient" "gradient (exact Jacobian)" (Html.Lazy.lazy2 gradientPanel model.pinTip model.gradient)
            , Html.div [ A.style "flex-basis" "100%" ]
                [ button
                    (if model.pinTip then
                        "Unpin the tip"

                     else
                        "Pin the tip"
                    )
                    TogglePin
                ]
            ]
        , section "2. Turn the cube"
            [ Html.text "Drag any orange corner. The cube turns so that the corner stays under the pointer: three rotation angles, solved through the exact derivatives of the rotation and the perspective projection. With two targets (the corner's position on the screen) and three angles, the solver takes the smallest turn that works, so the cube rolls the way you would expect. A corner can only go where turning can take it; past that, it follows as near as it can. Let go within 25° of a face-on view and the cube squares up: evg's "
            , code "Drag.onDrop"
            , Html.text " changes the state the drag lands in, and evg animates the landing."
            ]
            [ panel "cube" "" (Html.Lazy.lazy cubePanel model.cube) ]
        , section "3. Shape a curve by what it looks like"
            [ Html.text "A cubic Bézier curve, shaped without touching its control points (though you can: the small white circles). Grab the blue curve anywhere and drag it: where along the curve you grabbed is itself one of the solver's unknowns, so dragging along the curve slides the grab point and dragging across it reshapes the curve. At the selected point (the last one grabbed), drag the orange arrow to turn the curve's direction there, or the green handle along the normal to bend it tighter (further out) or looser (a curvature comb: its distance from the curve is proportional to the curvature, and the dashed circle is the circle that fits the curve there); the point, and when bending its direction too, stay put. The purple square is the curve's lowest point, a smooth maximum over 48 samples; drag it too. Each of these is a nonlinear function of the control points (unit tangent, curvature, a soft maximum), differentiated exactly by the tensor package. The two inner control points move; the ends stay put."
            ]
            [ panel "bezier" "" (Html.Lazy.lazy bezierPanel model.bezier) ]
        , section "4. Drag the ball in mid-flight"
            [ Html.text "The orange ball is where the shot is 1.2 seconds after firing, with air drag. Drag it: the launch angle and speed change so the ball is under the pointer at that moment. Its position is the end of a 40-step simulation, so the solver differentiates through all 40 steps." ]
            [ panel "cannon" "" (Html.Lazy.lazy cannonPanel model.cannon) ]
        , section "5. Focus the lens"
            [ Html.text "Nine parallel rays pass through a glass lens and bend at each face by Snell's law. Drag the orange focus, the point the rays pass closest to: the curvature of each face and the angle of the incoming rays change so that every ray passes as near the pointer as it can. That is nine misses and three numbers, solved as least squares through the derivatives of both refractions, all nine rays in one tensor. A lens with spherical faces cannot bring wide rays to one point (spherical aberration), so the solver also chooses the shape that focuses best. There is also a catalogue: while you drag, the foci of four stock lenses are ringed (A–D), and near one the lens becomes that stock lens. That is evg's own declarative choosing (closest, inside whenFar), with the gradient solver taking over again once you move away."
            ]
            [ panel "lens" "" (Html.Lazy.lazy lensPanel model.lens) ]
        , section "6. Two-source interference"
            [ Html.text "Two sources (orange) send out waves of one wavelength. Where crest meets crest the waves add up (bright bands); where crest meets trough they cancel (dark). The picture is one tensor graph run, one element per 10-pixel cell. Grab anywhere on the pattern and drag: the spacing of the sources and the wavelength change so that the band you grabbed passes under the pointer. Drag a source to change the spacing directly. The central band lies on the axis whatever the spacing, so it cannot be dragged off it."
            ]
            [ panel "waves" "" (Html.Lazy.lazy wavesPanel model.waves) ]
        , section "7. Flatten the curve"
            [ Html.text "An epidemic in the SIR model (susceptible, infected, recovered), simulated day by day for 150 days. Drag the orange peak of the infected curve: the infection rate and the time people stay infectious change to put the peak under the pointer. The peak is a smooth maximum, the days averaged with weights that keep only the top of the curve, so it has derivatives, and the solver follows them back through all 150 days."
            ]
            [ panel "epidemic" "" (Html.Lazy.lazy epidemicPanel model.epidemic) ]
        , section "8. Fit, and drag the fit"
            [ Html.text "A 1 → 8 → 1 network trains on the blue points, a few steps of "
            , code "Train.step"
            , Html.text " (AdamW) every frame, in the browser. Drag a point and the curve follows as it trains. Drag the curve itself and all 25 weights change so it passes under the pointer at that x; let go, and training pulls it back. Training pauses by itself once the loss is below 0.001, and starts again when a drag changes the fit."
            ]
            [ panel "fit" "" (Html.Lazy.lazy fitPanel model.fit) ]
        , section "9. Drag the decision boundary"
            [ Html.text "A 2 → 8 → 2 classifier learns to tell the red points from the blue, with softmax cross-entropy; the shading is how sure it is, and the line is where it cannot tell. Drag a point and the boundary follows as it trains. Drag the boundary itself and all 42 weights change so that it passes under the pointer: the solver's target is not a point but a level, the difference of the two class scores at the pointer. Training pauses once the loss is below 0.01."
            ]
            [ panel "classify" "" (Html.Lazy.lazy classifyPanel model.classify) ]
        , section "10. A graph that lays itself out"
            [ Html.text "A random graph of 20 nodes (a random tree plus seven extra edges), started scrambled and drawn by minimising stress: every pair of nodes wants to be as far apart on the page as the number of edges between them. Each frame takes a few gradient steps over all pairs at once (20 × 20 tensors) until the layout stops moving. Drag a node: it stays under the pointer and the others relax around it as you move. Let go, and the whole layout settles again. \"New graph\" draws another."
            ]
            [ panel "layout" "" (Html.div [] [ Html.Lazy.lazy layoutPanel model.layout, Html.div [ A.style "margin-top" "6px" ] [ button "New graph" NewGraph ] ]) ]
        , para
            [ Html.text "Built with stock Elm 0.19.1: evg's "
            , code "declarative-dragging"
            , Html.text " branch with one addition ("
            , code "Drag.varyWith"
            , Html.text ", a solver of your own), and the eco-lab/tensor package, which writes the same graphs as MLIR for Modular MAX."
            ]
        ]



-- Each panel is drawn lazily: a message re-renders only the panel whose state it changed.


builtInPanel : Bool -> Drag.Model Tentacle.State -> Html Msg
builtInPanel pin m =
    Evg.svg [] { width = 320, height = 290 } [ Drag.view BuiltInMsg (Tentacle.view Tentacle.BuiltIn pin) m ]


gradientPanel : Bool -> Drag.Model Tentacle.State -> Html Msg
gradientPanel pin m =
    Evg.svg [] { width = 320, height = 290 } [ Drag.view GradientMsg (Tentacle.view Tentacle.Gradient pin) m ]


bezierPanel : Drag.Model Bezier.State -> Html Msg
bezierPanel m =
    Evg.svg [] { width = 480, height = 320 } [ Drag.view BezierMsg Bezier.view m ]


cubePanel : Drag.Model Cube.State -> Html Msg
cubePanel m =
    Evg.svg [] { width = 480, height = 300 } [ Drag.view CubeMsg Cube.view m ]


cannonPanel : Drag.Model Cannon.State -> Html Msg
cannonPanel m =
    Evg.svg [] { width = 480, height = 300 } [ Drag.view CannonMsg Cannon.view m ]


lensPanel : Drag.Model Lens.State -> Html Msg
lensPanel m =
    Evg.svg [] { width = 480, height = 300 } [ Drag.view LensMsg Lens.view m ]


wavesPanel : Drag.Model Waves.State -> Html Msg
wavesPanel m =
    Evg.svg [] { width = 480, height = 300 } [ Drag.view WavesMsg Waves.view m ]


epidemicPanel : Drag.Model Epidemic.State -> Html Msg
epidemicPanel m =
    Evg.svg [] { width = 480, height = 300 } [ Drag.view EpidemicMsg Epidemic.view m ]


fitPanel : Trained Fit.State -> Html Msg
fitPanel t =
    Html.div [] [ Evg.svg [] { width = 480, height = 300 } [ Drag.view FitMsg Fit.view t.drag ], controls fitThreshold FitControl t ]


classifyPanel : Trained Classify.State -> Html Msg
classifyPanel t =
    Html.div [] [ Evg.svg [] { width = 480, height = 320 } [ Drag.view ClassifyMsg Classify.view t.drag ], controls classifyThreshold ClassifyControl t ]


layoutPanel : Drag.Model Layout.State -> Html Msg
layoutPanel m =
    Evg.svg [] { width = 480, height = 320 } [ Drag.view LayoutMsg Layout.view m ]


controls : Float -> (Control -> Msg) -> Trained s -> Html Msg
controls threshold toMsg t =
    Html.div [ A.style "display" "flex", A.style "gap" "8px", A.style "align-items" "center", A.style "margin-top" "6px" ]
        [ button
            (case t.training of
                Running _ ->
                    "Pause training"

                Paused ->
                    "Train"

                Fitted ->
                    "Keep training"
            )
            (toMsg Toggle)
        , button "Reset" (toMsg Reset)
        , Html.span [ A.style "font-size" "13px", A.style "color" "#495057" ]
            [ Html.text
                ("step "
                    ++ String.fromInt t.trainer.steps
                    ++ (case t.trainer.loss of
                            Just l ->
                                ", loss " ++ twoFigures l

                            Nothing ->
                                ""
                       )
                    ++ (if t.training == Fitted then
                            " (fitted: paused below " ++ String.fromFloat threshold ++ ")"

                        else
                            ""
                       )
                )
            ]
        ]


{-| A positive number to two significant figures: 0.0031, 4.2e-7.
-}
twoFigures : Float -> String
twoFigures x =
    if x <= 0 || isNaN x || isInfinite x then
        String.fromFloat x

    else
        let
            e =
                floor (logBase 10 x)

            m =
                toFloat (round (x / 10 ^ toFloat e * 10)) / 10
        in
        if e >= -3 && e <= 3 then
            String.fromFloat (toFloat (round (x * 10 ^ toFloat (1 - e))) / 10 ^ toFloat (1 - e))

        else
            String.fromFloat m ++ "e" ++ String.fromInt e


section : String -> List (Html Msg) -> List (Html Msg) -> Html Msg
section title intro panels =
    Html.div [ A.style "margin-top" "28px" ]
        [ Html.h2 [ A.style "font-size" "20px", A.style "margin-bottom" "4px" ] [ Html.text title ]
        , para intro
        , Html.div [ A.style "display" "flex", A.style "flex-wrap" "wrap", A.style "gap" "16px" ] panels
        ]


panel : String -> String -> Html Msg -> Html Msg
panel id caption content =
    Html.div [ A.id id, A.style "border" "1px solid #dee2e6", A.style "border-radius" "8px", A.style "padding" "8px", A.style "background" "white", A.style "touch-action" "none" ]
        ((if caption == "" then
            []

          else
            [ Html.div [ A.style "font-size" "13px", A.style "color" "#495057", A.style "margin-bottom" "4px" ] [ Html.text caption ] ]
         )
            ++ [ content ]
        )


para : List (Html Msg) -> Html Msg
para =
    Html.p [ A.style "max-width" "780px", A.style "margin" "6px 0 12px" ]


code : String -> Html Msg
code s =
    Html.code [ A.style "background" "#f1f3f5", A.style "padding" "1px 4px", A.style "border-radius" "4px", A.style "font-size" "0.92em" ] [ Html.text s ]


link : String -> String -> Html Msg
link url label =
    Html.a [ A.href url, A.target "_blank" ] [ Html.text label ]


button : String -> Msg -> Html Msg
button label msg =
    Html.button [ E.onClick msg, A.style "padding" "4px 12px", A.style "border-radius" "6px", A.style "border" "1px solid #adb5bd", A.style "background" "#f8f9fa", A.style "cursor" "pointer" ] [ Html.text label ]
