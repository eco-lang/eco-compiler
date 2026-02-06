module Compiler.GlobalOpt.MonoReturnArity exposing (computeReturnedClosureParamCount)

{-| Compute returned closure parameter count using normalized types.

After ABI normalization, we can rely on `Seg.stageArity` instead of
structural analysis of case/if branches.

@docs computeReturnedClosureParamCount

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Monomorphize.Segmentation as Seg
import Utils.Crash as Utils


{-| Compute how many parameters a returned closure takes (first stage only).

For closures, validates MONO\_016 and returns stage param count.
For other function-typed expressions, returns stage arity from type.
For non-function expressions, returns Nothing.

-}
computeReturnedClosureParamCount : Mono.MonoExpr -> Maybe Int
computeReturnedClosureParamCount expr =
    case expr of
        Mono.MonoClosure info _ closureType ->
            let
                stageParamCount =
                    List.length (Seg.stageParamTypes closureType)
            in
            if List.length info.params /= stageParamCount then
                Utils.crash
                    ("MonoReturnArity: MONO_016 violation: closure params="
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
                    Just (Seg.stageArity exprType)

                _ ->
                    Nothing
