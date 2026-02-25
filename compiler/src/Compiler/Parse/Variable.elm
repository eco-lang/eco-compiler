module Compiler.Parse.Variable exposing
    ( Upper(..)
    , lower, upper, moduleName, foreignUpper, foreignAlpha
    , isReservedWord
    , chompInnerChars
    , getInnerWidth, getInnerWidthHelp, getUpperWidth
    )

{-| Parser for variable names and identifiers in Elm.

This module handles parsing of lower-case variables, upper-case type names,
qualified names (with module prefixes), and module names. It properly handles
Unicode characters and enforces Elm's naming rules including reserved word
checking.


# Variable Types

@docs Upper


# Parsing Variables

@docs lower, upper, moduleName, foreignUpper, foreignAlpha


# Reserved Words

@docs isReservedWord


# Character Utilities

@docs chompInnerChars
@docs getInnerWidth, getInnerWidthHelp, getUpperWidth

-}

import Bitwise
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Data.Set as EverySet exposing (EverySet)



-- ====== LOCAL UPPER ======


{-| Parses an upper-case identifier (type name or constructor) that starts with A-Z.
-}
upper : (Row -> Col -> x) -> P.Parser x Name
upper toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( newPos, newCol ) =
                    chompUpper st.src st.pos st.end st.col
            in
            if newPos == st.pos then
                P.Eerr st.row st.col toError

            else
                let
                    name : Name
                    name =
                        Name.fromPtr st.src st.pos newPos
                in
                P.Cok name (P.State { st | pos = newPos, col = newCol })



-- ====== LOCAL LOWER ======


{-| Parses a lower-case identifier (variable or function name) that starts with a-z.
Rejects reserved keywords like 'if', 'then', 'case', etc.
-}
lower : (Row -> Col -> x) -> P.Parser x Name
lower toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( newPos, newCol ) =
                    chompLower st.src st.pos st.end st.col
            in
            if newPos == st.pos then
                P.Eerr st.row st.col toError

            else
                let
                    name : Name
                    name =
                        Name.fromPtr st.src st.pos newPos
                in
                if isReservedWord name then
                    P.Eerr st.row st.col toError

                else
                    let
                        newState : P.State
                        newState =
                            P.State { st | pos = newPos, col = newCol }
                    in
                    P.Cok name newState


{-| Checks whether a name is a reserved keyword that cannot be used as a variable name.
-}
isReservedWord : Name.Name -> Bool
isReservedWord name =
    EverySet.member identity name reservedWords


reservedWords : EverySet String Name
reservedWords =
    EverySet.fromList identity
        [ "if"
        , "then"
        , "else"
        , "case"
        , "of"
        , "let"
        , "in"
        , "type"
        , "module"
        , "where"
        , "import"
        , "exposing"
        , "as"
        , "port"
        ]



-- ====== MODULE NAME ======


{-| Parses a module name like 'Html', 'Json.Decode', or 'Data.Map.Internal'.
Module names consist of one or more upper-case identifiers separated by dots.
-}
moduleName : (Row -> Col -> x) -> P.Parser x Name
moduleName toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( pos1, col1 ) =
                    chompUpper st.src st.pos st.end st.col
            in
            if st.pos == pos1 then
                P.Eerr st.row st.col toError

            else
                let
                    ( status, newPos, newCol ) =
                        moduleNameHelp st.src pos1 st.end col1
                in
                case status of
                    Good ->
                        let
                            name : Name
                            name =
                                Name.fromPtr st.src st.pos newPos

                            newState : P.State
                            newState =
                                P.State { st | pos = newPos, col = newCol }
                        in
                        P.Cok name newState

                    Bad ->
                        P.Cerr st.row newCol toError


type ModuleNameStatus
    = Good
    | Bad


moduleNameHelp : String -> Int -> Int -> Col -> ( ModuleNameStatus, Int, Col )
moduleNameHelp src pos end col =
    if isDot src pos end then
        let
            pos1 : Int
            pos1 =
                pos + 1

            ( newPos, newCol ) =
                chompUpper src pos1 end (col + 1)
        in
        if pos1 == newPos then
            ( Bad, newPos, newCol )

        else
            moduleNameHelp src newPos end newCol

    else
        ( Good, pos, col )



-- ====== FOREIGN UPPER ======


{-| Represents an upper-case name that may be qualified with a module prefix.
-}
type Upper
    = Unqualified Name
    | Qualified Name Name


