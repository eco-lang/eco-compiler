module Evg.Advanced exposing
    ( viewBox, preserveAspectRatio, AlignValue(..), MeetOrSlice(..)
    , customElement, customAttribute, customFilter
    , fromSvg, notSupported
    , nestedSvg
    , link
    , role, ariaLabel, ariaHidden
    , visibility, Visibility(..)
    )

{-| Escape hatches and advanced features for when the high-level API isn't
enough.

Most of the time you won't need this module. It's here for the 5% of cases
where you need full control over SVG output.


# Viewport Control

A viewport is the rectangular area on screen that a drawing gets rendered
into. Normally `Evg.svg` sets it up for you so that one coordinate unit equals
one pixel. The functions here let you change that relationship: show a
different rectangle of your coordinate system, or control what happens when
the drawing and its on-screen area have different shapes.

@docs viewBox, preserveAspectRatio, AlignValue, MeetOrSlice


# Escape Hatches

@docs customElement, customAttribute, customFilter


# Embedding elm/svg

If you already have graphics built with [`elm/svg`](https://package.elm-lang.org/packages/elm/svg/latest/),
for example an icon exported from a drawing program, you can drop it straight
into an Evg drawing rather than porting it.

@docs fromSvg, notSupported


# Nested Viewports

@docs nestedSvg


# Links

@docs link


# Accessibility (ARIA)

@docs role, ariaLabel, ariaHidden


# Showing and Hiding Elements

@docs visibility, Visibility

-}

import Bitwise
import Dict
import Evg
import Evg.Internal as Internal exposing (Attribute(..))
import Svg
import Svg.Attributes
import VirtualDom


{-| Where to place the drawing inside the viewport when
[`preserveAspectRatio`](#preserveAspectRatio) leaves spare room or has to crop.

The names read as two halves: the `X` part picks horizontal placement (`Min`
is left, `Mid` is centre, `Max` is right) and the `Y` part picks vertical
placement (`Min` is top, `Mid` is centre, `Max` is bottom). So `XMidYMid`
centres the drawing both ways, which is the default and usually what you want.

`AlignNone` is different: instead of positioning the drawing, it stretches it
to fill the viewport exactly, distorting the shapes if the proportions don't
match.

-}
type AlignValue
    = AlignNone
    | XMinYMin
    | XMidYMin
    | XMaxYMin
    | XMinYMid
    | XMidYMid
    | XMaxYMid
    | XMinYMax
    | XMidYMax
    | XMaxYMax


{-| What to do when the drawing's proportions don't match the viewport's.

  - `Meet`: scale the drawing until it just fits inside. You see all of it,
    but there may be empty bands left over on two sides, like the black bars
    when a widescreen film plays on a square screen.
  - `Slice`: scale the drawing until it covers the whole viewport. There are
    no empty bands, but whatever pokes out past the edges gets cropped away.

![meet vs slice](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/preserve-aspect-ratio.svg)

-}
type MeetOrSlice
    = Meet
    | Slice


{-| Sets which rectangle of your coordinate system gets shown. Think of the
viewBox as a window onto your drawing: everything inside the rectangle
`(minX, minY)` to `(minX + width, minY + height)` is scaled to fill the
element's on-screen area, and everything outside it falls out of view.

    -- Show the region from (0, 0) to (1000, 1000),
    -- whatever the on-screen size of the element is:
    Advanced.viewBox 0 0 1000 1000

This means you can draw in whatever numbers are convenient (say, data values
from 0 to 1000) and let the viewBox map them onto the pixels available.
Changing `minX` and `minY` over time pans the window across the drawing, and
shrinking `width` and `height` zooms in.

-}
viewBox : Float -> Float -> Float -> Float -> Evg.Attribute { a | viewBox : Evg.Supported } msg
viewBox minX minY w h =
    let
        value =
            String.fromFloat minX
                ++ " "
                ++ String.fromFloat minY
                ++ " "
                ++ String.fromFloat w
                ++ " "
                ++ String.fromFloat h
    in
    Attr (Internal.mixString value vbHash_) "viewBox" value (Svg.Attributes.viewBox value)


{-| Controls what happens when the window's shape doesn't match the drawing's
shape. If the [`viewBox`](#viewBox) rectangle is, say, wide and short but the
on-screen area is tall and narrow, something has to give. The choices are:

  - letterbox it (`Meet`): show the whole drawing and leave empty bands
  - crop it (`Slice`): fill the whole area and cut off the overflow
  - stretch it (`AlignNone`): distort the drawing to fit exactly

The [`AlignValue`](#AlignValue) says where the drawing sits within the
viewport (centred, pushed to the top-left, and so on), and the
[`MeetOrSlice`](#MeetOrSlice) picks between letterboxing and cropping.

    -- The default behaviour: centred and letterboxed.
    Advanced.preserveAspectRatio
        Advanced.XMidYMid
        Advanced.Meet

-}
preserveAspectRatio : AlignValue -> MeetOrSlice -> Evg.Attribute { a | viewBox : Evg.Supported } msg
preserveAspectRatio align meetOrSlice =
    let
        value =
            if align == AlignNone then
                "none"

            else
                let
                    alignStr =
                        case align of
                            AlignNone ->
                                "none"

                            XMinYMin ->
                                "xMinYMin"

                            XMidYMin ->
                                "xMidYMin"

                            XMaxYMin ->
                                "xMaxYMin"

                            XMinYMid ->
                                "xMinYMid"

                            XMidYMid ->
                                "xMidYMid"

                            XMaxYMid ->
                                "xMaxYMid"

                            XMinYMax ->
                                "xMinYMax"

                            XMidYMax ->
                                "xMidYMax"

                            XMaxYMax ->
                                "xMaxYMax"

                    mosStr =
                        case meetOrSlice of
                            Meet ->
                                "meet"

                            Slice ->
                                "slice"
                in
                alignStr ++ " " ++ mosStr
    in
    Attr (Internal.mixString value parHash_) "preserveAspectRatio" value (Svg.Attributes.preserveAspectRatio value)


{-| Creates a raw SVG element by tag name. Use this when you need an element
that this library doesn't provide a dedicated function for.

    Advanced.customElement "foreignObject"
        [ Advanced.customAttribute "x" "10"
        , Advanced.customAttribute "width" "200"
        ]
        []

Any attribute is accepted here, including the ordinary ones from `Evg` and
its other modules, since the library cannot know what a tag you supply
yourself understands. That also means nothing is checked for you: it is up to
you to only pass attributes the element actually supports.

    Advanced.customElement "foreignObject"
        [ Advanced.customAttribute "width" "200"
        , Evg.opacity 0.5
        ]
        []

-}
customElement : String -> List (Evg.Attribute a msg) -> List (Internal.Evg msg) -> Internal.Evg msg
customElement tag attrs children =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, inspectable } =
            Internal.svgAttributes attrs
    in
    Internal.element tag (Bitwise.xor (Internal.hashStringToInt tag) (Internal.attrHash attrs)) vdomAttrs eventBuilders ownMatrix inspectable children defs


{-| Creates a raw SVG attribute. Use this when you need an attribute that this
library doesn't provide a dedicated function for.

    Advanced.customAttribute "data-tooltip" "hello"

-}
customAttribute : String -> String -> Evg.Attribute a msg
customAttribute key value =
    Attr (Internal.hashStringToInt key |> Internal.mixString value) key value (VirtualDom.attribute key value)


{-| Places graphics built with [`elm/svg`](https://package.elm-lang.org/packages/elm/svg/latest/)
into an Evg drawing. Useful for icons and other assets exported from a
graphics program, which tools convert to `elm/svg` mechanically, so you can
use them without porting them by hand.

    import Svg
    import Svg.Attributes

    Evg.svg []
        { width = 100, height = 100 }
        [ Evg.circle [] { r = 40, center = ( 50, 50 ) }
        , Advanced.fromSvg
            { id = "logo"
            , svg =
                Svg.g []
                    [ Svg.path
                        [ Svg.Attributes.d "M0 0 L9 9" ]
                        []
                    ]
            , fallback = Advanced.notSupported
            }
        ]

The fields:

  - `svg` is the graphic to embed.
  - `id` names this piece, and must be unique within your drawing. The
    library cannot look inside an `elm/svg` value, so the name stands in for
    the content when it needs to tell pieces apart, such as when one is used
    as a clip stencil. Two pieces sharing a name can be mistaken for each
    other.
  - `fallback` is drawn whenever something is asked of the graphic that the
    library cannot do to an opaque value. Pass
    [`notSupported`](#notSupported) to get a visible placeholder, `Evg.none`
    to leave a gap, or draw a real stand-in with Evg if you want the result
    to look right.

The fallback stands in for the graphic in these cases, so an unsupported
combination shows up rather than failing quietly:

  - [`Evg.toString`](Evg#toString) always uses it, since the embedded markup
    cannot be read back out of the virtual DOM.
  - Applying an [`Evg.Animate`](Evg-Animate) function uses it. Animations
    work by placing an element inside the shape they animate, and the inside
    of an embedded value is not ours to change.

One limit has no fallback, because the graphic still draws correctly: event
handlers on shapes within it report coordinates in the drawing's own space
rather than the shape's, since the library does not know what transforms the
embedded markup applies.

Attributes still work normally, since those go on a wrapper around the
embedded content, so you can position, fade, or clip an embedded graphic:

    Evg.group [ Evg.opacity 0.5 ]
        [ Advanced.fromSvg
            { id = "logo"
            , svg = myIcon
            , fallback = Advanced.notSupported
            }
        ]

-}
fromSvg :
    { id : String, svg : Svg.Svg msg, fallback : Evg.Evg msg }
    -> Evg.Evg msg
fromSvg { id, svg, fallback } =
    Internal.keyedNode (Internal.hashStringToInt id) svg fallback


{-| A visible "not supported" placeholder: a red box with white lettering,
sized to fill whatever area it is placed in. Use it as the `fallback` for
[`fromSvg`](#fromSvg) so that anything the library cannot serialize shows up
obviously in an exported file rather than silently leaving a hole.

The red box fills whatever area it is given, whether that is wide, tall, or
square, and the lettering stays readable at any of those shapes:

![the placeholder shown in a wide area and a tall one](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/not-supported.svg)

-}
notSupported : Evg.Evg msg
notSupported =
    -- The box is a plain rect at 100% of the container, so it stretches on
    -- its own. The lettering sits in its own viewport that letterboxes
    -- instead of stretching, so it keeps its proportions at any shape. It is
    -- a sibling of the box rather than inside it, since anything within a
    -- stretched viewport inherits that distortion.
    customElement "g"
        []
        [ customElement "rect"
            [ customAttribute "width" "100%"
            , customAttribute "height" "100%"
            , Evg.fillStr "#c00"
            ]
            []
        , customElement "svg"
            [ customAttribute "width" "100%"
            , customAttribute "height" "100%"
            , viewBox 0 0 100 40
            , preserveAspectRatio XMidYMid Meet
            ]
            [ Evg.text
                [ Evg.fillStr "white"
                , Evg.fontSize 11
                , Evg.fontFamily "sans-serif"
                ]
                { x = 50, y = 24, anchor = Evg.Middle }
                "NOT SUPPORTED"
            ]
        ]


{-| Creates a smaller drawing area inside the current one, with its own
coordinate system starting at `(0, 0)` in its own top-left corner. The record
says where the area sits and how big it is, in the parent's coordinates.

This is useful for embedding a self-contained sub-scene: the children position
themselves relative to the nested area, so you can move the whole thing around
by changing `x` and `y` without touching any child coordinates.

    Advanced.nestedSvg []
        { x = 50, y = 50, width = 100, height = 100 }
        [ Evg.circle [ Evg.fillStr "red" ]
            { r = 50, center = ( 50, 50 ) }
        ]

A nested area can also carry its own [`viewBox`](#viewBox), which rescales
whatever the children draw to fit the area. That makes it a window onto a
sub-scene: here a drawing that uses coordinates up to 1000 is shown inside a
100 by 100 box, letterboxed if the proportions differ.

    Advanced.nestedSvg
        [ Advanced.viewBox 0 0 1000 1000
        , Advanced.preserveAspectRatio
            Advanced.XMidYMid
            Advanced.Meet
        ]
        { x = 50, y = 50, width = 100, height = 100 }
        [ bigSubScene ]

-}
nestedSvg :
    List (Evg.Attribute { viewBox : Evg.Supported, opacity : Evg.Supported, filter : Evg.Supported, events : Evg.Supported } msg)
    -> { x : Float, y : Float, width : Float, height : Float }
    -> List (Internal.Evg msg)
    -> Internal.Evg msg
nestedSvg attrs { x, y, width, height } children =
    let
        { vdomAttrs, eventBuilders, defs, inspectable } =
            Internal.svgAttributes attrs

        baseAttrs =
            [ Svg.Attributes.x (String.fromFloat x)
            , Svg.Attributes.y (String.fromFloat y)
            , Svg.Attributes.width (String.fromFloat width)
            , Svg.Attributes.height (String.fromFloat height)
            ]

        childDefs =
            Internal.collectDefs children
    in
    -- A nested <svg> resets the event coordinate origin: the browser reports
    -- `offsetX`/`offsetY` relative to the nearest ancestor <svg>, which for
    -- these children is this nested viewport rather than the root. So event
    -- handlers here decode against the identity matrix (their local space is
    -- what the browser already reports), and children start a fresh matrix.
    -- The builders are wrapped to ignore the accumulated parent matrix.
    Internal.Evg
        { content =
            Internal.Tag "svg"
                (baseAttrs ++ vdomAttrs)
                (List.map (\build -> \_ -> build Internal.identityMat) eventBuilders)
        , ownMatrix = Internal.identityMat
        , children = children
        , hash = 0
        , defs = defs ++ childDefs
        , attrs =
            [ ( "x", String.fromFloat x )
            , ( "y", String.fromFloat y )
            , ( "width", String.fromFloat width )
            , ( "height", String.fromFloat height )
            ]
                ++ inspectable
        }


{-| Wraps content in a clickable link.

    Advanced.link "https://example.com"
        (Evg.text [ Evg.fillStr "blue" ]
            { x = 10, y = 20, anchor = Evg.Start }
            "Click me"
        )

-}
link : String -> Evg.Evg msg -> Internal.Evg msg
link href child =
    Internal.element "a" (Internal.mixString href aHash_) [ Svg.Attributes.xlinkHref href ] [] Internal.identityMat [] [ child ] []


{-| Sets the ARIA role for assistive technology.

    Evg.group [ Advanced.role "img" ] [ ... ]

-}
role : String -> Evg.Attribute { a | role : Evg.Supported } msg
role value =
    Attr (Internal.mixString value roleHash_) "role" value (VirtualDom.attribute "role" value)


{-| Provides a text label for assistive technology (screen readers).

    Evg.group
        [ Advanced.ariaLabel "Sales chart for Q4 2024" ]
        [ ... ]

-}
ariaLabel : String -> Evg.Attribute { a | ariaLabel : Evg.Supported } msg
ariaLabel value =
    Attr (Internal.mixString value alHash_) "aria-label" value (VirtualDom.attribute "aria-label" value)


{-| Hides an element from assistive technology. Use for purely decorative
shapes that add no informational value.

    Evg.group [ Advanced.ariaHidden True ]
        [ decorativeShapes ]

-}
ariaHidden : Bool -> Evg.Attribute { a | ariaHidden : Evg.Supported } msg
ariaHidden value =
    let
        str =
            if value then
                "true"

            else
                "false"
    in
    Attr (Internal.mixString str ahHash_) "aria-hidden" str (VirtualDom.attribute "aria-hidden" str)


{-| Whether a shape is visible or hidden.
-}
type Visibility
    = VisibilityVisible
    | VisibilityHidden
    | VisibilityCollapse


{-| Controls whether a shape is drawn. A hidden shape still occupies its
place in the drawing, and animations on it keep running, so making it
visible again shows it exactly where and how it would have been.

By default a hidden shape does not respond to pointer events. If you need an
invisible shape that still catches clicks, combine this with
`Evg.Events.pointerEvents` set to `Painted` or `All`.

    Advanced.visibility Advanced.VisibilityHidden

-}
visibility : Visibility -> Evg.Attribute { a | visibility : Evg.Supported } msg
visibility value =
    let
        str =
            case value of
                VisibilityVisible ->
                    "visible"

                VisibilityHidden ->
                    "hidden"

                VisibilityCollapse ->
                    "collapse"
    in
    Attr (Internal.mixString str visHash_) "visibility" str (Svg.Attributes.visibility str)



-- Custom filter


{-| Make your own filter primitive, for filter effects that `Evg.Filter`
doesn't cover.

You provide a function that receives the identifiers of the input filters (in
the same order as the list you pass) and returns a description of the raw
filter element to produce:

  - `name`: the SVG tag name, such as `"feTurbulence"`
  - `id` : a unique identifier for this filter step
  - `args`: attribute name and value pairs for the element
  - `children`: child elements, each a tag name with its own attribute pairs

-}
customFilter :
    (List String
     ->
        { name : String

        -- TODO: Generate the ID by hashing so the user doesn't need to specify
        , id : String
        , args : List ( String, String )
        , children : List ( String, List ( String, String ) )
        }
    )
    -> List Internal.Filter
    -> Internal.Filter
customFilter fn inputs =
    let
        allDefs =
            List.foldl
                (\input acc ->
                    Dict.union acc
                        (case input of
                            Internal.Filter args ->
                                Dict.insert args.id { name = args.name, id = args.id, args = args.args, children = args.children } args.defs

                            Internal.Virtual _ ->
                                Dict.empty
                        )
                )
                Dict.empty
                inputs

        res =
            fn
                (List.map
                    (\filter ->
                        case filter of
                            Internal.Filter args ->
                                args.id

                            Internal.Virtual str ->
                                str
                    )
                    inputs
                )
    in
    Internal.Filter
        { name = res.name
        , id = res.id
        , args = res.args
        , children = res.children
        , defs = allDefs
        }



-- Precomputed hash constants


vbHash_ : Int
vbHash_ =
    5173713


parHash_ : Int
parHash_ =
    160379166


aHash_ : Int
aHash_ =
    166906


roleHash_ : Int
roleHash_ =
    676855513


alHash_ : Int
alHash_ =
    5174058


ahHash_ : Int
ahHash_ =
    5174062


visHash_ : Int
visHash_ =
    160385301
