module Common.Format.Box exposing
    ( Line, identifier, keyword, punc, literal, row, space
    , Box(..), blankLine, line, mustBreak, stack_, stack1, andThen
    , allSingles, lineLength
    , indent, prefix, addSuffix
    , render
    )

{-| The layout algebra the formatter builds its output from: text pieces joined
into lines, and lines stacked into boxes.

Two facts shape the module. The first is that a piece of a line does not always
have a fixed width. A `Tab` advances to the next multiple of 4 columns, so how
wide it is depends on the column where it starts, and measuring or rendering a
line therefore always takes a starting column. Every line of a box is rendered
from column 0.

The second is that a block of output either can sit inside a surrounding line or
cannot. A `Box` records which: a single line can be joined into another line,
while a stack of lines, or a line that must end where it ends (a `--` comment),
has to stand on its own lines. The formatter decides between a one-line and a
multi-line layout by asking whether the parts are single lines (`allSingles`);
nothing here measures a line against a width limit.

The functions build lines (`identifier`, `keyword`, `punc` and `literal` all
make plain text; `row`, `space`), build and stack boxes, transform the lines of a
box (`indent`, `prefix`, `addSuffix`) and turn a box into text (`render`).


# Line Construction

@docs Line, identifier, keyword, punc, literal, row, space


# Box Construction

@docs Box, blankLine, line, mustBreak, stack_, stack1, andThen


# Box Properties

@docs allSingles, lineLength


# Box Transformations

@docs indent, prefix, addSuffix


# Rendering

@docs render

-}

import Basics.Extra exposing (flip)
import Prelude
import Result.Extra as Result
import Utils.Crash exposing (crash)
import Utils.Main as Utils


{-| A piece of one line of output. It is meant to hold no line break, but
nothing checks that a `Text` string has none.

`Text` is a string placed as it is. `Row` places its parts one after another.
`Space` is one column wide. `Tab` advances to the next multiple of 4 columns, a
full 4 when it starts on a multiple of 4, so its width depends on where it
starts.

-}
type Line
    = Text String
    | Row (List Line)
    | Space
    | Tab


{-| Makes a line of plain text; identical to `keyword`, `punc` and `literal`, and differs
only in what the caller is placing.
-}
identifier : String -> Line
identifier =
    Text


{-| Makes a line of plain text; identical to `identifier`, `punc` and `literal`, and differs
only in what the caller is placing.
-}
keyword : String -> Line
keyword =
    Text


{-| Makes a line of plain text; identical to `identifier`, `keyword` and `literal`, and differs
only in what the caller is placing.
-}
punc : String -> Line
punc =
    Text


{-| Makes a line of plain text; identical to `identifier`, `keyword` and `punc`, and differs
only in what the caller is placing.
-}
literal : String -> Line
literal =
    Text


{-| Joins lines into one, placed left to right.
-}
row : List Line -> Line
row =
    Row


{-| A one-column space.
-}
space : Line
space =
    Space


{-| A block of one or more lines of output, together with whether it can be
joined into a surrounding line.

`SingleLine` is one line that may appear in the middle of another line.

`Stack` holds two or more lines, the first separately from the rest because
some operations, such as `prefix`, treat the first line differently. A stack
always stands on its own lines.

`MustBreak` is one line that nothing may follow on the same line; it is used for
`--` comments. Stacking it with another box gives an ordinary `Stack`.

-}
type Box
    = SingleLine Line
    | Stack Line Line (List Line)
    | MustBreak Line


{-| A single-line box with no content.
-}
blankLine : Box
blankLine =
    line (literal "")


{-| Makes a single-line box from a line.
-}
line : Line -> Box
line l =
    SingleLine l


{-| Makes a box of one line that nothing may follow on the same line, as a `--`
comment needs.
-}
mustBreak : Line -> Box
mustBreak l =
    MustBreak l


