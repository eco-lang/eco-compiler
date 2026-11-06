module StringZeroLenJoinTest exposing (main)

{-| `String.join`, `String.concat` and `String.replace` return a true empty
string when the result is empty although the input list or string is not.

Each result is passed to `probe`, which checks four ways of asking whether a
string is empty: `String.length`, `String.isEmpty`, `== ""` and a `case` on the
`""` pattern. An empty result must answer all four as empty, `"0EQC"`.

  - `join_ascii`: `String.join` over lists of one or two empty strings, with
    the separators `", "`, `""` and `"-"`.
  - `concat`: `String.concat` of one, three or fifty empty strings, and of an
    empty slice followed by `""`.
  - `replace`: `String.replace` removing every occurrence of `"a"`, `"ab"` and
    the non-ASCII `"é"` from strings made only of that pattern.
  - `controls`: results that are not empty, `"-"` and `"ab"`, read as length 1
    and 2, and `String.join "-" []` is empty.

After that, the program builds a large comma-joined string of 100,001 numbers
and probes every case result again; `after_gc_bad` is the number that no longer
reads as `"0EQC"`, and must be 0.

-}

-- CHECK: join_ascii: ["0EQC","0EQC","0EQC","0EQC"]
-- CHECK: concat: ["0EQC","0EQC","0EQC","0EQC"]
-- CHECK: replace: ["0EQC","0EQC","0EQC"]
-- CHECK: controls: ["1eqc","0EQC","2eqc"]
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
