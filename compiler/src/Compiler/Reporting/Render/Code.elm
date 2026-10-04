module Compiler.Reporting.Render.Code exposing
    ( Source, toSource
    , toSnippet, toPair
    , Next(..), whatIsNext
    , nextLineStartsWithKeyword, nextLineStartsWithCloseCurly
    )

{-| An error report has to show the user the source text it is about, and this
module draws that excerpt. It also answers a few questions about what text
follows a given position, which the syntax error reports use to choose their
wording.

The source is held as a `Source`, its lines numbered from 1, made from the
whole text by `toSource`. Rows and columns here are the parser's, as
`Compiler.Reporting.Annotation` describes: both count from 1, and a region's end
is the position just after its last character.

A _snippet_ is the excerpt as drawn: the lines of a region, each behind a gutter
holding its line number and a `|`, between a _pre-hint_ and a _post-hint_, the
two documents of explanation shown above and below it. The part of the region
that is at fault is marked in red, in one of two ways. A part that lies on one
line, when that line is the region's last line, is underlined with `^`
characters on an extra line below. Any other part is marked by a `>` in the
gutter of each of its lines. There is no syntax highlighting.


# Source Representation

@docs Source, toSource


# Snippet Rendering

@docs toSnippet, toPair


# Context Analysis

@docs Next, whatIsNext
@docs nextLineStartsWithKeyword, nextLineStartsWithCloseCurly

-}

import Char
import Compiler.Parse.Primitives exposing (Col, Row)
import Compiler.Parse.Symbol exposing (binopCharSet)
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D exposing (Doc)
import Data.Set as EverySet
import Prelude



-- ====== CODE ======


{-| The text of one source file, as its lines paired with their line numbers.

This is a name for a list of pairs, not a new type, and nothing checks the
numbering. The functions here expect the shape `toSource` makes, numbers from 1
upwards with no gaps, because `toSnippet`, and `toPair` when it draws two
excerpts, select a region's lines by their place in the list, while the other
functions look a line up by its number.

-}
type alias Source =
    List ( Int, String )


{-| Returns the lines of `source` numbered from 1, followed by one more, empty,
line.
-}
toSource : String -> Source
toSource source =
    List.indexedMap (\i line -> ( i + 1, line )) (String.lines source ++ [ "" ])



-- ====== CODE FORMATTING ======


{-| Builds the snippet showing the lines of `region`: `preHint`, a blank line,
the numbered lines, then `postHint`.

`highlight` is the part to mark, and is the whole of `region` when it is
`Nothing`. It is underlined with `^` when it starts and ends on the same row and
that row is not above the last row of `region`. The underline is as wide as the
highlight, and at least one `^`. Otherwise each shown line whose row the
highlight spans gets a red `>` in its gutter.

A region that starts after the last line of `source` aborts the compiler.

-}
toSnippet : Source -> A.Region -> Maybe A.Region -> ( Doc, Doc ) -> Doc
toSnippet source region highlight ( preHint, postHint ) =
    D.vcat
        [ preHint
        , D.fromChars ""
        , render source region highlight
        , postHint
        ]


{-| Builds a snippet that points at two regions, `r1` and `r2`, using one pair
of hints or the other depending on how the regions lie.

When both regions are on one and the same row, the result is `oneStart`, a
blank line, that line shown once with both regions underlined with `^` beneath
it, then `oneEnd`. The underlines are placed for `r1` lying before `r2` on the line.

Otherwise each region is shown as its own excerpt, marked as `toSnippet` marks
a region with no separate highlight, and the result is `twoStart`, a blank
line, the excerpt for `r1`, `twoMiddle`, a blank line, the excerpt for `r2`,
then `twoEnd`. As with `toSnippet`, a region that starts after the last line of
`source` then aborts the compiler.

-}
toPair : Source -> A.Region -> A.Region -> ( Doc, Doc ) -> ( Doc, Doc, Doc ) -> Doc
toPair source r1 r2 ( oneStart, oneEnd ) ( twoStart, twoMiddle, twoEnd ) =
    case renderPair source r1 r2 of
        OneLine codeDocs ->
            D.vcat
                [ oneStart
                , D.fromChars ""
                , codeDocs
                , oneEnd
                ]

        TwoChunks code1 code2 ->
            D.vcat
                [ twoStart
                , D.fromChars ""
                , code1
                , twoMiddle
                , D.fromChars ""
                , code2
                , twoEnd
                ]



