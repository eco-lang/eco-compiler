module UnboxWrapperNothingTest exposing (main)

{-| Checks that `Nothing` wrapped in a single-constructor type and taken out
again by pattern matching is still `Nothing`.

The unwrapped value is matched with `case`, where `Nothing` gives `-1`, the
expected output.

## eco

A one-constructor, one-field type gets `Can.Unbox` treatment
(compiler/src/Compiler/IR/Canonical.elm): no `Custom` is allocated and the
wrapper is the payload itself, with projections through `TypedPath.Unbox`
(compiler/src/Compiler/IR/DecisionTree/TypedPath.elm). See
plans/sum-type-wrapper-unboxing.md for where `Unbox` applies.

The payload here is `Nothing`, an embedded constant rather than a heap object,
so after `Unbox` elimination the projected value must not be dereferenced.
The `UnboxWrapper*` family was a regression canary for the number-defaulting
work (plans/number-quiescence-before-defaulting.md).

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
