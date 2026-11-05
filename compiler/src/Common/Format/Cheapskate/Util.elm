module Common.Format.Cheapskate.Util exposing
    ( Scanner
    , isEscapable, isWhitespace
    , joinLines, tabFilter
    , scanBlankline, scanChar, scanIndentSpace, scanNonindentSpace
    , scanSpaces, scanSpacesToColumn, scanSpnl
    , nfb, nfbChar
    , upToCountChars
    )

{-| Small building blocks for Cheapskate, the Markdown parser the formatter
reads doc comments with: tests on characters, helpers on strings, and scanners.

A _scanner_ is a parser run only to learn whether a pattern matches at the
current place in the input, and to consume what matched. It returns nothing.
The scanners here consume spaces, a given character or a newline, or check that
something does not come next. Parsers, positions and columns are as
`Common.Format.Cheapskate.ParserCombinators` describes them.

`scanBlankline` takes the end of the input to be the end of the line, so it
recognises a blank line only when run on a single line. Of the scanners here,
only `scanSpnl`, and `scanChar` given a newline, consume a newline.

The scanners count only the space character as a space. A tab is an ordinary
character to them; `tabFilter` is what turns tabs into spaces.

`isEscapable` does not do what its name suggests: it leaves out three ASCII
punctuation characters. Its docstring gives the details.

@docs Scanner


# Character Classification

@docs isEscapable, isWhitespace


# String Utilities

@docs joinLines, tabFilter


# Scanning Combinators

@docs scanBlankline, scanChar, scanIndentSpace, scanNonindentSpace
@docs scanSpaces, scanSpacesToColumn, scanSpnl


# Lookahead Assertions

@docs nfb, nfbChar


# Character Consumption

@docs upToCountChars

-}

import Common.Format.Cheapskate.ParserCombinators exposing (Parser, andThen, char, column, count, endOfInput, getPosition, map, notFollowedBy, option, return, scan, skip, skipWhile)


{-| Joins the lines into one string with a newline between each pair and none
after the last.
-}
joinLines : List String -> String
joinLines =
    String.join "\n"


{-| Returns the string with each tab replaced by the spaces that reach the next
tab stop, with stops every four columns. A tab always becomes at least one
space, and becomes four when it already sits on a stop.

Columns are counted from the start of the string, and a newline counts as an
ordinary character, so the result is right only for a string holding one line.

-}
tabFilter : String -> String
tabFilter =
    let
        pad : List String -> List String
        pad value =
            case value of
                t :: ((_ :: _) as ts) ->
                    let
                        tl : Int
                        tl =
                            String.length t

                        n : Int
                        n =
                            tl + 4 - modBy 4 tl
                    in
                    String.padRight n ' ' t :: pad ts

                _ ->
                    value
    in
    String.split "\t" >> pad >> String.concat


{-| Tests whether `c` is a space or a line feed. No other character counts, not
even a non-breaking space or a form feed. Tabs and carriage returns never reach
the Markdown parser: `processLines` splits the text with `String.lines` and
expands tabs with `tabFilter`.
-}
isWhitespace : Char -> Bool
isWhitespace c =
    case c of
        ' ' ->
            True

        '\n' ->
            True

        _ ->
            False


{-| Tests whether `c` is one of the characters that a backslash escapes.

Of the 32 ASCII characters that are not letters, digits, the space or control
characters, all but three are escapable: `$`, `~` and the backtick are not. No
character outside ASCII is escapable.

-}
isEscapable : Char -> Bool
isEscapable c =
    isAscii c && (isSymbol c || isPunctuation c)


{-| A parser run only for whether it matches and for what it consumes. Its
result is always `()`.

This is a name for `Parser ()`, not a new type, so any `Parser ()` is accepted
where a `Scanner` is expected.

-}
type alias Scanner =
    Parser ()


{-| A scanner that consumes four spaces, and fails unless the next four
characters are all spaces. What follows them is not looked at.
-}
scanIndentSpace : Scanner
scanIndentSpace =
    map (\_ -> ()) (count 4 (skip ((==) ' ')))


