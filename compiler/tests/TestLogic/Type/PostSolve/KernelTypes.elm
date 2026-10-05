module TestLogic.Type.PostSolve.KernelTypes exposing (expectKernelTypesValid)

{-| Gives tests a check on the kernel type environment that PostSolve
produces, the table from which typed optimization later takes the types of
kernel functions (POST\_002).

A kernel function is one referenced as `Elm.Kernel.Home.name` (or with the
`Eco` prefix). The kernel type environment is keyed by home module and
function name; `Compiler.Type.KernelTypes` owns it and `Compiler.Type.PostSolve`
builds it, recording for each kernel the type of its first usage.

`expectKernelTypesValid` runs a module through PostSolve and looks at every
call whose function is a kernel reference. Such a call is a usage PostSolve
records a type from, so the environment must have an entry for the kernel, and
the kernel reference's node type after PostSolve must be exactly that entry.
A module with no direct kernel call fails, since there would be nothing to
check. A module that fails to canonicalize or type check fails with the
pipeline's message.

Not checked: kernel references that are not the function of a call, and
whether an entry agrees with the kernel's real type.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Expect
import TestLogic.TestPipeline as Pipeline
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| Runs `srcModule` through PostSolve and passes when it calls at least one
kernel function directly and every such call's kernel has an entry in the
kernel type environment equal to the kernel reference's node type.

It fails with one line per problem, or with the pipeline's message when
canonicalization or type checking fails.

-}
expectKernelTypesValid : Src.Module -> Expect.Expectation
expectKernelTypesValid srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                kernelCalls =
                    Helpers.walkExprs result.canonical
                        |> List.filterMap
                            (\exprNode ->
                                case exprNode.node of
                                    Can.Call (A.At _ funcInfo) _ ->
                                        case funcInfo.node of
                                            Can.VarKernel _ home name ->
                                                Just ( funcInfo.id, home, name )

                                            _ ->
                                                Nothing

                                    _ ->
                                        Nothing
                            )

                issues =
                    List.filterMap (checkKernelCall result.kernelEnv result.nodeTypesPost) kernelCalls
            in
            if List.isEmpty kernelCalls then
                Expect.fail "The program calls no kernel function, so there is nothing to check"

            else if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| Returns a description of what is wrong with one direct kernel call, whose
function is the kernel reference with node id `funcId` to `home.name`, or
`Nothing`.
-}
checkKernelCall : KernelTypes.KernelTypeEnv -> Array.Array (Maybe (Can.Type Name)) -> ( Int, Name, Name ) -> Maybe String
checkKernelCall kernelEnv nodeTypesPost ( funcId, home, name ) =
    let
        label =
            home ++ "." ++ name ++ " (node " ++ String.fromInt funcId ++ "): "
    in
    case KernelTypes.lookup home name kernelEnv of
        Nothing ->
            Just (label ++ "no entry in the kernel type environment")

        Just entry ->
            case Array.get funcId nodeTypesPost |> Maybe.andThen identity of
                Just nodeType ->
                    if nodeType == entry then
                        Nothing

                    else
                        Just (label ++ "node type " ++ Debug.toString nodeType ++ " differs from the entry " ++ Debug.toString entry)

                Nothing ->
                    Just (label ++ "the kernel reference has no node type")
