module Compiler.Generate.MLIR.Backend exposing (backend, generateMlirModule, streamMlirBytecode, streamMlirToWriter, writeMlirBytecode)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.

@docs backend, generateMlirModule, streamMlirToWriter, writeMlirBytecode, streamMlirBytecode

-}

import Array exposing (Array)
import Bytes exposing (Bytes)
import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Functions as Functions
import Compiler.Generate.MLIR.Lambdas as Lambdas
import Compiler.Generate.MLIR.TypeTable as TypeTable
import Compiler.Generate.Mode as Mode
import Dict
import Eco.File
import Mlir.Bytecode.Encode as BytecodeEncode
import Mlir.Bytecode.StreamEncode as StreamEncode
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Mlir.Pretty as Pretty
import Set
import System.IO as SysIO
import Task exposing (Task)
import Utils.Main as Utils
import Utils.Task.Extra as TaskExtra



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

        ( revOpChunks, ctxAfterNodes, _ ) =
            Array.foldl
                (\maybeNode ( accChunks, accCtx, specId ) ->
                    case maybeNode of
                        Nothing ->
                            ( accChunks, accCtx, specId + 1 )

                        Just node ->
                            let
                                ( nodeOps, newCtx ) =
                                    Functions.generateNode accCtx specId node
                            in
                            ( nodeOps :: accChunks, newCtx, specId + 1 )
                )
                ( [], ctx, 0 )
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
    { body = lambdaOps ++ ops ++ mainOps ++ List.reverse kernelDeclOps ++ [ typeTableOp ]
    , loc = Loc.unknown
    }


generateProgram : Mode.Mode -> Mono.MonoGraph -> String
generateProgram mode monoGraph =
    Pretty.ppModule (generateMlirModule mode monoGraph)



-- ====== STREAMING ======


{-| Stream MLIR text output to a writer function, emitting the module header,
each top-level operation, and footer sequentially.
-}
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

        stderrLog msg =
            TaskExtra.io (SysIO.writeLn SysIO.stderr msg)
    in
    -- Convert nodes to indexed list so the Array can be GC'd during streaming.
    -- List.foldl releases consumed cons cells, allowing processed nodes to be collected.
    let
        nodesList =
            Array.toIndexedList nodes
    in
    -- 1. Header
    writeChunk Pretty.ppModuleHeader
        |> Task.andThen (\_ -> stderrLog "  Generate node functions (streaming)...")
        |> Task.andThen (\_ -> streamNodesList ctx nodesList writeChunk)
        |> Task.andThen
            (\ctxAfterNodes ->
                -- 2. Lambdas
                stderrLog "  Process lambda closures (streaming)..."
                    |> Task.andThen
                        (\_ ->
                            let
                                ( lambdaOps, finalCtx ) =
                                    Lambdas.processLambdas ctxAfterNodes
                            in
                            writeOps lambdaOps writeChunk
                                |> Task.andThen
                                    (\_ ->
                                        -- 3. Main + kernel decls + type table
                                        stderrLog "  Generate main + kernel decls + type table (streaming)..."
                                            |> Task.andThen
                                                (\_ ->
                                                    let
                                                        mainOps =
                                                            case main of
                                                                Just mainInfo ->
                                                                    Functions.generateMainEntry finalCtx mainInfo

                                                                Nothing ->
                                                                    []

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

                                                        typeTableOp =
                                                            TypeTable.generateTypeTable finalCtx
                                                    in
                                                    writeOps mainOps writeChunk
                                                        |> Task.andThen (\_ -> writeOps (List.reverse kernelDeclOps) writeChunk)
                                                        |> Task.andThen (\_ -> writeOps [ typeTableOp ] writeChunk)
                                                )
                                    )
                        )
                    |> Task.andThen
                        (\_ ->
                            -- 4. Footer
                            writeChunk (Pretty.ppModuleFooter Loc.unknown)
                        )
            )


streamNodesList :
    Ctx.Context
    -> List ( Int, Maybe Mono.MonoNode )
    -> (String -> Task Never ())
    -> Task Never Ctx.Context
streamNodesList ctx0 remaining writeChunk =
    case remaining of
        [] ->
            Task.succeed ctx0

        ( _, Nothing ) :: rest ->
            -- Empty slot
            streamNodesList ctx0 rest writeChunk

        ( specId, Just node ) :: rest ->
            let
                ( nodeOps, newCtx ) =
                    Functions.generateNode ctx0 specId node

                -- Clear per-function fields to avoid accumulating across nodes.
                -- decoderExprs caches let-bound decoder expressions for BytesFusion;
                -- externBoxedVars tracks extern/kernel aliases — both are function-local.
                cleanCtx =
                    { newCtx
                        | decoderExprs = Dict.empty
                        , externBoxedVars = Set.empty
                    }
            in
            writeOps nodeOps writeChunk
                |> Task.andThen (\_ -> streamNodesList cleanCtx rest writeChunk)


