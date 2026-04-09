module UnboxWrapperNilTest exposing (main)

{-| Test Unbox (single-constructor) type wrapping empty list.
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
            Wrap []

        inner =
            unwrap w

        result =
            List.length inner

        _ = Debug.log "result" result
    in
    text "done"
