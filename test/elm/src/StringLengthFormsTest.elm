module StringLengthFormsTest exposing (main)

{-| kernel-opt-04: `String.length` over every String heap form.

Under `ECO_STRING_LENGTH_OP=1` each call below lowers to `eco.string.length`,
an inline `header.size` load with an embedded-constant guard, instead of an
`Elm_Kernel_String_length` call. HEAP\_025/HEAP\_032 say that one word is the
logical UTF-16 unit count for ALL SIX forms, which is exactly what makes the
inline read legal without per-tag dispatch — so this fixture's job is to reach
all six forms and pin that the answer is unchanged in both flavours.

Forms reached, and why each construction reaches it (thresholds from
AllocatorCommon.hpp): a bare ASCII literal is a `Tag_StringUtf8Leaf`; a literal
with non-ASCII is a UTF-16 `Tag_String`; `slice` above STRING\_TINY\_SLICE\_LIMIT
(128 units) allocates a `Tag_StringSlice`/`Tag_StringUtf8View` rather than
copying; `append` above STRING\_FLATTEN\_LIMIT (32768 units) builds a
`Tag_StringRope` instead of flattening; and a string at or above
(8192-8)/2 = 4092 units is a split-header `Tag_LargeStringHeader`. The empty
string is an embedded constant, which is the guard arm of the inline diamond
and the one case that never dereferences.

-}

-- CHECK: empty: 0
-- CHECK: ascii: 5
-- CHECK: utf16: 11
-- CHECK: large: 5000
-- CHECK: slice: 290
-- CHECK: rope: 40000
-- CHECK: sliceOfLarge: 4000
-- CHECK: emptySlice: 0

import Html exposing (text)


{-| Embedded constant: the ptr\_ind guard arm, never dereferenced.
-}
emptyStr : String
emptyStr =
    ""


{-| All-ASCII literal: Tag\_StringUtf8Leaf.
-}
asciiStr : String
asciiStr =
    "hello"


{-| Non-ASCII literal: UTF-16 Tag\_String. All chars are BMP, so 11 chars is
also 11 UTF-16 code units.
-}
utf16Str : String
utf16Str =
    "héllo wörld"


{-| At or above 4092 units: split-header Tag_LargeStringHeader.
-}
largeStr : String
largeStr =
    String.repeat 5000 "x"


{-| Above 128 units: an interior view rather than a copy.
-}
sliceStr : String
sliceStr =
    String.slice 10 300 (String.repeat 500 "y")


{-| Above 32768 units: append builds a Tag_StringRope instead of flattening.
-}
ropeStr : String
ropeStr =
    String.repeat 20000 "a" ++ String.repeat 20000 "b"


{-| A view over a large string — the interior-pointer case.
-}
sliceOfLargeStr : String
sliceOfLargeStr =
    String.slice 500 4500 largeStr


{-| A degenerate slice: empty result from a non-empty source.
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
