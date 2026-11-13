module Evg.Filter exposing
    ( Filter
    , withinSubregion, withinSRGB
    , sourceAlpha, sourceGraphic
    , image, imageAspectRatio
    , flood, floodStr
    , gaussianBlur, gaussianBlurXY
    , fractalNoise, turbulence
    , displacementMap, displacementMapWithChannelSelector, Channel(..)
    , colorMatrix, saturate, hueRotate, luminanceToAlpha
    , componentTransfer, RemappingFunction, identity, table, discrete, linear, gamma
    , compositeIn, compositeOut, compositeAtop, compositeOver, compositeXor, compositeArithmetic
    , blend, BlendMode(..)
    , merge
    , offset, dropShadow
    , erode, erodeXY, dilate, dilateXY
    , tile
    , convolve, ConvolveOption, divisor, bias, targetXY, edgeDuplicate, edgeWrap, edgeNone, preserveAlpha
    , specularLighting, diffuseLighting, Light, pointLight, distantLight, spotLight
    )

{-| Build image processing pipelines by composing filter operations.

A filter is an image effect applied to a shape after it has been drawn, much
like stacking adjustment layers in a photo editor. A blur softens the edges, a
drop shadow draws a dark blurred copy behind the shape, turbulence generates
cloudy noise, and a displacement map warps a shape using another image as the
guide.

    import Evg
    import Evg.Filter as Filter


    -- A simple drop shadow:
    shadow =
        Filter.merge
            [ Filter.sourceAlpha
                |> Filter.gaussianBlur 3
                |> Filter.offset 2 2
            , Filter.sourceGraphic
            ]

When run, this shows the original shape with a soft dark copy of itself
peeking out behind and slightly below it.

The key idea: each filter takes one or two input images and produces an output
image that can be piped into the next filter using `|>`.


# Basics

@docs Filter


## Modifying filter primitives

@docs withinSubregion, withinSRGB


# Sources

These represent ways to get an input image into the filter pipeline:

@docs sourceAlpha, sourceGraphic
@docs image, imageAspectRatio


# Filter Primitives


## Color fills

@docs flood, floodStr


## Blurring

@docs gaussianBlur, gaussianBlurXY


## Noise generation

@docs fractalNoise, turbulence


## Displacement

@docs displacementMap, displacementMapWithChannelSelector, Channel


## Color manipulation

@docs colorMatrix, saturate, hueRotate, luminanceToAlpha
@docs componentTransfer, RemappingFunction, identity, table, discrete, linear, gamma


## Compositing and blending

@docs compositeIn, compositeOut, compositeAtop, compositeOver, compositeXor, compositeArithmetic
@docs blend, BlendMode
@docs merge


## Positioning

@docs offset, dropShadow


## Morphology

@docs erode, erodeXY, dilate, dilateXY


## Tiling

@docs tile


## Convolution

@docs convolve, ConvolveOption, divisor, bias, targetXY, edgeDuplicate, edgeWrap, edgeNone, preserveAlpha


## Lighting

@docs specularLighting, diffuseLighting, Light, pointLight, distantLight, spotLight

-}

import Color
import Dict exposing (Dict)
import Evg.Advanced exposing (AlignValue(..), MeetOrSlice(..))
import Evg.Internal as Internal


type alias Rect =
    { x : Float, y : Float, width : Float, height : Float }


stitchTilesStr : Bool -> String
stitchTilesStr stitch =
    if stitch then
        "stitch"

    else
        "noStitch"


{-| One step in a filter pipeline, producing an image that can be fed into the
next step. Attach a finished pipeline to a shape with `Evg.filter`.
-}
type alias Filter =
    Internal.Filter



-- Helpers


f0 : String -> List ( String, String ) -> Filter
f0 name args =
    Internal.Filter
        { name = name
        , id = name ++ hashArgs args
        , args = args
        , defs = Dict.empty
        , children = []
        }


f1 : String -> List ( String, String ) -> Filter -> Filter
f1 name args inFilter =
    let
        inId =
            toId inFilter

        args2 =
            ( "in", inId ) :: args
    in
    Internal.Filter
        { name = name
        , id = name ++ hashArgs args2
        , args = args2
        , children = []
        , defs = makeDefs inFilter
        }


f2 : String -> List ( String, String ) -> Filter -> Filter -> Filter
f2 name args inFilter1 inFilter2 =
    let
        id1 =
            toId inFilter1

        id2 =
            toId inFilter2

        args2 =
            ( "in", id1 ) :: ( "in2", id2 ) :: args
    in
    Internal.Filter
        { name = name
        , id = name ++ hashArgs args2
        , args = args2
        , children = []
        , defs = makeDefs inFilter1 |> Dict.union (makeDefs inFilter2)
        }



-- Filters


{-| A black silhouette of the shape the filter is applied to. It keeps the
shape's outline and transparency (including soft anti-aliased edges) but
replaces all its colors with black.

This is the usual starting point for drop shadows, since a shadow is a dark
copy of the shape's outline. It is also handy as a mask for cutting other
images down to the shape's silhouette.

-}
sourceAlpha : Filter
sourceAlpha =
    Internal.Virtual "SourceAlpha"


{-| Fills the whole filter area with a single solid color. On its own it just
paints a colored rectangle over the shape; it becomes useful when combined
with other filters, for example recoloring a silhouette with `compositeIn`.

![flood example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-flood.svg)

    Filter.flood (Color.rgb255 255 0 0)

This produces a solid red rectangle covering the filter area.

-}
flood : Color.Color -> Filter
flood color =
    f0 "feFlood" [ ( "flood-color", Color.toCssString color ) ]


