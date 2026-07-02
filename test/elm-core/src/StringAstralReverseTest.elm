module StringAstralReverseTest exposing (main)

{-| G1/E4: reverse operates per UTF-16 code unit in Eco (Char is i16), so it is
exactly the code-unit reversal (fromList ∘ List.reverse ∘ toList). For an astral
char a single reverse swaps the surrogate halves — a deliberate divergence from
Elm's code-point reverse. Asserted as an equality so it is ASCII-safe (Debug.log
otherwise \u-escapes the surrogates).
-}

-- CHECK: rev_matches_codeunit: True

import Html exposing (text)


main =
    let
        _ =
            Debug.log "rev_matches_codeunit"
                (String.reverse "a😀b"
                    == String.fromList (List.reverse (String.toList "a😀b"))
                )
    in
    text "done"
