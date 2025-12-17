module Compiler.Parse.Keyword exposing
    ( type_, alias_, port_
    , if_, then_, else_, case_, of_, let_, in_
    , module_, import_, exposing_, as_
    , infix_, left_, right_, non_
    , effect_, where_, command_, subscription_
    , k4, k5
    )

{-| Parser for Elm language keywords.

This module provides parsers for all reserved keywords in Elm. Each parser
ensures that the keyword is not followed by identifier characters (to avoid
matching prefixes like "types" when looking for "type").


# Declaration Keywords

@docs type_, alias_, port_


# Expression Keywords

@docs if_, then_, else_, case_, of_, let_, in_


# Import Keywords

@docs module_, import_, exposing_, as_


# Infix Keywords

@docs infix_, left_, right_, non_


# Effect Keywords

@docs effect_, where_, command_, subscription_


# Keyword Helpers

@docs k4, k5

-}

import Compiler.Parse.Primitives as P exposing (Col, Parser, Row)
import Compiler.Parse.Variable as Var



-- DECLARATIONS


{-| Parses the 'type' keyword for type declarations.
-}
type_ : (Row -> Col -> x) -> Parser x ()
type_ tx =
    k4 't' 'y' 'p' 'e' tx


{-| Parses the 'alias' keyword for type alias declarations.
-}
alias_ : (Row -> Col -> x) -> Parser x ()
alias_ tx =
    k5 'a' 'l' 'i' 'a' 's' tx


{-| Parses the 'port' keyword for port declarations.
-}
port_ : (Row -> Col -> x) -> Parser x ()
port_ tx =
    k4 'p' 'o' 'r' 't' tx



-- IF EXPRESSIONS


{-| Parses the 'if' keyword for conditional expressions.
-}
if_ : (Row -> Col -> x) -> Parser x ()
if_ tx =
    k2 'i' 'f' tx


{-| Parses the 'then' keyword for conditional expressions.
-}
then_ : (Row -> Col -> x) -> Parser x ()
then_ tx =
    k4 't' 'h' 'e' 'n' tx


{-| Parses the 'else' keyword for conditional expressions.
-}
else_ : (Row -> Col -> x) -> Parser x ()
else_ tx =
    k4 'e' 'l' 's' 'e' tx



-- CASE EXPRESSIONS


{-| Parses the 'case' keyword for pattern matching expressions.
-}
case_ : (Row -> Col -> x) -> Parser x ()
case_ tx =
    k4 'c' 'a' 's' 'e' tx


{-| Parses the 'of' keyword for pattern matching expressions.
-}
of_ : (Row -> Col -> x) -> Parser x ()
of_ tx =
    k2 'o' 'f' tx



-- LET EXPRESSIONS


{-| Parses the 'let' keyword for let expressions.
-}
let_ : (Row -> Col -> x) -> Parser x ()
let_ tx =
    k3 'l' 'e' 't' tx


{-| Parses the 'in' keyword for let expressions.
-}
in_ : (Row -> Col -> x) -> Parser x ()
in_ tx =
    k2 'i' 'n' tx



-- INFIXES


{-| Parses the 'infix' keyword for infix operator declarations.
-}
infix_ : (Row -> Col -> x) -> Parser x ()
infix_ tx =
    k5 'i' 'n' 'f' 'i' 'x' tx


{-| Parses the 'left' keyword for left-associative operators.
-}
left_ : (Row -> Col -> x) -> Parser x ()
left_ tx =
    k4 'l' 'e' 'f' 't' tx


{-| Parses the 'right' keyword for right-associative operators.
-}
right_ : (Row -> Col -> x) -> Parser x ()
right_ tx =
    k5 'r' 'i' 'g' 'h' 't' tx


{-| Parses the 'non' keyword for non-associative operators.
-}
non_ : (Row -> Col -> x) -> Parser x ()
non_ tx =
    k3 'n' 'o' 'n' tx



-- IMPORTS


{-| Parses the 'module' keyword for module declarations.
-}
module_ : (Row -> Col -> x) -> Parser x ()
module_ tx =
    k6 'm' 'o' 'd' 'u' 'l' 'e' tx


