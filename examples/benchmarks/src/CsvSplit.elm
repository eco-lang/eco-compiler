module CsvSplit exposing (Document, bench, document)

{-| CSV by splitting: `n` generated CSV documents of 400 rows each (an id, a name, an integer
amount and a decimal price per row), split with `String.lines` and `String.split ","`, the
numbers read with `String.toInt` and `String.toFloat`, and the columns summed. Each document is
under 128 Ki characters (see `ExprParser` for why that matters to `csv-parser`, which parses the
same documents).

Checked at every size: the row count, the amount sum and the price sum must equal the sums
taken straight from the generator (the prices are whole cents, summed as integer cents).

-}


type alias Document =
    { text : String
    , rows : Int
    , amount : Int
    , cents : Int
    }


rowsPerDocument : Int
rowsPerDocument =
    400


{-| Document `d`: its text, and the sums the generator knows.
-}
document : Int -> Document
document d =
    let
        row i =
            let
                k =
                    d * rowsPerDocument + i

                amount =
                    modBy 100000 (k * 7919) - 50000

                cents =
                    modBy 1000000 (k * 104729)
            in
            ( String.fromInt k
                ++ ",item "
                ++ String.fromInt (modBy 997 k)
                ++ ","
                ++ String.fromInt amount
                ++ ","
                ++ String.fromInt (cents // 100)
                ++ "."
                ++ String.padLeft 2 '0' (String.fromInt (modBy 100 cents))
            , amount
            , cents
            )

        rows =
            List.map row (List.range 0 (rowsPerDocument - 1))
    in
    { text = "id,name,amount,price\n" ++ String.join "\n" (List.map (\( t, _, _ ) -> t) rows) ++ "\n"
    , rows = rowsPerDocument
    , amount = List.sum (List.map (\( _, a, _ ) -> a) rows)
    , cents = List.sum (List.map (\( _, _, c ) -> c) rows)
    }


{-| Rows, amount sum and price sum in cents, read by splitting.
-}
sums : String -> ( Int, Int, Int )
sums text =
    String.lines text
        |> List.drop 1
        |> List.filter (not << String.isEmpty)
        |> List.foldl
            (\line ( rows, amount, cents ) ->
                case String.split "," line of
                    [ _, _, a, p ] ->
                        ( rows + 1
                        , amount + Maybe.withDefault 0 (String.toInt a)
                        , cents + round (Maybe.withDefault 0 (String.toFloat p) * 100)
                        )

                    _ ->
                        ( rows, amount, cents )
            )
            ( 0, 0, 0 )


bench : Int -> Bool
bench n =
    List.all
        (\d ->
            let
                doc =
                    document d
            in
            sums doc.text == ( doc.rows, doc.amount, doc.cents )
        )
        (List.range 1 n)