{-| Returns a `Stack` of the lines of `b1` followed by the lines of `b2`.
-}
stack_ : Box -> Box -> Box
stack_ b1 b2 =
    let
        ( line1first, line1rest ) =
            destructure b1

        ( line2first, line2rest ) =
            destructure b2
    in
    case line1rest ++ line2first :: line2rest of
        [] ->
            crash "the list will contain at least line2first"

        first :: rest ->
            Stack line1first first rest


{-| Returns `first` with the boxes of `rest` stacked below it, in list order.
When `rest` is empty the result is `first` unchanged.
-}
andThen : List Box -> Box -> Box
andThen rest first =
    List.foldl (flip stack_) first rest


{-| Stacks the boxes of a list in order, one below the next. A list of one box
returns that box unchanged, and an empty list crashes the program.
-}
stack1 : List Box -> Box
stack1 children =
    case children of
        [] ->
            crash "stack1: empty structure"

        [ first ] ->
            first

        boxes ->
            Utils.foldr1 stack_ boxes


{-| Applies `fn` to every line of a box.
-}
mapLines : (Line -> Line) -> Box -> Box
mapLines fn =
    mapFirstLine fn fn


{-| Applies `firstFn` to the first line of a box and `restFn` to every other
line.
-}
mapFirstLine : (Line -> Line) -> (Line -> Line) -> Box -> Box
mapFirstLine firstFn restFn b =
    case b of
        SingleLine l1 ->
            SingleLine (firstFn l1)

        Stack l1 l2 ls ->
            Stack (firstFn l1) (restFn l2) (List.map restFn ls)

        MustBreak l1 ->
            MustBreak (firstFn l1)


{-| Puts a `Tab` before every line of a box, which moves each line 4 columns to
the right when rendered.
-}
indent : Box -> Box
indent =
    mapLines (\l -> row [ Tab, l ])


{-| Returns the line of a `SingleLine` box, or the box itself as an error for any
other box, `MustBreak` included.
-}
isLine : Box -> Result Box Line
isLine b =
    case b of
        SingleLine l ->
            Ok l

        _ ->
            Err b


{-| Splits a box into its first line and the lines after it.
-}
destructure : Box -> ( Line, List Line )
destructure b =
    case b of
        SingleLine l1 ->
            ( l1, [] )

        Stack l1 l2 rest ->
            ( l1, l2 :: rest )

        MustBreak l1 ->
            ( l1, [] )


{-| Returns the lines of the boxes when every one is a `SingleLine`, or the whole
list unchanged as an error otherwise. An empty list gives `Ok []`.
-}
allSingles : List Box -> Result (List Box) (List Line)
allSingles boxes =
    case Result.combine (List.map isLine boxes) of
        Ok lines_ ->
            Ok lines_

        _ ->
            Err boxes


{-| Puts `pref` before the first line of a box and the same number of spaces
before each other line, so that the other lines stay aligned with the first.

The width of `pref` is measured as if it started at column 0.

-}
prefix : Line -> Box -> Box
prefix pref =
    let
        prefixLength : Int
        prefixLength =
            lineLength 0 pref

        paddingSpaces : List Line
        paddingSpaces =
            List.repeat prefixLength space

        padLineWithSpaces : Line -> Line
        padLineWithSpaces l =
            row [ row paddingSpaces, l ]

        addPrefixToLine : Line -> Line
        addPrefixToLine l =
            row [ pref, l ]
    in
    mapFirstLine addPrefixToLine padLineWithSpaces


{-| Puts `suffix` after the last line of a box.

A box of one line, `MustBreak` included, comes back as a `SingleLine`.

-}
addSuffix : Line -> Box -> Box
addSuffix suffix b =
    case destructure b of
        ( l, [] ) ->
            line (row [ l, suffix ])

        ( l1, ls ) ->
            line l1
                |> andThen (List.map line (Prelude.init ls))
                |> andThen [ line (row [ Prelude.last ls, suffix ]) ]


