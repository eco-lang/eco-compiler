module PapSaturatePolyPipeMinimalTest exposing (main)

{-| Tests a polymorphic function that pipes a `Maybe` into a partially
applied `Maybe.withDefault`, called at type `Int`.

`polyWithDefault 0 (Just 42)` evaluates `Just 42 |> Maybe.withDefault 0`,
which is 42.

## eco

Minimal reproduction of a saturated `papExtend` result-type mismatch. All of
these were needed: a polymorphic result type, the pipe `|>` (a `Basics.apR`
call), and a partial application of a function of two or more arguments on
its right. The post-monomorphization inliner
(compiler/src/Compiler/MonoOpt/InlineSimplify.elm) inlined `apR`'s body but the
inner call kept its monomorphized result type `!eco.value` instead of the call
site's `i64`, so the saturated `papExtend` produced the wrong type. A direct
call, or concrete `Int` types, did not trigger it.

-}

-- CHECK: result: 42

import Html exposing (text)


{-| Returns the value inside `mx`, or `default` when it is `Nothing`.
-}
polyWithDefault : a -> Maybe a -> a
polyWithDefault default mx =
    mx |> Maybe.withDefault default


main =
    let
        result = polyWithDefault 0 (Just 42)
        _ = Debug.log "result" result
    in
    text (String.fromInt result)
