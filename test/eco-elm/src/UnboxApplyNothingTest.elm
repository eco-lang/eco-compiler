module UnboxApplyNothingTest exposing (main)

{-| Checks applicative-style `apply` on a single-constructor wrapper type, with
arguments computed from `Nothing` and an empty list.

`pure Tuple.pair` is applied in turn to `pure (extractMaybe Nothing)`, which is
`-1`, and `pure (extractList [])`, which is `"none"`, and the unwrapped pair
prints as `(-1,"none")`.

## eco

A one-constructor, one-field type gets `Can.Unbox` treatment
(compiler/src/Compiler/IR/Canonical.elm): no `Custom` is allocated and the
wrapper is the payload itself, with projections through `TypedPath.Unbox`
(compiler/src/Compiler/IR/DecisionTree/TypedPath.elm). See
plans/sum-type-wrapper-unboxing.md for where `Unbox` applies.

This test mirrors the `D.pure f |> D.apply` pattern of the compiler's JSON
outline decoder, with `Nothing` (an embedded constant) as the payload. It
was also one of the two pre-existing failures of the pre-monomorphization
identity validator noted in plans/post-inline-dead-spec-prune.md.

-}

-- CHECK: result: (-1,"none")

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
