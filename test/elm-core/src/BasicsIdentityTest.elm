module BasicsIdentityTest exposing (main)

{-| `identity` returns its argument unchanged for an Int and a String, and `always 99` returns
99 whatever its second argument.
-}

-- CHECK: identity_int: 42
-- CHECK: identity_string: "hello"
-- CHECK: always_result: 99

import Html exposing (text)

main =
    let
        _ = Debug.log "identity_int" (identity 42)
        _ = Debug.log "identity_string" (identity "hello")
        _ = Debug.log "always_result" (always 99 "ignored")
    in
    text "done"