{-| Like `flood`, but takes the color as a CSS color string.

![flood example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-flood.svg)

    Filter.floodStr "#FA32CA"

This produces a solid pink rectangle covering the filter area.

-}
floodStr : String -> Filter
floodStr str =
    f0 "feFlood" [ ( "flood-color", str ) ]


{-| Softens the input image, smearing sharp edges into a gentle haze, like an
out-of-focus photograph. Use it to de-emphasize background elements, soften
edges, or as the blurry ingredient of a drop shadow or glow.

The number is the blur radius: larger values give a blurrier result.

    Filter.sourceGraphic
        |> Filter.gaussianBlur 3

![blur example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-blur.svg)

-}
gaussianBlur : Float -> Filter -> Filter
gaussianBlur r =
    f1 "feGaussianBlur" [ ( "stdDeviation", String.fromFloat r ) ]


{-| Like `gaussianBlur`, but with separate horizontal and vertical blur radii.
Blurring only horizontally gives a motion-streak look; only vertically gives a
smeared, dripping look.
-}
gaussianBlurXY : Float -> Float -> Filter -> Filter
gaussianBlurXY rx ry =
    f1 "feGaussianBlur" [ ( "stdDeviation", String.fromFloat rx ++ " " ++ String.fromFloat ry ) ]


