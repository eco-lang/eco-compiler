module Compiler.Reporting.Render.Code exposing
    ( Source, toSource
    , toSnippet, toPair
    , Next(..), whatIsNext
    , nextLineStartsWithKeyword, nextLineStartsWithCloseCurly
    )

{-| Source code rendering for error messages.

This module handles the visual presentation of source code snippets in error
messages. It provides line numbering, syntax highlighting, underlines pointing
to problem areas, and context-aware formatting that makes errors easy to
locate and understand.


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



-- CODE


{-| Represents source code as a list of line numbers paired with their content.
Line numbers start at 1.
-}
type alias Source =
    List ( Int, String )


{-| Converts raw source code text into a Source representation, splitting on
newlines and adding line numbers starting from 1.
-}
toSource : String -> Source
toSource source =
    List.indexedMap (\i line -> ( i + 1, line )) (String.lines source ++ [ "" ])



-- CODE FORMATTING


{-| Renders a code snippet showing the specified region with optional highlighting
of a sub-region. Takes pre-hint and post-hint documentation to display before and
after the code snippet.
-}
toSnippet : Source -> A.Region -> Maybe A.Region -> ( Doc, Doc ) -> Doc
toSnippet source region highlight ( preHint, postHint ) =
    D.vcat
        [ preHint
        , D.fromChars ""
        , render source region highlight
        , postHint
        ]


{-| Renders two related code regions, either on a single line or as separate chunks.
Takes documentation for single-line and two-chunk cases respectively.
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



-- RENDER SNIPPET


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


drawLines : Bool -> Int -> A.Region -> Source -> Doc -> Doc
drawLines addZigZag width (A.Region (A.Position startLine _) (A.Position endLine _)) sourceLines finalLine =
    D.vcat <|
        List.map (drawLine addZigZag width startLine endLine) sourceLines
            ++ [ finalLine ]


drawLine : Bool -> Int -> Int -> Int -> ( Int, String ) -> Doc
drawLine addZigZag width startLine endLine ( n, line ) =
    addLineNumber addZigZag width startLine endLine n (D.fromChars line)


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



-- RENDER PAIR


type CodePair
    = OneLine Doc
    | TwoChunks Doc Doc


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



-- WHAT IS NEXT?


{-| Represents the next syntactic element at a position in the source code.
Used to provide context-aware error messages.
-}
type Next
    = Keyword String
    | Operator String
    | Close String Char
    | Upper Char String
    | Lower Char String
    | Other (Maybe Char)


{-| Analyzes the source code at the given row and column to determine what
syntactic element appears next (keyword, operator, identifier, etc.).
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


isInner : Char -> Bool
isInner char =
    Char.isAlphaNum char || char == '_'


isSymbol : Char -> Bool
isSymbol char =
    EverySet.member identity (Char.toCode char) binopCharSet


startsWithKeyword : String -> String -> Bool
startsWithKeyword restOfLine keyword =
    String.startsWith keyword restOfLine
        && (case String.dropLeft (String.length keyword) restOfLine |> String.toList of
                [] ->
                    True

                c :: _ ->
                    not (isInner c)
           )


{-| Checks if the next line starts with the specified keyword. Returns the
position of the keyword if found.
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


{-| Checks if the next line starts with a closing curly brace `}`. Returns the
position if found.
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
