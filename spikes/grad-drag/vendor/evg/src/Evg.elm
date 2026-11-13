module Evg exposing
    ( Evg, Attribute, Supported, Paint, Filter
    , CoordinateSpace, objectBoundingBox, userSpace
    , svg
    , group
    , line, rect, circle, ellipse, polygon, polyline
    , text, TextAnchor(..)
    , image
    , path
    , filter, filterWithCoordinates
    , fill, stroke, fillStr, strokeStr, strokeWidth, opacity
    , dashPattern, dashOffset
    , linecapRound, linecapSquare, linecapButt
    , linejoinRound, linejoinBevel, linejoinMiter
    , strokeOpacity, fillOpacity
    , fillRuleEvenOdd, fillRuleNonZero
    , cornerRadius, fontSize, fontFamily
    , title, desc
    , class, style
    , none, map
    , batch, noAttr, when
    , toString
    )

{-| Draw pictures with shapes, text, and effects, using a friendly, type-safe API.

You describe a picture as a list of shapes, and the library renders it in the
browser as crisp vector graphics that stay sharp at any size. Positions are
plain numbers: `(0, 0)` is the top-left corner, x grows to the right, and
y grows downward.

    import Evg exposing (Evg)

    scene : Html msg
    scene =
        Evg.svg []
            { width = 200, height = 200 }
            [ Evg.circle
                [ Evg.fillStr "tomato" ]
                { r = 60, center = ( 100, 100 ) }
            , Evg.line
                [ Evg.strokeStr "navy" ]
                ( 20, 20 )
                ( 180, 180 )
            ]

This draws a tomato-colored circle in the middle of a 200 by 200 canvas, with
a navy diagonal line crossing it.

Each shape takes a list of attributes (colors, outlines, effects) followed by
the measurements that define it. The type system checks that every attribute
makes sense for the shape it is applied to. For example, `cornerRadius` is
accepted on a rectangle but rejected on a circle at compile time.


# Core Types

@docs Evg, Attribute, Supported, Paint, Filter


# Coordinate Spaces

@docs CoordinateSpace, objectBoundingBox, userSpace


# Rendering

@docs svg


# Document Structure

@docs group


# Basic Shapes

@docs line, rect, circle, ellipse, polygon, polyline


# Drawing Text

@docs text, TextAnchor


# Images

@docs image


# Paths

@docs path


# Attributes


## Colors and painting

@docs filter, filterWithCoordinates
@docs fill, stroke, fillStr, strokeStr, strokeWidth, opacity

For gradient and pattern constructors, see [`Evg.Paint`](Evg-Paint).


## Stroke style

@docs dashPattern, dashOffset
@docs linecapRound, linecapSquare, linecapButt
@docs linejoinRound, linejoinBevel, linejoinMiter
@docs strokeOpacity, fillOpacity
@docs fillRuleEvenOdd, fillRuleNonZero


## Shape options

@docs cornerRadius, fontSize, fontFamily


## Accessibility

@docs title, desc


## CSS

@docs class, style


# Utilities

@docs none, map


# Attribute Utilities

@docs batch, noAttr, when


# Serialization

@docs toString

-}

import Bitwise
import Color
import Evg.Internal as Internal exposing (Def(..))
import Evg.Path
import Html
import Svg
import Svg.Attributes
import VirtualDom


