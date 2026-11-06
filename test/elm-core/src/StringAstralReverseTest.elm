module StringAstralReverseTest exposing (main)

{-| `String.reverse` keeps a character outside the Basic Multilingual Plane,
such as an emoji, whole, rather than reversing the two UTF-16 units it is
stored as.

The test checks that reversing `"a😀b"` equals reversing its `String.toList`,
that it gives `"b😀a"`, and that reversing `"x😀𝄞y"` twice returns it unchanged.

-}

-- CHECK: rev_matches_codepoint: True
-- CHECK: rev_pair_kept: True
-- CHECK: rev_twice_id: True

import Html exposing (text)


main =
    let
        _ =
            Debug.log "rev_matches_codepoint"
                (String.reverse "a😀b"
                    == String.fromList (List.reverse (String.toList "a😀b"))
                )

        _ =
            Debug.log "rev_pair_kept" (String.reverse "a😀b" == "b😀a")

        _ =
            Debug.log "rev_twice_id" (String.reverse (String.reverse "x😀𝄞y") == "x😀𝄞y")
    in
    text "done"