{-| Parses an upper-case identifier that may be qualified with a module prefix.
Examples: 'Just', 'Maybe.Just', 'Html.Attributes.class'.
-}
foreignUpper : (Row -> Col -> x) -> P.Parser x Upper
foreignUpper toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( upperStart, upperEnd, newCol ) =
                    foreignUpperHelp st.src st.pos st.end st.col
            in
            if upperStart == upperEnd then
                P.Eerr st.row newCol toError

            else
                let
                    newState : P.State
                    newState =
                        P.State { st | pos = upperEnd, col = newCol }

                    name : Name
                    name =
                        Name.fromPtr st.src upperStart upperEnd

                    upperName : Upper
                    upperName =
                        if upperStart == st.pos then
                            Unqualified name

                        else
                            let
                                home : Name
                                home =
                                    Name.fromPtr st.src st.pos (upperStart + -1)
                            in
                            Qualified home name
                in
                P.Cok upperName newState


foreignUpperHelp : String -> Int -> Int -> Col -> ( Int, Int, Col )
foreignUpperHelp src pos end col =
    let
        ( newPos, newCol ) =
            chompUpper src pos end col
    in
    if pos == newPos then
        ( pos, pos, col )

    else if isDot src newPos end then
        foreignUpperHelp src (newPos + 1) end (newCol + 1)

    else
        ( pos, newPos, newCol )



-- ====== FOREIGN ALPHA ======


{-| Parses a qualified or unqualified variable reference (upper or lower case).
Returns a Var or VarQual expression node. Examples: 'x', 'map', 'List.map', 'Maybe.Just'.
-}
foreignAlpha : (Row -> Col -> x) -> P.Parser x Src.Expr_
foreignAlpha toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( ( alphaStart, alphaEnd ), ( newCol, varType ) ) =
                    foreignAlphaHelp st.src st.pos st.end st.col
            in
            if alphaStart == alphaEnd then
                P.Eerr st.row newCol toError

            else
                let
                    name : Name
                    name =
                        Name.fromPtr st.src alphaStart alphaEnd

                    newState : P.State
                    newState =
                        P.State { st | pos = alphaEnd, col = newCol }
                in
                if alphaStart == st.pos then
                    if isReservedWord name then
                        P.Eerr st.row st.col toError

                    else
                        P.Cok (Src.Var varType name) newState

                else
                    let
                        home : Name
                        home =
                            Name.fromPtr st.src st.pos (alphaStart + -1)
                    in
                    P.Cok (Src.VarQual varType home name) newState


foreignAlphaHelp : String -> Int -> Int -> Col -> ( ( Int, Int ), ( Col, Src.VarType ) )
foreignAlphaHelp src pos end col =
    let
        ( lowerPos, lowerCol ) =
            chompLower src pos end col
    in
    if pos < lowerPos then
        ( ( pos, lowerPos ), ( lowerCol, Src.LowVar ) )

    else
        let
            ( upperPos, upperCol ) =
                chompUpper src pos end col
        in
        if pos == upperPos then
            ( ( pos, pos ), ( col, Src.CapVar ) )

        else if isDot src upperPos end then
            foreignAlphaHelp src (upperPos + 1) end (upperCol + 1)

        else
            ( ( pos, upperPos ), ( upperCol, Src.CapVar ) )



---- CHAR CHOMPERS ----
-- ====== DOTS ======


{-| Checks if the character at the given position is a dot (.).
-}
isDot : String -> Int -> Int -> Bool
isDot src pos end =
    pos < end && P.unsafeIndex src pos == '.'



-- ====== UPPER CHARS ======


{-| Consumes an upper-case identifier including any trailing inner characters (letters, digits, underscores).
Returns the new position and column after consuming the identifier.
-}
chompUpper : String -> Int -> Int -> Col -> ( Int, Col )
chompUpper src pos end col =
    let
        width : Int
        width =
            getUpperWidth src pos end
    in
    if width == 0 then
        ( pos, col )

    else
        chompInnerChars src (pos + width) end (col + 1)


{-| Returns the byte width of an upper-case starting character (1-4 bytes for UTF-8).
Returns 0 if the character is not upper-case.
-}
getUpperWidth : String -> Int -> Int -> Int
getUpperWidth src pos end =
    if pos < end then
        getUpperWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Helper for getUpperWidth that determines byte width based on the first character.
Handles ASCII upper-case letters and multi-byte UTF-8 upper-case characters.
-}
getUpperWidthHelp : String -> Int -> Int -> Char -> Int
getUpperWidthHelp src pos _ word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x41 {- A -} && code <= 0x5A {- Z -} then
        1

    else if code < 0xC0 then
        0

    else if code < 0xE0 then
        if Char.isUpper (chr2 src pos word) then
            2

        else
            0

    else if code < 0xF0 then
        if Char.isUpper (chr3 src pos word) then
            3

        else
            0

    else if code < 0xF8 then
        if Char.isUpper (chr4 src pos word) then
            4

        else
            0

    else
        0



-- ====== LOWER CHARS ======


{-| Consumes a lower-case identifier including any trailing inner characters (letters, digits, underscores).
Returns the new position and column after consuming the identifier.
-}
chompLower : String -> Int -> Int -> Col -> ( Int, Col )
chompLower src pos end col =
    let
        width : Int
        width =
            getLowerWidth src pos end
    in
    if width == 0 then
        ( pos, col )

    else
        chompInnerChars src (pos + width) end (col + 1)


