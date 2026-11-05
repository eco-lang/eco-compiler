module Compiler.GenerateMlir.BackendModule exposing (generateMlirModule, generateProgram, ppModule)

{-| Builds a whole program's MLIR in memory, for tests that inspect the ops or
the printed text of a module rather than a file.

The compiler only streams its module (`Compiler.GenerateMlir.Backend`); these
helpers assemble the same ops from the same pieces (`Backend.buildContext`,
`Backend.generateNodeOps` and `Backend.generateTrailer`), except that the
lifted lambdas come first, before the nodes.

-}

import Array
import Compiler.Config as Config
import Compiler.GenerateMlir.Backend as Backend
import Compiler.IR.Mono as Mono
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirModule)
import Mlir.Pretty as Pretty


{-| Generates the whole program as one `MlirModule`: the lambdas, then every
node in SpecId order, then the main entry, the kernel declarations and the
type table.
-}
generateMlirModule : Config.EcoConfig -> Mono.MonoGraph -> MlirModule
generateMlirModule ecoConfig monoGraph =
    let
        (Mono.MonoGraph { nodes, main, ports, flagsDecoder }) =
            monoGraph

        ( revOpChunks, ctxAfterNodes, _ ) =
            Array.foldl
                (\maybeNode ( accChunks, accCtx, specId ) ->
                    case maybeNode of
                        Nothing ->
                            ( accChunks, accCtx, specId + 1 )

                        Just node ->
                            let
                                ( nodeOps, newCtx ) =
                                    Backend.generateNodeOps accCtx specId node
                            in
                            ( nodeOps :: accChunks, newCtx, specId + 1 )
                )
                ( [], Backend.buildContext ecoConfig monoGraph, 0 )
                nodes

        trailer =
            Backend.generateTrailer main ports flagsDecoder ctxAfterNodes
    in
    { body =
        trailer.lambdaOps
            ++ List.concat (List.reverse revOpChunks)
            ++ trailer.mainOps
            ++ trailer.kernelDeclOps
            ++ [ trailer.typeTableOp ]
    , loc = Loc.unknown
    }


{-| Returns the printed text of the module `generateMlirModule` builds.
-}
generateProgram : Config.EcoConfig -> Mono.MonoGraph -> String
generateProgram ecoConfig monoGraph =
    ppModule (generateMlirModule ecoConfig monoGraph)


{-| Returns the text of a whole module as the compiler streams it:
`Pretty.ppModuleHeader`, each top-level operation as `Pretty.ppTopLevelOp`
prints it, then `Pretty.ppModuleFooter`.
-}
ppModule : MlirModule -> String
ppModule m =
    Pretty.ppModuleHeader ++ String.concat (List.map Pretty.ppTopLevelOp m.body) ++ Pretty.ppModuleFooter