-- ====== RENDER SNIPPET ======


{-| Draws the numbered lines of the region, marking `maybeSubRegion`, or the
whole region when that is `Nothing`, with an underline when `makeUnderline`
gives one and with `>` markers otherwise. Line numbers are right-aligned to
the width of the last shown line's number.

Lines are selected by their place in `sourceLines`, which is why a `Source`
must be numbered from 1 without gaps. A region that starts after the last line
leaves nothing to select, and `Prelude.last` then aborts.

-}
render : Source -> A.Region -> Maybe A.Region -> Doc
render sourceLines ((A.Region (A.Position startLine _) (A.Position endLine _)) as region) maybeSubRegion =
    let
        relevantLines : List ( Int, String )
        relevantLines =
            sourceLines
                |> List.drop (startLine - 1)
                |> List.take (1 + endLine - startLine)

        width : Int
        width =
            String.length (String.fromInt (Tuple.first (Prelude.last relevantLines)))

        smallerRegion : A.Region
        smallerRegion =
            Maybe.withDefault region maybeSubRegion
    in
    case makeUnderline width endLine smallerRegion of
        Nothing ->
            drawLines True width smallerRegion relevantLines D.empty

        Just underline ->
            drawLines False width smallerRegion relevantLines underline


{-| Returns the red `^` line that underlines a region, or `Nothing` when the
region spans more than one row or its row is above `realEndLine`, the last row
of the region being drawn.

The carets are indented past the gutter, which is `width + 2` characters wide,
so that the first stands under the region's start column.

-}
makeUnderline : Int -> Int -> A.Region -> Maybe Doc
makeUnderline width realEndLine (A.Region (A.Position start c1) (A.Position end c2)) =
    if start /= end || end < realEndLine then
        Nothing

    else
        let
            spaces : String
            spaces =
                String.repeat (c1 + width + 1) " "

            zigzag : String
            zigzag =
                String.repeat (max 1 (c2 - c1)) "^"
        in
        Just
            (D.fromChars spaces
                |> D.a (D.red (D.fromChars zigzag))
            )


{-| Draws each of `sourceLines` with its gutter, then `finalLine` below them.
When `addZigZag` is `True`, the lines whose rows the region spans get a `>`
marker.
-}
drawLines : Bool -> Int -> A.Region -> Source -> Doc -> Doc
drawLines addZigZag width (A.Region (A.Position startLine _) (A.Position endLine _)) sourceLines finalLine =
    D.vcat <|
        List.map (drawLine addZigZag width startLine endLine) sourceLines
            ++ [ finalLine ]


{-| Draws one numbered source line with its gutter.
-}
drawLine : Bool -> Int -> Int -> Int -> ( Int, String ) -> Doc
drawLine addZigZag width startLine endLine ( n, line ) =
    addLineNumber addZigZag width startLine endLine n (D.fromChars line)


{-| Puts the gutter in front of `line`: the number `n` right-aligned in `width`
characters, a `|`, then a red `>` when `addZigZag` is `True` and `n` is between
`start` and `end` inclusive, or a space otherwise.
-}
addLineNumber : Bool -> Int -> Int -> Int -> Int -> Doc -> Doc
addLineNumber addZigZag width start end n line =
    let
        number : String
        number =
            String.fromInt n

        lineNumber : String
        lineNumber =
            String.repeat (width - String.length number) " " ++ number ++ "|"

        spacer : Doc
        spacer =
            if addZigZag && start <= n && n <= end then
                D.red (D.fromChars ">")

            else
                D.fromChars " "
    in
    D.fromChars lineNumber |> D.a spacer |> D.a line



