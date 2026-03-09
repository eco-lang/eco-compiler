module Compiler.Generate.MLIR.Backend exposing (backend, generateMlirModule, streamMlirToWriter)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.

@docs backend, generateMlirModule, streamMlirToWriter

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
import Task exposing (Task)



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


-- ====== STREAMING ======


streamMlirToWriter :
    Mode.Mode
    -> Mono.MonoGraph
    -> (String -> Task Never ())
    -> Task Never ()
streamMlirToWriter mode monoGraph0 writeChunk =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes }) =
            monoGraph0

        signatures =
            Ctx.buildSignatures nodes

        ctx =
            Ctx.initContext mode registry signatures ctorShapes
    in
    -- 1. Header
    writeChunk Pretty.ppModuleHeader
        |> Task.andThen (\_ -> streamNodes ctx nodes writeChunk)
        |> Task.andThen
            (\ctxAfterNodes ->
                -- 2. Lambdas
                let
                    ( lambdaOps, finalCtx ) =
                        Lambdas.processLambdas ctxAfterNodes
                in
                writeOps lambdaOps writeChunk
                    |> Task.andThen
                        (\_ ->
                            -- 3. Main
                            let
                                mainOps =
                                    case main of
                                        Just mainInfo ->
                                            Functions.generateMainEntry finalCtx mainInfo

                                        Nothing ->
                                            []
                            in
                            writeOps mainOps writeChunk
                                |> Task.andThen
                                    (\_ ->
                                        -- 4. Kernel decls
                                        let
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
                                        in
                                        writeOps (List.reverse kernelDeclOps) writeChunk
                                            |> Task.andThen
                                                (\_ ->
                                                    -- 5. Type table
                                                    let
                                                        typeTableOp =
                                                            TypeTable.generateTypeTable finalCtx
                                                    in
                                                    writeOps [ typeTableOp ] writeChunk
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\_ ->
                            -- 6. Footer
                            writeChunk (Pretty.ppModuleFooter Loc.unknown)
                        )
            )


streamNodes :
    Ctx.Context
    -> EveryDict.Dict Int Int Mono.MonoNode
    -> (String -> Task Never ())
    -> Task Never Ctx.Context
streamNodes ctx0 nodes writeChunk =
    EveryDict.foldl compare
        (\specId node accTask ->
            accTask
                |> Task.andThen
                    (\accCtx ->
                        let
                            ( nodeOps, newCtx ) =
                                Functions.generateNode accCtx specId node
                        in
                        writeOps nodeOps writeChunk
                            |> Task.map (\_ -> newCtx)
                    )
        )
        (Task.succeed ctx0)
        nodes


writeOps : List MlirOp -> (String -> Task Never ()) -> Task Never ()
writeOps ops writeChunk =
    case ops of
        [] ->
            Task.succeed ()

        _ ->
            writeChunk (ops |> List.map Pretty.ppTopLevelOp |> String.concat)
