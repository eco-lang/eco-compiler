module Evg.Text exposing
    ( Span, tspan
    , richText
    , onPath
    , textLength, LengthAdjust(..)
    , dominantBaseline, Baseline(..)
    , textDecoration, TextDecoration(..)
    , letterSpacing, wordSpacing
    , writingMode, WritingMode(..)
    , dx, dy
    , fontWeight, FontWeight(..)
    , fontStyle, FontStyle(..)
    )

{-| Advanced text layout for when the basic `Evg.text` isn't enough.

Use this module when you need:

  - Mixed styling within a single line of text, such as one bold red word
    in an otherwise plain sentence

  - Text that bends to follow a curved line instead of sitting on a
    straight one

  - Fine control over spacing, boldness, decoration, and how the text sits
    relative to the point you place it at

Here is a sentence where just one word is red and bold:

    import Evg
    import Evg.Text as Text

    Text.richText [ Evg.fontSize 16 ]
        { x = 10, y = 50, anchor = Evg.Start }
        [ Text.tspan [ Evg.fillStr "black" ] "Hello, "
        , Text.tspan
            [ Evg.fillStr "red"
            , Text.fontWeight Text.Bold
            ]
            "world"
        , Text.tspan [ Evg.fillStr "black" ] "!"
        ]

A note on positioning: text is placed at a single point. The `anchor` field
decides where the text sits relative to that point horizontally (`Start`
puts the point at the left edge of the text, `Middle` centers the text on
it, `End` puts the point at the right edge), and by default the point sits
on the baseline, the invisible line the letters rest on. `dominantBaseline`
lets you change that vertical relationship.

![the same point anchoring text three ways: extending right of it, centered on it, and extending left of it](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/text-anchors.svg)


# Rich Text

@docs Span, tspan
@docs richText


# Text on a Path

@docs onPath


# Text Attributes

@docs textLength, LengthAdjust
@docs dominantBaseline, Baseline
@docs textDecoration, TextDecoration
@docs letterSpacing, wordSpacing
@docs writingMode, WritingMode
@docs dx, dy
@docs fontWeight, FontWeight
@docs fontStyle, FontStyle

-}

import Evg
import Evg.Internal as Internal exposing (Attribute(..))
import Evg.Path
import Svg.Attributes
import VirtualDom


{-| A run of text with its own styling, to be laid out as part of a
`richText` block. Create these with `tspan`.
-}
type Span msg
    = Span (List (VirtualDom.Attribute msg)) (List ( String, String )) String


{-| Creates a styled run of text. Use within `richText` to give different
parts of the same line their own color, size, weight, or font. The runs
flow one after another as a single piece of text.

    Text.tspan [ Evg.fillStr "red", Evg.fontSize 24 ]
        "important"

This produces the word "important" in large red letters wherever it falls
within the surrounding text.

-}
tspan : List (Evg.Attribute { a | text : Evg.Supported } msg) -> String -> Span msg
tspan attrs content =
    let
        { vdomAttrs, inspectable } =
            Internal.svgAttributes attrs
    in
    Span vdomAttrs inspectable content


{-| Renders several styled runs of text as one continuous line. Each run
can have its own color, size, and font, but they flow together as a single
piece of text.

The position works like `Evg.text`: the text is placed at the point
`( x, y )`, with `anchor` deciding whether that point is at the left edge
of the text (`Start`), its center (`Middle`), or its right edge (`End`).
The point sits on the baseline, so the letters rest on top of the `y`
coordinate you give.

    Text.richText [ Evg.fontSize 16 ]
        { x = 10, y = 30, anchor = Evg.Start }
        [ Text.tspan [ Evg.fillStr "black" ] "Normal "
        , Text.tspan [ Evg.fillStr "blue" ] "blue "
        , Text.tspan [ Evg.fillStr "black" ] "normal"
        ]

This shows one line of text starting at (10, 30) with only its middle word
in blue.

-}
richText :
    List (Evg.Attribute { a | text : Evg.Supported } msg)
    -> { x : Float, y : Float, anchor : Evg.TextAnchor }
    -> List (Span msg)
    -> Evg.Evg msg
