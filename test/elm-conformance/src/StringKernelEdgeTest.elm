module StringKernelEdgeTest exposing (main)

{-| Edge cases of elm/core's string functions: `String.indexes ""` is `[]`, `String.toInt` accepts a
leading `+`, and trimming and `String.words` treat all JavaScript whitespace as whitespace.

  - `String.indexes` with an empty needle returns no indexes.
  - `String.toInt` accepts "+5" and rejects "+", "-", "+-5" and "++5".
  - `String.trim`, `trimLeft` and `trimRight` treat VT, FF, NBSP, U+FEFF, U+1680, U+2028,
    U+2029, U+205F and U+3000 as whitespace, as well as space, tab, LF and CR.
  - `String.words` splits on VT, FF, NBSP and U+3000.

The tests also cover strings that are only whitespace, a string built by concatenation, and
`String.words` on a slice. Lengths and counts are logged instead of most strings, to keep the
output ASCII.

-}

-- CHECK: indexes empty: "[[],[]]"
-- CHECK: indexes control: "[[1],[0,2]]"
-- CHECK: toInt sign: "[Just 5,Just -5,Nothing,Nothing,Just 5,Nothing,Nothing]"
-- CHECK: trim js whitespace: "[1,1,1,1,1,1]"
-- CHECK: trimLeft js whitespace: "[2,2,2]"
-- CHECK: trimRight js whitespace: "[1,1,1]"
-- CHECK: trim control: "[1,3]"
-- CHECK: words counts: "[2,2,2,1]"
-- CHECK: trim only whitespace: "[0,0,0]"
-- CHECK: trim concat: "[6,80]"
-- CHECK: words ascii vt ff: "[[\"a\",\"b\",\"c\"],[\"x\",\"y\"]]"
-- CHECK: words slice: "[[\"a\",\"b\"],[\"x\",\"yy\"]]"

import ConformanceHelp exposing (logAll, worker)


{-| Prints the length of `f` applied to each of `inputs`.
-}
lengths : (String -> String) -> List String -> String
lengths f inputs =
    Debug.toString (List.map (\s -> String.length (f s)) inputs)


report : ()
report =
    logAll
        [ ( "indexes empty", Debug.toString (List.map (\h -> String.indexes "" h) [ "abc", "" ]) )
        , ( "indexes control", Debug.toString (List.map (\( n, h ) -> String.indexes n h) [ ( "b", "abc" ), ( "a", "aba" ) ]) )
        , ( "toInt sign", Debug.toString (List.map String.toInt [ "+5", "-5", "+", "-", "5", "+-5", "++5" ]) )
        , ( "trim js whitespace"
          , lengths String.trim
                [ "\u{000B}a\u{000C}"
                , "\u{00A0}a\u{00A0}"
                , "\u{FEFF}a\u{FEFF}"
                , "\u{2028}a\u{2029}"
                , "\u{3000}a\u{3000}"
                , "\u{1680}a\u{205F}"
                ]
          )
        , ( "trimLeft js whitespace", lengths String.trimLeft [ "\u{00A0}a ", "\u{3000}a ", "\u{000C}a " ] )
        , ( "trimRight js whitespace", lengths String.trimRight [ "a\u{00A0}", "a\u{FEFF}", "a\u{000B}" ] )
        , ( "trim control", lengths String.trim [ " \t\na\u{000D}\n", "a b" ] )
        , ( "words counts", Debug.toString (List.map (\s -> List.length (String.words s)) [ "a\u{00A0}b", "a\u{3000}b", "a b", "ab" ]) )
        , ( "trim only whitespace", lengths String.trim [ "\u{3000}\u{00A0} \t", "   ", "\u{000B}\u{000C}" ] )
        , ( "trim concat", lengths String.trim (List.map (\n -> "\u{00A0}" ++ String.repeat n "ab" ++ "\u{3000}") [ 3, 40 ]) )
        , ( "words ascii vt ff", Debug.toString (List.map String.words [ "a\u{000B}b\u{000C}c", "\u{000C} x  y \u{000B}" ]) )
        , ( "words slice", Debug.toString (List.map (\s -> String.words (String.slice 1 -1 s)) [ "x a b x", "xx\u{00A0}yy\u{00A0}x" ]) )
        ]


main : Program () () ()
main =
    worker report
