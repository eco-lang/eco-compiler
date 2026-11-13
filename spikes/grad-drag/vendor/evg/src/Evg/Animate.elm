module Evg.Animate exposing
    ( AnimationOption
    , repeatIndefinite, repeatCount, repeatFor, duration, delay, fillFreeze
    , easing, stepped, paced
    , additive, accumulateRepeats
    , beginOn, endOn, Trigger, click, mouseOver, mouseOut, manualStart
    , restartWhenNotActive, restartNever
    , onBegin, onEnd, onRepeat
    , Easing, easeLinear, easeInOut, easeIn, easeOut, cubicBezier
    , animate, set, keyframes, sampled
    , rotate, rotateAround, scale, scaleXY, translate, skewX, skewY
    , motion, motionKeyframes
    , upright, orientReverse, orientAngle
    , sequence, Step, step, stepRotateAround, stepTranslate, stepScale
    )

{-| Declarative animations that don't require any messages or subscriptions.

You describe the animation as part of your view and the browser plays it on
its own. There is no Elm update loop involved: no subscriptions, no
`Time`-based messages, no re-rendering every frame.

The vocabulary used throughout this module:

  - durations and keyframe times are in seconds
  - keyframes are snapshots of a value at points in time; the browser smoothly
    blends between them
  - easing is the speed profile of the motion between two keyframes, such as
    starting slow and finishing fast

Here is a small example:

    import Evg
    import Evg.Animate as Animate

    -- Animate a circle's radius with easing:
    Evg.circle
        [ Evg.fillStr "tomato" ]
        { r = 20, center = ( 50, 50 ) }
        |> Animate.animate [ Animate.repeatIndefinite ]
            "r"
            [ ( 0.5, Animate.easeInOut, "40" )
            , ( 1.5, Animate.easeLinear, "20" )
            ]

This shows a red circle that endlessly swells and shrinks back.


# Options

@docs AnimationOption
@docs repeatIndefinite, repeatCount, repeatFor, duration, delay, fillFreeze
@docs easing, stepped, paced
@docs additive, accumulateRepeats


# Triggers and restarting

@docs beginOn, endOn, Trigger, click, mouseOver, mouseOut, manualStart
@docs restartWhenNotActive, restartNever


# Reacting to animations

@docs onBegin, onEnd, onRepeat


# Easing Curves

@docs Easing, easeLinear, easeInOut, easeIn, easeOut, cubicBezier


# Animation Builders

@docs animate, set, keyframes, sampled


# Animating transforms

@docs rotate, rotateAround, scale, scaleXY, translate, skewX, skewY


# Motion along a path

@docs motion, motionKeyframes
@docs upright, orientReverse, orientAngle


# Sequencing

@docs sequence, Step, step, stepRotateAround, stepTranslate, stepScale

-}

import Evg.Internal as Internal exposing (Evg, wrapNode)
import Evg.Path
import Json.Decode as Decode
import Svg
import Svg.Attributes
import VirtualDom


{-| Options that control animation timing, repetition, triggering and how an
animation reports back into your program.
-}
type AnimationOption msg
    = RepeatIndefinite
    | RepeatCount Float
    | RepeatFor Float
    | Duration Float
    | Delay Float
    | FillFreeze
    | EasingOption Easing
    | Stepped
    | Paced
    | Additive
    | AccumulateRepeats
    | BeginOn Trigger
    | EndOn Trigger
    | RestartWhenNotActive
    | RestartNever
    | OnBegin msg
    | OnEnd msg
    | OnRepeat msg
    | Upright
    | OrientReverse
    | OrientAngle Float


{-| The animation repeats forever.
-}
repeatIndefinite : AnimationOption msg
repeatIndefinite =
    RepeatIndefinite


{-| The animation repeats a fixed number of times. Fractional counts are
allowed, so `2.5` runs the animation two and a half times.
-}
repeatCount : Float -> AnimationOption msg
repeatCount =
    RepeatCount


{-| The animation keeps repeating until the given number of seconds has
elapsed, then stops, even if that means cutting a cycle short.
-}
repeatFor : Float -> AnimationOption msg
repeatFor =
    RepeatFor


{-| The total duration of one animation cycle in seconds.
-}
duration : Float -> AnimationOption msg
duration =
    Duration


{-| Delay before the animation starts, in seconds.

If you also give a trigger with `beginOn`, the trigger wins and this delay is
ignored.

-}
delay : Float -> AnimationOption msg
delay =
    Delay


{-| When the animation ends, the element stays at its final state rather than
snapping back to the start.
-}
fillFreeze : AnimationOption msg
fillFreeze =
    FillFreeze


{-| Sets the easing (the speed profile of the motion) used between all
keyframes.

    Animate.keyframes
        [ Animate.repeatIndefinite
        , Animate.easing Animate.easeInOut
        ]
        [ ( 0
          , Evg.circle []
                { r = 10, center = ( 50, 50 ) }
          )
        , ( 1
          , Evg.circle []
                { r = 40, center = ( 50, 50 ) }
          )
        ]

This shows a circle growing and shrinking, gently accelerating out of each
extreme and slowing into the next.

-}
easing : Easing -> AnimationOption msg
easing =
    EasingOption


{-| Jump instantly from one keyframe value to the next with no smooth
in-between motion, like a slideshow of frames. Per-keyframe easings are ignored.
-}
stepped : AnimationOption msg
stepped =
    Stepped


{-| Move at a constant speed across the whole animation, spacing the keyframes
so that equal distances take equal time. Any keyframe times and easings you gave
are ignored in favor of this even pacing.
-}
paced : AnimationOption msg
paced =
    Paced


{-| Add this animation on top of any other transforms already on the element,
rather than replacing them. Transform animations (`rotate`, `scale`, and
friends) always do this automatically.
-}
additive : AnimationOption msg
additive =
    Additive


{-| Each repeat builds on the end of the previous one instead of starting over.
For example a `translate` that moves 10 to the right will end up 20 to the right
after two repeats, 30 after three, and so on.
-}
accumulateRepeats : AnimationOption msg
accumulateRepeats =
    AccumulateRepeats


{-| Start the animation when the given event happens on the element, instead of
right away. Give it more than once to start on any of several events.

    Animate.animate [ Animate.beginOn Animate.click ]
        "r"
        [ ( 0.4, Animate.easeOut, "40" ) ]

Nothing moves until the shape is clicked; then it quickly grows.

-}
beginOn : Trigger -> AnimationOption msg
beginOn =
    BeginOn


{-| End the animation early when the given event happens on the element.
-}
endOn : Trigger -> AnimationOption msg
endOn =
    EndOn


{-| Something that can start or stop an animation, such as a click or a mouse
hover on the animated element itself.
-}
type Trigger
    = ClickTrigger
    | MouseOverTrigger
    | MouseOutTrigger
    | ManualStart



-- Layer 3 (starting one element's animation from an event on a *different*
-- element via first-class Animation values) is intentionally out of scope. It
-- would need cross-element ids; a future extension could add it.


{-| The element is clicked.
-}
click : Trigger
click =
    ClickTrigger


{-| The pointer moves onto the element.
-}
mouseOver : Trigger
mouseOver =
    MouseOverTrigger


{-| The pointer moves off the element.
-}
mouseOut : Trigger
mouseOut =
    MouseOutTrigger


