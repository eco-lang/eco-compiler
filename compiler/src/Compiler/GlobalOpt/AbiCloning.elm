module Compiler.GlobalOpt.AbiCloning exposing (abiCloningPass)

{-| ABI Cloning Pass

This pass ensures homogeneous closure parameters within each function specialization.
It analyzes closure-typed parameters in higher-order functions and clones functions
when a parameter receives closures with different capture ABIs at different call sites.

Algorithm:

1.  Traverse all call sites to collect capture ABIs for each closure-typed parameter
2.  If any parameter has multiple distinct capture ABIs, clone the function
3.  Rewrite call sites to target appropriate clones
4.  Iterate until fixed point


# API

@docs abiCloningPass

-}

import Compiler.AST.Monomorphized as Mono



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


{-| Run the ABI cloning pass on a MonoGraph.
Ensures each closure-typed parameter within a single function specialization
has at most one capture ABI across all call sites.

Currently a no-op — the collection/cloning phases are not yet implemented.
-}
abiCloningPass : Mono.MonoGraph -> Mono.MonoGraph
abiCloningPass graph =
    graph
