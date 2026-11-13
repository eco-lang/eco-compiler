module Evg.Path exposing
    ( Path(..), PathSegment(..)
    , RelativeSegment
    , m, l, h, v, c, s, q, t, a
    , close, endPoint, startPoint
    , Segment(..), toSegments, fromSegments
    , pathLength, interpolate
    , toString
    )

{-| Draw arbitrary shapes out of straight lines and curves.

A path is a shape drawn by moving an imaginary pen: you place it somewhere,
then draw straight lines and curves from point to point. Most shapes that
aren't simple rectangles or circles (icons, chart lines, arrows, country
outlines) end up being paths.

Every point is a pair of `( x, y )` numbers measured from the top-left
corner of the drawing: x grows to the right, y grows downward.

This module offers two ways of describing the same shape:

  - `Path` lists the pen movements one after another, much like you would
    describe the shape out loud ("start here, line to there, curve over to
    there"). Use it to construct paths.
  - `Segment` describes the shape as a list of independent pieces, each
    knowing its own start and end points. Use it for computations like
    measuring a path or finding points along it.

You can convert freely between them with `toSegments` and `fromSegments`.


# Path Commands

Paths are built from a starting point and a sequence of drawing commands.
Uppercase constructors (`M`, `L`, `C`, and so on) use absolute coordinates:
"draw a line to the point (90, 90)". Lowercase functions (`m`, `l`, `c`,
and so on) use coordinates relative to wherever the pen currently is:
"draw a line 80 units to the right".

    import Evg.Path exposing (Path(..), PathSegment(..))


    -- Absolute: a triangle with its tip at the top
    triangle =
        M ( 50, 10 ) [ L ( 90, 90 ), L ( 10, 90 ), Z ]

    -- Relative: a square starting at (10, 10),
    -- each side 80 units
    square =
        M ( 10, 10 )
            [ l ( 80, 0 )
            , l ( 0, 80 )
            , l ( -80, 0 )
            , Z
            ]

@docs Path, PathSegment


## Relative Commands

These produce path segments with coordinates relative to the current point.

@docs RelativeSegment
@docs m, l, h, v, c, s, q, t, a


## Utilities

@docs close, endPoint, startPoint


# Geometric Segments

A `Segment` represents a single piece of a path with explicit start and end
points. This is more convenient for computations (measuring length, sampling
points, transforming) since you don't need to track the "current point" state.

@docs Segment, toSegments, fromSegments


## Measurement and Sampling

@docs pathLength, interpolate


# Rendering

@docs toString

-}


{-| A single stroke of the pen: first lift the pen and put it down somewhere,
then draw a sequence of lines and curves from there.

  - `M point segments` places the pen at an absolute position, then draws
  - `MRelative offset segments` places the pen relative to wherever the
    previous stroke ended, then draws

Passing several `Path` values to `Evg.path` draws them all as one shape.
Since the pen lifts between strokes, the pieces can be disconnected, and a
piece drawn inside another one cuts a hole in it. That is how you draw a
donut: one stroke for the outer circle, another for the inner one.

-}
type Path
    = M ( Float, Float ) (List PathSegment)
    | MRelative ( Float, Float ) (List PathSegment)


{-| The individual pen movements, each using absolute coordinates. For every
one of these there is also a lowercase function (`l`, `h`, `c`, and so on)
that does the same thing with coordinates relative to the current pen position.

  - `L point` draws a straight line to the point
  - `H x` draws a horizontal line to the given x coordinate
  - `V y` draws a vertical line to the given y coordinate
  - `C cp1 cp2 end` draws a cubic curve; the two control points each pull
    their end of the line toward themselves, so the curve can bend one way
    and then the other, like an S
  - `S cp2 end` continues a previous curve smoothly, so you only supply the
    second control point
  - `Q cp end` draws a quadratic curve, a simple bow bent toward one
    control point
  - `T end` continues a previous quadratic curve smoothly, needing no
    control point at all
  - `A rx ry rotation largeArc sweep end` draws an arc, a slice of an
    ellipse outline, good for pie charts and rounded corners
  - `Z` closes the shape with a straight line back to where the stroke began

The straight line commands look like this: `L` heads directly from the
current position to the point you give it.

![a straight line from a start point to an end point](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-l.svg)

For details and pictures of each curve type, see the matching lowercase
functions below.

-}
type PathSegment
    = L ( Float, Float )
    | H Float
    | V Float
    | C ( Float, Float ) ( Float, Float ) ( Float, Float )
    | S ( Float, Float ) ( Float, Float )
    | Q ( Float, Float ) ( Float, Float )
    | T ( Float, Float )
    | A Float Float Float Bool Bool ( Float, Float )
    | Z
    | Rel RelativeSegment


