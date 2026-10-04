module Text.PrettyPrint.ANSI.Leijen exposing
    ( Doc, SimpleDoc(..), Style, Color
    , text, empty
    , append, plus, a
    , align, indent, hang, fill
    , cat, hcat, vcat, sep, hsep, fillSep
    , plain, underline
    , red, green, blue, cyan, yellow, black
    , dullred, dullcyan, dullyellow
    , renderPretty, displayS, displayIO
    )

{-| Messages for a terminal have to be laid out to fit its width and may be
coloured, and this module is the pretty printer that does both.

A _document_ (`Doc`) is a description of text that the renderer lays out later,
once the page width is known. It is the `Pretty.Doc` of the
`the-sett/elm-pretty-printer` package, so the layout rules are that package's.
Do not read the names here as promises: `fill` indents and does not pad to a
width, and `hcat` keeps only the last of its documents.

Most combinators come down to one idea, the _group_. A line break inside a
group is either taken or, if the whole group fits on the remaining line,
replaced by its flat form, which is a space or nothing depending on the break.
`cat` and `sep` group their documents; `vcat` does not, so its breaks are
taken unless it is placed inside a group that fits. `fillSep` decides each
break on its own. The joining functions `vcat`, `cat`, `sep`, `hsep` and
`fillSep` skip any element that is the value `empty` itself, so it adds no
separator. A document with no content built another way, such as `sep []`, is
not skipped.

`a` and `plus` take their arguments in pipeline order: `x |> a y` is `x`
immediately followed by `y`, and `x |> plus y` is `x`, a space, then `y`.
Called directly, `a y x` is likewise `x` then `y`. `append x y` is `x` then
`y`.

Every string in a document may carry a `Style`: bold, underline and a colour.
The styling functions change the style of every string inside the document
they are given, so the outermost colour applied wins. Rendering is in two
steps. `renderPretty` lays a document out as a `SimpleDoc`, in which styles
have become SGR commands, the terminal styling commands that
`System.Console.Ansi` describes. `displayS` then writes it as a string with
escape sequences, and `displayIO` writes that string to a handle.


# Core Types

@docs Doc, SimpleDoc, Style, Color


# Document Construction

@docs text, empty


# Document Combinators

@docs append, plus, a


# Layout Combinators

@docs align, indent, hang, fill


# List Combinators

@docs cat, hcat, vcat, sep, hsep, fillSep


# Styling

@docs plain, underline


# Colors (Vivid)

@docs red, green, blue, cyan, yellow, black


# Colors (Dull)

@docs dullred, dullcyan, dullyellow


# Rendering

@docs renderPretty, displayS, displayIO

-}

import Pretty as P
import Pretty.Renderer as PR
import System.Console.Ansi as Ansi
import System.IO as IO
import Task exposing (Task)


{-| A document whose strings may each carry a `Style`.

This is `Pretty.Doc Style`, so the functions of `Pretty` work on it as well as
the ones here.

-}
type alias Doc =
    P.Doc Style


{-| A document after layout: a chain of pieces to write in order, ending in
`SEmpty`.

`SText` is a string to write as it is.

`SLine` is a line break followed by the given number of spaces of indentation.

`SSGR` is a list of SGR commands to write, in order, before the rest. An empty
list writes nothing.

-}
type SimpleDoc
    = SEmpty
    | SText String SimpleDoc
    | SLine Int SimpleDoc
    | SSGR (List Ansi.SGR) SimpleDoc


{-| Writes `simpleDoc` to `handle` as the text `displayS` gives, escape
sequences included.

Write errors are discarded, as `System.IO.write` describes.

-}
displayIO : IO.Handle -> SimpleDoc -> Task Never ()
displayIO handle simpleDoc =
    IO.write handle (displayS simpleDoc "")