{-| Generates soft, organic, cloud-like noise, filling the filter area with
random smoky color. Use it as a texture (clouds, marble, water) or as the
guide image for `displacementMap` to make things look warped or hand-drawn.

![noise types comparison](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-noise-types.svg)

    Filter.fractalNoise
        { baseFrequency = 0.05
        , numOctaves = 3
        , seed = 1
        , stitchTiles = False
        }

This fills the area with a colorful, smoky cloud texture.

Note that the texture is generated from nothing: whatever shape you apply
this to is replaced by noise rather than textured. To affect a shape, feed
the noise into [`displacementMap`](#displacementMap).

The options:

  - `baseFrequency` controls how fine the noise is (smaller values give larger features)
  - `numOctaves` adds layers of detail (more layers give a more intricate pattern)
  - `seed` picks a different random pattern for each value
  - `stitchTiles`, when `True`, makes the noise pattern tile seamlessly at the edges

-}
fractalNoise : { baseFrequency : Float, numOctaves : Int, seed : Int, stitchTiles : Bool } -> Filter
fractalNoise { baseFrequency, numOctaves, seed, stitchTiles } =
    f0 "feTurbulence"
        [ ( "baseFrequency", String.fromFloat baseFrequency )
        , ( "numOctaves", String.fromInt numOctaves )
        , ( "seed", String.fromInt seed )
        , ( "type", "fractalNoise" )
        , ( "stitchTiles", stitchTilesStr stitchTiles )
        ]


{-| Warps the first input using the second input as a guide image. Each pixel
of the first image is nudged sideways and up or down by an amount read from
the corresponding pixel of the guide, so straight edges come out wavy and
wobbly. Use it with noise as the guide for water ripples, heat shimmer, or a
hand-drawn look. Higher `scale` values produce more extreme distortion.

The first filter argument is the image to warp; the second (or the one piped
in with `|>`) is the guide image.

    -- Wavy distortion effect:
    Filter.fractalNoise
        { baseFrequency = 0.05
        , numOctaves = 1
        , seed = 1
        , stitchTiles = False
        }
        |> Filter.displacementMap { scale = 20 }
            Filter.sourceGraphic

This makes the shape's edges ripple as if seen through wavy glass.

![displacement example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-displacement.svg)

-}
displacementMap : { scale : Float } -> Filter -> Filter -> Filter
displacementMap { scale } inFilter1 inFilter2 =
    f2 "feDisplacementMap"
        [ ( "scale", String.fromFloat scale ) ]
        inFilter1
        inFilter2


{-| Selects which color channel of the guide image a displacement map reads
from:

  - `Red`
  - `Green`
  - `Blue`
  - `Alpha`

-}
type Channel
    = Red
    | Green
    | Blue
    | Alpha


channelToString : Channel -> String
channelToString channel =
    case channel of
        Red ->
            "R"

        Green ->
            "G"

        Blue ->
            "B"

        Alpha ->
            "A"


{-| Like `displacementMap`, but lets you pick which color channel of the guide
image drives the horizontal shift and which drives the vertical shift. By
default browsers use the alpha channel for both, which is rarely what you want
with colorful guide images like noise.
-}
displacementMapWithChannelSelector : { scale : Float, xChannelSelector : Channel, yChannelSelector : Channel } -> Filter -> Filter -> Filter
displacementMapWithChannelSelector { scale, xChannelSelector, yChannelSelector } inFilter1 inFilter2 =
    f2 "feDisplacementMap"
        [ ( "scale", String.fromFloat scale ), ( "xChannelSelector", channelToString xChannelSelector ), ( "yChannelSelector", channelToString yChannelSelector ) ]
        inFilter1
        inFilter2


{-| Recolors the input by computing each output color channel as a weighted
mix of the input channels. This is the general-purpose color tool: greyscale,
sepia, channel swaps, tints and transparency tricks are all particular
matrices. For the common cases, `saturate`, `hueRotate` and `luminanceToAlpha`
are easier to use.

The matrix transformation applied is:

    | R' |     | a00 a01 a02 a03 a04 |   | R |
    | G' |     | a10 a11 a12 a13 a14 |   | G |
    | B' |  =  | a20 a21 a22 a23 a24 | * | B |
    | A' |     | a30 a31 a32 a33 a34 |   | A |
    | 1  |     |  0   0   0   0   1  |   | 1 |

on the RGBA color and alpha values of every pixel on the input graphics to produce a result with a new set of RGBA color and alpha values.

The calculations are performed on non-premultiplied color values.

The input here is the above matrix in row order `[[ a00, a01, ...], [ a10, a11, ...], ...]`. This is a 4x5 list of lists. Extra values will be ignored and missing values will be substituted for the identity matrix. So

    Filter.colorMatrix
        [ [ 0.12 ]
        , [ 0, 0.12 ]
        , [ 1, 0, 0, 0, 0, 0.12 ]
        ]

is equivalent to:

    Filter.colorMatrix
        [ [ 0.12, 0, 0, 0, 0 ]
        , [ 0, 0.12, 0, 0, 0 ]
        , [ 1, 0, 0, 0, 0 ]
        , [ 0, 0, 0, 1, 0 ]
        , [ 0, 0, 0, 0, 1 ]
        ]

-}
colorMatrix : List (List Float) -> Filter -> Filter
colorMatrix matrix inFilter =
    let
        values =
            matrix
                |> defaultMatrix
                |> List.concatMap (\row -> List.map String.fromFloat row)
                |> String.join " "
    in
    f1 "feColorMatrix" [ ( "type", "matrix" ), ( "values", values ) ] inFilter


{-| Adjusts how vivid the colors are. A value of `1` leaves colors unchanged,
`0` drains all color away leaving grey, and values above `1` make colors more
intense. Use it to mute a background or make an element pop.

    -- Desaturate to greyscale:
    Filter.sourceGraphic
        |> Filter.saturate 0

The shape keeps its brightness but loses all color, appearing in shades of grey.

![saturate example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-saturate.svg)

    -- Vivid, over-saturated colors:
    Filter.sourceGraphic
        |> Filter.saturate 2.5

Colors come out noticeably more intense than the original.

-}
saturate : Float -> Filter -> Filter
saturate amount inFilter =
    f1 "feColorMatrix" [ ( "type", "saturate" ), ( "values", String.fromFloat amount ) ] inFilter


{-| Shifts every color around the color wheel by the given angle in degrees,
so for example reds can become greens and greens become blues. Brightness and
transparency are unaffected. Useful for producing color variations of the same
artwork.

![hue rotate example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-hue-rotate.svg)

    -- Shift all colors by 90 degrees:
    Filter.sourceGraphic
        |> Filter.hueRotate 90

Every color in the shape changes to a different one, while the drawing itself stays put.

-}
hueRotate : Float -> Filter -> Filter
hueRotate angle inFilter =
    f1 "feColorMatrix" [ ( "type", "hueRotate" ), ( "values", String.fromFloat angle ) ] inFilter


{-| Turns brightness into transparency: bright areas of the input become
opaque and dark areas become see-through, while all color is discarded. Useful
for building masks from colored content, where you then use the result to hide
or reveal parts of another image.

![luminance to alpha example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-luminance-to-alpha.svg)

    -- Use brightness as transparency:
    Filter.sourceGraphic
        |> Filter.luminanceToAlpha

The result is a black image whose opacity follows the brightness of the original.

-}
luminanceToAlpha : Filter -> Filter
luminanceToAlpha inFilter =
    f1 "feColorMatrix" [ ( "type", "luminanceToAlpha" ) ] inFilter


identityMatrix : List (List Float)
identityMatrix =
    [ [ 1, 0, 0, 0, 0 ]
    , [ 0, 1, 0, 0, 0 ]
    , [ 0, 0, 1, 0, 0 ]
    , [ 0, 0, 0, 1, 0 ]
    , [ 0, 0, 0, 0, 1 ]
    ]


defaultMatrix : List (List Float) -> List (List Float)
defaultMatrix input =
    List.map2 (mergeWithTemplate []) (mergeWithTemplate [] input identityMatrix) identityMatrix


mergeWithTemplate : List a -> List a -> List a -> List a
mergeWithTemplate result input template =
    case input of
        [] ->
            List.reverse result ++ template

        i :: is ->
            case template of
                [] ->
                    List.reverse result

                _ :: ts ->
                    mergeWithTemplate (i :: result) is ts


{-| Adjusts each color channel independently by passing its values through a
remapping function, much like the "curves" or "levels" tools in a photo
editor. This is how you do brightness adjustment, contrast adjustment, color
balance, or posterization (reducing colors to a few flat bands).

![component transfer functions](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-component-transfer.svg)

    -- Increase contrast on all color channels:
    Filter.sourceGraphic
        |> Filter.componentTransfer
            { r = Filter.table [ 0, 0.1, 0.9, 1 ]
            , g = Filter.table [ 0, 0.1, 0.9, 1 ]
            , b = Filter.table [ 0, 0.1, 0.9, 1 ]
            , a = Filter.identity
            }

Dark areas of the shape get darker and bright areas brighter.

-}
componentTransfer :
    { r : RemappingFunction
    , g : RemappingFunction
    , b : RemappingFunction
    , a : RemappingFunction
    }
    -> Filter
    -> Filter
componentTransfer { r, g, b, a } inFilter =
    let
        remappingToChild remapping channel =
            case remapping of
                Identity ->
                    Nothing

                Table values ->
                    Just
                        ( channel
                        , [ ( "type", "table" )
                          , ( "tableValues", String.join " " (List.map String.fromFloat values) )
                          ]
                        )

                Discrete values ->
                    Just
                        ( channel
                        , [ ( "type", "discrete" )
                          , ( "tableValues", String.join " " (List.map String.fromFloat values) )
                          ]
                        )

                Linear slope intercept ->
                    Just
                        ( channel
                        , [ ( "type", "linear" )
                          , ( "slope", String.fromFloat slope )
                          , ( "intercept", String.fromFloat intercept )
                          ]
                        )

                Gamma amplitude_ exponent_ offset_ ->
                    Just
                        ( channel
                        , [ ( "type", "gamma" )
                          , ( "amplitude", String.fromFloat amplitude_ )
                          , ( "exponent", String.fromFloat exponent_ )
                          , ( "offset", String.fromFloat offset_ )
                          ]
                        )

        id =
            toId inFilter

        children =
            List.filterMap Basics.identity
                [ remappingToChild r "feFuncR"
                , remappingToChild g "feFuncG"
                , remappingToChild b "feFuncB"
                , remappingToChild a "feFuncA"
                ]
    in
    Internal.Filter
        { name = "feComponentTransfer"
        , id = "feComponentTransfer-" ++ id ++ String.join "-" (List.map (\( aa, bs ) -> aa ++ "_" ++ (List.map (\( bk, bv ) -> bk ++ "_" ++ bv) bs |> String.join "-")) children)
        , args = [ ( "in", id ) ]
        , children =
            List.filterMap Basics.identity
                [ remappingToChild r "feFuncR"
                , remappingToChild g "feFuncG"
                , remappingToChild b "feFuncB"
                , remappingToChild a "feFuncA"
                ]
        , defs = makeDefs inFilter
        }


{-| Describes how one color channel's values are remapped in
`componentTransfer`. Build one with `identity`, `table`, `discrete`, `linear`
or `gamma`.
-}
type RemappingFunction
    = Identity
    | Table (List Float)
    | Discrete (List Float)
    | Linear Float Float
    | Gamma Float Float Float


{-| Leaves the channel unchanged.
-}
identity : RemappingFunction
identity =
    Identity


{-| For table, the function is defined by linear interpolation between the values given. The table has n+1 values (i.e., v0 to vn) specifying the start and end values for n evenly sized interpolation regions.

![component transfer functions](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-component-transfer.svg)

Let's look at an example:

    Filter.table [ 0, 0.6, 0.8, 1 ]

In this case we have 4 values, so we have 3 equal regions:

    0.0 - 0.33 ==> 0.0 - 0.6

    0.33 - 0.66 ==> 0.6 - 0.8

    0.66 - 1.0 ==> 0.8 - 1.0

So for instance if I get a color value of 0.5, this falls in the middle of the second region, and so will get remapped to the middle of the output region, which is 0.7.

-}
table : List Float -> RemappingFunction
table =
    Table


{-| For discrete, the function is defined by the step function defined by the values given, which provides a list of n values (i.e., v0 to vn-1) in order to identify a step function consisting of n steps.

![component transfer functions](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-component-transfer.svg)

Let's look at an example:

    Filter.discrete [ 0, 0.6, 0.8, 1 ]

In this case we have 4 values, so we have 4 equal regions:

    0.0 - 0.25 ==> 0.0

    0.25 - 0.5 ==> 0.6

    0.5 - 0.75 ==> 0.8

    0.75 - 1.0 ==> 1

So for instance if I get a color value of 0.6, this falls in the third region, and so will get remapped to the third value, which is 0.8.

-}
discrete : List Float -> RemappingFunction
discrete =
    Discrete


{-| For linear, the function is defined by the following linear equation:

    C' = slope * C + intercept

Where C is the input value and C' is the output value.

![component transfer functions](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-component-transfer.svg)

-}
linear : { slope : Float, intercept : Float } -> RemappingFunction
linear { slope, intercept } =
    Linear slope intercept


{-| For gamma, the function is defined by the following exponential function:

    C' = amplitude * C  ^ exponent + offset

Where C is the input value and C' is the output value.

![component transfer functions](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-component-transfer.svg)

-}
gamma : { amplitude : Float, exponent : Float, offset : Float } -> RemappingFunction
gamma config =
    Gamma config.amplitude config.exponent config.offset



--


rectToRelative : Rect -> List ( String, String )
rectToRelative rect =
    [ ( "x", String.fromFloat (rect.x * 100) ++ "%" )
    , ( "y", String.fromFloat (rect.y * 100) ++ "%" )
    , ( "width", String.fromFloat (rect.width * 100) ++ "%" )
    , ( "height", String.fromFloat (rect.height * 100) ++ "%" )
    ]


{-| Restricts a filter operation to a rectangular part of the filter area.

Each filter operation normally covers the entire filter area. `withinSubregion`
confines the previous operation's input and output to a smaller rectangle.
This is useful for limiting expensive effects to where they are needed, or
creatively, for confining a blur or a color fill to just part of the image.

![subregion example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-subregion.svg)

The coordinates are fractions of the filter area (which defaults to the
element's bounding box plus some padding). So `{ x = 0, y = 0, width = 1, height = 1 }`
covers the full filter area, and `{ x = 0.25, y = 0.25, width = 0.5, height = 0.5 }`
covers the center quarter.

    -- Blur only the bottom half:
    Filter.merge
        [ Filter.sourceGraphic
        , Filter.sourceGraphic
            |> Filter.gaussianBlur 5
            |> Filter.withinSubregion
                { x = 0
                , y = 0.5
                , width = 1
                , height = 0.5
                }
        ]

This renders the original shape with a blurred strip across its bottom half.
Anything a restricted operation produces outside its rectangle is clipped
away, so without the `merge` the top half would simply be empty.

-}
withinSubregion : { x : Float, y : Float, width : Float, height : Float } -> Filter -> Filter
withinSubregion rect f =
    case f of
        Internal.Filter filt ->
            Internal.Filter { filt | args = rectToRelative rect ++ filt.args }

        Internal.Virtual _ ->
            f


{-| Forces a filter operation to do its color math in the sRGB color space.

By default, SVG filters compute in a color space called linearRGB, which can
produce unexpected results. For example, a Gaussian blur in linearRGB tends to
darken colors and create muddy midtones. Using sRGB often gives results closer
to what you would expect from photo editors or CSS filters.

    -- A blur that preserves perceived brightness:
    Filter.sourceGraphic
        |> Filter.gaussianBlur 4
        |> Filter.withinSRGB

This is especially noticeable for blurring, blending and compositing
operations, where linearRGB math can produce visible color shifts.

-}
withinSRGB : Filter -> Filter
withinSRGB f =
    case f of
        Internal.Filter filt ->
            Internal.Filter { filt | args = ( "color-interpolation-filters", "sRGB" ) :: filt.args }

        Internal.Virtual _ ->
            f


{-| The shape the filter is applied to, exactly as it would have been drawn
with no filter, in full color. Use this when you want the original shape to
appear somewhere in the final result, for example drawn on top of its own
shadow.
-}
sourceGraphic : Filter
sourceGraphic =
    Internal.Virtual "SourceGraphic"


{-| Loads an external image (by URL) to use as a filter input, for example as
a texture to blend over the shape. The image is stretched to fill the filter
area.

    Filter.image "texture.png"
        |> Filter.blend Filter.Screen
            Filter.sourceGraphic

The shape appears lightened by the bright parts of the texture image.

-}
image : String -> Filter
image url =
    f0 "feImage" [ ( "href", url ) ]


{-| Like `image`, but with explicit control over how the image scales to fit
the filter area, so it can keep its proportions instead of stretching. `Meet`
fits the whole image inside the area (possibly leaving gaps), `Slice` fills
the area completely (possibly cropping), and the align value picks which part
of the image stays anchored.

    import Evg.Advanced
        exposing
            ( AlignValue(..)
            , MeetOrSlice(..)
            )

    Filter.imageAspectRatio XMidYMid Slice "photo.jpg"

-}
imageAspectRatio : AlignValue -> MeetOrSlice -> String -> Filter
imageAspectRatio align meetOrSlice url =
    let
        parStr =
            case align of
                AlignNone ->
                    "none"

                _ ->
                    alignToString align ++ " " ++ meetOrSliceToString meetOrSlice
    in
    f0 "feImage" [ ( "href", url ), ( "preserveAspectRatio", parStr ) ]


alignToString : AlignValue -> String
alignToString align =
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


meetOrSliceToString : MeetOrSlice -> String
meetOrSliceToString mos =
    case mos of
        Meet ->
            "meet"

        Slice ->
            "slice"


{-| Generates swirling, marble-like noise that fills the filter area. Compared
to `fractalNoise` it looks sharper and more vein-like, resembling flames,
marble or rippling water rather than soft clouds. Use it as a texture or as
the guide image for `displacementMap`. The options mean the same as in
`fractalNoise`.

![noise types comparison](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-noise-types.svg)

    Filter.turbulence
        { baseFrequency = 0.05
        , numOctaves = 2
        , seed = 1
        , stitchTiles = False
        }

This fills the area with a sharp, swirling colored texture.

Note that the texture is generated from nothing: whatever shape you apply
this to is replaced by noise rather than textured. To affect a shape, feed
the noise into [`displacementMap`](#displacementMap), which uses it to push
the shape's pixels around.

![turbulence as a displacement guide](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-turbulence.svg)

-}
turbulence : { baseFrequency : Float, numOctaves : Int, seed : Int, stitchTiles : Bool } -> Filter
turbulence { baseFrequency, numOctaves, seed, stitchTiles } =
    f0 "feTurbulence"
        [ ( "baseFrequency", String.fromFloat baseFrequency )
        , ( "numOctaves", String.fromInt numOctaves )
        , ( "seed", String.fromInt seed )
        , ( "type", "turbulence" )
        , ( "stitchTiles", stitchTilesStr stitchTiles )
        ]


{-| Keeps only the parts of the first input that overlap the second, like
using the second image as a cookie cutter on the first. A common use is
recoloring a silhouette: cut a `flood` color down to the shape's outline.

![composite operators](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-composite.svg)

    Filter.compositeIn foreground mask

Only the parts of `foreground` that sit over `mask` remain visible.

-}
compositeIn : Filter -> Filter -> Filter
compositeIn =
    f2 "feComposite" [ ( "operator", "in" ) ]


{-| Keeps only the parts of the first input that do not overlap the second,
punching a hole in the first image wherever the second one is. Useful for
cut-out and outline effects.

![composite operators](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-composite.svg)

-}
compositeOut : Filter -> Filter -> Filter
compositeOut =
    f2 "feComposite" [ ( "operator", "out" ) ]


{-| Draws the first input on top of the second, but only where the second is
visible; anything hanging over the edge of the second image is trimmed away.
Useful for painting decoration onto a shape without spilling outside it.

![composite operators](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-composite.svg)

-}
compositeAtop : Filter -> Filter -> Filter
compositeAtop =
    f2 "feComposite" [ ( "operator", "atop" ) ]


{-| Stacks the first input over the second, like laying one photo on top of
another; the second shows through wherever the first is transparent. For
stacking more than two layers, `merge` is more convenient.

![composite operators](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-composite.svg)

-}
compositeOver : Filter -> Filter -> Filter
compositeOver =
    f2 "feComposite" [ ( "operator", "over" ) ]


{-| Keeps only the parts of each input that do not overlap the other; the
overlap itself disappears. Where two shapes cross, this leaves a hole.

![composite operators](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-composite.svg)

-}
compositeXor : Filter -> Filter -> Filter
compositeXor =
    f2 "feComposite" [ ( "operator", "xor" ) ]


{-| Combines two inputs pixel by pixel using the formula
`result = k1*in1*in2 + k2*in1 + k3*in2 + k4`, applied to each color channel.
This gives precise numeric control when none of the ready-made composite
operations do what you need, such as adding a lighting result onto a base
image.

![composite operators](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-composite.svg)

    -- Add lighting to a base image:
    Filter.compositeArithmetic 0 1 1 0 base lighting

The brightness of the two images adds together, making lit areas glow.

-}
compositeArithmetic : Float -> Float -> Float -> Float -> Filter -> Filter -> Filter
compositeArithmetic k1 k2 k3 k4 =
    f2 "feComposite"
        [ ( "operator", "arithmetic" )
        , ( "k1", String.fromFloat k1 )
        , ( "k2", String.fromFloat k2 )
        , ( "k3", String.fromFloat k3 )
        , ( "k4", String.fromFloat k4 )
        ]


{-| How the colors of two overlapping images mix, matching the blend modes
found in photo editors:

![blend modes](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-blend.svg)

  - `Normal`: the top image simply covers the bottom one
  - `Multiply`: colors combine to get darker, like overlapping stained glass
  - `Screen`: colors combine to get lighter, like two projections on a screen
  - `Darken`: keeps whichever pixel is darker
  - `Lighten`: keeps whichever pixel is lighter
  - `Overlay`: darkens dark areas and lightens light ones, boosting contrast

-}
type BlendMode
    = Normal
    | Multiply
    | Screen
    | Darken
    | Lighten
    | Overlay


{-| Mixes the colors of two inputs where they overlap, using one of the
`BlendMode`s. Unlike the composite operations, which decide which image wins
in the overlap, blending mixes the colors of both.

![blend modes](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-blend.svg)

    Filter.blend Filter.Multiply foreground background

Where the images overlap the colors combine and darken, as if drawn with
overlapping marker pens.

-}
blend : BlendMode -> Filter -> Filter -> Filter
blend mode =
    let
        modeStr =
            case mode of
                Normal ->
                    "normal"

                Multiply ->
                    "multiply"

                Screen ->
                    "screen"

                Darken ->
                    "darken"

                Lighten ->
                    "lighten"

                Overlay ->
                    "overlay"
    in
    f2 "feBlend" [ ( "mode", modeStr ) ]


{-| Stacks any number of filter results on top of each other, first in the
list at the back, last at the front. This is typically the final step of a
filter, for example placing the original shape back on top of its shadow.

    Filter.merge [ background, middleLayer, foreground ]

-}
merge : List Filter -> Filter
merge inputs =
    let
        mergeNodeChildren =
            List.map (\input -> ( "feMergeNode", [ ( "in", toId input ) ] )) inputs

        allDefs =
            List.foldl (\input acc -> Dict.union acc (makeDefs input)) Dict.empty inputs

        idsStr =
            String.join "-" (List.map toId inputs)
    in
    Internal.Filter
        { name = "feMerge"
        , id = "feMerge-" ++ idsStr
        , args = []
        , children = mergeNodeChildren
        , defs = allDefs
        }


{-| Slides the input image by the given horizontal and vertical distance,
leaving it otherwise unchanged. This is the usual way to push a shadow copy
out from under the original shape.

![offset example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-offset.svg)

    Filter.sourceAlpha
        |> Filter.gaussianBlur 3
        |> Filter.offset 4 4

This produces a soft dark blob shifted down and to the right of where the
shape sits.

-}
offset : Float -> Float -> Filter -> Filter
offset dx dy =
    f1 "feOffset" [ ( "dx", String.fromFloat dx ), ( "dy", String.fromFloat dy ) ]


{-| Draws a dark, blurred copy of the input behind it, making the shape look
like it floats above the page. This is the one-step version of the classic
blur, offset and merge pipeline.

    Filter.sourceGraphic
        |> Filter.dropShadow
            { offset = ( 3, 3 )
            , blur = 4
            , color = Color.black
            }

The shape appears with a soft black shadow peeking out below and to the right.

![drop shadow example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-drop-shadow.svg)

-}
dropShadow : { offset : ( Float, Float ), blur : Float, color : Color.Color } -> Filter -> Filter
dropShadow config inFilter =
    let
        ( ox, oy ) =
            config.offset
    in
    f1 "feDropShadow"
        [ ( "dx", String.fromFloat ox )
        , ( "dy", String.fromFloat oy )
        , ( "stdDeviation", String.fromFloat config.blur )
        , ( "flood-color", Color.toCssString config.color )
        ]
        inFilter


{-| Shaves the given radius off every edge of the image, so filled areas
shrink and thin lines get thinner or disappear. Use it to make strokes or text
look lighter, or to shrink a silhouette before building an inset effect.

    Filter.sourceGraphic |> Filter.erode 0.5

The shape appears slightly thinner all around.

![erode example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-erode.svg)

-}
erode : Float -> Filter -> Filter
erode radius =
    f1 "feMorphology" [ ( "operator", "erode" ), ( "radius", String.fromFloat radius ) ]


{-| Like `erode`, but with separate horizontal and vertical radii.

    Filter.sourceGraphic |> Filter.erodeXY 1 0.5

-}
erodeXY : Float -> Float -> Filter -> Filter
erodeXY rx ry =
    f1 "feMorphology" [ ( "operator", "erode" ), ( "radius", String.fromFloat rx ++ " " ++ String.fromFloat ry ) ]


{-| Grows every edge of the image outward by the given radius, so filled
areas expand and thin lines get fatter. Useful for making text look bolder or
for building an outline (dilate the silhouette, then subtract the original).

    Filter.sourceGraphic |> Filter.dilate 1

The shape appears slightly fatter all around.

![dilate example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-dilate.svg)

-}
dilate : Float -> Filter -> Filter
dilate radius =
    f1 "feMorphology" [ ( "operator", "dilate" ), ( "radius", String.fromFloat radius ) ]


{-| Like `dilate`, but with separate horizontal and vertical radii.

    Filter.sourceGraphic |> Filter.dilateXY 2 1

-}
dilateXY : Float -> Float -> Filter -> Filter
dilateXY rx ry =
    f1 "feMorphology" [ ( "operator", "dilate" ), ( "radius", String.fromFloat rx ++ " " ++ String.fromFloat ry ) ]


{-| Fills the whole filter area by repeating the input image side by side,
like bathroom tiles. Usually combined with `withinSubregion` to pick out the
small patch that gets repeated.

![tile example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-tile.svg)

-}
tile : Filter -> Filter
tile =
    f1 "feTile" []


{-| An option for configuring the `convolve` filter.
-}
type ConvolveOption
    = Divisor Float
    | Bias Float
    | TargetXY Int Int
    | EdgeMode String
    | PreserveAlpha


{-| Recomputes each pixel as a weighted mix of itself and its neighbors, using
the grid of weights (the kernel) you supply. Depending on the kernel this can
sharpen, emboss, detect edges, or blur; use it when you need a pixel-level
effect that none of the other filters provide.

![convolve example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-convolve.svg)

The kernel dimensions are derived automatically from the list of lists.

    -- 3x3 sharpen kernel:
    Filter.sourceGraphic
        |> Filter.convolve []
            [ [ 0, -1, 0 ]
            , [ -1, 5, -1 ]
            , [ 0, -1, 0 ]
            ]

    -- Edge detection with custom options:
    Filter.sourceGraphic
        |> Filter.convolve
            [ Filter.edgeDuplicate, Filter.bias 0.5 ]
            [ [ -1, -1, -1 ]
            , [ -1, 8, -1 ]
            , [ -1, -1, -1 ]
            ]

The first example makes details crisper; the second turns the image dark with
bright lines tracing the edges.

-}
convolve : List ConvolveOption -> List (List Float) -> Filter -> Filter
convolve options kernel inFilter =
    let
        rows =
            List.length kernel

        cols =
            kernel |> List.head |> Maybe.map List.length |> Maybe.withDefault 0

        kernelStr =
            kernel
                |> List.concatMap (List.map String.fromFloat)
                |> String.join " "

        baseArgs =
            [ ( "order", String.fromInt cols ++ " " ++ String.fromInt rows )
            , ( "kernelMatrix", kernelStr )
            ]

        optionArgs =
            List.concatMap convolveOptionToArgs options
    in
    f1 "feConvolveMatrix" (baseArgs ++ optionArgs) inFilter


convolveOptionToArgs : ConvolveOption -> List ( String, String )
convolveOptionToArgs opt =
    case opt of
        Divisor d ->
            [ ( "divisor", String.fromFloat d ) ]

        Bias b ->
            [ ( "bias", String.fromFloat b ) ]

        TargetXY tx ty ->
            [ ( "targetX", String.fromInt tx ), ( "targetY", String.fromInt ty ) ]

        EdgeMode mode ->
            [ ( "edgeMode", mode ) ]

        PreserveAlpha ->
            [ ( "preserveAlpha", "true" ) ]


{-| Sets the divisor for the convolution. By default, the divisor is the sum of
all kernel values (normalizing the result). Override this when you want to
control brightness.

    Filter.convolve [ Filter.divisor 1 ] kernel input

-}
divisor : Float -> ConvolveOption
divisor =
    Divisor


{-| Adds a constant value to the result after the kernel is applied.
Defaults to 0. Useful for shifting negative results into visible range
(e.g., for edge detection).

    Filter.convolve [ Filter.bias 0.5 ] edgeKernel input

-}
bias : Float -> ConvolveOption
bias =
    Bias


{-| Sets which pixel in the kernel aligns with the source pixel being computed.
Defaults to the center of the kernel (`floor(orderX/2)`, `floor(orderY/2)`).

    -- Aim the effect at the kernel's top-left:
    Filter.convolve [ Filter.targetXY 0 0 ] kernel input

-}
targetXY : Int -> Int -> ConvolveOption
targetXY =
    TargetXY


{-| At the edges of the image, duplicate the nearest border pixels outward.
This avoids dark or transparent borders.

    Filter.convolve [ Filter.edgeDuplicate ]
        kernel
        input

-}
edgeDuplicate : ConvolveOption
edgeDuplicate =
    EdgeMode "duplicate"


{-| At the edges of the image, wrap around to the opposite side (tiling).

    Filter.convolve [ Filter.edgeWrap ] kernel input

-}
edgeWrap : ConvolveOption
edgeWrap =
    EdgeMode "wrap"


{-| At the edges of the image, use transparent black (zero) for out-of-bounds
pixels. This is the default behavior.

    Filter.convolve [ Filter.edgeNone ] kernel input

-}
edgeNone : ConvolveOption
edgeNone =
    EdgeMode "none"


{-| When set, only the alpha channel is convolved; the RGB channels are passed
through unchanged. Useful for blurring transparency without affecting colors.

    Filter.convolve [ Filter.preserveAlpha ]
        blurKernel
        input

-}
preserveAlpha : ConvolveOption
preserveAlpha =
    PreserveAlpha


{-| A light source for use with `specularLighting` and `diffuseLighting`.
Build one with `pointLight`, `distantLight` or `spotLight`.
-}
type Light
    = PointLight { x : Float, y : Float, z : Float }
    | DistantLight { azimuth : Float, elevation : Float }
    | SpotLight { x : Float, y : Float, z : Float, pointsAtX : Float, pointsAtY : Float, pointsAtZ : Float, limitingConeAngle : Float }


{-| A light source at a specific position in 3D space, shining in all
directions like a bare light bulb hovering over the image. Areas near the
light appear brighter than areas far away.

![lighting example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-lighting.svg)

    Filter.pointLight { x = 50, y = 50, z = 200 }

-}
pointLight : { x : Float, y : Float, z : Float } -> Light
pointLight =
    PointLight


{-| A light source infinitely far away, like the sun, so its rays hit the
whole image from the same direction. `azimuth` is the compass direction the
light comes from and `elevation` is how high it sits above the horizon, both
in degrees.

    Filter.distantLight { azimuth = 45, elevation = 60 }

-}
distantLight : { azimuth : Float, elevation : Float } -> Light
distantLight =
    DistantLight


{-| A cone-shaped spotlight, like a desk lamp: it sits at `(x, y, z)`, aims at
the `pointsAt` position, and only lights what falls inside its cone.
`limitingConeAngle` (in degrees) controls how wide the cone is.
-}
spotLight : { x : Float, y : Float, z : Float, pointsAtX : Float, pointsAtY : Float, pointsAtZ : Float, limitingConeAngle : Float } -> Light
spotLight =
    SpotLight


{-| Renders shiny highlights, as if the input were a glossy 3D surface
reflecting a light. The input's transparency is treated as a height map, so
the shape appears embossed with bright glints where the light catches it. Use
it for glass, metal or plastic button effects, usually added onto the original
shape with `compositeArithmetic` or `compositeIn`.

![lighting example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-lighting.svg)

`surfaceScale` sets how tall the imaginary bumps are, `specularConstant` the
overall brightness of the reflection, and `specularExponent` how tightly
focused the glints are (higher means smaller, sharper highlights).

    Filter.sourceGraphic
        |> Filter.specularLighting
            { surfaceScale = 5
            , specularConstant = 0.75
            , specularExponent = 20
            , lightingColor = Color.white
            }
            (Filter.pointLight
                { x = 50, y = 50, z = 200 }
            )

This shows a bright glint on the shape's edges nearest the light, fading to
black elsewhere.

-}
specularLighting :
    { surfaceScale : Float
    , specularConstant : Float
    , specularExponent : Float
    , lightingColor : Color.Color
    }
    -> Light
    -> Filter
    -> Filter
specularLighting config light inFilter =
    let
        id =
            toId inFilter

        lightChild =
            lightToChild light

        colorStr =
            Color.toCssString config.lightingColor

        args =
            [ ( "in", id )
            , ( "surfaceScale", String.fromFloat config.surfaceScale )
            , ( "specularConstant", String.fromFloat config.specularConstant )
            , ( "specularExponent", String.fromFloat config.specularExponent )
            , ( "lighting-color", colorStr )
            ]
    in
    Internal.Filter
        { name = "feSpecularLighting"
        , id = "feSpecularLighting-" ++ id ++ String.join "-" (List.map (\( a, b ) -> a ++ "_" ++ b) args)
        , args = args
        , children = [ lightChild ]
        , defs = makeDefs inFilter
        }


{-| Renders soft, matte shading, as if the input were a rough 3D surface lit
by a lamp, with no shiny glints. Like `specularLighting`, it treats the
input's transparency as a height map; the result is an evenly lit embossed
look, good for paper, stone or fabric effects.

![lighting example](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/filter-lighting.svg)

`surfaceScale` sets how tall the imaginary bumps are and `diffuseConstant` the
overall brightness.

    Filter.sourceGraphic
        |> Filter.diffuseLighting
            { surfaceScale = 1
            , diffuseConstant = 1
            , lightingColor = Color.white
            }
            (Filter.distantLight
                { azimuth = 45, elevation = 55 }
            )

This shows the shape evenly lit from the upper left with a gently embossed
look.

-}
diffuseLighting :
    { surfaceScale : Float
    , diffuseConstant : Float
    , lightingColor : Color.Color
    }
    -> Light
    -> Filter
    -> Filter
diffuseLighting config light inFilter =
    let
        id =
            toId inFilter

        lightChild =
            lightToChild light

        colorStr =
            Color.toCssString config.lightingColor

        args =
            [ ( "in", id )
            , ( "surfaceScale", String.fromFloat config.surfaceScale )
            , ( "diffuseConstant", String.fromFloat config.diffuseConstant )
            , ( "lighting-color", colorStr )
            ]
    in
    Internal.Filter
        { name = "feDiffuseLighting"
        , id = "feDiffuseLighting-" ++ id ++ String.join "-" (List.map (\( a, b ) -> a ++ "_" ++ b) args)
        , args = args
        , children = [ lightChild ]
        , defs = makeDefs inFilter
        }


lightToChild : Light -> ( String, List ( String, String ) )
lightToChild light =
    case light of
        PointLight { x, y, z } ->
            ( "fePointLight"
            , [ ( "x", String.fromFloat x )
              , ( "y", String.fromFloat y )
              , ( "z", String.fromFloat z )
              ]
            )

        DistantLight { azimuth, elevation } ->
            ( "feDistantLight"
            , [ ( "azimuth", String.fromFloat azimuth )
              , ( "elevation", String.fromFloat elevation )
              ]
            )

        SpotLight config ->
            ( "feSpotLight"
            , [ ( "x", String.fromFloat config.x )
              , ( "y", String.fromFloat config.y )
              , ( "z", String.fromFloat config.z )
              , ( "pointsAtX", String.fromFloat config.pointsAtX )
              , ( "pointsAtY", String.fromFloat config.pointsAtY )
              , ( "pointsAtZ", String.fromFloat config.pointsAtZ )
              , ( "limitingConeAngle", String.fromFloat config.limitingConeAngle )
              ]
            )



-- Implementation details


hashArgs : List ( String, String ) -> String
hashArgs args =
    String.fromInt (List.foldl (\( k, v ) acc -> Internal.mixString v (Internal.mixString k acc)) 5381 args)


toId : Filter -> String
toId filter =
    case filter of
        Internal.Filter args ->
            args.id

        Internal.Virtual str ->
            str


makeDefs : Filter -> Dict String (Internal.BaseFilter {})
makeDefs filter_ =
    case filter_ of
        Internal.Filter args ->
            Dict.insert args.id { name = args.name, id = args.id, args = args.args, children = args.children } args.defs

        Internal.Virtual _ ->
            Dict.empty
