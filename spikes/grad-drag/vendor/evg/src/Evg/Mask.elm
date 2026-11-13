module Evg.Mask exposing
    ( alpha, alphaWithCoordinates
    , luminance, luminanceWithCoordinates
    )

{-| Fade parts of a shape in and out using another shape as a mask.

A mask is like a stencil with soft edges. Where a clip path (see `Evg.Clip`)
either shows or hides each part of a shape with a hard boundary, a mask can
show a part at any strength in between. You draw a second shape (the mask),
and each point of the masked shape becomes as visible as the mask is
"strong" at that point. Paint the mask with a gradient and the shape fades
out gradually instead of being cut off.

    import Evg
    import Evg.Mask as Mask

    -- A blue square showing only inside a circle:
    Evg.rect
        [ Mask.alpha
            (Evg.circle [ Evg.fillStr "white" ]
                { r = 50, center = ( 50, 50 ) }
            )
        , Evg.fillStr "blue"
        ]
        { x = 0, y = 0, width = 100, height = 100 }

![clip versus mask example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/clip-vs-mask-example.svg)

The same colorful square shown twice: on the left cut by a clip path (hard
circular edge), on the right faded by a mask painted with a soft-edged
circle (the edge melts away gradually).

There are two ways a mask's "strength" can be measured, and each has its own
pair of functions below.


# Alpha Masks

The mask's own transparency controls visibility. Where the mask shape is
fully opaque (any color), the masked shape shows completely; where the mask
is transparent or absent, the shape is hidden; in between, it is partially
see-through.

@docs alpha, alphaWithCoordinates


# Luminance Masks

The mask's brightness controls visibility. White areas show the shape fully,
black areas hide it, and greys show it partially. Use this when you want to
paint the mask with light and dark colors, for example a white-to-black
gradient or a photograph.

@docs luminance, luminanceWithCoordinates

-}

import Bitwise
import Evg
import Evg.Internal as Internal exposing (Attribute(..), Def(..))
import Svg.Attributes
import VirtualDom


{-| Masks a shape using another shape's transparency. Wherever the mask
shape is opaque, the masked shape shows; wherever the mask is transparent
or there is no mask shape at all, it is hidden; partially see-through areas
of the mask show the shape partially.

    -- A red square, visible only inside the circle:
    Evg.rect
        [ Mask.alpha
            (Evg.circle [ Evg.fillStr "white" ]
                { r = 40, center = ( 50, 50 ) }
            )
        , Evg.fillStr "red"
        ]
        { x = 0, y = 0, width = 100, height = 100 }

-}
alpha : Evg.Evg msg -> Attribute a msg
alpha evg =
    let
        (Internal.Evg { hash }) =
            evg

        idHash =
            Bitwise.xor hash maskHash_

        id =
            "mask-" ++ String.fromInt idHash
    in
    DefAttr
        idHash
        "mask"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.mask ("url(#" ++ id ++ ")"))
        (Def id
            (Internal.Evg
                { content = Internal.Tag "mask" [ Svg.Attributes.id id, VirtualDom.attribute "mask-type" "alpha" ] []
                , ownMatrix = Internal.identityMat
                , children = [ evg ]
                , hash = 0
                , defs = []
                , attrs = [ ( "id", id ), ( "mask-type", "alpha" ) ]
                }
            )
        )


