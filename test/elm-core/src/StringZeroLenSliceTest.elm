module StringZeroLenSliceTest exposing (main)

{-| HEAP_071 audit: every String kernel that cuts a range out of a string, asked
for an EMPTY range, over every representation: small ASCII (UTF-8 leaf), small
non-ASCII (UTF-16 leaf), large ASCII (ByteBuffer + UTF-8 view), large
non-ASCII (split-header UTF-16), a structural slice, and a rope (> the 128K
flatten limit). Each result must be the Empty constant.

probe s = length, String.isEmpty, (s == ""), case-on-"" — "0EQC" is correct.
-}

-- CHECK: slice_ascii: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: slice_utf16: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: slice_big_ascii: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: slice_big_utf16: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: slice_of_slice: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: slice_rope: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: uncons_rest: ["0EQC", "0EQC", "0EQC"]
-- CHECK: sizes: [3, 2, 9600, 9601, 9000, 160000]
-- CHECK: after_gc_bad: 0

import Html exposing (text)


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


{-| Seven ways to ask for an empty range of `s`. -}
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

        -- a structural slice (> tiny limit) over a large UTF-16 parent
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
