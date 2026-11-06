module CompilerIssue1964AnnotatedPolymorphicRecursionWrapperTest exposing (..)

{-| A recursive call at a wrapped type argument is rejected despite the annotation.

<https://github.com/elm/compiler/issues/1964>

`depth : Nested a -> Int` is annotated, so the recursive call at `Nested (Wrapper a)` is
well-typed (polymorphic recursion with an annotation). Elm 0.19.1 reports a type mismatch
(`Nested (Wrapper a)` vs `Nested a`).

-}

-- CHECK: depth: 2

import Html exposing (text)


type Nested a
    = Nested (Nested (Wrapper a))
    | Leaf a


type Wrapper a
    = Wrapper a


depth : Nested a -> Int
depth thing =
    case thing of
        Nested inner ->
            1 + depth inner

        Leaf _ ->
            0


value : Nested ()
value =
    Nested (Nested (Leaf (Wrapper (Wrapper ()))))


main =
    let
        _ =
            Debug.log "depth" (depth value)
    in
    text "done"
