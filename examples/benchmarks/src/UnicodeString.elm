module UnicodeString exposing (bench)

{-| String operations on text that is not all ASCII: `n` words generated from code points, mixing
ASCII letters, letters outside ASCII (é, ж) and CJK characters. On the text: `String.length`,
`String.slice`, `String.indexes`, `String.toUpper`, `String.reverse` and `String.foldl`. eco
stores ASCII strings as UTF-8 and widens to UTF-16 when it must, so this measures that against
plain ASCII work.

Only characters of the Basic Multilingual Plane are used: on eco's native backend a `Char` is
one UTF-16 code unit, so `Char.fromCode 0x1F600` gives U+FFFF and `String.toList` splits an
emoji into its two surrogates, where Elm gives one character
(`plans/benchmark-suite-expansion.md`, Status).

Checked at every size against the generated code points: the length in UTF-16 units, the sum of
the code points (via `foldl`), the position of every occurrence of the marker word, the ASCII
letters after `toUpper`, a slice's length and code points, and reversing twice giving the text
back. Only the ASCII part of `toUpper` is checked: eco's native `String.toUpper` maps ASCII
letters only (`Char.toUpper` in `elm-kernel-cpp` has a TODO for full Unicode), so é stays é where
Elm gives É.

-}


next : Int -> Int
next seed =
    modBy 2147483647 (seed * 16807)


{-| Code points to draw from: ASCII lower case, é è à, ж и л, 中 文 字.
-}
pool : List Int
pool =
    List.range 0x61 0x7A ++ [ 0xE9, 0xE8, 0xE0, 0x0436, 0x0438, 0x043B, 0x4E2D, 0x6587, 0x5B57 ]


poolSize : Int
poolSize =
    List.length pool


pick : Int -> Int
pick k =
    Maybe.withDefault 0x61 (List.head (List.drop k pool))


{-| The marker word placed every tenth word; its letters never occur elsewhere.
-}
marker : String
marker =
    "QED"


{-| The code points of `n` words: nine random words of 3 to 8 code points for every marker,
separated by spaces.
-}
codePoints : Int -> List Int
codePoints n =
    let
        go i seed acc =
            if i >= n then
                List.reverse acc

            else
                let
                    s1 =
                        next seed

                    wordLength =
                        3 + modBy 6 s1

                    letters s k ws =
                        if k <= 0 then
                            ( ws, s )

                        else
                            let
                                s2 =
                                    next s
                            in
                            letters s2 (k - 1) (pick (modBy poolSize s2) :: ws)

                    ( wordPoints, s3 ) =
                        if modBy 10 i == 9 then
                            ( List.reverse (List.map Char.toCode (String.toList marker)), s1 )

                        else
                            letters s1 wordLength []

                    separator =
                        if i == 0 then
                            []

                        else
                            [ 0x20 ]
                in
                go (i + 1) s3 (wordPoints ++ separator ++ acc)
    in
    go 0 1 []


utf16Length : Int -> Int
utf16Length cp =
    if cp > 0xFFFF then
        2

    else
        1


{-| The ASCII part of a code point after upper-casing, 0 for anything else.
-}
asciiUpper : Int -> Int
asciiUpper cp =
    if cp >= 0x61 && cp <= 0x7A then
        cp - 32

    else if cp < 0x80 then
        cp

    else
        0


asciiSum : String -> Int
asciiSum s =
    String.foldl
        (\c acc ->
            if Char.toCode c < 0x80 then
                acc + Char.toCode c

            else
                acc
        )
        0
        s


codeSum : String -> Int
codeSum s =
    String.foldl (\c acc -> acc + Char.toCode c) 0 s


bench : Int -> Bool
bench n =
    let
        points =
            codePoints n

        text =
            String.fromList (List.map Char.fromCode points)

        length =
            List.sum (List.map utf16Length points)

        markerPositions =
            List.foldl
                (\cp ( pos, acc ) ->
                    ( pos + utf16Length cp
                    , if cp == Char.toCode 'Q' then
                        pos :: acc

                      else
                        acc
                    )
                )
                ( 0, [] )
                points
                |> Tuple.second
                |> List.reverse

        half =
            length // 2

        sliced =
            String.slice 0 half text
    in
    String.length text
        == length
        && codeSum text
        == List.sum points
        && String.indexes marker text
        == markerPositions
        && asciiSum (String.toUpper text)
        == List.sum (List.map asciiUpper points)
        && String.length (String.toUpper text)
        == length
        && String.reverse (String.reverse text)
        == text
        && String.length sliced
        == half
        && codeSum sliced
        == List.sum (List.take half points)