{-| Lays out `doc` for a page `w` columns wide, keeping each group on one line
where it fits in what remains of the line. The first argument is ignored.

Styles become `SSGR` pieces. Before each string that carries a style come the
SGR commands for that style, and before the first string without a style that
follows, a reset. The indentation after a line break is a string without a
style, so the first line break after styled text is preceded by a reset.

Three consequences are easy to miss. Between two styled strings there is no
reset, so the attributes of the first stay on for the second: underline
followed by red gives underlined red. A document that ends in styled text ends
without a reset. And a string whose style has every field off still counts as
styled, so a reset still comes before the next string without a style, although
it set nothing; `plain` gives every string such a style.

-}
renderPretty : Int -> Doc -> SimpleDoc
renderPretty w doc =
    PR.pretty w
        { init = { styled = False, newline = False, list = [] }
        , tagged =
            \style str acc ->
                { acc | styled = True, list = SText str :: SSGR (styleToSgrs style) :: acc.list }
        , untagged =
            \str acc ->
                let
                    newAcc : { styled : Bool, newline : Bool, list : List (SimpleDoc -> SimpleDoc) }
                    newAcc =
                        if acc.styled then
                            { acc | styled = False, list = SSGR [ Ansi.Reset ] :: acc.list }

                        else
                            acc
                in
                if newAcc.newline then
                    { newAcc | newline = False, list = SLine (String.length str) :: newAcc.list }

                else
                    { newAcc | list = SText str :: newAcc.list }
        , newline = \acc -> { acc | newline = True }
        , outer = \{ list } -> List.foldl (<|) SEmpty list
        }
        doc


{-| Returns the SGR commands that turn on `style`: bold, then underline, then
the foreground colour, each only if set. The default style gives an empty list.
-}
styleToSgrs : Style -> List Ansi.SGR
styleToSgrs style =
    [ if style.bold then
        Just (Ansi.SetConsoleIntensity Ansi.BoldIntensity)

      else
        Nothing
    , if style.underline then
        Just (Ansi.SetUnderlining Ansi.SingleUnderline)

      else
        Nothing
    , style.color
        |> Maybe.map
            (\color ->
                case color of
                    Red ->
                        Ansi.SetColor Ansi.Foreground Ansi.Vivid Ansi.Red

                    Green ->
                        Ansi.SetColor Ansi.Foreground Ansi.Vivid Ansi.Green

                    Cyan ->
                        Ansi.SetColor Ansi.Foreground Ansi.Vivid Ansi.Cyan

                    Blue ->
                        Ansi.SetColor Ansi.Foreground Ansi.Vivid Ansi.Blue

                    Black ->
                        Ansi.SetColor Ansi.Foreground Ansi.Vivid Ansi.Black

                    Yellow ->
                        Ansi.SetColor Ansi.Foreground Ansi.Vivid Ansi.Yellow

                    DullCyan ->
                        Ansi.SetColor Ansi.Foreground Ansi.Dull Ansi.Cyan

                    DullRed ->
                        Ansi.SetColor Ansi.Foreground Ansi.Dull Ansi.Red

                    DullYellow ->
                        Ansi.SetColor Ansi.Foreground Ansi.Dull Ansi.Yellow
            )
    ]
        |> List.filterMap identity