{-| Produces a scanner that consumes spaces up to column `col`: exactly as many
as `col` is ahead of the current column, failing if there are fewer spaces than
that. At or past `col` it consumes nothing and succeeds.
-}
scanSpacesToColumn : Int -> Scanner
scanSpacesToColumn col =
    getPosition
        |> map column
        |> andThen
            (\currentCol ->
                let
                    n : Int
                    n =
                        col - currentCol
                in
                if n >= 1 then
                    count n (skip ((==) ' '))
                        |> map (\_ -> ())

                else
                    return ()
            )


{-| A scanner that consumes as many spaces as come next, up to three. It never
fails.
-}
scanNonindentSpace : Scanner
scanNonindentSpace =
    map (\_ -> ()) (upToCountChars 3 ((==) ' '))


{-| Produces a scanner that consumes `c` if it is the next character, and fails
otherwise.
-}
scanChar : Char -> Scanner
scanChar c =
    skip ((==) c) |> andThen (\_ -> return ())


{-| A scanner that succeeds, consuming the rest of the input, when that rest is
empty or holds only spaces. A tab or a newline makes it fail.
-}
scanBlankline : Scanner
scanBlankline =
    scanSpaces |> andThen (\_ -> endOfInput)


{-| A scanner that consumes every space that comes next, if any. It never fails.
-}
scanSpaces : Scanner
scanSpaces =
    skipWhile ((==) ' ')


{-| A scanner that consumes spaces, then, if a newline comes next, that newline
and the spaces after it. It crosses at most one newline, and never fails.
-}
scanSpnl : Scanner
scanSpnl =
    scanSpaces |> andThen (\_ -> option () (char '\n' |> andThen (\_ -> scanSpaces)))


{-| Produces a scanner that consumes nothing and succeeds exactly when `p` would
fail at the current place in the input. The name is short for "not followed
by".
-}
nfb : Parser a -> Scanner
nfb =
    notFollowedBy


{-| Produces a scanner that consumes nothing and succeeds unless the next
character is `c`. It succeeds at the end of the input.
-}
nfbChar : Char -> Scanner
nfbChar c =
    nfb (skip ((==) c))


{-| Produces a parser that consumes and returns the longest prefix of the input
whose characters all satisfy `f`, cut off at `cnt` characters. It never fails,
and returns `""` when the next character does not satisfy `f` or `cnt` is zero
or less.
-}
upToCountChars : Int -> (Char -> Bool) -> Parser String
upToCountChars cnt f =
    scan 0
        (\n c ->
            if n < cnt && f c then
                Just (n + 1)

            else
                Nothing
        )


{-| Tests whether `c` is an ASCII character, that is, below U+0080.
-}
isAscii : Char -> Bool
isAscii c =
    c < '\u{0080}'


{-| Tests whether `c` is one of the fifteen characters `+ - / * = . < > : & | ^ ? % !`.

Together with `isPunctuation` this decides `isEscapable`. `$`, `~` and the
backtick are in neither.

-}
isSymbol : Char -> Bool
isSymbol c =
    String.contains (String.fromChar c) "+-/*=.<>:&|^?%!"


{-| Tests whether `c` is one of the ASCII characters that Unicode classes as
punctuation, such as `-`, brackets and quotation marks: `! " # % & ' ( ) * , - .
/ : ; ? @ [ \ ] _ { }`. `isEscapable` asks only about ASCII characters.
-}
isPunctuation : Char -> Bool
isPunctuation c =
    List.member (Char.toCode c)
        [ 0x21
        , 0x22
        , 0x23
        , 0x25
        , 0x26
        , 0x27
        , 0x28
        , 0x29
        , 0x2A
        , 0x2C
        , 0x2D
        , 0x2E
        , 0x2F
        , 0x3A
        , 0x3B
        , 0x3F
        , 0x40
        , 0x5B
        , 0x5C
        , 0x5D
        , 0x5F
        , 0x7B
        , 0x7D
        ]
