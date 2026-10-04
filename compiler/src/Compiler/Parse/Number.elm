module Compiler.Parse.Number exposing
    ( Number(..), Outcome(..)
    , number, precedence
    , chompHex
    )

{-| A number written in source is scanned here, so that a malformed one is
reported with the specific mistake it contains rather than as an unexpected
character.

`number` reads a decimal integer such as `42`, a hexadecimal integer such as
`0x1F` (a lower-case `x` only), or a float such as `1.5`, `2e10` or `3.0E-4`. It
returns the value together with the source text it was read from. A literal
must start with a digit, so `-1` is not a number here, and `.5` is not either.

Most of the file is a set of scanners, one for each part of a literal: the
integer part, a leading zero, the fraction, the exponent and hexadecimal digits.
Each moves forward one character at a time and returns an `Outcome`. A scanner
is a plain function on the source text and a position, not a parser, which is
why `number` alone deals with rows, columns and the parser state.

Two rules decide most of the errors. A literal must not run straight into a
character that could continue a name: `12abc` or `1_000` is a `NumberEnd` error,
not the number `12` followed by a name. What counts as such a character is
whatever `Compiler.Parse.Variable.getInnerWidthHelp` accepts inside a name. And
a literal starting with `0` may only be `0` itself, a fraction such as `0.5`, or
a hexadecimal literal, so `007` is a `NumberNoLeadingZero` error and `0e5` a
`NumberEnd` error. The errors are the `Number` type of
`Compiler.Reporting.Error.Syntax`.

`precedence`, which reads the single digit of an `infix` declaration, is here
because it is the one other parser that reads a digit.


# Number Types

@docs Number, Outcome


# Parsing Numbers

@docs number, precedence


# Hexadecimal Parsing

@docs chompHex

-}

import Compiler.AST.Utils.Binop as Binop
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Error.Syntax as E



-- ====== HELPERS ======


{-| Returns whether `word`, the character at `pos`, is one that may continue a
name, which a number must not run into: an ASCII letter, a digit, `_`, or a
character `Compiler.Parse.Variable.getInnerWidthHelp` accepts beyond ASCII.
-}
isDirtyEnd : String -> Int -> Int -> Char -> Bool
isDirtyEnd src pos end word =
    Var.getInnerWidthHelp src pos end word > 0


{-| Returns whether a character is one of the ASCII digits `0` to `9`.
-}
isDecimalDigit : Char -> Bool
isDecimalDigit word =
    Char.isDigit word



-- ====== NUMBERS ======


{-| A numeric literal read from source: its value and the exact text it was
written as.

`Int` is an integer, written in decimal or in hexadecimal. `Float` is a literal
with a fraction, an exponent or both. In each, the `String` is the literal as it
appears in the source, such as `0x1F` or `1.50e3`, so a value can be printed the
way it was written.

The value of an `Int` is accumulated digit by digit with no overflow check, so
the value of a literal too large for an `Int` is not reliable. The value of a
`Float` is `String.toFloat` of the text.

-}
type Number
    = Int Int String
    | Float Float String


{-| Produces a parser for one numeric literal, as the module docstring
describes.

When the next character is not a digit, or the input is at its end, the parser
fails without consuming anything, with the error `toExpectation` builds at the
starting position. A literal that starts with a digit but is malformed fails as
having consumed input, with `toError` given the `Number` error and the position
where scanning stopped: the character that broke the rule, such as the letter
after `12`, the `.` of `1.` or the second digit of `07`.

One case differs. A float whose text `String.toFloat` rejects fails without
consuming anything, with `toExpectation`, but at the column after the literal
rather than at its start.

-}
number : (Row -> Col -> x) -> (E.Number -> Row -> Col -> x) -> P.Parser x Number
number toExpectation toError =
    P.Parser <|
        \(P.State st) ->
            if st.pos >= st.end then
                P.Eerr st.row st.col toExpectation

            else
                let
                    word : Char
                    word =
                        charAtPos st.pos st.src
                in
                if not (isDecimalDigit word) then
                    P.Eerr st.row st.col toExpectation

                else
                    let
                        outcome : Outcome
                        outcome =
                            if word == '0' then
                                chompZero st.src (st.pos + 1) st.end

                            else
                                chompInt st.src (st.pos + 1) st.end (Char.toCode word - Char.toCode '0')
                    in
                    case outcome of
                        Err_ newPos problem ->
                            let
                                newCol : Col
                                newCol =
                                    st.col + (newPos - st.pos)
                            in
                            P.Cerr st.row newCol (toError problem)

                        OkInt newPos n ->
                            let
                                newCol : Col
                                newCol =
                                    st.col + (newPos - st.pos)

                                integer : Number
                                integer =
                                    Int n (String.slice st.pos newPos st.src)

                                newState : P.State
                                newState =
                                    P.State { st | pos = newPos, col = newCol }
                            in
                            P.Cok integer newState

                        OkFloat newPos ->
                            let
                                newCol : Col
                                newCol =
                                    st.col + (newPos - st.pos)

                                raw : String
                                raw =
                                    String.slice st.pos newPos st.src

                                parsed : Maybe Float
                                parsed =
                                    String.toFloat raw
                            in
                            case parsed of
                                Just copy_ ->
                                    let
                                        newState : P.State
                                        newState =
                                            P.State { st | pos = newPos, col = newCol }
                                    in
                                    P.Cok (Float copy_ raw) newState

                                Nothing ->
                                    P.Eerr st.row newCol toExpectation



