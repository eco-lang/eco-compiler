module TestLogic.Type.PostSolve.KernelTypes exposing (expectKernelTypesValid)

{-| Gives tests a check on the kernel type environment that PostSolve
produces, the table from which typed optimization later takes the types of
kernel functions.

A kernel function is one referenced as `Elm.Kernel.Home.name` (or with the
`Eco` prefix). The kernel type environment is keyed by home module and
function name; `Compiler.Type.KernelTypes` owns it and `Compiler.Type.PostSolve`
builds it.

The check is much narrower than "kernel types are valid". It walks every
entry's type and reports each type variable whose name is the empty string,
labelled with the entry's `Home.name`. Any other type passes, including a bare
type variable, and a record's extension variable is not looked at. A module
that fails to canonicalize or type check fails with the pipeline's message.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Type.KernelTypes as KernelTypes
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through PostSolve and passes when no entry of the
resulting kernel type environment contains a type variable with an empty name.

It fails with one line per such variable outside a record's extension, or
with the pipeline's message when canonicalization or type checking fails.

-}
expectKernelTypesValid : Src.Module -> Expect.Expectation
expectKernelTypesValid srcModule =
    case Pipeline.runToPostSolve srcModule of
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


{-| Returns one message for each empty-named type variable, other than a
record's extension variable, in any entry of `kernelEnv`, each labelled with
the entry's `Home.name`.
-}
collectKernelTypeIssues : KernelTypes.KernelTypeEnv -> List String
collectKernelTypeIssues kernelEnv =
    Dict.foldl
        (\( moduleName, funcName ) canType acc ->
            let
                context =
                    moduleName ++ "." ++ funcName
            in
            checkKernelTypeWellFormed context canType ++ acc
        )
        []
        kernelEnv


{-| Returns one message for each type variable with an empty name inside
`canType`, each starting with `context`.

The label gains " arg" or " result" on entering either side of a function
type, and a dot and the field name on entering a record field; other nested
types keep the label they were given. A record's extension variable is not
examined. Nothing else about the type is checked.

-}
checkKernelTypeWellFormed : String -> Can.Type Name -> List String
checkKernelTypeWellFormed context canType =
    case canType of
        Can.TVar name ->
            if String.isEmpty name then
                [ context ++ ": Kernel type has empty type variable name" ]

            else
                []

        Can.TLambda _ argType resultType ->
            checkKernelTypeWellFormed (context ++ " arg") argType
                ++ checkKernelTypeWellFormed (context ++ " result") resultType

        Can.TType _ _ args ->
            List.concatMap (checkKernelTypeWellFormed context) args

        Can.TRecord fields _ ->
            Dict.foldl
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