{-| The animation never starts on its own. It waits to be started by another
animation in a `sequence`.
-}
manualStart : Trigger
manualStart =
    ManualStart


{-| If the animation is triggered again while it is already running, ignore the
new trigger. A fresh trigger only takes effect once the current run has
finished.
-}
restartWhenNotActive : AnimationOption msg
restartWhenNotActive =
    RestartWhenNotActive


{-| The animation can only run once; later triggers are ignored.
-}
restartNever : AnimationOption msg
restartNever =
    RestartNever


{-| Send a message the moment the animation starts.

A browser support caveat: browsers only started delivering these animation
milestone events reliably in versions released after late 2025. Older Safari
(including iOS) may never send them, even though the animation itself plays
fine. Don't gate critical state changes on receiving one; if you must support
older browsers, a timer matching the animation's timing (e.g. `Process.sleep`)
is the dependable alternative. This applies equally to `onEnd` and `onRepeat`.

-}
onBegin : msg -> AnimationOption msg
onBegin =
    OnBegin


{-| Send a message the moment the animation ends. Never sent by animations
that repeat forever.

See `onBegin` for a browser support caveat: on older browsers (notably
Safari before late 2025) this message may never arrive, so avoid relying on
it for critical state changes. For example, prefer a timer over `onEnd` for
removing an element after its exit animation.

-}
onEnd : msg -> AnimationOption msg
onEnd =
    OnEnd


{-| Send a message each time the animation completes a repeat.

See `onBegin` for a browser support caveat that also applies here.

-}
onRepeat : msg -> AnimationOption msg
onRepeat =
    OnRepeat


{-| The speed profile of the motion between two keyframes: whether it moves at
a constant rate, starts slow and speeds up, or the reverse. The values covered
are the same either way; easing only changes how fast the animation travels
through them at each moment.
-}
type alias Easing =
    Internal.Easing


{-| Constant speed from start to finish.
-}
easeLinear : Easing
easeLinear =
    Internal.Linear


{-| Starts slow, speeds up, then slows down at the end.
-}
easeInOut : Easing
easeInOut =
    Internal.EaseInOut


{-| Starts slow, then speeds up.
-}
easeIn : Easing
easeIn =
    Internal.EaseIn


{-| Starts fast, then slows down.
-}
easeOut : Easing
easeOut =
    Internal.EaseOut


{-| A custom speed profile defined by a cubic bezier curve, the same format
used by CSS `cubic-bezier(...)` timing functions. The four numbers are the two
control points `(x1, y1)` and `(x2, y2)`.

    Animate.cubicBezier 0.68 -0.55 0.265 1.55

This one makes the motion pull back slightly, race forward, overshoot the
target and settle, like a spring.

-}
cubicBezier : Float -> Float -> Float -> Float -> Easing
cubicBezier =
    Internal.CubicBezier


{-| Animates a single attribute of a shape between keyframe values with easing.

Each keyframe is a tuple of `( time, easing, value )` where:

  - `time` is seconds from the start of the animation when this value is reached
  - `easing` is the speed profile of the motion leading TO this value
  - `value` is the attribute value at this keyframe (as a string)

The initial value comes from the element's own attributes.

    -- Pulse a rectangle's corner radius:
    Evg.rect [ Evg.cornerRadius 30, Evg.fillStr "navy" ]
        { x = 10, y = 10, width = 100, height = 100 }
        |> Animate.animate [ Animate.repeatIndefinite ]
            "rx"
            [ ( 0.8, Animate.easeLinear, "50" )
            , ( 1.8, Animate.easeInOut, "20" )
            , ( 3.0, Animate.easeLinear, "30" )
            ]

This shows a navy square whose corners continuously round off and sharpen
again.

-}
animate :
    List (AnimationOption msg)
    -> String
    -> List ( Float, Easing, String )
    -> Evg msg
    -> Evg msg
animate options attrName kfs (Internal.Evg evgRecord) =
    let
        fullKeyframes =
            if hasKeyframeAtZero kfs then
                kfs

            else
                case lookupAttr attrName evgRecord.attrs of
                    Just currentValue ->
                        ( 0, easeLinear, currentValue ) :: kfs

                    Nothing ->
                        kfs

        animateNode =
            buildAnimateNode options attrName fullKeyframes
    in
    Internal.Evg { evgRecord | children = evgRecord.children ++ [ wrapNode animateNode ] }


{-| Instantly sets an attribute to a value at a chosen moment, with no smooth
transition. Handy for toggling something on at a delay or on a click.

    -- Turn a circle red the moment it is clicked:
    Evg.circle
        [ Evg.fillStr "gray" ]
        { r = 20, center = ( 50, 50 ) }
        |> Animate.set
            [ Animate.beginOn Animate.click ]
            "fill"
            "red"

The circle stays gray until clicked, then instantly turns red.

Since nothing is blended, the `easing` option has no effect here. The
`duration` option means something different: it is how long the set value
lasts, after which the value snaps back (unless you also use `fillFreeze`).

-}
set :
    List (AnimationOption msg)
    -> String
    -> String
    -> Evg msg
    -> Evg msg
set options attrName toValue (Internal.Evg evgRecord) =
    let
        durAttrs =
            case getDurationMaybe options of
                Just d ->
                    [ Svg.Attributes.dur (seconds d) ]

                Nothing ->
                    []

        node =
            Svg.node "set"
                ([ Svg.Attributes.attributeName attrName
                 , Svg.Attributes.to toValue
                 ]
                    ++ durAttrs
                    ++ beginAttrs options
                    ++ behaviorAttrs { forceAdditive = False, includeFillRestart = True } options
                )
                []
    in
    Internal.Evg { evgRecord | children = evgRecord.children ++ [ wrapNode node ] }


{-| Spins a shape by a number of degrees. Each keyframe is
`( time, easing, angle )`, where `angle` is in degrees. Positive angles turn
clockwise.

The rotation is added on top of any transforms already on the element, and it
turns around the coordinate system's origin (the top-left corner). To spin a
shape in place, use `rotateAround`.

    -- A shape spinning a full turn every 2 seconds:
    Evg.rect
        [ Evg.fillStr "teal" ]
        { x = 40, y = 40, width = 20, height = 20 }
        |> Animate.rotate [ Animate.repeatIndefinite ]
            [ ( 2, Animate.easeLinear, 360 ) ]

This shows a square sweeping around the top-left corner of the drawing in a
wide circle.

-}
rotate :
    List (AnimationOption msg)
    -> List ( Float, Easing, Float )
    -> Evg msg
    -> Evg msg
rotate options kfs =
    attachTransform options "rotate" "0" (mapValue String.fromFloat kfs)


{-| Like `rotate`, but spins around a chosen center point `( cx, cy )`. This
is the usual way to rotate a shape "in place".

    -- Spin a square around its center at (50, 50):
    Evg.rect
        [ Evg.fillStr "teal" ]
        { x = 40, y = 40, width = 20, height = 20 }
        |> Animate.rotateAround
            [ Animate.repeatIndefinite ]
            ( 50, 50 )
            [ ( 2, Animate.easeLinear, 360 ) ]

This shows a square smoothly turning in place, completing a revolution every
two seconds.

-}
rotateAround :
    List (AnimationOption msg)
    -> ( Float, Float )
    -> List ( Float, Easing, Float )
    -> Evg msg
    -> Evg msg
