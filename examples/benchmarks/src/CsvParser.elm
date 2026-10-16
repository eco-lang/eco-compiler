module CsvParser exposing (bench)

{-| CSV with `elm/parser`: the same `n` documents as `csv-split` (`CsvSplit.document`), parsed with
`Parser.loop` over rows, `chompWhile` and `getChompedString` for fields, and `Parser.int` and
`String.toFloat` for the numbers, for a direct parser-combinator against `String.split`
comparison.

Checked at every size: the row count, the amount sum and the price sum (in cents) must equal the
generator's, as for `csv-split`.

-}

import CsvSplit
import Parser exposing ((|.), (|=), Parser, Step(..))


field : Parser String
field =
    Parser.getChompedString (Parser.chompWhile (\c -> c /= ',' && c /= '\n'))


number : Parser Int
number =
    Parser.oneOf
        [ Parser.succeed negate |. Parser.symbol "-" |= Parser.int
        , Parser.int
        ]


cents : Parser Int
cents =
    field
        |> Parser.andThen
            (\text ->
                case String.toFloat text of
                    Just f ->
                        Parser.succeed (round (f * 100))

                    Nothing ->
                        Parser.problem ("bad price " ++ text)
            )


type alias Totals =
    { rows : Int, amount : Int, cents : Int }


row : Totals -> Parser (Step Totals Totals)
row t =
    Parser.oneOf
        [ Parser.succeed (\a c -> Loop (Totals (t.rows + 1) (t.amount + a) (t.cents + c)))
            |. Parser.int
            |. Parser.symbol ","
            |. field
            |. Parser.symbol ","
            |= number
            |. Parser.symbol ","
            |= cents
            |. Parser.symbol "\n"
        , Parser.succeed (Done t) |. Parser.end
        ]


csv : Parser Totals
csv =
    Parser.succeed identity
        |. Parser.chompUntil "\n"
        |. Parser.symbol "\n"
        |= Parser.loop (Totals 0 0 0) row


bench : Int -> Bool
bench n =
    List.all
        (\d ->
            let
                doc =
                    CsvSplit.document d
            in
            Parser.run csv doc.text == Ok (Totals doc.rows doc.amount doc.cents)
        )
        (List.range 1 n)