{-| Parses the 'import' keyword for import declarations.
-}
import_ : (Row -> Col -> x) -> Parser x ()
import_ tx =
    k6 'i' 'm' 'p' 'o' 'r' 't' tx


{-| Parses the 'exposing' keyword for exposing lists in module and import declarations.
-}
exposing_ : (Row -> Col -> x) -> Parser x ()
exposing_ tx =
    k8 'e' 'x' 'p' 'o' 's' 'i' 'n' 'g' tx


{-| Parses the 'as' keyword for module aliasing in import declarations.
-}
as_ : (Row -> Col -> x) -> Parser x ()
as_ tx =
    k2 'a' 's' tx



-- EFFECTS


{-| Parses the 'effect' keyword for effect module declarations.
-}
effect_ : (Row -> Col -> x) -> Parser x ()
effect_ tx =
    k6 'e' 'f' 'f' 'e' 'c' 't' tx


{-| Parses the 'where' keyword for effect module declarations.
-}
where_ : (Row -> Col -> x) -> Parser x ()
where_ tx =
    k5 'w' 'h' 'e' 'r' 'e' tx


{-| Parses the 'command' keyword for effect module declarations.
-}
command_ : (Row -> Col -> x) -> Parser x ()
command_ tx =
    k7 'c' 'o' 'm' 'm' 'a' 'n' 'd' tx


