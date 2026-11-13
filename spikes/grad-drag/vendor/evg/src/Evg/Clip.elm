module Evg.Clip exposing (clip, clipWithCoordinates)

{-| Show only part of a shape by cutting away the rest.

A clip path works like a stencil: you provide a second shape, and only the
parts of the first shape that fall inside it are drawn. Everything outside
is cut away completely, leaving a hard edge, as if you had taken scissors
to the picture.

If you want soft, gradual edges instead of a clean cut, see `Evg.Mask`.

    import Evg
    import Evg.Clip as Clip

    -- Show only the part of the photo inside a circle,
    -- producing a round photo cutout:
    Evg.image
        [ Clip.clip
            (Evg.circle []
                { r = 50, center = ( 50, 50 ) }
            )
        ]
        { href = "photo.jpg"
        , x = 0
        , y = 0
        , width = 100
        , height = 100
        }

![clip example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/clip-example.svg)

A colorful rectangle clipped by a circle: the corners are cut away and the
circle's edge is crisp.


# Clipping

@docs clip, clipWithCoordinates

-}

import Bitwise
import Evg
import Evg.Internal as Internal exposing (Attribute(..), Def(..))
import Svg.Attributes


{-| Cuts a shape down using another shape as a stencil. Only the parts inside
the stencil shape stay visible; everything outside disappears. The stencil
shape itself is never drawn, it only decides what shows.

The stencil is positioned using the same coordinates as the rest of the
picture, so a circle centered at `(50, 50)` cuts around that point of the
picture.

    -- A photo cropped to a circle:
    Evg.image
        [ Clip.clip
            (Evg.circle []
                { r = 50, center = ( 50, 50 ) }
            )
        ]
        { href = "photo.jpg"
        , x = 0
        , y = 0
        , width = 100
        , height = 100
        }

    -- A blue square cropped to a triangle:
    Evg.rect
        [ Clip.clip
            (Evg.polygon []
                [ ( 50, 0 ), ( 100, 100 ), ( 0, 100 ) ]
            )
        , Evg.fillStr "blue"
        ]
        { x = 0, y = 0, width = 100, height = 100 }

-}
clip : Evg.Evg msg -> Attribute a msg
clip evg =
    let
        (Internal.Evg { hash }) =
            evg

        idHash =
            Bitwise.xor hash clipHash_

        id =
            "clip-" ++ String.fromInt idHash
    in
    DefAttr
        idHash
        "clip-path"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.clipPath ("url(#" ++ id ++ ")"))
        (Def id
            (Internal.Evg
                { content = Internal.Tag "clipPath" [ Svg.Attributes.id id ] []
                , ownMatrix = Internal.identityMat
                , children = [ evg ]
                , hash = 0
                , defs = []
                , attrs = [ ( "id", id ) ]
                }
            )
        )


{-| Like `clip`, but you choose how the stencil's coordinates are measured.

With `clip`, the stencil is positioned in the picture's own coordinates.
Use `Evg.objectBoundingBox` to measure the stencil against the shape being
clipped instead: `(0, 0)` is that shape's top-left corner and `(1, 1)` its
bottom-right, so the same stencil adapts to shapes of any size.

    -- Show the left half, whatever the shape's size:
    Evg.rect
        [ Clip.clipWithCoordinates
            (Evg.objectBoundingBox
                { x = 0, y = 0, width = 1, height = 1 }
            )
            (Evg.rect []
                { x = 0
                , y = 0
                , width = 0.5
                , height = 1
                }
            )
        , Evg.fillStr "red"
        ]
        { x = 20, y = 20, width = 160, height = 160 }

-}
clipWithCoordinates : Evg.CoordinateSpace -> Evg.Evg msg -> Attribute a msg
clipWithCoordinates space evg =
    let
        (Internal.Evg { hash }) =
            evg

        spaceHash =
            Internal.coordinateSpaceHash space

        idHash =
            Bitwise.xor hash clipHash_ |> Internal.mixInt spaceHash

        id =
            "clip-" ++ String.fromInt idHash
    in
    DefAttr
        idHash
        "clip-path"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.clipPath ("url(#" ++ id ++ ")"))
        (Def id
            (Internal.Evg
                { content = Internal.Tag "clipPath" (Svg.Attributes.id id :: Internal.coordinateSpaceAttrs Svg.Attributes.clipPathUnits space) []
                , ownMatrix = Internal.identityMat
                , children = [ evg ]
                , hash = 0
                , defs = []
                , attrs = ( "id", id ) :: Internal.coordinateSpaceData "clipPathUnits" space
                }
            )
        )



-- Precomputed hash constants


clipHash_ : Int
clipHash_ =
    677360987