rotateAround options center kfs =
    attachTransform options
        "rotate"
        (aroundValue "0" center)
        (mapValue (\a -> aroundValue (String.fromFloat a) center) kfs)


{-| Grows or shrinks a shape uniformly. A factor of `1` is the original size,
`2` is double, `0.5` is half. Each keyframe is `( time, easing, factor )`.

    -- A pulsing "heartbeat" scale:
    Evg.circle
        [ Evg.fillStr "crimson" ]
        { r = 20, center = ( 50, 50 ) }
        |> Animate.scale [ Animate.repeatIndefinite ]
            [ ( 0.3, Animate.easeOut, 1.3 )
            , ( 0.6, Animate.easeInOut, 1 )
            ]

This shows a circle throbbing larger and back like a heartbeat.

Note that scaling happens relative to the coordinate system origin, so shapes
away from the top-left corner also drift as they grow.

-}
scale :
    List (AnimationOption msg)
    -> List ( Float, Easing, Float )
    -> Evg msg
    -> Evg msg
scale options kfs =
    attachTransform options "scale" "1" (mapValue String.fromFloat kfs)


{-| Like `scale`, but with separate horizontal and vertical factors. Each
keyframe value is a pair `( sx, sy )`.

    Evg.rect
        [ Evg.fillStr "teal" ]
        { x = 40, y = 40, width = 20, height = 20 }
        |> Animate.scaleXY [ Animate.repeatIndefinite ]
            [ ( 1, Animate.easeInOut, ( 2, 0.5 ) ) ]

This shows a square repeatedly squashing into a wide, flat rectangle.

-}
scaleXY :
    List (AnimationOption msg)
    -> List ( Float, Easing, ( Float, Float ) )
    -> Evg msg
    -> Evg msg
scaleXY options kfs =
    attachTransform options "scale" "1 1" (mapValue pairValue kfs)


{-| Slides a shape by a horizontal and vertical offset. Each keyframe value is a
pair `( dx, dy )`, added on top of the element's own position.

    -- Slide 100 to the right and back:
    Evg.circle
        [ Evg.fillStr "orange" ]
        { r = 10, center = ( 20, 50 ) }
        |> Animate.translate
            [ Animate.repeatIndefinite ]
            [ ( 1, Animate.easeInOut, ( 100, 0 ) )
            , ( 2, Animate.easeInOut, ( 0, 0 ) )
            ]

This shows a circle gliding to the right and back again, over and over.

-}
translate :
    List (AnimationOption msg)
    -> List ( Float, Easing, ( Float, Float ) )
    -> Evg msg
    -> Evg msg
translate options kfs =
    attachTransform options "translate" "0 0" (mapValue pairValue kfs)


{-| Slants a shape sideways by an angle in degrees (its top edge leans left or
right). Each keyframe is `( time, easing, angle )`.
-}
skewX :
    List (AnimationOption msg)
    -> List ( Float, Easing, Float )
    -> Evg msg
    -> Evg msg
skewX options kfs =
    attachTransform options "skewX" "0" (mapValue String.fromFloat kfs)


{-| Slants a shape vertically by an angle in degrees (its side edges lean up or
down). Each keyframe is `( time, easing, angle )`.
-}
skewY :
    List (AnimationOption msg)
    -> List ( Float, Easing, Float )
    -> Evg msg
    -> Evg msg
skewY options kfs =
    attachTransform options "skewY" "0" (mapValue String.fromFloat kfs)


attachTransform :
    List (AnimationOption msg)
    -> String
    -> String
    -> List ( Float, Easing, String )
    -> Evg msg
    -> Evg msg
attachTransform options typeStr identityStr strKfs (Internal.Evg evgRecord) =
    let
        ( _, base ) =
            transformBaseAttrs True options typeStr identityStr strKfs

        node =
            Svg.node "animateTransform" (base ++ beginAttrs options) []
    in
    Internal.Evg { evgRecord | children = evgRecord.children ++ [ wrapNode node ] }


transformBaseAttrs :
    Bool
    -> List (AnimationOption msg)
    -> String
    -> String
    -> List ( Float, Easing, String )
    -> ( Float, List (VirtualDom.Attribute msg) )
transformBaseAttrs includeFillRestart options typeStr identityStr strKfs =
    let
        dur =
            getDuration options (maxKfTime strKfs)

        normalized =
            normalizeKeyframes dur (Just identityStr) strKfs

        base =
            [ Svg.Attributes.attributeName "transform"
            , Svg.Attributes.type_ typeStr
            , Svg.Attributes.additive "sum"
            ]
                ++ timingAttrs options normalized
                ++ [ Svg.Attributes.dur (seconds dur) ]
                ++ behaviorAttrs { forceAdditive = True, includeFillRestart = includeFillRestart } options
    in
    ( dur, base )


{-| Moves an element along a path over the animation's duration. By default the
element also turns to face the direction it is travelling.

    import Evg.Path exposing (Path(..), PathSegment(..))

    -- A circle repeatedly gliding along a curve:
    Evg.circle
        [ Evg.fillStr "red" ]
        { r = 5, center = ( 0, 0 ) }
        |> Animate.motion
            [ Animate.repeatIndefinite
            , Animate.duration 3
            ]
            [ M ( 10, 80 )
                [ C ( 40, 10 ) ( 65, 10 ) ( 95, 80 ) ]
            ]

This shows a small red dot swooping up and over an arc, then starting again.

Use `upright`, `orientReverse` or `orientAngle` to change how the element is
turned as it moves.

-}
motion :
    List (AnimationOption msg)
    -> List Evg.Path.Path
    -> Evg msg
    -> Evg msg
motion options paths (Internal.Evg evgRecord) =
    let
        pathStr =
            paths |> List.map Evg.Path.toString |> String.concat

        dur =
            getDuration options 1.0

        easingAttrs =
            case getEasingMaybe options of
                Just e ->
                    [ Svg.Attributes.keyPoints "0;1"
                    , Svg.Attributes.keyTimes "0;1"
                    , Svg.Attributes.calcMode "spline"
                    , Svg.Attributes.keySplines (easingToSpline e)
                    ]

                Nothing ->
                    []

        node =
            Svg.node "animateMotion"
                ([ Svg.Attributes.dur (seconds dur)
                 , Svg.Attributes.path pathStr
                 ]
                    ++ easingAttrs
                    ++ [ VirtualDom.attribute "rotate" (motionRotate options) ]
                    ++ beginAttrs options
                    ++ behaviorAttrs { forceAdditive = False, includeFillRestart = True } options
                )
                []
    in
    Internal.Evg { evgRecord | children = evgRecord.children ++ [ wrapNode node ] }


