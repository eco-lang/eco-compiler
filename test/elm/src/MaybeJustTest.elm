module MaybeJustTest exposing (main)

{-| Test Just creation.
-}

-- CHECK: just1: Just 42
-- CHECK: just2: Just "hello"
-- CHECK: just3: Just True

import Html exposing (text)


main =
    let
        _ = Debug.log "just1" (Just 42)
        _ = Debug.log "just2" (Just "hello")
        _ = Debug.log "just3" (Just True)
    in
    text "done"
