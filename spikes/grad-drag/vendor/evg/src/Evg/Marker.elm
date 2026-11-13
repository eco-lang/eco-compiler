module Evg.Marker exposing
    ( Marker, marker, markerUserSpace, Orientation(..)
    , markerStart, markerMid, markerEnd
    )

{-| Stamp small symbols, like arrowheads or dots, onto the ends and corners
of lines.

A marker is a little reusable drawing that gets stamped at chosen points of
a line, polyline, or path: at its start, at its end, or at each corner along
the way. The classic example is an arrowhead at the end of a line, but a
marker can be any shape you like.

    import Evg
    import Evg.Marker as Marker

    -- A triangular arrowhead:
    arrow =
        Marker.marker []
            { width = 10
            , height = 10
            , refX = 10
            , refY = 5
            }
            Marker.AutoOrientation
            (Evg.polygon [ Evg.fillStr "black" ]
                [ ( 0, 0 ), ( 10, 5 ), ( 0, 10 ) ]
            )

    -- A horizontal line ending in the arrowhead:
    Evg.line [ Marker.markerEnd arrow ]
        ( 20, 50 )
        ( 180, 50 )

![marker arrow example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/marker-arrow-example.svg)


# Creating Markers

@docs Marker, marker, markerUserSpace, Orientation


# Applying Markers

@docs markerStart, markerMid, markerEnd

-}

import Evg
import Evg.Internal as Internal exposing (Attribute(..), Def(..), Supported)
import Svg.Attributes
import VirtualDom


{-| A small reusable drawing that can be stamped at the start, the corners,
or the end of lines and paths. Build one with `marker` or `markerUserSpace`,
then attach it with `markerStart`, `markerMid`, or `markerEnd`.
-}
type Marker msg
    = Marker Int (Internal.Evg msg)


{-| Controls how the marker turns to follow the line it sits on.

  - `AutoOrientation`: the marker rotates to point along the direction the
    line is traveling at that point. This is what you want for arrowheads.
  - `AutoStartReverse`: like `AutoOrientation`, except a marker placed at the
    start of the line points backward, away from the line. Useful for a
    double-headed arrow built from one arrowhead shape.
  - `Fixed angle`: the marker is always drawn turned clockwise by this many
    degrees, regardless of the line's direction. `Fixed 0` keeps it upright.

-}
type Orientation
    = AutoOrientation
    | AutoStartReverse
    | Fixed Float


{-| Creates a marker that grows and shrinks with the thickness of the line
it decorates. A marker given `width = 10` on a line drawn 2 units thick is
stamped 20 units wide, so arrowheads stay in proportion to their line. This
is usually what you want.

The record describes the marker's own little canvas. `width` and `height`
are its size, and `refX` and `refY` are the anchor point: the spot inside the
marker that lands exactly on the line's endpoint or corner. In the arrowhead
example below, the anchor `(10, 5)` is the arrow's tip, so the tip touches
the very end of the line.

The first argument is a list of extra attributes for the marker's canvas.
You can pass a `viewBox` to give the marker's content its own convenient
coordinate system, or `preserveAspectRatio` to control how it stretches.

    -- A simple arrowhead whose tip lands
    -- on the line's end:
    Marker.marker []
        { width = 10, height = 10, refX = 10, refY = 5 }
        Marker.AutoOrientation
        (Evg.polygon [ Evg.fillStr "black" ]
            [ ( 0, 0 ), ( 10, 5 ), ( 0, 10 ) ]
        )

    -- The same arrowhead, drawn in 0 to 100
    -- coordinates for convenience:
    Marker.marker [ Advanced.viewBox 0 0 100 100 ]
        { width = 10
        , height = 10
        , refX = 100
        , refY = 50
        }
        Marker.AutoOrientation
        (Evg.polygon [ Evg.fillStr "black" ]
            [ ( 0, 0 ), ( 100, 50 ), ( 0, 100 ) ]
        )

-}
marker :
    List (Evg.Attribute { viewBox : Evg.Supported, preserveAspectRatio : Evg.Supported } Never)
    -> { width : Float, height : Float, refX : Float, refY : Float }
    -> Orientation
    -> Internal.Evg msg
    -> Marker msg
marker attrs config orientation content =
    buildMarker attrs "strokeWidth" config orientation content


{-| Creates a marker with a fixed size. Unlike `marker`, its size does not
follow the thickness of the line it decorates: a marker given `width = 10`
is always stamped 10 units wide, whether the line is hairline-thin or very
thick. Use this when markers should stay the same size across lines of
different weights.

    -- A small red dot, always 8 units across:
    Marker.markerUserSpace []
        { width = 8, height = 8, refX = 4, refY = 4 }
        Marker.AutoOrientation
        (Evg.circle [ Evg.fillStr "red" ]
            { r = 4, center = ( 4, 4 ) }
        )

-}
markerUserSpace :
    List (Evg.Attribute { viewBox : Evg.Supported, preserveAspectRatio : Evg.Supported } Never)
    -> { width : Float, height : Float, refX : Float, refY : Float }
    -> Orientation
    -> Internal.Evg msg
    -> Marker msg
