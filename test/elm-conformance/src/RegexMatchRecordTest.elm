module RegexMatchRecordTest exposing (main)

{-| The `Match` records that `Regex.find`, `Regex.findAtMost` and `Regex.replace` produce carry the
right `index`, `match`, `number` and `submatches`.

Whole records are printed with `Debug.toString`, and single fields are read with `.match`,
`.number` and `.index`. The pattern `(a)b|(c)` gives submatches with a group that did not take
part in the match, which must be `Nothing`. The `replace` tests read every field inside the
replacement function.

-}

-- CHECK: find: "[{ index = 0, match = \"a\", number = 1, submatches = [] }]"
-- CHECK: find match: "[\"a\",\"a\"]"
-- CHECK: find number: "[1,2]"
-- CHECK: find index: "[1,4]"
-- CHECK: groups: "[{ index = 0, match = \"ab\", number = 1, submatches = [Just \"a\",Nothing] },{ index = 3, match = \"c\", number = 2, submatches = [Nothing,Just \"c\"] }]"
-- CHECK: findAtMost: "[\"x1\",\"x2\"]"
-- CHECK: replace: "b<1:a:1:0>b"
-- CHECK: replace groups: "[ab|1|a,-][c|2|-,c]"

import ConformanceHelp exposing (logAll, worker)
import Regex exposing (Match, Regex)


re : String -> Regex
re pattern =
    Maybe.withDefault Regex.never (Regex.fromString pattern)


sub : Maybe String -> String
sub m =
    Maybe.withDefault "-" m


report : ()
report =
    logAll
        [ ( "find", Debug.toString (List.concatMap (\s -> Regex.find (re "a") s) [ "abc" ]) )
        , ( "find match", Debug.toString (List.map .match (Regex.find (re "a") "bacda")) )
        , ( "find number", Debug.toString (List.map .number (Regex.find (re "a") "bacda")) )
        , ( "find index", Debug.toString (List.map .index (Regex.find (re "a") "bacda")) )
        , ( "groups", Debug.toString (List.concatMap (\s -> Regex.find (re "(a)b|(c)") s) [ "ab-c" ]) )
        , ( "findAtMost", Debug.toString (List.map .match (Regex.findAtMost 2 (re "x[0-9]") "x1 x2 x3")) )
        , ( "replace"
          , Regex.replace (re "a")
                (\m -> "<" ++ String.fromInt m.index ++ ":" ++ m.match ++ ":" ++ String.fromInt m.number ++ ":" ++ String.fromInt (List.length m.submatches) ++ ">")
                "bab"
          )
        , ( "replace groups"
          , Regex.replace (re "(a)b|(c)")
                (\m -> "[" ++ m.match ++ "|" ++ String.fromInt m.number ++ "|" ++ String.join "," (List.map sub m.submatches) ++ "]")
                "abc"
          )
        ]


main : Program () () ()
main =
    worker report
