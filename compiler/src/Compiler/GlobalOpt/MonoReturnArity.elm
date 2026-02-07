module Compiler.GlobalOpt.MonoReturnArity exposing
    ( computeReturnedClosureParamCount
    , collectStageArities
    )

{-| Compute returned closure parameter count using normalized types.

For multi-stage closures (closures that return closures), we track
the sequence of stage arities so applyByStages can correctly handle each
stage boundary.

@docs computeReturnedClosureParamCount, collectStageArities

-}

import Compiler.AST.Monomorphized as Mono
import Utils.Crash as Utils


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


{-| Compute how many parameters a returned closure takes (first stage only).

For closures, validates GOPT\_016 (stage params match closure params) and returns
the first-stage parameter count.
For other function-typed expressions, returns stage arity from type.
For non-function expressions, returns Nothing.

NOTE: This returns the first stage arity. For multi-stage closures, use
collectStageArities to get the full sequence.

-}
computeReturnedClosureParamCount : Mono.MonoExpr -> Maybe Int
computeReturnedClosureParamCount expr =
    case expr of
        Mono.MonoClosure info _ closureType ->
            let
                stageParamCount =
                    List.length (Mono.stageParamTypes closureType)
            in
            if List.length info.params /= stageParamCount then
                Utils.crash
                    ("MonoReturnArity: GOPT_001 violation: closure params="
                        ++ String.fromInt (List.length info.params)
                        ++ ", stage arity="
                        ++ String.fromInt stageParamCount
                    )

            else
                Just stageParamCount

        _ ->
            let
                exprType =
                    Mono.typeOf expr
            in
            case exprType of
                Mono.MFunction _ _ ->
                    Just (Mono.stageArity exprType)

                _ ->
                    Nothing
