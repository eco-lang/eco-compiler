module Levenshtein exposing (bench)

{-| Levenshtein edit distance by dynamic programming, one row at a time, over `n` pairs of
generated strings of about 300 characters: `String.toList`, and the per-cell minimum of three
neighbours carried along `List`s. Most pairs are a random string and a copy with generated edits;
every fourth pair is one of three structured kinds whose distance is known exactly.

Checked at every size: the structured pairs must give their exact distance (a string against
itself 0, against its first `k` characters `length - k`, against a string over a disjoint
alphabet the larger length), and every edited pair must lie between the length difference and
the number of edits made. At the sizes in `known` the sum of all `n` distances must also match
a Python implementation of the same recurrence.

-}


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| `length` random characters from `alphabet`, and the seed after them.
-}
randomString : String -> Int -> Int -> ( List Char, Int )
randomString alphabet length seed =
    let
        size =
            String.length alphabet

        go k s acc =
            if k <= 0 then
                ( acc, s )

            else
                let
                    s2 =
                        next s

                    c =
                        String.slice (modBy size s2) (modBy size s2 + 1) alphabet
                in
                go (k - 1) s2 (String.toList c ++ acc)
    in
    go length seed []


{-| Apply `count` random edits (substitute, insert or delete one character) to `chars`.
-}
edit : Int -> Int -> List Char -> ( List Char, Int )
edit count seed chars =
    if count <= 0 then
        ( chars, seed )

    else
        let
            s1 =
                next seed

            s2 =
                next s1

            at =
                modBy (List.length chars + 1) s1

            before =
                List.take at chars

            after =
                List.drop at chars

            letter =
                Maybe.withDefault 'a' (List.head (String.toList (String.slice (modBy 4 s2) (modBy 4 s2 + 1) "acgt")))

            edited =
                case modBy 3 s2 of
                    0 ->
                        before ++ letter :: List.drop 1 after

                    1 ->
                        before ++ letter :: after

                    _ ->
                        before ++ List.drop 1 after
        in
        edit (count - 1) s2 edited


distance : List Char -> List Char -> Int
distance a b =
    let
        firstRow =
            List.range 0 (List.length b)

        step ca ( i, previous ) =
            let
                go bs prev left diagonal acc =
                    case ( bs, prev ) of
                        ( cb :: restB, up :: restPrev ) ->
                            let
                                cost =
                                    if ca == cb then
                                        0

                                    else
                                        1

                                cell =
                                    min (min (up + 1) (left + 1)) (diagonal + cost)
                            in
                            go restB restPrev cell up (cell :: acc)

                        _ ->
                            List.reverse acc
            in
            case previous of
                first :: rest ->
                    ( i + 1, go b rest (i + 1) first [ i + 1 ] )

                [] ->
                    ( i + 1, previous )
    in
    Tuple.second (List.foldl step ( 0, firstRow ) a)
        |> List.reverse
        |> List.head
        |> Maybe.withDefault (List.length b)


type Pair
    = Edited (List Char) (List Char) Int
    | Known (List Char) (List Char) Int


pair : Int -> Pair
pair k =
    let
        ( base, s1 ) =
            randomString "acgt" (250 + modBy 100 (k * 7919)) (k * 104729 + 1)

        length =
            List.length base
    in
    case modBy 12 k of
        0 ->
            Known base base 0

        4 ->
            let
                keep =
                    modBy (length + 1) s1
            in
            Known base (List.take keep base) (length - keep)

        8 ->
            let
                ( other, _ ) =
                    randomString "XYZ" (200 + modBy 120 s1) s1
            in
            Known base other (max length (List.length other))

        _ ->
            let
                edits =
                    1 + modBy 40 s1

                ( changed, _ ) =
                    edit edits s1 base
            in
            Edited base changed edits


{-| `( n, sum of the n distances )`, from a Python implementation of the recurrence.
-}
known : List ( Int, Int )
known =
    [ ( 10, 659 ), ( 50, 2156 ), ( 70, 3382 ) ]


bench : Int -> Bool
bench n =
    let
        results =
            List.map
                (\k ->
                    case pair k of
                        Known a b expected ->
                            let
                                d =
                                    distance a b
                            in
                            ( d, d == expected )

                        Edited a b edits ->
                            let
                                d =
                                    distance a b
                            in
                            ( d, d >= abs (List.length a - List.length b) && d <= edits )
                )
                (List.range 1 n)

        total =
            List.foldl (\( d, _ ) s -> s + d) 0 results

        matchesKnown =
            case List.filter (\( size, _ ) -> size == n) known of
                ( _, expected ) :: _ ->
                    total == expected

                [] ->
                    True
    in
    List.all Tuple.second results && matchesKnown