{-| Parses the 'subscription' keyword for effect module declarations.
-}
subscription_ : (Row -> Col -> x) -> Parser x ()
subscription_ toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos12 : Int
                pos12 =
                    st.pos + 12
            in
            if
                (pos12 <= st.end)
                    && (P.unsafeIndex st.src st.pos == 's')
                    && (P.unsafeIndex st.src (st.pos + 1) == 'u')
                    && (P.unsafeIndex st.src (st.pos + 2) == 'b')
                    && (P.unsafeIndex st.src (st.pos + 3) == 's')
                    && (P.unsafeIndex st.src (st.pos + 4) == 'c')
                    && (P.unsafeIndex st.src (st.pos + 5) == 'r')
                    && (P.unsafeIndex st.src (st.pos + 6) == 'i')
                    && (P.unsafeIndex st.src (st.pos + 7) == 'p')
                    && (P.unsafeIndex st.src (st.pos + 8) == 't')
                    && (P.unsafeIndex st.src (st.pos + 9) == 'i')
                    && (P.unsafeIndex st.src (st.pos + 10) == 'o')
                    && (P.unsafeIndex st.src (st.pos + 11) == 'n')
                    && (Var.getInnerWidth st.src pos12 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos12, col = st.col + 12 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError



-- KEYWORDS


{-| Helper for parsing a 2-character keyword. Ensures the keyword is not followed by identifier characters.
-}
k2 : Char -> Char -> (Row -> Col -> x) -> Parser x ()
k2 w1 w2 toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos2 : Int
                pos2 =
                    st.pos + 2
            in
            if
                (pos2 <= st.end)
                    && (P.unsafeIndex st.src st.pos == w1)
                    && (P.unsafeIndex st.src (st.pos + 1) == w2)
                    && (Var.getInnerWidth st.src pos2 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos2, col = st.col + 2 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError


k3 : Char -> Char -> Char -> (Row -> Col -> x) -> Parser x ()
k3 w1 w2 w3 toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos3 : Int
                pos3 =
                    st.pos + 3
            in
            if
                (pos3 <= st.end)
                    && (P.unsafeIndex st.src st.pos == w1)
                    && (P.unsafeIndex st.src (st.pos + 1) == w2)
                    && (P.unsafeIndex st.src (st.pos + 2) == w3)
                    && (Var.getInnerWidth st.src pos3 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos3, col = st.col + 3 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError


{-| Helper for parsing a 4-character keyword. Ensures the keyword is not followed by identifier characters.
-}
k4 : Char -> Char -> Char -> Char -> (Row -> Col -> x) -> Parser x ()
k4 w1 w2 w3 w4 toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos4 : Int
                pos4 =
                    st.pos + 4
            in
            if
                (pos4 <= st.end)
                    && (P.unsafeIndex st.src st.pos == w1)
                    && (P.unsafeIndex st.src (st.pos + 1) == w2)
                    && (P.unsafeIndex st.src (st.pos + 2) == w3)
                    && (P.unsafeIndex st.src (st.pos + 3) == w4)
                    && (Var.getInnerWidth st.src pos4 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos4, col = st.col + 4 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError


{-| Helper for parsing a 5-character keyword. Ensures the keyword is not followed by identifier characters.
-}
k5 : Char -> Char -> Char -> Char -> Char -> (Row -> Col -> x) -> Parser x ()
k5 w1 w2 w3 w4 w5 toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos5 : Int
                pos5 =
                    st.pos + 5
            in
            if
                (pos5 <= st.end)
                    && (P.unsafeIndex st.src st.pos == w1)
                    && (P.unsafeIndex st.src (st.pos + 1) == w2)
                    && (P.unsafeIndex st.src (st.pos + 2) == w3)
                    && (P.unsafeIndex st.src (st.pos + 3) == w4)
                    && (P.unsafeIndex st.src (st.pos + 4) == w5)
                    && (Var.getInnerWidth st.src pos5 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos5, col = st.col + 5 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError


k6 : Char -> Char -> Char -> Char -> Char -> Char -> (Row -> Col -> x) -> Parser x ()
k6 w1 w2 w3 w4 w5 w6 toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos6 : Int
                pos6 =
                    st.pos + 6
            in
            if
                (pos6 <= st.end)
                    && (P.unsafeIndex st.src st.pos == w1)
                    && (P.unsafeIndex st.src (st.pos + 1) == w2)
                    && (P.unsafeIndex st.src (st.pos + 2) == w3)
                    && (P.unsafeIndex st.src (st.pos + 3) == w4)
                    && (P.unsafeIndex st.src (st.pos + 4) == w5)
                    && (P.unsafeIndex st.src (st.pos + 5) == w6)
                    && (Var.getInnerWidth st.src pos6 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos6, col = st.col + 6 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError


k7 : Char -> Char -> Char -> Char -> Char -> Char -> Char -> (Row -> Col -> x) -> Parser x ()
k7 w1 w2 w3 w4 w5 w6 w7 toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos7 : Int
                pos7 =
                    st.pos + 7
            in
            if
                (pos7 <= st.end)
                    && (P.unsafeIndex st.src st.pos == w1)
                    && (P.unsafeIndex st.src (st.pos + 1) == w2)
                    && (P.unsafeIndex st.src (st.pos + 2) == w3)
                    && (P.unsafeIndex st.src (st.pos + 3) == w4)
                    && (P.unsafeIndex st.src (st.pos + 4) == w5)
                    && (P.unsafeIndex st.src (st.pos + 5) == w6)
                    && (P.unsafeIndex st.src (st.pos + 6) == w7)
                    && (Var.getInnerWidth st.src pos7 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos7, col = st.col + 7 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError


k8 : Char -> Char -> Char -> Char -> Char -> Char -> Char -> Char -> (Row -> Col -> x) -> Parser x ()
k8 w1 w2 w3 w4 w5 w6 w7 w8 toError =
    P.Parser <|
        \(P.State st) ->
            let
                pos8 : Int
                pos8 =
                    st.pos + 8
            in
            if
                (pos8 <= st.end)
                    && (P.unsafeIndex st.src st.pos == w1)
                    && (P.unsafeIndex st.src (st.pos + 1) == w2)
                    && (P.unsafeIndex st.src (st.pos + 2) == w3)
                    && (P.unsafeIndex st.src (st.pos + 3) == w4)
                    && (P.unsafeIndex st.src (st.pos + 4) == w5)
                    && (P.unsafeIndex st.src (st.pos + 5) == w6)
                    && (P.unsafeIndex st.src (st.pos + 6) == w7)
                    && (P.unsafeIndex st.src (st.pos + 7) == w8)
                    && (Var.getInnerWidth st.src pos8 st.end == 0)
            then
                let
                    s : P.State
                    s =
                        P.State { st | pos = pos8, col = st.col + 8 }
                in
                P.Cok () s

            else
                P.Eerr st.row st.col toError
