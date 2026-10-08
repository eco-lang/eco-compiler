module StringZeroLenJoinUtf16Test exposing (main)

{-| HEAP_071 audit: String.join with a non-ASCII (UTF-16) separator and a
single empty element. The separator is never emitted, so the result is empty;
the UTF-16 join path in StringOps.cpp allocates a raw Tag_String of size 0
(no assertion guards it), producing a zero-length heap string that is NOT
equal to "". This case is SILENT in every build — only the semantic probe or a
GC survival check can see it.

probe s = length, String.isEmpty, (s == ""), case-on-"" — "0EQC" is correct.
-}

-- CHECK: join_utf16_sep: ["0EQC", "0EQC", "0EQC"]
-- CHECK: control: ["1eqc", "3eqc"]
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
        cases =
            [ String.join "é" [ "" ]
            , String.join " → " [ "" ]
            , String.join "é" [ String.dropLeft 5 "abc" ]
            ]

        controls =
            [ String.join "é" [ "", "" ]
            , String.join "é" [ "a", "b" ]
            ]

        churn =
            List.range 0 100000
                |> List.map (\n -> String.fromInt n ++ "x")
                |> String.join ","

        afterGcBad =
            if String.length churn > 0 then
                cases |> List.map probe |> List.filter ((/=) "0EQC") |> List.length

            else
                -1

        _ =
            Debug.log "join_utf16_sep" (List.map probe cases)

        _ =
            Debug.log "control" (List.map probe controls)

        _ =
            Debug.log "after_gc_bad" afterGcBad
    in
    text "done"
