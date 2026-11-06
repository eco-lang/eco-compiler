module UnboxWrapperTrueFalseTest exposing (main)

{-| Checks that `True` and `False`, each wrapped in a single-constructor type and
taken out again by pattern matching, keep their values.

## eco

A one-constructor, one-field type gets `Can.Unbox` treatment
(compiler/src/Compiler/IR/Canonical.elm): no `Custom` is allocated and the
wrapper is the payload itself, with projections through `TypedPath.Unbox`
(compiler/src/Compiler/IR/DecisionTree/TypedPath.elm). See
plans/sum-type-wrapper-unboxing.md for where `Unbox` applies.

The payload here is `True` or `False`; Bool is always a boxed `!eco.value` in heap storage, an embedded constant rather than a heap object,
so after `Unbox` elimination the projected value must not be dereferenced.
The `UnboxWrapper*` family was a regression canary for the number-defaulting
work (plans/number-quiescence-before-defaulting.md).

-}

-- CHECK: r1: True
-- CHECK: r2: False

import Html exposing (text)


type Wrapper a
    = Wrap a


unwrap : Wrapper a -> a
unwrap (Wrap x) =
    x


main =
    let
        r1 =
            unwrap (Wrap True)

        r2 =
            unwrap (Wrap False)

        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
