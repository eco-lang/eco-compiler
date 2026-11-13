module Evg.Transform exposing
    ( translate, rotate, rotateAround, scale, scaleUniform
    , skewX, skewY, matrix
    )

{-| Move, rotate, resize, and slant shapes.

Transforms change where and how a shape is drawn without changing the
numbers that define it. You describe the shape once, then use transforms to
place it, spin it, or stretch it.

You can list several transforms on the same shape and they combine into one.
The transform listed last takes effect on the shape first. In the second
example below, the square is first rotated around the corner of the picture
and then moved into place, which is the usual recipe for rotating a shape
"in place" (though `rotateAround` does this in one step).

    import Evg
    import Evg.Transform as Transform

    -- Move a square 50 units to the right:
    Evg.rect [ Transform.translate 50 0 ]
        { x = 0, y = 0, width = 40, height = 40 }

    -- A square rotated 45 degrees, sitting at (50, 50):
    Evg.rect
        [ Transform.translate 50 50
        , Transform.rotate 45
        ]
        { x = -20, y = -20, width = 40, height = 40 }

@docs translate, rotate, rotateAround, scale, scaleUniform
@docs skewX, skewY, matrix

-}

import Evg
import Evg.Internal as Internal exposing (Attribute(..), Mat23, Supported)


{-| Moves a shape sideways and down without changing its size or angle.
Positive values move right and down, negative values move left and up.

    -- move 100 right, 50 down:
    Transform.translate 100 50

![translate example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/transform-translate-example.svg)

The grey square is the original position and the blue square is the result.

-}
translate : Float -> Float -> Evg.Attribute { a | transform : Evg.Supported } msg
translate dx dy =
    let
        str =
            "translate(" ++ String.fromFloat dx ++ " " ++ String.fromFloat dy ++ ")"
    in
    TransformAttr (Internal.mixString str transformHash_) str { a = 1, b = 0, c = 0, d = 1, e = dx, f = dy }


{-| Rotates a shape clockwise by the given angle in degrees. The rotation
pivots around the top-left corner of the picture, the `(0, 0)` point, not
around the shape's own center. A shape far from that corner will swing
around it like the tip of a clock hand. If you want a shape to spin in
place, use `rotateAround` with the shape's center instead.

    Transform.rotate 90 -- quarter turn clockwise

![rotate example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/transform-rotate-example.svg)

The grey square is the original and the blue square has been rotated 30
degrees around the top-left corner of the picture.

-}
rotate : Float -> Evg.Attribute { a | transform : Evg.Supported } msg
rotate angle =
    let
        str =
            "rotate(" ++ String.fromFloat angle ++ ")"
    in
    TransformAttr (Internal.mixString str transformHash_) str (rotationMat angle)


{-| Rotates a shape clockwise by the given angle in degrees, pivoting around
the point you give. Pass the shape's own center to spin it in place. This is
usually what you want when "rotating a shape".

    Transform.rotateAround 45 ( 50, 50 )

![rotateAround example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/transform-rotate-around-example.svg)

The grey square is the original and the blue square has been rotated 45
degrees around its own center, so it stays put and just turns.

-}
rotateAround : Float -> ( Float, Float ) -> Attribute { a | transform : Supported } msg
rotateAround angle ( cx, cy ) =
    let
        str =
            "rotate(" ++ String.fromFloat angle ++ " " ++ String.fromFloat cx ++ " " ++ String.fromFloat cy ++ ")"

        -- translate(cx,cy) · rotate(angle) · translate(-cx,-cy)
        mat =
            Internal.composeMat
                { a = 1, b = 0, c = 0, d = 1, e = cx, f = cy }
                (Internal.composeMat (rotationMat angle)
                    { a = 1, b = 0, c = 0, d = 1, e = -cx, f = -cy }
                )
    in
    TransformAttr (Internal.mixString str transformHash_) str mat