getLowerWidth : String -> Int -> Int -> Int
getLowerWidth src pos end =
    if pos < end then
        getLowerWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


getLowerWidthHelp : String -> Int -> Int -> Char -> Int
getLowerWidthHelp src pos _ word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x61 {- a -} && code <= 0x7A {- z -} then
        1

    else if code < 0xC0 then
        0

    else if code < 0xE0 then
        if Char.isLower (chr2 src pos word) then
            2

        else
            0

    else if code < 0xF0 then
        if Char.isLower (chr3 src pos word) then
            3

        else
            0

    else if code < 0xF8 then
        if Char.isLower (chr4 src pos word) then
            4

        else
            0

    else
        0



-- ====== INNER CHARS ======


{-| Consumes the inner characters of an identifier (letters, digits, underscores).
Used after consuming the initial character of a variable name.
-}
chompInnerChars : String -> Int -> Int -> Col -> ( Int, Col )
chompInnerChars src pos end col =
    let
        width : Int
        width =
            getInnerWidth src pos end
    in
    if width == 0 then
        ( pos, col )

    else
        chompInnerChars src (pos + width) end (col + 1)


{-| Returns the byte width of an inner identifier character (letter, digit, or underscore).
Returns 0 if the character is not a valid inner character.
-}
getInnerWidth : String -> Int -> Int -> Int
getInnerWidth src pos end =
    if pos < end then
        getInnerWidthHelp src pos end (P.unsafeIndex src pos)

    else
        0


{-| Helper for getInnerWidth that determines byte width based on the character.
Handles ASCII alphanumeric characters, underscores, and multi-byte UTF-8 letters.
-}
getInnerWidthHelp : String -> Int -> Int -> Char -> Int
getInnerWidthHelp src pos _ word =
    let
        code : Int
        code =
            Char.toCode word
    in
    if code >= 0x61 {- a -} && code <= 0x7A {- z -} then
        1

    else if code >= 0x41 {- A -} && code <= 0x5A {- Z -} then
        1

    else if code >= 0x30 {- 0 -} && code <= 0x39 {- 9 -} then
        1

    else if code == 0x5F {- _ -} then
        1

    else if code < 0xC0 then
        0

    else if code < 0xE0 then
        if Char.isAlpha (chr2 src pos word) then
            2

        else
            0

    else if code < 0xF0 then
        if Char.isAlpha (chr3 src pos word) then
            3

        else
            0

    else if code < 0xF8 then
        if Char.isAlpha (chr4 src pos word) then
            4

        else
            0

    else
        0



-- ====== EXTRACT CHARACTERS ======


chr2 : String -> Int -> Char -> Char
chr2 src pos firstWord =
    let
        i1 : Int
        i1 =
            unpack firstWord

        i2 : Int
        i2 =
            unpack (P.unsafeIndex src (pos + 1))

        c1 : Int
        c1 =
            (i1 - 0xC0) |> Bitwise.shiftLeftBy 6

        c2 : Int
        c2 =
            i2 - 0x80
    in
    Char.fromCode (c1 + c2)


chr3 : String -> Int -> Char -> Char
chr3 src pos firstWord =
    let
        i1 : Int
        i1 =
            unpack firstWord

        i2 : Int
        i2 =
            unpack (P.unsafeIndex src (pos + 1))

        i3 : Int
        i3 =
            unpack (P.unsafeIndex src (pos + 2))

        c1 : Int
        c1 =
            (i1 - 0xE0) |> Bitwise.shiftLeftBy 12

        c2 : Int
        c2 =
            (i2 - 0x80) |> Bitwise.shiftLeftBy 6

        c3 : Int
        c3 =
            i3 - 0x80
    in
    Char.fromCode (c1 + c2 + c3)


chr4 : String -> Int -> Char -> Char
chr4 src pos firstWord =
    let
        i1 : Int
        i1 =
            unpack firstWord

        i2 : Int
        i2 =
            unpack (P.unsafeIndex src (pos + 1))

        i3 : Int
        i3 =
            unpack (P.unsafeIndex src (pos + 2))

        i4 : Int
        i4 =
            unpack (P.unsafeIndex src (pos + 3))

        c1 : Int
        c1 =
            (i1 - 0xF0) |> Bitwise.shiftLeftBy 18

        c2 : Int
        c2 =
            (i2 - 0x80) |> Bitwise.shiftLeftBy 12

        c3 : Int
        c3 =
            (i3 - 0x80) |> Bitwise.shiftLeftBy 6

        c4 : Int
        c4 =
            i4 - 0x80
    in
    Char.fromCode (c1 + c2 + c3 + c4)


unpack : Char -> Int
unpack =
    Char.toCode