{-| Renders a line as it appears when it starts at column `startColumn`.
-}
renderLine : Int -> Line -> String
renderLine startColumn line_ =
    case line_ of
        Text text ->
            text

        Space ->
            " "

        Tab ->
            String.fromList (List.repeat (tabLength startColumn) ' ')

        Row lines_ ->
            renderRow startColumn lines_


{-| Renders a box as text, with trailing spaces removed from every line.

A `SingleLine` or `MustBreak` box ends with a newline; a `Stack` separates its
lines with newlines but does not end with one.

-}
render : Box -> String
render box =
    case box of
        SingleLine line_ ->
            String.trimRight (renderLine 0 line_) ++ "\n"

        Stack l1 l2 rest ->
            String.join "\n" (List.map (String.trimRight << renderLine 0) (l1 :: l2 :: rest))

        MustBreak line_ ->
            String.trimRight (renderLine 0 line_) ++ "\n"


{-| Returns the column at which a line ends when it starts at `startColumn`. This
is the line's width only when `startColumn` is 0.
-}
lineLength : Int -> Line -> Int
lineLength startColumn line_ =
    startColumn
        + (case line_ of
            Text string ->
                String.length string

            Space ->
                1

            Tab ->
                tabLength startColumn

            Row lines_ ->
                rowLength startColumn lines_
          )


{-| The state `renderRow_` starts from: nothing rendered yet, at `startColumn`.
-}
initRow : Int -> ( String, Int )
initRow startColumn =
    ( "", startColumn )


{-| The number of columns between tab stops.
-}
spacesInTab : Int
spacesInTab =
    4


{-| Returns how many columns `startColumn` lies past the previous tab stop, not
how many remain to the next one.
-}
spacesToNextTab : Int -> Int
spacesToNextTab startColumn =
    modBy spacesInTab startColumn


{-| Returns the width of a `Tab` starting at `startColumn`: the columns up to the
next tab stop, or a full 4 when `startColumn` is already on one.
-}
tabLength : Int -> Int
tabLength startColumn =
    spacesInTab - spacesToNextTab startColumn


{-| Returns the text of a row's parts placed one after another from
`startColumn`, together with its width.

The parts are rendered in order while the current column is carried along,
because each `Tab` needs the column it starts at. For the parts
`[Space, Tab, Text "abc", Tab, Text "x"]` from column 0:

    text        | column | parts left
    ""          | 0      | [Space, Tab, Text "abc", Tab, Text "x"]
    " "         | 1      | [Tab, Text "abc", Tab, Text "x"]
    "    "      | 4      | [Text "abc", Tab, Text "x"]
    "    abc"   | 7      | [Tab, Text "x"]
    "    abc "  | 8      | [Text "x"]
    "    abc x" | 9      | []

The width is the end column less `startColumn`.

-}
renderRow_ : Int -> List Line -> ( String, Int )
renderRow_ startColumn lines_ =
    let
        ( result, endColumn ) =
            List.foldl addLine (initRow startColumn) lines_

        resultLength : Int
        resultLength =
            endColumn - startColumn
    in
    ( result, resultLength )


{-| Appends one part to the text rendered so far and returns the column it ends
at.

    addLine Tab ( " ", 1 ) == ( "    ", 4 )

-}
addLine : Line -> ( String, Int ) -> ( String, Int )
addLine line_ ( string, startColumn_ ) =
    let
        newString : String
        newString =
            string ++ renderLine startColumn_ line_

        newStartColumn : Int
        newStartColumn =
            lineLength startColumn_ line_
    in
    ( newString, newStartColumn )


{-| Renders the parts of a row placed one after another from `startColumn`.
-}
renderRow : Int -> List Line -> String
renderRow startColumn lines_ =
    Tuple.first (renderRow_ startColumn lines_)


{-| Returns the width of a row's parts placed one after another from
`startColumn`.
-}
rowLength : Int -> List Line -> Int
rowLength startColumn lines_ =
    Tuple.second (renderRow_ startColumn lines_)
