module EitherTypeTest exposing (main)

{-| Test Either-like polymorphic type with two constructors and two type parameters. -}

-- CHECK: left: 42
-- CHECK: right: 0
-- CHECK: mapLeft: 84
-- CHECK: isLeft: True

import Html exposing (text)


type Either a b
    = Left a
    | Right b


fromEither e default =
    case e of
        Left x ->
            x

        Right _ ->
            default


mapLeft f e =
    case e of
        Left x ->
            Left (f x)

        Right y ->
            Right y


isLeft e =
    case e of
        Left _ ->
            True

        Right _ ->
            False


main =
    let
        _ = Debug.log "left" (fromEither (Left 42) 0)
        _ = Debug.log "right" (fromEither (Right "err") 0)
        mapped = mapLeft (\x -> x * 2) (Left 42)
        _ = Debug.log "mapLeft" (fromEither mapped 0)
        _ = Debug.log "isLeft" (isLeft (Left 1))
    in
    text "done"
