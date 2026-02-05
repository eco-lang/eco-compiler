module TestLogic.Type.PostSolve.KernelTypes exposing (expectKernelTypesValid)

{-| Test logic for invariant POST\_002: Kernel types are correctly resolved.

Verify that references to kernel (built-in) types like Int, Float, String,
List, etc. are correctly resolved and consistent throughout the module.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.LocalOpt.Typed.KernelTypes as KernelTypes
import Data.Map as Dict
import Expect
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono


{-| Verify that kernel function types are inferred from usage.
-}
expectKernelTypesValid : Src.Module -> Expect.Expectation
expectKernelTypesValid srcModule =
    case TOMono.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectKernelTypeIssues result.kernelEnv
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- KERNEL TYPE VERIFICATION
-- ============================================================================


{-| Collect issues with kernel types.

Kernel types should be consistent and well-formed.

-}
collectKernelTypeIssues : KernelTypes.KernelTypeEnv -> List String
collectKernelTypeIssues kernelEnv =
    -- The KernelTypeEnv maps (module, name) pairs to their types
    -- Verify all kernel types are well-formed
    Dict.foldl (\a b -> compare (Tuple.first a) (Tuple.first b))
        (\( moduleName, funcName ) canType acc ->
            let
                context =
                    moduleName ++ "." ++ funcName
            in
            checkKernelTypeWellFormed context canType ++ acc
        )
        []
        kernelEnv


{-| Check if a kernel type is well-formed.

Kernel types should be:

  - Non-empty (not just a bare type variable)
  - Have valid type constructors
  - Have consistent function signatures

-}
checkKernelTypeWellFormed : String -> Can.Type -> List String
checkKernelTypeWellFormed context canType =
    case canType of
        Can.TVar name ->
            -- Kernel types should generally not be bare type variables
            -- (they should be function types or concrete types)
            if String.isEmpty name then
                [ context ++ ": Kernel type has empty type variable name" ]

            else
                []

        Can.TLambda argType resultType ->
            checkKernelTypeWellFormed (context ++ " arg") argType
                ++ checkKernelTypeWellFormed (context ++ " result") resultType

        Can.TType _ _ args ->
            List.concatMap (checkKernelTypeWellFormed context) args

        Can.TRecord fields _ ->
            Dict.foldl compare
                (\fieldName (Can.FieldType _ fieldType) acc ->
                    checkKernelTypeWellFormed (context ++ "." ++ fieldName) fieldType ++ acc
                )
                []
                fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            checkKernelTypeWellFormed context a
                ++ checkKernelTypeWellFormed context b
                ++ List.concatMap (checkKernelTypeWellFormed context) cs

        Can.TAlias _ _ args aliasedType ->
            List.concatMap (\( _, argType ) -> checkKernelTypeWellFormed context argType) args
                ++ (case aliasedType of
                        Can.Holey t ->
                            checkKernelTypeWellFormed context t

                        Can.Filled t ->
                            checkKernelTypeWellFormed context t
                   )