{-| A drawing command whose coordinates are measured from the current pen
position rather than from the top-left corner. You don't build these
directly: the lowercase functions in this module ([`l`](#l), [`h`](#h),
[`c`](#c), and so on) create them for you, already wrapped in a
`PathSegment` via its `Rel` variant.
-}
type RelativeSegment
    = RL ( Float, Float )
    | RH Float
    | RV Float
    | RC ( Float, Float ) ( Float, Float ) ( Float, Float )
    | RS ( Float, Float ) ( Float, Float )
    | RQ ( Float, Float ) ( Float, Float )
    | RT ( Float, Float )
    | RA Float Float Float Bool Bool ( Float, Float )



-- Relative command constructors


{-| Lift the pen and put it down again at an offset from where the previous
stroke ended, starting a new stroke there. Nothing is drawn by the move
itself.

    m ( 10, 20 ) [ l ( 50, 0 ), l ( 0, 50 ), Z ]

This starts a new triangle 10 units right and 20 units down from wherever
the previous stroke finished.

-}
m : ( Float, Float ) -> (List PathSegment -> Path)
m offset =
    MRelative offset


{-| Draw a straight line from the current pen position, offset by the given
amount. The first number moves right (negative moves left), the second moves
down (negative moves up).

![a straight line from a start point to an end point](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-l.svg)

    l ( 80, 0 ) -- 80 right

    l ( 0, -40 ) -- 40 up

-}
l : ( Float, Float ) -> PathSegment
l offset =
    Rel (RL offset)


{-| Draw a horizontal line from the current pen position. Positive amounts
go right, negative ones go left. It is a convenient shorthand for `l` when
you know the line should be perfectly level.

The picture shows a horizontal line followed by a vertical one:

![a horizontal line followed by a vertical line, forming a corner](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-h-v.svg)

    h 100 -- 100 units right

    h -50 -- 50 units left

-}
h : Float -> PathSegment
h dx =
    Rel (RH dx)


{-| Draw a vertical line from the current pen position. Positive amounts go
down, negative ones go up. Like `h`, this is a shorthand for `l` when the
line should be perfectly upright.

    v 80 -- 80 units down

    v -30 -- 30 units up

-}
v : Float -> PathSegment
v dy =
    Rel (RV dy)


{-| Draw a cubic curve, shaped by two invisible control points. The first
control point pulls the start of the line toward itself, the second pulls
the end. Because each end can be pulled in a different direction, a cubic
curve can bend one way and then the other, giving it an S capability that
the simpler quadratic curve lacks. This is the workhorse curve: reach for
it when you need precise control over how a curve leaves one point and
arrives at another.

In the picture, the dashed lines connect each end of the curve to the
control point pulling on it:

![a cubic curve arching between two points, with dashed lines to its two control points](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-c.svg)

All three points are offsets from the current pen position:

    c ( 0, -50 ) ( 80, -50 ) ( 80, 0 )

This draws an arch that rises 50 units and lands 80 units to the right.

-}
c : ( Float, Float ) -> ( Float, Float ) -> ( Float, Float ) -> PathSegment
c cp1 cp2 end =
    Rel (RC cp1 cp2 end)


{-| Continue a cubic curve smoothly. You give only the second control point
and the end point; the first control point is computed automatically by
mirroring the previous curve's last control point, which guarantees there is
no visible kink where the two curves meet. Use it when chaining several
cubic curves into one flowing line, such as a wave.

In the picture, a regular cubic curve (dark) is continued by a smooth one
(blue); the mirrored control point is shown as a dashed circle:

![a cubic curve continued smoothly by a second curve, with the mirrored control point shown dashed](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-s.svg)

Both points are offsets from the current pen position:

    s ( 40, -30 ) ( 80, 0 )

-}
s : ( Float, Float ) -> ( Float, Float ) -> PathSegment
s cp2 end =
    Rel (RS cp2 end)


{-| Draw a quadratic curve, shaped by a single invisible control point. The
line bows toward the control point without ever touching it, like a rope
being tugged from one side. It always bends in just one direction, so it is
the simplest way to soften a line when you don't need the S shapes a cubic
curve can make.

In the picture, the dashed lines connect the ends of the curve to the
control point pulling on it:

![a quadratic curve bowing toward a single control point above it](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-q.svg)

Both points are offsets from the current pen position:

    q ( 40, -60 ) ( 80, 0 )

This draws a bow that arcs upward and lands 80 units to the right.

-}
q : ( Float, Float ) -> ( Float, Float ) -> PathSegment
q cp end =
    Rel (RQ cp end)


{-| Continue a quadratic curve smoothly. You give only the end point; the
control point is computed automatically by mirroring the previous curve's
control point, so the joined curves flow into each other without a kink.
Chaining `t` after a `q` is an easy way to draw a wavy line.

In the picture, a quadratic curve (dark) is continued by a smooth one
(blue); the mirrored control point is shown as a dashed circle:

![a quadratic curve continued smoothly by a second curve, with the mirrored control point shown dashed](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-t.svg)

The end point is an offset from the current pen position:

    t ( 40, 0 )

-}
t : ( Float, Float ) -> PathSegment
t end =
    Rel (RT end)


{-| Draw an arc, a slice of an ellipse outline, from the current pen position
to an end point. Arcs are what you reach for when drawing pie chart slices,
rounded corners, or anything else that should look like part of a circle.

You describe the ellipse the arc is cut from (`rx` and `ry` are its
horizontal and vertical radii; make them equal for a circular arc, and
`rotation` tilts the whole ellipse by that many degrees). Between any two
points there are four possible arcs of that ellipse: a long way round and a
short way round, on either side of the line between the points. Two flags
pick which one you get. `largeArc = True` chooses the longer route, and
`sweep = True` makes the pen curve clockwise rather than counterclockwise.

Every panel in the picture uses the same start point, end point, and radii.
Only the two flags differ, and each combination picks out a different one of
the four arcs. The blue arc is the one selected; the pale arcs are the other
three possibilities:

![the four arcs between the same two points, one per combination of the largeArc and sweep flags](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/path-a.svg)

The end point is an offset from the current pen position:

    a 50 50 0 False True ( 100, 0 )

This draws the short clockwise half of a circle, bulging upward, ending
100 units to the right.

-}
a : Float -> Float -> Float -> Bool -> Bool -> ( Float, Float ) -> PathSegment
a rx ry rotation largeArc sweep end =
    Rel (RA rx ry rotation largeArc sweep end)



-- Geometric Segment representation


{-| A single piece of a path with explicit start and end points. This
representation is more convenient for geometric computation, since you always
know where each piece starts and ends without tracking any pen state. It also
has only 4 constructors, which makes comprehensive case statements much
easier to write.

  - `Line` is a straight line between two points
  - `Quadratic` is a curve pulled toward one control point
  - `Cubic` is a curve pulled by two control points, one for each end
  - `Arc` is a slice of an ellipse outline

-}
type Segment
    = Line { from : ( Float, Float ), to : ( Float, Float ) }
    | Quadratic { from : ( Float, Float ), controlPoint : ( Float, Float ), to : ( Float, Float ) }
    | Cubic { from : ( Float, Float ), controlPoint1 : ( Float, Float ), controlPoint2 : ( Float, Float ), to : ( Float, Float ) }
    | Arc { from : ( Float, Float ), rx : Float, ry : Float, rotation : Float, largeArc : Bool, sweep : Bool, to : ( Float, Float ) }


{-| Convert paths into a list of geometric segments, resolving all the
relative movements so that each segment knows its own absolute start and end
points.

This is useful when you need to:

  - Measure the length of a path
  - Sample points along a path
  - Transform individual segments
  - Compute bounding boxes

Closing commands (`Z`) become explicit straight `Line` segments back to the
stroke's starting point, so a closed shape measures and samples like the
complete outline you see on screen.

-}
toSegments : List Path -> List Segment
toSegments paths =
    toSegmentsAccum ( 0, 0 ) paths []


toSegmentsAccum : ( Float, Float ) -> List Path -> List Segment -> List Segment
toSegmentsAccum currentPoint paths acc =
    case paths of
        [] ->
            acc

        path :: rest ->
            let
                ( start, segments ) =
                    case path of
                        M absStart segs ->
                            ( absStart, segs )

                        MRelative ( dx, dy ) segs ->
                            let
                                ( cx, cy ) =
                                    currentPoint
                            in
                            ( ( cx + dx, cy + dy ), segs )

                newSegments =
                    segmentsToGeometric start segments

                newEnd =
                    case List.reverse newSegments of
                        [] ->
                            start

                        lastSeg :: _ ->
                            segmentTo lastSeg
            in
            toSegmentsAccum newEnd rest (acc ++ newSegments)


segmentsToGeometric : ( Float, Float ) -> List PathSegment -> List Segment
segmentsToGeometric start segments =
    let
        go current previous remaining acc =
            case remaining of
                [] ->
                    List.reverse acc

                seg :: rest ->
                    let
                        ( nextPoint, segment ) =
                            resolveSegment start current previous seg
                    in
                    case segment of
                        Just geom ->
                            go nextPoint (Just geom) rest (geom :: acc)

                        Nothing ->
                            go nextPoint Nothing rest acc
    in
    go start Nothing segments []


{-| Reflect a point about the current point.
-}
reflectAbout : ( Float, Float ) -> ( Float, Float ) -> ( Float, Float )
reflectAbout ( cx, cy ) ( px, py ) =
    ( 2 * cx - px, 2 * cy - py )


{-| The first control point that `S` implies: the reflection, about the
current point, of the previous cubic's second control point. Per the SVG
specification a smooth cubic only chains off another cubic (`C`, `c`, `S`,
`s`); after anything else the control point is coincident with the current
point.
-}
smoothCubicControl : ( Float, Float ) -> Maybe Segment -> ( Float, Float )
smoothCubicControl current previous =
    case previous of
        Just (Cubic { controlPoint2 }) ->
            reflectAbout current controlPoint2

        _ ->
            current


{-| The control point that `T` implies: the reflection, about the current
point, of the previous quadratic's control point. A smooth quadratic only
chains off another quadratic (`Q`, `q`, `T`, `t`); after anything else the
control point is coincident with the current point.
-}
smoothQuadraticControl : ( Float, Float ) -> Maybe Segment -> ( Float, Float )
smoothQuadraticControl current previous =
    case previous of
        Just (Quadratic { controlPoint }) ->
            reflectAbout current controlPoint

        _ ->
            current


resolveSegment : ( Float, Float ) -> ( Float, Float ) -> Maybe Segment -> PathSegment -> ( ( Float, Float ), Maybe Segment )
resolveSegment subpathStart ( cx, cy ) previous seg =
    case seg of
        L to ->
            ( to, Just (Line { from = ( cx, cy ), to = to }) )

        H x ->
            ( ( x, cy ), Just (Line { from = ( cx, cy ), to = ( x, cy ) }) )

        V y ->
            ( ( cx, y ), Just (Line { from = ( cx, cy ), to = ( cx, y ) }) )

        C cp1 cp2 to ->
            ( to, Just (Cubic { from = ( cx, cy ), controlPoint1 = cp1, controlPoint2 = cp2, to = to }) )

        S cp2 to ->
            ( to
            , Just
                (Cubic
                    { from = ( cx, cy )
                    , controlPoint1 = smoothCubicControl ( cx, cy ) previous
                    , controlPoint2 = cp2
                    , to = to
                    }
                )
            )

        Q cp to ->
            ( to, Just (Quadratic { from = ( cx, cy ), controlPoint = cp, to = to }) )

        T to ->
            ( to
            , Just
                (Quadratic
                    { from = ( cx, cy )
                    , controlPoint = smoothQuadraticControl ( cx, cy ) previous
                    , to = to
                    }
                )
            )

        A rx ry rotation largeArc sweep to ->
            ( to, Just (Arc { from = ( cx, cy ), rx = rx, ry = ry, rotation = rotation, largeArc = largeArc, sweep = sweep, to = to }) )

        Z ->
            -- Closing a stroke draws a straight line back to where the stroke
            -- began and moves the pen there. When the pen is already at the
            -- start, there is nothing to draw.
            ( subpathStart
            , if ( cx, cy ) == subpathStart then
                Nothing

              else
                Just (Line { from = ( cx, cy ), to = subpathStart })
            )

        Rel rel ->
            resolveRelSegment ( cx, cy ) previous rel


resolveRelSegment : ( Float, Float ) -> Maybe Segment -> RelativeSegment -> ( ( Float, Float ), Maybe Segment )
resolveRelSegment ( cx, cy ) previous rel =
    case rel of
        RL ( dx, dy ) ->
            let
                to =
                    ( cx + dx, cy + dy )
            in
            ( to, Just (Line { from = ( cx, cy ), to = to }) )

        RH dx ->
            let
                to =
                    ( cx + dx, cy )
            in
            ( to, Just (Line { from = ( cx, cy ), to = to }) )

        RV dy ->
            let
                to =
                    ( cx, cy + dy )
            in
            ( to, Just (Line { from = ( cx, cy ), to = to }) )

        RC ( dx1, dy1 ) ( dx2, dy2 ) ( dx, dy ) ->
            let
                to =
                    ( cx + dx, cy + dy )
            in
            ( to, Just (Cubic { from = ( cx, cy ), controlPoint1 = ( cx + dx1, cy + dy1 ), controlPoint2 = ( cx + dx2, cy + dy2 ), to = to }) )

        RS ( dx2, dy2 ) ( dx, dy ) ->
            let
                to =
                    ( cx + dx, cy + dy )
            in
            ( to
            , Just
                (Cubic
                    { from = ( cx, cy )
                    , controlPoint1 = smoothCubicControl ( cx, cy ) previous
                    , controlPoint2 = ( cx + dx2, cy + dy2 )
                    , to = to
                    }
                )
            )

        RQ ( dx1, dy1 ) ( dx, dy ) ->
            let
                to =
                    ( cx + dx, cy + dy )
            in
            ( to, Just (Quadratic { from = ( cx, cy ), controlPoint = ( cx + dx1, cy + dy1 ), to = to }) )

        RT ( dx, dy ) ->
            let
                to =
                    ( cx + dx, cy + dy )
            in
            ( to
            , Just
                (Quadratic
                    { from = ( cx, cy )
                    , controlPoint = smoothQuadraticControl ( cx, cy ) previous
                    , to = to
                    }
                )
            )

        RA rx ry rotation largeArc sweep ( dx, dy ) ->
            let
                to =
                    ( cx + dx, cy + dy )
            in
            ( to, Just (Arc { from = ( cx, cy ), rx = rx, ry = ry, rotation = rotation, largeArc = largeArc, sweep = sweep, to = to }) )


{-| Convert geometric segments back into paths. Consecutive segments that
share endpoints become one continuous pen stroke. Wherever a segment starts
somewhere other than where the previous one ended, the pen is lifted and a
new stroke begins there.

    fromSegments
        [ Line { from = ( 10, 10 ), to = ( 90, 10 ) }
        , Line { from = ( 90, 10 ), to = ( 90, 90 ) }
        ]
    --> [ M ( 10, 10 ) [ L ( 90, 10 ), L ( 90, 90 ) ] ]

    -- A discontinuity creates a new subpath:
    fromSegments
        [ Line { from = ( 0, 0 ), to = ( 50, 0 ) }
        , Line
            { from = ( 100, 100 )
            , to = ( 150, 100 )
            }
        ]
    --> [ M ( 0, 0 ) [ L ( 50, 0 ) ]
    --> , M ( 100, 100 ) [ L ( 150, 100 ) ]
    --> ]

-}
fromSegments : List Segment -> List Path
fromSegments segments =
    case segments of
        [] ->
            []

        first :: rest ->
            let
                result =
                    List.foldl
                        (\seg acc ->
                            if segmentFrom seg == acc.currentEnd then
                                { acc | currentPathSegs = acc.currentPathSegs ++ [ segmentToPathSegment seg ], currentEnd = segmentTo seg }

                            else
                                { finishedPaths = acc.finishedPaths ++ [ M acc.currentStart acc.currentPathSegs ]
                                , currentStart = segmentFrom seg
                                , currentPathSegs = [ segmentToPathSegment seg ]
                                , currentEnd = segmentTo seg
                                }
                        )
                        { finishedPaths = []
                        , currentStart = segmentFrom first
                        , currentPathSegs = [ segmentToPathSegment first ]
                        , currentEnd = segmentTo first
                        }
                        rest
            in
            result.finishedPaths ++ [ M result.currentStart result.currentPathSegs ]


segmentFrom : Segment -> ( Float, Float )
segmentFrom seg =
    case seg of
        Line { from } ->
            from

        Quadratic { from } ->
            from

        Cubic { from } ->
            from

        Arc { from } ->
            from


segmentTo : Segment -> ( Float, Float )
segmentTo seg =
    case seg of
        Line { to } ->
            to

        Quadratic { to } ->
            to

        Cubic { to } ->
            to

        Arc { to } ->
            to


segmentToPathSegment : Segment -> PathSegment
segmentToPathSegment seg =
    case seg of
        Line { to } ->
            L to

        Quadratic { controlPoint, to } ->
            Q controlPoint to

        Cubic { controlPoint1, controlPoint2, to } ->
            C controlPoint1 controlPoint2 to

        Arc { rx, ry, rotation, largeArc, sweep, to } ->
            A rx ry rotation largeArc sweep to



-- Measurement and Sampling


{-| The total length of a path, that is, how far the pen travels while
drawing it. Straight lines are measured exactly; curves are measured
approximately by sampling points along them.

    pathLength [ M ( 0, 0 ) [ L ( 100, 0 ) ] ] --> 100

    -- a 3-4-5 triangle:
    pathLength [ M ( 0, 0 ) [ L ( 30, 40 ) ] ] --> 50

-}
pathLength : List Path -> Float
pathLength paths =
    paths
        |> toSegments
        |> List.map segmentLength
        |> List.sum


{-| Find the point you would reach by tracing the path partway along its
length. The second argument says how far to go: 0.0 is the very start of the
path, 1.0 is the very end, and 0.5 is the point exactly halfway along,
measured by drawn distance. Useful for placing labels or markers along a
line, or for animating something traveling along a path.

    interpolate [ M ( 0, 0 ) [ L ( 100, 0 ) ] ] 0.5
    --> ( 50, 0 )

-}
interpolate : List Path -> Float -> ( Float, Float )
interpolate paths param =
    let
        segments =
            toSegments paths

        totalLen =
            List.map segmentLength segments |> List.sum

        targetLen =
            param * totalLen
    in
    interpolateSegments segments targetLen


interpolateSegments : List Segment -> Float -> ( Float, Float )
interpolateSegments segments remainingLen =
    case segments of
        [] ->
            ( 0, 0 )

        seg :: rest ->
            let
                len =
                    segmentLength seg
            in
            if remainingLen <= len then
                segmentPointAt (remainingLen / len) seg

            else
                interpolateSegments rest (remainingLen - len)


segmentLength : Segment -> Float
segmentLength seg =
    case seg of
        Line { from, to } ->
            dist from to

        Quadratic { from, controlPoint, to } ->
            quadraticLength from controlPoint to

        Cubic { from, controlPoint1, controlPoint2, to } ->
            cubicLength from controlPoint1 controlPoint2 to

        Arc arc ->
            approximateLengthBy 32 (\p -> arcPointAt p arc)


segmentPointAt : Float -> Segment -> ( Float, Float )
segmentPointAt param seg =
    case seg of
        Line { from, to } ->
            lerp param from to

        Quadratic { from, controlPoint, to } ->
            quadraticPointAt param from controlPoint to

        Cubic { from, controlPoint1, controlPoint2, to } ->
            cubicPointAt param from controlPoint1 controlPoint2 to

        Arc arc ->
            arcPointAt param arc


dist : ( Float, Float ) -> ( Float, Float ) -> Float
dist ( x1, y1 ) ( x2, y2 ) =
    sqrt ((x2 - x1) ^ 2 + (y2 - y1) ^ 2)


lerp : Float -> ( Float, Float ) -> ( Float, Float ) -> ( Float, Float )
lerp param ( x1, y1 ) ( x2, y2 ) =
    ( x1 + param * (x2 - x1), y1 + param * (y2 - y1) )


quadraticPointAt : Float -> ( Float, Float ) -> ( Float, Float ) -> ( Float, Float ) -> ( Float, Float )
quadraticPointAt param ( x0, y0 ) ( x1, y1 ) ( x2, y2 ) =
    let
        mt =
            1 - param
    in
    ( mt * mt * x0 + 2 * mt * param * x1 + param * param * x2
    , mt * mt * y0 + 2 * mt * param * y1 + param * param * y2
    )


cubicPointAt : Float -> ( Float, Float ) -> ( Float, Float ) -> ( Float, Float ) -> ( Float, Float ) -> ( Float, Float )
cubicPointAt param ( x0, y0 ) ( x1, y1 ) ( x2, y2 ) ( x3, y3 ) =
    let
        mt =
            1 - param
    in
    ( mt * mt * mt * x0 + 3 * mt * mt * param * x1 + 3 * mt * param * param * x2 + param * param * param * x3
    , mt * mt * mt * y0 + 3 * mt * mt * param * y1 + 3 * mt * param * param * y2 + param * param * param * y3
    )


quadraticLength : ( Float, Float ) -> ( Float, Float ) -> ( Float, Float ) -> Float
quadraticLength from cp to =
    approximateLengthBy 16 (\p -> quadraticPointAt p from cp to)


cubicLength : ( Float, Float ) -> ( Float, Float ) -> ( Float, Float ) -> ( Float, Float ) -> Float
cubicLength from cp1 cp2 to =
    approximateLengthBy 16 (\p -> cubicPointAt p from cp1 cp2 to)


{-| A point along an elliptical arc, using the endpoint-to-center conversion
from the SVG specification (appendix B.2.4). Degenerate arcs (zero radii, or
coincident endpoints) fall back to the straight chord, matching how browsers
render them.
-}
arcPointAt : Float -> { from : ( Float, Float ), rx : Float, ry : Float, rotation : Float, largeArc : Bool, sweep : Bool, to : ( Float, Float ) } -> ( Float, Float )
arcPointAt param { from, rx, ry, rotation, largeArc, sweep, to } =
    case arcCenterParams from rx ry rotation largeArc sweep to of
        Nothing ->
            lerp param from to

        Just { cx, cy, rxAdj, ryAdj, startAngle, deltaAngle, cosPhi, sinPhi } ->
            let
                theta =
                    startAngle + param * deltaAngle

                x =
                    rxAdj * cos theta

                y =
                    ryAdj * sin theta
            in
            ( cx + cosPhi * x - sinPhi * y
            , cy + sinPhi * x + cosPhi * y
            )


{-| Convert an arc's endpoint description (the form paths use) into its
center description (the form you can sample): center, corrected radii, start
angle, and how far around the ellipse the arc travels. Returns Nothing for
degenerate arcs that render as a straight line or as nothing at all.
-}
arcCenterParams :
    ( Float, Float )
    -> Float
    -> Float
    -> Float
    -> Bool
    -> Bool
    -> ( Float, Float )
    -> Maybe { cx : Float, cy : Float, rxAdj : Float, ryAdj : Float, startAngle : Float, deltaAngle : Float, cosPhi : Float, sinPhi : Float }
arcCenterParams ( x1, y1 ) rx0 ry0 rotationDeg largeArc sweep ( x2, y2 ) =
    let
        rx1 =
            abs rx0

        ry1 =
            abs ry0

        -- Step 1: midpoint-relative coordinates in the ellipse's own frame.
    in
    if (rx1 == 0 || ry1 == 0) || (x1 == x2 && y1 == y2) then
        Nothing

    else
        let
            -- Step 2: scale radii up if they are too small to span the points.
            phi =
                degrees rotationDeg

            cosPhi =
                cos phi

            sinPhi =
                sin phi

            dx =
                (x1 - x2) / 2

            dy =
                (y1 - y2) / 2

            x1p =
                cosPhi * dx + sinPhi * dy

            y1p =
                -sinPhi * dx + cosPhi * dy

            lambda =
                (x1p * x1p) / (rx1 * rx1) + (y1p * y1p) / (ry1 * ry1)

            scale =
                if lambda > 1 then
                    sqrt lambda

                else
                    1

            rx =
                rx1 * scale

            ry =
                ry1 * scale

            -- Step 3: center in the ellipse frame.
            num =
                rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p

            den =
                rx * rx * y1p * y1p + ry * ry * x1p * x1p

            sign =
                if largeArc /= sweep then
                    1

                else
                    -1

            coef =
                sign * sqrt (max 0 (num / den))

            cxp =
                coef * (rx * y1p / ry)

            cyp =
                coef * (-ry * x1p / rx)

            -- Step 4: back to user coordinates, plus the angle sweep.
            cx =
                cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2

            cy =
                sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2

            startAngle =
                atan2 ((y1p - cyp) / ry) ((x1p - cxp) / rx)

            endAngle =
                atan2 ((-y1p - cyp) / ry) ((-x1p - cxp) / rx)

            rawDelta =
                endAngle - startAngle

            deltaAngle =
                if sweep && rawDelta < 0 then
                    rawDelta + 2 * pi

                else if not sweep && rawDelta > 0 then
                    rawDelta - 2 * pi

                else
                    rawDelta
        in
        Just
            { cx = cx
            , cy = cy
            , rxAdj = rx
            , ryAdj = ry
            , startAngle = startAngle
            , deltaAngle = deltaAngle
            , cosPhi = cosPhi
            , sinPhi = sinPhi
            }


approximateLengthBy : Int -> (Float -> ( Float, Float )) -> Float
approximateLengthBy steps pointAt =
    let
        dt =
            1.0 / toFloat steps

        go i prev acc =
            if i > steps then
                acc

            else
                let
                    current =
                        pointAt (toFloat i * dt)
                in
                go (i + 1) current (acc + dist prev current)
    in
    go 1 (pointAt 0) 0



-- Utilities


{-| Close every stroke in the path by drawing a straight line from wherever
it ends back to where it began, turning open lines into sealed outlines.
-}
close : List Path -> List Path
close paths =
    List.map closeOne paths


closeOne : Path -> Path
closeOne path =
    case path of
        M start segments ->
            M start (segments ++ [ Z ])

        MRelative offset segments ->
            MRelative offset (segments ++ [ Z ])


{-| The point where the pen finishes after drawing the whole path, in other
words the end of the final stroke. Handy when you want to continue drawing
from where a path left off or attach something to its tip.
-}
endPoint : List Path -> ( Float, Float )
endPoint paths =
    List.foldl pathEndPoint ( 0, 0 ) paths


{-| Where the pen ends up after one stroke, given where the previous stroke
left it (relative strokes and movements resolve against that).
-}
pathEndPoint : Path -> ( Float, Float ) -> ( Float, Float )
pathEndPoint path previousEnd =
    let
        ( start, segments ) =
            case path of
                M absStart segs ->
                    ( absStart, segs )

                MRelative ( dx, dy ) segs ->
                    let
                        ( px, py ) =
                            previousEnd
                    in
                    ( ( px + dx, py + dy ), segs )
    in
    List.foldl (segmentEndPoint start) start segments


segmentEndPoint : ( Float, Float ) -> PathSegment -> ( Float, Float ) -> ( Float, Float )
segmentEndPoint subpathStart segment ( cx, cy ) =
    case segment of
        L pt ->
            pt

        H x ->
            ( x, cy )

        V y ->
            ( cx, y )

        C _ _ pt ->
            pt

        S _ pt ->
            pt

        Q _ pt ->
            pt

        T pt ->
            pt

        A _ _ _ _ _ pt ->
            pt

        Z ->
            subpathStart

        Rel rel ->
            case rel of
                RL ( dx, dy ) ->
                    ( cx + dx, cy + dy )

                RH dx ->
                    ( cx + dx, cy )

                RV dy ->
                    ( cx, cy + dy )

                RC _ _ ( dx, dy ) ->
                    ( cx + dx, cy + dy )

                RS _ ( dx, dy ) ->
                    ( cx + dx, cy + dy )

                RQ _ ( dx, dy ) ->
                    ( cx + dx, cy + dy )

                RT ( dx, dy ) ->
                    ( cx + dx, cy + dy )

                RA _ _ _ _ _ ( dx, dy ) ->
                    ( cx + dx, cy + dy )


{-| The point where the pen is first put down, in other words the start of
the first stroke. A path whose first stroke uses the relative [`m`](#m)
starts relative to the origin, so its offset is its starting point.
-}
startPoint : List Path -> ( Float, Float )
startPoint paths =
    case paths of
        [] ->
            ( 0, 0 )

        first :: _ ->
            startPointOfOne first


startPointOfOne : Path -> ( Float, Float )
startPointOfOne path =
    case path of
        M start _ ->
            start

        MRelative offset _ ->
            offset



-- Rendering


{-| Render a single path to the compact text notation that SVG uses for
path data (the `d` attribute), for example `"M10 10L90 10Z"`. You rarely need
this yourself, since `Evg.path` accepts `Path` values directly, but it is
useful for interoperating with other libraries or debugging. To render a
list of paths, use `List.map toString >> String.join ""`.
-}
toString : Path -> String
toString path =
    case path of
        M ( mx, my ) segments ->
            "M" ++ floatPair mx my ++ String.concat (List.map segmentToString segments)

        MRelative ( dx, dy ) segments ->
            "m" ++ floatPair dx dy ++ String.concat (List.map segmentToString segments)


segmentToString : PathSegment -> String
segmentToString segment =
    case segment of
        L ( x, y ) ->
            "L" ++ floatPair x y

        H x ->
            "H" ++ String.fromFloat x

        V y ->
            "V" ++ String.fromFloat y

        C ( x1, y1 ) ( x2, y2 ) ( x, y ) ->
            "C" ++ floatPair x1 y1 ++ " " ++ floatPair x2 y2 ++ " " ++ floatPair x y

        S ( x2, y2 ) ( x, y ) ->
            "S" ++ floatPair x2 y2 ++ " " ++ floatPair x y

        Q ( x1, y1 ) ( x, y ) ->
            "Q" ++ floatPair x1 y1 ++ " " ++ floatPair x y

        T ( x, y ) ->
            "T" ++ floatPair x y

        A rx ry rotation largeArc sweep ( x, y ) ->
            "A"
                ++ String.fromFloat rx
                ++ " "
                ++ String.fromFloat ry
                ++ " "
                ++ String.fromFloat rotation
                ++ " "
                ++ boolToFlag largeArc
                ++ " "
                ++ boolToFlag sweep
                ++ " "
                ++ floatPair x y

        Z ->
            "Z"

        Rel rel ->
            relativeToString rel


relativeToString : RelativeSegment -> String
relativeToString rel =
    case rel of
        RL ( dx, dy ) ->
            "l" ++ floatPair dx dy

        RH dx ->
            "h" ++ String.fromFloat dx

        RV dy ->
            "v" ++ String.fromFloat dy

        RC ( x1, y1 ) ( x2, y2 ) ( x, y ) ->
            "c" ++ floatPair x1 y1 ++ " " ++ floatPair x2 y2 ++ " " ++ floatPair x y

        RS ( x2, y2 ) ( x, y ) ->
            "s" ++ floatPair x2 y2 ++ " " ++ floatPair x y

        RQ ( x1, y1 ) ( x, y ) ->
            "q" ++ floatPair x1 y1 ++ " " ++ floatPair x y

        RT ( x, y ) ->
            "t" ++ floatPair x y

        RA rx ry rotation largeArc sweep ( x, y ) ->
            "a"
                ++ String.fromFloat rx
                ++ " "
                ++ String.fromFloat ry
                ++ " "
                ++ String.fromFloat rotation
                ++ " "
                ++ boolToFlag largeArc
                ++ " "
                ++ boolToFlag sweep
                ++ " "
                ++ floatPair x y


floatPair : Float -> Float -> String
floatPair x y =
    String.fromFloat x ++ " " ++ String.fromFloat y


boolToFlag : Bool -> String
boolToFlag b =
    if b then
        "1"

    else
        "0"