richText attrs pos spans =
    let
        { vdomAttrs, eventBuilders, ownMatrix, defs, a11yChildren, inspectable, textPath } =
            Internal.svgAttributes attrs

        anchorStr =
            anchorToString pos.anchor

        baseAttrs =
            [ Svg.Attributes.x (String.fromFloat pos.x)
            , Svg.Attributes.y (String.fromFloat pos.y)
            , Svg.Attributes.textAnchor anchorStr
            ]

        spanChildren =
            List.map
                (\(Span spanAttrs spanData content) ->
                    Internal.Evg
                        { content = Internal.Tag "tspan" spanAttrs []
                        , ownMatrix = Internal.identityMat
                        , children = [ Internal.textNode content ]
                        , hash = Internal.hashStringToInt content
                        , defs = []
                        , attrs = spanData
                        }
                )
                spans

        contentChildren =
            case textPath of
                Nothing ->
                    spanChildren

                Just ( href, _ ) ->
                    [ Internal.Evg
                        { content = Internal.Tag "textPath" [ Svg.Attributes.xlinkHref ("#" ++ href) ] []
                        , ownMatrix = Internal.identityMat
                        , children = spanChildren
                        , hash = Internal.hashStringToInt href
                        , defs = []
                        , attrs = [ ( "xlink:href", "#" ++ href ) ]
                        }
                    ]
    in
    Internal.Evg
        { content = Internal.Tag "text" (baseAttrs ++ vdomAttrs) eventBuilders
        , ownMatrix = ownMatrix
        , children = a11yChildren ++ contentChildren
        , hash = Internal.attrHash attrs |> Internal.mixFloat pos.x |> Internal.mixFloat pos.y
        , defs = defs
        , attrs = [ ( "x", String.fromFloat pos.x ), ( "y", String.fromFloat pos.y ), ( "text-anchor", anchorStr ) ] ++ inspectable
        }


