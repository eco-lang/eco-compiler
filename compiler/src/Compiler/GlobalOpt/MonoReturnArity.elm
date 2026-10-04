module Compiler.GlobalOpt.MonoReturnArity exposing (collectStageArities)

{-| The passes after monomorphization need one agreed reading of a function
type as a list of stage arities, and this module supplies it.

A function type is a chain of `MFunction` stages, each taking one or more
arguments at once, as `Compiler.AST.Monomorphized` describes. The _stage
arity_ of a stage is how many arguments it takes, and the list of stage
arities, outermost first, is what that module calls the type's
segmentation. Code that applies a function stage by stage uses this list to
decide where the arguments of one stage end and the next begin.

@docs collectStageArities

-}

import Compiler.AST.Monomorphized as Mono


{-| Returns the stage arities of `monoType`, outermost stage first, or `[]` when
it is not a function type.

The type's stages are read as they stand, without regrouping. So
`MFunction [ a, b ] (MFunction [ c ] r)` gives `[ 2, 1 ]`, while a curried
`Int -> Int -> Int` gives `[ 1, 1 ]` only while it is still one argument per
stage; once regrouped into `MFunction [ Int, Int ] Int` it gives `[ 2 ]`.

-}
collectStageArities : Mono.MonoType -> List Int
collectStageArities monoType =
    case monoType of
        Mono.MFunction _ _ paramTypes resultType ->
            List.length paramTypes :: collectStageArities resultType

        _ ->
            []
