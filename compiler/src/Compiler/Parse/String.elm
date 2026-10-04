module Compiler.Parse.String exposing (string, character)

{-| A string or character literal must be checked and recorded without losing
how it was written, and this module scans both kinds.

`string` reads a `"` string, which must close on the line it opens on, or a
`"""` string, which may run over several lines. `character` reads a `'`
literal, which must hold exactly one character. Both accept the escapes `\n`,
`\r`, `\t`, `\"`, `\'`, `\\` and `\u{...}`, where the braces hold four to six
hexadecimal digits naming a code point no greater than `10FFFF`. Any other
escape is an error of the `Escape` type in `Compiler.Reporting.Error.Syntax`.

The result is the literal's escaped text, not the value it denotes, in the form
`Compiler.Elm.String` describes. An escape written in the source stays as
written, so `\n` remains two characters. A few things are rewritten as escapes:
a bare `'` in a string becomes `\'`, a bare `"` in a character literal becomes
`\"`, a raw newline or carriage return inside `"""` becomes `\n` or `\r`, and
`\u{...}` becomes one `\uXXXX` escape, or two (a surrogate pair) for a code
point of `FFFF` or more. A bare `"` inside `"""` is kept as it is. So two
literals that denote the same value can give different text.

Most of the file is the scanners behind these two parsers. Each walks the
source one character at a time, collecting the literal as a list of chunks,
newest first, where a chunk is either a stretch of source to copy or an escape
to write. It tracks the row and column as it goes, so that an error is reported
where it occurs.

@docs string, character

-}

import Compiler.Elm.String as ES
import Compiler.Parse.Number as Number
import Compiler.Parse.Primitives as P exposing (Col, Parser(..), Row)
import Compiler.Reporting.Error.Syntax as E



-- ====== CHARACTER ======


{-| Parses a character literal such as `'a'`, `'\n'` or `'\u{00E9}'`, giving
its escaped text.

When the next character is not `'`, the parser fails without consuming input,
with `toExpectation`. Every other failure consumes input and gives a `toError`
value. `CharNotString` is for quotes that hold no character or more than one,
and carries the width from the opening quote to just past the closing one.
`CharEndless` is for a newline or the end of the input before the closing
quote, reported where the line or input ended, or at a backslash that is the
last character of the input. `CharEscape` is for a bad escape, reported at its
backslash.

-}
character : (Row -> Col -> x) -> (E.Char -> Row -> Col -> x) -> Parser x String
character toExpectation toError =
    Parser
        (\(P.State st) ->
            if st.pos >= st.end || P.unsafeIndex st.src st.pos /= '\'' then
                P.Eerr st.row st.col toExpectation

            else
                case chompChar st.src (st.pos + 1) st.end st.row (st.col + 1) 0 placeholder of
                    Good newPos newCol numChars mostRecent ->
                        if numChars /= 1 then
                            P.Cerr st.row st.col (toError (E.CharNotString (newCol - st.col)))

                        else
                            let
                                newState : P.State
                                newState =
                                    P.State { st | pos = newPos, col = newCol }

                                char : String
                                char =
                                    ES.fromChunks st.src [ mostRecent ]
                            in
                            P.Cok char newState

                    CharEndless newCol ->
                        P.Cerr st.row newCol (toError E.CharEndless)

                    CharEscape r c escape ->
                        P.Cerr r c (toError (E.CharEscape escape))
        )


{-| The outcome of scanning the inside of a character literal.

`Good` carries the position and column just past the closing `'`, the number of
characters between the quotes, and the chunk for the last of them.

`CharEndless` carries the column at which scanning stopped without finding the
closing quote.

`CharEscape` carries the position of the backslash and what is wrong with its
escape.

-}
type CharResult
    = Good Int Col Int ES.Chunk
    | CharEndless Col
    | CharEscape Row Col E.Escape


