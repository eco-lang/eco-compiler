module Compiler.Generate.MLIR.Backend exposing (backend, generateMlirModule)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.

@docs backend, generateMlirModule

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Functions as Functions
import Compiler.Generate.MLIR.Lambdas as Lambdas
import Compiler.Generate.MLIR.TypeTable as TypeTable
import Compiler.Generate.Mode as Mode
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
            generateProgram config.mode config.graph |> CodeGen.TextOutput
    }



-- ====== GENERATE WHOLE PROGRAM ======


{-| Generate an MlirModule directly, for use in invariant testing.
-}
generateMlirModule : Mode.Mode -> Mono.MonoGraph -> MlirModule
generateMlirModule mode monoGraph0 =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes }) =
            monoGraph0

        signatures : Dict.Dict Int Ctx.FuncSignature
        signatures =
            Ctx.buildSignatures nodes

        ctx : Ctx.Context
        ctx =
            Ctx.initContext mode registry signatures ctorShapes

        ( revOpChunks, ctxAfterNodes ) =
            EveryDict.foldl compare
                (\specId node ( accChunks, accCtx ) ->
                    let
                        ( nodeOps, newCtx ) =
                            Functions.generateNode accCtx specId node
                    in
                    ( nodeOps :: accChunks, newCtx )
                )
                ( [], ctx )
                nodes

        ops =
            List.concat (List.reverse revOpChunks)

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
                    ( declOp :: accOps, newCtx )
                )
                ( [], finalCtx )
                finalCtx.kernelDecls

        -- Generate the type table op for debug printing
        typeTableOp : MlirOp
        typeTableOp =
            TypeTable.generateTypeTable finalCtx
    in
    { body = typeTableOp :: List.reverse kernelDeclOps ++ lambdaOps ++ ops ++ mainOps
    , loc = Loc.unknown
    }


generateProgram : Mode.Mode -> Mono.MonoGraph -> String
generateProgram mode monoGraph =
    Pretty.ppModule (generateMlirModule mode monoGraph)
