module CompareEmptyStringTest exposing (main)

{-| `compare` on String values, including `""` (Const_EmptyString).
Top-level path in `Utils::cmp` handles `!a && !b → 0`, `!a → -1`,
`!b → 1`, so these should all be correct today — regression guard.
-}

-- CHECK: ee: EQ
-- CHECK: ea: LT
-- CHECK: ae: GT
-- CHECK: eab: LT
-- CHECK: abe: GT
-- CHECK: aa: EQ
-- CHECK: ab: LT
-- CHECK: ba: GT
-- CHECK: aba: GT

import Html exposing (text)


main =
    let
        _ = Debug.log "ee" (compare "" "")
        _ = Debug.log "ea" (compare "" "a")
        _ = Debug.log "ae" (compare "a" "")
        _ = Debug.log "eab" (compare "" "ab")
        _ = Debug.log "abe" (compare "ab" "")
        _ = Debug.log "aa" (compare "a" "a")
        _ = Debug.log "ab" (compare "a" "b")
        _ = Debug.log "ba" (compare "b" "a")
        _ = Debug.log "aba" (compare "ab" "a")
    in
    text "done"
