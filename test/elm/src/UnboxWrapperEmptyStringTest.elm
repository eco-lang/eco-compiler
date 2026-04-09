module UnboxWrapperEmptyStringTest exposing (main)

{-| Test Unbox (single-constructor) type wrapping empty string.
-}

-- CHECK: result: 0

import Html exposing (text)


type Wrapper a
    = Wrap a


unwrap : Wrapper a -> a
unwrap (Wrap x) =
    x


main =
    let
        w =
            Wrap ""

        result =
            String.length (unwrap w)

        _ = Debug.log "result" result
    in
    text "done"