{-| A piece of a picture: a single shape, some text, or a group of other
pieces. Your whole drawing is a tree of these, and [`svg`](#svg) turns that
tree into `Html`.
-}
type alias Evg msg =
    Internal.Evg msg


{-| A setting applied to a shape, such as its color, outline, or an effect.

The `constraints` type parameter records which shapes an attribute makes sense
on, so mistakes are caught when compiling. For example, `cornerRadius` only
applies to rectangles, and the compiler will tell you if you put it on a
circle.

-}
type alias Attribute constraints msg =
    Internal.Attribute constraints msg


{-| A marker that appears in the `constraints` of an [`Attribute`](#Attribute).
You only need it when writing your own type annotations for attribute lists,
for example a helper producing attributes that work on any shape with a fill:

    fancyFill :
        List
            (Evg.Attribute
                { a | fill : Evg.Supported }
                msg
            )

-}
type alias Supported =
    Internal.Supported


{-| Describes what a shape is painted with: a solid color, a gradient, a
repeating pattern, or nothing at all. Built with the
[`Evg.Paint`](Evg-Paint) module and used with [`fill`](#fill) and
[`stroke`](#stroke).
-}
type alias Paint =
    Internal.Paint


{-| An image effect that can be applied to a shape, like a blur or a drop
shadow. Built with the [`Evg.Filter`](Evg-Filter) module and applied with
[`filter`](#filter).
-}
type alias Filter =
    Internal.Filter


{-| Where text sits relative to the position you give it. See
[`text`](#text) for what each option looks like.
-}
type TextAnchor
    = Start
    | Middle
    | End


{-| Decides which coordinates an effect (a gradient, pattern, clip path, or
mask) is measured in.

Most of the time you don't need to think about this, because the default
functions pick a sensible option. The `*WithCoordinates` variants let you
choose explicitly, and there are two choices:

Object bounding box coordinates are measured against the shape being painted.
`(0, 0)` means the shape's own top-left corner and `(1, 1)` its bottom-right,
no matter where the shape is or how big it is. Use this for effects that
should stretch with the shape, like "fade from left edge to right edge".

User space coordinates are the same plain numbers you position shapes with.
Use this for effects that should stay fixed in the picture no matter which
shape they are applied to, like one large gradient shared by several bars of
a chart.

-}
type alias CoordinateSpace =
    Internal.CoordinateSpace


{-| Coordinates measured against the shape being painted, where `(0, 0)` is
its top-left corner and `(1, 1)` its bottom-right. The rect says which part
of the shape the effect covers. Usually you want all of it:

    -- A gradient spanning the whole shape:
    Evg.objectBoundingBox
        { x = 0, y = 0, width = 1, height = 1 }

-}
objectBoundingBox : { x : Float, y : Float, width : Float, height : Float } -> CoordinateSpace
objectBoundingBox =
    Internal.ObjectBoundingBox


{-| Coordinates in the same units you position shapes with. The rect says
which region of the picture the effect covers.

    -- A gradient pinned to a specific area:
    Evg.userSpace
        { x = 0, y = 0, width = 200, height = 100 }

-}
userSpace : { x : Float, y : Float, width : Float, height : Float } -> CoordinateSpace
userSpace =
    Internal.UserSpace


{-| Creates the drawing canvas. All shapes go inside here, and the result is
ordinary `Html` you can place anywhere in your view.

The `width` and `height` set both the size on screen (in pixels) and the
coordinate system: child coordinates run from `(0, 0)` at the top-left to
`(width, height)` at the bottom-right. If CSS later stretches or shrinks the
element, your coordinates keep working; the drawing scales as one piece.

    Evg.svg []
        { width = 300, height = 200 }
        [ Evg.circle
            [ Evg.fillStr "red" ]
            { r = 50, center = ( 150, 100 ) }
        ]

-}
svg : List (Attribute { viewBox : Supported, events : Supported } msg) -> { width : Float, height : Float } -> List (Evg msg) -> Html.Html msg
svg attrs dims children =
    let
        { vdomAttrs, eventBuilders, defs } =
            Internal.svgAttributes attrs

        allDefs =
            defs ++ Internal.collectDefs children

        childNodes =
            List.map Internal.toNode children

        viewBoxStr =
            "0 0 " ++ String.fromFloat dims.width ++ " " ++ String.fromFloat dims.height

        -- The root viewBox is "0 0 width height", so scene coordinates map 1:1
        -- to the children's coordinates: the accumulated matrix here is identity.
        rootEvents =
            List.map (\build -> build Internal.identityMat) eventBuilders

        baseAttrs =
            [ Svg.Attributes.viewBox viewBoxStr
            , Svg.Attributes.width (String.fromFloat dims.width)
            , Svg.Attributes.height (String.fromFloat dims.height)
            ]
    in
    Svg.svg (baseAttrs ++ vdomAttrs ++ rootEvents)
        (Internal.renderDefs allDefs :: childNodes)


{-| Collects several shapes into one, so you can treat them as a unit. An
attribute placed on the group applies to everything inside: fade them all out
with one `opacity`, move them together with one transform, or listen for
clicks on any of them with one event handler.

    -- Two overlapping squares, both at half opacity:
    Evg.group [ Evg.opacity 0.5 ]
        [ Evg.rect
            [ Evg.fillStr "blue" ]
            { x = 0
            , y = 0
            , width = 100
            , height = 100
            }
        , Evg.rect
            [ Evg.fillStr "red" ]
            { x = 50
            , y = 50
            , width = 100
            , height = 100
            }
        ]

Groups are also handy for structuring a drawing the way you'd structure code,
with one function returning the group for each part of the picture.

-}
group : List (Attribute { opacity : Supported, filter : Supported, transform : Supported, events : Supported } msg) -> List (Evg msg) -> Evg msg
group attrs children =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs
    in
    Internal.element "g"
        (Bitwise.xor gHash_ (Internal.attrHash attrs))
        vdomAttrs
        eventBuilders
        ownMatrix
        inspectable
        (a11yChildren ++ children)
        defs


{-| Draws a straight line from one point to another.

A line has no inside to fill, only a stroke (the visible ink drawn along it).
If you don't pick a stroke color, you get a thin black line.

![line example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/line.svg)

    Evg.line [] ( 10, 20 ) ( 110, 20 )

    -- A thicker red diagonal:
    Evg.line
        [ Evg.strokeStr "red", Evg.strokeWidth 3 ]
        ( 0, 0 )
        ( 100, 100 )

-}
line :
    List (Attribute { stroke : Supported, opacity : Supported, marker : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> ( Float, Float )
    -> ( Float, Float )
    -> Evg msg
line attrs ( x1, y1 ) ( x2, y2 ) =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        baseAttrs =
            [ Svg.Attributes.x1 (String.fromFloat x1)
            , Svg.Attributes.y1 (String.fromFloat y1)
            , Svg.Attributes.x2 (String.fromFloat x2)
            , Svg.Attributes.y2 (String.fromFloat y2)
            , Svg.Attributes.stroke "black"
            ]
    in
    Internal.element "line"
        (lineHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixFloat x1 |> Internal.mixFloat y1 |> Internal.mixFloat x2 |> Internal.mixFloat y2)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        ([ ( "x1", String.fromFloat x1 ), ( "y1", String.fromFloat y1 ), ( "x2", String.fromFloat x2 ), ( "y2", String.fromFloat y2 ), ( "stroke", "black" ) ] ++ inspectable)
        a11yChildren
        defs


{-| Draws a rectangle. The `x` and `y` give its top-left corner, and `width`
and `height` extend it rightward and downward from there. Without a fill
color it comes out solid black.

![rect example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/rect-example.svg)

    Evg.rect
        [ Evg.fillStr "navy" ]
        { x = 10, y = 10, width = 100, height = 100 }

    -- With rounded corners:
    Evg.rect [ Evg.fillStr "navy", Evg.cornerRadius 10 ]
        { x = 10, y = 10, width = 100, height = 100 }

-}
rect :
    List (Attribute { fill : Supported, stroke : Supported, cornerRadius : Supported, opacity : Supported, marker : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> { x : Float, y : Float, width : Float, height : Float }
    -> Evg msg
rect attrs { x, y, width, height } =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        baseAttrs =
            [ Svg.Attributes.x (String.fromFloat x)
            , Svg.Attributes.y (String.fromFloat y)
            , Svg.Attributes.width (String.fromFloat width)
            , Svg.Attributes.height (String.fromFloat height)
            ]
    in
    Internal.element "rect"
        (rectHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixFloat x |> Internal.mixFloat y |> Internal.mixFloat width |> Internal.mixFloat height)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        ([ ( "x", String.fromFloat x ), ( "y", String.fromFloat y ), ( "width", String.fromFloat width ), ( "height", String.fromFloat height ) ] ++ inspectable)
        a11yChildren
        defs


{-| Draws a circle. You give the center point and the radius `r` (the
distance from the center to the edge).

![circle example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/circle-example.svg)

    Evg.circle
        [ Evg.fillStr "crimson" ]
        { r = 40, center = ( 50, 50 ) }

-}
circle :
    List (Attribute { fill : Supported, stroke : Supported, opacity : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> { r : Float, center : ( Float, Float ) }
    -> Evg msg
circle attrs { r, center } =
    let
        ( cx, cy ) =
            center

        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        baseAttrs =
            [ Svg.Attributes.r (String.fromFloat r)
            , Svg.Attributes.cx (String.fromFloat cx)
            , Svg.Attributes.cy (String.fromFloat cy)
            ]
    in
    Internal.element "circle"
        (circleHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixFloat r |> Internal.mixFloat cx |> Internal.mixFloat cy)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        ([ ( "r", String.fromFloat r ), ( "cx", String.fromFloat cx ), ( "cy", String.fromFloat cy ) ] ++ inspectable)
        a11yChildren
        defs


{-| Draws an ellipse (an oval): like a circle, but with separate radii for
each direction. `rx` is the distance from the center to the left and right
edges, `ry` to the top and bottom. A wide `rx` with a small `ry` gives a
flattened, lying-down oval.

![ellipse example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/ellipse-example.svg)

    Evg.ellipse
        [ Evg.fillStr "mediumpurple" ]
        { rx = 70, ry = 35, center = ( 80, 50 ) }

-}
ellipse :
    List (Attribute { fill : Supported, stroke : Supported, opacity : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> { rx : Float, ry : Float, center : ( Float, Float ) }
    -> Evg msg
ellipse attrs { rx, ry, center } =
    let
        ( cx, cy ) =
            center

        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        baseAttrs =
            [ Svg.Attributes.rx (String.fromFloat rx)
            , Svg.Attributes.ry (String.fromFloat ry)
            , Svg.Attributes.cx (String.fromFloat cx)
            , Svg.Attributes.cy (String.fromFloat cy)
            ]
    in
    Internal.element "ellipse"
        (ellipseHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixFloat rx |> Internal.mixFloat ry |> Internal.mixFloat cx |> Internal.mixFloat cy)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        ([ ( "rx", String.fromFloat rx ), ( "ry", String.fromFloat ry ), ( "cx", String.fromFloat cx ), ( "cy", String.fromFloat cy ) ] ++ inspectable)
        a11yChildren
        defs


{-| Draws a closed shape by connecting a list of corner points with straight
lines. The last point connects back to the first automatically, so three
points make a triangle, four make a quadrilateral, and so on.

![polygon example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/polygon-example.svg)

    -- A triangle:
    Evg.polygon [ Evg.fillStr "limegreen" ]
        [ ( 60, 10 ), ( 110, 100 ), ( 10, 100 ) ]

For shapes with curved edges, see [`path`](#path).

-}
polygon :
    List (Attribute { fill : Supported, stroke : Supported, opacity : Supported, marker : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> List ( Float, Float )
    -> Evg msg
polygon attrs points =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        pointsStr =
            points
                |> List.map (\( x, y ) -> String.fromFloat x ++ "," ++ String.fromFloat y)
                |> String.join " "

        baseAttrs =
            [ Svg.Attributes.points pointsStr ]
    in
    Internal.element "polygon"
        (polygonHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixString pointsStr)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        (( "points", pointsStr ) :: inspectable)
        a11yChildren
        defs


{-| Draws a connected series of straight line segments through a list of
points, like a line chart. Unlike [`polygon`](#polygon) the shape stays open:
the last point does not connect back to the first. It comes out as a thin
black line with nothing filled in.

![polyline example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/polyline-example.svg)

    Evg.polyline []
        [ ( 10, 50 )
        , ( 30, 10 )
        , ( 50, 40 )
        , ( 70, 20 )
        , ( 90, 45 )
        , ( 110, 15 )
        ]

-}
polyline :
    List (Attribute { fill : Supported, stroke : Supported, opacity : Supported, marker : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> List ( Float, Float )
    -> Evg msg
polyline attrs points =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        pointsStr =
            points
                |> List.map (\( x, y ) -> String.fromFloat x ++ "," ++ String.fromFloat y)
                |> String.join " "

        baseAttrs =
            [ Svg.Attributes.points pointsStr
            , Svg.Attributes.fill "none"
            , Svg.Attributes.stroke "black"
            ]
    in
    Internal.element "polyline"
        (polylineHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixString pointsStr)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        ([ ( "points", pointsStr ), ( "fill", "none" ), ( "stroke", "black" ) ] ++ inspectable)
        a11yChildren
        defs


{-| Draws a line of text at a position.

The `y` coordinate is the text's baseline, the invisible line the letters sit
on, so the characters appear above the point you give (with descenders like
the tail of a "g" hanging below it). The `anchor` says where the text sits
horizontally relative to `x`:

  - `Start`: the text begins at `x` and runs to the right
  - `Middle`: the text is centered on `x`
  - `End`: the text ends at `x`, running to the left of it

`Middle` is what you want for labelling a point, like the value above a bar
in a chart.

    Evg.text [ Evg.fillStr "black", Evg.fontSize 24 ]
        { x = 50, y = 50, anchor = Evg.Start }
        "Hello"

For multiple styles within one line, or text that flows along a curve, see
the [`Evg.Text`](Evg-Text) module.

-}
text :
    List (Attribute { a | text : Supported } msg)
    -> { x : Float, y : Float, anchor : TextAnchor }
    -> String
    -> Evg msg
text attrs pos content =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable, textPath } =
            Internal.svgAttributes attrs

        anchorStr =
            case pos.anchor of
                Start ->
                    "start"

                Middle ->
                    "middle"

                End ->
                    "end"

        baseAttrs =
            [ Svg.Attributes.x (String.fromFloat pos.x)
            , Svg.Attributes.y (String.fromFloat pos.y)
            , Svg.Attributes.textAnchor anchorStr
            ]

        contentChildren =
            case textPath of
                Nothing ->
                    [ Internal.textNode content ]

                Just ( href, _ ) ->
                    [ Internal.element "textPath"
                        (Internal.hashStringToInt href)
                        [ Svg.Attributes.xlinkHref ("#" ++ href) ]
                        []
                        Internal.identityMat
                        [ ( "xlink:href", "#" ++ href ) ]
                        [ Internal.textNode content ]
                        []
                    ]
    in
    Internal.Evg
        { content = Internal.Tag "text" (baseAttrs ++ vdomAttrs) eventBuilders
        , ownMatrix = ownMatrix
        , children = a11yChildren ++ contentChildren
        , hash = textHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixFloat pos.x |> Internal.mixFloat pos.y |> Internal.mixString content
        , defs = defs
        , attrs = [ ( "x", String.fromFloat pos.x ), ( "y", String.fromFloat pos.y ), ( "text-anchor", anchorStr ) ] ++ inspectable
        }


{-| Places an image file (PNG, JPG, SVG, and so on) into the drawing. The
`href` is the image's URL, and the rectangle says where it goes and how big
to draw it. If the rectangle's proportions don't match the image's, the
image is scaled to fit inside without distortion.

    Evg.image []
        { href = "photo.png"
        , x = 0
        , y = 0
        , width = 200
        , height = 150
        }

-}
image :
    List (Attribute { opacity : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> { href : String, x : Float, y : Float, width : Float, height : Float }
    -> Evg msg
image attrs { href, x, y, width, height } =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        baseAttrs =
            [ Svg.Attributes.xlinkHref href
            , Svg.Attributes.x (String.fromFloat x)
            , Svg.Attributes.y (String.fromFloat y)
            , Svg.Attributes.width (String.fromFloat width)
            , Svg.Attributes.height (String.fromFloat height)
            ]
    in
    Internal.element "image"
        (imageHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixString href |> Internal.mixFloat x |> Internal.mixFloat y |> Internal.mixFloat width |> Internal.mixFloat height)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        ([ ( "href", href ), ( "x", String.fromFloat x ), ( "y", String.fromFloat y ), ( "width", String.fromFloat width ), ( "height", String.fromFloat height ) ] ++ inspectable)
        a11yChildren
        defs


{-| Draws a free-form shape from a list of pen movements: place the pen
somewhere, then draw straight lines, curves, and arcs from point to point.
This is the most flexible shape and the one to reach for when rectangles,
circles, and polygons aren't enough. The movements themselves are described
with the [`Evg.Path`](Evg-Path) module.

You pass a list of subpaths. Most shapes need just one; several subpaths
make a compound shape, where an inner subpath can cut a hole in an outer one.

    import Evg.Path exposing (Path(..), PathSegment(..))

    -- A smooth arch drawn with a single curve:
    Evg.path
        [ Evg.fillStr "none", Evg.strokeStr "black" ]
        [ M ( 10, 80 )
            [ C ( 40, 10 ) ( 65, 10 ) ( 95, 80 ) ]
        ]

    -- A donut: an outer circle with a smaller
    -- circular hole cut out:
    Evg.path [ Evg.fillStr "gold" ]
        [ M ( 50, 10 )
            [ A 40 40 0 True True ( 50, 90 )
            , A 40 40 0 True True ( 50, 10 )
            ]
        , M ( 50, 25 )
            [ A 25 25 0 True False ( 50, 75 )
            , A 25 25 0 True False ( 50, 25 )
            ]
        ]

-}
path :
    List (Attribute { fill : Supported, stroke : Supported, opacity : Supported, marker : Supported, filter : Supported, transform : Supported, events : Supported } msg)
    -> List Evg.Path.Path
    -> Evg msg
path attrs subpaths =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable } =
            Internal.svgAttributes attrs

        pathStr =
            subpaths |> List.map Evg.Path.toString |> String.concat

        baseAttrs =
            [ Svg.Attributes.d pathStr ]
    in
    Internal.element "path"
        (pathHash_ |> Internal.mixInt (Internal.attrHash attrs) |> Internal.mixString pathStr)
        (baseAttrs ++ vdomAttrs)
        eventBuilders
        ownMatrix
        (( "d", pathStr ) :: inspectable)
        a11yChildren
        defs


{-| An element that draws nothing. Handy when a branch of your code has
nothing to show:

    if model.showMarker then
        Evg.circle [] { r = 4, center = model.position }

    else
        Evg.none

-}
none : Evg msg
none =
    Internal.Evg
        { content = Internal.TextContent ""
        , ownMatrix = Internal.identityMat
        , children = []
        , hash = 0
        , defs = []
        , attrs = []
        }


{-| Changes the message type of a drawing, just like `Html.map`. Use it to
embed a drawing whose event handlers produce one message type into a view
that uses another.
-}
map : (a -> b) -> Evg a -> Evg b
map fn evg =
    Internal.mapEvg fn evg


{-| Bundles several attributes into one, so you can name a reusable style
and apply it as a single attribute.

    buttonStyle =
        Evg.batch
            [ Evg.fillStr "blue"
            , Evg.strokeStr "navy"
            , Evg.strokeWidth 2
            ]

    view =
        Evg.rect
            [ buttonStyle ]
            { x = 0, y = 0, width = 80, height = 30 }

-}
batch : List (Attribute a msg) -> Attribute a msg
batch =
    Internal.Batch


{-| An attribute that does nothing. Useful as a placeholder or default.

    Evg.rect
        [ if highlighted then
            Evg.fillStr "yellow"

          else
            Evg.noAttr
        ]
        { x = 0, y = 0, width = 50, height = 50 }

-}
noAttr : Attribute a msg
noAttr =
    Internal.Batch []


{-| Conditionally include an attribute. When the condition is `False`,
produces `noAttr`.

    Evg.rect [ Evg.when isActive (Evg.fillStr "green") ]
        { x = 0, y = 0, width = 50, height = 50 }

-}
when : Bool -> Attribute a msg -> Attribute a msg
when condition attr =
    if condition then
        attr

    else
        Internal.Batch []


{-| Render the drawing to a string of SVG markup instead of `Html`. Takes
the same arguments as [`svg`](#svg), so a scene can be shown live or written
to an `.svg` file with the same code.

    Evg.toString []
        { width = 100, height = 100 }
        [ Evg.circle []
            { r = 40, center = ( 50, 50 ) }
        ]

The result is a complete SVG document: an `<svg>` root carrying the namespace
and viewBox, containing a `<circle>` element with the radius and center you
gave.

Useful for generating image files in scripts, snapshot-testing drawings, or
rendering on a server. A few things behave differently from live rendering:

  - Event handlers are dropped. Markup is a picture, not a program.
  - `Evg.Performance.lazy` shapes are computed (there is nothing to cache).
  - Raw nodes smuggled in from outside the library cannot be read back out
    of the virtual DOM, so they are omitted.

-}
toString : List (Attribute { viewBox : Supported, events : Supported } msg) -> { width : Float, height : Float } -> List (Evg msg) -> String
toString attrs dims children =
    let
        { inspectable, defs } =
            Internal.svgAttributes attrs

        allDefs =
            defs ++ Internal.collectDefs children

        viewBoxStr =
            "0 0 " ++ String.fromFloat dims.width ++ " " ++ String.fromFloat dims.height

        body =
            Internal.serializeDefs allDefs
                ++ String.concat (List.map Internal.serialize children)

        rootAttrs =
            ( "xmlns", "http://www.w3.org/2000/svg" )
                -- textPath, use, and image serialize an `xlink:href`, which a
                -- standalone .svg file can only parse if the xlink namespace
                -- is declared on the root. Add it only when actually used.
                :: (if String.contains "xlink:" body then
                        [ ( "xmlns:xlink", "http://www.w3.org/1999/xlink" ) ]

                    else
                        []
                   )
                ++ [ ( "viewBox", viewBoxStr )
                   , ( "width", String.fromFloat dims.width )
                   , ( "height", String.fromFloat dims.height )
                   ]
                ++ inspectable

        attrStr =
            rootAttrs
                |> Internal.dedupeAttrs
                |> List.map (\( k, v ) -> " " ++ k ++ "=\"" ++ v ++ "\"")
                |> String.concat
    in
    "<svg" ++ attrStr ++ ">" ++ body ++ "</svg>"



-- Filter attributes


{-| Applies an image effect to a shape after it is drawn, like blurring it or
giving it a drop shadow. Effects are built with the
[`Evg.Filter`](Evg-Filter) module.

    import Evg.Filter as Filter

    blur =
        Filter.sourceGraphic |> Filter.gaussianBlur 3

    -- A circle with softly blurred edges:
    Evg.circle
        [ Evg.filter blur ]
        { r = 50, center = ( 100, 100 ) }

-}
filter : Filter -> Attribute { a | filter : Supported } msg
filter f =
    case Internal.filterElem f of
        ( "", _ ) ->
            Internal.Batch []

        ( id, _ ) ->
            Internal.DefAttr
                (Internal.mixString id filterHash_)
                "filter"
                ("url(#" ++ id ++ ")")
                (Svg.Attributes.filter ("url(#" ++ id ++ ")"))
                (Def id (Internal.filterToEvg id f))


{-| Like `filter`, but with explicit control over the region the effect is
allowed to paint into.

Effects often need room beyond the shape's edges: a blur bleeds outward, a
drop shadow sits below and to the side. By default the region extends
slightly past the shape, which suits most cases. If an effect appears cut
off at a straight edge, widen the region with this function.

    Evg.text
        [ Evg.filterWithCoordinates
            (Evg.objectBoundingBox
                { x = -0.25
                , y = -0.25
                , width = 1.5
                , height = 1.6
                }
            )
            myFilter
        ]
        { x = 100, y = 50, anchor = Evg.Middle }
        "Hello"

-}
filterWithCoordinates : CoordinateSpace -> Filter -> Attribute { a | filter : Supported } msg
filterWithCoordinates space f =
    case Internal.filterPrimitives f of
        ( "", _ ) ->
            Internal.Batch []

        ( id, _ ) ->
            let
                spaceHash =
                    Internal.coordinateSpaceHash space

                fullId =
                    id ++ "-" ++ String.fromInt spaceHash

                filterEvg =
                    Internal.filterToEvgWith fullId
                        (Internal.coordinateSpaceAttrs Svg.Attributes.filterUnits space)
                        (Internal.coordinateSpaceData "filterUnits" space)
                        f
            in
            Internal.DefAttr
                (Internal.mixString fullId filterHash_)
                "filter"
                ("url(#" ++ fullId ++ ")")
                (Svg.Attributes.filter ("url(#" ++ fullId ++ ")"))
                (Def fullId filterEvg)



-- Attributes


{-| Paints the inside of a shape. The `Paint` value can be a solid color, a
gradient, or a repeating pattern; see [`Evg.Paint`](Evg-Paint) for how to
build them.

    import Evg.Paint as Paint

    Evg.rect
        [ Evg.fill
            (Paint.solid (Color.rgb255 0 128 255))
        ]
        { x = 0, y = 0, width = 100, height = 100 }

If you just want a color and are happy writing it as a string, `fillStr` is
shorter.

-}
fill : Paint -> Attribute { a | fill : Supported } msg
fill =
    paintAttr "fill" fillNoneHash_ fillHash_ fillUrlHash_ fillCtxFillHash_ fillCtxStrokeHash_ Svg.Attributes.fill


{-| Paints the stroke of a shape, the visible line drawn along its edge.
Like `fill`, it takes a `Paint` value, so outlines can be gradients or
patterns as well as solid colors.

    import Evg.Paint as Paint

    Evg.circle
        [ Evg.stroke
            (Paint.solid (Color.rgb255 0 0 0))
        ]
        { r = 40, center = ( 50, 50 ) }

-}
stroke : Paint -> Attribute { a | stroke : Supported } msg
stroke =
    paintAttr "stroke" strokeNoneHash_ strokeHash_ strokeUrlHash_ strokeCtxFillHash_ strokeCtxStrokeHash_ Svg.Attributes.stroke


{-| Colors the inside of a shape, using any color notation CSS understands:
named colors, hex codes, `rgb(...)`, and so on. Pass `"none"` to leave the
inside unpainted so anything behind the shape shows through.

    Evg.fillStr "red"

    Evg.fillStr "#FF0000"

    Evg.fillStr "none"

-}
fillStr : String -> Attribute { a | fill : Supported } msg
fillStr color =
    Internal.Attr (Internal.mixString color fillHash_) "fill" color (Svg.Attributes.fill color)


{-| Colors the stroke of a shape (the line along its edge), using any color
notation CSS understands. Pass `"none"` to remove the outline.

For gradient or patterned outlines use [`stroke`](#stroke). For dashes and
line endings see [`dashPattern`](#dashPattern) and the line cap and join
functions below.

    Evg.strokeStr "black"

    Evg.strokeStr "#FF0000"

-}
strokeStr : String -> Attribute { a | stroke : Supported } msg
strokeStr color =
    Internal.Attr (Internal.mixString color strokeHash_) "stroke" color (Svg.Attributes.stroke color)


{-| Sets how thick the stroke is drawn, in the same units as your
coordinates. The line straddles the shape's edge, half inside and half
outside.

    Evg.strokeWidth 2

-}
strokeWidth : Float -> Attribute { a | stroke : Supported } msg
strokeWidth w =
    Internal.Attr (Internal.mixFloat w strokeWidthHash_) "stroke-width" (String.fromFloat w) (Svg.Attributes.strokeWidth (String.fromFloat w))


{-| Makes a shape translucent. At `1.0` the shape is fully solid, at `0.5`
whatever is behind it shows through evenly, and at `0.0` it is invisible
(though still present, so it can still receive clicks).

    Evg.opacity 0.5

-}
opacity : Float -> Attribute { a | opacity : Supported } msg
opacity o =
    Internal.Attr (Internal.mixFloat o opacityHash_) "opacity" (String.fromFloat o) (Svg.Attributes.opacity (String.fromFloat o))


{-| Rounds the corners of a rectangle. The radius is the size of the
quarter-circle used at each corner, so bigger numbers give softer corners.
A radius of half the rectangle's height turns the short ends into
semicircles, giving a pill shape.

    Evg.rect [ Evg.fillStr "blue", Evg.cornerRadius 10 ]
        { x = 0, y = 0, width = 100, height = 60 }

-}
cornerRadius : Float -> Attribute { a | cornerRadius : Supported } msg
cornerRadius r =
    Internal.Attr (Internal.mixFloat r cornerRadiusHash_) "rx" (String.fromFloat r) (Svg.Attributes.rx (String.fromFloat r))


{-| Sets the text size. The number is the height of the font in your
coordinate units, so text scales along with the rest of the drawing.

    Evg.fontSize 24

-}
fontSize : Float -> Attribute { a | font : Supported } msg
fontSize size =
    Internal.Attr (Internal.mixFloat size fontSizeHash_) "font-size" (String.fromFloat size ++ "px") (Svg.Attributes.fontSize (String.fromFloat size ++ "px"))


{-| Sets the typeface for text. You can list multiple fonts separated by commas
as fallbacks, just like in CSS.

    Evg.fontFamily "'Helvetica Neue', Arial, sans-serif"

-}
fontFamily : String -> Attribute { a | font : Supported } msg
fontFamily family =
    Internal.Attr (Internal.mixString family fontFamilyHash_) "font-family" family (Svg.Attributes.fontFamily family)


{-| Adds a short text label to a shape for screen readers and tooltips.
Browsers will typically show this as a tooltip on hover.

    Evg.circle [ Evg.title "Connection status: online" ]
        { r = 5, center = ( 10, 10 ) }

-}
title : String -> Attribute a msg
title str =
    Internal.AccessibilityChild (Internal.mixString str titleHash_)
        (Internal.element "title" (Internal.mixString str titleHash_) [] [] Internal.identityMat [] [ Internal.textNode str ] [])


{-| Adds a longer text description to a shape for assistive technology.
Unlike `title` it never appears as a tooltip; it exists purely for screen
readers, so this is the place to describe what a complex graphic shows.

    Evg.group
        [ Evg.desc "Bar chart of monthly revenue" ]
        [ ... ]

-}
desc : String -> Attribute a msg
desc str =
    Internal.AccessibilityChild (Internal.mixString str descHash_)
        (Internal.element "desc" (Internal.mixString str descHash_) [] [] Internal.identityMat [] [ Internal.textNode str ] [])


{-| Assigns a CSS class name for external styling.

    Evg.rect [ Evg.class "highlight" ]
        { x = 0, y = 0, width = 100, height = 100 }

-}
class : String -> Attribute a msg
class name =
    Internal.Attr (Internal.mixString name classHash_) "class" name (Svg.Attributes.class name)


{-| Applies inline CSS directly to an element, as one string of
declarations.

    Evg.style "filter: drop-shadow(2px 2px 2px grey)"

-}
style : String -> Attribute a msg
style name =
    Internal.Attr (Internal.mixString name styleHash_) "style" name (Svg.Attributes.style name)



-- Stroke style


{-| Draws the stroke as dashes instead of a continuous line. The numbers
alternate between the length of a dash and the length of the gap after it,
repeating along the whole line.

    -- 10-unit dashes with 5-unit gaps:
    Evg.line
        [ Evg.strokeStr "black"
        , Evg.dashPattern [ 10, 5 ]
        ]
        ( 0, 50 )
        ( 200, 50 )

    -- Dot, gap, dash, gap, repeated:
    Evg.dashPattern [ 2, 5, 10, 5 ]

-}
dashPattern : List Float -> Attribute { a | stroke : Supported } msg
dashPattern values =
    let
        str =
            String.join " " (List.map String.fromFloat values)
    in
    Internal.Attr (List.foldl Internal.mixFloat dashArrayHash_ values) "stroke-dasharray" str (Svg.Attributes.strokeDasharray str)


{-| Slides the dash pattern along the line by the given distance. Animating
this value makes the dashes appear to march along the path, the classic
"marching ants" selection effect.

    Evg.dashOffset 5

-}
dashOffset : Float -> Attribute { a | stroke : Supported } msg
dashOffset value =
    Internal.Attr (Internal.mixFloat value dashOffsetHash_) "stroke-dashoffset" (String.fromFloat value) (Svg.Attributes.strokeDashoffset (String.fromFloat value))


{-| Gives lines rounded ends: a semicircle caps each endpoint, extending
half the stroke width past it. This is what makes thick lines look friendly
rather than abruptly chopped.
-}
linecapRound : Attribute { a | stroke : Supported } msg
linecapRound =
    Internal.Attr linecapRoundHash_ "stroke-linecap" "round" (Svg.Attributes.strokeLinecap "round")


{-| Gives lines square ends that extend half the stroke width past the
endpoint. Similar to the default flat end, but the line reaches slightly
further.
-}
linecapSquare : Attribute { a | stroke : Supported } msg
linecapSquare =
    Internal.Attr linecapSquareHash_ "stroke-linecap" "square" (Svg.Attributes.strokeLinecap "square")


{-| Cuts lines off flat exactly at the endpoint. This is the default.
-}
linecapButt : Attribute { a | stroke : Supported } msg
linecapButt =
    Internal.Attr linecapButtHash_ "stroke-linecap" "butt" (Svg.Attributes.strokeLinecap "butt")


{-| Rounds off the corners where two line segments meet, as if drawn with a
round pen.
-}
linejoinRound : Attribute { a | stroke : Supported } msg
linejoinRound =
    Internal.Attr linejoinRoundHash_ "stroke-linejoin" "round" (Svg.Attributes.strokeLinejoin "round")


{-| Flattens the corners where two line segments meet, as if the sharp point
had been snipped off.
-}
linejoinBevel : Attribute { a | stroke : Supported } msg
linejoinBevel =
    Internal.Attr linejoinBevelHash_ "stroke-linejoin" "bevel" (Svg.Attributes.strokeLinejoin "bevel")


{-| Keeps corners as sharp points. This is the default look.

Very acute angles would produce absurdly long spikes, so the `limit` caps
how far the point may extend (as a multiple of the stroke width) before the
corner falls back to a flattened bevel. A typical value is 4.

    Evg.linejoinMiter { limit = 4 }

-}
linejoinMiter : { limit : Float } -> Attribute { a | stroke : Supported } msg
linejoinMiter { limit } =
    Internal.Attr (Internal.mixFloat limit miterLimitHash_) "stroke-miterlimit" (String.fromFloat limit) (Svg.Attributes.strokeMiterlimit (String.fromFloat limit))


{-| Makes just the outline translucent, leaving the fill untouched. `0.0` is
invisible and `1.0` fully solid.
-}
strokeOpacity : Float -> Attribute { a | stroke : Supported } msg
strokeOpacity value =
    Internal.Attr (Internal.mixFloat value strokeOpacityHash_) "stroke-opacity" (String.fromFloat value) (Svg.Attributes.strokeOpacity (String.fromFloat value))


{-| Makes just the interior fill translucent, leaving the outline untouched.
`0.0` is invisible and `1.0` fully solid.
-}
fillOpacity : Float -> Attribute { a | fill : Supported } msg
fillOpacity value =
    Internal.Attr (Internal.mixFloat value fillOpacityHash_) "fill-opacity" (String.fromFloat value) (Svg.Attributes.fillOpacity (String.fromFloat value))


{-| Changes which regions count as "inside" a self-overlapping shape.

When a path crosses over itself, or one subpath sits within another, the
browser has to decide which enclosed regions get filled. With this rule, a
region is filled only if a line drawn from it to the outside crosses the
shape's edge an odd number of times. In practice: overlapping areas become
unfilled holes.

-}
fillRuleEvenOdd : Attribute { a | fill : Supported } msg
fillRuleEvenOdd =
    Internal.Attr fillRuleEvenOddHash_ "fill-rule" "evenodd" (Svg.Attributes.fillRule "evenodd")


{-| The default rule for deciding which regions of a self-overlapping shape
get filled: a region is filled unless the strokes enclosing it wind in
opposite directions and cancel out. In practice: overlaps stay filled, and
you cut holes by drawing the inner subpath in the opposite direction from
the outer one.
-}
fillRuleNonZero : Attribute { a | fill : Supported } msg
fillRuleNonZero =
    Internal.Attr fillRuleNonZeroHash_ "fill-rule" "nonzero" (Svg.Attributes.fillRule "nonzero")



-- Internal helpers
-- Precomputed tag hash constants


gHash_ : Int
gHash_ =
    166908


lineHash_ : Int
lineHash_ =
    677142455


rectHash_ : Int
rectHash_ =
    676845927


circleHash_ : Int
circleHash_ =
    -1896205791


ellipseHash_ : Int
ellipseHash_ =
    -656157507


polygonHash_ : Int
polygonHash_ =
    1854525653


polylineHash_ : Int
polylineHash_ =
    1655756237


textHash_ : Int
textHash_ =
    676909464


imageHash_ : Int
imageHash_ =
    -486264968


pathHash_ : Int
pathHash_ =
    676786560



-- Paint rendering helpers


paintAttr : String -> Int -> Int -> Int -> Int -> Int -> (String -> VirtualDom.Attribute msg) -> Internal.Paint -> Attribute a msg
paintAttr name noneH baseHash urlHash ctxFillH ctxStrokeH svgAttr paint =
    case paint of
        Internal.PaintNone ->
            Internal.Attr noneH name "none" (svgAttr "none")

        Internal.PaintSolid color ->
            let
                str =
                    Color.toCssString color
            in
            Internal.Attr (Internal.mixColor color baseHash) name str (svgAttr str)

        Internal.PaintStr str ->
            Internal.Attr (Internal.mixString str baseHash) name str (svgAttr str)

        Internal.PaintContextFill ->
            Internal.Attr ctxFillH name "context-fill" (svgAttr "context-fill")

        Internal.PaintContextStroke ->
            Internal.Attr ctxStrokeH name "context-stroke" (svgAttr "context-stroke")

        Internal.PaintLinearGradient start end stops ->
            let
                hash =
                    linearGradientHash start end stops

                id =
                    "e" ++ String.fromInt hash
            in
            Internal.DefAttr (Internal.mixInt hash urlHash) name ("url(#" ++ id ++ ")") (svgAttr ("url(#" ++ id ++ ")")) (Def id (renderLinearGradient id start end stops))

        Internal.PaintLinearGradientCS space start end stops ->
            let
                hash =
                    Internal.mixInt (Internal.coordinateSpaceHash space) (linearGradientHash start end stops)

                id =
                    "e" ++ String.fromInt hash
            in
            Internal.DefAttr (Internal.mixInt hash urlHash) name ("url(#" ++ id ++ ")") (svgAttr ("url(#" ++ id ++ ")")) (Def id (renderLinearGradientCS id space start end stops))

        Internal.PaintRadialGradient center radius stops ->
            let
                hash =
                    radialGradientHash center radius stops

                id =
                    "e" ++ String.fromInt hash
            in
            Internal.DefAttr (Internal.mixInt hash urlHash) name ("url(#" ++ id ++ ")") (svgAttr ("url(#" ++ id ++ ")")) (Def id (renderRadialGradient id center radius stops))

        Internal.PaintRadialGradientCS space center radius stops ->
            let
                hash =
                    Internal.mixInt (Internal.coordinateSpaceHash space) (radialGradientHash center radius stops)

                id =
                    "e" ++ String.fromInt hash
            in
            Internal.DefAttr (Internal.mixInt hash urlHash) name ("url(#" ++ id ++ ")") (svgAttr ("url(#" ++ id ++ ")")) (Def id (renderRadialGradientCS id space center radius stops))

        Internal.PaintPattern attrs size content ->
            let
                hash =
                    patternHash attrs size

                id =
                    "e" ++ String.fromInt hash
            in
            Internal.DefAttr (Internal.mixInt hash urlHash) name ("url(#" ++ id ++ ")") (svgAttr ("url(#" ++ id ++ ")")) (Def id (renderPattern id attrs size content))

        Internal.PaintPatternCS attrs space content ->
            let
                hash =
                    Internal.mixInt (Internal.coordinateSpaceHash space) (patternHash attrs { width = 0, height = 0 })

                id =
                    "e" ++ String.fromInt hash
            in
            Internal.DefAttr (Internal.mixInt hash urlHash) name ("url(#" ++ id ++ ")") (svgAttr ("url(#" ++ id ++ ")")) (Def id (renderPatternCS id attrs space content))


linearGradientHash : ( Float, Float ) -> ( Float, Float ) -> List Internal.Stop -> Int
linearGradientHash ( x1, y1 ) ( x2, y2 ) stops =
    lgHash_
        |> Internal.mixFloat x1
        |> Internal.mixFloat y1
        |> Internal.mixFloat x2
        |> Internal.mixFloat y2
        |> stopsHash stops


radialGradientHash : ( Float, Float ) -> Float -> List Internal.Stop -> Int
radialGradientHash ( cx, cy ) r stops =
    rgHash_
        |> Internal.mixFloat cx
        |> Internal.mixFloat cy
        |> Internal.mixFloat r
        |> stopsHash stops


stopsHash : List Internal.Stop -> Int -> Int
stopsHash stops acc =
    List.foldl
        (\s a ->
            case s of
                Internal.ColorStop offset color op ->
                    a
                        |> Internal.mixFloat offset
                        |> Internal.mixColor color
                        |> Internal.mixFloat op

                Internal.StrStop offset str op ->
                    a
                        |> Internal.mixFloat offset
                        |> Internal.mixString str
                        |> Internal.mixFloat op
        )
        acc
        stops


patternHash : List (Internal.Attribute {} Never) -> { width : Float, height : Float } -> Int
patternHash attrs size =
    patHash_
        |> Internal.mixInt (Internal.attrHash attrs)
        |> Internal.mixFloat size.width
        |> Internal.mixFloat size.height


renderLinearGradient : String -> ( Float, Float ) -> ( Float, Float ) -> List Internal.Stop -> Internal.Evg msg
renderLinearGradient id ( x1, y1 ) ( x2, y2 ) stops =
    let
        baseAttrs =
            [ Svg.Attributes.id id, Svg.Attributes.x1 (String.fromFloat x1), Svg.Attributes.y1 (String.fromFloat y1), Svg.Attributes.x2 (String.fromFloat x2), Svg.Attributes.y2 (String.fromFloat y2) ]
    in
    Internal.Evg
        { content = Internal.Tag "linearGradient" baseAttrs []
        , ownMatrix = Internal.identityMat
        , children = List.map stopToEvg stops
        , hash = 0
        , defs = []
        , attrs = [ ( "id", id ), ( "x1", String.fromFloat x1 ), ( "y1", String.fromFloat y1 ), ( "x2", String.fromFloat x2 ), ( "y2", String.fromFloat y2 ) ]
        }


renderRadialGradient : String -> ( Float, Float ) -> Float -> List Internal.Stop -> Internal.Evg msg
renderRadialGradient id ( cx, cy ) r stops =
    let
        baseAttrs =
            [ Svg.Attributes.id id, Svg.Attributes.cx (String.fromFloat cx), Svg.Attributes.cy (String.fromFloat cy), Svg.Attributes.r (String.fromFloat r) ]
    in
    Internal.Evg
        { content = Internal.Tag "radialGradient" baseAttrs []
        , ownMatrix = Internal.identityMat
        , children = List.map stopToEvg stops
        , hash = 0
        , defs = []
        , attrs = [ ( "id", id ), ( "cx", String.fromFloat cx ), ( "cy", String.fromFloat cy ), ( "r", String.fromFloat r ) ]
        }


renderLinearGradientCS : String -> Internal.CoordinateSpace -> ( Float, Float ) -> ( Float, Float ) -> List Internal.Stop -> Internal.Evg msg
renderLinearGradientCS id space ( x1, y1 ) ( x2, y2 ) stops =
    let
        baseAttrs =
            [ Svg.Attributes.id id, Svg.Attributes.x1 (String.fromFloat x1), Svg.Attributes.y1 (String.fromFloat y1), Svg.Attributes.x2 (String.fromFloat x2), Svg.Attributes.y2 (String.fromFloat y2) ] ++ Internal.coordinateSpaceAttrs Svg.Attributes.gradientUnits space
    in
    Internal.Evg
        { content = Internal.Tag "linearGradient" baseAttrs []
        , ownMatrix = Internal.identityMat
        , children = List.map stopToEvg stops
        , hash = 0
        , defs = []
        , attrs = [ ( "id", id ), ( "x1", String.fromFloat x1 ), ( "y1", String.fromFloat y1 ), ( "x2", String.fromFloat x2 ), ( "y2", String.fromFloat y2 ) ]
        }


renderRadialGradientCS : String -> Internal.CoordinateSpace -> ( Float, Float ) -> Float -> List Internal.Stop -> Internal.Evg msg
renderRadialGradientCS id space ( cx, cy ) r stops =
    let
        baseAttrs =
            [ Svg.Attributes.id id, Svg.Attributes.cx (String.fromFloat cx), Svg.Attributes.cy (String.fromFloat cy), Svg.Attributes.r (String.fromFloat r) ] ++ Internal.coordinateSpaceAttrs Svg.Attributes.gradientUnits space
    in
    Internal.Evg
        { content = Internal.Tag "radialGradient" baseAttrs []
        , ownMatrix = Internal.identityMat
        , children = List.map stopToEvg stops
        , hash = 0
        , defs = []
        , attrs = [ ( "id", id ), ( "cx", String.fromFloat cx ), ( "cy", String.fromFloat cy ), ( "r", String.fromFloat r ) ]
        }


stopToEvg : Internal.Stop -> Internal.Evg msg
stopToEvg s =
    let
        ( offsetStr, colorStr, opStr ) =
            case s of
                Internal.ColorStop offset color op ->
                    ( String.fromFloat offset, Color.toCssString color, String.fromFloat op )

                Internal.StrStop offset str op ->
                    ( String.fromFloat offset, str, String.fromFloat op )
    in
    Internal.Evg
        { content = Internal.Tag "stop" [ Svg.Attributes.offset offsetStr, Svg.Attributes.stopColor colorStr, Svg.Attributes.stopOpacity opStr ] []
        , ownMatrix = Internal.identityMat
        , children = []
        , hash = 0
        , defs = []
        , attrs = [ ( "offset", offsetStr ), ( "stop-color", colorStr ), ( "stop-opacity", opStr ) ]
        }


renderPattern : String -> List (Internal.Attribute {} Never) -> { width : Float, height : Float } -> List (Internal.Evg Never) -> Internal.Evg msg
renderPattern id attrs size content =
    let
        baseAttrs =
            [ Svg.Attributes.id id
            , Svg.Attributes.width (String.fromFloat size.width)
            , Svg.Attributes.height (String.fromFloat size.height)
            , Svg.Attributes.patternUnits "userSpaceOnUse"
            , Svg.Attributes.patternContentUnits "userSpaceOnUse"
            ]
                ++ patternExtraAttrs attrs
    in
    Internal.Evg
        { content = Internal.Tag "pattern" baseAttrs []
        , ownMatrix = Internal.identityMat
        , children = List.map (Internal.mapEvg never) content
        , hash = 0
        , defs = []
        , attrs =
            [ ( "id", id )
            , ( "width", String.fromFloat size.width )
            , ( "height", String.fromFloat size.height )
            , ( "patternUnits", "userSpaceOnUse" )
            , ( "patternContentUnits", "userSpaceOnUse" )
            ]
                ++ patternExtraData attrs
        }


renderPatternCS : String -> List (Internal.Attribute {} Never) -> Internal.CoordinateSpace -> List (Internal.Evg Never) -> Internal.Evg msg
renderPatternCS id attrs space content =
    let
        baseAttrs =
            Svg.Attributes.id id
                :: Internal.coordinateSpaceAttrs Svg.Attributes.patternUnits space
                ++ [ Svg.Attributes.patternContentUnits (coordinateSpaceUnitStr space) ]
                ++ patternExtraAttrs attrs
    in
    Internal.Evg
        { content = Internal.Tag "pattern" baseAttrs []
        , ownMatrix = Internal.identityMat
        , children = List.map (Internal.mapEvg never) content
        , hash = 0
        , defs = []
        , attrs =
            ( "id", id )
                :: Internal.coordinateSpaceData "patternUnits" space
                ++ [ ( "patternContentUnits", coordinateSpaceUnitStr space ) ]
                ++ patternExtraData attrs
        }


coordinateSpaceUnitStr : Internal.CoordinateSpace -> String
coordinateSpaceUnitStr space =
    case space of
        Internal.ObjectBoundingBox _ ->
            "objectBoundingBox"

        Internal.UserSpace _ ->
            "userSpaceOnUse"


patternExtraAttrs : List (Internal.Attribute {} Never) -> List (VirtualDom.Attribute msg)
patternExtraAttrs attrs =
    let
        go remaining accAttrs accTransforms =
            case remaining of
                [] ->
                    case accTransforms of
                        [] ->
                            List.reverse accAttrs

                        _ ->
                            Svg.Attributes.patternTransform (String.join " " (List.reverse accTransforms)) :: List.reverse accAttrs

                (Internal.Attr _ _ _ a) :: rest ->
                    go rest (VirtualDom.mapAttribute never a :: accAttrs) accTransforms

                (Internal.TransformAttr _ str _) :: rest ->
                    go rest accAttrs (str :: accTransforms)

                (Internal.EventAttr _ _) :: rest ->
                    go rest accAttrs accTransforms

                (Internal.DefAttr _ _ _ a _) :: rest ->
                    go rest (VirtualDom.mapAttribute never a :: accAttrs) accTransforms

                (Internal.AccessibilityChild _ _) :: rest ->
                    go rest accAttrs accTransforms

                (Internal.Batch batchAttrs) :: rest ->
                    go (batchAttrs ++ rest) accAttrs accTransforms

                (Internal.TextPathChild _ _ _) :: rest ->
                    go rest accAttrs accTransforms
    in
    go attrs [] []


{-| The data equivalent of `patternExtraAttrs`, for the inspectable `attrs`
field that `toString` reads. Mirrors it exactly so serialization matches the
rendered pattern.
-}
patternExtraData : List (Internal.Attribute {} Never) -> List ( String, String )
patternExtraData attrs =
    let
        go remaining accAttrs accTransforms =
            case remaining of
                [] ->
                    case accTransforms of
                        [] ->
                            List.reverse accAttrs

                        _ ->
                            ( "patternTransform", String.join " " (List.reverse accTransforms) ) :: List.reverse accAttrs

                (Internal.Attr _ key value _) :: rest ->
                    go rest (( key, value ) :: accAttrs) accTransforms

                (Internal.TransformAttr _ str _) :: rest ->
                    go rest accAttrs (str :: accTransforms)

                (Internal.EventAttr _ _) :: rest ->
                    go rest accAttrs accTransforms

                (Internal.DefAttr _ key value _ _) :: rest ->
                    go rest (( key, value ) :: accAttrs) accTransforms

                (Internal.AccessibilityChild _ _) :: rest ->
                    go rest accAttrs accTransforms

                (Internal.Batch batchAttrs) :: rest ->
                    go (batchAttrs ++ rest) accAttrs accTransforms

                (Internal.TextPathChild _ _ _) :: rest ->
                    go rest accAttrs accTransforms
    in
    go attrs [] []



-- Precomputed attribute hash constants


fillHash_ : Int
fillHash_ =
    677453386


strokeHash_ : Int
strokeHash_ =
    1938098789


strokeWidthHash_ : Int
strokeWidthHash_ =
    -1219659557


opacityHash_ : Int
opacityHash_ =
    -1465780020


cornerRadiusHash_ : Int
cornerRadiusHash_ =
    84188576


fontSizeHash_ : Int
fontSizeHash_ =
    -69154159


fontFamilyHash_ : Int
fontFamilyHash_ =
    1718893322


titleHash_ : Int
titleHash_ =
    -490512739


descHash_ : Int
descHash_ =
    677385522


classHash_ : Int
classHash_ =
    -476638269


styleHash_ : Int
styleHash_ =
    -503454451


dashArrayHash_ : Int
dashArrayHash_ =
    243421572


dashOffsetHash_ : Int
dashOffsetHash_ =
    -1113053220


linecapRoundHash_ : Int
linecapRoundHash_ =
    1058227875


linecapSquareHash_ : Int
linecapSquareHash_ =
    -1737383556


linecapButtHash_ : Int
linecapButtHash_ =
    864934254


linejoinRoundHash_ : Int
linejoinRoundHash_ =
    -1622331127


linejoinBevelHash_ : Int
linejoinBevelHash_ =
    -1637521043


miterLimitHash_ : Int
miterLimitHash_ =
    -274614851


strokeOpacityHash_ : Int
strokeOpacityHash_ =
    -801583284


fillOpacityHash_ : Int
fillOpacityHash_ =
    496674745


fillRuleEvenOddHash_ : Int
fillRuleEvenOddHash_ =
    -1551409005


fillRuleNonZeroHash_ : Int
fillRuleNonZeroHash_ =
    972049067


fillNoneHash_ : Int
fillNoneHash_ =
    1984853460


fillUrlHash_ : Int
fillUrlHash_ =
    -1717729310


fillCtxFillHash_ : Int
fillCtxFillHash_ =
    1581062175


fillCtxStrokeHash_ : Int
fillCtxStrokeHash_ =
    -226969656


strokeNoneHash_ : Int
strokeNoneHash_ =
    169084409


strokeUrlHash_ : Int
strokeUrlHash_ =
    -1319456653


strokeCtxFillHash_ : Int
strokeCtxFillHash_ =
    1058951230


strokeCtxStrokeHash_ : Int
strokeCtxStrokeHash_ =
    349795705


filterHash_ : Int
filterHash_ =
    -1802320473


lgHash_ : Int
lgHash_ =
    1673607882


rgHash_ : Int
rgHash_ =
    -1984607316


patHash_ : Int
patHash_ =
    1572663005
