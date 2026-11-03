module RegexUtf16IndexTest exposing (main)

{-| `Match.index` counts UTF-16 code units, as `String.length` and `String.slice` do, recorded
from Elm on node (run-js-e2e.js --record). eco 0.2.0 counted code points, so slicing a string at a
match index went wrong after any character outside the BMP (eco-bugs.md number 4,
plans/kg-reported-bugs.md step 3). U+1F600 is two units; U+00E9 and U+4E2D are one each.

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