{-| Moves an element along a path like `motion`, but lets you control how far
along the path the element is at each moment. Each keyframe is
`( time, easing, progress )`, where `progress` is a fraction from `0` (start of
the path) to `1` (end).

This lets you speed up, slow down, pause or even reverse along a fixed path.

    import Evg.Path exposing (Path(..), PathSegment(..))

    Evg.circle
        [ Evg.fillStr "red" ]
        { r = 5, center = ( 0, 0 ) }
        |> Animate.motionKeyframes
            [ Animate.repeatIndefinite
            , Animate.duration 4
            ]
            [ M ( 10, 80 )
                [ C ( 40, 10 ) ( 65, 10 ) ( 95, 80 ) ]
            ]
            [ ( 1, Animate.easeInOut, 0.5 )
            , ( 4, Animate.easeInOut, 1 )
            ]

The dot rushes to the middle of the curve in the first second, then drifts
slowly through the rest.

-}
motionKeyframes :
    List (AnimationOption msg)
    -> List Evg.Path.Path
    -> List ( Float, Easing, Float )
    -> Evg msg
    -> Evg msg
motionKeyframes options paths kfs (Internal.Evg evgRecord) =
    let
        pathStr =
            paths |> List.map Evg.Path.toString |> String.concat

        dur =
            getDuration options (maxKfTime kfs)

        normalized =
            normalizeKeyframes dur Nothing (mapValue String.fromFloat kfs)

        node =
            Svg.node "animateMotion"
                ([ Svg.Attributes.dur (seconds dur)
                 , Svg.Attributes.path pathStr
                 ]
                    ++ motionTimingAttrs options normalized
                    ++ [ VirtualDom.attribute "rotate" (motionRotate options) ]
                    ++ beginAttrs options
                    ++ behaviorAttrs { forceAdditive = False, includeFillRestart = True } options
                )
                []
    in
    Internal.Evg { evgRecord | children = evgRecord.children ++ [ wrapNode node ] }


motionRotate : List (AnimationOption msg) -> String
motionRotate options =
    if List.any isUpright options then
        "0"

    else if List.any isOrientReverse options then
        "auto-reverse"

    else
        case getOrientAngle options of
            Just a ->
                String.fromFloat a

            Nothing ->
                "auto"


hasKeyframeAtZero : List ( Float, Easing, String ) -> Bool
hasKeyframeAtZero kfs =
    case kfs of
        ( t, _, _ ) :: _ ->
            t == 0

        [] ->
            False


lookupAttr : String -> List ( String, String ) -> Maybe String
lookupAttr name attrs =
    case attrs of
        [] ->
            Nothing

        ( k, v ) :: rest ->
            if k == name then
                Just v

            else
                lookupAttr name rest


{-| Animates between complete shapes at specified times. Each entry is a
snapshot of the whole shape at a moment in seconds; the library works out
which attributes change across snapshots and generates synchronized
animations for each one, and the browser blends between them.

This is the highest-level animation API: you describe what the shape looks
like at each moment, and the library handles the rest.

    import Evg
    import Evg.Animate as Animate

    pulsingCircle =
        Animate.keyframes
            [ Animate.repeatIndefinite
            , Animate.easing Animate.easeInOut
            ]
            [ ( 0.0
              , Evg.circle
                    [ Evg.fillStr "rgb(20,60,20)" ]
                    { r = 10, center = ( 50, 50 ) }
              )
            , ( 0.6
              , Evg.circle
                    [ Evg.fillStr "rgb(20,180,20)" ]
                    { r = 40, center = ( 50, 50 ) }
              )
            , ( 1.0
              , Evg.circle
                    [ Evg.fillStr "rgb(20,60,20)" ]
                    { r = 10, center = ( 50, 50 ) }
              )
            ]

This shows a circle repeatedly growing while brightening to a vivid green,
then shrinking and darkening back.

If frames have different element types, the shapes are swapped out at the
right moments instead of smoothly blended.

-}
keyframes : List (AnimationOption msg) -> List ( Float, Evg msg ) -> Evg msg
keyframes options frames =
    case frames of
        [] ->
            wrapNode (VirtualDom.text "")

        _ ->
            let
                runs =
                    segmentByCompatibility frames

                dur =
                    List.foldl (\( t, _ ) acc -> max t acc) 0 frames

                globalEasing =
                    getEasing options
            in
            case runs of
                [ singleRun ] ->
                    case singleRun of
                        _ :: _ ->
                            keyframesCompatible options globalEasing dur singleRun

                        [] ->
                            wrapNode (VirtualDom.text "")

                multipleRuns ->
                    buildSegmentedTimeline options globalEasing dur multipleRuns


segmentByCompatibility : List ( Float, Evg msg ) -> List (List ( Float, Evg msg ))
segmentByCompatibility frames =
    case frames of
        [] ->
            []

        first :: rest ->
            let
                go remaining currentRun acc =
                    case remaining of
                        [] ->
                            List.reverse (List.reverse currentRun :: acc)

                        frame :: more ->
                            if pairCompatible (List.head (List.reverse currentRun) |> Maybe.withDefault frame) frame then
                                go more (frame :: currentRun) acc

                            else
                                go more [ frame ] (List.reverse currentRun :: acc)
            in
            go rest [ first ] []


pairCompatible : ( Float, Evg msg ) -> ( Float, Evg msg ) -> Bool
pairCompatible ( _, Internal.Evg a ) ( _, Internal.Evg b ) =
    List.map Tuple.first a.attrs == List.map Tuple.first b.attrs


buildSegmentedTimeline : List (AnimationOption msg) -> Easing -> Float -> List (List ( Float, Evg msg )) -> Evg msg
buildSegmentedTimeline options globalEasing dur runs =
    let
        isRepeating =
            List.any isRepeatIndefinite options

        runChildren =
            List.indexedMap
                (\i run ->
                    case run of
                        [] ->
                            wrapNode (VirtualDom.text "")

                        ( startT, Internal.Evg firstRecord ) :: _ ->
                            let
                                nextRunStart =
                                    runs
                                        |> List.drop (i + 1)
                                        |> List.head
                                        |> Maybe.andThen List.head
                                        |> Maybe.map Tuple.first
                                        |> Maybe.withDefault dur

                                animatedElement =
                                    if List.length run > 1 then
                                        keyframesCompatible options globalEasing dur run

                                    else
                                        Internal.Evg firstRecord

                                animatedNode =
                                    Internal.toNode animatedElement

                                repeatAttr =
                                    if isRepeating then
                                        [ Svg.Attributes.repeatCount "indefinite" ]

                                    else
                                        [ VirtualDom.attribute "fill" "freeze" ]

                                visibilityAnim =
                                    Svg.animate
                                        ([ Svg.Attributes.attributeName "visibility"
                                         , Svg.Attributes.dur (seconds dur)
                                         , Svg.Attributes.values (visibilityValues startT nextRunStart dur)
                                         , Svg.Attributes.keyTimes (visibilityKeyTimes startT nextRunStart dur)
                                         , Svg.Attributes.calcMode "discrete"
                                         ]
                                            ++ repeatAttr
                                        )
                                        []

                                wrappedNode =
                                    Svg.g [ Svg.Attributes.visibility "hidden" ] [ animatedNode, visibilityAnim ]
                            in
                            -- SMIL timelines have no serializable form, so the
                            -- fallback is empty: toString omits the animation.
                            Internal.Evg { content = Internal.Raw wrappedNode Internal.emptyEvg, ownMatrix = Internal.identityMat, children = [], hash = 0, defs = firstRecord.defs, attrs = [] }
                )
                runs
    in
    Internal.Evg
        { content = Internal.Tag "g" [] []
        , ownMatrix = Internal.identityMat
        , children = runChildren
        , hash = 0
        , defs = List.concatMap (\( _, Internal.Evg { defs } ) -> defs) (List.concat runs)
        , attrs = []
        }


