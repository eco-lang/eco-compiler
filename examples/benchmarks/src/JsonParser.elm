module JsonParser exposing (bench)

{-| A JSON parser written with `elm/parser`, run on the same documents as `json` (`n` coordinate
objects, from `JsonCoords.document`): objects, arrays, strings with escapes, numbers, `true`,
`false` and `null` into a JSON value type, then the coordinates' averages. The parser-combinator
side of the comparison with `Json.Decode`: `oneOf`, `loop`, `chompWhile`, `getChompedString`,
`lazy` and `andThen` over a long input.

Checked at every size: the averages must equal, exactly, those `Json.Decode` gets from the same
text (the numbers are read the same way, by `String.toFloat` of the same digits).

-}

import Dict exposing (Dict)
import Json.Decode
import JsonCoords exposing (Coordinate)
import Parser exposing ((|.), (|=), Parser, Step(..))


type Value
    = JObject (Dict String Value)
    | JArray (List Value)
    | JString String
    | JNumber Float
    | JBool Bool
    | JNull


value : Parser Value
value =
    Parser.oneOf
        [ Parser.map JObject object
        , Parser.map JArray array
        , Parser.map JString string
        , Parser.map JNumber number
        , Parser.map (\_ -> JBool True) (Parser.keyword "true")
        , Parser.map (\_ -> JBool False) (Parser.keyword "false")
        , Parser.map (\_ -> JNull) (Parser.keyword "null")
        ]
        |. Parser.spaces


object : Parser (Dict String Value)
object =
    Parser.succeed identity
        |. Parser.symbol "{"
        |. Parser.spaces
        |= Parser.oneOf
            [ Parser.succeed Dict.empty |. Parser.symbol "}"
            , Parser.loop Dict.empty members
            ]


members : Dict String Value -> Parser (Step (Dict String Value) (Dict String Value))
members acc =
    Parser.succeed (\key v more -> more (Dict.insert key v acc))
        |= string
        |. Parser.spaces
        |. Parser.symbol ":"
        |. Parser.spaces
        |= Parser.lazy (\_ -> value)
        |= Parser.oneOf
            [ Parser.succeed Loop |. Parser.symbol "," |. Parser.spaces
            , Parser.succeed Done |. Parser.symbol "}"
            ]


array : Parser (List Value)
array =
    Parser.succeed identity
        |. Parser.symbol "["
        |. Parser.spaces
        |= Parser.oneOf
            [ Parser.succeed [] |. Parser.symbol "]"
            , Parser.loop [] elements
            ]


elements : List Value -> Parser (Step (List Value) (List Value))
elements acc =
    Parser.succeed (\v more -> more (v :: acc))
        |= Parser.lazy (\_ -> value)
        |= Parser.oneOf
            [ Parser.succeed Loop |. Parser.symbol "," |. Parser.spaces
            , Parser.succeed (Done << List.reverse) |. Parser.symbol "]"
            ]


string : Parser String
string =
    Parser.succeed identity
        |. Parser.symbol "\""
        |= Parser.loop [] stringPieces


stringPieces : List String -> Parser (Step (List String) String)
stringPieces acc =
    Parser.oneOf
        [ Parser.succeed (Done (String.concat (List.reverse acc))) |. Parser.symbol "\""
        , Parser.succeed (\piece -> Loop (piece :: acc))
            |. Parser.symbol "\\"
            |= escape
        , Parser.succeed (\piece -> Loop (piece :: acc))
            |= Parser.getChompedString (Parser.chompIf (\c -> c /= '"' && c /= '\\') |. Parser.chompWhile (\c -> c /= '"' && c /= '\\'))
        ]


escape : Parser String
escape =
    Parser.oneOf
        [ Parser.map (\_ -> "\"") (Parser.symbol "\"")
        , Parser.map (\_ -> "\\") (Parser.symbol "\\")
        , Parser.map (\_ -> "/") (Parser.symbol "/")
        , Parser.map (\_ -> "\u{0008}") (Parser.symbol "b")
        , Parser.map (\_ -> "\u{000C}") (Parser.symbol "f")
        , Parser.map (\_ -> "\n") (Parser.symbol "n")
        , Parser.map (\_ -> "\u{000D}") (Parser.symbol "r")
        , Parser.map (\_ -> "\t") (Parser.symbol "t")
        , Parser.succeed identity
            |. Parser.symbol "u"
            |= (Parser.getChompedString (Parser.chompIf Char.isHexDigit |. Parser.chompIf Char.isHexDigit |. Parser.chompIf Char.isHexDigit |. Parser.chompIf Char.isHexDigit)
                    |> Parser.map (\hex -> String.fromChar (Char.fromCode (hexValue hex)))
               )
        ]


hexValue : String -> Int
hexValue hex =
    String.foldl
        (\c acc ->
            let
                code =
                    Char.toCode (Char.toLower c)

                digit =
                    if code >= 0x61 then
                        code - 0x61 + 10

                    else
                        code - 0x30
            in
            acc * 16 + digit
        )
        0
        hex


number : Parser Float
number =
    Parser.getChompedString
        (Parser.succeed ()
            |. Parser.oneOf [ Parser.chompIf (\c -> c == '-'), Parser.succeed () ]
            |. Parser.chompIf Char.isDigit
            |. Parser.chompWhile (\c -> Char.isDigit c || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-')
        )
        |> Parser.andThen
            (\text ->
                case String.toFloat text of
                    Just f ->
                        Parser.succeed f

                    Nothing ->
                        Parser.problem ("bad number " ++ text)
            )


document : Parser Value
document =
    Parser.succeed identity
        |. Parser.spaces
        |= value
        |. Parser.end


coordinates : Value -> Maybe (List Coordinate)
coordinates v =
    let
        field name fields =
            case Dict.get name fields of
                Just (JNumber f) ->
                    Just f

                _ ->
                    Nothing

        coordinate item =
            case item of
                JObject fields ->
                    Maybe.map3 Coordinate (field "x" fields) (field "y" fields) (field "z" fields)

                _ ->
                    Nothing
    in
    case v of
        JObject top ->
            case Dict.get "coordinates" top of
                Just (JArray items) ->
                    List.foldr (\item acc -> Maybe.map2 (::) (coordinate item) acc) (Just []) items

                _ ->
                    Nothing

        _ ->
            Nothing


bench : Int -> Bool
bench n =
    let
        text =
            JsonCoords.document n

        parsed =
            Parser.run document text
                |> Result.toMaybe
                |> Maybe.andThen coordinates
                |> Maybe.map JsonCoords.averages

        decoded =
            Result.toMaybe (Result.map JsonCoords.averages (Json.Decode.decodeString JsonCoords.decoder text))
    in
    parsed /= Nothing && parsed == decoded
