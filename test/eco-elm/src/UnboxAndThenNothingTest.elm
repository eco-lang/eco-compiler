module UnboxAndThenNothingTest exposing (main)

{-| Checks `andThen`-style chaining on a single-constructor wrapper type whose
wrapped value is `Nothing`.

`pure Nothing` is passed to a callback that maps `Nothing` to `pure 42`, then
through a second `andThen` that adds 0, and the result is unwrapped with a
lambda that destructures `Wrap`. The expected output is `42`.

## eco

A one-constructor, one-field type gets `Can.Unbox` treatment
(compiler/src/Compiler/IR/Canonical.elm): no `Custom` is allocated and the
wrapper is the payload itself, with projections through `TypedPath.Unbox`
(compiler/src/Compiler/IR/DecisionTree/TypedPath.elm). See
plans/sum-type-wrapper-unboxing.md for where `Unbox` applies.

This test mirrors the `Decoder.andThen` chaining that crashed the compiler
during the bootstrap self-compile: the unwrapped payload is `Nothing`, an
embedded constant rather than a heap object, so code that dereferenced the
projected field as a heap pointer failed.

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
