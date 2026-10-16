module Lexer exposing (bench)

{-| A lexer for a small language with `elm/parser`, the Elm-specific part of parsing: keywords that
are prefixes of identifiers (`if` / `iffy`, `let` / `letter`, `in` / `inner`), operators that
are prefixes of other operators (`=` / `==` / `=>`, `-` / `->`, `<` / `<=`), integers, strings
with escapes and comments, tried with `oneOf` alternatives that need `backtrackable` and
`commit` (a keyword only counts when no identifier character follows it). `n` documents of 600
tokens each, every one under 128 Ki characters.

Checked at every size: the count of every token kind must equal the generator's, which knows
the kind of each token it writes.

-}

import Dict exposing (Dict)
import Parser exposing ((|.), (|=), Parser, Step(..))


type Kind
    = Keyword
    | Identifier
    | Operator
    | Number
    | Text


kindName : Kind -> String
kindName k =
    case k of
        Keyword ->
            "keyword"

        Identifier ->
            "identifier"

        Operator ->
            "operator"

        Number ->
            "number"

        Text ->
            "string"


keywords : List String
keywords =
    [ "if", "then", "else", "let", "in", "case", "of", "type" ]


identifiers : List String
identifiers =
    [ "iffy", "letter", "inner", "x", "y1", "caseload", "offset", "typed", "then_", "value", "els" ]


operators : List String
operators =
    [ "==", "=>", "=", "->", "-", "<=", "<", "+", "(", ")" ]


isIdentChar : Char -> Bool
isIdentChar c =
    Char.isAlphaNum c || c == '_'


keyword : Parser Kind
keyword =
    Parser.oneOf (List.map (\k -> Parser.backtrackable (Parser.keyword k)) keywords)
        |> Parser.map (\_ -> Keyword)


identifier : Parser Kind
identifier =
    Parser.succeed Identifier
        |. Parser.chompIf Char.isAlpha
        |. Parser.chompWhile isIdentChar


operator : Parser Kind
operator =
    Parser.oneOf (List.map Parser.symbol operators) |> Parser.map (\_ -> Operator)


number : Parser Kind
number =
    Parser.succeed Number
        |. Parser.chompIf Char.isDigit
        |. Parser.chompWhile Char.isDigit


text : Parser Kind
text =
    Parser.succeed Text
        |. Parser.symbol "\""
        |. Parser.loop ()
            (\_ ->
                Parser.oneOf
                    [ Parser.succeed (Done ()) |. Parser.symbol "\""
                    , Parser.succeed (Loop ()) |. Parser.symbol "\\" |. Parser.chompIf (\_ -> True)
                    , Parser.succeed (Loop ()) |. Parser.chompIf (\c -> c /= '"' && c /= '\\')
                    ]
            )


{-| Spaces, newlines and `--` comments between tokens.
-}
gap : Parser ()
gap =
    Parser.loop ()
        (\_ ->
            Parser.oneOf
                [ Parser.succeed (Loop ()) |. Parser.lineComment "--"
                , Parser.succeed (Loop ()) |. Parser.chompIf (\c -> c == ' ' || c == '\n')
                , Parser.succeed (Done ())
                ]
        )


token : Parser Kind
token =
    Parser.oneOf [ keyword, identifier, number, text, operator ]


tokens : Parser (Dict String Int)
tokens =
    Parser.succeed identity
        |. gap
        |= Parser.loop Dict.empty
            (\counts ->
                Parser.oneOf
                    [ Parser.succeed (\k -> Loop (Dict.update (kindName k) (\c -> Just (Maybe.withDefault 0 c + 1)) counts))
                        |= token
                        |. gap
                    , Parser.succeed (Done counts) |. Parser.end
                    ]
            )


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


pick : Int -> List String -> String
pick s list =
    Maybe.withDefault "" (List.head (List.drop (modBy (List.length list) s) list))


{-| Document `d`: its text and the generator's count of each kind.
-}
document : Int -> ( String, Dict String Int )
document d =
    let
        go i seed pieces counts =
            if i <= 0 then
                ( String.concat (List.reverse pieces), counts )

            else
                let
                    s1 =
                        next seed

                    s2 =
                        next s1

                    ( piece, kind ) =
                        case modBy 6 s1 of
                            0 ->
                                ( pick s2 keywords, Keyword )

                            1 ->
                                ( pick s2 identifiers, Identifier )

                            2 ->
                                ( pick s2 operators, Operator )

                            3 ->
                                ( String.fromInt (modBy 100000 s2), Number )

                            4 ->
                                ( "\"say \\\"" ++ pick s2 identifiers ++ "\\\" now\"", Text )

                            _ ->
                                ( pick s2 identifiers, Identifier )

                    separator =
                        case modBy 9 s2 of
                            0 ->
                                " -- a comment\n"

                            1 ->
                                "\n"

                            _ ->
                                " "

                    counts2 =
                        Dict.update (kindName kind) (\c -> Just (Maybe.withDefault 0 c + 1)) counts
                in
                go (i - 1) s2 (separator :: piece :: pieces) counts2
    in
    go 600 (d * 7919 + 1) [] Dict.empty


bench : Int -> Bool
bench n =
    List.all
        (\d ->
            let
                ( source, expected ) =
                    document d
            in
            Parser.run tokens source == Ok expected
        )
        (List.range 1 n)
