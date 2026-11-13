module Evg.Internal.Interpolation exposing
    ( Method(..)
    , Weights
    , triangulate
    , weights
    )

{-| Turning a pointer position into blend weights over a set of target
positions, for `Evg.Drag.between`.

The targets are triangulated (Delaunay). Inside the triangulation the pointer
gets either the barycentric weights of the triangle it sits in, or Sibson's
natural neighbour weights, which are smoother: they don't kink when the
pointer crosses a triangle edge. Outside it, the pointer is projected onto the
nearest edge of the convex hull and weighted along that edge; the distance it
had to be moved is reported as the gap.

Degenerate layouts are handled directly: one target always gets everything,
and targets in a line are interpolated along it.

-}

import Dict exposing (Dict)


type alias Point =
    ( Float, Float )


type Method
    = Barycentric
    | NaturalNeighbor


{-| Weights per target index (only non-zero ones), and how far the pointer is
from the region the targets span.
-}
type alias Weights =
    { weights : List ( Int, Float )
    , gap : Float
    }


type alias Triangle =
    ( Int, Int, Int )


{-| Weights for `query`, given the target positions.
-}
weights : Method -> List Point -> Point -> Weights
weights method points query =
    let
        indexed =
            List.indexedMap Tuple.pair points

        -- Targets that land on the same spot can't be told apart by the
        -- pointer, so the first one stands in for the others.
        distinct =
            dedupe indexed
    in
    case distinct of
        [] ->
            { weights = [], gap = 1 / 0 }

        [ ( i, p ) ] ->
            { weights = [ ( i, 1 ) ], gap = dist p query }

        _ ->
            if collinear (List.map Tuple.second distinct) then
                alongLine distinct query

            else
                inPlane method distinct query


dedupe : List ( Int, Point ) -> List ( Int, Point )
dedupe indexed =
    List.foldl
        (\( i, p ) acc ->
            if List.any (\( _, q ) -> dist2 p q < 1.0e-12) acc then
                acc

            else
                acc ++ [ ( i, p ) ]
        )
        []
        indexed



-- VECTOR HELPERS


sub : Point -> Point -> Point
sub ( ax, ay ) ( bx, by ) =
    ( ax - bx, ay - by )


add : Point -> Point -> Point
add ( ax, ay ) ( bx, by ) =
    ( ax + bx, ay + by )


scale : Float -> Point -> Point
scale k ( x, y ) =
    ( k * x, k * y )


dot : Point -> Point -> Float
dot ( ax, ay ) ( bx, by ) =
    ax * bx + ay * by


cross : Point -> Point -> Float
cross ( ax, ay ) ( bx, by ) =
    ax * by - ay * bx


dist2 : Point -> Point -> Float
dist2 a b =
    let
        d =
            sub a b
    in
    dot d d


dist : Point -> Point -> Float
dist a b =
    sqrt (dist2 a b)


{-| Signed area times two of the triangle (a, b, c); positive when
counter-clockwise in a y-up frame.
-}
orient : Point -> Point -> Point -> Float
orient a b c =
    cross (sub b a) (sub c a)



-- COLLINEAR TARGETS


collinear : List Point -> Bool
collinear points =
    case points of
        p0 :: rest ->
            let
                extent =
                    List.foldl (\p acc -> max acc (dist p p0)) 0 rest

                farthest =
                    List.foldl
                        (\p acc ->
                            if dist p p0 > dist acc p0 then
                                p

                            else
                                acc
                        )
                        p0
                        rest
            in
            extent
                == 0
                || List.all (\p -> abs (orient p0 farthest p) <= 1.0e-9 * extent * extent) rest

        [] ->
            True


alongLine : List ( Int, Point ) -> Point -> Weights
alongLine distinct query =
    case distinct of
        ( _, p0 ) :: _ ->
            let
                far =
                    List.foldl
                        (\( _, p ) acc ->
                            if dist p p0 > dist acc p0 then
                                p

                            else
                                acc
                        )
                        p0
                        distinct

                dir =
                    sub far p0

                param p =
                    dot (sub p p0) dir

                sorted =
                    List.sortBy (\( _, p ) -> param p) distinct
            in
            nearestOnPolyline sorted query

        [] ->
            { weights = [], gap = 1 / 0 }


{-| Project onto each segment of the chain and keep the closest projection.
-}
nearestOnPolyline : List ( Int, Point ) -> Point -> Weights
nearestOnPolyline chain query =
    let
        segments =
            List.map2 Tuple.pair chain (List.drop 1 chain)
    in
    segments
        |> List.map (\( a, b ) -> onSegment a b query)
        |> List.foldl
            (\w best ->
                case best of
                    Nothing ->
                        Just w

                    Just b ->
                        if w.gap < b.gap then
                            Just w

                        else
                            best
            )
            Nothing
        |> Maybe.withDefault { weights = [], gap = 1 / 0 }


