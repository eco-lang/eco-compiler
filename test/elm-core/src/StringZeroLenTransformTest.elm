module StringZeroLenTransformTest exposing (main)

{-| `String` functions that transform a whole string return a true empty string
when the result is empty.

Each result is passed to `probe`, which checks `String.length`,
`String.isEmpty`, `== ""` and a `case` on the `""` pattern. An empty result must
answer all four as empty, `"0EQC"`.

  - `trim`: `String.trim`, `trimLeft` and `trimRight` on three whitespace-only
    strings, of lengths 3, 9600 and 200 as `sizes` logs; the last is what
    `String.dropLeft 1` leaves of `"é"` followed by 200 spaces.
  - `filter_none`: `String.filter` keeping nothing from `"abc"`, `"éü"` and a
    9600-character string, and `Char.isDigit` on `"abc"`.
  - `on_empty`: `String.map`, `toUpper`, `toLower`, `reverse`, `trim` and
    `filter` applied to an empty string.
  - `build_empty`: `String.fromList []`, a `toList`/`fromList` round trip,
    `String.repeat` with count 0 or of `""`, `padLeft 0`, `padRight` with a
    negative length, and `++` of two empty strings.

After that, the program builds a large comma-joined string of 100,001 numbers
and probes every case result again; `after_gc_bad` is the number that no longer
reads as `"0EQC"`, and must be 0.

-}

-- CHECK: sizes: [3,9600,200]
-- CHECK: trim: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: filter_none: ["0EQC","0EQC","0EQC","0EQC"]
-- CHECK: on_empty: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
-- CHECK: build_empty: ["0EQC","0EQC","0EQC","0EQC","0EQC","0EQC","0EQC"]
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


{-| Returns `s` trimmed at both ends, at the start and at the end.
-}
trims : String -> List String
trims s =
    [ String.trim s, String.trimLeft s, String.trimRight s ]


main =
    let
        blank =
            " \t\n"

        bigBlank =
            String.repeat 3200 " \t\n"

        -- 200 spaces left after dropping a leading non-ASCII character
        utf16Blank =
            String.dropLeft 1 ("é" ++ String.repeat 200 " ")

        trimResults =
            trims blank ++ trims bigBlank ++ trims utf16Blank

        none =
            \_ -> False

        filterResults =
            [ String.filter none "abc"
            , String.filter none "éü"
            , String.filter none (String.repeat 1200 "abcdefgh")
            , String.filter Char.isDigit "abc"
            ]

        empty =
            String.left 0 "abc"

        onEmpty =
            [ String.map Char.toUpper empty
            , String.toUpper empty
            , String.toLower empty
            , String.reverse empty
            , String.trim empty
            , String.filter (\_ -> True) empty
            , String.map identity ""
            ]

        buildEmpty =
            [ String.fromList []
            , String.fromList (String.toList empty)
            , String.repeat 0 "abc"
            , String.repeat 5 ""
            , String.padLeft 0 ' ' ""
            , String.padRight -3 'x' empty
            , empty ++ ""
            ]

        held =
            trimResults ++ filterResults ++ onEmpty ++ buildEmpty

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
            Debug.log "sizes" (List.map String.length [ blank, bigBlank, utf16Blank ])

        _ =
            Debug.log "trim" (List.map probe trimResults)

        _ =
            Debug.log "filter_none" (List.map probe filterResults)

        _ =
            Debug.log "on_empty" (List.map probe onEmpty)

        _ =
            Debug.log "build_empty" (List.map probe buildEmpty)

        _ =
            Debug.log "after_gc_bad" afterGcBad
    in
    text "done"
