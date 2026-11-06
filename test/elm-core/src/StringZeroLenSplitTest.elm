module StringZeroLenSplitTest exposing (main)

{-| `String.split` and `String.lines` return true empty strings for the empty
parts produced by leading, trailing and adjacent separators.

Each part is passed to `probe`, which checks `String.length`, `String.isEmpty`,
`== ""` and a `case` on the `""` pattern. An empty part must answer all four as
empty, `"0EQC"`; the non-empty parts `"a"`, `"b"` and `"é"` read as `"1eqc"`.

  - `split_ascii`, `split_ascii_mixed`, `split_ascii_long_sep`: splitting
    `","` and `",a,,b,"` on `","`, and `"abcdabcd"` on the four-character
    separator `"abcd"`.
  - `split_utf16`, `split_utf16_mixed`, `split_utf16_long_sep`: the same
    shapes with the separators `"é"` and `"éééé"`.
  - `split_empty_input`: splitting `""` gives one empty part.
  - `split_big_bad`: splitting 2000 commas gives 2001 parts, and the number
    that are not `"0EQC"` must be 0.
  - `lines_ascii`, `lines_utf16`, `lines_empty`: `String.lines` on
    `"\n\n\r\n"` (four empty lines, `\r\n` counting as one break), on
    `"\né\n"`, and on `""`.

After that, the program builds a large comma-joined string of 100,001 numbers
and probes every empty part again; `after_gc_bad` is the number that no longer
reads as `"0EQC"`, and must be 0.

-}

-- CHECK: split_ascii: ["0EQC","0EQC"]
-- CHECK: split_ascii_mixed: ["0EQC","1eqc","0EQC","1eqc","0EQC"]
-- CHECK: split_ascii_long_sep: ["0EQC","0EQC","0EQC"]
-- CHECK: split_utf16: ["0EQC","0EQC"]
-- CHECK: split_utf16_mixed: ["0EQC","1eqc","0EQC","1eqc","0EQC"]
-- CHECK: split_utf16_long_sep: ["0EQC","0EQC","0EQC"]
-- CHECK: split_empty_input: ["0EQC"]
-- CHECK: split_big_bad: 0
-- CHECK: lines_ascii: ["0EQC","0EQC","0EQC","0EQC"]
-- CHECK: lines_utf16: ["0EQC","1eqc","0EQC"]
-- CHECK: lines_empty: ["0EQC"]
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
        ++ (if String.isEmpty s then
                "E"

            else
                "e"
           )
        ++ (if s == "" then
                "Q"

            else
                "q"
           )
        ++ (case s of
                "" ->
                    "C"

                _ ->
                    "c"
           )


{-| Tells whether `s` has length 0; used to keep only the empty parts.
-}
isEmptyPart : String -> Bool
isEmptyPart s =
    String.length s == 0


main =
    let
        splitAscii =
            String.split "," ","

        splitAsciiMixed =
            String.split "," ",a,,b,"

        splitAsciiLongSep =
            String.split "abcd" "abcdabcd"

        splitUtf16 =
            String.split "é" "é"

        splitUtf16Mixed =
            String.split "é" "éaéébé"

        splitUtf16LongSep =
            String.split "éééé" "éééééééé"

        splitEmptyInput =
            String.split "," ""

        -- large input: 2000 adjacent separators -> 2001 empty parts
        splitBig =
            String.split "," (String.repeat 2000 ",")

        splitBigBad =
            splitBig |> List.map probe |> List.filter ((/=) "0EQC") |> List.length

        linesAscii =
            String.lines "\n\n\u{000D}\n"

        linesUtf16 =
            String.lines "\né\n"

        linesEmpty =
            String.lines ""

        held =
            List.filter isEmptyPart
                (splitAscii
                    ++ splitAsciiMixed
                    ++ splitAsciiLongSep
                    ++ splitUtf16
                    ++ splitUtf16Mixed
                    ++ splitUtf16LongSep
                    ++ splitEmptyInput
                    ++ splitBig
                    ++ linesAscii
                    ++ linesUtf16
                    ++ linesEmpty
                )

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
            Debug.log "split_ascii" (List.map probe splitAscii)

        _ =
            Debug.log "split_ascii_mixed" (List.map probe splitAsciiMixed)

        _ =
            Debug.log "split_ascii_long_sep" (List.map probe splitAsciiLongSep)

        _ =
            Debug.log "split_utf16" (List.map probe splitUtf16)

        _ =
            Debug.log "split_utf16_mixed" (List.map probe splitUtf16Mixed)

        _ =
            Debug.log "split_utf16_long_sep" (List.map probe splitUtf16LongSep)

        _ =
            Debug.log "split_empty_input" (List.map probe splitEmptyInput)

        _ =
            Debug.log "split_big_bad" splitBigBad

        _ =
            Debug.log "lines_ascii" (List.map probe linesAscii)

        _ =
            Debug.log "lines_utf16" (List.map probe linesUtf16)

        _ =
            Debug.log "lines_empty" (List.map probe linesEmpty)

        _ =
            Debug.log "after_gc_bad" afterGcBad
    in
    text "done"
