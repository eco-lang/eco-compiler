module StringAstralReverseTest exposing (main)

{-| G1/E4: reverse keeps a surrogate pair together and in order, as Elm's JS
`_String_reverse` does, so it equals the code-point reversal
(fromList ∘ List.reverse ∘ toList, where toList yields one Char per code
point) and "a😀b" reverses to "b😀a". Asserted as equalities so the output is
ASCII-only (Debug.log \u-escapes each UTF-16 unit of a non-ASCII string).
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