{-| Scans a character literal from `pos` up to and including its closing `'`,
counting the characters read in `numChars` and keeping the chunk for the most
recent one in `mostRecent`. A bare `"` is kept as the escape `\"`, a `\u{...}`
as its code point, and any other character or escape as the stretch of source
it occupies.
-}
chompChar : String -> Int -> Int -> Row -> Col -> Int -> ES.Chunk -> CharResult
chompChar src pos end row col numChars mostRecent =
    if pos >= end then
        CharEndless col

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if word == '\'' then
            Good (pos + 1) (col + 1) numChars mostRecent

        else if word == '\n' then
            CharEndless col

        else if word == '"' then
            chompChar src (pos + 1) end row (col + 1) (numChars + 1) doubleQuote

        else if word == '\\' then
            case eatEscape src (pos + 1) end row col of
                EscapeNormal ->
                    chompChar src (pos + 2) end row (col + 2) (numChars + 1) (ES.Slice pos 2)

                EscapeUnicode delta code ->
                    chompChar src (pos + delta) end row (col + delta) (numChars + 1) (ES.CodePoint code)

                EscapeProblem r c badEscape ->
                    CharEscape r c badEscape

                EscapeEndOfFile ->
                    CharEndless col

        else
            let
                width : Int
                width =
                    P.getCharWidth word

                newPos : Int
                newPos =
                    pos + width
            in
            chompChar src newPos end row (col + 1) (numChars + 1) (ES.Slice pos width)



-- ====== STRINGS ======


{-| Parses a string literal, giving its escaped text and whether it was written
with `"""`.

`""` not followed by a third `"` is the empty single-line string. When the next
character is not `"`, the parser fails without consuming input, with
`toExpectation`. Every other failure consumes input and gives a `toError` value.
A `"` string that meets a newline or the end of the input gives
`StringEndless_Single` at that point. A `"""` string whose closing `"""` is
never found gives `StringEndless_Multi` at its opening quotes. A bad escape
gives `StringEscape` at its backslash.

-}
string : (Row -> Col -> x) -> (E.String_ -> Row -> Col -> x) -> Parser x ( String, Bool )
string toExpectation toError =
    Parser
        (\(P.State st) ->
            if isDoubleQuote st.src st.pos st.end then
                let
                    pos1 : Int
                    pos1 =
                        st.pos + 1
                in
                case
                    if isDoubleQuote st.src pos1 st.end then
                        let
                            pos2 : Int
                            pos2 =
                                st.pos + 2
                        in
                        if isDoubleQuote st.src pos2 st.end then
                            let
                                pos3 : Int
                                pos3 =
                                    st.pos + 3

                                col3 : Col
                                col3 =
                                    st.col + 3
                            in
                            multiString st.src pos3 st.end st.row col3 pos3 st.row st.col []

                        else
                            SROk pos2 st.row (st.col + 2) "" False

                    else
                        singleString st.src pos1 st.end st.row (st.col + 1) pos1 []
                of
                    SROk newPos newRow newCol utf8 multiline ->
                        let
                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, row = newRow, col = newCol }
                        in
                        P.Cok ( utf8, multiline ) newState

                    SRErr r c x ->
                        P.Cerr r c (toError x)

            else
                P.Eerr st.row st.col toExpectation
        )


{-| Returns whether the character at `pos` is `"`, and `False` when `pos` is
at or past `end`.
-}
isDoubleQuote : String -> Int -> Int -> Bool
isDoubleQuote src pos end =
    pos < end && P.unsafeIndex src pos == '"'


{-| The outcome of scanning the inside of a string literal.

`SROk` carries the position, row and column just past the closing quotes, the
escaped text, and whether the literal was written with `"""`.

`SRErr` carries the position the error is reported at, and the error.

-}
type StringResult
    = SROk Int Row Col String Bool
    | SRErr Row Col E.String_


{-| Returns the escaped text of a literal whose chunks so far are `revChunks`,
newest first, followed by the source from `start` up to `end`.
-}
finalize : String -> Int -> Int -> List ES.Chunk -> String
finalize src start end revChunks =
    ES.fromChunks src <|
        List.reverse <|
            if start == end then
                revChunks

            else
                ES.Slice start (end - start) :: revChunks