-- ====== RENDER PAIR ======


{-| Two regions as `renderPair` drew them, in one of its two forms.

`OneLine` holds a single line with both regions underlined beneath it, and
`TwoChunks` holds a separate excerpt for each region, first then second.

-}
type CodePair
    = OneLine Doc
    | TwoChunks Doc Doc


{-| Draws `region1` and `region2` as one line with two underlines when each
lies on a single row and the rows are the same, or else as two excerpts drawn
by `render` with no separate highlight.

The one-line form places the second underline `startCol2 - endCol1` spaces
after the first, so it is right only when `region1` ends before `region2`
starts. Its line is found by number, and is drawn empty when `source` has no
line with that number.

-}
renderPair : Source -> A.Region -> A.Region -> CodePair
renderPair source region1 region2 =
    let
        (A.Region (A.Position startRow1 startCol1) (A.Position endRow1 endCol1)) =
            region1

        (A.Region (A.Position startRow2 startCol2) (A.Position endRow2 endCol2)) =
            region2
    in
    if startRow1 == endRow1 && endRow1 == startRow2 && startRow2 == endRow2 then
        let
            lineNumber : String
            lineNumber =
                String.fromInt startRow1

            spaces1 : String
            spaces1 =
                String.repeat (startCol1 + String.length lineNumber + 1) " "

            zigzag1 : String
            zigzag1 =
                String.repeat (endCol1 - startCol1) "^"

            spaces2 : String
            spaces2 =
                String.repeat (startCol2 - endCol1) " "

            zigzag2 : String
            zigzag2 =
                String.repeat (endCol2 - startCol2) "^"

            line : String
            line =
                List.head (List.filter (\( row, _ ) -> row == startRow1) source) |> Maybe.map Tuple.second |> Maybe.withDefault ""
        in
        OneLine
            (D.vcat
                [ D.fromChars (lineNumber ++ "| " ++ line)
                , D.fromChars spaces1
                    |> D.a (D.red (D.fromChars zigzag1))
                    |> D.a (D.fromChars spaces2)
                    |> D.a (D.red (D.fromChars zigzag2))
                ]
            )

    else
        TwoChunks
            (render source region1 Nothing)
            (render source region2 Nothing)



-- ====== WHAT IS NEXT ======


{-| What kind of text starts at a position in the source, as `whatIsNext`
classifies it.

`Keyword` carries a reserved word, as `Compiler.Parse.Variable.isReservedWord`
decides.

`Operator` carries operator characters, starting with the one at the position.

`Close` carries the name of a closing bracket, such as `"square bracket"`, and
the bracket itself.

`Upper` carries the first character of a capitalised name and the name's
characters after it. `Lower` carries the first character of a lower-case name
and the whole name, that first character included.

`Other` carries the character at the position when it is none of the above,
and is `Other Nothing` when there is no character there.

The text in `Keyword`, `Operator`, `Upper` and `Lower` is not always one
token, because `whatIsNext` gathers it from the rest of the line.

-}
type Next
    = Keyword String
    | Operator String
    | Close String Char
    | Upper Char String
    | Lower Char String
    | Other (Maybe Char)


