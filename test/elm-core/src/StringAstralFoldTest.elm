module StringAstralFoldTest exposing (main)

{-| G1/E2: foldl/foldr iterate by UTF-16 CODE UNIT in Eco — Char is i16 per the
enforced REP_ABI_001 / CGEN_015 invariants, so an astral char is folded as its
two surrogate halves. This documents Eco's deliberate divergence from Elm's
code-point folding (matching Elm would require widening Char).
-}

-- CHECK: foldl_astral: 2
-- CHECK: foldl_mixed: 4
-- CHECK: foldr_mixed: 4

import Html exposing (text)


main =
    let
        _ =
            Debug.log "foldl_astral" (String.foldl (\_ n -> n + 1) 0 "😀")

        _ =
            Debug.log "foldl_mixed" (String.foldl (\_ n -> n + 1) 0 "a😀b")

        _ =
            Debug.log "foldr_mixed" (String.foldr (\_ n -> n + 1) 0 "a😀b")
    in
    text "done"