{-| Returns `revChunks`, newest first, extended by the source from `start` up
to `end` when that is not empty, and then by `chunk`.
-}
addEscape : ES.Chunk -> Int -> Int -> List ES.Chunk -> List ES.Chunk
addEscape chunk start end revChunks =
    if start == end then
        chunk :: revChunks

    else
        chunk :: ES.Slice start (end - start) :: revChunks



-- ====== SINGLE STRINGS ======


{-| Scans a `"` string from `pos` to its closing quote.

`initialPos` is where the stretch of source not yet in `revChunks` begins.
Ordinary characters and escapes such as `\n` extend that stretch; only a bare
`'` or a `\u{...}` escape closes it and adds an escape chunk.

-}
singleString : String -> Int -> Int -> Row -> Col -> Int -> List ES.Chunk -> StringResult
singleString src pos end row col initialPos revChunks =
    if pos >= end then
        SRErr row col E.StringEndless_Single

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if word == '"' then
            SROk (pos + 1)
                row
                (col + 1)
                (finalize src initialPos pos revChunks)
                False

        else if word == '\n' then
            SRErr row col E.StringEndless_Single

        else if word == '\'' then
            let
                newPos : Int
                newPos =
                    pos + 1
            in
            addEscape singleQuote initialPos pos revChunks |> singleString src newPos end row (col + 1) newPos

        else if word == '\\' then
            case eatEscape src (pos + 1) end row col of
                EscapeNormal ->
                    singleString src (pos + 2) end row (col + 2) initialPos revChunks

                EscapeUnicode delta code ->
                    let
                        newPos : Int
                        newPos =
                            pos + delta
                    in
                    addEscape (ES.CodePoint code) initialPos pos revChunks |> singleString src newPos end row (col + delta) newPos

                EscapeProblem r c x ->
                    SRErr r c (E.StringEscape x)

                EscapeEndOfFile ->
                    SRErr row (col + 1) E.StringEndless_Single

        else
            let
                newPos : Int
                newPos =
                    pos + P.getCharWidth word
            in
            singleString src newPos end row (col + 1) initialPos revChunks



-- ====== MULTI STRINGS ======


{-| Scans a `"""` string from `pos` to its closing `"""`, as `singleString`
does, with two differences. A raw newline or carriage return also closes the
stretch and adds an escape chunk; a newline moves to the next row, and a
carriage return leaves the column unchanged. And a literal left unclosed is
reported at `sr` and `sc`, the position of its opening quotes.
-}
multiString : String -> Int -> Int -> Row -> Col -> Int -> Row -> Col -> List ES.Chunk -> StringResult
multiString src pos end row col initialPos sr sc revChunks =
    if pos >= end then
        SRErr sr sc E.StringEndless_Multi

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if word == '"' && isDoubleQuote src (pos + 1) end && isDoubleQuote src (pos + 2) end then
            SROk (pos + 3)
                row
                (col + 3)
                (finalize src initialPos pos revChunks)
                True

        else if word == '\'' then
            let
                pos1 : Int
                pos1 =
                    pos + 1
            in
            addEscape singleQuote initialPos pos revChunks |> multiString src pos1 end row (col + 1) pos1 sr sc

        else if word == '\n' then
            let
                pos1 : Int
                pos1 =
                    pos + 1
            in
            addEscape newline initialPos pos revChunks |> multiString src pos1 end (row + 1) 1 pos1 sr sc

        else if word == '\u{000D}' then
            let
                pos1 : Int
                pos1 =
                    pos + 1
            in
            addEscape carriageReturn initialPos pos revChunks |> multiString src pos1 end row col pos1 sr sc

        else if word == '\\' then
            case eatEscape src (pos + 1) end row col of
                EscapeNormal ->
                    multiString src (pos + 2) end row (col + 2) initialPos sr sc revChunks

                EscapeUnicode delta code ->
                    let
                        newPos : Int
                        newPos =
                            pos + delta
                    in
                    addEscape (ES.CodePoint code) initialPos pos revChunks |> multiString src newPos end row (col + delta) newPos sr sc

                EscapeProblem r c x ->
                    SRErr r c (E.StringEscape x)

                EscapeEndOfFile ->
                    SRErr sr sc E.StringEndless_Multi

        else
            let
                newPos : Int
                newPos =
                    pos + P.getCharWidth word
            in
            multiString src newPos end row (col + 1) initialPos sr sc revChunks



