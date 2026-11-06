module StringLengthFormsTest exposing (main)

{-| `String.length` gives the right count for strings built in several different ways,
not only for literals.

The strings are: the empty string (0); the ASCII literal `"hello"` (5); the literal
`"héllo wörld"`, whose accented letters each count as one (11); `String.repeat 5000 "x"`
(5000); a 290-character `String.slice` of a 500-character string; the `++` of two
70000-character strings (140000); a 4000-character slice of the 5000-character string; and
an empty slice of `"hello"` (0).

-}

-- CHECK: empty: 0
-- CHECK: ascii: 5
-- CHECK: utf16: 11
-- CHECK: large: 5000
-- CHECK: slice: 290
-- CHECK: rope: 140000
-- CHECK: sliceOfLarge: 4000
-- CHECK: emptySlice: 0

import Html exposing (text)


{-| The empty string.
-}
emptyStr : String
emptyStr =
    ""


{-| A literal made only of ASCII characters.
-}
asciiStr : String
asciiStr =
    "hello"


{-| A literal with two non-ASCII letters. Each is a single UTF-16 code unit, so
the 11 characters have length 11.
-}
utf16Str : String
utf16Str =
    "héllo wörld"


{-| A 5000-character string built with `String.repeat`.
-}
largeStr : String
largeStr =
    String.repeat 5000 "x"


{-| Characters 10 to 299 of a 500-character string, 290 in all.
-}
sliceStr : String
sliceStr =
    String.slice 10 300 (String.repeat 500 "y")


{-| Two 70000-character strings joined with `++`.
-}
ropeStr : String
ropeStr =
    String.repeat 70000 "a" ++ String.repeat 70000 "b"


{-| Characters 500 to 4499 of `largeStr`, 4000 in all.
-}
sliceOfLargeStr : String
sliceOfLargeStr =
    String.slice 500 4500 largeStr


{-| An empty slice of a non-empty string.
-}
emptySliceStr : String
emptySliceStr =
    String.slice 3 3 asciiStr


main : Html.Html msg
main =
    let
        _ =
            Debug.log "empty" (String.length emptyStr)

        _ =
            Debug.log "ascii" (String.length asciiStr)

        _ =
            Debug.log "utf16" (String.length utf16Str)

        _ =
            Debug.log "large" (String.length largeStr)

        _ =
            Debug.log "slice" (String.length sliceStr)

        _ =
            Debug.log "rope" (String.length ropeStr)

        _ =
            Debug.log "sliceOfLarge" (String.length sliceOfLargeStr)

        _ =
            Debug.log "emptySlice" (String.length emptySliceStr)
    in
    text "done"
