module Compiler.Parse.Space exposing
    ( Parser
    , chomp, chompAndCheckIndent
    , checkIndent, checkAligned, checkFreshLine
    , docComment
    )

{-| Elm's layout rule decides where a construct ends by the column its next
token starts in, so the parser has to know the column after every gap between
tokens. This module reads those gaps and checks the columns.

A gap is any run of spaces, newlines, `--` line comments and `{- -}` block
comments. Block comments nest. A carriage return between comments is skipped
without moving the column, and a tab outside a line comment is an error,
`E.HasTab`. The comments in a gap are kept, in source order, so that the
formatter can put them back: `chomp` returns them as `Src.FComments`. A doc
comment, a block comment whose opening is followed by `|`, ends a gap rather
than being part of it, and is read by `docComment`.

The checks look at the current column, mostly against the parser state's
`indent`, the column a layout-sensitive construct is measured against. A token
is _indented_ when its column is greater than `indent` and greater than 1,
_aligned_ when its column equals `indent`, and on a _fresh line_ when its column
is 1. This module counts one column per character, whatever its width in the
source string.

Most of the file is one scanner, `eat`, which reads whitespace and both kinds
of comment in a single tail-recursive loop so that a long gap does not exhaust
the JavaScript stack.


# Space Parser Type

@docs Parser


# Consuming Whitespace

@docs chomp, chompAndCheckIndent


# Indentation Checks

@docs checkIndent, checkAligned, checkFreshLine


# Documentation Comments

@docs docComment

-}

import Compiler.AST.Snippet as Snippet
import Compiler.AST.Source as Src
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- ====== SPACE PARSING ======


{-| A parser whose result is paired with a position, by convention the
position where the parsed thing ends, before any whitespace after it.

That position is what a caller passes to `checkIndent` before the next token.
This is a name for `P.Parser x ( a, A.Position )`, and nothing checks which
position a parser puts there.

-}
type alias Parser x a =
    P.Parser x ( a, A.Position )



-- ====== CHOMP ======


{-| Reads the gap at the current position and returns its comments in source
order.

It succeeds as consumed input even when the gap is empty, and stops without
consuming at a doc comment. A tab fails with `toError E.HasTab` at the tab.

-}
chomp : (E.Space -> Row -> Col -> x) -> P.Parser x Src.FComments
chomp toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( ( status, comments, newPos ), ( newRow, newCol ) ) =
                    eat EatSpaces [] st.src st.pos st.end st.row st.col
            in
            case status of
                Good ->
                    let
                        newState : P.State
                        newState =
                            P.State { st | pos = newPos, row = newRow, col = newCol }
                    in
                    P.Cok (List.reverse comments) newState

                HasTab ->
                    P.Cerr newRow newCol (toError E.HasTab)

                EndlessMultiComment ->
                    P.Cerr newRow newCol (toError E.EndlessMultiComment)



-- ====== CHECKS ======


{-| Succeeds, consuming nothing, when the current column is indented: greater
than `indent` and greater than 1.

Otherwise it fails without consuming, at the position given as the first
argument rather than at the current one. Callers pass the end of the previous
token there.

-}
checkIndent : A.Position -> (Int -> Int -> x) -> P.Parser x ()
checkIndent (A.Position endRow endCol) toError =
    P.Parser <|
        \((P.State st) as state) ->
            if st.col > st.indent && st.col > 1 then
                P.Eok () state

            else
                P.Eerr endRow endCol toError


{-| Succeeds, consuming nothing, when the current column equals `indent`.

Otherwise it fails without consuming, at the current position, and the first
argument `toError` receives is `indent`, the expected column.

-}
checkAligned : (Int -> Int -> Int -> x) -> P.Parser x ()
checkAligned toError =
    P.Parser <|
        \((P.State st) as state) ->
            if st.col == st.indent then
                P.Eok () state

            else
                P.Eerr st.row st.col (toError st.indent)


{-| Succeeds, consuming nothing, when the current column is 1, and otherwise
fails without consuming at the current position.
-}
checkFreshLine : (Row -> Col -> x) -> P.Parser x ()
checkFreshLine toError =
    P.Parser <|
        \((P.State st) as state) ->
            if st.col == 1 then
                P.Eok () state

            else
                P.Eerr st.row st.col toError



-- ====== CHOMP AND CHECK ======


