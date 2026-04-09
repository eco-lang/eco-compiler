module UnboxWrapperNothingTest exposing (main)

{-| Test Unbox (single-constructor) type wrapping Nothing.
The Wrapper type has one constructor with one field, so it gets
Can.Unbox treatment. After Unbox elimination, projecting field 0
from the wrapper must handle Nothing (an embedded constant).
-}

-- CHECK: result: -1

import Html exposing (text)


type Wrapper a
    = Wrap a


unwrap : Wrapper a -> a
unwrap (Wrap x) =
    x


main =
    let
        w =
            Wrap Nothing

        inner =
            unwrap w

        result =
            case inner of
                Just x ->
                    x

                Nothing ->
                    -1

        _ = Debug.log "result" result
    in
    text "done"
