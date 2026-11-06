module RegexUtf16IndexTest exposing (main)

{-| `Match.index` counts UTF-16 code units, as `String.length` and `String.slice` do.

U+1F600 is two code units; U+00E9 and U+4E2D are one each. The tests check the index of a match
after U+1F600, that `String.slice` at that index gives the matched text, the indexes of repeated
matches between U+1F600s, indexes after one-unit non-ASCII characters, the index passed to a
`Regex.replace` function, and the index from `Regex.findAtMost`.

-}

-- CHECK: find index: "[3]"
-- CHECK: slice at index: "True"
-- CHECK: find indexes: "[0,3,6,9]"
-- CHECK: bmp indexes: "[2,4]"
-- CHECK: replace index: "a<3>c<9>"
-- CHECK: findAtMost index: "[5]"

import ConformanceHelp exposing (logAll, worker)
import Regex exposing (Regex)


re : String -> Regex
re pattern =
    Maybe.withDefault Regex.never (Regex.fromString pattern)


emoji : String
emoji =
    String.fromChar (Char.fromCode 0x0001F600)


report : ()
report =
    let
        text =
            "a" ++ emoji ++ "b"

        indexes =
            List.map .index (Regex.find (re "(b)") text)
    in
    logAll
        [ ( "find index", Debug.toString indexes )
        , ( "slice at index", Debug.toString (List.map (\i -> String.slice i (i + 1) text) indexes == [ "b" ]) )
        , ( "find indexes", Debug.toString (List.map .index (Regex.find (re "x") (String.repeat 4 ("x" ++ emoji)))) )
        , ( "bmp indexes", Debug.toString (List.map .index (Regex.find (re "x") ("\u{00E9}\u{4E2D}x\u{00E9}x"))) )
        , ( "replace index", String.filter (\c -> Char.toCode c < 128) (Regex.replace (re "[bd]") (\m -> "<" ++ String.fromInt m.index ++ ">") ("a" ++ emoji ++ "bc" ++ emoji ++ emoji ++ "d")) )
        , ( "findAtMost index", Debug.toString (List.map .index (Regex.findAtMost 1 (re "y") (emoji ++ emoji ++ "\u{00E9}y"))) )
        ]


main : Program () () ()
main =
    worker report
