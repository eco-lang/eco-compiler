module UnboxApplyNothingTest exposing (main)

{-| Test applicative-style apply on a single-constructor (Unbox) wrapper type
with Nothing values, mirroring the D.pure f |> D.apply pattern used in
the compiler's JSON outline decoder.
-}

-- CHECK: result: (-1, "none")

import Html exposing (text)


type Wrapper a
    = Wrap a


pure : a -> Wrapper a
pure a =
    Wrap a


apply : Wrapper a -> Wrapper (a -> b) -> Wrapper b
apply (Wrap arg) (Wrap f) =
    Wrap (f arg)


unwrap : Wrapper a -> a
unwrap (Wrap x) =
    x


extractMaybe : Maybe Int -> Int
extractMaybe m =
    case m of
        Just x ->
            x

        Nothing ->
            -1


extractList : List a -> String
extractList l =
    case l of
        [] ->
            "none"

        _ ->
            "some"


main =
    let
        result =
            pure Tuple.pair
                |> apply (pure (extractMaybe Nothing))
                |> apply (pure (extractList []))
                |> unwrap

        _ = Debug.log "result" result
    in
    text "done"
