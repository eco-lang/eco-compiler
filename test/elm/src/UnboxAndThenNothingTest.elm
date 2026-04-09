module UnboxAndThenNothingTest exposing (main)

{-| Test andThen-style chaining on a single-constructor (Unbox) wrapper type
where the wrapped value is Nothing. This mirrors the Decoder.andThen pattern
that crashes the compiler during bootstrap Stage 7.
-}

-- CHECK: result: 42

import Html exposing (text)


type Wrapper a
    = Wrap a


pure : a -> Wrapper a
pure a =
    Wrap a


andThen : (a -> Wrapper b) -> Wrapper a -> Wrapper b
andThen callback (Wrap a) =
    callback a


main =
    let
        w =
            pure Nothing

        result =
            w
                |> andThen
                    (\v ->
                        case v of
                            Nothing ->
                                pure 42

                            Just x ->
                                pure x
                    )
                |> andThen (\x -> pure (x + 0))
                |> (\(Wrap x) -> x)

        _ = Debug.log "result" result
    in
    text "done"
