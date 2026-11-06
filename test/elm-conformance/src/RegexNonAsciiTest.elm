module RegexNonAsciiTest exposing (main)

{-| elm/regex matches non-ASCII text by UTF-16 code units: `.` matches U+00E9 once and U+1F600 as
two separate units.

The tests also check that a character class and a `\u00e9` escape match U+00E9, that a
case-insensitive pattern for U+00E9 matches U+00C9, that `^.{3}$` matches "aéb", that
`Regex.replace` replaces each character of "é中" with one "x", and that `Regex.split` splits on
a non-ASCII separator. Matches are shown as their counts, lengths and code points, so the output
stays ASCII.

-}

-- CHECK: dot on e-acute: "1 [1] [E9]"
-- CHECK: dot on emoji: "2 [1,1]"
-- CHECK: class e-acute/u-umlaut: "True"
-- CHECK: escape u00e9: "True"
-- CHECK: icase e-acute: "True"
-- CHECK: three dots: "True"
-- CHECK: replace dots: "xx"
-- CHECK: split cjk: "2 [E9] [62]"
-- CHECK: split e-acute: "2 [61] [62]"

import ConformanceHelp exposing (cps, logAll, worker)
import Regex exposing (Regex)


re : String -> Regex
re pattern =
    Maybe.withDefault Regex.never (Regex.fromString pattern)


emoji : String
emoji =
    String.fromChar (Char.fromCode 0x0001F600)


eAcute : String
eAcute =
    "\u{00E9}"


{-| Shows the number of strings, their lengths and their code points.
-}
parts : List String -> String
parts strs =
    String.fromInt (List.length strs)
        ++ " ["
        ++ String.join "," (List.map (String.fromInt << String.length) strs)
        ++ "] ["
        ++ String.join "," (List.map cps strs)
        ++ "]"


{-| Shows the number of strings and their lengths. It is used for matches that may be lone
surrogates, whose code points are not printed.
-}
lengths : List String -> String
lengths strs =
    String.fromInt (List.length strs)
        ++ " ["
        ++ String.join "," (List.map (String.fromInt << String.length) strs)
        ++ "]"


{-| Shows the number of strings and their code points.
-}
partsCps : List String -> String
partsCps strs =
    String.fromInt (List.length strs) ++ " [" ++ String.join "] [" (List.map cps strs) ++ "]"


report : ()
report =
    let
        icase =
            Maybe.withDefault Regex.never
                (Regex.fromStringWith { caseInsensitive = True, multiline = False } eAcute)
    in
    logAll
        [ ( "dot on e-acute", parts (List.map .match (Regex.find (re ".") eAcute)) )
        , ( "dot on emoji", lengths (List.map .match (Regex.find (re ".") emoji)) )
        , ( "class e-acute/u-umlaut", Debug.toString (Regex.contains (re "^[\u{00E9}\u{00FC}]$") "\u{00FC}") )
        , ( "escape u00e9", Debug.toString (Regex.contains (re "\\u00e9") eAcute) )
        , ( "icase e-acute", Debug.toString (Regex.contains icase "\u{00C9}") )
        , ( "three dots", Debug.toString (Regex.contains (re "^.{3}$") ("a" ++ eAcute ++ "b")) )
        , ( "replace dots", Regex.replace (re ".") (\_ -> "x") (eAcute ++ "\u{4E2D}") )
        , ( "split cjk", partsCps (Regex.split (re "\u{4E2D}") (eAcute ++ "\u{4E2D}b")) )
        , ( "split e-acute", partsCps (Regex.split (re eAcute) ("a" ++ eAcute ++ "b")) )
        ]


main : Program () () ()
main =
    worker report
