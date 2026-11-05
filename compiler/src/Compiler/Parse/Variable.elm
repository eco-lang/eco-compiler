module Compiler.Parse.Variable exposing
    ( Upper(..)
    , lower, matchingLower, upper, moduleName, foreignUpper, foreignAlpha
    )

{-| This module holds the parsers that read a name in Elm source. What counts
as a name, character by character, is decided in `Compiler.Lexer.Identifier`.

An _identifier_ is a first character followed by any number of _inner
characters_. The first character is a lower-case letter for the name of a
value, and an upper-case letter for the name of a type, a constructor or one
part of a module name. A _qualified_ name is preceded by its _home_, the name
of a module, written as upper-case identifiers each followed by a dot, as in
`List.map` or `Json.Decode.Decoder`. The parsers with `foreign` in their names
read a name that may be qualified.

A lower-case identifier may not be a reserved word
(`Compiler.Lexer.Identifier.isReservedWord`). Only an unqualified name is
checked against them.

Each parser is written directly as a function on the parser state, with
positions and columns as `Compiler.Lexer.Primitives` describes them. Every
failure is reported with `Eerr`, as having consumed nothing, except a dot in a
module name that is not followed by an upper-case identifier, and a name that
`matchingLower` reads but does not expect, which are `Cerr`.


# Variable Types

@docs Upper


# Parsing Variables

@docs lower, matchingLower, upper, moduleName, foreignUpper, foreignAlpha

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Name as Name exposing (Name)
import Compiler.IR.Source as Src
import Compiler.Lexer.Identifier as Identifier
import Compiler.Lexer.Primitives as P exposing (Col, Row)



-- ====== LOCAL UPPER ======


{-| Produces a parser for an unqualified upper-case identifier. It stops before
a dot, so on `Maybe.Just` it reads `Maybe`. When no upper-case identifier starts
at its position, it fails with `Eerr` there.
-}
upper : (Row -> Col -> x) -> P.Parser x Name
upper toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( newPos, newCol ) =
                    Identifier.chompUpper st.src st.pos st.end st.col
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


{-| Produces a parser for an unqualified lower-case identifier that is not a
reserved word. It fails with `Eerr` at its starting position when no lower-case
identifier starts there, and also when the identifier it reads is reserved.
-}
lower : (Row -> Col -> x) -> P.Parser x Name
lower toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( newPos, newCol ) =
                    Identifier.chompLower st.src st.pos st.end st.col
            in
            if newPos == st.pos then
                P.Eerr st.row st.col toError

            else
                let
                    name : Name
                    name =
                        Name.fromPtr st.src st.pos newPos
                in
                if Identifier.isReservedWord name then
                    P.Eerr st.row st.col toError

                else
                    let
                        newState : P.State
                        newState =
                            P.State { st | pos = newPos, col = newCol }
                    in
                    P.Cok name newState



{-| Produces a parser for a lower-case name that must equal `expectedName`, as
the name repeated after a type annotation must, returning it with the region
where it was read.

A missing name fails like `lower`, with `toRepeatError`. A different name fails
with `toMatchError` at the start of the name, marked consumed.

-}
matchingLower : (Row -> Col -> x) -> (Name -> Row -> Col -> x) -> Name -> P.Parser x (A.Located Name)
matchingLower toRepeatError toMatchError expectedName =
    P.addLocation (lower toRepeatError)
        |> P.andThen
            (\((A.At (A.Region (A.Position row col) _) name) as located) ->
                if name == expectedName then
                    P.pure located

                else
                    P.Parser (\_ -> P.Cerr row col (toMatchError name))
            )


-- ====== MODULE NAME ======


{-| Produces a parser for a module name: one or more upper-case identifiers
joined by dots, such as `Html` or `Json.Decode`, read as one `Name` that keeps
its dots.

It fails with `Eerr` at its starting position when no upper-case identifier
starts there. A dot that is not followed by an upper-case identifier, as in
`Json.decode` or `Json.` followed by a space, is a failure with `Cerr` at the
column just after the dot.

-}
moduleName : (Row -> Col -> x) -> P.Parser x Name
moduleName toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( pos1, col1 ) =
                    Identifier.chompUpper st.src st.pos st.end st.col
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


{-| How the scan of the dotted parts of a module name ended. `Good` means it
stopped where there is no dot, either at a character that is not a dot or at
the end of the input. `Bad` means it found a dot with no upper-case identifier
after it.
-}
type ModuleNameStatus
    = Good
    | Bad


{-| Returns how the scan of the rest of a module name ends, starting from `pos`
just after an upper-case identifier, with the position and column where it
stopped: the end of the name for `Good`, or just after the dot for `Bad`.
-}
moduleNameHelp : String -> Int -> Int -> Col -> ( ModuleNameStatus, Int, Col )
moduleNameHelp src pos end col =
    if isDot src pos end then
        let
            pos1 : Int
            pos1 =
                pos + 1

            ( newPos, newCol ) =
                Identifier.chompUpper src pos1 end (col + 1)
        in
        if pos1 == newPos then
            ( Bad, newPos, newCol )

        else
            moduleNameHelp src newPos end newCol

    else
        ( Good, pos, col )



-- ====== FOREIGN UPPER ======


{-| An upper-case name as written in source, with or without its home.

`Unqualified` carries the name alone. `Qualified` carries the home, without its
final dot, and then the name, so `Json.Decode.Decoder` is
`Qualified "Json.Decode" "Decoder"`.

-}
type Upper
    = Unqualified Name
    | Qualified Name Name


{-| Produces a parser for an upper-case name with or without its home, such as
`Just` or `Maybe.Just`.

A dot after an upper-case identifier is always read as part of the name, so
every part must be upper-case. Where a dot is not followed by an upper-case
identifier, as in `Maybe.withDefault`, the parser fails with `Eerr` at the
column just after that dot. It also fails with `Eerr` at its starting position
when no upper-case identifier starts there.

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


{-| Returns where the last part of a possibly qualified upper-case name starting
at `pos` begins and ends, and the column at its end; the home runs from `pos` to
the dot before that last part. When a part is missing, the begin and end are
equal, at the position where an upper-case identifier was expected.
-}
foreignUpperHelp : String -> Int -> Int -> Col -> ( Int, Int, Col )
foreignUpperHelp src pos end col =
    let
        ( newPos, newCol ) =
            Identifier.chompUpper src pos end col
    in
    if pos == newPos then
        ( pos, pos, col )

    else if isDot src newPos end then
        foreignUpperHelp src (newPos + 1) end (newCol + 1)

    else
        ( pos, newPos, newCol )



-- ====== FOREIGN ALPHA ======


{-| Produces a parser for a reference to a value or constructor, with or
without its home, read as an expression: `Src.Var` for `x` or `Just`, and
`Src.VarQual` with the home for `List.map` or `Maybe.Just`. The variable type is
`LowVar` when the last part is lower-case and `CapVar` when it is upper-case.

Upper-case parts followed by a dot are read as the home, and the first
lower-case part ends the name, so on `List.map.x` it reads `List.map`. Only an
unqualified name is checked against the reserved words, and one that is
reserved fails with `Eerr` at the starting position. When no part starts at the
position, or none follows a dot, the parser fails with `Eerr` at the column
where a part was expected.

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
                    if Identifier.isReservedWord name then
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


{-| Returns where the last part of a possibly qualified name starting at `pos`
begins and ends, the column at its end, and whether that part is lower-case or
upper-case. When a part is missing, the begin and end are equal, at the
position where a part was expected, and the variable type is `CapVar`.
-}
foreignAlphaHelp : String -> Int -> Int -> Col -> ( ( Int, Int ), ( Col, Src.VarType ) )
foreignAlphaHelp src pos end col =
    let
        ( lowerPos, lowerCol ) =
            Identifier.chompLower src pos end col
    in
    if pos < lowerPos then
        ( ( pos, lowerPos ), ( lowerCol, Src.LowVar ) )

    else
        let
            ( upperPos, upperCol ) =
                Identifier.chompUpper src pos end col
        in
        if pos == upperPos then
            ( ( pos, pos ), ( col, Src.CapVar ) )

        else if isDot src upperPos end then
            foreignAlphaHelp src (upperPos + 1) end (upperCol + 1)

        else
            ( ( pos, upperPos ), ( upperCol, Src.CapVar ) )



---- CHAR CHOMPERS ----
-- ====== DOTS ======


{-| Returns whether `pos` is before `end` and the character there is a dot.
-}
isDot : String -> Int -> Int -> Bool
isDot src pos end =
    pos < end && P.unsafeIndex src pos == '.'
