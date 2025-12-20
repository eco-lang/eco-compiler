module Compiler.Fuzz.Fuzzers exposing
    ( BinopCategory
    , Scope
      -- Scope operations
    , -- Types
      SimpleType
    , addVar
    , binopChainFuzzer
      -- Module fuzzers
    , boolExprFuzzer
    , complexExprFuzzer
    , decrementDepth
      -- Type-indexed expression fuzzers
    , emptyScope
    , exprFuzzerForType
      -- Pattern fuzzers
    , floatExprFuzzer
    , intExprFuzzer
    , intPatternFuzzer
    , lambdaExprFuzzer
    , listExprFuzzer
    , mixedContainerFuzzer
    , multiBindingLetFuzzer
    , multiBranchCaseFuzzer
    , multiDefModuleFuzzer
    , nestedLetFuzzer
    , patternFuzzerForType
      -- Structural fuzzers
    , recordExprFuzzer
    , stringExprFuzzer
    , tuple3ExprFuzzer
    , tupleExprFuzzer
    , unitExprFuzzer
    )

{-| Main export module for deep structural fuzzers.

This module re-exports the most commonly used fuzzers from the
TypedExpr, Structure, and Module submodules.


## Usage

    import Compiler.Fuzz.Fuzzers exposing (..)

    Test.fuzz (intExprFuzzer (emptyScope 3))
        "Random int expression"
        (\expr -> ...)

-}

import Compiler.Fuzz.Module as M
import Compiler.Fuzz.Structure as S
import Compiler.Fuzz.TypedExpr as TE



-- =============================================================================
-- RE-EXPORTS FROM TypedExpr
-- =============================================================================


{-| Simple type representation for tracking types during generation.
-}
type alias SimpleType =
    TE.SimpleType


{-| Scope tracks variables in scope and remaining depth budget.
-}
type alias Scope =
    TE.Scope


{-| Create an empty scope with a given depth budget.
-}
emptyScope : Int -> Scope
emptyScope =
    TE.emptyScope


{-| Add a variable to scope.
-}
addVar : String -> TE.SimpleType -> Scope -> Scope
addVar =
    TE.addVar


{-| Decrement the depth budget.
-}
decrementDepth : Scope -> Scope
decrementDepth =
    TE.decrementDepth


{-| Generate an expression of type Int.
-}
intExprFuzzer =
    TE.intExprFuzzer


{-| Generate an expression of type Float.
-}
floatExprFuzzer =
    TE.floatExprFuzzer


{-| Generate an expression of type String.
-}
stringExprFuzzer =
    TE.stringExprFuzzer


{-| Generate an expression of type Bool.
-}
boolExprFuzzer =
    TE.boolExprFuzzer


{-| Generate an expression of type ().
-}
unitExprFuzzer =
    TE.unitExprFuzzer


{-| Generate an expression of type List a.
-}
listExprFuzzer =
    TE.listExprFuzzer


{-| Generate an expression of type (a, b).
-}
tupleExprFuzzer =
    TE.tupleExprFuzzer


{-| Generate an expression of type (a, b, c).
-}
tuple3ExprFuzzer =
    TE.tuple3ExprFuzzer


{-| Generate an expression of type { ... }.
-}
recordExprFuzzer =
    TE.recordExprFuzzer


{-| Generate an expression of the given type.
-}
exprFuzzerForType =
    TE.exprFuzzerForType


{-| Generate an Int pattern with bindings.
-}
intPatternFuzzer =
    TE.intPatternFuzzer


{-| Generate a pattern for any type.
-}
patternFuzzerForType =
    TE.patternFuzzerForType



-- =============================================================================
-- RE-EXPORTS FROM Structure
-- =============================================================================


{-| Generate a let expression with multiple bindings.
-}
multiBindingLetFuzzer =
    S.multiBindingLetFuzzer


{-| Generate a case expression with multiple branches.
-}
multiBranchCaseFuzzer =
    S.multiBranchCaseFuzzer


{-| Generate nested let expressions.
-}
nestedLetFuzzer =
    S.nestedLetFuzzer


{-| Generate a lambda expression with multiple parameters.
-}
lambdaExprFuzzer =
    S.lambdaExprFuzzer


{-| Categories of binary operators.
-}
type alias BinopCategory =
    S.BinopCategory


{-| Generate a chain of binary operators.
-}
binopChainFuzzer =
    S.binopChainFuzzer



-- =============================================================================
-- RE-EXPORTS FROM Module
-- =============================================================================


{-| Generate a module with multiple top-level definitions.
-}
multiDefModuleFuzzer =
    M.multiDefModuleFuzzer


{-| Generate expressions with mixed container types.
-}
mixedContainerFuzzer =
    M.mixedContainerFuzzer


{-| Generate complex expressions combining multiple structural elements.
-}
complexExprFuzzer =
    M.complexExprFuzzer
