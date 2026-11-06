module StringZeroLenSliceTest exposing (main)

{-| `String.slice`, `left`, `right`, `dropLeft` and `dropRight` return a true
empty string when asked for an empty range, for short and long, ASCII and
non-ASCII inputs.

`emptyCuts` asks for an empty range seven ways, and each result is passed to
`probe`, which checks `String.length`, `String.isEmpty`, `== ""` and a `case`
on the `""` pattern. An empty result must answer all four as empty, `"0EQC"`.

The inputs, whose lengths `sizes` logs, are `"abc"` (3), `"éü"` (2), a
9600-character ASCII string, the same with a leading `é` (9601), a
9000-character slice of that one, and a 160000-character string made by
appending two halves. `uncons_rest` checks the rest left by `String.uncons` on
three one-character strings.

After that, the program builds a large comma-joined string of 100,001 numbers
and probes every case result again; `after_gc_bad` is the number that no longer
reads as `"0EQC"`, and must be 0.

-}

-- CHECK: slice_ascii: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: slice_utf16: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: slice_big_ascii: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: slice_big_utf16: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: slice_of_slice: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: slice_rope: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: uncons_rest: ["0EQC","0EQC","0EQC"]
-- CHECK: sizes: [3,2,9600,9601,9000,160000]
-- CHECK: after_gc_bad: 0

import Html exposing (text)


{-| Returns a four-character summary of `s`: its length, then `E` if
`String.isEmpty s` holds (else `e`), `Q` if `s == ""` (else `q`), and `C` if a
`case` on `s` matches the `""` pattern (else `c`). A correct empty string gives
`"0EQC"`.
-}
probe : String -> String
probe s =
    String.fromInt (String.length s)
        ++ (if String.isEmpty s then "E" else "e")
        ++ (if s == "" then "Q" else "q")
        ++ (case s of
                "" ->
                    "C"

                _ ->
                    "c"
           )


{-| Returns seven empty ranges of `s`: two `String.slice` calls with equal
indices, one with start past end, `left 0`, `right 0`, and dropping all of `s`
from either end.
-}
emptyCuts : String -> List String
emptyCuts s =
    let
        n =
            String.length s
    in
    [ String.slice 2 2 s
    , String.slice 5 1 s
    , String.slice -1 -1 s
    , String.left 0 s
    , String.right 0 s
    , String.dropLeft n s
    , String.dropRight (n + 3) s
    ]


{-| Returns what follows the first character of `s`, or `"uncons-failed"` if
`s` is empty.
-}
unconsRest : String -> String
unconsRest s =
    case String.uncons s of
        Just ( _, rest ) ->
            rest

        Nothing ->
            "uncons-failed"


main =
    let
        ascii =
            "abc"

        utf16 =
            "éü"

        bigAscii =
            String.repeat 1200 "abcdefgh"

        bigUtf16 =
            "é" ++ String.repeat 1200 "abcdefgh"

        -- a 9000-character slice of the long non-ASCII string
        sliced =
            String.slice 100 9100 bigUtf16

        half =
            String.repeat 5000 "abcdefghijklmnop"

        rope =
            half ++ half

        groups =
            [ emptyCuts ascii
            , emptyCuts utf16
            , emptyCuts bigAscii
            , emptyCuts bigUtf16
            , emptyCuts sliced
            , emptyCuts rope
            ]

        uncons =
            [ unconsRest "a", unconsRest "é", unconsRest (String.right 1 bigUtf16) ]

        held =
            List.concat groups ++ uncons

        churn =
            List.range 0 100000
                |> List.map (\n -> String.fromInt n ++ "x")
                |> String.join ","

        afterGcBad =
            if String.length churn > 0 then
                held |> List.map probe |> List.filter ((/=) "0EQC") |> List.length

            else
                -1

        _ =
            Debug.log "sizes" (List.map String.length [ ascii, utf16, bigAscii, bigUtf16, sliced, rope ])

        _ =
            Debug.log "slice_ascii" (List.map probe (emptyCuts ascii))

        _ =
            Debug.log "slice_utf16" (List.map probe (emptyCuts utf16))

        _ =
            Debug.log "slice_big_ascii" (List.map probe (emptyCuts bigAscii))

        _ =
            Debug.log "slice_big_utf16" (List.map probe (emptyCuts bigUtf16))

        _ =
            Debug.log "slice_of_slice" (List.map probe (emptyCuts sliced))

        _ =
            Debug.log "slice_rope" (List.map probe (emptyCuts rope))

        _ =
            Debug.log "uncons_rest" (List.map probe uncons)

        _ =
            Debug.log "after_gc_bad" afterGcBad
    in
    text "done"