{-| Reads the gap as `chomp` does, then requires the column after it to be
indented: greater than `indent` and greater than 1.

Gap errors are reported as `chomp` reports them, through `toSpaceError`. An
indentation failure is reported through `toIndentError` at the position before
the gap, not at the end of a previous token as `checkIndent` reports it, and it
counts as consumed input even when the gap was empty.

-}
chompAndCheckIndent : (E.Space -> Row -> Col -> x) -> (Row -> Col -> x) -> P.Parser x Src.FComments
chompAndCheckIndent toSpaceError toIndentError =
    P.Parser <|
        \(P.State st) ->
            let
                ( ( status, comments, newPos ), ( newRow, newCol ) ) =
                    eat EatSpaces [] st.src st.pos st.end st.row st.col
            in
            case status of
                Good ->
                    if newCol > st.indent && newCol > 1 then
                        let
                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, row = newRow, col = newCol }
                        in
                        P.Cok (List.reverse comments) newState

                    else
                        P.Cerr st.row st.col toIndentError

                HasTab ->
                    P.Cerr newRow newCol (toSpaceError E.HasTab)

                EndlessMultiComment ->
                    P.Cerr newRow newCol (toSpaceError E.EndlessMultiComment)


{-| What `eat` is in the middle of reading.

`EatSpaces` is between comments. `EatLineComment` is inside a `--` comment and
carries the index just after the `--`, where the comment's text starts.
`EatMultiComment` is at a `{` that may open a block comment.

-}
type EatType
    = EatSpaces
    | EatLineComment Int
    | EatMultiComment


{-| How a scan of a gap ended: at the end of the gap, at a tab, or at a block
comment with no end.
-}
type Status
    = Good
    | HasTab
    | EndlessMultiComment


{-| Reads a gap from `pos`, given the comments read so far, newest first, and
returns how it ended, all the comments, newest first, and the index, row and
column where it stopped.

Reading whitespace, line comments and block comments in one self-calling loop,
switched by `EatType`, keeps every step a tail call, so a long gap does not
exhaust the stack.

A `--` comment's text runs from after the `--` to before the newline, so a
carriage return before the newline is part of it, and it may hold tabs. A block
comment's text is everything between its `{-` and `-}`, split into lines. A
block comment opening closer to `end` than two characters is left unread, as
is a doc comment.

On a tab the index, row and column are the tab's. For an unclosed block comment
they are those of the comment's `{`.

-}
eat : EatType -> Src.FComments -> String -> Int -> Int -> Row -> Col -> ( ( Status, Src.FComments, Int ), ( Row, Col ) )
eat eatType comments src pos end row col =
    case eatType of
        EatSpaces ->
            if pos >= end then
                ( ( Good, comments, pos ), ( row, col ) )

            else
                case P.unsafeIndex src pos of
                    ' ' ->
                        eat EatSpaces comments src (pos + 1) end row (col + 1)

                    '\n' ->
                        eat EatSpaces comments src (pos + 1) end (row + 1) 1

                    '{' ->
                        eat EatMultiComment comments src pos end row col

                    '-' ->
                        let
                            pos1 : Int
                            pos1 =
                                pos + 1
                        in
                        if pos1 < end && P.unsafeIndex src pos1 == '-' then
                            eat (EatLineComment (pos + 2)) comments src (pos + 2) end row (col + 2)

                        else
                            ( ( Good, comments, pos ), ( row, col ) )

                    '\u{000D}' ->
                        eat EatSpaces comments src (pos + 1) end row col

                    '\t' ->
                        ( ( HasTab, comments, pos ), ( row, col ) )

                    _ ->
                        ( ( Good, comments, pos ), ( row, col ) )

        EatLineComment startPos ->
            if pos >= end then
                let
                    newComment : Src.FComment
                    newComment =
                        Src.LineComment (String.slice startPos pos src)
                in
                ( ( Good, newComment :: comments, pos ), ( row, col ) )

            else
                let
                    word : Char
                    word =
                        P.unsafeIndex src pos
                in
                if word == '\n' then
                    let
                        newComment : Src.FComment
                        newComment =
                            Src.LineComment (String.slice startPos pos src)
                    in
                    eat EatSpaces (newComment :: comments) src (pos + 1) end (row + 1) 1

                else
                    let
                        newPos : Int
                        newPos =
                            pos + P.getCharWidth word
                    in
                    eat (EatLineComment startPos) comments src newPos end row (col + 1)

        EatMultiComment ->
            let
                pos2 : Int
                pos2 =
                    pos + 2
            in
            if pos2 >= end then
                ( ( Good, comments, pos ), ( row, col ) )

            else
                let
                    pos1 : Int
                    pos1 =
                        pos + 1
                in
                if P.unsafeIndex src pos1 == '-' then
                    if P.unsafeIndex src pos2 == '|' then
                        ( ( Good, comments, pos ), ( row, col ) )

                    else
                        let
                            ( ( status, newPos ), ( newRow, newCol ) ) =
                                eatMultiCommentHelp src pos2 end row (col + 2) 1
                        in
                        case status of
                            MultiGood ->
                                let
                                    newComment : Src.FComment
                                    newComment =
                                        Src.BlockComment (String.lines (String.slice pos2 (newPos - 2) src))
                                in
                                eat EatSpaces (newComment :: comments) src newPos end newRow newCol

                            MultiTab ->
                                ( ( HasTab, comments, newPos ), ( newRow, newCol ) )

                            MultiEndless ->
                                ( ( EndlessMultiComment, comments, pos ), ( row, col ) )

                else
                    ( ( Good, comments, pos ), ( row, col ) )


