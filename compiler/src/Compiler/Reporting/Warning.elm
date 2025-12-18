module Compiler.Reporting.Warning exposing (Warning(..), Context(..))

{-| Compiler warnings for code quality issues.

This module defines warnings that the compiler can emit for code that is
syntactically correct but potentially problematic. Unlike errors, warnings
do not prevent compilation but help developers write cleaner, more
maintainable code.


# Types

@docs Warning, Context


# Reporting

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A



-- ALL POSSIBLE WARNINGS


{-| Represents a compiler warning that indicates potentially problematic code.

Warnings are issued for code quality issues such as unused imports, unused
variables, or missing type annotations. Unlike errors, warnings do not prevent
compilation.

-}
type Warning
    = UnusedVariable A.Region Context Name
    | MissingTypeAnnotation A.Region Name Can.Type


{-| Describes the context where an unused variable was found.

The context affects how the warning message is phrased and what suggestions
are provided to the user.

-}
type Context
    = Def
    | Pattern



-- TO REPORT
