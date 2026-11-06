module UnboxWrapperUnitTest exposing (main)

{-| A single-constructor custom type can wrap the unit value `()`, and pattern
matching on the constructor in a function argument gives the `()` back.

`unwrap (Wrap ())` is logged, so the expected output is `result: ()`.

## eco

A one-constructor, one-field type gets `Can.Unbox` treatment
(compiler/src/Compiler/IR/Canonical.elm): no `Custom` is allocated and the
wrapper is the payload itself, with projections through `TypedPath.Unbox`
(compiler/src/Compiler/IR/DecisionTree/TypedPath.elm). See
plans/sum-type-wrapper-unboxing.md for where `Unbox` applies.

The payload here is Unit, an embedded constant rather than a heap object,
so after `Unbox` elimination the projected value must not be dereferenced.
The `UnboxWrapper*` family was a regression canary for the number-defaulting
work (plans/number-quiescence-before-defaulting.md).

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
