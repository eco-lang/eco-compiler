module PapSaturatePolyPipeMinimalTest exposing (main)

{-| Minimal reproduction of the papExtend saturated result type mismatch bug.

Trigger conditions (ALL required):
1. Polymorphic function with type variable in result position
2. Pipe operator |> (desugars to Basics.apR call)
3. Right side of pipe is a partial application of a 2+ arg function (e.g. Maybe.withDefault)

Root cause: MonoInlineSimplify inlines apR's body, but the inner MonoCall
retains its original monomorphized result type (CEcoValue) instead of being
updated to the concrete type (MInt) from the call site. This causes the
saturated papExtend to produce !eco.value instead of i64.

Without the pipe operator (using direct call syntax), the bug does not occur.
Without polymorphism (using concrete Int types), the bug does not occur.

See: Compiler/GlobalOpt/MonoInlineSimplify.elm tryInlineCall, exact application case.
-}

-- CHECK: result: 42

import Html exposing (text)


{-| Polymorphic function using pipe with Maybe.withDefault.
When monomorphized with a = Int, the pipe's intermediate result type
should be i64 but remains !eco.value due to the inlining bug.
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