{-| Stretches or squashes a shape, with separate factors for width and
height. A factor of `1.0` means no change, `2.0` doubles that dimension,
and `0.5` halves it.

Distances from the top-left corner of the picture are scaled too, so a shape
that does not touch that corner also moves as it grows or shrinks.

    -- twice as wide, same height:
    Transform.scale 2.0 1.0

![scale example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/transform-scale-example.svg)

The grey square is the original and the blue rectangle is the same square
stretched to twice its width.

-}
scale : Float -> Float -> Evg.Attribute { a | transform : Evg.Supported } msg
scale sx sy =
    let
        str =
            "scale(" ++ String.fromFloat sx ++ " " ++ String.fromFloat sy ++ ")"
    in
    TransformAttr (Internal.mixString str transformHash_) str { a = sx, b = 0, c = 0, d = sy, e = 0, f = 0 }


{-| Grows or shrinks a shape by the same factor in both directions, keeping
its proportions.

    Transform.scaleUniform 0.5 -- shrink to half size

-}
scaleUniform : Float -> Evg.Attribute { a | transform : Evg.Supported } msg
scaleUniform s =
    let
        str =
            "scale(" ++ String.fromFloat s ++ " " ++ String.fromFloat s ++ ")"
    in
    TransformAttr (Internal.mixString str transformHash_) str { a = s, b = 0, c = 0, d = s, e = 0, f = 0 }


{-| Slants a shape sideways by the given angle in degrees, like pushing a
deck of cards sideways so it leans. A square becomes a leaning
parallelogram; its vertical edges tilt while its horizontal edges stay
level. The further a point is from the top of the picture, the further it
shifts sideways.

    Transform.skewX 20

![skewX example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/transform-skew-x-example.svg)

The grey square is the original and the blue parallelogram is the same
square slanted 20 degrees to the side.

-}
skewX : Float -> Evg.Attribute { a | transform : Evg.Supported } msg
skewX angle =
    let
        str =
            "skewX(" ++ String.fromFloat angle ++ ")"
    in
    TransformAttr (Internal.mixString str transformHash_) str { a = 1, b = 0, c = tanDeg angle, d = 1, e = 0, f = 0 }


{-| Slants a shape up or down by the given angle in degrees. This is the
vertical partner of `skewX`: a square's horizontal edges tilt while its
vertical edges stay upright, and the further a point is from the left of
the picture, the further it shifts down.

    Transform.skewY 10

-}
skewY : Float -> Evg.Attribute { a | transform : Evg.Supported } msg
skewY angle =
    let
        str =
            "skewY(" ++ String.fromFloat angle ++ ")"
    in
    TransformAttr (Internal.mixString str transformHash_) str { a = 1, b = tanDeg angle, c = 0, d = 1, e = 0, f = 0 }


{-| The escape hatch: applies an arbitrary 2D transformation given as six
numbers. `matrix a b c d e f` moves each point `(x, y)` of the shape to
`(a*x + c*y + e, b*x + d*y + f)`. Every combination of moving, rotating,
scaling, and slanting can be written this way.

Most of the time you will not need this. The other functions in this module
cover the common cases with friendlier names.

-}
matrix : Float -> Float -> Float -> Float -> Float -> Float -> Evg.Attribute { a | transform : Evg.Supported } msg
matrix a b c d e f =
    let
        str =
            "matrix("
                ++ String.fromFloat a
                ++ " "
                ++ String.fromFloat b
                ++ " "
                ++ String.fromFloat c
                ++ " "
                ++ String.fromFloat d
                ++ " "
                ++ String.fromFloat e
                ++ " "
                ++ String.fromFloat f
                ++ ")"
    in
    TransformAttr (Internal.mixString str transformHash_) str { a = a, b = b, c = c, d = d, e = e, f = f }


degToRad : Float -> Float
degToRad deg =
    deg * pi / 180


tanDeg : Float -> Float
tanDeg deg =
    tan (degToRad deg)


rotationMat : Float -> Mat23
rotationMat angle =
    let
        rad =
            degToRad angle

        cos_ =
            cos rad

        sin_ =
            sin rad
    in
    { a = cos_, b = sin_, c = -sin_, d = cos_, e = 0, f = 0 }


transformHash_ : Int
transformHash_ =
    -708404361