-- ====== ESCAPE CHARACTERS ======


{-| What a backslash in a literal begins.

`EscapeNormal` is one of the two-character escapes `\n`, `\r`, `\t`, `\"`, `\'`
and `\\`.

`EscapeUnicode` is a valid `\u{...}` escape, and carries its width in
characters, from the backslash to the closing brace, and the code point.

`EscapeEndOfFile` is a backslash that is the last character of the input.

`EscapeProblem` carries the position of the backslash and the error.

-}
type Escape
    = EscapeNormal
    | EscapeUnicode Int Int
    | EscapeEndOfFile
    | EscapeProblem Row Col E.Escape


{-| Reads the escape whose backslash is at `row` and `col` and whose next
character is at `pos`.
-}
eatEscape : String -> Int -> Int -> Row -> Col -> Escape
eatEscape src pos end row col =
    if pos >= end then
        EscapeEndOfFile

    else
        case P.unsafeIndex src pos of
            'n' ->
                EscapeNormal

            'r' ->
                EscapeNormal

            't' ->
                EscapeNormal

            '"' ->
                EscapeNormal

            '\'' ->
                EscapeNormal

            '\\' ->
                EscapeNormal

            'u' ->
                eatUnicode src (pos + 1) end row col

            _ ->
                EscapeProblem row col E.EscapeUnknown


{-| Reads the rest of a `\u` escape from `pos`, just after the `u`, where the
backslash is at `row` and `col`.

A missing `{`, or digits not followed by `}`, is `BadUnicodeFormat`. A value
above `10FFFF`, or no digits at all (`\u{}`), is `BadUnicodeCode`. Fewer than
four or more than six digits is `BadUnicodeLength`; the value is checked first,
so too many digits with a value above `10FFFF` is `BadUnicodeCode`.

-}
eatUnicode : String -> Int -> Int -> Row -> Col -> Escape
eatUnicode src pos end row col =
    if pos >= end || P.unsafeIndex src pos /= '{' then
        EscapeProblem row col (E.BadUnicodeFormat 2)

    else
        let
            digitPos : Int
            digitPos =
                pos + 1

            ( newPos, code ) =
                Number.chompHex src digitPos end

            numDigits : Int
            numDigits =
                newPos - digitPos
        in
        if newPos >= end || P.unsafeIndex src newPos /= '}' then
            EscapeProblem row col (E.BadUnicodeFormat (2 + numDigits))

        else if code < 0 || code > 0x0010FFFF then
            EscapeProblem row col (E.BadUnicodeCode (3 + numDigits))

        else if numDigits < 4 || numDigits > 6 then
            EscapeProblem row col (E.BadUnicodeLength (3 + numDigits) numDigits code)

        else
            EscapeUnicode (numDigits + 4) code


{-| The chunk written as `\'`, which stands for a bare `'` in a string.
-}
singleQuote : ES.Chunk
singleQuote =
    ES.Escape '\''


{-| The chunk written as `\"`, which stands for a bare `"` in a character
literal.
-}
doubleQuote : ES.Chunk
doubleQuote =
    ES.Escape '"'


{-| The chunk written as `\n`, which stands for a raw newline in a `"""`
string.
-}
newline : ES.Chunk
newline =
    ES.Escape 'n'


{-| The chunk written as `\r`, which stands for a raw carriage return in a
`"""` string.
-}
carriageReturn : ES.Chunk
carriageReturn =
    ES.Escape 'r'


{-| The chunk `character` starts from before it has read a character. It never
reaches a result, because a literal with no character is rejected.
-}
placeholder : ES.Chunk
placeholder =
    ES.CodePoint 0xFFFD