visibilityValues : Float -> Float -> Float -> String
visibilityValues startT endT dur =
    if startT == 0 then
        "visible;hidden"

    else if endT >= dur then
        "hidden;visible"

    else
        "hidden;visible;hidden"


visibilityKeyTimes : Float -> Float -> Float -> String
visibilityKeyTimes startT endT dur =
    if startT == 0 then
        "0;" ++ String.fromFloat (endT / dur)

    else if endT >= dur then
        "0;" ++ String.fromFloat (startT / dur)

    else
        "0;" ++ String.fromFloat (startT / dur) ++ ";" ++ String.fromFloat (endT / dur)


keyframesCompatible : List (AnimationOption msg) -> Easing -> Float -> List ( Float, Evg msg ) -> Evg msg
keyframesCompatible options globalEasing dur frames =
    case frames of
        [] ->
            wrapNode (VirtualDom.text "")

        ( _, Internal.Evg baseRecord ) :: _ ->
            let
                allDefs =
                    List.concatMap (\( _, Internal.Evg { defs } ) -> defs) frames

                frameData =
                    List.map (\( t, Internal.Evg { attrs } ) -> ( t, attrs )) frames

                allKeys =
                    frameData
                        |> List.concatMap (\( _, attrs ) -> List.map Tuple.first attrs)
                        |> uniqueStrings

                ( defKeys, normalKeys ) =
                    List.partition (\key -> attrIsDefRef key frameData) (List.filter (\key -> attrChanges key frameData) allKeys)

                animatedDefs =
                    List.filterMap (animateDefAttr options frames allDefs) defKeys

                consumedDefIds =
                    defKeys
                        |> List.concatMap
                            (\key ->
                                frameData
                                    |> List.filterMap (\( _, attrs ) -> lookupAttr key attrs)
                                    |> List.filterMap extractDefId
                            )

                staticDefs =
                    List.filter (\(Internal.Def id _) -> not (List.member id consumedDefIds)) allDefs

                changingKeys =
                    normalKeys

                animateChildren =
                    List.map
                        (\key ->
                            let
                                attrKeyframes =
                                    List.map
                                        (\( t, attrs ) ->
                                            ( t, globalEasing, lookupAttrWithDefault key "" attrs )
                                        )
                                        frameData
                            in
                            makeAnimateChild options key attrKeyframes dur
                        )
                        changingKeys

                childCounts =
                    List.map (\( _, Internal.Evg { children } ) -> List.length children) frames

                minChildCount =
                    List.foldl min 999999 childCounts

                maxChildCount =
                    List.foldl max 0 childCounts

                sharedChildren =
                    List.range 0 (minChildCount - 1)
                        |> List.map
                            (\i ->
                                let
                                    childFrames =
                                        List.filterMap
                                            (\( t, Internal.Evg { children } ) ->
                                                List.head (List.drop i children)
                                                    |> Maybe.map (\child -> ( t, child ))
                                            )
                                            frames
                                in
                                keyframes options childFrames
                            )

                isRepeating =
                    List.any isRepeatIndefinite options

                extraChildren =
                    List.range minChildCount (maxChildCount - 1)
                        |> List.filterMap
                            (\i ->
                                let
                                    childFrames =
                                        List.filterMap
                                            (\( t, Internal.Evg { children } ) ->
                                                List.head (List.drop i children)
                                                    |> Maybe.map (\child -> ( t, child ))
                                            )
                                            frames
                                in
                                case childFrames of
                                    [] ->
                                        Nothing

                                    _ ->
                                        Just (wrapExtraChild options isRepeating dur frames childFrames)
                            )
            in
            Internal.Evg
                { baseRecord
                    | children = sharedChildren ++ extraChildren ++ animateChildren
                    , defs = dedupDefs (animatedDefs ++ staticDefs)
                }


attrIsDefRef : String -> List ( Float, List ( String, String ) ) -> Bool
attrIsDefRef key frameData =
    frameData
        |> List.filterMap (\( _, attrs ) -> lookupAttr key attrs)
        |> List.all (String.startsWith "url(#")


animateDefAttr : List (AnimationOption msg) -> List ( Float, Evg msg ) -> List (Internal.Def msg) -> String -> Maybe (Internal.Def msg)
animateDefAttr options frames allDefs key =
    let
        frameDefIds =
            frames
                |> List.filterMap
                    (\( t, Internal.Evg { attrs } ) ->
                        lookupAttr key attrs
                            |> Maybe.andThen extractDefId
                            |> Maybe.map (\id -> ( t, id ))
                    )

        defEvgs =
            frameDefIds
                |> List.filterMap
                    (\( t, id ) ->
                        findDef id allDefs
                            |> Maybe.map (\evg -> ( t, evg ))
                    )
    in
    case defEvgs of
        [] ->
            Nothing

        _ ->
            let
                animated =
                    keyframes options defEvgs

                firstId =
                    frameDefIds |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault ""
            in
            Just (Internal.Def firstId animated)


extractDefId : String -> Maybe String
extractDefId value =
    if String.startsWith "url(#" value && String.endsWith ")" value then
        Just (String.dropLeft 5 value |> String.dropRight 1)

    else
        Nothing


findDef : String -> List (Internal.Def msg) -> Maybe (Internal.Evg msg)
findDef targetId defs =
    case defs of
        [] ->
            Nothing

        (Internal.Def id evg) :: rest ->
            if id == targetId then
                Just evg

            else
                findDef targetId rest


attrChanges : String -> List ( Float, List ( String, String ) ) -> Bool
attrChanges key frameData =
    let
        values =
            List.filterMap (\( _, attrs ) -> lookupAttr key attrs) frameData
    in
    case values of
        [] ->
            False

        first :: rest ->
            List.any (\v -> v /= first) rest


lookupAttrWithDefault : String -> String -> List ( String, String ) -> String
lookupAttrWithDefault key default attrs =
    case lookupAttr key attrs of
        Just v ->
            v

        Nothing ->
            default


makeAnimateChild : List (AnimationOption msg) -> String -> List ( Float, Easing, String ) -> Float -> Evg msg
makeAnimateChild options key attrKeyframes dur =
    wrapNode (buildAnimateNode (Duration dur :: options) key attrKeyframes)


wrapExtraChild : List (AnimationOption msg) -> Bool -> Float -> List ( Float, Evg msg ) -> List ( Float, Evg msg ) -> Evg msg
wrapExtraChild options isRepeating dur allFrames childFrames =
    let
        startT =
            childFrames |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0

        endT =
            childFrames |> List.reverse |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault dur

        visibleEnd =
            allFrames
                |> List.filterMap
                    (\( t, _ ) ->
                        if t > endT then
                            Just t

                        else
                            Nothing
                    )
                |> List.head
                |> Maybe.withDefault dur

        animatedChild =
            keyframes options childFrames

        childNode =
            Internal.toNode animatedChild

        repeatAttr =
            if isRepeating then
                [ Svg.Attributes.repeatCount "indefinite" ]

            else
                [ VirtualDom.attribute "fill" "freeze" ]

        visibilityAnim =
            Svg.animate
                ([ Svg.Attributes.attributeName "visibility"
                 , Svg.Attributes.dur (seconds dur)
                 , Svg.Attributes.values (visibilityValues startT visibleEnd dur)
                 , Svg.Attributes.keyTimes (visibilityKeyTimes startT visibleEnd dur)
                 , Svg.Attributes.calcMode "discrete"
                 ]
                    ++ repeatAttr
                )
                []
    in
    wrapNode (Svg.g [ Svg.Attributes.visibility "hidden" ] [ childNode, visibilityAnim ])


