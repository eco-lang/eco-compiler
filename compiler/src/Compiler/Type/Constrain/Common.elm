module Compiler.Type.Constrain.Common exposing
    ( State(..), Header, emptyState, addToHeaders, getType
    , patternToCategory, patternNeedsConstraint, extractVarFromType
    , Args(..), ArgsProps, makeArgs, TypedArgs(..)
    , RigidTypeVar, Info(..), emptyInfo
    , getName, getAccessName, toShaderRecord
    -- Pattern state
    -- Def info
    -- Expression helpers
    -- Args types
    -- Pattern helpers
    )

{-| Shared types and helpers for constraint generation.

This module contains types and functions that are used by both the Erased
and Typed constraint generation pathways.


# Pattern State

@docs State, Header, emptyState, addToHeaders, getType


# Pattern Helpers

@docs patternToCategory, patternNeedsConstraint, extractVarFromType


# Args Types

@docs Args, ArgsProps, makeArgs, TypedArgs


# Definition Info

@docs RigidTypeVar, Info, emptyInfo


# Expression Helpers

@docs getName, getAccessName, toShaderRecord

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Type as Type exposing (Constraint, Type(..))
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ===== PATTERN STATE =====


{-| State accumulated during pattern constraint generation.

Contains the header (variables introduced by the pattern with their types),
a list of flexible type variables created during constraint generation,
and constraints stored in reverse order for efficient appending.

-}
type State
    = State Header (List IO.Variable) (List Constraint)


{-| Header maps variable names to their types with source locations.

Records all variables introduced by a pattern, associating each name
with its inferred type and the region where it was bound.

-}
type alias Header =
    Dict String Name (A.Located Type)


{-| Initial empty state for pattern constraint generation.

Contains no variable bindings, no type variables, and no constraints.

-}
emptyState : State
emptyState =
    State Dict.empty [] []


{-| Add a variable to the pattern headers.
-}
addToHeaders : A.Region -> Name -> E.PExpected Type -> State -> State
addToHeaders region name expectation (State headers vars revCons) =
    let
        tipe : Type
        tipe =
            getType expectation

        newHeaders : Dict String Name (A.Located Type)
        newHeaders =
            Dict.insert identity name (A.At region tipe) headers
    in
    State newHeaders vars revCons


{-| Extract the type from a pattern expectation.
-}
getType : E.PExpected Type -> Type
getType expectation =
    case expectation of
        E.PNoExpectation tipe ->
            tipe

        E.PFromContext _ _ tipe ->
            tipe



-- ===== PATTERN HELPERS =====


{-| Determine the appropriate PCategory for a pattern node.
This matches the categories used in the constraint generation.
-}
patternToCategory : Can.Pattern_ -> E.PCategory
patternToCategory node =
    case node of
        Can.PAnything ->
            -- PAnything doesn't generate a CPattern constraint, use PRecord as fallback
            E.PRecord

        Can.PVar _ ->
            -- PVar doesn't generate a CPattern constraint, use PRecord as fallback
            E.PRecord

        Can.PAlias _ _ ->
            -- PAlias delegates to inner pattern, use PRecord as fallback
            E.PRecord

        Can.PUnit ->
            E.PUnit

        Can.PTuple _ _ _ ->
            E.PTuple

        Can.PCtor { name } ->
            E.PCtor name

        Can.PList _ ->
            E.PList

        Can.PCons _ _ ->
            E.PList

        Can.PRecord _ ->
            E.PRecord

        Can.PInt _ ->
            E.PInt

        Can.PStr _ _ ->
            E.PStr

        Can.PChr _ ->
            E.PChr

        Can.PBool _ _ ->
            E.PBool


{-| Determine if a pattern needs a CPattern constraint.

Patterns that DON'T need constraints (matching `add` behavior):

  - PAnything: just returns state unchanged
  - PVar: just updates headers, no structural constraint
  - PAlias: delegates to inner pattern, no constraint for the alias itself

All other patterns need CPattern constraints to enforce their structure.

-}
patternNeedsConstraint : Can.Pattern_ -> Bool
patternNeedsConstraint node =
    case node of
        Can.PAnything ->
            False

        Can.PVar _ ->
            False

        Can.PAlias _ _ ->
            False

        _ ->
            True


{-| Try to extract a variable from a type.
Returns Just var if the type is VarN var, Nothing otherwise.
-}
extractVarFromType : Type -> Maybe IO.Variable
extractVarFromType tipe =
    case tipe of
        Type.VarN v ->
            Just v

        _ ->
            Nothing



-- ===== ARGS TYPES =====


{-| Wrapper for argument constraint information, containing type variables,
the overall function type, result type, and pattern state from argument patterns.
-}
type Args
    = Args ArgsProps


{-| Properties for constrained function arguments including:

  - vars: Type variables introduced for arguments and result
  - tipe: The full function type (arg1 -> arg2 -> ... -> result)
  - result: The result type of the function
  - state: Pattern matching state from argument patterns

-}
type alias ArgsProps =
    { vars : List IO.Variable
    , tipe : Type
    , result : Type
    , state : State
    }


{-| Construct an Args value from its components: type variables, function type,
result type, and pattern state.
-}
makeArgs : List IO.Variable -> Type -> Type -> State -> Args
makeArgs vars tipe result state =
    Args { vars = vars, tipe = tipe, result = result, state = state }


{-| Information about typed function arguments including the full function type,
the result type, and the pattern state from argument patterns.
-}
type TypedArgs
    = TypedArgs Type Type State



-- ===== DEF INFO =====


{-| As we step past type annotations, the free type variables are added to
the "rigid type variables" dict. Allowing sharing of rigid variables
between nested type annotations.

So if you have a top-level type annotation like (func : a -> b) the RTV
dictionary will hold variables for `a` and `b`

-}
type alias RigidTypeVar =
    Dict String Name Type


{-| Internal type for accumulating information about recursive definitions.
Tracks type variables, constraints, and type headers for both rigid (typed)
and flexible (untyped) definitions.
-}
type Info
    = Info (List IO.Variable) (List Constraint) (Dict String Name (A.Located Type))


{-| Empty Info structure with no variables, constraints, or headers.
-}
emptyInfo : Info
emptyInfo =
    Info [] [] Dict.empty



-- ===== EXPRESSION HELPERS =====


{-| Extract the name from an expression for better error messages. Returns
FuncName, CtorName, OpName, or NoName depending on the expression form.
-}
getName : Can.Expr -> E.MaybeName
getName (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            E.FuncName name

        Can.VarTopLevel _ name ->
            E.FuncName name

        Can.VarForeign _ name _ ->
            E.FuncName name

        Can.VarCtor _ _ name _ _ ->
            E.CtorName name

        Can.VarOperator op _ _ _ ->
            E.OpName op

        Can.VarKernel _ _ name ->
            E.FuncName name

        _ ->
            E.NoName


{-| Extract the variable name from an expression being accessed (e.g., in record
access). Returns Nothing if the expression is not a simple variable reference.
-}
getAccessName : Can.Expr -> Maybe Name
getAccessName (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            Just name

        Can.VarTopLevel _ name ->
            Just name

        Can.VarForeign _ name _ ->
            Just name

        _ ->
            Nothing


{-| Convert a dictionary of shader types to a record type. If the dictionary
is empty, returns the base record type; otherwise constructs a record with
the shader types mapped to Elm types.
-}
toShaderRecord : Dict String Name Shader.Type -> Type -> Type
toShaderRecord types baseRecType =
    if Dict.isEmpty types then
        baseRecType

    else
        RecordN (Dict.map (\_ -> glToType) types) baseRecType


{-| Convert a GLSL/WebGL type to the corresponding Elm type (e.g., V2 becomes
vec2, Float becomes float).
-}
glToType : Shader.Type -> Type
glToType glType =
    case glType of
        Shader.V2 ->
            Type.vec2

        Shader.V3 ->
            Type.vec3

        Shader.V4 ->
            Type.vec4

        Shader.M4 ->
            Type.mat4

        Shader.Int ->
            Type.int

        Shader.Float ->
            Type.float

        Shader.Texture ->
            Type.texture

        Shader.Bool ->
            Type.bool
