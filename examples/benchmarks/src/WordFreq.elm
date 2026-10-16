module WordFreq exposing (bench)

{-| Word frequencies: generate `n` words of text from a fixed vocabulary (skewed, so that a few
words are common), split it with `String.words`, count each word with `Dict.update` in a
`Dict String Int`, and take the ten most frequent. String keys, splitting, `Dict` updates and a
sort.

Checked at every size against the generator: the counts must add up to `n`, every word's count
must equal the number of times the generator chose it (counted into an `Array` by vocabulary
index, with no `Dict` and no text), and the top ten must be the top ten of those counts.

-}

import Array exposing (Array)
import Dict exposing (Dict)


syllables : Array String
syllables =
    Array.fromList [ "ka", "lo", "mi", "ne", "su", "ta", "ri", "vo", "pe", "du", "xa", "zo" ]


{-| Vocabulary word `i`, for `i` in `0 .. 499`: three syllables picked from its digits.
-}
word : Int -> String
word i =
    let
        syllable k =
            Maybe.withDefault "" (Array.get (modBy 12 k) syllables)
    in
    syllable i ++ syllable (i // 12) ++ syllable (i // 144 + i)


vocabularySize : Int
vocabularySize =
    500


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| The vocabulary index of the word drawn from `seed`: the smaller of two draws, so low indices
are more common.
-}
pick : Int -> Int
pick seed =
    min (modBy vocabularySize seed) (modBy vocabularySize (seed // vocabularySize))


{-| The indices of the `n` words, in order.
-}
indices : Int -> List Int
indices n =
    let
        go i seed acc =
            if i <= 0 then
                List.reverse acc

            else
                let
                    s =
                        next seed
                in
                go (i - 1) s (pick s :: acc)
    in
    go n 1 []


text : Int -> String
text n =
    String.join " " (List.map word (indices n))


increment : Maybe Int -> Maybe Int
increment count =
    Just (Maybe.withDefault 0 count + 1)


byCount : ( String, Int ) -> ( String, Int ) -> Order
byCount ( wa, ca ) ( wb, cb ) =
    case compare cb ca of
        EQ ->
            compare wa wb

        order ->
            order


bench : Int -> Bool
bench n =
    let
        counts =
            List.foldl (\w d -> Dict.update w increment d) Dict.empty (String.words (text n))

        top =
            List.take 10 (List.sortWith byCount (Dict.toList counts))

        expected =
            List.foldl (\i a -> Array.set i (Maybe.withDefault 0 (Array.get i a) + 1) a) (Array.repeat vocabularySize 0) (indices n)

        expectedCounts =
            Array.toIndexedList expected
                |> List.filter (\( _, c ) -> c > 0)
                |> List.map (\( i, c ) -> ( word i, c ))

        expectedTop =
            List.take 10 (List.sortWith byCount expectedCounts)
    in
    Dict.foldl (\_ c s -> s + c) 0 counts
        == n
        && List.all (\( w, c ) -> Dict.get w counts == Just c) expectedCounts
        && Dict.size counts
        == List.length expectedCounts
        && top
        == expectedTop
