module Evg.Events exposing
    ( onClick, onPointerDown, onPointerUp, onPointerMove
    , onPointerEnter, onPointerLeave, onPointerCancel
    , onClickWith, onPointerDownWith, onPointerUpWith, onPointerMoveWith
    , Pointer, PointerType(..), Button(..), Modifiers
    , onWheel, Wheel
    , Frame, frameToScene, whileDragging
    , touchAction, TouchActionValue(..)
    , pointerEvents, PointerEventsValue(..)
    , cursor, CursorValue(..)
    )

{-| Handle mouse, touch, and pen interactions on shapes.

Event handlers receive coordinates in _your_ coordinate space, not raw screen
pixels. There are three spaces a position can live in, and the library converts
between them for you:

  - **local**: the numbers you used to draw _this_ element. If the shape lives
    inside `Evg.group [ Transform.translate 50 0 ]`, local coordinates already
    have that translation undone. The simple handlers (like `onClick`) give you
    this, so a click at the visual centre of a shape reports the centre in the
    shape's own numbers no matter how it's been moved, scaled, or rotated.
  - **scene**: the root coordinate system of your `Evg.svg`, meaning the same
    numbers you'd use without any transforms. This is the space to do drag
    maths in, because it doesn't move when the thing you're dragging moves.
  - **client**: raw browser pixels, measured from the top-left corner of the
    browser window. An escape hatch, and the currency of window-level drag
    tracking.

When you use no transforms, local and scene are identical, so you can ignore the
distinction until you need it.

    import Evg
    import Evg.Events as Events

    Evg.circle
        [ Evg.fillStr "blue"
        , Events.onClick (\point -> ClickedAt point)
        ]
        { r = 30, center = ( 50, 50 ) }


# Simple handlers

These report a single `( x, y )` position in the element's local coordinate
space. They work for mouse, touch, and pen alike.

@docs onClick, onPointerDown, onPointerUp, onPointerMove
@docs onPointerEnter, onPointerLeave, onPointerCancel


# Detailed handlers

Sometimes a position isn't enough: you also want the input device, which
button was pressed, which keyboard modifiers were held, or the
[`Frame`](#Frame) for window-level drag tracking. These handlers hand you a
[`Pointer`](#Pointer) record with all of that.

@docs onClickWith, onPointerDownWith, onPointerUpWith, onPointerMoveWith
@docs Pointer, PointerType, Button, Modifiers


# Scroll and zoom

@docs onWheel, Wheel


# Dragging beyond the element

A mouse drag that leaves the element stops sending events to it, because the
browser delivers them to whatever is now under the cursor. To keep following
the pointer you listen on the window instead, but a window event can't tell
you where your drawing is. A [`Frame`](#Frame), captured during an ordinary
handler while that information is still available, bridges the gap.

@docs Frame, frameToScene, whileDragging


# Pointer behaviour

@docs touchAction, TouchActionValue
@docs pointerEvents, PointerEventsValue
@docs cursor, CursorValue

-}

import Browser.Events
import Evg
import Evg.Internal as Internal exposing (Attribute(..), Mat23, Supported)
import Json.Decode as Decode exposing (Decoder)
import Svg.Attributes
import VirtualDom



-- RECORDS


{-| Everything known about a pointer event.

  - `local`: position in this element's own coordinate space (see the module
    intro).
  - `scene`: position in the root `Evg.svg` coordinate space.
  - `client`: raw browser pixels, measured from the top-left corner of the
    browser window.
  - `frame`: a snapshot of how to convert client pixels to scene coordinates,
    for use with [`whileDragging`](#whileDragging).
  - `pointerType`: whether this was a mouse, touch, or pen.
  - `pointerId`: a number identifying this pointer, so you can track several
    fingers independently during a multi-touch gesture.
  - `isPrimary`: `True` for the first pointer in a multi-pointer gesture.
  - `button`: which button triggered the event.
  - `modifiers`: which keyboard modifier keys were held.

-}
type alias Pointer =
    { local : ( Float, Float )
    , scene : ( Float, Float )
    , client : ( Float, Float )
    , frame : Frame
    , pointerType : PointerType
    , pointerId : Int
    , isPrimary : Bool
    , button : Button
    , modifiers : Modifiers
    }


{-| The kind of device that produced a pointer event.
-}
type PointerType
    = Mouse
    | Touch
    | Pen


{-| Which button was pressed. For touch and pen this is normally `Main`.
-}
type Button
    = Main
    | Middle
    | Secondary
    | Back
    | Forward
    | NoButton


{-| Which modifier keys were held during the event.
-}
type alias Modifiers =
    { shift : Bool
    , ctrl : Bool
    , alt : Bool
    , meta : Bool
    }


{-| A mouse-wheel or trackpad scroll event.

  - `local` / `scene`: where the pointer was, in the two coordinate spaces.
  - `delta`: how far it scrolled, normalised to pixels (positive is
    down/right).
  - `pinch`: `True` when this is a trackpad pinch-to-zoom rather than a plain
    scroll. Browsers report pinches as a scroll with the Ctrl key implicitly
    held, which is what this detects.
  - `frame`: as on [`Pointer`](#Pointer).
  - `modifiers`: modifier keys held. Note `ctrl` reads `True` during a
    trackpad pinch even if the physical key isn't down; use `pinch` to tell
    them apart.

-}
type alias Wheel =
    { local : ( Float, Float )
    , scene : ( Float, Float )
    , delta : ( Float, Float )
    , pinch : Bool
    , frame : Frame
    , modifiers : Modifiers
    }


{-| A snapshot of the conversion from client pixels to scene coordinates,
captured at the moment of a pointer event. Pass it to
[`whileDragging`](#whileDragging) to convert the window-level events that follow.

You get one on every [`Pointer`](#Pointer) and [`Wheel`](#Wheel) record; store it
in your model when a drag starts.

-}
type Frame
    = Frame Mat23



-- SIMPLE HANDLERS


{-| Fires when the element is clicked. Reports the click position in the
element's local coordinate space.
-}
onClick : (( Float, Float ) -> msg) -> Attribute { a | events : Supported } msg
onClick toMsg =
    simple "click" toMsg


{-| Fires when a pointer (mouse button, finger, or pen) is pressed on the
element. This is where a drag or gesture usually begins.

For touch and pen the browser keeps sending `onPointerMove`/`onPointerUp` to
this element even if the pointer leaves it (browsers call this "pointer
capture": the element that received the press keeps receiving the follow-up
events). So touch and pen gestures work without any extra setup. Mouse drags
need [`whileDragging`](#whileDragging) to follow the cursor off the element.
Pair this with [`touchAction`](#touchAction) `None` so the browser doesn't
treat a touch-drag as a scroll.

-}
onPointerDown : (( Float, Float ) -> msg) -> Attribute { a | events : Supported } msg
onPointerDown toMsg =
    simple "pointerdown" toMsg


{-| Fires when a pressed pointer is released over the element.
-}
onPointerUp : (( Float, Float ) -> msg) -> Attribute { a | events : Supported } msg
onPointerUp toMsg =
    simple "pointerup" toMsg


{-| Fires continuously as a pointer moves over the element. Use sparingly,
since it generates many messages.
-}
onPointerMove : (( Float, Float ) -> msg) -> Attribute { a | events : Supported } msg
onPointerMove toMsg =
    simple "pointermove" toMsg


{-| Fires once when a pointer enters the element.
-}
onPointerEnter : msg -> Attribute { a | events : Supported } msg
onPointerEnter msg =
    EventAttr (eventHash "pointerenter") (\_ -> VirtualDom.on "pointerenter" (VirtualDom.Normal (Decode.succeed msg)))


{-| Fires once when a pointer leaves the element.
-}
onPointerLeave : msg -> Attribute { a | events : Supported } msg
onPointerLeave msg =
    EventAttr (eventHash "pointerleave") (\_ -> VirtualDom.on "pointerleave" (VirtualDom.Normal (Decode.succeed msg)))


{-| Fires when the browser takes over an in-progress gesture, for example when
a touch turns into a page scroll. Treat it like an interrupted `onPointerUp`:
end whatever drag was in progress.
-}
onPointerCancel : msg -> Attribute { a | events : Supported } msg
onPointerCancel msg =
    EventAttr (eventHash "pointercancel") (\_ -> VirtualDom.on "pointercancel" (VirtualDom.Normal (Decode.succeed msg)))



-- DETAILED HANDLERS


{-| Like [`onClick`](#onClick), but hands you the full [`Pointer`](#Pointer)
record.
-}
onClickWith : (Pointer -> msg) -> Attribute { a | events : Supported } msg
onClickWith toMsg =
    detailed "click" toMsg


{-| Like [`onPointerDown`](#onPointerDown), but hands you the full
[`Pointer`](#Pointer) record. This is where you'd grab `.frame` and `.pointerId`
to set up a drag.
-}
onPointerDownWith : (Pointer -> msg) -> Attribute { a | events : Supported } msg
onPointerDownWith toMsg =
    detailed "pointerdown" toMsg


{-| Like [`onPointerUp`](#onPointerUp), but hands you the full
[`Pointer`](#Pointer) record.
-}
onPointerUpWith : (Pointer -> msg) -> Attribute { a | events : Supported } msg
onPointerUpWith toMsg =
    detailed "pointerup" toMsg


{-| Like [`onPointerMove`](#onPointerMove), but hands you the full
[`Pointer`](#Pointer) record.
-}
onPointerMoveWith : (Pointer -> msg) -> Attribute { a | events : Supported } msg
onPointerMoveWith toMsg =
    detailed "pointermove" toMsg



-- WHEEL


{-| Fires when the mouse wheel or trackpad scrolls over the element. Calls
`preventDefault`, so the page won't scroll while the pointer is over your
drawing. That is handy for zoom, but don't attach it to something the user
needs to be able to scroll past.

    Events.onWheel (\wheel -> Zoomed wheel)

-}
onWheel : (Wheel -> msg) -> Attribute { a | events : Supported } msg
onWheel toMsg =
    EventAttr (eventHash "wheel")
        (\accum ->
            VirtualDom.on "wheel"
                (VirtualDom.MayPreventDefault (Decode.map (\w -> ( toMsg w, True )) (wheelDecoder accum)))
        )



-- FRAME / DRAGGING


{-| Convert a client-pixel position to scene coordinates using a captured
[`Frame`](#Frame).
-}
frameToScene : Frame -> ( Float, Float ) -> ( Float, Float )
frameToScene (Frame mat) point =
    Internal.applyPoint mat point


{-| Track a mouse drag across the whole window, converting each position to
scene coordinates via a [`Frame`](#Frame) you captured on `onPointerDown`.

Subscribe to it only while a drag is in progress, and only for mouse drags.
Touch and pen keep firing on the element itself, so they don't need it:

    subscriptions model =
        case model.drag of
            Just { frame, pointerType } ->
                if pointerType == Events.Mouse then
                    Events.whileDragging frame
                        { onMove = DragMoved
                        , onEnd = DragEnded
                        }

                else
                    Sub.none

            Nothing ->
                Sub.none

The `Frame` is a snapshot taken when the drag began. If the page scrolls or your
`Evg.svg` moves during the drag, the converted positions will be off by that
much; capture a fresh `Frame` if that matters. A `Frame` also assumes the `svg`
element itself carries no CSS `transform` (ordinary positioning is fine).

-}
whileDragging : Frame -> { onMove : ( Float, Float ) -> msg, onEnd : ( Float, Float ) -> msg } -> Sub msg
whileDragging (Frame mat) handlers =
    Sub.batch
        [ Browser.Events.onMouseMove (Decode.map (handlers.onMove << Internal.applyPoint mat) clientPointDecoder)
        , Browser.Events.onMouseUp (Decode.map (handlers.onEnd << Internal.applyPoint mat) clientPointDecoder)
        ]



-- SHARED DECODING


{-| Build a simple handler that reports the local-space position.
-}
simple : String -> (( Float, Float ) -> msg) -> Attribute { a | events : Supported } msg
simple name toMsg =
    EventAttr (eventHash name)
        (\accum -> VirtualDom.on name (VirtualDom.Normal (Decode.map (toMsg << .local) (pointerDecoder accum))))


{-| Build a detailed handler that reports the whole `Pointer`.
-}
detailed : String -> (Pointer -> msg) -> Attribute { a | events : Supported } msg
detailed name toMsg =
    EventAttr (eventHash name)
        (\accum -> VirtualDom.on name (VirtualDom.Normal (Decode.map toMsg (pointerDecoder accum))))


{-| The affine mapping from an element-relative offset to scene coordinates,
derived from the root `<svg>`'s viewBox, rendered size, and preserveAspectRatio.
Written `sceneX = sx * offsetX + ex` per axis.
-}
type alias SceneAffine =
    { sx : Float
    , ex : Float
    , sy : Float
    , ey : Float
    }


pointerDecoder : Mat23 -> Decoder Pointer
pointerDecoder accum =
    Decode.map8
        (\affine ( ox, oy ) ( cx, cy ) ptrType ids btn mods _ ->
            let
                scene =
                    ( affine.sx * ox + affine.ex, affine.sy * oy + affine.ey )

                frame =
                    buildFrame affine ( cx, cy ) ( ox, oy )
            in
            { local = Internal.applyPoint (Internal.invertMat accum) scene
            , scene = scene
            , client = ( cx, cy )
            , frame = frame
            , pointerType = ptrType
            , pointerId = ids.pointerId
            , isPrimary = ids.isPrimary
            , button = btn
            , modifiers = mods
            }
        )
        sceneAffineDecoder
        offsetDecoder
        clientPointDecoder
        pointerTypeDecoder
        pointerIdsDecoder
        buttonDecoder
        modifiersDecoder
        (Decode.succeed ())


wheelDecoder : Mat23 -> Decoder Wheel
wheelDecoder accum =
    Decode.map7
        (\affine ( ox, oy ) ( cx, cy ) delta pinch mods _ ->
            let
                scene =
                    ( affine.sx * ox + affine.ex, affine.sy * oy + affine.ey )
            in
            { local = Internal.applyPoint (Internal.invertMat accum) scene
            , scene = scene
            , delta = delta
            , pinch = pinch
            , frame = buildFrame affine ( cx, cy ) ( ox, oy )
            , modifiers = mods
            }
        )
        sceneAffineDecoder
        offsetDecoder
        clientPointDecoder
        wheelDeltaDecoder
        (Decode.field "ctrlKey" Decode.bool)
        modifiersDecoder
        (Decode.succeed ())


offsetDecoder : Decoder ( Float, Float )
offsetDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "offsetX" Decode.float)
        (Decode.field "offsetY" Decode.float)


clientPointDecoder : Decoder ( Float, Float )
clientPointDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)


wheelDeltaDecoder : Decoder ( Float, Float )
wheelDeltaDecoder =
    Decode.map3
        (\dx dy mode ->
            let
                factor =
                    -- deltaMode: 0 = pixels, 1 = lines, 2 = pages
                    case mode of
                        1 ->
                            16

                        2 ->
                            800

                        _ ->
                            1
            in
            ( dx * factor, dy * factor )
        )
        (Decode.field "deltaX" Decode.float)
        (Decode.field "deltaY" Decode.float)
        (Decode.oneOf [ Decode.field "deltaMode" Decode.int, Decode.succeed 0 ])


pointerTypeDecoder : Decoder PointerType
pointerTypeDecoder =
    Decode.oneOf
        [ Decode.field "pointerType" Decode.string
            |> Decode.map
                (\s ->
                    case s of
                        "touch" ->
                            Touch

                        "pen" ->
                            Pen

                        _ ->
                            Mouse
                )
        , Decode.succeed Mouse
        ]


pointerIdsDecoder : Decoder { pointerId : Int, isPrimary : Bool }
pointerIdsDecoder =
    Decode.map2 (\pid primary -> { pointerId = pid, isPrimary = primary })
        (Decode.oneOf [ Decode.field "pointerId" Decode.int, Decode.succeed 0 ])
        (Decode.oneOf [ Decode.field "isPrimary" Decode.bool, Decode.succeed True ])


buttonDecoder : Decoder Button
buttonDecoder =
    Decode.oneOf [ Decode.field "button" Decode.int, Decode.succeed 0 ]
        |> Decode.map
            (\b ->
                case b of
                    0 ->
                        Main

                    1 ->
                        Middle

                    2 ->
                        Secondary

                    3 ->
                        Back

                    4 ->
                        Forward

                    _ ->
                        NoButton
            )


modifiersDecoder : Decoder Modifiers
modifiersDecoder =
    Decode.map4 Modifiers
        (Decode.field "shiftKey" Decode.bool)
        (Decode.field "ctrlKey" Decode.bool)
        (Decode.field "altKey" Decode.bool)
        (Decode.field "metaKey" Decode.bool)


{-| Reads the root `<svg>`'s geometry off the event target and derives the
offset→scene affine. Tries the target's `ownerSVGElement` (set when the handler
is on a shape or group), falling back to the target itself (when the handler is
on the `<svg>` root, whose `ownerSVGElement` is null).
-}
sceneAffineDecoder : Decoder SceneAffine
sceneAffineDecoder =
    Decode.oneOf
        [ Decode.at [ "currentTarget", "ownerSVGElement" ] geometryDecoder |> Decode.map affineFromGeometry
        , Decode.field "currentTarget" geometryDecoder |> Decode.map affineFromGeometry

        -- If the root <svg> geometry can't be read (e.g. no viewBox, or a
        -- non-browser test DOM), fall back to treating offset pixels as scene
        -- coordinates directly rather than failing the whole handler.
        , Decode.succeed { sx = 1, ex = 0, sy = 1, ey = 0 }
        ]


type alias Geometry =
    { vbX : Float
    , vbY : Float
    , vbW : Float
    , vbH : Float
    , width : Float
    , height : Float
    , align : Int
    , meetOrSlice : Int
    }


geometryDecoder : Decoder Geometry
geometryDecoder =
    Decode.map8 Geometry
        (Decode.at [ "viewBox", "baseVal", "x" ] Decode.float)
        (Decode.at [ "viewBox", "baseVal", "y" ] Decode.float)
        (Decode.at [ "viewBox", "baseVal", "width" ] Decode.float)
        (Decode.at [ "viewBox", "baseVal", "height" ] Decode.float)
        (Decode.field "clientWidth" Decode.float)
        (Decode.field "clientHeight" Decode.float)
        (Decode.oneOf [ Decode.at [ "preserveAspectRatio", "baseVal", "align" ] Decode.int, Decode.succeed 5 ])
        (Decode.oneOf [ Decode.at [ "preserveAspectRatio", "baseVal", "meetOrSlice" ] Decode.int, Decode.succeed 1 ])


{-| Turn decoded SVG geometry into the per-axis offset→scene affine, exactly
inverting how the browser lays out a viewBox (including preserveAspectRatio
letterboxing).
-}
affineFromGeometry : Geometry -> SceneAffine
affineFromGeometry g =
    if g.width == 0 || g.height == 0 || g.vbW == 0 || g.vbH == 0 then
        { sx = 1, ex = 0, sy = 1, ey = 0 }

    else if g.align == 0 then
        -- preserveAspectRatio="none": independent per-axis scaling.
        { sx = g.vbW / g.width
        , ex = g.vbX
        , sy = g.vbH / g.height
        , ey = g.vbY
        }

    else
        let
            scaleX =
                g.width / g.vbW

            scaleY =
                g.height / g.vbH

            scale =
                if g.meetOrSlice == 2 then
                    max scaleX scaleY

                else
                    min scaleX scaleY

            tx =
                (g.width - g.vbW * scale) * alignFractionX g.align

            ty =
                (g.height - g.vbH * scale) * alignFractionY g.align
        in
        { sx = 1 / scale
        , ex = g.vbX - tx / scale
        , sy = 1 / scale
        , ey = g.vbY - ty / scale
        }


alignFractionX : Int -> Float
alignFractionX align =
    -- 1,4,7 = xMin ; 2,5,8 = xMid ; 3,6,9 = xMax
    case modBy 3 align of
        1 ->
            0

        2 ->
            0.5

        _ ->
            1


alignFractionY : Int -> Float
alignFractionY align =
    -- 1,2,3 = YMin ; 4,5,6 = YMid ; 7,8,9 = YMax
    if align <= 3 then
        0

    else if align <= 6 then
        0.5

    else
        1


{-| Build a `Frame` (a client→scene affine) from the offset→scene affine plus
one known (client, offset) pair. Since `offset = client - svgOrigin`, we recover
the svg's client origin as `client - offset` and fold it into the mapping.
-}
buildFrame : SceneAffine -> ( Float, Float ) -> ( Float, Float ) -> Frame
buildFrame affine ( cx, cy ) ( ox, oy ) =
    let
        originX =
            cx - ox

        originY =
            cy - oy
    in
    Frame
        { a = affine.sx
        , b = 0
        , c = 0
        , d = affine.sy
        , e = affine.ex - affine.sx * originX
        , f = affine.ey - affine.sy * originY
        }



-- POINTER BEHAVIOUR


{-| How the browser should treat touch gestures on this element.
-}
type TouchActionValue
    = None
    | PanX
    | PanY
    | Manipulation


{-| Declares which touch gestures the browser may handle itself, before your
handlers see them. Set this to `None` on anything you drag or zoom with touch,
so the browser doesn't scroll or pinch the page instead.

    Events.touchAction Events.None

-}
touchAction : TouchActionValue -> Evg.Attribute { a | events : Evg.Supported } msg
touchAction value =
    let
        str =
            case value of
                None ->
                    "none"

                PanX ->
                    "pan-x"

                PanY ->
                    "pan-y"

                Manipulation ->
                    "manipulation"
    in
    -- `touch-action` is a CSS property, not an SVG presentation attribute:
    -- as an attribute browsers ignore it, so it has to go in as a style.
    Attr (Internal.mixString str taHash_) "style" ("touch-action: " ++ str) (VirtualDom.style "touch-action" str)


{-| Controls which parts of a shape respond to pointer events.
-}
type PointerEventsValue
    = VisiblePainted
    | Visible
    | Painted
    | All
    | PointerEventsNone


{-| Sets which parts of a shape can receive pointer events.

  - `VisiblePainted`: only the painted (filled/stroked) visible areas (default)
  - `Visible`: the entire visible area, even transparent parts
  - `Painted`: all painted areas, even if hidden
  - `All`: the entire area regardless of visibility or paint
  - `PointerEventsNone`: the shape ignores all pointer events

-}
pointerEvents : PointerEventsValue -> Evg.Attribute { a | events : Evg.Supported } msg
pointerEvents value =
    let
        str =
            case value of
                VisiblePainted ->
                    "visiblePainted"

                Visible ->
                    "visible"

                Painted ->
                    "painted"

                All ->
                    "all"

                PointerEventsNone ->
                    "none"
    in
    Attr (Internal.mixString str peHash_) "pointer-events" str (Svg.Attributes.pointerEvents str)


{-| The mouse cursor shape when hovering over the element.
-}
type CursorValue
    = Default
    | PointerCursor
    | Move
    | Crosshair
    | Text
    | NotAllowed
    | Grab
    | Grabbing


{-| Sets the mouse cursor appearance when hovering over the shape.

    -- hand cursor, indicating clickable:
    Events.cursor Events.PointerCursor

-}
cursor : CursorValue -> Evg.Attribute { a | events : Evg.Supported } msg
cursor value =
    let
        str =
            case value of
                Default ->
                    "default"

                PointerCursor ->
                    "pointer"

                Move ->
                    "move"

                Crosshair ->
                    "crosshair"

                Text ->
                    "text"

                NotAllowed ->
                    "not-allowed"

                Grab ->
                    "grab"

                Grabbing ->
                    "grabbing"
    in
    Attr (Internal.mixString str curHash_) "cursor" str (Svg.Attributes.cursor str)



-- Hashes


eventHash : String -> Int
eventHash name =
    Internal.mixString name 987654321


peHash_ : Int
peHash_ =
    5173520


curHash_ : Int
curHash_ =
    160398417


taHash_ : Int
taHash_ =
    5171540
