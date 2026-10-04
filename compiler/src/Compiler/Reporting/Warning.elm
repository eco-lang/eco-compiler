module Compiler.Reporting.Warning exposing (Warning(..), Context(..))

{-| Some problems in a program do not stop it compiling, and this module names
the ones the compiler detects. A warning is such a problem: the code is valid,
but something in it is worth the author's attention.

There are two. An unused variable is a name bound by a `let` or by a pattern and
never referred to. A missing type annotation is a top-level definition written
without one; the warning carries the type the type checker inferred for it.

Warnings are accumulated alongside a computation's result through
`Compiler.Reporting.Result`. Nothing in this module turns a warning into a
message.

@docs Warning, Context

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A



-- ====== ALL POSSIBLE WARNINGS ======


{-| A problem that does not stop compilation, located at the region of source
it concerns.

`UnusedVariable` names a variable that is bound and never referred to within
its scope, and says by what kind of binding through its `Context`. The region
is where the name is bound.

`MissingTypeAnnotation` names a top-level definition that has no type
annotation, at the region of its name, together with the type inferred for it.

-}
type Warning
    = UnusedVariable A.Region Context Name
    | MissingTypeAnnotation A.Region Name (Can.Type Name)


{-| The kind of binding that introduced an unused variable.

`Def` is a name bound in a `let`, by a definition or by destructuring.

`Pattern` is a name bound by any other pattern: an argument of a function or
lambda, or a variable in a `case` branch.

-}
type Context
    = Def
    | Pattern