writeOps : List MlirOp -> (String -> Task Never ()) -> Task Never ()
writeOps ops writeChunk =
    case ops of
        [] ->
            Task.succeed ()

        [ single ] ->
            writeChunk (Pretty.ppTopLevelOp single)

        _ ->
            writeChunk (ops |> List.map Pretty.ppTopLevelOp |> String.concat)



-- ====== BYTECODE OUTPUT ======


{-| Generate MLIR bytecode and write it to a file.
Builds the full MlirModule in memory, encodes to bytecode, then writes.
-}
writeMlirBytecode :
    Mode.Mode
    -> Mono.MonoGraph
    -> String
    -> Task Never ()
writeMlirBytecode mode monoGraph target =
    let
        mlirModule =
            generateMlirModule mode monoGraph

        bytecodeBytes =
            BytecodeEncode.encodeModule mlirModule
    in
    Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
        |> Task.andThen (\_ -> Eco.File.writeBytes target bytecodeBytes)


{-| Generate MLIR bytecode using the streaming encoder.
Processes funcs one at a time via Task chaining so the GC can reclaim
each func's MlirOps before the next is generated. Peak memory is
dominated by tables + the largest single func rather than all funcs.
-}
streamMlirBytecode :
    Mode.Mode
    -> Mono.MonoGraph
    -> String
    -> Task Never ()
streamMlirBytecode mode monoGraph0 target =
    let
        (Mono.MonoGraph { nodes, main, registry, ctorShapes }) =
            monoGraph0

        signatures =
            Ctx.buildSignatures nodes

        ctx =
            Ctx.initContext mode registry signatures ctorShapes

        nodesList =
            Array.toIndexedList nodes

        initTables =
            StreamEncode.emptyStreamTables
    in
    -- Phase 1: Stream node functions — collect tables + encode per func
    streamNodesCollectEncode ctx nodesList initTables
        |> Task.andThen
            (\( ctxAfterNodes, tablesAfterNodes ) ->
                let
                    -- Process lambdas
                    ( lambdaOps, finalCtx ) =
                        Lambdas.processLambdas ctxAfterNodes

                    tablesAfterLambdas =
                        StreamEncode.collectAndEncodeOps lambdaOps tablesAfterNodes

                    -- Main entry
                    mainOps =
                        case main of
                            Just mainInfo ->
                                Functions.generateMainEntry finalCtx mainInfo

                            Nothing ->
                                []

                    tablesAfterMain =
                        StreamEncode.collectAndEncodeOps mainOps tablesAfterLambdas

                    -- Kernel declarations
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

                    tablesAfterKernels =
                        StreamEncode.collectAndEncodeOps (List.reverse kernelDeclOps) tablesAfterMain

                    -- Type table
                    typeTableOp =
                        TypeTable.generateTypeTable finalCtx

                    finalTables =
                        StreamEncode.collectAndEncodeOps [ typeTableOp ] tablesAfterKernels

                    -- Assemble final bytecode
                    bytecodeBytes =
                        StreamEncode.assembleModule finalTables Loc.unknown
                in
                Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
                    |> Task.andThen (\_ -> Eco.File.writeBytes target bytecodeBytes)
            )


{-| Stream through nodes, collecting into tables and encoding each func's ops.
Uses Task.andThen chaining so the runtime can GC each func's MlirOps
before processing the next.
-}
streamNodesCollectEncode :
    Ctx.Context
    -> List ( Int, Maybe Mono.MonoNode )
    -> StreamEncode.StreamTables
    -> Task Never ( Ctx.Context, StreamEncode.StreamTables )
streamNodesCollectEncode ctx0 remaining tables =
    case remaining of
        [] ->
            Task.succeed ( ctx0, tables )

        ( _, Nothing ) :: rest ->
            streamNodesCollectEncode ctx0 rest tables

        ( specId, Just node ) :: rest ->
            let
                ( nodeOps, newCtx ) =
                    Functions.generateNode ctx0 specId node

                cleanCtx =
                    { newCtx
                        | decoderExprs = Dict.empty
                        , externBoxedVars = Set.empty
                    }

                newTables =
                    StreamEncode.collectAndEncodeOps nodeOps tables
            in
            Task.succeed ()
                |> Task.andThen (\_ -> streamNodesCollectEncode cleanCtx rest newTables)