{-| Returns `acc` followed by the text of `simpleDoc`, with each SGR command
written as an escape sequence: the escape character, `[`, a code, then `m`.

The codes are 0 for a reset, 1 for bold and 4 for underline. A dull colour is
30 to 36 and a vivid one 90 to 96: black, red, green, yellow, blue and cyan are
0, 1, 2, 3, 4 and 6 above the base. The colour's layer is not looked at; every
colour is written as a foreground colour.

-}
displayS : SimpleDoc -> String -> String
displayS simpleDoc acc =
    case simpleDoc of
        SEmpty ->
            acc

        SText str sd ->
            displayS sd (acc ++ str)

        SLine n sd ->
            displayS sd (acc ++ "\n" ++ String.repeat n " ")

        SSGR (Ansi.Reset :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[0m")

        SSGR ((Ansi.SetUnderlining Ansi.SingleUnderline) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[4m")

        SSGR ((Ansi.SetColor _ Ansi.Dull Ansi.Red) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[31m")

        SSGR ((Ansi.SetColor _ Ansi.Vivid Ansi.Red) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[91m")

        SSGR ((Ansi.SetColor _ Ansi.Dull Ansi.Green) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[32m")

        SSGR ((Ansi.SetColor _ Ansi.Vivid Ansi.Green) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[92m")

        SSGR ((Ansi.SetColor _ Ansi.Dull Ansi.Yellow) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[33m")

        SSGR ((Ansi.SetColor _ Ansi.Vivid Ansi.Yellow) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[93m")

        SSGR ((Ansi.SetColor _ Ansi.Dull Ansi.Cyan) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[36m")

        SSGR ((Ansi.SetColor _ Ansi.Vivid Ansi.Cyan) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[96m")

        SSGR ((Ansi.SetColor _ Ansi.Dull Ansi.Black) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[30m")

        SSGR ((Ansi.SetColor _ Ansi.Dull Ansi.Blue) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[34m")

        SSGR ((Ansi.SetColor _ Ansi.Vivid Ansi.Black) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[90m")

        SSGR ((Ansi.SetColor _ Ansi.Vivid Ansi.Blue) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[94m")

        SSGR ((Ansi.SetConsoleIntensity Ansi.BoldIntensity) :: tail) sd ->
            displayS (SSGR tail sd) (acc ++ "\u{001B}[1m")

        SSGR [] sd ->
            displayS sd acc


{-| Creates a document holding the given string, with no style.
-}
text : String -> Doc
text =
    P.string


{-| Gives every string in the document the style with bold, underline and
colour all off, so that rendering it sets no colour or attribute.

Every string comes out carrying that style, including any that had none, and
`renderPretty` treats a string with a style as styled whatever the style is. A
document passed through `plain` therefore still renders with a reset before
each line break that follows text.

-}
plain : Doc -> Doc
plain =
    updateStyle (\_ -> defaultStyle)


{-| Underlines every string in the document, keeping its colour and boldness.
-}
underline : Doc -> Doc
underline =
    updateStyle (\style -> { style | underline = True })


{-| Returns the second document immediately followed by the first, with no
separator, so that `x |> a y` is `x` then `y`.
-}
a : Doc -> Doc -> Doc
a =
    P.a


{-| Returns `doc1`, a space, then `doc2`, so that `doc1 |> plus doc2` reads
left to right.

If either document is `empty`, no space is added.

-}
plus : Doc -> Doc -> Doc
plus doc2 doc1 =
    P.words [ doc1, doc2 ]


{-| Returns the first document immediately followed by the second, with no
separator.
-}
append : Doc -> Doc -> Doc
append =
    P.append


{-| Sets the indentation inside the document to the column at which the
document starts, in place of the enclosing indentation. A line break there
returns to that column unless a combinator nested within the document, such as
`hang`, changes the indentation.
-}
align : Doc -> Doc
align =
    P.align


{-| Joins the documents with no separator if they all fit on the rest of the
line, and otherwise puts each on its own line.
-}
cat : List Doc -> Doc
cat =
    vcat >> P.group


{-| The document with no content.
-}
empty : Doc
empty =
    P.empty


{-| Does the same as `indent`. It does not pad a document to a width.
-}
fill : Int -> Doc -> Doc
fill =
    P.indent


{-| Joins the documents with breaks that are each a space if what follows fits
on the line, and a line break otherwise. Each break is decided on its own, so
the result fills lines the way a paragraph does.
-}
fillSep : List Doc -> Doc
fillSep =
    P.softlines


{-| Sets the indentation inside the document to the given number of columns
to the right of the column at which the document starts. Later lines start
there unless a combinator nested within the document changes the indentation.
The first line is not moved.
-}
hang : Int -> Doc -> Doc
hang =
    P.hang


{-| Returns `empty` for an empty list and the document itself for a list of
one. For a list of two or more it returns only the last document; the others
are dropped.
-}
hcat : List Doc -> Doc
hcat docs =
    hcatHelp docs empty


{-| Returns `acc` if `docs` is empty, and otherwise the last of `docs`. The
accumulated documents are discarded when one document remains.
-}
hcatHelp : List Doc -> Doc -> Doc
hcatHelp docs acc =
    case docs of
        [] ->
            acc

        [ doc ] ->
            doc

        doc :: ds ->
            hcatHelp ds (P.append doc acc)


{-| Joins the documents with a space between each pair. The separator is
always a space, never a line break.
-}
hsep : List Doc -> Doc
hsep =
    P.words


{-| Writes the given number of spaces before the document, and sets the
indentation inside it to that many columns to the right of the column at which
the spaces begin. Later lines start there unless a combinator nested within the
document changes the indentation.
-}
indent : Int -> Doc -> Doc
indent =
    P.indent


{-| Joins the documents with spaces if they all fit on the rest of the line,
and otherwise puts each on its own line.
-}
sep : List Doc -> Doc
sep =
    P.lines >> P.group


{-| Joins the documents with a line break between each pair.

The breaks are always taken, unless the result is placed inside a group that
fits on one line, as `cat` does; there the documents are joined with no
separator.

-}
vcat : List Doc -> Doc
vcat =
    P.join P.tightline


{-| Colours every string in the document vivid red (code 91), replacing
any colour it had.
-}
red : Doc -> Doc
red =
    updateColor Red


{-| Colours every string in the document vivid cyan (code 96), replacing
any colour it had.
-}
cyan : Doc -> Doc
cyan =
    updateColor Cyan


{-| Colours every string in the document vivid green (code 92), replacing
any colour it had.
-}
green : Doc -> Doc
green =
    updateColor Green


{-| Colours every string in the document vivid blue (code 94), replacing
any colour it had.
-}
blue : Doc -> Doc
blue =
    updateColor Blue


{-| Colours every string in the document vivid black (code 90), replacing
any colour it had.
-}
black : Doc -> Doc
black =
    updateColor Black


{-| Colours every string in the document vivid yellow (code 93), replacing
any colour it had.
-}
yellow : Doc -> Doc
yellow =
    updateColor Yellow


{-| Colours every string in the document dull red (code 31), replacing
any colour it had.
-}
dullred : Doc -> Doc
dullred =
    updateColor DullRed


{-| Colours every string in the document dull cyan (code 36), replacing
any colour it had.
-}
dullcyan : Doc -> Doc
dullcyan =
    updateColor DullCyan


{-| Colours every string in the document dull yellow (code 33), replacing
any colour it had.
-}
dullyellow : Doc -> Doc
dullyellow =
    updateColor DullYellow



-- ====== STYLE ======


{-| How one string is drawn: bold or not, underlined or not, and in which
colour. A `color` of `Nothing` sets no colour.

No function in this module sets `bold`.

-}
type alias Style =
    { bold : Bool
    , underline : Bool
    , color : Maybe Color
    }


{-| A foreground colour a `Style` can carry. The six without a prefix are the
vivid shades; the three with a `Dull` prefix are the dull shades of red, cyan
and yellow. There is no dull green, blue or black.
-}
type Color
    = Red
    | Green
    | Cyan
    | Blue
    | Black
    | Yellow
    | DullCyan
    | DullRed
    | DullYellow


{-| The style with bold, underline and colour all off.
-}
defaultStyle : Style
defaultStyle =
    Style False False Nothing


{-| Sets the colour of every string in the document to `newColor`, keeping its
boldness and underline.
-}
updateColor : Color -> Doc -> Doc
updateColor newColor =
    updateStyle (\style -> { style | color = Just newColor })


{-| Applies `mapper` to the style of every string in the document. A string
with no style is given `mapper defaultStyle`, so every string comes out with a
style.
-}
updateStyle : (Style -> Style) -> Doc -> Doc
updateStyle mapper =
    P.updateTag
        (\_ ->
            Maybe.map mapper
                >> Maybe.withDefault (mapper defaultStyle)
                >> Just
        )
