module Evg.Drag exposing
    ( Model, init, state, preview, isDragging, setState, animateTo
    , View, Context, onDrag, key, zIndex, dragged
    , Msg, update, updateWithEvents, Event(..), subscriptions, view
    , Spec, fixed
    , between, betweenSpecs, betweenWith, BetweenOptions, Interpolation(..)
    , closest, closestSpecs, closestWith, ClosestOptions
    , vary, vary2, varyN, varyWith, Solver
    , constrain, Constraint, lessThan, moreThan, equal, inOrder, all, pin
    , withFloating, withFloatingWith, FloatingOptions
    , whenFar, whenFarWith
    , withSnapRadius, chain
    , onDrop, during
    , withOverlay
    , withDropTransition, withBranchTransition
    )

{-| Make drawings draggable by saying what they can _become_.

The usual way to make something draggable is to handle pointer events: on
press remember where you grabbed, on move work out the new position, on
release snap it somewhere sensible, and maybe animate. Every new interaction
means new arithmetic, and anything fancier than "follow the pointer" (snap to
slots, reorder a list, rotate a dial, move a card between piles) gets
complicated quickly.

This module turns that around. You keep writing a plain view function from
your state to a drawing. On anything draggable you say which _states_ dragging
it can lead to. The library draws those states (without showing them), looks
at where the dragged element ends up in each, and works out the rest: which
state the pointer is heading towards, how to blend the drawing in between,
where to land on release, and how to animate the landing.

    type alias State =
        { on : Bool }

    toggle : Drag.View State msg
    toggle ctx s =
        Evg.group []
            [ Evg.rect [ Evg.cornerRadius 30, Evg.fillStr "#ddd" ]
                { x = 0, y = 0, width = 120, height = 60 }
            , Evg.circle
                [ Evg.fillStr "white"
                , Drag.onDrag ctx "knob" (\() -> Drag.between [ { on = False }, { on = True } ])
                ]
                { r = 26
                , center =
                    if s.on then
                        ( 90, 30 )

                    else
                        ( 30, 30 )
                }
            ]

That is a complete toggle switch: the knob slides between its two positions
as you drag (the drawing is blended between the two states), and on release
it settles into whichever is closer.

![A toggle switch at four moments of a drag](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/drag-between.svg)

Above, the switch at four moments: grabbed, a third of the way across, two
thirds, and dropped. Note that the track's colour changes along with the
knob's position; nothing in the code above says it should, it follows from
blending the two drawings.

These ideas come from the paper [_Declarative Dragging_](https://declarative-dragging.github.io/)
and its library Dragology, by Joshua Horowitz, Andrew Blinn and Jeffrey Heer.


# Wiring it up

A draggable drawing has a [`Model`](#Model) holding the current state. Hook
its [`update`](#update), [`subscriptions`](#subscriptions) and
[`view`](#view) into your program like any other component:

    type alias Model =
        { toggle : Drag.Model State }

    type Msg
        = ToggleMsg (Drag.Msg State)

    update msg model =
        case msg of
            ToggleMsg dragMsg ->
                { model | toggle = Drag.update toggle dragMsg model.toggle }

    subscriptions model =
        Sub.map ToggleMsg (Drag.subscriptions model.toggle)

    view model =
        Evg.svg []
            { width = 120, height = 60 }
            [ Drag.view ToggleMsg toggle model.toggle ]

@docs Model, init, state, preview, isDragging, setState, animateTo
@docs View, Context, onDrag, key, zIndex, dragged
@docs Msg, update, updateWithEvents, Event, subscriptions, view


# Specs

A [`Spec`](#Spec) describes what dragging an element does. The basic specs
pick between states in different ways; the modifiers further down adjust
how they behave.

@docs Spec, fixed


## Blending between states

@docs between, betweenSpecs, betweenWith, BetweenOptions, Interpolation


## Snapping to the nearest option

@docs closest, closestSpecs, closestWith, ClosestOptions


## Continuous values

@docs vary, vary2, varyN, varyWith, Solver
@docs constrain, Constraint, lessThan, moreThan, equal, inOrder, all, pin


# Modifiers

@docs withFloating, withFloatingWith, FloatingOptions
@docs whenFar, whenFarWith
@docs withSnapRadius, chain
@docs onDrop, during
@docs withOverlay


# Transitions

Dropping something and switching between options animate by default, for 0.2
seconds with [`Animate.easeOut`](Evg-Animate#easeOut). These let you change
that. They take the same durations (in seconds) and easings as
[`Evg.Animate`](Evg-Animate), so motion looks consistent across a drawing.
A duration of 0 switches the animation off.

@docs withDropTransition, withBranchTransition

-}

import Browser.Events
import Evg exposing (Evg, Supported)
import Evg.Animate as Animate
import Evg.Events as Events
import Evg.Internal as Internal exposing (Attribute(..), Mat23)
import Evg.Internal.Interpolation as Interpolation
import Evg.Internal.Layered as Layered exposing (Layered)
import Evg.Internal.Optimize as Optimize
import Svg.Attributes
import VirtualDom



-- MODEL


{-| The state of a draggable drawing: your own `state`, plus whatever drag or
animation is in progress.
-}
type Model state
    = Model (ModelData state)


type alias ModelData state =
    { state : state
    , drag : Maybe (Active state)
    , spring : Maybe (Spring state)

    -- The key of the element that was last dropped, kept on top until its
    -- landing animation finishes.
    , landing : Maybe String
    }


type alias Active state =
    { key : String
    , anchor : Point
    , spec : Spec state
    , memory : Memory
    , startState : state
    , rootFromScene : Mat23
    , frame : Events.Frame
    , pointerId : Int
    , pointerType : Events.PointerType
    , result : Res state
    }


type alias Spring state =
    { from : Plan state
    , elapsed : Float
    , transition : TransitionData
    }


type alias Point =
    ( Float, Float )


{-| Start with the given state.
-}
init : state -> Model state
init s =
    Model { state = s, drag = Nothing, spring = Nothing, landing = Nothing }


{-| The current state. During a drag this is still the state from before the
drag; see [`preview`](#preview) for where the drag is heading.
-}
state : Model state -> state
state (Model m) =
    m.state


{-| The state the current drag would drop into if released now, or the
current state when nothing is being dragged. Handy for showing live values
next to the drawing.
-}
preview : Model state -> state
preview (Model m) =
    case m.drag of
        Just active ->
            active.result.dropState

        Nothing ->
            m.state


{-| Whether something is being dragged.
-}
isDragging : Model state -> Bool
isDragging (Model m) =
    isJust m.drag


isJust : Maybe a -> Bool
isJust maybe =
    case maybe of
        Just _ ->
            True

        Nothing ->
            False


{-| Replace the state immediately, abandoning any drag in progress.
-}
setState : state -> Model state -> Model state
setState s (Model m) =
    Model { m | state = s, drag = Nothing, spring = Nothing }


{-| Move to a new state with an animation lasting the given number of
seconds, as if it had been dropped there. Use it for changes that come from
elsewhere, such as buttons or keyboard shortcuts.

    Drag.animateTo 0.3 Animate.easeInOut { on = True } model

-}
animateTo : Float -> Animate.Easing -> state -> Model state -> Model state
animateTo seconds easing s (Model m) =
    Model
        { m
            | state = s
            , drag = Nothing
            , spring = startSpring (makeTransition seconds easing) m
        }



-- VIEW FUNCTIONS


{-| A view function for a draggable drawing. It is an ordinary function from
your state to a drawing, with one extra argument, the [`Context`](#Context),
which you need for [`onDrag`](#onDrag).

The library calls it many times per frame while dragging, on states that may
never be shown, so keep it a pure function of its arguments.

-}
type alias View state msg =
    Context state msg -> state -> Evg msg


{-| What a [`View`](#View) needs to know while it draws.
-}
type Context state msg
    = Context
        { toMsg : Maybe (Msg state -> msg)
        , dragged : Maybe String
        }


{-| The key of the element being dragged, if any. Use it to style the dragged
element differently, e.g. with a shadow.
-}
dragged : Context state msg -> Maybe String
dragged (Context ctx) =
    ctx.dragged


{-| Make an element draggable. The string is a key identifying the element
(see [`key`](#key)); the function says what dragging does. It runs once, when
the drag starts, so it can look at the state it was drawn from:

    Drag.onDrag ctx "knob" (\() -> Drag.between [ { on = False }, { on = True } ])

Grabbing an element also brings it to the front for the duration of the drag.

-}
onDrag : Context state msg -> String -> (() -> Spec state) -> Evg.Attribute { a | events : Supported } msg
onDrag (Context ctx) k makeSpec =
    case ctx.toMsg of
        Nothing ->
            key k

        Just toMsg ->
            Batch
                [ key k
                , Events.touchAction Events.None
                , Events.cursor Events.Grab
                , EventAttr (Internal.mixString k 77339)
                    (\accum ->
                        case Events.onPointerDownWith (\pointer -> toMsg (Start { key = k, makeSpec = makeSpec, pointer = pointer, accum = accum })) of
                            EventAttr _ build ->
                                build accum

                            _ ->
                                VirtualDom.attribute "data-drag" k
                    )
                ]


{-| Give an element an identity, so it can be followed from one state to
another. Elements with the same key in two states are treated as the same
thing, even if they sit in different groups, so blending moves them from one
place to the other instead of fading one out and the other in.

Give keys to the items of anything that gets rearranged: list entries, cards,
nodes in a tree. Keys must be unique within one drawing.

Keyed elements are drawn above the unkeyed drawing around them, nested keyed
elements above their keyed ancestors, and otherwise in the order they appear.
Use [`zIndex`](#zIndex) to change that.

-}
key : String -> Evg.Attribute a msg
key k =
    Attr (Internal.mixString k 1997) Layered.keyAttribute k (VirtualDom.attribute Layered.keyAttribute k)


{-| Stacking order among keyed siblings. Higher numbers are drawn later, so on
top; the default is 0, and negative numbers go below the element's keyed
parent. Only applies to keyed elements.
-}
zIndex : Int -> Evg.Attribute a msg
zIndex z =
    let
        str =
            String.fromInt z
    in
    Attr (Internal.mixString str 4391) Layered.zAttribute str (VirtualDom.attribute Layered.zAttribute str)



-- MESSAGES


{-| Messages for [`update`](#update).
-}
type Msg state
    = Start (StartInfo state)
    | MovedScene Point
    | EndedScene Point
    | MovedLocal Int Point
    | EndedLocal Int Point
    | Cancelled Int
    | Tick Float


type alias StartInfo state =
    { key : String
    , makeSpec : () -> Spec state
    , pointer : Events.Pointer
    , accum : Mat23
    }


{-| Things that happened during an [`updateWithEvents`](#updateWithEvents).

  - `Started key`: a drag of the element with that key began.
  - `Moved state`: the pointer moved; the state is where the drag would drop
    now.
  - `Dropped state`: the drag finished in this state, which is now the
    model's state.

-}
type Event state
    = Started String
    | Moved state
    | Dropped state


{-| Advance the model. Pass the same view function you draw with, because
working out a drag means drawing hypothetical states.
-}
update : View state msg -> Msg state -> Model state -> Model state
update userView msg model =
    updateWithEvents userView msg model |> Tuple.first


{-| Like [`update`](#update), but also tells you what happened, for example
to save a state once it's dropped.
-}
updateWithEvents : View state msg -> Msg state -> Model state -> ( Model state, List (Event state) )
updateWithEvents userView msg (Model m) =
    case msg of
        Start info ->
            if isJust m.drag || (info.pointer.pointerType == Events.Mouse && info.pointer.button /= Events.Main) then
                ( Model m, [] )

            else
                startDrag userView info m

        MovedScene scenePoint ->
            case m.drag of
                Just active ->
                    if active.pointerType == Events.Mouse then
                        moveTo userView (Internal.applyPoint active.rootFromScene scenePoint) active m

                    else
                        ( Model m, [] )

                Nothing ->
                    ( Model m, [] )

        EndedScene scenePoint ->
            case m.drag of
                Just active ->
                    if active.pointerType == Events.Mouse then
                        let
                            ( Model moved, _ ) =
                                moveTo userView (Internal.applyPoint active.rootFromScene scenePoint) active m
                        in
                        drop moved

                    else
                        ( Model m, [] )

                Nothing ->
                    ( Model m, [] )

        MovedLocal pointerId point ->
            case m.drag of
                Just active ->
                    if active.pointerId == pointerId && active.pointerType /= Events.Mouse then
                        moveTo userView point active m

                    else
                        ( Model m, [] )

                Nothing ->
                    ( Model m, [] )

        EndedLocal pointerId point ->
            case m.drag of
                Just active ->
                    if active.pointerId == pointerId && active.pointerType /= Events.Mouse then
                        let
                            ( Model moved, _ ) =
                                moveTo userView point active m
                        in
                        drop moved

                    else
                        ( Model m, [] )

                Nothing ->
                    ( Model m, [] )

        Cancelled pointerId ->
            case m.drag of
                Just active ->
                    if active.pointerId == pointerId then
                        ( Model
                            { m
                                | drag = Nothing
                                , spring = startSpring defaultTransition m
                                , landing = Just active.key
                            }
                        , []
                        )

                    else
                        ( Model m, [] )

                Nothing ->
                    ( Model m, [] )

        Tick dt ->
            case m.spring of
                Just spring ->
                    let
                        elapsed =
                            spring.elapsed + dt
                    in
                    if elapsed >= spring.transition.duration then
                        ( Model { m | spring = Nothing, landing = Nothing }, [] )

                    else
                        ( Model { m | spring = Just { spring | elapsed = elapsed } }, [] )

                Nothing ->
                    ( Model m, [] )


startDrag : View state msg -> StartInfo state -> ModelData state -> ( Model state, List (Event state) )
startDrag userView info m =
    let
        startCtx =
            Context { toMsg = Nothing, dragged = Just info.key }

        frame =
            Layered.locateFrame info.key (userView startCtx m.state)
                |> Maybe.withDefault { matrix = Internal.identityMat, origin = ( 0, 0 ) }

        ( localX, localY ) =
            info.pointer.local

        -- The grabbed point, relative to the element's origin, so it can be
        -- found again in states where the element has moved.
        anchor =
            ( localX - Tuple.first frame.origin, localY - Tuple.second frame.origin )

        rootFromScene =
            Internal.composeMat frame.matrix (Internal.invertMat info.accum)

        pointer =
            Internal.applyPoint frame.matrix info.pointer.local

        spec =
            info.makeSpec ()

        env =
            runEnv userView info.key anchor m.state

        ( result, memory ) =
            run env pointer spec MNone

        active =
            { key = info.key
            , anchor = anchor
            , spec = spec
            , memory = memory
            , startState = m.state
            , rootFromScene = rootFromScene
            , frame = info.pointer.frame
            , pointerId = info.pointer.pointerId
            , pointerType = info.pointer.pointerType
            , result = result
            }
    in
    ( Model { m | drag = Just active, spring = Nothing, landing = Nothing }
    , [ Started info.key ]
    )


moveTo : View state msg -> Point -> Active state -> ModelData state -> ( Model state, List (Event state) )
moveTo userView pointer active m =
    let
        env =
            runEnv userView active.key active.anchor active.startState

        ( firstResult, firstMemory ) =
            run env pointer active.spec active.memory

        -- Chaining: the drag has arrived in a new state, so carry on from
        -- there as if it had been dropped and grabbed again.
        ( continued, result, memory ) =
            case firstResult.chainNext of
                Just next ->
                    if firstResult.dropState /= active.startState then
                        let
                            newStart =
                                firstResult.dropState

                            newSpec =
                                next newStart

                            ( chainedResult, chainedMemory ) =
                                run (runEnv userView active.key active.anchor newStart) pointer newSpec MNone
                        in
                        ( { active | startState = newStart, spec = newSpec }, chainedResult, chainedMemory )

                    else
                        ( active, firstResult, firstMemory )

                Nothing ->
                    ( active, firstResult, firstMemory )

        spring =
            if result.path /= active.result.path && continued.startState == active.startState then
                case result.branchTransition of
                    Just t ->
                        startSpring t m

                    Nothing ->
                        startSpring defaultTransition m

            else
                m.spring
    in
    ( Model { m | drag = Just { continued | result = result, memory = memory }, spring = spring }
    , [ Moved result.dropState ]
    )


drop : ModelData state -> ( Model state, List (Event state) )
drop m =
    case m.drag of
        Just active ->
            let
                dropTransition =
                    Maybe.withDefault defaultTransition active.result.dropTransition

                dropState =
                    active.result.dropState
            in
            ( Model
                { m
                    | state = dropState
                    , drag = Nothing
                    , spring = startSpring dropTransition m
                    , landing = Just active.key
                }
            , [ Dropped dropState ]
            )

        Nothing ->
            ( Model m, [] )


{-| Snapshot what is on screen now as the starting point of a transition.
-}
startSpring : TransitionData -> ModelData state -> Maybe (Spring state)
startSpring data m =
    if data.duration <= 0 then
        Nothing

    else
        Just { from = limitDepth 4 (displayPlan m), elapsed = 0, transition = data }


{-| The plan for what is on screen right now.
-}
displayPlan : ModelData state -> Plan state
displayPlan m =
    let
        target =
            case m.drag of
                Just active ->
                    active.result.preview

                Nothing ->
                    PState m.state
    in
    case m.spring of
        Just spring ->
            let
                eased =
                    springProgress spring
            in
            PBlend [ ( spring.from, 1 - eased ), ( target, eased ) ]

        Nothing ->
            target


springProgress : Spring state -> Float
springProgress spring =
    spring.transition.ease (clamp 0 1 (spring.elapsed / spring.transition.duration))


{-| Transitions that start while others are still running nest their
snapshots. Past a few levels the oldest ones are hardly visible, so they are
dropped to keep drawing cheap.
-}
limitDepth : Int -> Plan state -> Plan state
limitDepth depth plan =
    -- IGNORE TCO: tree recursion over plans cannot be tail-call optimized
    case plan of
        PBlend items ->
            if depth <= 0 then
                items
                    |> List.foldl
                        (\( p, w ) best ->
                            case best of
                                Just ( _, bw ) ->
                                    if w > bw then
                                        Just ( p, w )

                                    else
                                        best

                                Nothing ->
                                    Just ( p, w )
                        )
                        Nothing
                    |> Maybe.map (Tuple.first >> limitDepth 0)
                    |> Maybe.withDefault plan

            else
                PBlend (List.map (\( p, w ) -> ( limitDepth (depth - 1) p, w )) items)

        PFloat data ->
            PFloat { data | inner = limitDepth depth data.inner }

        POverlay overlay inner ->
            POverlay overlay (limitDepth depth inner)

        PState _ ->
            plan


{-| Follow the pointer while dragging, and run animations.
-}
subscriptions : Model state -> Sub (Msg state)
subscriptions (Model m) =
    Sub.batch
        [ case m.drag of
            Just active ->
                if active.pointerType == Events.Mouse then
                    Events.whileDragging active.frame { onMove = MovedScene, onEnd = EndedScene }

                else
                    Sub.none

            Nothing ->
                Sub.none
        , case m.spring of
            Just _ ->
                Browser.Events.onAnimationFrameDelta Tick

            Nothing ->
                Sub.none
        ]


{-| Draw the current state, or the drag in progress. The result is an
ordinary drawing to place anywhere inside an `Evg.svg`, including inside
transformed groups.
-}
view : (Msg state -> msg) -> View state msg -> Model state -> Evg msg
view toMsg userView (Model m) =
    let
        draggedKey =
            case m.drag of
                Just active ->
                    Just active.key

                Nothing ->
                    m.landing

        ctx =
            Context { toMsg = Just toMsg, dragged = Maybe.map .key m.drag }

        env =
            { render = \s -> Layered.fromEvg draggedKey (userView ctx s)
            , key = draggedKey
            , anchor = Maybe.map .anchor m.drag |> Maybe.withDefault ( 0, 0 )
            , startState = Maybe.map .startState m.drag |> Maybe.withDefault m.state
            }

        layered =
            evalPlan env (displayPlan m)

        noSelect =
            Svg.Attributes.style "user-select: none; -webkit-user-select: none"
    in
    case m.drag of
        Just active ->
            let
                -- Touch and pen keep reporting to the element they pressed,
                -- and those reports bubble up to here. A transparent sheet on
                -- top catches the pointer if that element is replaced.
                captureSheet =
                    Evg.rect
                        [ Evg.fillStr "transparent"
                        , Events.pointerEvents Events.All
                        , Events.cursor Events.Grabbing
                        ]
                        { x = -100000, y = -100000, width = 200000, height = 200000 }

                handlers =
                    if active.pointerType == Events.Mouse then
                        []

                    else
                        List.filterMap eventBuilder
                            [ Events.onPointerMoveWith (\p -> toMsg (MovedLocal p.pointerId p.local))
                            , Events.onPointerUpWith (\p -> toMsg (EndedLocal p.pointerId p.local))
                            , Events.onPointerCancel (toMsg (Cancelled active.pointerId))
                            ]
            in
            Layered.toEvg [ noSelect ] handlers (Layered.addOverlay -1 captureSheet layered)

        Nothing ->
            Layered.toEvg [ noSelect ] [] layered


eventBuilder : Evg.Attribute a msg -> Maybe (Mat23 -> VirtualDom.Attribute msg)
eventBuilder attr =
    case attr of
        EventAttr _ build ->
            Just build

        _ ->
            Nothing



-- SPECS


{-| What dragging an element does. Build one with the functions below and
return it from the function you give [`onDrag`](#onDrag).
-}
type Spec state
    = Fixed state
    | Between BetweenOptions (List (Spec state))
    | Closest ClosestOptions (List (Spec state))
    | Vary (List Float) (List Float -> state)
    | VaryWith (Solver -> List Float) (List Float) (List Float -> state)
    | Constrain (state -> Constraint) (Spec state)
    | Pin (state -> List Float) (Spec state)
    | WhenFar { gapIn : Float, gapOut : Float } (Spec state) (Spec state)
    | Floating FloatingOptions (Spec state)
    | SnapRadius Float (Spec state)
    | Chain (state -> Spec state) (Spec state)
    | OnDrop (state -> state) (Spec state)
    | During (state -> state) (Spec state)
    | DropTransition TransitionData (Spec state)
    | BranchTransition TransitionData (Spec state)
    | Overlay (Evg Never) (Spec state)


{-| Always show this one state, and drop into it. On its own that isn't much
of a drag, but it is a building block: [`between`](#between) and
[`closest`](#closest) are usually given fixed states, and
[`whenFar`](#whenFar) often falls back to one.

    -- Dragging doesn't change anything:
    Drag.fixed state

-}
fixed : state -> Spec state
fixed =
    Fixed


{-| Blend smoothly between states as the pointer moves between the positions
the dragged element has in each. On release, drop into the state whose
position is nearest the pointer.

    -- A three-way switch:
    Drag.between [ { mode = Low }, { mode = Mid }, { mode = High } ]

Everything in the drawing blends, not just the dragged element: positions,
sizes, colours, path shapes. With two states the element moves along the line
between them; with more it can move anywhere in the area they span, and
dragging outside that area slides along its edge.

-}
between : List state -> Spec state
between states =
    Between defaultBetween (List.map Fixed states)


{-| Like [`between`](#between), but blending between the previews of other
specs, which may themselves move as you drag.
-}
betweenSpecs : List (Spec state) -> Spec state
betweenSpecs =
    Between defaultBetween


{-| Options for [`betweenWith`](#betweenWith).

  - `interpolation`: how the pointer position turns into blend amounts. See
    [`Interpolation`](#Interpolation).
  - `sharpness`: 1 gives an even blend. Higher values pull towards the nearest
    state, like a magnet, approaching [`closest`](#closest) as they grow.

-}
type alias BetweenOptions =
    { interpolation : Interpolation
    , sharpness : Float
    }


{-| How [`between`](#between) weighs its states when there are three or more
that don't lie in a line.

  - `Barycentric`: the positions are joined into triangles and the pointer
    blends the three corners of the triangle it is in. Simple and
    predictable, but the blend changes direction abruptly when crossing from
    one triangle to the next.
  - `NaturalNeighbor`: blends every nearby state by how much of the
    neighbourhood the pointer "steals" from it. Smooth everywhere.

-}
type Interpolation
    = Barycentric
    | NaturalNeighbor


defaultBetween : BetweenOptions
defaultBetween =
    { interpolation = Barycentric, sharpness = 1 }


{-| [`betweenSpecs`](#betweenSpecs) with options.

    Drag.betweenWith { interpolation = Drag.NaturalNeighbor, sharpness = 1 }
        (List.map Drag.fixed corners)

-}
betweenWith : BetweenOptions -> List (Spec state) -> Spec state
betweenWith =
    Between


{-| Jump to whichever state puts the dragged element nearest the pointer.
Unlike [`between`](#between) there is no blending: the drawing snaps from one
state to the next (with a short animation).

    -- Reorder a list by dragging an item to another slot:
    Drag.closest
        (List.map (\slot -> { items = moveItem index slot s.items })
            (List.range 0 (List.length s.items - 1))
        )

![A list being reordered with closest](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/drag-closest.svg)

Dragging the top row down: as the pointer passes each row, the whole list
jumps to the order with the grabbed row in that place.

On its own the dragged element snaps too, which can feel jerky; add
[`withFloating`](#withFloating) to let it follow the pointer while the rest
rearranges.

-}
closest : List state -> Spec state
closest states =
    Closest defaultClosest (List.map Fixed states)


{-| Like [`closest`](#closest), but choosing between other specs. Each frame
the one whose dragged element gets nearest the pointer is shown.

    -- Slide along a track, or switch to another track:
    Drag.closestSpecs
        (List.map (\track -> Drag.vary s.x (\x -> { s | track = track, x = x })) tracks)

-}
closestSpecs : List (Spec state) -> Spec state
closestSpecs =
    Closest defaultClosest


{-| Options for [`closestWith`](#closestWith).

  - `stickiness`: stay with the current option until another gets this many
    units nearer. Stops flickering between two options that are about as
    good.
  - `lockPast`: once the current option has carried the dragged element this
    far from where it started, stick with it until it comes back. Useful when
    every option starts from the current state, so they all look equally
    good at first.

-}
type alias ClosestOptions =
    { stickiness : Float
    , lockPast : Maybe Float
    }


defaultClosest : ClosestOptions
defaultClosest =
    { stickiness = 0, lockPast = Nothing }


{-| [`closestSpecs`](#closestSpecs) with options.
-}
closestWith : ClosestOptions -> List (Spec state) -> Spec state
closestWith =
    Closest


{-| Vary a number continuously so that the dragged element stays under the
pointer. Give the starting value and a function building the state from a
value:

    -- A slider:
    Drag.vary s.value (\v -> { s | value = v })
        |> Drag.constrain (\st -> Drag.inOrder [ 0, st.value, 100 ])

    -- A dial: vary the angle, and the knob goes round
    Drag.vary s.angle (\a -> { s | angle = a })

![A two-jointed arm following the pointer](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/drag-vary.svg)

Above, a two-jointed arm whose hand is dragged with
`Drag.vary2 ( shoulder, elbow ) ...`: in every frame both angles are chosen
so that the hand sits under the pointer.

You never say how pointer movement maps to the value. The library finds the
value by trying values and looking where the element ends up, so it works no
matter how the value is drawn: as a position, an angle, a point along a
curve, or through several nested transforms.

-}
vary : Float -> (Float -> state) -> Spec state
vary initial toState =
    Vary [ initial ]
        (\params ->
            case params of
                v :: _ ->
                    toState v

                [] ->
                    toState initial
        )


{-| Vary two numbers, for example a point's x and y:

    Drag.vary2 ( p.x, p.y ) (\x y -> { s | point = { x = x, y = y } })

-}
vary2 : ( Float, Float ) -> (Float -> Float -> state) -> Spec state
vary2 ( a, b ) toState =
    Vary [ a, b ]
        (\params ->
            case params of
                x :: y :: _ ->
                    toState x y

                _ ->
                    toState a b
        )


{-| Vary any number of numbers. The function receives them in the same order.
-}
varyN : List Float -> (List Float -> state) -> Spec state
varyN =
    Vary


{-| What a [`varyWith`](#varyWith) solver is told on every pointer move: where the
pointer is, where the grabbed point was when the drag began (`grab`), the
values then (`start`) and the values it returned last time (`previous`, the
same as `start` on the first move).
-}
type alias Solver =
    { pointer : ( Float, Float )
    , grab : ( Float, Float )
    , start : List Float
    , previous : List Float
    }


{-| [`varyN`](#varyN) with your own solver: given the pointer, return the values
that put the dragged element under it. Use it when you can compute that better
than trying values and re-rendering, for example from exact derivatives of a
model of the drawing.

The solver sees the pointer and the grab point in the drawing's coordinates. It
is called once per pointer move, and it is responsible for any limits:
[`constrain`](#constrain) and [`pin`](#pin) do not apply to it.

(Added to the `declarative-dragging` branch for `spikes/grad-drag`; see
`vendor/evg/PATCH.md`.)

-}
varyWith : (Solver -> List Float) -> List Float -> (List Float -> state) -> Spec state
varyWith =
    VaryWith


{-| A condition on a state for [`constrain`](#constrain).
-}
type Constraint
    = Constraint (List Float)


{-| Keep varied values within limits. The function looks at a candidate state
and says what must hold; applies to every [`vary`](#vary) inside the spec.

    Drag.vary2 ( s.x, s.y ) (\x y -> { s | x = x, y = y })
        |> Drag.constrain
            (\st ->
                Drag.all
                    [ Drag.inOrder [ 0, st.x, 300 ]
                    , Drag.inOrder [ 0, st.y, 200 ]
                    ]
            )

When the pointer goes past a limit, the element stops at the limit and slides
along it.

-}
constrain : (state -> Constraint) -> Spec state -> Spec state
constrain =
    Constrain


{-| The first number must be at most the second.
-}
lessThan : Float -> Float -> Constraint
lessThan a b =
    Constraint [ a - b ]


{-| The first number must be at least the second.
-}
moreThan : Float -> Float -> Constraint
moreThan a b =
    Constraint [ b - a ]


{-| The two numbers must be equal.
-}
equal : Float -> Float -> Constraint
equal a b =
    Constraint [ a - b, b - a ]


{-| The numbers must not decrease: `inOrder [ 0, x, 100 ]` keeps `x` between 0
and 100.
-}
inOrder : List Float -> Constraint
inOrder nums =
    Constraint (List.map2 (-) nums (List.drop 1 nums))


{-| All of these must hold.
-}
all : List Constraint -> Constraint
all constraints =
    Constraint (List.concatMap (\(Constraint gs) -> gs) constraints)


{-| Keep some values exactly as they were when the drag started, while
[`vary`](#vary) changes others. For instance, vary both ends of a line while
keeping its midpoint pinned, and dragging an end rotates the line about its
middle.
-}
pin : (state -> List Float) -> Spec state -> Spec state
pin =
    Pin


{-| Options for [`withFloatingWith`](#withFloatingWith).

  - `ghost`: leave a faded copy of the element, at this opacity, where it
    would land.
  - `tether`: limit how far the element strays from where it would land. Given
    the distance from there to the pointer, return how far to actually go.

-}
type alias FloatingOptions =
    { ghost : Maybe Float
    , tether : Maybe (Float -> Float)
    }


{-| Let the dragged element follow the pointer freely, while the rest of the
drawing shows the state it would drop into. On release it slides into place.

    Drag.closest reorderings
        |> Drag.withFloating

This is usually what you want for rearranging things: the item feels picked
up, and the others make room for it.

![A list being reordered with closest and withFloating](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/drag-floating.svg)

The same drag as in [`closest`](#closest), with floating: the grabbed row stays
under the pointer the whole time, and the other rows slide out of its way.

-}
withFloating : Spec state -> Spec state
withFloating =
    Floating { ghost = Nothing, tether = Nothing }


{-| [`withFloating`](#withFloating) with options.

    Drag.closest reorderings
        |> Drag.withFloatingWith { ghost = Just 0.3, tether = Nothing }

-}
withFloatingWith : FloatingOptions -> Spec state -> Spec state
withFloatingWith =
    Floating


{-| Switch to another spec when the pointer is far (more than 50 units) from
anything this spec can offer. The second argument is the usual spec, the
first the fallback:

    -- Snap to a slot when close to one, otherwise stay as you were:
    Drag.closest slots
        |> Drag.whenFar (Drag.fixed state)
        |> Drag.withFloating

-}
whenFar : Spec state -> Spec state -> Spec state
whenFar =
    whenFarWith { gapIn = 50, gapOut = 50 }


{-| [`whenFar`](#whenFar) with custom distances: switch to the fallback when
the gap exceeds `gapOut`, and back when it drops below `gapIn`. A smaller
`gapIn` stops the drag flickering at the boundary.
-}
whenFarWith : { gapIn : Float, gapOut : Float } -> Spec state -> Spec state -> Spec state
whenFarWith gaps background foreground =
    WhenFar { gapIn = min gaps.gapIn gaps.gapOut, gapOut = gaps.gapOut } background foreground


{-| Snap the preview to the drop state once the dragged element is within this
distance of where it would land. Combined with [`between`](#between) this
gives a magnetic feel. It changes only what is shown, not what is dropped.
-}
withSnapRadius : Float -> Spec state -> Spec state
withSnapRadius =
    SnapRadius


{-| Keep going after arriving somewhere. Whenever the preview has snapped onto
its drop state (so this needs [`withSnapRadius`](#withSnapRadius) inside it),
the drag carries on from that state, as if it had been dropped and grabbed
again, with the spec the function gives for it. One gesture can then make
several moves in a row.

    -- Swap a tile with a neighbour, then the next neighbour, and so on,
    -- without letting go:
    moves state
        |> Drag.withSnapRadius 1
        |> Drag.chain moves

States are compared with `==` to tell whether the drag has arrived somewhere
new, so they mustn't contain functions.

-}
chain : (state -> Spec state) -> Spec state -> Spec state
chain =
    Chain


{-| Change the state that is dropped into. The preview is unaffected.

    -- Whatever happens during the drag, a release resets the counter:
    spec |> Drag.onDrop (\s -> { s | moves = 0 })

-}
onDrop : (state -> state) -> Spec state -> Spec state
onDrop =
    OnDrop


{-| Change the state on every frame, and show the changed state. Use it to
keep derived values up to date while dragging, e.g. to re-run a layout.
-}
during : (state -> state) -> Spec state -> Spec state
during =
    During


{-| Draw something on top while this spec is in charge of the drag, in the
drawing's own coordinates. It disappears on release. Good for marking drop
targets.

    Drag.fixed target
        |> Drag.whenFar (Drag.fixed state)
        |> Drag.withOverlay (Evg.circle [ Evg.strokeStr "gray", Evg.fillStr "none" ] { r = 6, center = targetPosition })

-}
withOverlay : Evg Never -> Spec state -> Spec state
withOverlay =
    Overlay



-- TRANSITIONS


type alias TransitionData =
    { duration : Float
    , ease : Float -> Float
    }


makeTransition : Float -> Animate.Easing -> TransitionData
makeTransition seconds easing =
    { duration = seconds * 1000, ease = Internal.easingFunction easing }


defaultTransition : TransitionData
defaultTransition =
    makeTransition 0.2 Animate.easeOut


{-| How to animate the drop: a duration in seconds and an easing.

    Drag.between [ { on = False }, { on = True } ]
        -- overshoot a little, then settle:
        |> Drag.withDropTransition 0.4 (Animate.cubicBezier 0.34 1.56 0.64 1)

-}
withDropTransition : Float -> Animate.Easing -> Spec state -> Spec state
withDropTransition seconds easing =
    DropTransition (makeTransition seconds easing)


{-| How to animate switching between options during a drag: between the
options of a [`closest`](#closest), between the two sides of a
[`whenFar`](#whenFar), or snapping in and out of a
[`withSnapRadius`](#withSnapRadius).
-}
withBranchTransition : Float -> Animate.Easing -> Spec state -> Spec state
withBranchTransition seconds easing =
    BranchTransition (makeTransition seconds easing)



-- RUNNING SPECS


{-| What a spec produces each frame.

  - `preview`: what to draw.
  - `dropState`: what releasing would drop into.
  - `gap`: how far the dragged element is from the pointer; `closest` and
    `whenFar` compare these.
  - `grabPos`: where the grabbed point of the dragged element is.
  - `path`: which branches of the spec tree are active; a change starts a
    branch transition.

-}
type alias Res state =
    { preview : Plan state
    , dropState : state
    , gap : Float
    , grabPos : Maybe Point
    , path : List String
    , dropTransition : Maybe TransitionData
    , branchTransition : Maybe TransitionData
    , snapped : Bool
    , chainNext : Maybe (state -> Spec state)
    }


{-| A description of a drawing in terms of states, kept as data so the model
can store it and the view can draw it.
-}
type Plan state
    = PState state
    | PBlend (List ( Plan state, Float ))
    | PFloat { inner : Plan state, target : Point, ghost : Maybe Float }
    | POverlay (Evg Never) (Plan state)


{-| What each part of a spec remembers between frames.
-}
type Memory
    = MNone
    | MFixed (Maybe Point)
    | MChildren (List Memory)
    | MClosest ClosestMemory (List Memory)
    | MWhenFar Bool Memory Memory
    | MVary (List Float) (List Float)
    | MVaryWith Point (List Float) (List Float)


type alias ClosestMemory =
    { lastBest : Maybe Int
    , locked : Maybe Int
    , home : Maybe Point
    }


type alias RunEnv state =
    { locate : state -> Maybe Point
    , startState : state
    , constraints : List (state -> Constraint)
    , pins : List (state -> List Float)
    }


runEnv : View state msg -> String -> Point -> state -> RunEnv state
runEnv userView k anchor startState =
    let
        ctx =
            Context { toMsg = Nothing, dragged = Just k }
    in
    { locate = \s -> Layered.locate k anchor (userView ctx s)
    , startState = startState
    , constraints = []
    , pins = []
    }


simple : Plan state -> state -> Float -> Maybe Point -> Res state
simple plan s gap grabPos =
    { preview = plan
    , dropState = s
    , gap = gap
    , grabPos = grabPos
    , path = []
    , dropTransition = Nothing
    , branchTransition = Nothing
    , snapped = False
    , chainNext = Nothing
    }


gapTo : Point -> Maybe Point -> Float
gapTo pointer maybePos =
    case maybePos of
        Just p ->
            distance pointer p

        Nothing ->
            1 / 0


distance : Point -> Point -> Float
distance ( ax, ay ) ( bx, by ) =
    sqrt ((ax - bx) ^ 2 + (ay - by) ^ 2)


run : RunEnv state -> Point -> Spec state -> Memory -> ( Res state, Memory )
run env pointer spec memory =
    -- IGNORE TCO: recursion over the spec tree cannot be tail-call optimized
    case spec of
        Fixed s ->
            let
                pos =
                    case memory of
                        MFixed cached ->
                            cached

                        _ ->
                            env.locate s
            in
            ( simple (PState s) s (gapTo pointer pos) pos, MFixed pos )

        Between options specs ->
            runBetween env pointer options specs memory

        Closest options specs ->
            runClosest env pointer options specs memory

        Vary initial toState ->
            runVary env pointer initial toState memory

        VaryWith solve initial toState ->
            runVaryWith env pointer solve initial toState memory

        Constrain constraint inner ->
            run { env | constraints = constraint :: env.constraints } pointer inner memory

        Pin reader inner ->
            run { env | pins = reader :: env.pins } pointer inner memory

        WhenFar gaps background foreground ->
            let
                ( inForeground, fgMemory, bgMemory ) =
                    case memory of
                        MWhenFar inFg fgM bgM ->
                            ( inFg, fgM, bgM )

                        _ ->
                            ( True, MNone, MNone )

                ( fgResult, fgMemory2 ) =
                    run env pointer foreground fgMemory

                threshold =
                    if inForeground then
                        gaps.gapOut

                    else
                        gaps.gapIn
            in
            if fgResult.gap <= threshold then
                ( { fgResult | path = "fg" :: fgResult.path }, MWhenFar True fgMemory2 bgMemory )

            else
                let
                    ( bgResult, bgMemory2 ) =
                        run env pointer background bgMemory
                in
                ( { bgResult | path = "bg" :: bgResult.path }, MWhenFar False fgMemory2 bgMemory2 )

        Floating options inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory

                target =
                    case ( options.tether, result.grabPos ) of
                        ( Just tether, Just ( ex, ey ) ) ->
                            let
                                ( px, py ) =
                                    pointer

                                len =
                                    distance pointer ( ex, ey )
                            in
                            if len < 1.0e-6 then
                                pointer

                            else
                                let
                                    k =
                                        tether len / len
                                in
                                ( ex + (px - ex) * k, ey + (py - ey) * k )

                        _ ->
                            pointer
            in
            ( { result
                | preview = PFloat { inner = result.preview, target = target, ghost = options.ghost }
                , grabPos = Just target
                , dropTransition = Nothing
                , branchTransition = Nothing
              }
            , innerMemory
            )

        SnapRadius radius inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory

                dropPos =
                    env.locate result.dropState

                snapped =
                    case ( dropPos, result.grabPos ) of
                        ( Just dp, Just gp ) ->
                            distance dp gp <= radius

                        _ ->
                            False
            in
            ( if snapped then
                { result
                    | preview = PState result.dropState
                    , grabPos = dropPos
                    , path = "snapped" :: result.path
                    , snapped = True
                }

              else
                { result | path = "free" :: result.path }
            , innerMemory
            )

        Chain next inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory
            in
            ( if result.snapped then
                { result | chainNext = Just next }

              else
                result
            , innerMemory
            )

        OnDrop fn inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory
            in
            ( { result | dropState = fn result.dropState }, innerMemory )

        During fn inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory

                transformed =
                    fn result.dropState

                pos =
                    env.locate transformed
            in
            ( { result
                | preview = PState transformed
                , dropState = transformed
                , gap = gapTo pointer pos
                , grabPos = pos
              }
            , innerMemory
            )

        DropTransition data inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory
            in
            ( { result | dropTransition = Just data }, innerMemory )

        BranchTransition data inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory
            in
            ( { result | branchTransition = Just data }, innerMemory )

        Overlay overlay inner ->
            let
                ( result, innerMemory ) =
                    run env pointer inner memory
            in
            ( { result | preview = POverlay overlay result.preview }, innerMemory )


childMemories : Int -> Memory -> List Memory
childMemories n memory =
    case memory of
        MChildren ms ->
            ms

        MClosest _ ms ->
            ms

        _ ->
            List.repeat n MNone


runChildren : RunEnv state -> Point -> List (Spec state) -> List Memory -> List ( Res state, Memory )
runChildren env pointer specs memories =
    List.map2 (\spec mem -> run env pointer spec mem) specs memories


runBetween : RunEnv state -> Point -> BetweenOptions -> List (Spec state) -> Memory -> ( Res state, Memory )
runBetween env pointer options specs memory =
    let
        ran =
            runChildren env pointer specs (childMemories (List.length specs) memory)

        results =
            List.map Tuple.first ran

        newMemory =
            MChildren (List.map Tuple.second ran)

        -- Options whose drawing lacks the dragged element can't be placed,
        -- so they take no part in the blend.
        placed =
            results
                |> List.filterMap (\r -> Maybe.map (\p -> ( r, p )) r.grabPos)

        method =
            case options.interpolation of
                Barycentric ->
                    Interpolation.Barycentric

                NaturalNeighbor ->
                    Interpolation.NaturalNeighbor

        interpolated =
            Interpolation.weights method (List.map Tuple.second placed) pointer

        sharpened =
            if options.sharpness == 1 then
                interpolated.weights

            else
                let
                    raised =
                        List.map (\( i, w ) -> ( i, w ^ options.sharpness )) interpolated.weights

                    total =
                        List.sum (List.map Tuple.second raised)
                in
                if total > 0 then
                    List.map (\( i, w ) -> ( i, w / total )) raised

                else
                    interpolated.weights

        weighted =
            List.filterMap
                (\( i, w ) ->
                    placed
                        |> List.drop i
                        |> List.head
                        |> Maybe.map (\( r, p ) -> ( r, p, w ))
                )
                sharpened

        nearest =
            placed
                |> List.sortBy (\( _, p ) -> distance p pointer)
                |> List.head
    in
    case ( weighted, nearest ) of
        ( _ :: _, Just ( nearestResult, _ ) ) ->
            ( { preview = PBlend (List.map (\( r, _, w ) -> ( r.preview, w )) weighted)
              , dropState = nearestResult.dropState
              , gap = interpolated.gap
              , grabPos = Just (List.foldl (\( _, ( x, y ), w ) ( ax, ay ) -> ( ax + x * w, ay + y * w )) ( 0, 0 ) weighted)
              , path = []
              , dropTransition = Nothing
              , branchTransition = Nothing
              , snapped = False
              , chainNext = Nothing
              }
            , newMemory
            )

        _ ->
            ( simple (PState env.startState) env.startState (1 / 0) Nothing, newMemory )


runClosest : RunEnv state -> Point -> ClosestOptions -> List (Spec state) -> Memory -> ( Res state, Memory )
runClosest env pointer options specs memory =
    let
        mem =
            case memory of
                MClosest m _ ->
                    m

                _ ->
                    { lastBest = Nothing
                    , locked = Nothing
                    , home =
                        case options.lockPast of
                            Just _ ->
                                env.locate env.startState

                            Nothing ->
                                Nothing
                    }

        memories =
            childMemories (List.length specs) memory

        isPastLock result =
            case ( options.lockPast, mem.home ) of
                ( Just limit, Just home ) ->
                    case result.grabPos of
                        Just p ->
                            distance p home > limit

                        Nothing ->
                            True

                _ ->
                    False

        runAt i =
            Maybe.map2 (\spec m -> run env pointer spec m)
                (List.head (List.drop i specs))
                (List.head (List.drop i memories))

        replaceAt i newMem =
            List.indexedMap
                (\j m ->
                    if j == i then
                        newMem

                    else
                        m
                )
                memories

        finish i result locked newMemories =
            ( { result | path = String.fromInt i :: result.path }
            , MClosest { mem | lastBest = Just i, locked = locked } newMemories
            )

        chooseFreely () =
            let
                ran =
                    runChildren env pointer specs memories

                scored =
                    List.indexedMap
                        (\i ( r, _ ) ->
                            ( i
                            , r.gap
                                - (if Just i == mem.lastBest then
                                    options.stickiness

                                   else
                                    0
                                  )
                            )
                        )
                        ran

                best =
                    scored
                        |> List.sortBy Tuple.second
                        |> List.head
                        |> Maybe.map Tuple.first
            in
            case best of
                Just i ->
                    case List.head (List.drop i ran) of
                        Just ( r, _ ) ->
                            finish i
                                r
                                (if isPastLock r then
                                    Just i

                                 else
                                    Nothing
                                )
                                (List.map Tuple.second ran)

                        Nothing ->
                            empty

                Nothing ->
                    empty

        empty =
            ( { preview = PState env.startState
              , dropState = env.startState
              , gap = 1 / 0
              , grabPos = Nothing
              , path = [ "none" ]
              , dropTransition = Nothing
              , branchTransition = Nothing
              , snapped = False
              , chainNext = Nothing
              }
            , MClosest mem memories
            )
    in
    case mem.locked of
        Just i ->
            case runAt i of
                Just ( r, m ) ->
                    if isPastLock r then
                        finish i r (Just i) (replaceAt i m)

                    else
                        chooseFreely ()

                Nothing ->
                    chooseFreely ()

        Nothing ->
            chooseFreely ()


{-| How strongly constraints push back. Large enough that a violation of a
thousandth of a unit costs as much as a unit of distance from the pointer.
-}
penaltyWeight : Float
penaltyWeight =
    1000


runVary : RunEnv state -> Point -> List Float -> (List Float -> state) -> Memory -> ( Res state, Memory )
runVary env pointer initial toState memory =
    let
        ( start, pinTargets ) =
            case memory of
                MVary previous targets ->
                    ( previous, targets )

                _ ->
                    ( initial, List.concatMap (\reader -> reader (toState initial)) env.pins )

        ( px, py ) =
            pointer

        residuals candidate =
            let
                candidateState =
                    toState candidate

                ( dx, dy ) =
                    case env.locate candidateState of
                        Just ( x, y ) ->
                            ( x - px, y - py )

                        Nothing ->
                            ( 1.0e6, 1.0e6 )

                violations =
                    List.concatMap
                        (\c ->
                            let
                                (Constraint gs) =
                                    c candidateState
                            in
                            List.map (\g -> penaltyWeight * max 0 g) gs
                        )
                        env.constraints

                pinned =
                    List.map2 (\v target -> penaltyWeight * (v - target)) (List.concatMap (\reader -> reader candidateState) env.pins) pinTargets
            in
            dx :: dy :: violations ++ pinned

        params =
            Optimize.leastSquares { maxIterations = 20 } residuals start

        s =
            toState params

        pos =
            env.locate s
    in
    ( simple (PState s) s (gapTo pointer pos) pos, MVary params pinTargets )



runVaryWith : RunEnv state -> Point -> (Solver -> List Float) -> List Float -> (List Float -> state) -> Memory -> ( Res state, Memory )
runVaryWith env pointer solve initial toState memory =
    let
        ( grab, previous ) =
            case memory of
                MVaryWith g _ prev ->
                    ( g, prev )

                _ ->
                    -- where the grabbed point is in the start state: where the pointer went down
                    ( Maybe.withDefault pointer (env.locate (toState initial)), initial )

        params =
            solve { pointer = pointer, grab = grab, start = initial, previous = previous }

        s =
            toState params

        pos =
            env.locate s
    in
    ( simple (PState s) s (gapTo pointer pos) pos, MVaryWith grab initial params )



-- DRAWING PLANS


type alias ViewEnv state msg =
    { render : state -> Layered msg
    , key : Maybe String
    , anchor : Point
    , startState : state
    }


evalPlan : ViewEnv state msg -> Plan state -> Layered msg
evalPlan env plan =
    -- IGNORE TCO: recursion over the plan tree cannot be tail-call optimized
    case plan of
        PState s ->
            env.render s

        PBlend items ->
            items
                |> List.filter (\( _, w ) -> w > 1.0e-4)
                |> List.map (\( p, w ) -> ( evalPlan env p, w ))
                |> Layered.blendMany

        PFloat { inner, target, ghost } ->
            let
                layered =
                    evalPlan env inner
            in
            case env.key of
                Just k ->
                    case Layered.position k env.anchor layered of
                        Just ( ex, ey ) ->
                            Layered.floatLayer k ( Tuple.first target - ex, Tuple.second target - ey ) ghost layered

                        Nothing ->
                            -- The element isn't in this preview (say, it was
                            -- dragged out of a list), so borrow it from the
                            -- state the drag started in.
                            let
                                start =
                                    env.render env.startState
                            in
                            case Layered.position k env.anchor start of
                                Just ( ex, ey ) ->
                                    Layered.transplant k start layered
                                        |> Layered.floatLayer k ( Tuple.first target - ex, Tuple.second target - ey ) Nothing

                                Nothing ->
                                    layered

                Nothing ->
                    layered

        POverlay overlay inner ->
            Layered.addOverlay (depthOf inner) (Internal.mapEvg never overlay) (evalPlan env inner)


depthOf : Plan state -> Int
depthOf plan =
    -- IGNORE TCO: recursion over the plan tree cannot be tail-call optimized
    case plan of
        POverlay _ inner ->
            1 + depthOf inner

        PFloat { inner } ->
            depthOf inner

        _ ->
            0
