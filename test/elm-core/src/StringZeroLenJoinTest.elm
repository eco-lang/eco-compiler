module StringZeroLenJoinTest exposing (main)

{-| HEAP_071 audit: String.join / String.concat / String.replace whose RESULT is
empty although the list is not. Every empty result must be the Empty constant,
never a zero-length heap string.

`join` (StringOps.cpp) only returns early when the LIST is empty; with a
non-empty list of empty strings total_len is 0 and the ASCII byte-join path
calls allocAsciiOut(0), which asserts in -UNDEBUG builds (the macOS/Windows
bundles) and allocates a header-only leaf otherwise.

probe s = length, String.isEmpty, (s == ""), case-on-"" — "0EQC" is a correct
empty string, "0eqc" is a zero-length heap string that is not "".
-}

-- CHECK: join_ascii: ["0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: concat: ["0EQC", "0EQC", "0EQC", "0EQC"]
-- CHECK: replace: ["0EQC", "0EQC", "0EQC"]
-- CHECK: controls: ["1eqc", "0EQC", "2eqc"]
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


main =
    let
        joinAscii =
            [ String.join ", " [ "" ]
            , String.join "" [ "", "" ]
            , String.join "" [ "" ]
            , String.join "-" [ String.left 0 "abc" ]
            ]

        concats =
            [ String.concat [ "" ]
            , String.concat [ "", "", "" ]
            , String.concat [ String.slice 1 1 "abc", "" ]
            , String.concat (List.repeat 50 "")
            ]

        -- replace = join to (split from s): every part empty, empty separator.
        replaces =
            [ String.replace "a" "" "aaa"
            , String.replace "ab" "" "abab"
            , String.replace "é" "" "éé"
            ]

        controls =
            [ String.join "-" [ "", "" ]
            , String.join "-" []
            , String.concat [ "a", "", "b" ]
            ]

        held =
            joinAscii ++ concats ++ replaces

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
            Debug.log "join_ascii" (List.map probe joinAscii)

        _ =
            Debug.log "concat" (List.map probe concats)

        _ =
            Debug.log "replace" (List.map probe replaces)

        _ =
            Debug.log "controls" (List.map probe controls)

        _ =
            Debug.log "after_gc_bad" afterGcBad
    in
    text "done"