-- ====== CHOMP OUTCOME ======


{-| The result of scanning a literal from some position: where scanning
stopped, and what was found.

Every constructor's first `Int` is the position, an index into the source text,
where scanning stopped. For a success it is just past the literal.

`Err_` is a malformed literal, carrying the error, and its position is where
scanning stopped. That is often, but not always, the character that broke the
rule: for a bad fraction it is the `.`, and for a hexadecimal literal cut short
by the end of the input it is the end.

`OkInt` is an integer literal, and its second `Int` is the value.

`OkFloat` is a float literal. It carries no value; `number` reads that from the
text.

-}
type Outcome
    = Err_ Int E.Number
    | OkInt Int Int
    | OkFloat Int



-- ====== CHOMP INT ======


{-| Scans the rest of a decimal literal from `pos`, where `n` is the value of the
digits already read.

More digits extend the integer. A `.` or an `e` or `E` turns the literal into a
float, and the fraction or exponent is scanned in turn. A character that may
continue a name is a `NumberEnd` error. Anything else ends an integer literal.

-}
chompInt : String -> Int -> Int -> Int -> Outcome
chompInt src pos end n =
    if pos >= end then
        OkInt pos n

    else
        let
            word : Char
            word =
                charAtPos pos src
        in
        if isDecimalDigit word then
            chompInt src (pos + 1) end (10 * n + (Char.toCode word - Char.toCode '0'))

        else if word == '.' then
            chompFraction src pos end n

        else if word == 'e' || word == 'E' then
            chompExponent src (pos + 1) end

        else if isDirtyEnd src pos end word then
            Err_ pos E.NumberEnd

        else
            OkInt pos n



-- ====== CHOMP FRACTION ======


{-| Scans a fraction, where `pos` is the position of the `.` and `n` is the value
of the integer part. The `.` must be followed by a digit, otherwise the result is
a `NumberDot n` error at the `.`, so `1.` and `1.e5` are errors.
-}
chompFraction : String -> Int -> Int -> Int -> Outcome
chompFraction src pos end n =
    let
        pos1 : Int
        pos1 =
            pos + 1
    in
    if pos1 >= end then
        Err_ pos (E.NumberDot n)

    else
        let
            nextWord : Char
            nextWord =
                charAtPos pos1 src
        in
        if isDecimalDigit nextWord then
            chompFractionHelp src (pos1 + 1) end

        else
            Err_ pos (E.NumberDot n)


{-| Scans the digits of a fraction after its first. An `e` or `E` starts an
exponent, a character that may continue a name is a `NumberEnd` error, and
anything else ends a float literal.
-}
chompFractionHelp : String -> Int -> Int -> Outcome
chompFractionHelp src pos end =
    if pos >= end then
        OkFloat pos

    else
        let
            word : Char
            word =
                charAtPos pos src
        in
        if isDecimalDigit word then
            chompFractionHelp src (pos + 1) end

        else if word == 'e' || word == 'E' then
            chompExponent src (pos + 1) end

        else if isDirtyEnd src pos end word then
            Err_ pos E.NumberEnd

        else
            OkFloat pos



-- ====== CHOMP EXPONENT ======


{-| Scans an exponent, from the position just after its `e` or `E`. It must be a
digit, or a `+` or `-` followed by a digit; anything else, including the end of
the input, is a `NumberEnd` error at `pos`.
-}
chompExponent : String -> Int -> Int -> Outcome
chompExponent src pos end =
    if pos >= end then
        Err_ pos E.NumberEnd

    else
        let
            word : Char
            word =
                charAtPos pos src
        in
        if isDecimalDigit word then
            chompExponentHelp src (pos + 1) end

        else if word == '+' || word == '-' then
            let
                pos1 : Int
                pos1 =
                    pos + 1

                nextWord : Char
                nextWord =
                    charAtPos pos1 src
            in
            if pos1 < end && isDecimalDigit nextWord then
                chompExponentHelp src (pos + 2) end

            else
                Err_ pos E.NumberEnd

        else
            Err_ pos E.NumberEnd


{-| Scans the digits of an exponent after its first. The first character that is
not a digit ends a float literal, whatever it is: unlike the other scanners, this
one does not reject a character that may continue a name, so `1e5x` is read as
the float `1e5` followed by `x`.
-}
chompExponentHelp : String -> Int -> Int -> Outcome
chompExponentHelp src pos end =
    if pos >= end then
        OkFloat pos

    else
        let
            word : Char
            word =
                charAtPos pos src
        in
        if isDecimalDigit word then
            chompExponentHelp src (pos + 1) end

        else
            OkFloat pos