onSegment : ( Int, Point ) -> ( Int, Point ) -> Point -> Weights
onSegment ( i, a ) ( j, b ) query =
    let
        ab =
            sub b a

        len2 =
            dot ab ab

        u =
            if len2 == 0 then
                0

            else
                clamp 0 1 (dot (sub query a) ab / len2)

        closest =
            add a (scale u ab)
    in
    { weights = List.filter (\( _, w ) -> w > 0) [ ( i, 1 - u ), ( j, u ) ]
    , gap = dist closest query
    }



-- TARGETS SPANNING AN AREA


inPlane : Method -> List ( Int, Point ) -> Point -> Weights
inPlane method distinct query =
    let
        hull =
            convexHull distinct

        onHull =
            nearestOnPolyline (hull ++ List.take 1 hull) query
    in
    if onHull.gap <= 1.0e-6 then
        -- On the boundary every method agrees with plain interpolation along
        -- the edge, and natural neighbour weights degenerate there.
        onHull

    else
        let
            positions =
                Dict.fromList distinct

            triangles =
                triangulate distinct
        in
        case List.filter (\tri -> contains positions tri query) triangles of
            tri :: _ ->
                case method of
                    Barycentric ->
                        { weights = barycentric positions tri query, gap = 0 }

                    NaturalNeighbor ->
                        { weights = sibson positions triangles tri query, gap = 0 }

            [] ->
                -- Outside the hull: slide onto its boundary.
                onHull


pos : Dict Int Point -> Int -> Point
pos positions i =
    Dict.get i positions |> Maybe.withDefault ( 0, 0 )


contains : Dict Int Point -> Triangle -> Point -> Bool
contains positions ( i, j, k ) q =
    let
        a =
            pos positions i

        b =
            pos positions j

        c =
            pos positions k

        area =
            orient a b c

        eps =
            -1.0e-9 * abs area
    in
    orient a b q * sign area >= eps && orient b c q * sign area >= eps && orient c a q * sign area >= eps


sign : Float -> Float
sign x =
    if x < 0 then
        -1

    else
        1


barycentric : Dict Int Point -> Triangle -> Point -> List ( Int, Float )
barycentric positions ( i, j, k ) q =
    let
        a =
            pos positions i

        b =
            pos positions j

        c =
            pos positions k

        area =
            orient a b c

        wa =
            orient b c q / area

        wb =
            orient c a q / area

        wc =
            1 - wa - wb
    in
    [ ( i, wa ), ( j, wb ), ( k, wc ) ]
        |> List.map (\( idx, w ) -> ( idx, clamp 0 1 w ))
        |> normalize


normalize : List ( Int, Float ) -> List ( Int, Float )
normalize ws =
    let
        total =
            List.sum (List.map Tuple.second ws)
    in
    if total <= 0 then
        ws

    else
        ws
            |> List.map (\( i, w ) -> ( i, w / total ))
            |> List.filter (\( _, w ) -> w > 0)


{-| Delaunay triangulation by Bowyer–Watson: insert the points one at a time
into a triangle large enough to hold them all, re-triangulating the hole left
by the triangles whose circumcircle contains the new point. Triangles that
touch the enclosing triangle's corners are removed at the end. Fine for the
dozens of targets a drag usually has.
-}
triangulate : List ( Int, Point ) -> List Triangle
triangulate distinct =
    let
        xs =
            List.map (Tuple.second >> Tuple.first) distinct

        ys =
            List.map (Tuple.second >> Tuple.second) distinct

        minX =
            List.minimum xs |> Maybe.withDefault 0

        maxX =
            List.maximum xs |> Maybe.withDefault 0

        minY =
            List.minimum ys |> Maybe.withDefault 0

        maxY =
            List.maximum ys |> Maybe.withDefault 0

        size =
            max 1 (max (maxX - minX) (maxY - minY))

        cx =
            (minX + maxX) / 2

        cy =
            (minY + maxY) / 2

        -- Indices -1, -2, -3 are the enclosing triangle's corners.
        super =
            [ ( -1, ( cx - 100 * size, cy - 100 * size ) )
            , ( -2, ( cx + 100 * size, cy - 100 * size ) )
            , ( -3, ( cx, cy + 100 * size ) )
            ]

        positions =
            Dict.fromList (super ++ distinct)

        insert ( i, p ) tris =
            let
                ( bad, good ) =
                    List.partition (\tri -> inCircumcircle positions tri p) tris

                boundary =
                    cavityBoundary bad
            in
            good ++ List.map (\( a, b ) -> orientCcw positions ( a, b, i )) boundary
    in
    List.foldl insert [ ( -1, -2, -3 ) ] distinct
        |> List.filter (\( a, b, c ) -> a >= 0 && b >= 0 && c >= 0)


orientCcw : Dict Int Point -> Triangle -> Triangle
orientCcw positions ( a, b, c ) =
    if orient (pos positions a) (pos positions b) (pos positions c) < 0 then
        ( a, c, b )

    else
        ( a, b, c )