uniqueStrings : List String -> List String
uniqueStrings list =
    List.foldl
        (\item acc ->
            if List.member item acc then
                acc

            else
                acc ++ [ item ]
        )
        []
        list


dedupDefs : List (Internal.Def msg) -> List (Internal.Def msg)
dedupDefs defs =
    List.foldl
        (\((Internal.Def id _) as def) ( seen, acc ) ->
            if List.member id seen then
                ( seen, acc )

            else
                ( id :: seen, def :: acc )
        )
        ( [], [] )
        defs
        |> Tuple.second
        |> List.reverse


{-| Creates an animation by sampling a function at regular intervals.

The function receives a value from 0.0 to 1.0 representing progress through
the animation, and should return the shape at that point in time. The library
generates keyframes by evaluating the function at evenly-spaced sample points.

    -- A progress bar that fills from left to right:
    Animate.sampled [ Animate.repeatIndefinite ]
        { samples = 10, duration = 3 }
        (\progress ->
            Evg.rect [ Evg.fillStr "green" ]
                { x = 0
                , y = 40
                , width = progress * 200
                , height = 20
                }
        )

This shows a green bar repeatedly stretching from empty to full width over
three seconds.

More samples means smoother animation but larger DOM output. For most
animations, 6 to 12 samples is sufficient.

-}
sampled :
    List (AnimationOption msg)
    -> { samples : Int, duration : Float }
    -> (Float -> Evg msg)
    -> Evg msg
sampled options config fn =
    let
        n =
            max 1 config.samples

        frames =
            List.range 0 n
                |> List.map
                    (\i ->
                        let
                            fraction =
                                toFloat i / toFloat n
                        in
                        ( config.duration * fraction, fn fraction )
                    )
    in
    keyframes options frames



-- Sequencing


{-| A single stage of a `sequence`. Build one with `step`, `stepRotateAround`,
`stepTranslate` or `stepScale`.
-}
type Step msg
    = Step
        { intrinsicDur : Float
        , stepDelay : Float
        , hashInt : Int
        , render : String -> Maybe String -> List (VirtualDom.Attribute msg) -> VirtualDom.Node msg
        }


{-| Runs a list of animation steps one after another on the same element. Each
step waits for the previous one to finish before it starts.

    Evg.rect
        [ Evg.fillStr "teal" ]
        { x = 40, y = 40, width = 20, height = 20 }
        |> Animate.sequence [ Animate.fillFreeze ]
            [ Animate.stepTranslate
                [ Animate.duration 1 ]
                [ ( 1, Animate.easeOut, ( 40, 0 ) ) ]
            , Animate.stepRotateAround
                [ Animate.duration 1 ]
                ( 50, 50 )
                [ ( 1, Animate.easeInOut, 180 ) ]
            ]

This shows a square sliding to the right, then rotating a half turn once the
slide has finished.

If you start the sequence with a trigger (`beginOn Animate.click`), the whole
chain waits for that event and then runs step by step. Repeating an
event-triggered sequence is not supported.

-}
sequence :
    List (AnimationOption msg)
    -> List (Step msg)
    -> Evg msg
    -> Evg msg
sequence options steps (Internal.Evg evgRecord) =
    let
        eventTriggered =
            List.any isBeginOn options

        outerDistribute =
            distributeAttrs options

        nodes =
            if eventTriggered then
                buildEventSequence evgRecord.hash options outerDistribute steps

            else
                buildTimeSequence (getDelay options |> Maybe.withDefault 0) outerDistribute steps
    in
    Internal.Evg { evgRecord | children = evgRecord.children ++ List.map wrapNode nodes }


buildTimeSequence :
    Float
    -> List (VirtualDom.Attribute msg)
    -> List (Step msg)
    -> List (VirtualDom.Node msg)
buildTimeSequence outerDelay outer steps =
    let
        go remaining cumulative acc =
            case remaining of
                [] ->
                    List.reverse acc

                (Step s) :: rest ->
                    let
                        begin =
                            outerDelay + cumulative + s.stepDelay

                        node =
                            s.render (seconds begin) Nothing outer
                    in
                    go rest (cumulative + s.stepDelay + s.intrinsicDur) (node :: acc)
    in
    go steps 0 []


buildEventSequence :
    Int
    -> List (AnimationOption msg)
    -> List (VirtualDom.Attribute msg)
    -> List (Step msg)
    -> List (VirtualDom.Node msg)
buildEventSequence targetHash options outer steps =
    let
        trigger =
            beginString options |> Maybe.withDefault "indefinite"

        ids =
            List.indexedMap (stepId targetHash) steps

        total =
            List.length steps
    in
    List.indexedMap
        (\i (Step s) ->
            let
                begin =
                    if i == 0 then
                        trigger

                    else
                        let
                            prevId =
                                listGet (i - 1) ids |> Maybe.withDefault ""

                            suffix =
                                if s.stepDelay > 0 then
                                    "+" ++ seconds s.stepDelay

                                else
                                    ""
                        in
                        prevId ++ ".end" ++ suffix

                maybeId =
                    if i < total - 1 then
                        listGet i ids

                    else
                        Nothing
            in
            s.render begin maybeId outer
        )
        steps


stepId : Int -> Int -> Step msg -> String
stepId targetHash index (Step s) =
    "e" ++ String.fromInt (targetHash |> Internal.mixInt index |> Internal.mixInt s.hashInt)


listGet : Int -> List a -> Maybe a
listGet i xs =
    List.head (List.drop i xs)


{-| A sequence step that animates a single attribute, exactly like `animate`.
-}
step :
    List (AnimationOption msg)
    -> String
    -> List ( Float, Easing, String )
    -> Step msg
step options attrName kfs =
    let
        dur =
            getDuration options (maxKfTime kfs)

        normalized =
            normalizeKeyframes dur Nothing kfs

        base =
            Svg.Attributes.attributeName attrName
                :: timingAttrs options normalized
                ++ Svg.Attributes.dur (seconds dur)
                :: behaviorAttrs { forceAdditive = False, includeFillRestart = False } options
    in
    Step
        { intrinsicDur = dur
        , stepDelay = getDelay options |> Maybe.withDefault 0
        , hashInt = hashStrKfs attrName kfs
        , render =
            \begin maybeId outer ->
                Svg.animate (base ++ outer ++ Svg.Attributes.begin begin :: idAttr maybeId) []
        }


{-| A sequence step that rotates around a center point, like `rotateAround`.
-}
stepRotateAround :
    List (AnimationOption msg)
    -> ( Float, Float )
    -> List ( Float, Easing, Float )
    -> Step msg
stepRotateAround options center kfs =
    transformStep options
        "rotate"
        (aroundValue "0" center)
        (mapValue (\a -> aroundValue (String.fromFloat a) center) kfs)


{-| A sequence step that slides the element, like `translate`.
-}
stepTranslate :
    List (AnimationOption msg)
    -> List ( Float, Easing, ( Float, Float ) )
    -> Step msg
