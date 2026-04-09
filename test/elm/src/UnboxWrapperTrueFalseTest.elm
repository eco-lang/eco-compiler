module UnboxWrapperTrueFalseTest exposing (main)

{-| Test Unbox (single-constructor) type wrapping True and False.
-}

-- CHECK: r1: True
-- CHECK: r2: False

import Html exposing (text)


type Wrapper a
    = Wrap a


unwrap : Wrapper a -> a
unwrap (Wrap x) =
    x


main =
    let
        r1 =
            unwrap (Wrap True)

        r2 =
            unwrap (Wrap False)

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
