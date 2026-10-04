module Compiler.Reporting.Doc exposing
    ( Doc
    , plus, append, a
    , align, cat, empty, fill, fillSep, hang
    , hcat, hsep, indent, sep, vcat
    , Color
    , red, cyan, green, blue, black, yellow
    , dullred, dullcyan, dullyellow
    , fromChars, fromName, fromVersion, fromPackage, fromInt
    , toAnsi, toString, toLine
    , encode
    , stack, reflow, commaSep
    , toSimpleNote, toFancyNote, toSimpleHint, toFancyHint
    , link, fancyLink, reflowLink, makeLink, makeNakedLink
    , args, ordinal, intToOrdinal, cycle
    )

{-| The compiler's messages to people, its error reports and help text, are
built as documents, and this module is the vocabulary they are built in.

A _document_ (`Doc`) is a description of text that is laid out only when it is
rendered, once the width of the page is known. It is the document of
`Text.PrettyPrint.ANSI.Leijen`, and that module's docstrings own the rules of
layout and styling. This module passes its combinators and colours through
unchanged. Besides conversions from values such as a version or a package name,
it adds two things of its own.

The first is the ways a finished document leaves the compiler. `toAnsi` writes
it to a handle, laid out for a page 80 columns wide, with its colours and
underlines as ANSI escape sequences. `toString` lays it out at the same width
with every style switched off, and `toLine` at a width so large that no group
ever needs to break. `encode` turns it into JSON, in which each run of text
records its style as data rather than as escape sequences.

The second is phrasing: the shapes that recur across compiler messages. They
are a paragraph reflowed from a plain string, a list joined with commas and a
conjunction, a paragraph that opens with an underlined `Note:` or `Hint:`, a
link to a page of documentation on elm-lang.org, a count of arguments, an
ordinal such as `2nd`, and a box diagram of a cycle of names.

Four of the passed-through combinators do not do what their names suggest. `a`
and `plus` take their arguments in pipeline order, so `x |> a y` is `x`
immediately followed by `y` and `x |> plus y` puts a space between them. `fill`
indents a document and does not pad it to a width. `hcat` keeps only the last
of two or more documents.


# Document Type

@docs Doc


# Combinators

@docs plus, append, a
@docs align, cat, empty, fill, fillSep, hang
@docs hcat, hsep, indent, sep, vcat


# Colors

@docs Color
@docs red, cyan, green, blue, black, yellow
@docs dullred, dullcyan, dullyellow


# Conversion from Values

@docs fromChars, fromName, fromVersion, fromPackage, fromInt


# Rendering

@docs toAnsi, toString, toLine
@docs encode


# High-Level Formatting

@docs stack, reflow, commaSep


# Notes and Hints

@docs toSimpleNote, toFancyNote, toSimpleHint, toFancyHint


# Links and References

@docs link, fancyLink, reflowLink, makeLink, makeNakedLink


# Helpers

@docs args, ordinal, intToOrdinal, cycle

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Encode as E
import Maybe.Extra as Maybe
import Prelude
import System.Console.Ansi as Ansi
import System.IO exposing (Handle)
import Task exposing (Task)
import Text.PrettyPrint.ANSI.Leijen as P



-- ====== Conversion from Values ======


{-| Creates a document holding the string as it is, with no style.
-}
fromChars : String -> Doc
fromChars =
    P.text


{-| Creates a document holding the name as it is, with no style.
-}
fromName : Name -> Doc
fromName =
    P.text


{-| Creates a document holding the version in its written form, such as
`1.0.5`.
-}
fromVersion : V.Version -> Doc
fromVersion vsn =
    P.text (V.toChars vsn)


{-| Creates a document holding the package name as `author/project`.
-}
fromPackage : Pkg.Name -> Doc
fromPackage pkg =
    P.text (Pkg.toChars pkg)


{-| Creates a document holding the integer in decimal.
-}
fromInt : Int -> Doc
fromInt n =
    P.text (String.fromInt n)



-- ====== Rendering ======


{-| Writes `doc` to `handle`, laid out for a page 80 columns wide, with its
colours and underlines as ANSI escape sequences.

The escape sequences are written whatever the handle is; nothing here checks
whether it is a terminal. Write errors are discarded, as `System.IO.write`
describes.

-}
toAnsi : Handle -> Doc -> Task Never ()
toAnsi handle doc =
    P.displayIO handle (P.renderPretty 80 doc)


{-| Returns `doc` as text laid out for a page 80 columns wide, with every
colour and underline switched off.

Switching the styles off does not leave the text free of escape sequences: a
reset sequence still comes before each line break that follows text, as
`Text.PrettyPrint.ANSI.Leijen.plain` describes.

-}
toString : Doc -> String
toString doc =
    P.displayS (P.renderPretty 80 (P.plain doc)) ""


{-| Returns `doc` as text with every style switched off, laid out for a page
about a thousand million columns wide, so that every group fits on its line
and none of its breaks is taken.

A break that is not in a group, such as one between the documents of `vcat` or
`stack`, is still taken, so the result can contain line breaks. Reset escape
sequences remain, as they do in `toString`.

-}
toLine : Doc -> String
toLine doc =
    let
        maxBound : number
        maxBound =
            2147483647
    in
    P.displayS (P.renderPretty (maxBound // 2) (P.plain doc)) ""



-- ====== High-Level Formatting ======


{-| Joins the documents with `vcat`, putting an empty line between each pair.
-}
stack : List Doc -> Doc
stack docs =
    P.vcat (List.intersperse (P.text "") docs)


{-| Creates a paragraph from `paragraph`: its words, split at whitespace, are
filled into lines as `fillSep` fills them.

The original spacing and line breaks of the string are not kept.

-}
reflow : String -> Doc
reflow paragraph =
    P.fillSep (List.map P.text (String.words paragraph))


{-| Returns the pieces of an English list of `names`, each styled with
`addStyle`, for the caller to join with spaces: one name alone, two joined by
`conjunction`, and three or more as `a, b, and c`, with a comma after every
name but the last and `conjunction` before the last.

`addStyle` is not applied to the commas or to `conjunction`. An empty list of
names aborts the program.

-}
commaSep : Doc -> (Doc -> Doc) -> List Doc -> List Doc
commaSep conjunction addStyle names =
    case names of
        [ name ] ->
            [ addStyle name ]

        [ name1, name2 ] ->
            [ addStyle name1, conjunction, addStyle name2 ]

        _ ->
            List.map (\name -> P.append (addStyle name) (P.text ",")) (Prelude.init names)
                ++ [ conjunction
                   , addStyle (Prelude.last names)
                   ]



-- ====== Notes ======


{-| Creates a paragraph that opens with `Note:`, with `Note` underlined, and
continues with the words of `message`, filled as `reflow` fills them.
-}
toSimpleNote : String -> Doc
toSimpleNote message =
    toFancyNote (List.map P.text (String.words message))


{-| Creates a paragraph that opens with `Note:`, with `Note` underlined, and
continues with `chunks`, filled into lines as `fillSep` fills them.
-}
toFancyNote : List Doc -> Doc
toFancyNote chunks =
    P.fillSep (P.append (P.underline (P.text "Note")) (P.text ":") :: chunks)



-- ====== Hints ======


{-| Creates a paragraph that opens with `Hint:`, with `Hint` underlined, and
continues with the words of `message`, filled as `reflow` fills them.
-}
toSimpleHint : String -> Doc
toSimpleHint message =
    toFancyHint (List.map P.text (String.words message))


{-| Creates a paragraph that opens with `Hint:`, with `Hint` underlined, and
continues with `chunks`, filled into lines as `fillSep` fills them.
-}
toFancyHint : List Doc -> Doc
toFancyHint chunks =
    P.fillSep (P.append (P.underline (P.text "Hint")) (P.text ":") :: chunks)



-- ====== Links and References ======


{-| Creates a paragraph that opens with `word` underlined and followed by a
colon, then the words of `before`, the link `makeLink` gives for `fileName`,
and the words of `after`, filled into lines as `fillSep` fills them.
-}
link : String -> String -> String -> String -> Doc
link word before fileName after =
    P.fillSep <|
        P.append (P.underline (P.text word)) (P.text ":")
            :: List.map P.text (String.words before)
            ++ P.text (makeLink fileName)
            :: List.map P.text (String.words after)


{-| Does what `link` does, but takes the text before and after the link as
documents, so that they can carry styles.
-}
fancyLink : String -> List Doc -> String -> List Doc -> Doc
fancyLink word before fileName after =
    P.fillSep <|
        P.append (P.underline (P.text word)) (P.text ":")
            :: before
            ++ P.text (makeLink fileName)
            :: after


{-| Returns the address `makeNakedLink` gives for `fileName`, between angle
brackets.
-}
makeLink : String -> String
makeLink fileName =
    "<" ++ makeNakedLink fileName ++ ">"


{-| Returns the address of the page `fileName` on elm-lang.org, under the
version of Elm this compiler implements: `https://elm-lang.org/0.19.1/` followed
by `fileName` as given.
-}
makeNakedLink : String -> String
makeNakedLink fileName =
    "https://elm-lang.org/" ++ V.toChars V.elmCompiler ++ "/" ++ fileName


{-| Creates a paragraph of the words of `before`, the link `makeLink` gives for
`fileName`, and the words of `after`, filled into lines as `fillSep` fills
them. Unlike `link`, it has no underlined opening word.
-}
reflowLink : String -> String -> String -> Doc
reflowLink before fileName after =
    P.fillSep <|
        List.map P.text (String.words before)
            ++ P.text (makeLink fileName)
            :: List.map P.text (String.words after)



-- ====== Helpers ======


{-| Returns `n` followed by the word for it: `1 argument` for one, and
`n arguments` for any other number, zero included.
-}
args : Int -> String
args n =
    String.fromInt n
        ++ (if n == 1 then
                " argument"

            else
                " arguments"
           )


{-| Returns the English ordinal of a position counted from zero, so the first
position gives `1st`.
-}
ordinal : Index.ZeroBased -> String
ordinal index =
    intToOrdinal (Index.toHuman index)


{-| Returns `number` followed by its English ordinal suffix, such as `1st`,
`22nd`, `103rd` or `4th`. Numbers ending in 11, 12 or 13 take `th`, as in
`11th` and `112th`.
-}
intToOrdinal : Int -> String
intToOrdinal number =
    let
        remainder100 : Int
        remainder100 =
            modBy 100 number

        ending : String
        ending =
            if List.member remainder100 [ 11, 12, 13 ] then
                "th"

            else
                let
                    remainder10 : Int
                    remainder10 =
                        modBy 10 number
                in
                if remainder10 == 1 then
                    "st"

                else if remainder10 == 2 then
                    "nd"

                else if remainder10 == 3 then
                    "rd"

                else
                    "th"
    in
    String.fromInt number ++ ending


{-| Creates a diagram of a cycle that starts at `name`, runs through `names` in
order and returns to `name`, indented by `indent_` columns.

Each name is on a line of its own, in dull yellow, with a downward arrow on the
line between each pair. A box drawn in Unicode line characters joins the last
name back to the first. With `names` empty, the diagram shows `name` alone, a
name that depends on itself.

The lines are joined with `vcat`, so they are on separate lines unless the
diagram is placed inside a group that fits on one line.

-}
cycle : Int -> Name -> List Name -> Doc
cycle indent_ name names =
    let
        toLn : Name -> P.Doc
        toLn n =
            P.append cycleLn (P.dullyellow (fromName n))
    in
    (cycleTop
        :: List.intersperse cycleMid (toLn name :: List.map toLn names)
        ++ [ cycleEnd ]
    )
        |> P.vcat
        |> P.indent indent_


{-| The top line of a `cycle` diagram, the top of the box.
-}
cycleTop : Doc
cycleTop =
    if isWindows then
        P.text "+-----+"

    else
        P.text "┌─────┐"


{-| The start of a line of a `cycle` diagram that holds a name: the left side
of the box and the space before the name.
-}
cycleLn : Doc
cycleLn =
    if isWindows then
        P.text "|    "

    else
        P.text "│    "


{-| The line of a `cycle` diagram between two names: the left side of the box
and a downward arrow.
-}
cycleMid : Doc
cycleMid =
    if isWindows then
        P.text "|     |"

    else
        P.text "│     ↓"


{-| The bottom line of a `cycle` diagram, the bottom of the box.
-}
cycleEnd : Doc
cycleEnd =
    if isWindows then
        P.text "+-<---+"

    else
        P.text "└─────┘"


{-| The switch that would draw the `cycle` diagram in ASCII characters instead
of Unicode line characters. It is always `False`, so the ASCII forms are never
used.
-}
isWindows : Bool
isWindows =
    False



-- ====== JSON Encoding ======


{-| Returns `doc` laid out for a page 80 columns wide, as a JSON array of runs
of text.

A new run starts before each styled string and at each reset, so two runs in a
row can have the same style. A run with no style is a JSON string. A run with a
style is an object with fields `bold` and `underline`, both booleans, `color`,
which is a `Color` name or `null`, and `string`, the text. Line breaks are
written into the text as a newline followed by the indentation of the next
line.

The style of a run is what a terminal would show at that point, so where one
styled string follows another with no reset between them, as
`Text.PrettyPrint.ANSI.Leijen.renderPretty` describes, the second run keeps the
attributes of the first. A run can be empty: when the document begins with
styled text, the array begins with the empty string. No function in
`Text.PrettyPrint.ANSI.Leijen` makes text bold.

-}
encode : Doc -> E.Value
encode doc =
    E.array (toJsonHelp noStyle [] (P.renderPretty 80 doc))


{-| The style in effect at a point in the rendered text, as `encode` records it:
whether it is bold, whether it is underlined, in that order, and its colour, if
it has one.
-}
type Style
    = Style Bool Bool (Maybe Color)


{-| The style with bold, underline and colour all off: the style at the start
of the text and after a reset.
-}
noStyle : Style
noStyle =
    Style False False Nothing


{-| A colour as `encode` names it.

Each of the six colours has two constructors. The one written with only an
initial capital, such as `Red`, is the dull shade, and the one in capitals,
such as `RED`, is the vivid shade. `encode` writes a dull shade in lower case
and a vivid one in capitals, so `Red` is `"red"` and `RED` is `"RED"`.

A document can carry only the colours of `Text.PrettyPrint.ANSI.Leijen.Color`,
which has no dull green, blue or black, so `encode` never writes `Green`,
`Blue` or `Black`.

-}
type Color
    = Red
    | RED
    | Yellow
    | YELLOW
    | Green
    | GREEN
    | Cyan
    | CYAN
    | Blue
    | BLUE
    | Black
    | BLACK


{-| Returns the runs of `simpleDoc`, given that `style` is in effect and that
`revChunks` holds, latest first, the text written since the last list of SGR
commands, or since the start.

Every list of SGR commands in `simpleDoc` closes the current run, even one that
is empty or one that does not change the style.

-}
toJsonHelp : Style -> List String -> P.SimpleDoc -> List E.Value
toJsonHelp style revChunks simpleDoc =
    case simpleDoc of
        P.SEmpty ->
            [ encodeChunks style revChunks ]

        P.SText string rest ->
            toJsonHelp style (string :: revChunks) rest

        P.SLine indent_ rest ->
            toJsonHelp style (String.repeat indent_ " " :: "\n" :: revChunks) rest

        P.SSGR sgrs rest ->
            encodeChunks style revChunks :: toJsonHelp (sgrToStyle sgrs style) [] rest


{-| Returns `style` after the commands `sgrs`, applied in order: a reset gives
`noStyle`, a bold or underline command turns that attribute on, and a colour
command replaces the colour, each leaving the rest as it was.
-}
sgrToStyle : List Ansi.SGR -> Style -> Style
sgrToStyle sgrs ((Style bold underline color) as style) =
    case sgrs of
        [] ->
            style

        sgr :: rest ->
            sgrToStyle rest <|
                case sgr of
                    Ansi.Reset ->
                        noStyle

                    Ansi.SetConsoleIntensity i ->
                        Style (isBold i) underline color

                    Ansi.SetUnderlining u ->
                        Style bold (isUnderline u) color

                    Ansi.SetColor l i c ->
                        Style bold underline (toColor l i c)


{-| Returns `True`: bold is the only intensity `System.Console.Ansi` has.
-}
isBold : Ansi.ConsoleIntensity -> Bool
isBold intensity =
    case intensity of
        Ansi.BoldIntensity ->
            True


{-| Returns `True`: a single underline is the only underline
`System.Console.Ansi` has.
-}
isUnderline : Ansi.Underlining -> Bool
isUnderline underlining =
    case underlining of
        Ansi.SingleUnderline ->
            True


{-| Returns the `Color` for an SGR colour in the given shade. Each of the six
colours of `System.Console.Ansi` has a `Color` in both shades, and the
foreground is that module's only layer, so the result is always `Just`.
-}
toColor : Ansi.ConsoleLayer -> Ansi.ColorIntensity -> Ansi.Color -> Maybe Color
toColor layer intensity color =
    case layer of
        Ansi.Foreground ->
            let
                pick : b -> b -> b
                pick dull vivid =
                    case intensity of
                        Ansi.Dull ->
                            dull

                        Ansi.Vivid ->
                            vivid
            in
            Just <|
                case color of
                    Ansi.Red ->
                        pick Red RED

                    Ansi.Yellow ->
                        pick Yellow YELLOW

                    Ansi.Green ->
                        pick Green GREEN

                    Ansi.Cyan ->
                        pick Cyan CYAN

                    Ansi.Blue ->
                        pick Blue BLUE

                    Ansi.Black ->
                        pick Black BLACK


{-| Returns one run of `encode`'s output: the text of `revChunks` in the order
it was written, as a bare JSON string if `style` has no attribute and no
colour, and otherwise as an object carrying the style.
-}
encodeChunks : Style -> List String -> E.Value
encodeChunks (Style bold underline color) revChunks =
    let
        chars : String
        chars =
            String.concat (List.reverse revChunks)
    in
    case ( color, not bold && not underline ) of
        ( Nothing, True ) ->
            E.chars chars

        _ ->
            E.object
                [ ( "bold", E.bool bold )
                , ( "underline", E.bool underline )
                , ( "color", Maybe.unwrap E.null encodeColor color )
                , ( "string", E.chars chars )
                ]


{-| Returns the JSON name of a colour: the constructor name in lower case for a
dull shade and in capitals for a vivid one.
-}
encodeColor : Color -> E.Value
encodeColor color =
    E.string <|
        case color of
            Red ->
                "red"

            RED ->
                "RED"

            Yellow ->
                "yellow"

            YELLOW ->
                "YELLOW"

            Green ->
                "green"

            GREEN ->
                "GREEN"

            Cyan ->
                "cyan"

            CYAN ->
                "CYAN"

            Blue ->
                "blue"

            BLUE ->
                "BLUE"

            Black ->
                "black"

            BLACK ->
                "BLACK"



-- ====== Document Type and Combinators ======


{-| A document: a description of text, possibly coloured and underlined, that
is laid out when it is rendered. It is `Text.PrettyPrint.ANSI.Leijen.Doc`, and
is interchangeable with it.
-}
type alias Doc =
    P.Doc


{-| Returns the second document immediately followed by the first, with no
separator, so that `x |> a y` is `x` then `y`.
-}
a : Doc -> Doc -> Doc
a =
    P.a


{-| Returns the second document, a space, then the first, so that
`x |> plus y` is `x`, a space, then `y`. If either document is `empty`, no
space is added.
-}
plus : Doc -> Doc -> Doc
plus =
    P.plus


{-| Returns the first document immediately followed by the second, with no
separator.
-}
append : Doc -> Doc -> Doc
append =
    P.append


{-| Sets the indentation inside the document to the column at which it starts,
so that its later lines start under its first character unless something
nested within it changes the indentation.
-}
align : Doc -> Doc
align =
    P.align


{-| Joins the documents with no separator if they all fit on the rest of the
line, and otherwise puts each on its own line.
-}
cat : List Doc -> Doc
cat =
    P.cat


{-| The document with no content.
-}
empty : Doc
empty =
    P.empty


{-| Does the same as `indent`. Despite its name, it does not pad a document to
a width.
-}
fill : Int -> Doc -> Doc
fill =
    P.fill


{-| Joins the documents with breaks that are each a space if what follows fits
on the line, and a line break otherwise, filling lines the way a paragraph
does.
-}
fillSep : List Doc -> Doc
fillSep =
    P.fillSep


{-| Sets the indentation inside the document to the given number of columns to
the right of the column at which it starts. The first line is not moved.
-}
hang : Int -> Doc -> Doc
hang =
    P.hang


{-| Returns `empty` for an empty list and the document itself for a list of
one. For a list of two or more it returns only the last document, as
`Text.PrettyPrint.ANSI.Leijen.hcat` describes; the others are dropped.
-}
hcat : List Doc -> Doc
hcat =
    P.hcat


{-| Joins the documents with a space between each pair, never a line break.
-}
hsep : List Doc -> Doc
hsep =
    P.hsep


{-| Writes the given number of spaces before the document, and indents its
later lines by the same amount relative to where those spaces begin.
-}
indent : Int -> Doc -> Doc
indent =
    P.indent


{-| Joins the documents with spaces if they all fit on the rest of the line,
and otherwise puts each on its own line.
-}
sep : List Doc -> Doc
sep =
    P.sep


{-| Joins the documents with a line break between each pair. Inside a group
that fits on one line, such as `cat` makes, the breaks become nothing and the
documents run together.
-}
vcat : List Doc -> Doc
vcat =
    P.vcat


{-| Colours every string in the document vivid red, replacing any colour it
had.
-}
red : Doc -> Doc
red =
    P.red


{-| Colours every string in the document vivid cyan, replacing any colour it
had.
-}
cyan : Doc -> Doc
cyan =
    P.cyan


{-| Colours every string in the document vivid green, replacing any colour it
had.
-}
green : Doc -> Doc
green =
    P.green


{-| Colours every string in the document vivid blue, replacing any colour it
had.
-}
blue : Doc -> Doc
blue =
    P.blue


{-| Colours every string in the document vivid black, replacing any colour it
had.
-}
black : Doc -> Doc
black =
    P.black


{-| Colours every string in the document vivid yellow, replacing any colour it
had.
-}
yellow : Doc -> Doc
yellow =
    P.yellow


{-| Colours every string in the document dull red, replacing any colour it had.
-}
dullred : Doc -> Doc
dullred =
    P.dullred


{-| Colours every string in the document dull cyan, replacing any colour it
had.
-}
dullcyan : Doc -> Doc
dullcyan =
    P.dullcyan


{-| Colours every string in the document dull yellow, replacing any colour it
had.
-}
dullyellow : Doc -> Doc
dullyellow =
    P.dullyellow
