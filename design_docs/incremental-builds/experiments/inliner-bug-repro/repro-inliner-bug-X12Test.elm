module X12Test exposing (main)

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.GlobalOpt.IncCensus as IncCensus
import Dict
import System.Exit as Exit
import System.IO as IO
import Task


graph : Mono.MonoGraph
graph =
    Mono.MonoGraph
        { nodes = Array.empty
        , main = Nothing
        , registry = { nextId = 0, mapping = Mono.specKeyMapEmpty, reverseMapping = Array.empty, countByGlobal = Dict.empty }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 0
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        }


main : IO.Program
main =
    IO.run
        (IO.writeLn IO.stdout (IncCensus.render Dict.empty graph ++ IncCensus.polyGlobals TOpt.emptyGlobalGraph)
            |> Task.andThen (\() -> Exit.exitSuccess)
        )
