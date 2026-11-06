module CompareEmptyStringTest exposing (main)

{-| `compare` on `String` values, including the empty string.

The empty string is equal to itself and less than any non-empty string. A
string that is a prefix of another (`"a"` and `"ab"`) is less than it.

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
