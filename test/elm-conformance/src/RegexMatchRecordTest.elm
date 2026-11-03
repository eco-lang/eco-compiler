module RegexMatchRecordTest exposing (main)

{-| Every field of the `Match` records `Regex.find`, `Regex.findAtMost` and `Regex.replace`
build, recorded from Elm on node (run-js-e2e.js --record). eco 0.2.0 built them with the fields
in alphabetical order, while compiled code reads records with their unboxed fields first: `.match`
segfaulted and `.number` read the string's pointer (eco-bugs.md number 1,
plans/kg-reported-bugs.md step 1). Also a submatch that did not take part (`Nothing`).

The inputs go through `List.map`, so the kernels run at run time, not in a constant fold.

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
