module Compiler.GlobalOpt.MonoReturnArity exposing
    ( collectStageArities
    )

{-| Compute stage arities for multi-stage closures.

For multi-stage closures (closures that return closures), we track
the sequence of stage arities so applyByStages can correctly handle each
stage boundary.

@docs collectStageArities

-}

import Compiler.AST.Monomorphized as Mono


{-| Compute the sequence of stage arities for a function type.

For a type like Int -> Int -> Int:

  - First stage takes 1 arg (returns Int -> Int)
  - Second stage takes 1 arg (returns Int)
  - Result: [1, 1]

For a type like Int -> Int:

  - Single stage takes 1 arg (returns Int)
  - Result: [1]

For a non-function type, returns [].

-}
collectStageArities : Mono.MonoType -> List Int
collectStageArities monoType =
    case monoType of
        Mono.MFunction paramTypes resultType ->
            List.length paramTypes :: collectStageArities resultType

        _ ->
            []