{-| How `eatMultiCommentHelp` ended: after the comment's close, at a tab, or
at `end` with the comment still open.
-}
type MultiStatus
    = MultiGood
    | MultiTab
    | MultiEndless


{-| Reads the inside of a block comment from `pos`, where `openComments` block
comments are open, and returns how it ended with the index, row and column it
stopped at.

A `{-` inside opens one more comment and a `-}` closes one, and the result is
`MultiGood` once the last is closed, with the index just after that close. On a
tab the position is the tab's. A carriage return counts a column here.

-}
eatMultiCommentHelp : String -> Int -> Int -> Row -> Col -> Int -> ( ( MultiStatus, Int ), ( Row, Col ) )
eatMultiCommentHelp src pos end row col openComments =
    if pos >= end then
        ( ( MultiEndless, pos ), ( row, col ) )

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if word == '\n' then
            eatMultiCommentHelp src (pos + 1) end (row + 1) 1 openComments

        else if word == '\t' then
            ( ( MultiTab, pos ), ( row, col ) )

        else if word == '-' && P.isWord src (pos + 1) end '}' then
            if openComments == 1 then
                ( ( MultiGood, pos + 2 ), ( row, col + 2 ) )

            else
                eatMultiCommentHelp src (pos + 2) end row (col + 2) (openComments - 1)

        else if word == '{' && P.isWord src (pos + 1) end '-' then
            eatMultiCommentHelp src (pos + 2) end row (col + 2) (openComments + 1)

        else
            let
                newPos : Int
                newPos =
                    pos + P.getCharWidth word
            in
            eatMultiCommentHelp src newPos end row (col + 1) openComments



-- ====== DOCUMENTATION COMMENT ======


{-| Reads a doc comment, from its opening to the matching close, at the
current position, and returns its body as a snippet placed at the row and
column where the body starts.

The body excludes both delimiters, and block comments may nest in it. It reads
no whitespace before the comment. Without a doc comment here it fails without
consuming, through `toExpectation`. A tab in the comment fails at the tab, and
a comment with no end fails at its opening `{`, both through `toSpaceError` and
as consumed input.

-}
docComment : (Int -> Int -> x) -> (E.Space -> Int -> Int -> x) -> P.Parser x Src.Comment
docComment toExpectation toSpaceError =
    P.Parser <|
        \(P.State st) ->
            let
                pos3 : Int
                pos3 =
                    st.pos + 3
            in
            if
                (pos3 <= st.end)
                    && (P.unsafeIndex st.src st.pos == '{')
                    && (P.unsafeIndex st.src (st.pos + 1) == '-')
                    && (P.unsafeIndex st.src (st.pos + 2) == '|')
            then
                let
                    col3 : Col
                    col3 =
                        st.col + 3

                    ( ( status, newPos ), ( newRow, newCol ) ) =
                        eatMultiCommentHelp st.src pos3 st.end st.row col3 1
                in
                case status of
                    MultiGood ->
                        let
                            off : Int
                            off =
                                pos3

                            len : Int
                            len =
                                newPos - pos3 - 2

                            snippet : Snippet.Snippet
                            snippet =
                                Snippet.Snippet
                                    { fptr = st.src
                                    , offset = off
                                    , length = len
                                    , offRow = st.row
                                    , offCol = col3
                                    }

                            comment : Src.Comment
                            comment =
                                Src.Comment snippet

                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, row = newRow, col = newCol }
                        in
                        P.Cok comment newState

                    MultiTab ->
                        P.Cerr newRow newCol (toSpaceError E.HasTab)

                    MultiEndless ->
                        P.Cerr st.row st.col (toSpaceError E.EndlessMultiComment)

            else
                P.Eerr st.row st.col toExpectation
