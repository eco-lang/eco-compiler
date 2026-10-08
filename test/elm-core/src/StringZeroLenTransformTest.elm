module StringZeroLenTransformTest exposing (main)

{-| HEAP_071 audit: whole-string transforms whose RESULT is empty — trim family
on whitespace-only input (ASCII leaf, large ASCII, and a UTF-16 structural
slice of spaces), filter that drops everything (ASCII, UTF-16, large),
map / toUpper / toLower / reverse / fromList / repeat / pad / append on empty
input. Each result must be the Empty constant.

probe s = length, String.isEmpty, (s == ""), case-on-"" — "0EQC" is correct.
-}

-- CHECK: sizes: [3, 9600, 200]
-- CHECK: trim: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: filter_none: ["0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: on_empty: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: build_empty: ["0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC", "0EQC"]
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


trims : String -> List String
trims s =
    [ String.trim s, String.trimLeft s, String.trimRight s ]


main =
    let
        blank =
            " \t\n"

        bigBlank =
            String.repeat 3200 " \t\n"

        -- "é" forces UTF-16; dropping it leaves a 200-char UTF-16 slice of spaces
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