{-| Returns what kind of text starts at `row` and `col` in `sourceLines`,
judged by its first character: an upper-case or lower-case ASCII letter, an
operator character, or a closing bracket, else `Other`.

After the first character, the text carried is every identifier character
(ASCII letter, digit or `_`) for a name, or every operator character for an
operator, in the rest of the line, with the others skipped rather than ending
it. On a line reading `foo bar`, the result at the `f` is `Lower 'f' "foobar"`,
and a lower-case word is a `Keyword` only when what is gathered this way is a
reserved word.

The line is found by its number. When there is no line `row`, or `col` is past
its end, the result is `Other Nothing`.

-}
whatIsNext : Source -> Row -> Col -> Next
whatIsNext sourceLines row col =
    case List.head (List.filter (\( r, _ ) -> r == row) sourceLines) of
        Nothing ->
            Other Nothing

        Just ( _, line ) ->
            case String.dropLeft (col - 1) line |> String.toList of
                [] ->
                    Other Nothing

                c :: cs ->
                    if Char.isUpper c then
                        Upper c (List.filter isInner cs |> String.fromList)

                    else if Char.isLower c then
                        detectKeywords c (String.fromList cs)

                    else if isSymbol c then
                        Operator (c :: List.filter isSymbol cs |> String.fromList)

                    else if c == ')' then
                        Close "parenthesis" ')'

                    else if c == ']' then
                        Close "square bracket" ']'

                    else if c == '}' then
                        Close "curly brace" '}'

                    else
                        Other (Just c)


{-| Returns `Keyword` when `c` followed by the identifier characters kept from
`rest` is a reserved word of `Compiler.Parse.Variable`, and `Lower` otherwise.

The identifier characters of `rest` are all of them, not only the run at its
start: other characters are skipped, not stopped at.

-}
detectKeywords : Char -> String -> Next
detectKeywords c rest =
    let
        cs : String
        cs =
            List.filter isInner (String.toList rest) |> String.fromList

        name : String
        name =
            String.fromChar c ++ cs
    in
    if Var.isReservedWord name then
        Keyword name

    else
        Lower c name


{-| Returns whether `char` may appear after the first letter of a name: an
ASCII letter or digit, or `_`.
-}
isInner : Char -> Bool
isInner char =
    Char.isAlphaNum char || char == '_'


{-| Returns whether `char` is one of the characters operators are made of, as
`Compiler.Parse.Symbol.binopCharSet` lists them.
-}
isSymbol : Char -> Bool
isSymbol char =
    EverySet.member identity (Char.toCode char) binopCharSet


{-| Returns whether `restOfLine` begins with `keyword` as a whole word, that is,
not followed directly by an identifier character.
-}
startsWithKeyword : String -> String -> Bool
startsWithKeyword restOfLine keyword =
    String.startsWith keyword restOfLine
        && (case String.dropLeft (String.length keyword) restOfLine |> String.toList of
                [] ->
                    True

                c :: _ ->
                    not (isInner c)
           )


{-| Returns a position on line `row + 1` when that line, after its leading
whitespace, begins with `keyword` as a whole word, and `Nothing` otherwise or
when there is no such line.

The position's row is `row + 1`. Its column is one more than the length of the
line without its leading whitespace, which is in general not the column the
keyword starts at.

-}
nextLineStartsWithKeyword : String -> Source -> Row -> Maybe ( Row, Col )
nextLineStartsWithKeyword keyword sourceLines row =
    List.head (List.filter (\( r, _ ) -> r == row + 1) sourceLines)
        |> Maybe.andThen
            (\( _, line ) ->
                if startsWithKeyword (String.trimLeft line) keyword then
                    Just ( row + 1, 1 + String.length (String.trimLeft line) )

                else
                    Nothing
            )


{-| Returns a position on line `row + 1` when that line, after its leading
whitespace, begins with `}`, and `Nothing` otherwise or when there is no such
line.

The position's row is `row + 1`. Its column is one more than the length of the
line without its leading whitespace, which is in general not the column of
the `}`.

-}
nextLineStartsWithCloseCurly : Source -> Row -> Maybe ( Row, Col )
nextLineStartsWithCloseCurly sourceLines row =
    List.head (List.filter (\( r, _ ) -> r == row + 1) sourceLines)
        |> Maybe.andThen
            (\( _, line ) ->
                case String.trimLeft line |> String.toList of
                    '}' :: _ ->
                        Just ( row + 1, 1 + String.length (String.trimLeft line) )

                    _ ->
                        Nothing
            )