{-| Edges of the given triangles that belong to only one of them, each in the
direction it runs around its triangle.
-}
cavityBoundary : List Triangle -> List ( Int, Int )
cavityBoundary tris =
    let
        edges =
            List.concatMap (\( a, b, c ) -> [ ( a, b ), ( b, c ), ( c, a ) ]) tris

        shared ( a, b ) =
            List.any (\( x, y ) -> x == b && y == a) edges
    in
    List.filter (\e -> not (shared e)) edges


inCircumcircle : Dict Int Point -> Triangle -> Point -> Bool
inCircumcircle positions ( i, j, k ) p =
    let
        ( ax, ay ) =
            sub (pos positions i) p

        ( bx, by ) =
            sub (pos positions j) p

        ( cx, cy ) =
            sub (pos positions k) p

        det =
            (ax * ax + ay * ay)
                * (bx * cy - cx * by)
                - (bx * bx + by * by)
                * (ax * cy - cx * ay)
                + (cx * cx + cy * cy)
                * (ax * by - bx * ay)

        o =
            orient (pos positions i) (pos positions j) (pos positions k)
    in
    det * sign o > 1.0e-12 * (ax * ax + ay * ay + bx * bx + by * by + cx * cx + cy * cy) ^ 2


circumcenter : Point -> Point -> Point -> Maybe Point
circumcenter ( ax, ay ) ( bx, by ) ( cx, cy ) =
    let
        d =
            2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    in
    if abs d < 1.0e-12 then
        Nothing

    else
        let
            a2 =
                ax * ax + ay * ay

            b2 =
                bx * bx + by * by

            c2 =
                cx * cx + cy * cy
        in
        Just
            ( (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
            , (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
            )


{-| Sibson's natural neighbour weights. Inserting the query point into the
triangulation steals a piece of each neighbour's Voronoi cell; the weights are
the sizes of those pieces. Each piece is a convex polygon whose corners are
the circumcentres of the deleted triangles around that neighbour plus the two
new triangles' circumcentres next to it, so its area follows from sorting
those corners by angle.
-}
sibson : Dict Int Point -> List Triangle -> Triangle -> Point -> List ( Int, Float )
sibson positions triangles fallbackTri q =
    let
        cavity =
            List.filter (\tri -> inCircumcircle positions tri q) triangles

        boundary =
            cavityBoundary cavity

        neighbours =
            boundary |> List.map Tuple.first

        nextOf i =
            boundary
                |> List.filter (\( a, _ ) -> a == i)
                |> List.head
                |> Maybe.map Tuple.second

        prevOf i =
            boundary
                |> List.filter (\( _, b ) -> b == i)
                |> List.head
                |> Maybe.map Tuple.first

        stolen i =
            let
                p =
                    pos positions i

                old =
                    cavity
                        |> List.filter (\( a, b, c ) -> a == i || b == i || c == i)
                        |> List.filterMap (\( a, b, c ) -> circumcenter (pos positions a) (pos positions b) (pos positions c))

                new =
                    [ nextOf i, prevOf i ]
                        |> List.filterMap identity
                        |> List.filterMap (\other -> circumcenter q p (pos positions other))
            in
            convexArea (old ++ new)

        raw =
            List.map (\i -> ( i, stolen i )) neighbours
    in
    if List.isEmpty cavity || List.any (\( _, a ) -> isNaN a || isInfinite a) raw then
        barycentric positions fallbackTri q

    else
        case normalize raw of
            [] ->
                barycentric positions fallbackTri q

            ws ->
                ws


convexArea : List Point -> Float
convexArea points =
    case points of
        [] ->
            0

        _ ->
            let
                n =
                    toFloat (List.length points)

                centroid =
                    scale (1 / n) (List.foldl add ( 0, 0 ) points)

                sorted =
                    List.sortBy
                        (\p ->
                            let
                                ( dx, dy ) =
                                    sub p centroid
                            in
                            atan2 dy dx
                        )
                        points
            in
            List.map2 cross sorted (List.drop 1 sorted ++ List.take 1 sorted)
                |> List.sum
                |> (\s -> abs s / 2)


{-| Convex hull, counter-clockwise, by Andrew's monotone chain.
-}
convexHull : List ( Int, Point ) -> List ( Int, Point )
convexHull distinct =
    let
        sorted =
            List.sortWith
                (\( _, ( ax, ay ) ) ( _, ( bx, by ) ) ->
                    case compare ax bx of
                        EQ ->
                            compare ay by

                        other ->
                            other
                )
                distinct

        build pts =
            List.foldl
                (\p stack -> p :: popWhile p stack)
                []
                pts

        popWhile (( _, p ) as item) stack =
            case stack of
                ( _, b ) :: ((( _, a ) :: _) as rest) ->
                    if orient a b p <= 0 then
                        popWhile item rest

                    else
                        stack

                _ ->
                    stack

        lower =
            List.reverse (build sorted)

        upper =
            List.reverse (build (List.reverse sorted))
    in
    List.drop 1 (List.reverse lower) |> List.reverse |> (\l -> l ++ (List.drop 1 (List.reverse upper) |> List.reverse))