stepTranslate options kfs =
    transformStep options "translate" "0 0" (mapValue pairValue kfs)


{-| A sequence step that grows or shrinks the element, like `scale`.
-}
stepScale :
    List (AnimationOption msg)
    -> List ( Float, Easing, Float )
    -> Step msg
stepScale options kfs =
    transformStep options "scale" "1" (mapValue String.fromFloat kfs)


transformStep :
    List (AnimationOption msg)
    -> String
    -> String
    -> List ( Float, Easing, String )
    -> Step msg
transformStep options typeStr identityStr strKfs =
    let
        ( dur, base ) =
            transformBaseAttrs False options typeStr identityStr strKfs
    in
    Step
        { intrinsicDur = dur
        , stepDelay = getDelay options |> Maybe.withDefault 0
        , hashInt = hashStrKfs typeStr strKfs
        , render =
            \begin maybeId outer ->
                Svg.node "animateTransform" (base ++ outer ++ Svg.Attributes.begin begin :: idAttr maybeId) []
        }


idAttr : Maybe String -> List (VirtualDom.Attribute msg)
idAttr maybeId =
    case maybeId of
        Just i ->
            [ Svg.Attributes.id i ]

        Nothing ->
            []


hashStrKfs : String -> List ( Float, Easing, String ) -> Int
hashStrKfs label kfs =
    List.foldl
        (\( t, _, v ) acc -> acc |> Internal.mixFloat t |> Internal.mixString v)
        (Internal.mixString label 5381)
        kfs



-- Internal helpers


buildAnimateNode : List (AnimationOption msg) -> String -> List ( Float, Easing, String ) -> VirtualDom.Node msg
buildAnimateNode options attrName kfs =
    let
        dur =
            getDuration options (maxKfTime kfs)

        normalized =
            normalizeKeyframes dur Nothing kfs
    in
    Svg.animate
        (Svg.Attributes.attributeName attrName
            :: timingAttrs options normalized
            ++ Svg.Attributes.dur (seconds dur)
            :: beginAttrs options
            ++ behaviorAttrs { forceAdditive = False, includeFillRestart = True } options
        )
        []


{-| Scale keyframe times into 0..1, prepending a start frame (from the given
value, or a copy of the first frame if `Nothing`) and appending a trailing 1.0
frame when needed.
-}
normalizeKeyframes : Float -> Maybe String -> List ( Float, Easing, String ) -> List ( Float, Easing, String )
normalizeKeyframes dur startValue kfs =
    let
        raw =
            List.map (\( t, e, v ) -> ( t / dur, e, v )) kfs

        withStart =
            case raw of
                ( t0, _, v0 ) :: _ ->
                    if t0 > 0.001 then
                        ( 0, Internal.Linear, Maybe.withDefault v0 startValue ) :: raw

                    else
                        raw

                [] ->
                    raw
    in
    case List.reverse withStart of
        ( tLast, _, vLast ) :: _ ->
            if tLast < 0.999 then
                withStart ++ [ ( 1, Internal.Linear, vLast ) ]

            else
                withStart

        [] ->
            withStart


timingAttrs : List (AnimationOption msg) -> List ( Float, Easing, String ) -> List (VirtualDom.Attribute msg)
timingAttrs options normalized =
    let
        vals =
            normalized |> List.map (\( _, _, v ) -> v) |> String.join ";"
    in
    if List.any isPaced options then
        [ Svg.Attributes.values vals
        , Svg.Attributes.calcMode "paced"
        ]

    else if List.any isStepped options then
        [ Svg.Attributes.values vals
        , Svg.Attributes.keyTimes (keyTimesString normalized)
        , Svg.Attributes.calcMode "discrete"
        ]

    else
        [ Svg.Attributes.values vals
        , Svg.Attributes.keyTimes (keyTimesString normalized)
        , Svg.Attributes.calcMode "spline"
        , Svg.Attributes.keySplines (keySplinesString normalized)
        ]


motionTimingAttrs : List (AnimationOption msg) -> List ( Float, Easing, String ) -> List (VirtualDom.Attribute msg)
motionTimingAttrs options normalized =
    let
        kp =
            normalized |> List.map (\( _, _, v ) -> v) |> String.join ";"
    in
    if List.any isPaced options then
        [ Svg.Attributes.keyPoints kp
        , Svg.Attributes.calcMode "paced"
        ]

    else if List.any isStepped options then
        [ Svg.Attributes.keyPoints kp
        , Svg.Attributes.keyTimes (keyTimesString normalized)
        , Svg.Attributes.calcMode "discrete"
        ]

    else
        [ Svg.Attributes.keyPoints kp
        , Svg.Attributes.keyTimes (keyTimesString normalized)
        , Svg.Attributes.calcMode "spline"
        , Svg.Attributes.keySplines (keySplinesString normalized)
        ]


keyTimesString : List ( Float, Easing, String ) -> String
keyTimesString normalized =
    normalized |> List.map (\( t, _, _ ) -> String.fromFloat t) |> String.join ";"


keySplinesString : List ( Float, Easing, String ) -> String
keySplinesString normalized =
    normalized |> List.drop 1 |> List.map (\( _, e, _ ) -> easingToSpline e) |> String.join ";"


behaviorAttrs :
    { forceAdditive : Bool, includeFillRestart : Bool }
    -> List (AnimationOption msg)
    -> List (VirtualDom.Attribute msg)
behaviorAttrs { forceAdditive, includeFillRestart } options =
    repeatAttrs options
        ++ additiveAttrs forceAdditive options
        ++ accumulateAttrs options
        ++ (if includeFillRestart then
                fillAttrs options ++ restartAttrs options

            else
                []
           )
        ++ eventAttrs options


repeatAttrs : List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
repeatAttrs options =
    (if List.any isRepeatIndefinite options then
        [ Svg.Attributes.repeatCount "indefinite" ]

     else
        case getRepeatCount options of
            Just n ->
                [ Svg.Attributes.repeatCount (String.fromFloat n) ]

            Nothing ->
                []
    )
        ++ (case getRepeatFor options of
                Just d ->
                    [ Svg.Attributes.repeatDur (seconds d) ]

                Nothing ->
                    []
           )


additiveAttrs : Bool -> List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
additiveAttrs forceAdditive options =
    if forceAdditive || List.any isAdditive options then
        [ Svg.Attributes.additive "sum" ]

    else
        []


accumulateAttrs : List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
accumulateAttrs options =
    if List.any isAccumulate options then
        [ Svg.Attributes.accumulate "sum" ]

    else
        []


fillAttrs : List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
fillAttrs options =
    if List.any isFillFreeze options then
        [ Svg.Attributes.fill "freeze" ]

    else
        []


restartAttrs : List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
restartAttrs options =
    if List.any isRestartNever options then
        [ Svg.Attributes.restart "never" ]

    else if List.any isRestartWhenNotActive options then
        [ Svg.Attributes.restart "whenNotActive" ]

    else
        []


eventAttrs : List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
eventAttrs options =
    List.filterMap
        (\opt ->
            case opt of
                OnBegin m ->
                    Just (VirtualDom.on "beginEvent" (VirtualDom.Normal (Decode.succeed m)))

                OnEnd m ->
                    Just (VirtualDom.on "endEvent" (VirtualDom.Normal (Decode.succeed m)))

                OnRepeat m ->
                    Just (VirtualDom.on "repeatEvent" (VirtualDom.Normal (Decode.succeed m)))

                _ ->
                    Nothing
        )
        options


