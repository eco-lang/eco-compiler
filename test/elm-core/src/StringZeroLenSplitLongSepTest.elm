module StringZeroLenSplitLongSepTest exposing (main)

{-| Found by the HEAP_071 audit (not a zero-length bug): StringOps::split's
UTF-16 path scans short separators (1-3 units) with
`for (i = 0; i <= str_len - sep_len; ++i)` on size_t, so a separator LONGER
than a non-ASCII input wraps the bound to ~2^64 and reads past the snapshot
buffer. The UTF-8 path (`i + sep_len <= str_len`) and the >= 4-unit
Horspool path are not affected. Expected: the input comes back as the single
part.
-}

-- CHECK: split_long_sep_utf16: [True, True, True, True]
-- CHECK: split_long_sep_ascii: ["a"]

import Html exposing (text)


main =
    let
        _ =
            -- compared with == (Debug.log escapes non-ASCII as \u00XX)
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
