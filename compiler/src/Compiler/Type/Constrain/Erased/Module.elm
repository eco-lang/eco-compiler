module Compiler.Type.Constrain.Erased.Module exposing (constrain)

{-| The front end's type check (`Compiler.Compile.typeCheck`) needs a module's
constraint but never reads back the type of an individual expression, so it
asks for the constraint without the bookkeeping that reading back requires.
This module is that entry point.

It runs the one shared generator, `Compiler.Type.Constrain.Typed.Module`, with
node recording off: no map from expression and pattern ids to solver
variables is kept, and the placeholder variables for synthetic expressions are
not made. The resulting tree is not identical to the recording one, since some
extra variables and equalities are still emitted, but checking is
equivalent. Solving it still yields the module's top-level
annotations; only per-expression types are lost.

@docs constrain

-}

import Compiler.AST.Canonical as Can
import Compiler.Type.Constrain.Typed.Module as Typed
import Compiler.Type.Type exposing (Constraint)
import System.TypeCheck.IO exposing (IO)


{-| Returns the constraint for a module with node recording off; see
`Compiler.Type.Constrain.Typed.Module.constrainErased`.
-}
constrain : Can.Module -> IO Constraint
constrain =
    Typed.constrainErased
