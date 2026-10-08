module StringZeroLenSplitTest exposing (main)

{-| HEAP_071 audit: split / lines / words producing EMPTY parts (leading,
trailing and adjacent separators), on ASCII (UTF-8 byte path) and non-ASCII
(UTF-16 snapshot path) inputs, plus a large input. Every empty part must be the
Empty constant.

probe s = length, String.isEmpty, (s == ""), case-on-"" — "0EQC" is correct.
-}

-- CHECK: split_ascii: ["0EQC", "0EQC"]
-- CHECK: split_ascii_mixed: ["0EQC", "1eqc", "0EQC", "1eqc", "0EQC"]
-- CHECK: split_ascii_long_sep: ["0EQC", "0EQC", "0EQC"]
-- CHECK: split_utf16: ["0EQC", "0EQC"]
-- CHECK: split_utf16_mixed: ["0EQC", "1eqc", "0EQC", "1eqc", "0EQC"]
-- CHECK: split_utf16_long_sep: ["0EQC", "0EQC", "0EQC"]
-- CHECK: split_empty_input: ["0EQC"]
-- CHECK: split_big_bad: 0
-- CHECK: lines_ascii: ["0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: lines_utf16: ["0EQC", "1eqc", "0EQC"]
-- CHECK: lines_empty: ["0EQC"]
-- CHECK: words_blank: [[], [], []]
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
            String.split "é" "éaééb\u{00E9}"

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

        wordsBlank =
            [ String.words "   ", String.words "\t\n\u{000D} ", String.words "" ]

        held =
            List.filter isEmptyPart
                (splitAscii ++ splitAsciiMixed ++ splitAsciiLongSep ++ splitUtf16
                    ++ splitUtf16Mixed ++ splitUtf16LongSep ++ splitEmptyInput
                    ++ splitBig ++ linesAscii ++ linesUtf16 ++ linesEmpty
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
            Debug.log "words_blank" wordsBlank

        _ =
            Debug.log "after_gc_bad" afterGcBad
    in
    text "done"
