module Compiler.Type.Constrain.Erased.Module exposing (constrain)

{-| Constraint generation for the erased (type-check-only) pathway.

The erased and typed pathways used to be two separate, near-identical
generators. They are now a single generator (`Compiler.Type.Constrain.Typed.*`).
This module is the erased entry point: it runs that generator with node
recording disabled, so it produces the same constraints as before without
building the id→var side table or the Group B synthetic placeholder vars.

@docs constrain

-}

import Compiler.AST.Canonical as Can
import Compiler.Type.Constrain.Typed.Module as Typed
import Compiler.Type.Type exposing (Constraint)
import System.TypeCheck.IO exposing (IO)


{-| Generate type constraints for a canonical module (no node tracking).
-}
constrain : Can.Module -> IO Constraint
constrain =
    Typed.constrainErased
