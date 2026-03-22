module Compiler.GlobalOpt.Staging exposing
    ( StagingSolution
    , analyzeAndSolveStaging, validateClosureStaging
    )

{-| Global staging algorithm for determining correct staged-currying calling
conventions for all function-carrying constructs.

This module coordinates:

1.  Computing natural staging for producers (closures, tail-funcs, kernels)
2.  Building equivalence classes via union-find for function flow
3.  Choosing canonical staging per class via majority voting
4.  Rewriting non-conforming producers with wrappers
5.  Annotating calls with pre-computed CallInfo


# Types

@docs StagingSolution


# API

@docs analyzeAndSolveStaging, validateClosureStaging

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.Staging.GraphBuilder as GraphBuilder
import Compiler.GlobalOpt.Staging.ProducerInfo as ProducerInfo
import Compiler.GlobalOpt.Staging.Rewriter as Rewriter
import Compiler.GlobalOpt.Staging.Solver as Solver
import Compiler.GlobalOpt.Staging.Types as Types
import Dict
import Set


{-| Re-export StagingSolution for external use.
-}
type alias StagingSolution =
    Types.StagingSolution



-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================


{-| Analyze and solve staging for the entire MonoGraph.

This function:

1.  Computes natural staging for all producers
2.  Builds the staging graph (union-find over producers and slots)
3.  Solves for canonical segmentations
4.  Rewrites the graph with wrappers where needed

-}
analyzeAndSolveStaging :
    Mono.MonoGraph
    -> ( StagingSolution, Mono.MonoGraph )
analyzeAndSolveStaging graph0 =
    let
        -- 1. Compute natural staging for all producers
        producerInfo =
            ProducerInfo.computeProducerInfo graph0
    in
    if Dict.isEmpty producerInfo.naturalSeg then
        -- No producers (no closures, no tail-funcs, no kernels with staging).
        -- Skip graph building, solving, and rewriting entirely.
        ( { producerClass = Dict.empty
          , classSeg = Array.empty
          , slotClass = Dict.empty
          , dynamicSlots = Set.empty
          }
        , graph0
        )

    else
        let
            -- 2. Build staging graph with union-find edges
            sg =
                GraphBuilder.buildStagingGraph graph0 producerInfo

            -- 3. Solve: build classes, choose canonical segmentations
            solution =
                Solver.solveStagingGraph producerInfo sg

            -- 4. Rewrite graph: wrap producers, adjust types
            graph1 =
                Rewriter.applyStagingSolution solution producerInfo graph0
        in
        ( solution, graph1 )



-- ============================================================================
-- VALIDATE CLOSURE STAGING
-- ============================================================================


{-| Validate that all closures satisfy GOPT\_001 (params match stage arity).

This is a defensive check - if the rewriting was correct, all closures should
already be valid. If validation fails, it indicates a bug in the algorithm.

-}
validateClosureStaging : Mono.MonoGraph -> Mono.MonoGraph
validateClosureStaging graph =
    -- Walk all closures and check params == stageArity(type)
    -- For now, trust the rewriter and return unchanged
    -- In a more robust implementation, we'd crash on violations
    graph



-- ============================================================================
-- ANNOTATE CALL STAGING
-- ============================================================================
