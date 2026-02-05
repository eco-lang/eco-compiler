module Compiler.Generate.MLIR.Backend exposing (backend, generateMlirModule)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.

@docs backend, generateMlirModule

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Functions as Functions
import Compiler.Generate.MLIR.Lambdas as Lambdas
import Compiler.Generate.MLIR.TypeTable as TypeTable
import Compiler.Generate.Mode as Mode
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Data.Map as EveryDict
import Dict
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Mlir.Pretty as Pretty



-- ====== BACKEND ======


{-| The MLIR backend that generates MLIR code from fully monomorphized IR with all polymorphism resolved.
-}
backend : CodeGen.MonoCodeGen
backend =
    { generate =
        \config ->
            generateProgram config.mode config.typeEnv config.graph |> CodeGen.TextOutput
    }



-- ====== GENERATE WHOLE PROGRAM ======


{-| Generate an MlirModule directly, for use in invariant testing.
-}
generateMlirModule : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> MlirModule
generateMlirModule mode typeEnv monoGraph0 =
    let
        -- Run the Mono IR optimizer before MLIR generation
        --( Mono.MonoGraph { nodes, main, registry, ctorShapes }, _ ) =
        --    MonoInlineSimplify.optimize mode typeEnv monoGraph0
        (Mono.MonoGraph { nodes, main, registry, ctorShapes, returnedClosureParamCounts }) =
            monoGraph0

        -- Convert Data.Map -> Elm Dict for returnedClosureParamCounts
        returnedCounts : Dict.Dict Int (Maybe Int)
        returnedCounts =
            EveryDict.foldl compare
                (\specId maybeCount acc ->
                    Dict.insert specId maybeCount acc
                )
                Dict.empty
                returnedClosureParamCounts

        signatures : Dict.Dict Int Ctx.FuncSignature
        signatures =
            Ctx.buildSignatures nodes returnedCounts

        ctx : Ctx.Context
        ctx =
            Ctx.initContext mode registry signatures ctorShapes

        ( ops, ctxAfterNodes ) =
            EveryDict.foldl compare
                (\specId node ( accOps, accCtx ) ->
                    let
                        ( op, newCtx ) =
                            Functions.generateNode accCtx specId node
                    in
                    ( accOps ++ [ op ], newCtx )
                )
                ( [], ctx )
                nodes

        ( lambdaOps, finalCtx ) =
            Lambdas.processLambdas ctxAfterNodes

        -- ctorShapes are already complete from MonoGraph - no fill step needed
        mainOps : List MlirOp
        mainOps =
            case main of
                Just mainInfo ->
                    Functions.generateMainEntry finalCtx mainInfo

                Nothing ->
                    []

        -- Generate kernel function declarations from tracked calls
        ( kernelDeclOps, _ ) =
            Dict.foldl
                (\name sig ( accOps, accCtx ) ->
                    let
                        ( newCtx, declOp ) =
                            Functions.generateKernelDecl accCtx name sig
                    in
                    ( accOps ++ [ declOp ], newCtx )
                )
                ( [], finalCtx )
                finalCtx.kernelDecls

        -- Generate the type table op for debug printing
        typeTableOp : MlirOp
        typeTableOp =
            TypeTable.generateTypeTable finalCtx
    in
    { body = typeTableOp :: kernelDeclOps ++ lambdaOps ++ ops ++ mainOps
    , loc = Loc.unknown
    }


generateProgram : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> String
generateProgram mode typeEnv monoGraph =
    Pretty.ppModule (generateMlirModule mode typeEnv monoGraph)