-- ====== CHOMP ZERO ======


{-| Scans what follows a leading `0`, from the position after it.

An `x` starts a hexadecimal literal and a `.` a fraction. Another digit is a
`NumberNoLeadingZero` error, and a character that may continue a name a
`NumberEnd` error; there is no exponent branch here, so `0e5` is that error.
Anything else ends the literal `0`.

-}
chompZero : String -> Int -> Int -> Outcome
chompZero src pos end =
    if pos >= end then
        OkInt pos 0

    else
        let
            word : Char
            word =
                charAtPos pos src
        in
        if word == 'x' then
            chompHexInt src (pos + 1) end

        else if word == '.' then
            chompFraction src pos end 0

        else if isDecimalDigit word then
            Err_ pos E.NumberNoLeadingZero

        else if isDirtyEnd src pos end word then
            Err_ pos E.NumberEnd

        else
            OkInt pos 0


{-| Scans the digits of a hexadecimal literal, from the position after `0x`. No
digits, or a character that may continue a name among or after them, is a
`NumberHexDigit` error at the position where `chompHex` stopped.
-}
chompHexInt : String -> Int -> Int -> Outcome
chompHexInt src pos end =
    let
        ( newPos, answer ) =
            chompHex src pos end
    in
    if answer < 0 then
        Err_ newPos E.NumberHexDigit

    else
        OkInt newPos answer



-- ====== CHOMP HEX ======


{-| Returns the position after the run of hexadecimal digits starting at `pos`,
and the value of those digits. Digits may be upper or lower case.

The value is negative when there is no valid run. It is `-1` when there are no
digits at all before the end of the input or a character that cannot continue a
name. It is `-2` when scanning stops at a character that may continue a name
but is not a hexadecimal digit, such as `g` or `_`, whether or not digits came
before it; the position is then that character.

There is no overflow check on the value.

-}
chompHex : String -> Int -> Int -> ( Int, Int )
chompHex src pos end =
    chompHexHelp src pos end -1 0


{-| Scans hexadecimal digits from `pos`, where `answer` is the result so far
(`-1` before any digit) and `accumulator` the value of the digits read, giving
the result `chompHex` describes.
-}
chompHexHelp : String -> Int -> Int -> Int -> Int -> ( Int, Int )
chompHexHelp src pos end answer accumulator =
    if pos >= end then
        ( pos, answer )

    else
        let
            newAnswer : Int
            newAnswer =
                stepHex src pos end (charAtPos pos src) accumulator
        in
        if newAnswer < 0 then
            ( pos
            , if newAnswer == -1 then
                answer

              else
                -2
            )

        else
            chompHexHelp src (pos + 1) end newAnswer newAnswer


{-| Returns `acc` extended by the hexadecimal digit `word`, the character at
`pos`. For a character that is not a hexadecimal digit it returns `-2` when the
character may continue a name and `-1` otherwise.
-}
stepHex : String -> Int -> Int -> Char -> Int -> Int
stepHex src pos end word acc =
    if '0' <= word && word <= '9' then
        16 * acc + (Char.toCode word - Char.toCode '0')

    else if 'a' <= word && word <= 'f' then
        16 * acc + 10 + (Char.toCode word - Char.toCode 'a')

    else if 'A' <= word && word <= 'F' then
        16 * acc + 10 + (Char.toCode word - Char.toCode 'A')

    else if isDirtyEnd src pos end word then
        -2

    else
        -1



-- ====== PRECEDENCE ======


{-| Produces a parser for the precedence in an `infix` declaration: exactly one
digit, `0` to `9`, whose value is the precedence. The character after the digit
is not examined.

When the next character is not a digit, or the input is at its end, it fails
without consuming anything, with the error `toExpectation` builds.

-}
precedence : (Row -> Col -> x) -> P.Parser x Binop.Precedence
precedence toExpectation =
    P.Parser <|
        \(P.State st) ->
            if st.pos >= st.end then
                P.Eerr st.row st.col toExpectation

            else
                let
                    word : Char
                    word =
                        charAtPos st.pos st.src
                in
                if isDecimalDigit word then
                    P.Cok
                        (Char.toCode word - Char.toCode '0')
                        (P.State { st | pos = st.pos + 1, col = st.col + 1 })

                else
                    P.Eerr st.row st.col toExpectation



-- ====== CHAR AT POSITION ======


{-| Returns the character at `pos` in `src`, or a space when `pos` is at or past
the end, so a scanner may look one character ahead without checking the bound.
-}
charAtPos : Int -> String -> Char
charAtPos pos src =
    String.dropLeft pos src
        |> String.uncons
        |> Maybe.map Tuple.first
        |> Maybe.withDefault ' '
