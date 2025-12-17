module Compiler.Reporting.Doc exposing
    ( Doc
    , plus, append, a
    , align, cat, empty, fill, fillSep, hang
    , hcat, hsep, indent, sep, vcat
    , Color(..)
    , red, cyan, green, blue, black, yellow
    , dullred, dullcyan, dullyellow
    , fromChars, fromName, fromVersion, fromPackage, fromInt
    , toAnsi, toString, toLine
    , encode
    , stack, reflow, commaSep
    , toSimpleNote, toFancyNote, toSimpleHint, toFancyHint
    , link, fancyLink, reflowLink, makeLink, makeNakedLink
    , args, moreArgs, ordinal, intToOrdinal, cycle
    )

{-| Pretty-printing and formatting for compiler error messages.

This module provides a rich interface for building beautifully formatted,
colorized error messages. It wraps the ANSI pretty-printing library and adds
Elm-specific conveniences for creating helpful diagnostics.


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

@docs args, moreArgs, ordinal, intToOrdinal, cycle

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


{-| Convert a string to a Doc.
-}
fromChars : String -> Doc
fromChars =
    P.text


{-| Convert a Name to a Doc.
-}
fromName : Name -> Doc
fromName =
    P.text


{-| Convert a version to a Doc.
-}
fromVersion : V.Version -> Doc
fromVersion vsn =
    P.text (V.toChars vsn)


{-| Convert a package name to a Doc.
-}
fromPackage : Pkg.Name -> Doc
fromPackage pkg =
    P.text (Pkg.toChars pkg)


{-| Convert an integer to a Doc.
-}
fromInt : Int -> Doc
fromInt n =
    P.text (String.fromInt n)



-- ====== Rendering ======


{-| Render a Doc to ANSI output with color support for the given handle.
-}
toAnsi : Handle -> Doc -> Task Never ()
toAnsi handle doc =
    P.displayIO handle (P.renderPretty 1 80 doc)


{-| Render a Doc to a plain string without any ANSI color codes.
-}
toString : Doc -> String
toString doc =
    P.displayS (P.renderPretty 1 80 (P.plain doc)) ""


{-| Render a Doc to a single line string without any line breaks.
-}
toLine : Doc -> String
toLine doc =
    let
        maxBound : number
        maxBound =
            2147483647
    in
    P.displayS (P.renderPretty 1 (maxBound // 2) (P.plain doc)) ""



-- ====== High-Level Formatting ======


{-| Stack documents vertically with blank lines between them.
-}
stack : List Doc -> Doc
stack docs =
    P.vcat (List.intersperse (P.text "") docs)


{-| Reflow a paragraph of text, breaking it into words and filling lines optimally.
-}
reflow : String -> Doc
reflow paragraph =
    P.fillSep (List.map P.text (String.words paragraph))


{-| Format a list with commas and a conjunction (e.g., "a, b, and c").
The first argument is the conjunction, the second is a styling function,
and the third is the list of documents to format.
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


{-| Create a note from a simple string message.
-}
toSimpleNote : String -> Doc
toSimpleNote message =
    toFancyNote (List.map P.text (String.words message))


{-| Create a note from a list of formatted document chunks.
-}
toFancyNote : List Doc -> Doc
toFancyNote chunks =
    P.fillSep (P.append (P.underline (P.text "Note")) (P.text ":") :: chunks)



-- ====== Hints ======


{-| Create a hint from a simple string message.
-}
toSimpleHint : String -> Doc
toSimpleHint message =
    toFancyHint (List.map P.text (String.words message))


{-| Create a hint from a list of formatted document chunks.
-}
toFancyHint : List Doc -> Doc
toFancyHint chunks =
    P.fillSep (P.append (P.underline (P.text "Hint")) (P.text ":") :: chunks)



-- ====== Links and References ======


{-| Create a link with an underlined word, text before, a URL to a file, and text after.
-}
link : String -> String -> String -> String -> Doc
link word before fileName after =
    P.fillSep <|
        P.append (P.underline (P.text word)) (P.text ":")
            :: List.map P.text (String.words before)
            ++ P.text (makeLink fileName)
            :: List.map P.text (String.words after)


{-| Create a link with an underlined word, formatted docs before, a URL to a file,
and formatted docs after.
-}
fancyLink : String -> List Doc -> String -> List Doc -> Doc
fancyLink word before fileName after =
    P.fillSep <|
        P.append (P.underline (P.text word)) (P.text ":")
            :: before
            ++ P.text (makeLink fileName)
            :: after


{-| Create a full link URL in angle brackets pointing to elm-lang.org documentation.
-}
makeLink : String -> String
makeLink fileName =
    "<" ++ makeNakedLink fileName ++ ">"


{-| Create a bare link URL (without angle brackets) pointing to elm-lang.org documentation.
-}
makeNakedLink : String -> String
makeNakedLink fileName =
    "https://elm-lang.org/" ++ V.toChars V.elmCompiler ++ "/" ++ fileName


{-| Create a reflowed text block with an embedded link.
-}
reflowLink : String -> String -> String -> Doc
reflowLink before fileName after =
    P.fillSep <|
        List.map P.text (String.words before)
            ++ P.text (makeLink fileName)
            :: List.map P.text (String.words after)



-- ====== Helpers ======


{-| Format a count of arguments with proper singular/plural handling (e.g., "1 argument" or "2 arguments").
-}
args : Int -> String
args n =
    String.fromInt n
        ++ (if n == 1 then
                " argument"

            else
                " arguments"
           )


{-| Format a count of additional arguments with "more" (e.g., "1 more argument" or "2 more arguments").
-}
moreArgs : Int -> String
moreArgs n =
    String.fromInt n
        ++ " more"
        ++ (if n == 1 then
                " argument"

            else
                " arguments"
           )


{-| Convert a zero-based index to an ordinal string (e.g., "1st", "2nd", "3rd", "4th").
-}
ordinal : Index.ZeroBased -> String
ordinal index =
    intToOrdinal (Index.toHuman index)


{-| Convert an integer to an ordinal string (e.g., "1st", "2nd", "3rd", "4th").
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


{-| Create a visual cycle diagram showing circular dependencies between names.
The diagram is indented by the specified amount and shows arrows connecting the names in a cycle.
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


cycleTop : Doc
cycleTop =
    if isWindows then
        P.text "+-----+"

    else
        P.text "┌─────┐"


cycleLn : Doc
cycleLn =
    if isWindows then
        P.text "|    "

    else
        P.text "│    "


cycleMid : Doc
cycleMid =
    if isWindows then
        P.text "|     |"

    else
        P.text "│     ↓"


cycleEnd : Doc
cycleEnd =
    if isWindows then
        P.text "+-<---+"

    else
        P.text "└─────┘"


isWindows : Bool
isWindows =
    -- Info.os == "mingw32"
    False



-- ====== JSON Encoding ======


{-| Encode a Doc to JSON, preserving styling information (bold, underline, colors).
-}
encode : Doc -> E.Value
encode doc =
    E.array (toJsonHelp noStyle [] (P.renderPretty 1 80 doc))


type Style
    = Style Bool Bool (Maybe Color)


noStyle : Style
noStyle =
    Style False False Nothing


{-| Terminal color values, with lowercase for dull colors and uppercase for vivid colors.
-}
type Color
    = Red
    | RED
    | Magenta
    | MAGENTA
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
    | White
    | WHITE


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

                    Ansi.SetItalicized _ ->
                        style

                    Ansi.SetUnderlining u ->
                        Style bold (isUnderline u) color

                    Ansi.SetBlinkSpeed _ ->
                        style

                    Ansi.SetVisible _ ->
                        style

                    Ansi.SetSwapForegroundBackground _ ->
                        style

                    Ansi.SetColor l i c ->
                        Style bold underline (toColor l i c)


isBold : Ansi.ConsoleIntensity -> Bool
isBold intensity =
    case intensity of
        Ansi.BoldIntensity ->
            True

        Ansi.FaintIntensity ->
            False

        Ansi.NormalIntensity ->
            False


isUnderline : Ansi.Underlining -> Bool
isUnderline underlining =
    case underlining of
        Ansi.SingleUnderline ->
            True

        Ansi.DoubleUnderline ->
            False

        Ansi.NoUnderline ->
            False


toColor : Ansi.ConsoleLayer -> Ansi.ColorIntensity -> Ansi.Color -> Maybe Color
toColor layer intensity color =
    case layer of
        Ansi.Background ->
            Nothing

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

                    Ansi.Magenta ->
                        pick Magenta MAGENTA

                    Ansi.Yellow ->
                        pick Yellow YELLOW

                    Ansi.Green ->
                        pick Green GREEN

                    Ansi.Cyan ->
                        pick Cyan CYAN

                    Ansi.Blue ->
                        pick Blue BLUE

                    Ansi.White ->
                        pick White WHITE

                    Ansi.Black ->
                        pick Black BLACK


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


encodeColor : Color -> E.Value
encodeColor color =
    E.string <|
        case color of
            Red ->
                "red"

            RED ->
                "RED"

            Magenta ->
                "magenta"

            MAGENTA ->
                "MAGENTA"

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

            White ->
                "white"

            WHITE ->
                "WHITE"



-- ====== Document Type and Combinators ======


{-| The core document type for pretty-printing.
-}
type alias Doc =
    P.Doc


{-| Append two documents with a space in between.
-}
a : Doc -> Doc -> Doc
a =
    P.a


{-| Append two documents with a space in between (synonym for `a`).
-}
plus : Doc -> Doc -> Doc
plus =
    P.plus


{-| Concatenate two documents without any space between them.
-}
append : Doc -> Doc -> Doc
append =
    P.append


{-| Align a document by adding appropriate indentation to all subsequent lines.
-}
align : Doc -> Doc
align =
    P.align


{-| Concatenate documents horizontally without spaces, adding line breaks only when necessary.
-}
cat : List Doc -> Doc
cat =
    P.cat


{-| An empty document.
-}
empty : Doc
empty =
    P.empty


{-| Fill a document to the specified width by adding spaces on the right.
-}
fill : Int -> Doc -> Doc
fill =
    P.fill


{-| Concatenate documents with spaces, adding line breaks when they don't fit on one line.
-}
fillSep : List Doc -> Doc
fillSep =
    P.fillSep


{-| Hang a document by indenting all lines except the first by the specified amount.
-}
hang : Int -> Doc -> Doc
hang =
    P.hang


{-| Concatenate documents horizontally without any separation.
-}
hcat : List Doc -> Doc
hcat =
    P.hcat


{-| Concatenate documents horizontally with spaces between them.
-}
hsep : List Doc -> Doc
hsep =
    P.hsep


{-| Indent a document by the specified number of spaces.
-}
indent : Int -> Doc -> Doc
indent =
    P.indent


{-| Concatenate documents with spaces, or with line breaks if they don't fit.
-}
sep : List Doc -> Doc
sep =
    P.sep


{-| Concatenate documents vertically.
-}
vcat : List Doc -> Doc
vcat =
    P.vcat


{-| Apply vivid red color to a document.
-}
red : Doc -> Doc
red =
    P.red


{-| Apply vivid cyan color to a document.
-}
cyan : Doc -> Doc
cyan =
    P.cyan


{-| Apply vivid green color to a document.
-}
green : Doc -> Doc
green =
    P.green


{-| Apply vivid blue color to a document.
-}
blue : Doc -> Doc
blue =
    P.blue


{-| Apply black color to a document.
-}
black : Doc -> Doc
black =
    P.black


{-| Apply vivid yellow color to a document.
-}
yellow : Doc -> Doc
yellow =
    P.yellow


{-| Apply dull red color to a document.
-}
dullred : Doc -> Doc
dullred =
    P.dullred


{-| Apply dull cyan color to a document.
-}
dullcyan : Doc -> Doc
dullcyan =
    P.dullcyan


{-| Apply dull yellow color to a document.
-}
dullyellow : Doc -> Doc
dullyellow =
    P.dullyellow