markerUserSpace attrs config orientation content =
    buildMarker attrs "userSpaceOnUse" config orientation content


buildMarker :
    List (Internal.Attribute a Never)
    -> String
    -> { width : Float, height : Float, refX : Float, refY : Float }
    -> Orientation
    -> Internal.Evg msg
    -> Marker msg
buildMarker attrs units config orientation content =
    let
        orientStr =
            case orientation of
                AutoOrientation ->
                    "auto"

                AutoStartReverse ->
                    "auto-start-reverse"

                Fixed angle ->
                    String.fromFloat angle

        hash =
            markerHash_
                |> Internal.mixFloat config.width
                |> Internal.mixFloat config.height
                |> Internal.mixFloat config.refX
                |> Internal.mixFloat config.refY
                |> Internal.mixString orientStr
                |> Internal.mixString units
                |> Internal.mixInt (Internal.attrHash attrs)

        id =
            "e" ++ String.fromInt hash

        markerEvg =
            Internal.Evg
                { content =
                    Internal.Tag "marker"
                        ([ Svg.Attributes.id id
                         , Svg.Attributes.markerWidth (String.fromFloat config.width)
                         , Svg.Attributes.markerHeight (String.fromFloat config.height)
                         , Svg.Attributes.refX (String.fromFloat config.refX)
                         , Svg.Attributes.refY (String.fromFloat config.refY)
                         , Svg.Attributes.orient orientStr
                         , Svg.Attributes.markerUnits units
                         ]
                            ++ markerExtraAttrs attrs
                        )
                        []
                , ownMatrix = Internal.identityMat
                , children = [ content ]
                , hash = hash
                , defs = []
                , attrs =
                    [ ( "id", id )
                    , ( "markerWidth", String.fromFloat config.width )
                    , ( "markerHeight", String.fromFloat config.height )
                    , ( "refX", String.fromFloat config.refX )
                    , ( "refY", String.fromFloat config.refY )
                    , ( "orient", orientStr )
                    , ( "markerUnits", units )
                    ]
                }
    in
    Marker hash markerEvg


{-| Stamps a marker at the first point of a line, polyline, or path.

    Evg.polyline [ Marker.markerStart dot ]
        [ ( 10, 10 ), ( 90, 90 ) ]

-}
markerStart : Marker msg -> Attribute { a | marker : Supported } msg
markerStart (Marker hash node) =
    let
        id =
            "e" ++ String.fromInt hash
    in
    DefAttr
        (Internal.mixInt hash msHash_)
        "marker-start"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.markerStart ("url(#" ++ id ++ ")"))
        (Def id node)


{-| Stamps a marker at every corner of a polyline or path between the first
and last points. In the example below, the dot appears only at the middle
bend, not at either end.

    Evg.polyline [ Marker.markerMid dot ]
        [ ( 10, 10 ), ( 50, 80 ), ( 90, 10 ) ]

![markerMid example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/marker-mid-example.svg)

-}
markerMid : Marker msg -> Attribute { a | marker : Supported } msg
markerMid (Marker hash node) =
    let
        id =
            "e" ++ String.fromInt hash
    in
    DefAttr
        (Internal.mixInt hash mmHash_)
        "marker-mid"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.markerMid ("url(#" ++ id ++ ")"))
        (Def id node)


{-| Stamps a marker at the last point of a line, polyline, or path. This is
the usual place for an arrowhead.

    Evg.line [ Marker.markerEnd arrow ]
        ( 20, 50 )
        ( 180, 50 )

-}
markerEnd : Marker msg -> Attribute { a | marker : Supported } msg
markerEnd (Marker hash node) =
    let
        id =
            "e" ++ String.fromInt hash
    in
    DefAttr
        (Internal.mixInt hash meHash_)
        "marker-end"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.markerEnd ("url(#" ++ id ++ ")"))
        (Def id node)


markerExtraAttrs : List (Internal.Attribute a Never) -> List (VirtualDom.Attribute msg)
markerExtraAttrs attrs =
    List.filterMap
        (\attr ->
            case attr of
                Attr _ _ _ a ->
                    Just (VirtualDom.mapAttribute never a)

                DefAttr _ _ _ a _ ->
                    Just (VirtualDom.mapAttribute never a)

                _ ->
                    Nothing
        )
        attrs



-- Precomputed hash constants


markerHash_ : Int
markerHash_ =
    -2064048697


msHash_ : Int
msHash_ =
    5173945


mmHash_ : Int
mmHash_ =
    5173927


meHash_ : Int
meHash_ =
    5173935
