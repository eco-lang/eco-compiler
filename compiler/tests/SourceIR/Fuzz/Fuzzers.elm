module SourceIR.Fuzz.Fuzzers exposing
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

    import SourceIR.Fuzz.Fuzzers exposing (..)

    Test.fuzz (intExprFuzzer (emptyScope 3))
        "Random int expression"
        (\expr -> ...)

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Fuzz exposing (Fuzzer)
import SourceIR.Fuzz.Module as M
import SourceIR.Fuzz.Structure as S
import SourceIR.Fuzz.TypedExpr as TE



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
intExprFuzzer : Scope -> Fuzzer Src.Expr
intExprFuzzer =
    TE.intExprFuzzer


{-| Generate an expression of type Float.
-}
floatExprFuzzer : Scope -> Fuzzer Src.Expr
floatExprFuzzer =
    TE.floatExprFuzzer


{-| Generate an expression of type String.
-}
stringExprFuzzer : Scope -> Fuzzer Src.Expr
stringExprFuzzer =
    TE.stringExprFuzzer


{-| Generate an expression of type Bool.
-}
boolExprFuzzer : Scope -> Fuzzer Src.Expr
boolExprFuzzer =
    TE.boolExprFuzzer


{-| Generate an expression of type ().
-}
unitExprFuzzer : Fuzzer Src.Expr
unitExprFuzzer =
    TE.unitExprFuzzer


{-| Generate an expression of type List a.
-}
listExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listExprFuzzer =
    TE.listExprFuzzer


{-| Generate an expression of type (a, b).
-}
tupleExprFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleExprFuzzer =
    TE.tupleExprFuzzer


{-| Generate an expression of type (a, b, c).
-}
tuple3ExprFuzzer : Scope -> SimpleType -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tuple3ExprFuzzer =
    TE.tuple3ExprFuzzer


{-| Generate an expression of type { ... }.
-}
recordExprFuzzer : Scope -> List ( Name, SimpleType ) -> Fuzzer Src.Expr
recordExprFuzzer =
    TE.recordExprFuzzer


{-| Generate an expression of the given type.
-}
exprFuzzerForType : Scope -> SimpleType -> Fuzzer Src.Expr
exprFuzzerForType =
    TE.exprFuzzerForType


{-| Generate an Int pattern with bindings.
-}
intPatternFuzzer : Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
intPatternFuzzer =
    TE.intPatternFuzzer


{-| Generate a pattern for any type.
-}
patternFuzzerForType : SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
patternFuzzerForType =
    TE.patternFuzzerForType



-- =============================================================================
-- RE-EXPORTS FROM Structure
-- =============================================================================


{-| Generate a let expression with multiple bindings.
-}
multiBindingLetFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
multiBindingLetFuzzer =
    S.multiBindingLetFuzzer


{-| Generate a case expression with multiple branches.
-}
multiBranchCaseFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
multiBranchCaseFuzzer =
    S.multiBranchCaseFuzzer


{-| Generate nested let expressions.
-}
nestedLetFuzzer : Scope -> SimpleType -> Int -> Fuzzer Src.Expr
nestedLetFuzzer =
    S.nestedLetFuzzer


{-| Generate a lambda expression with multiple parameters.
-}
lambdaExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
lambdaExprFuzzer =
    S.lambdaExprFuzzer


{-| Categories of binary operators.
-}
type alias BinopCategory =
    S.BinopCategory


{-| Generate a chain of binary operators.
-}
binopChainFuzzer : Scope -> BinopCategory -> Fuzzer Src.Expr
binopChainFuzzer =
    S.binopChainFuzzer



-- =============================================================================
-- RE-EXPORTS FROM Module
-- =============================================================================


{-| Generate a module with multiple top-level definitions.
-}
multiDefModuleFuzzer : Int -> Fuzzer Src.Module
multiDefModuleFuzzer =
    M.multiDefModuleFuzzer


{-| Generate expressions with mixed container types.
-}
mixedContainerFuzzer : Scope -> Fuzzer Src.Expr
mixedContainerFuzzer =
    M.mixedContainerFuzzer


{-| Generate complex expressions combining multiple structural elements.
-}
complexExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
complexExprFuzzer =
    M.complexExprFuzzer
