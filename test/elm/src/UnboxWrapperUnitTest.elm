module UnboxWrapperUnitTest exposing (main)

{-| Test Unbox (single-constructor) type wrapping Unit.
-}

-- CHECK: result: ()

import Html exposing (text)


type Wrapper a
    = Wrap a


unwrap : Wrapper a -> a
unwrap (Wrap x) =
    x


main =
    let
        w =
            Wrap ()

        result =
            unwrap w

        _ = Debug.log "result" result
    in
    text "done"
