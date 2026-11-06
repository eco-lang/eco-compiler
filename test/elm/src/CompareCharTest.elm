module CompareCharTest exposing (main)

{-| `compare` on `Char` returns `LT`, `GT` or `EQ` by character code.

  - `cmp1`: `compare 'a' 'b'` is `LT`.
  - `cmp2`: `compare 'z' 'a'` is `GT`.
  - `cmp3`: `compare 'x' 'x'` is `EQ`.

-}

-- CHECK: cmp1: LT
-- CHECK: cmp2: GT
-- CHECK: cmp3: EQ

import Html exposing (text)


main =
    let
        _ = Debug.log "cmp1" (compare 'a' 'b')
        _ = Debug.log "cmp2" (compare 'z' 'a')
        _ = Debug.log "cmp3" (compare 'x' 'x')
    in
    text "done"