{-| Makes text bend to follow a path instead of running in a straight line.
Apply this attribute to `Evg.text` or `Text.richText` and each letter is
placed and rotated so the whole line of text traces the path's shape, the
way lettering follows the curve of a round badge or a wavy banner.

![the words "along a curve" bending upward and back down over an arch](https://raw.githubusercontent.com/gampleman/evg/master/docs/images/text-on-path.svg)

    import Evg.Path exposing (Path(..), PathSegment(..))

    Evg.text
        [ Evg.fillStr "black"
        , Text.onPath
            [ M ( 10, 80 )
                [ C ( 40, 10 ) ( 65, 10 ) ( 95, 80 ) ]
            ]
        ]
        { x = 0, y = 0, anchor = Evg.Start }
        "Text along a curve"

This draws the sentence climbing up and over an arch. The path itself stays
invisible; only the text shows. Text that is longer than the path gets cut
off at the path's end.

-}
onPath : List Evg.Path.Path -> Evg.Attribute { a | text : Evg.Supported } msg
onPath paths =
    let
        pathStr =
            paths |> List.map Evg.Path.toString |> String.concat

        hash =
            Internal.mixString pathStr tpHash_

        pathId =
            "e" ++ String.fromInt hash
    in
    TextPathChild hash
        pathId
        (Internal.Def pathId
            (Internal.Evg
                { content = Internal.Tag "path" [ Svg.Attributes.id pathId, Svg.Attributes.d pathStr ] []
                , ownMatrix = Internal.identityMat
                , children = []
                , hash = hash
                , defs = []
                , attrs = [ ( "id", pathId ), ( "d", pathStr ) ]
                }
            )
        )


{-| Forces text to occupy exactly the given width, stretching or squeezing
it as needed. Useful when text must line up with something of a fixed size,
such as filling the full width of a button or column regardless of how many
letters it contains. The second argument controls whether only the gaps
between letters change or the letters themselves deform too.

    Text.textLength 200 Text.SpacingAndGlyphs

This makes the text exactly 200 units wide, stretching both the letters and
the spaces between them.

-}
textLength : Float -> LengthAdjust -> Evg.Attribute { a | text : Evg.Supported } msg
textLength len adjust =
    let
        adjustStr =
            case adjust of
                Spacing ->
                    "spacing"

                SpacingAndGlyphs ->
                    "spacingAndGlyphs"
    in
    Batch
        [ Attr (Internal.mixFloat len tlHash_) "textLength" (String.fromFloat len) (Svg.Attributes.textLength (String.fromFloat len))
        , Attr (Internal.mixString adjustStr laHash_) "lengthAdjust" adjustStr (Svg.Attributes.lengthAdjust adjustStr)
        ]


{-| How text is stretched or squeezed when `textLength` forces it to a
specific width.

  - `Spacing` only changes the gaps between letters; the letters keep their
    shape, so this looks better for small adjustments
  - `SpacingAndGlyphs` stretches the letters themselves as well as the gaps,
    which distorts the letterforms but distributes big changes more evenly

-}
type LengthAdjust
    = Spacing
    | SpacingAndGlyphs


{-| Where text sits vertically relative to the `y` coordinate you place it
at. See `dominantBaseline` for what each option looks like.
-}
type Baseline
    = Auto
    | Middle
    | Hanging
    | Central
    | TextTop
    | TextBottom


{-| Controls where text sits vertically relative to the `y` coordinate you
give it. By default the letters rest on top of that coordinate, like words
sitting on a ruled line. This attribute moves that line.

  - `Auto` is the default: letters rest on top of `y`, with descenders like
    the tail of "g" dipping below
  - `Middle` centers the text vertically on `y`, which is usually what you
    want when labeling a point or centering text in a box
  - `Hanging` hangs the text below `y`, so `y` marks roughly the top of the
    letters
  - `Central` also centers on `y`, but measures from the font's overall
    height rather than the lowercase letters, so it can sit slightly
    differently than `Middle`
  - `TextTop` puts the very top of the font's tallest letters at `y`
  - `TextBottom` puts the very bottom of the font's deepest descenders at `y`

For example:

    Text.dominantBaseline Text.Hanging

This makes the text hang below the point you give instead of sitting on it.

-}
dominantBaseline : Baseline -> Evg.Attribute { a | text : Evg.Supported } msg
dominantBaseline baseline =
    let
        str =
            case baseline of
                Auto ->
                    "auto"

                Middle ->
                    "middle"

                Hanging ->
                    "hanging"

                Central ->
                    "central"

                TextTop ->
                    "text-top"

                TextBottom ->
                    "text-bottom"
    in
    Attr (Internal.mixString str dbHash_) "dominant-baseline" str (Svg.Attributes.dominantBaseline str)


{-| Lines drawn through or alongside text.

  - `Underline` draws a line under the text
  - `Overline` draws a line above the text
  - `LineThrough` strikes the text out with a line through its middle
  - `NoDecoration` removes any of the above

-}
type TextDecoration
    = Underline
    | Overline
    | LineThrough
    | NoDecoration


{-| Draws a decorative line on the text: underneath it, above it, or
striking through it.

    Text.textDecoration Text.Underline

This underlines the text.

-}
textDecoration : TextDecoration -> Evg.Attribute { a | text : Evg.Supported } msg
textDecoration decoration =
    let
        str =
            case decoration of
                Underline ->
                    "underline"

                Overline ->
                    "overline"

                LineThrough ->
                    "line-through"

                NoDecoration ->
                    "none"
    in
    Attr (Internal.mixString str tdHash_) "text-decoration" str (Svg.Attributes.textDecoration str)


{-| Adjusts the space between individual letters. Positive values spread
the letters apart, negative values squeeze them closer together.

    Text.letterSpacing 2

This adds 2 units of extra space between every pair of letters, giving the
text an airy, spaced-out look.

-}
letterSpacing : Float -> Evg.Attribute { a | text : Evg.Supported } msg
letterSpacing value =
    Attr (Internal.mixFloat value lsHash_) "letter-spacing" (String.fromFloat value) (Svg.Attributes.letterSpacing (String.fromFloat value))


{-| Adjusts the space between words, leaving the letters within each word
untouched. Positive values push the words apart, negative values pull them
together.

    Text.wordSpacing 5

This adds 5 units of extra space at every gap between words.

-}
wordSpacing : Float -> Evg.Attribute { a | text : Evg.Supported } msg
wordSpacing value =
    Attr (Internal.mixFloat value wsHash_) "word-spacing" (String.fromFloat value) (Svg.Attributes.wordSpacing (String.fromFloat value))


{-| The direction lines of text run.

  - `HorizontalTB` is ordinary horizontal text, with lines stacking top to
    bottom
  - `VerticalRL` runs text top to bottom, with successive lines stacking
    right to left, as in traditional Japanese layout
  - `VerticalLR` runs text top to bottom, with successive lines stacking
    left to right

-}
type WritingMode
    = HorizontalTB
    | VerticalRL
    | VerticalLR


{-| Controls whether text is written horizontally or vertically.

    Text.writingMode Text.VerticalRL

This makes the text run from top to bottom, as in traditional Japanese
layout.

-}
writingMode : WritingMode -> Evg.Attribute { a | text : Evg.Supported } msg
writingMode mode =
    let
        str =
            case mode of
                HorizontalTB ->
                    "horizontal-tb"

                VerticalRL ->
                    "vertical-rl"

                VerticalLR ->
                    "vertical-lr"
    in
    Attr (Internal.mixString str wmHash_) "writing-mode" str (Svg.Attributes.writingMode str)


{-| Nudges text sideways from where it would otherwise be drawn. Positive
values move it right, negative values move it left. Handy for fine-tuning a
label's position without recomputing its `x` coordinate, or for offsetting
one span inside `richText`.

    Text.dx 5

This shifts the text 5 units to the right.

-}
dx : Float -> Evg.Attribute { a | text : Evg.Supported } msg
dx value =
    Attr (Internal.mixFloat value dxHash_) "dx" (String.fromFloat value) (Svg.Attributes.dx (String.fromFloat value))


{-| Nudges text up or down from where it would otherwise be drawn. Positive
values move it down, negative values move it up. A common trick is to use
this on spans inside `richText` to create superscripts and subscripts.

    Text.dy 10

This shifts the text 10 units down.

-}
dy : Float -> Evg.Attribute { a | text : Evg.Supported } msg
dy value =
    Attr (Internal.mixFloat value dyHash_) "dy" (String.fromFloat value) (Svg.Attributes.dy (String.fromFloat value))


{-| How thick the strokes of the letters are.

  - `Normal` is regular text
  - `Bold` is heavy text
  - `Bolder` is one step heavier than the surrounding text
  - `Lighter` is one step lighter than the surrounding text
  - `Weight n` picks an exact weight on the usual 100 to 900 scale, where
    400 is normal and 700 is bold (the font must provide that weight for it
    to show)

-}
type FontWeight
    = Normal
    | Bold
    | Bolder
    | Lighter
    | Weight Int


{-| Controls how bold the text looks.

    Text.fontWeight Text.Bold

    Text.fontWeight (Text.Weight 600)

The second example produces a semi-bold weight, between normal and bold.

-}
fontWeight : FontWeight -> Evg.Attribute { a | text : Evg.Supported } msg
fontWeight weight =
    let
        str =
            case weight of
                Normal ->
                    "normal"

                Bold ->
                    "bold"

                Bolder ->
                    "bolder"

                Lighter ->
                    "lighter"

                Weight n ->
                    String.fromInt n
    in
    Attr (Internal.mixString str fwHash_) "font-weight" str (Svg.Attributes.fontWeight str)


{-| Whether the letters are upright or slanted.

  - `StyleNormal` is upright text
  - `Italic` uses the font's italic letterforms, which are usually slanted
    and often more cursive
  - `Oblique` simply slants the normal letterforms without changing their
    shapes

-}
type FontStyle
    = StyleNormal
    | Italic
    | Oblique


{-| Controls whether the text is upright or slanted.

    Text.fontStyle Text.Italic

This renders the text in slanted italic letters.

-}
fontStyle : FontStyle -> Evg.Attribute { a | text : Evg.Supported } msg
fontStyle style =
    let
        str =
            case style of
                StyleNormal ->
                    "normal"

                Italic ->
                    "italic"

                Oblique ->
                    "oblique"
    in
    Attr (Internal.mixString str fsHash_) "font-style" str (Svg.Attributes.fontStyle str)



-- Internal


anchorToString : Evg.TextAnchor -> String
anchorToString anchor =
    case anchor of
        Evg.Start ->
            "start"

        Evg.Middle ->
            "middle"

        Evg.End ->
            "end"



-- Precomputed hash constants


tpHash_ : Int
tpHash_ =
    -976228043


tlHash_ : Int
tlHash_ =
    1867193460


laHash_ : Int
laHash_ =
    -1829680416


dbHash_ : Int
dbHash_ =
    5174147


tdHash_ : Int
tdHash_ =
    5173653


lsHash_ : Int
lsHash_ =
    5173914


wsHash_ : Int
wsHash_ =
    5173735


wmHash_ : Int
wmHash_ =
    5173753


dxHash_ : Int
dxHash_ =
    5174169


dyHash_ : Int
dyHash_ =
    5174168


fwHash_ : Int
fwHash_ =
    2136892850


fsHash_ : Int
fsHash_ =
    -2143184287
