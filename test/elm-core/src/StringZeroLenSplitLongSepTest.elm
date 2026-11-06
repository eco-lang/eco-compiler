module StringZeroLenSplitLongSepTest exposing (main)

{-| `String.split` with a separator longer than the input returns the input
unchanged as the single part.

`split_long_sep_utf16` uses the non-ASCII inputs `"é"` and `"éü"` with
separators of two or three characters (`"ab"`, `"abc"`, `"éé"`, `"üéx"`) and
compares each result with `==` against the expected one-element list.
`split_long_sep_ascii` logs `String.split "ab" "a"`, which must be `["a"]`.

-}

-- CHECK: split_long_sep_utf16: [True,True,True,True]
-- CHECK: split_long_sep_ascii: ["a"]

import Html exposing (text)


main =
    let
        _ =
            -- compared with == so the expected output holds no non-ASCII text
            Debug.log "split_long_sep_utf16"
                [ String.split "ab" "é" == [ "é" ]
                , String.split "abc" "é" == [ "é" ]
                , String.split "éé" "é" == [ "é" ]
                , String.split "üéx" "éü" == [ "éü" ]
                ]

        _ =
            Debug.log "split_long_sep_ascii" (String.split "ab" "a")
    in
    text "done"