distributeAttrs : List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
distributeAttrs options =
    fillAttrs options ++ restartAttrs options


beginAttrs : List (AnimationOption msg) -> List (VirtualDom.Attribute msg)
beginAttrs options =
    let
        begin =
            case beginString options of
                Just b ->
                    [ Svg.Attributes.begin b ]

                Nothing ->
                    []

        endTriggers =
            List.filterMap
                (\opt ->
                    case opt of
                        EndOn t ->
                            Just (triggerToString t)

                        _ ->
                            Nothing
                )
                options

        end =
            case endTriggers of
                [] ->
                    []

                _ ->
                    [ Svg.Attributes.end (String.join ";" endTriggers) ]
    in
    begin ++ end


beginString : List (AnimationOption msg) -> Maybe String
beginString options =
    let
        triggers =
            List.filterMap
                (\opt ->
                    case opt of
                        BeginOn t ->
                            Just (triggerToString t)

                        _ ->
                            Nothing
                )
                options
    in
    case triggers of
        [] ->
            case getDelay options of
                Just d ->
                    Just (seconds d)

                Nothing ->
                    Nothing

        _ ->
            Just (String.join ";" triggers)


triggerToString : Trigger -> String
triggerToString t =
    case t of
        ClickTrigger ->
            "click"

        MouseOverTrigger ->
            "mouseover"

        MouseOutTrigger ->
            "mouseout"

        ManualStart ->
            "indefinite"


seconds : Float -> String
seconds x =
    String.fromFloat x ++ "s"


maxKfTime : List ( Float, Easing, a ) -> Float
maxKfTime kfs =
    case kfs of
        [] ->
            1.0

        _ ->
            List.foldl (\( t, _, _ ) acc -> max t acc) 0 kfs


mapValue : (a -> String) -> List ( Float, Easing, a ) -> List ( Float, Easing, String )
mapValue toStr kfs =
    List.map (\( t, e, v ) -> ( t, e, toStr v )) kfs


pairValue : ( Float, Float ) -> String
pairValue ( x, y ) =
    String.fromFloat x ++ " " ++ String.fromFloat y


aroundValue : String -> ( Float, Float ) -> String
aroundValue angle ( cx, cy ) =
    angle ++ " " ++ String.fromFloat cx ++ " " ++ String.fromFloat cy


getEasing : List (AnimationOption msg) -> Easing
getEasing options =
    List.foldl
        (\opt acc ->
            case opt of
                EasingOption e ->
                    e

                _ ->
                    acc
        )
        Internal.EaseInOut
        options


getEasingMaybe : List (AnimationOption msg) -> Maybe Easing
getEasingMaybe options =
    List.foldl
        (\opt acc ->
            case opt of
                EasingOption e ->
                    Just e

                _ ->
                    acc
        )
        Nothing
        options


getDuration : List (AnimationOption msg) -> Float -> Float
getDuration options default =
    List.foldl
        (\opt acc ->
            case opt of
                Duration d ->
                    d

                _ ->
                    acc
        )
        default
        options


getDurationMaybe : List (AnimationOption msg) -> Maybe Float
getDurationMaybe options =
    List.foldl
        (\opt acc ->
            case opt of
                Duration d ->
                    Just d

                _ ->
                    acc
        )
        Nothing
        options


getRepeatCount : List (AnimationOption msg) -> Maybe Float
getRepeatCount options =
    List.foldl
        (\opt acc ->
            case opt of
                RepeatCount n ->
                    Just n

                _ ->
                    acc
        )
        Nothing
        options


getRepeatFor : List (AnimationOption msg) -> Maybe Float
getRepeatFor options =
    List.foldl
        (\opt acc ->
            case opt of
                RepeatFor d ->
                    Just d

                _ ->
                    acc
        )
        Nothing
        options


getDelay : List (AnimationOption msg) -> Maybe Float
getDelay options =
    List.foldl
        (\opt acc ->
            case opt of
                Delay d ->
                    Just d

                _ ->
                    acc
        )
        Nothing
        options


getOrientAngle : List (AnimationOption msg) -> Maybe Float
getOrientAngle options =
    List.foldl
        (\opt acc ->
            case opt of
                OrientAngle a ->
                    Just a

                _ ->
                    acc
        )
        Nothing
        options


isRepeatIndefinite : AnimationOption msg -> Bool
isRepeatIndefinite opt =
    case opt of
        RepeatIndefinite ->
            True

        _ ->
            False


isStepped : AnimationOption msg -> Bool
isStepped opt =
    case opt of
        Stepped ->
            True

        _ ->
            False


isPaced : AnimationOption msg -> Bool
isPaced opt =
    case opt of
        Paced ->
            True

        _ ->
            False


isAdditive : AnimationOption msg -> Bool
isAdditive opt =
    case opt of
        Additive ->
            True

        _ ->
            False


isAccumulate : AnimationOption msg -> Bool
isAccumulate opt =
    case opt of
        AccumulateRepeats ->
            True

        _ ->
            False


isFillFreeze : AnimationOption msg -> Bool
isFillFreeze opt =
    case opt of
        FillFreeze ->
            True

        _ ->
            False


isRestartNever : AnimationOption msg -> Bool
isRestartNever opt =
    case opt of
        RestartNever ->
            True

        _ ->
            False


isRestartWhenNotActive : AnimationOption msg -> Bool
isRestartWhenNotActive opt =
    case opt of
        RestartWhenNotActive ->
            True

        _ ->
            False


isBeginOn : AnimationOption msg -> Bool
isBeginOn opt =
    case opt of
        BeginOn _ ->
            True

        _ ->
            False


isUpright : AnimationOption msg -> Bool
isUpright opt =
    case opt of
        Upright ->
            True

        _ ->
            False


isOrientReverse : AnimationOption msg -> Bool
isOrientReverse opt =
    case opt of
        OrientReverse ->
            True

        _ ->
            False


{-| For `motion` and `motionKeyframes`: keep the element upright as it travels
along the path, instead of turning to face its direction of movement.
-}
upright : AnimationOption msg
upright =
    Upright


{-| For `motion` and `motionKeyframes`: turn the element to face backwards along
its direction of movement.
-}
orientReverse : AnimationOption msg
orientReverse =
    OrientReverse


{-| For `motion` and `motionKeyframes`: hold the element at a fixed angle (in
degrees) as it travels, regardless of the path's direction.
-}
orientAngle : Float -> AnimationOption msg
orientAngle =
    OrientAngle


easingToSpline : Easing -> String
easingToSpline e =
    case e of
        Internal.Linear ->
            "0 0 1 1"

        Internal.EaseInOut ->
            ".5 0 .5 1"

        Internal.EaseIn ->
            ".5 0 1 1"

        Internal.EaseOut ->
            "0 0 .5 1"

        Internal.CubicBezier x1 y1 x2 y2 ->
            String.fromFloat x1
                ++ " "
                ++ String.fromFloat y1
                ++ " "
                ++ String.fromFloat x2
                ++ " "
                ++ String.fromFloat y2
