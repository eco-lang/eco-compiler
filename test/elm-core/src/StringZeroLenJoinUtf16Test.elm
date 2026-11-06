module StringZeroLenJoinUtf16Test exposing (main)

{-| `String.join` with a non-ASCII separator over a single empty element
returns a true empty string: the separator is never inserted, so the result is
`""`.

Each result is passed to `probe`, which checks four ways of asking whether a
string is empty: `String.length`, `String.isEmpty`, `== ""` and a `case` on the
`""` pattern. An empty result must answer all four as empty, `"0EQC"`.

  - `join_utf16_sep`: the separators `"é"` and `" → "` joining `[ "" ]`, and
    `"é"` joining a list holding `String.dropLeft 5 "abc"`.
  - `control`: with two elements the separator does appear, so
    `String.join "é" [ "", "" ]` has length 1 and `String.join "é" [ "a", "b" ]`
    length 3.

After that, the program builds a large comma-joined string of 100,001 numbers
and probes every case result again; `after_gc_bad` is the number that no longer
reads as `"0EQC"`, and must be 0.

-}

-- CHECK: join_utf16_sep: ["0EQC","0EQC","0EQC"]
-- CHECK: control: ["1eqc","3eqc"]
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
