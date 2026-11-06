module ComparableMinMaxTest exposing (main)

{-| `min` and `max` on `String` and `Char`, which order them by character code.

  - `minStr` and `maxStr`: of `"apple"` and `"zebra"`, the minimum is `"apple"` and the maximum `"zebra"`.
  - `minChar` and `maxChar`: of `'a'` and `'z'`, the minimum is `'a'` and the maximum `'z'`.

Among what is not tested: equal arguments, and `Int`, `Float`, tuples and lists.

-}

-- CHECK: minStr: "apple"
-- CHECK: maxStr: "zebra"
-- CHECK: minChar: 'a'
-- CHECK: maxChar: 'z'

import Html exposing (text)


main =
    let
        _ = Debug.log "minStr" (min "apple" "zebra")
        _ = Debug.log "maxStr" (max "apple" "zebra")
        _ = Debug.log "minChar" (min 'a' 'z')
        _ = Debug.log "maxChar" (max 'a' 'z')
    in
    text "done"
