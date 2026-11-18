module StringCallbacks exposing (bench)

{-| `String.foldl`, `String.any`, `String.all`, `String.filter` and `String.map` with small
functions over 2,000 short words (3 to 12 characters, about one word in eleven with a non-ASCII
letter), `n` passes. Each call calls its function once per character, so the work is the
kernel's per-call setup and its call of the function, not the text.

Checked at every size against the same figures computed from the generator's `List Char`s,
without any `String` function.

-}


wordCount : Int
wordCount =
    2000


charAt : Int -> Int -> Char
charAt w j =
    if modBy 11 w == 0 && j == 1 then
        'é'

    else if modBy 7 (w + j) == 0 then
        Char.fromCode (48 + modBy 10 (w * 3 + j))

    else
        Char.fromCode (97 + modBy 26 (w * 7 + j * 13))


wordChars : List (List Char)
wordChars =
    List.map (\w -> List.map (charAt w) (List.range 0 (2 + modBy 10 w))) (List.range 0 (wordCount - 1))


isLetter : Char -> Bool
isLetter c =
    Char.isLower c || Char.toCode c > 127


{-| The figures of one pass: code-point sum, words with a digit, all-letter words, characters
other than 'a', and the code-point sum after 'e' becomes 'f'.
-}
type alias Figures =
    { codes : Int, withDigit : Int, allLetters : Int, notA : Int, mapped : Int }


zero : Figures
zero =
    { codes = 0, withDigit = 0, allLetters = 0, notA = 0, mapped = 0 }


swapE : Char -> Char
swapE c =
    if c == 'e' then
        'f'

    else
        c


countIf : Bool -> Int
countIf b =
    if b then
        1

    else
        0


pass : List String -> Figures
pass words =
    List.foldl
        (\s f ->
            { codes = f.codes + String.foldl (\c acc -> acc + Char.toCode c) 0 s
            , withDigit = f.withDigit + countIf (String.any Char.isDigit s)
            , allLetters = f.allLetters + countIf (String.all isLetter s)
            , notA = f.notA + String.length (String.filter (\c -> c /= 'a') s)
            , mapped = f.mapped + String.foldl (\c acc -> acc + Char.toCode c) 0 (String.map swapE s)
            }
        )
        zero
        words


expected : Figures
expected =
    List.foldl
        (\cs f ->
            { codes = f.codes + List.sum (List.map Char.toCode cs)
            , withDigit = f.withDigit + countIf (List.any Char.isDigit cs)
            , allLetters = f.allLetters + countIf (List.all isLetter cs)
            , notA = f.notA + List.length (List.filter (\c -> c /= 'a') cs)
            , mapped = f.mapped + List.sum (List.map (swapE >> Char.toCode) cs)
            }
        )
        zero
        wordChars


bench : Int -> Bool
bench n =
    let
        words =
            List.map String.fromList wordChars

        want =
            expected

        go : Int -> Bool -> Bool
        go left ok =
            if left <= 0 then
                ok

            else
                go (left - 1) (ok && pass words == want)
    in
    go n True