{-| Like `alpha`, but you choose how the mask shape's coordinates are
measured. Use `Evg.objectBoundingBox` to measure the mask against the shape
being masked (where `(0, 0)` is its top-left corner and `(1, 1)` its
bottom-right), or `Evg.userSpace` to pin the mask to a fixed region of the
picture.

    Evg.rect
        [ Mask.alphaWithCoordinates
            (Evg.userSpace
                { x = 0
                , y = 0
                , width = 200
                , height = 200
                }
            )
            (Evg.circle [ Evg.fillStr "white" ]
                { r = 100, center = ( 100, 100 ) }
            )
        , Evg.fillStr "red"
        ]
        { x = 0, y = 0, width = 200, height = 200 }

-}
alphaWithCoordinates : Evg.CoordinateSpace -> Evg.Evg msg -> Attribute a msg
alphaWithCoordinates space evg =
    let
        id =
            "mask-" ++ Internal.contentHash evg ++ "-" ++ String.fromInt (Internal.coordinateSpaceHash space)
    in
    DefAttr
        (Internal.mixString id maskHash_)
        "mask"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.mask ("url(#" ++ id ++ ")"))
        (Def id
            (Internal.Evg
                { content =
                    Internal.Tag "mask"
                        (Svg.Attributes.id id
                            :: VirtualDom.attribute "mask-type" "alpha"
                            :: Internal.coordinateSpaceAttrs Svg.Attributes.maskContentUnits space
                        )
                        []
                , ownMatrix = Internal.identityMat
                , children = [ evg ]
                , hash = 0
                , defs = []
                , attrs = ( "id", id ) :: ( "mask-type", "alpha" ) :: Internal.coordinateSpaceData "maskContentUnits" space
                }
            )
        )


{-| Masks a shape using another shape's brightness. White areas of the mask
show the shape fully, black areas hide it, and greys show it partially.
Painting the mask with a white-to-black gradient makes the shape fade out
smoothly.

    -- A red square, visible inside the white circle:
    Evg.rect
        [ Mask.luminance
            (Evg.circle [ Evg.fillStr "white" ]
                { r = 40, center = ( 50, 50 ) }
            )
        , Evg.fillStr "red"
        ]
        { x = 0, y = 0, width = 100, height = 100 }

-}
luminance : Evg.Evg msg -> Attribute a msg
luminance evg =
    let
        id =
            "mask-lum-" ++ Internal.contentHash evg
    in
    DefAttr
        (Internal.mixString id maskLumHash_)
        "mask"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.mask ("url(#" ++ id ++ ")"))
        (Def id
            (Internal.Evg
                { content = Internal.Tag "mask" [ Svg.Attributes.id id ] []
                , ownMatrix = Internal.identityMat
                , children = [ evg ]
                , hash = 0
                , defs = []
                , attrs = [ ( "id", id ) ]
                }
            )
        )


{-| Like `luminance`, but you choose how the mask shape's coordinates are
measured. Use `Evg.objectBoundingBox` to measure the mask against the shape
being masked, or `Evg.userSpace` to pin the mask to a fixed region of the
picture.

    Evg.rect
        [ Mask.luminanceWithCoordinates
            (Evg.userSpace
                { x = 0
                , y = 0
                , width = 200
                , height = 200
                }
            )
            (Evg.circle [ Evg.fillStr "white" ]
                { r = 100, center = ( 100, 100 ) }
            )
        , Evg.fillStr "red"
        ]
        { x = 0, y = 0, width = 200, height = 200 }

-}
luminanceWithCoordinates : Evg.CoordinateSpace -> Evg.Evg msg -> Attribute a msg
luminanceWithCoordinates space evg =
    let
        id =
            "mask-lum-" ++ Internal.contentHash evg ++ "-" ++ String.fromInt (Internal.coordinateSpaceHash space)
    in
    DefAttr
        (Internal.mixString id maskLumHash_)
        "mask"
        ("url(#" ++ id ++ ")")
        (Svg.Attributes.mask ("url(#" ++ id ++ ")"))
        (Def id
            (Internal.Evg
                { content = Internal.Tag "mask" (Svg.Attributes.id id :: Internal.coordinateSpaceAttrs Svg.Attributes.maskContentUnits space) []
                , ownMatrix = Internal.identityMat
                , children = [ evg ]
                , hash = 0
                , defs = []
                , attrs = ( "id", id ) :: Internal.coordinateSpaceData "maskContentUnits" space
                }
            )
        )



-- Precomputed hash constants


maskHash_ : Int
maskHash_ =
    677180817


maskLumHash_ : Int
maskLumHash_ =
    432382325
