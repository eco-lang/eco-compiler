module Text.PrettyPrint.ANSI.Leijen exposing
    ( Doc, SimpleDoc(..), Style, Color(..)
    , text, empty
    , append, plus, a
    , align, indent, hang, fill
    , cat, hcat, vcat, sep, hsep, fillSep
    , plain, underline
    , red, green, blue, cyan, yellow, black
    , dullred, dullcyan, dullyellow
    , renderPretty, displayS, displayIO
    )

{-| Pretty printing library with ANSI terminal color and style support.

This module provides a document-based pretty printing system that supports ANSI escape codes
for terminal output. It combines layout combinators with styling functions to create
formatted, colorized text output. The implementation wraps a generic pretty printer with
ANSI SGR (Select Graphic Rendition) command generation.


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


{-| A document that can be pretty-printed with ANSI styling.
-}
type alias Doc =
    P.Doc Style


{-| A simplified document representation after layout, ready for rendering to a string.
-}
type SimpleDoc
    = SEmpty
    | SText String SimpleDoc
    | SLine Int SimpleDoc
    | SSGR (List Ansi.SGR) SimpleDoc


{-| Writes a SimpleDoc to the specified IO handle as a task.
-}
displayIO : IO.Handle -> SimpleDoc -> Task Never ()
displayIO handle simpleDoc =
    IO.hPutStr handle (displayS simpleDoc "")


{-| Renders a Doc into a SimpleDoc with the specified page width.
-}
renderPretty : Float -> Int -> Doc -> SimpleDoc
renderPretty _ w doc =
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


{-| Converts a SimpleDoc to a string with ANSI escape codes, appending to an accumulator.
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


{-| Creates a document containing the given string.
-}
text : String -> Doc
text =
    P.string


{-| Removes all styling from a document.
-}
plain : Doc -> Doc
plain =
    updateStyle (\_ -> defaultStyle)


{-| Applies underline styling to a document.
-}
underline : Doc -> Doc
underline =
    updateStyle (\style -> { style | underline = True })


{-| Concatenates two documents with a space or line break between them.
-}
a : Doc -> Doc -> Doc
a =
    P.a


{-| Combines two documents with a space between them.
-}
plus : Doc -> Doc -> Doc
plus doc2 doc1 =
    P.words [ doc1, doc2 ]


{-| Concatenates two documents without any separator.
-}
append : Doc -> Doc -> Doc
append =
    P.append


{-| Aligns a document to the current column position.
-}
align : Doc -> Doc
align =
    P.align


{-| Concatenates documents vertically or horizontally depending on available space.
-}
cat : List Doc -> Doc
cat =
    vcat >> P.group


{-| An empty document.
-}
empty : Doc
empty =
    P.empty


{-| Indents a document by the specified number of spaces.
-}
fill : Int -> Doc -> Doc
fill =
    P.indent


{-| Concatenates documents with soft line breaks that become spaces when possible.
-}
fillSep : List Doc -> Doc
fillSep =
    P.softlines


{-| Creates a hanging indent with the specified offset.
-}
hang : Int -> Doc -> Doc
hang =
    P.hang


{-| Concatenates documents horizontally with no separator.
-}
hcat : List Doc -> Doc
hcat docs =
    hcatHelp docs empty


hcatHelp : List Doc -> Doc -> Doc
hcatHelp docs acc =
    case docs of
        [] ->
            acc

        [ doc ] ->
            doc

        doc :: ds ->
            hcatHelp ds (P.append doc acc)


{-| Concatenates documents horizontally with spaces between them.
-}
hsep : List Doc -> Doc
hsep =
    P.words


{-| Indents a document by the specified number of spaces.
-}
indent : Int -> Doc -> Doc
indent =
    P.indent


{-| Concatenates documents with line breaks or spaces depending on available space.
-}
sep : List Doc -> Doc
sep =
    P.lines >> P.group


{-| Concatenates documents vertically with line breaks between them.
-}
vcat : List Doc -> Doc
vcat =
    P.join P.tightline


{-| Applies vivid red color to a document.
-}
red : Doc -> Doc
red =
    updateColor Red


{-| Applies vivid cyan color to a document.
-}
cyan : Doc -> Doc
cyan =
    updateColor Cyan


{-| Applies vivid green color to a document.
-}
green : Doc -> Doc
green =
    updateColor Green


{-| Applies vivid blue color to a document.
-}
blue : Doc -> Doc
blue =
    updateColor Blue


{-| Applies vivid black color to a document.
-}
black : Doc -> Doc
black =
    updateColor Black


{-| Applies vivid yellow color to a document.
-}
yellow : Doc -> Doc
yellow =
    updateColor Yellow


{-| Applies dull red color to a document.
-}
dullred : Doc -> Doc
dullred =
    updateColor DullRed


{-| Applies dull cyan color to a document.
-}
dullcyan : Doc -> Doc
dullcyan =
    updateColor DullCyan


{-| Applies dull yellow color to a document.
-}
dullyellow : Doc -> Doc
dullyellow =
    updateColor DullYellow



-- ====== STYLE ======


{-| Represents the styling attributes applied to text in a document.
-}
type alias Style =
    { bold : Bool
    , underline : Bool
    , color : Maybe Color
    }


{-| Represents ANSI terminal colors in both vivid and dull variants.
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


defaultStyle : Style
defaultStyle =
    Style False False Nothing


updateColor : Color -> Doc -> Doc
updateColor newColor =
    updateStyle (\style -> { style | color = Just newColor })


updateStyle : (Style -> Style) -> Doc -> Doc
updateStyle mapper =
    P.updateTag
        (\_ ->
            Maybe.map mapper
                >> Maybe.withDefault (mapper defaultStyle)
                >> Just
        )
