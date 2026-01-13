module Compiler.Optimize.Typed.Names exposing
    ( Tracker
    , run
    , generate
    , registerGlobal, registerKernel, registerCtor, registerDebug
    , registerField, registerFieldDict, registerFieldList
    , pure, map, andThen, traverse
    , withVarTypes, lookupLocalType
    )

{-| Tracks names, dependencies, and types during typed optimization.

This module provides a state monad (Tracker) that threads through the typed optimization
process, collecting information about:

  - Global dependencies (functions, constructors, kernels used)
  - Field names accessed across the module
  - Fresh variable names for generated temporaries
  - Local variable types (added for typed optimization)

The key difference from Erased.Names is the locals environment that maps variable
names to their types, enabling type-aware optimization.


# Core Type

@docs Tracker


# Running

@docs run


# Name Generation

@docs generate


# Dependency Registration

@docs registerGlobal, registerKernel, registerCtor, registerDebug
@docs registerField, registerFieldDict, registerFieldList


# Monad Operations

@docs pure, map, andThen, traverse


# Local Type Environment

@docs withVarTypes, lookupLocalType

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== CORE TYPE ======


{-| State monad that tracks name generation, dependencies, and local types during optimization.

Threads through four pieces of state:

  - A unique ID counter for generating fresh variable names
  - A set of global dependencies (functions, constructors, kernels)
  - A dictionary tracking field name usage counts
  - A dictionary of local variable types (Name -> Can.Type)

-}
type Tracker a
    = Tracker
        (Int
         -> EverySet (List String) TOpt.Global
         -> Dict String Name Int
         -> Dict String Name Can.Type
         -> TResult a
        )


type TResult a
    = TResult TResultProps a


type alias TResultProps =
    { uid : Int
    , deps : EverySet (List String) TOpt.Global
    , fields : Dict String Name Int
    , locals : Dict String Name Can.Type
    }


{-| Helper to construct TResult with positional args
-}
tResult : Int -> EverySet (List String) TOpt.Global -> Dict String Name Int -> Dict String Name Can.Type -> a -> TResult a
tResult uid deps fields locals value =
    TResult { uid = uid, deps = deps, fields = fields, locals = locals } value



-- ====== RUNNING ======


{-| Execute a Tracker computation, returning collected dependencies, fields, and the result value.

Returns a tuple of:

  - Global dependencies (functions, constructors, kernels used)
  - Field names and their usage counts
  - The computed result value

-}
run : Tracker a -> ( EverySet (List String) TOpt.Global, Dict String Name Int, a )
run (Tracker k) =
    case k 0 EverySet.empty Dict.empty Dict.empty of
        TResult props value ->
            ( props.deps, props.fields, value )



-- ====== NAME GENERATION ======


{-| Generate a fresh, unique variable name.

The generated name is guaranteed to not conflict with any other names in the module.
Names are generated sequentially as _v0, _v1, \_v2, etc.

-}
generate : Tracker Name
generate =
    Tracker <|
        \uid deps fields locals ->
            tResult (uid + 1) deps fields locals (Name.fromVarIndex uid)



-- ====== DEPENDENCY REGISTRATION ======


{-| Register a dependency on a kernel function and return the given value.

Kernel functions are JavaScript primitives exposed to Elm code.
Registering them ensures they are included in the final output.

-}
registerKernel : Name -> a -> Tracker a
registerKernel home value =
    Tracker <|
        \uid deps fields locals ->
            tResult uid (EverySet.insert TOpt.toComparableGlobal (TOpt.toKernelGlobal home) deps) fields locals value


{-| Register a dependency on a global function or value and return a reference to it.

Creates a VarGlobal expression referencing the function/value and adds it to the
dependency set so the code generator knows to import it.

-}
registerGlobal : A.Region -> IO.Canonical -> Name -> Can.Type -> Tracker TOpt.Expr
registerGlobal region home name itype =
    Tracker <|
        \uid deps fields locals ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global home name
            in
            tResult uid (EverySet.insert TOpt.toComparableGlobal global deps) fields locals (TOpt.VarGlobal region global itype)


{-| Register a dependency on a Debug module function and return a debug variable reference.

Debug functions are special-cased to support conditional compilation and removal
in production builds. The home module is tracked for context.

-}
registerDebug : Name -> IO.Canonical -> A.Region -> Can.Type -> Tracker TOpt.Expr
registerDebug name home region itype =
    Tracker <|
        \uid deps fields locals ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global ModuleName.debug name
            in
            tResult uid (EverySet.insert TOpt.toComparableGlobal global deps) fields locals (TOpt.VarDebug region name home Nothing itype)


{-| Register a dependency on a type constructor and return an optimized expression.

Handles three cases based on constructor options:

  - Normal: Regular constructor, returns VarGlobal
  - Enum: Zero-argument constructor, returns VarEnum (or Bool for True/False in Basics)
  - Unbox: Single-argument constructor, returns VarBox and registers identity dependency

-}
registerCtor : A.Region -> IO.Canonical -> A.Located Name -> Index.ZeroBased -> Can.CtorOpts -> Can.Type -> Tracker TOpt.Expr
registerCtor region home (A.At _ name) index opts itype =
    Tracker <|
        \uid deps fields locals ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global home name

                newDeps : EverySet (List String) TOpt.Global
                newDeps =
                    EverySet.insert TOpt.toComparableGlobal global deps
            in
            case opts of
                Can.Normal ->
                    tResult uid newDeps fields locals (TOpt.VarGlobal region global itype)

                Can.Enum ->
                    let
                        boolType =
                            Can.TType ModuleName.basics "Bool" []
                    in
                    tResult uid newDeps fields locals <|
                        case name of
                            "True" ->
                                if home == ModuleName.basics then
                                    TOpt.Bool region True boolType

                                else
                                    TOpt.VarEnum region global index itype

                            "False" ->
                                if home == ModuleName.basics then
                                    TOpt.Bool region False boolType

                                else
                                    TOpt.VarEnum region global index itype

                            _ ->
                                TOpt.VarEnum region global index itype

                Can.Unbox ->
                    tResult uid (EverySet.insert TOpt.toComparableGlobal identity newDeps) fields locals (TOpt.VarBox region global itype)


identity : TOpt.Global
identity =
    TOpt.Global ModuleName.basics Name.identity_


{-| Register usage of a record field name and return the given value.

Increments the usage count for the field name, which is used by the code generator
to determine optimal field name mangling strategies.

-}
registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \uid d fields locals ->
            tResult uid d (Utils.mapInsertWith Basics.identity (+) name 1 fields) locals value


{-| Register usage of multiple record fields from a dictionary and return the given value.

Takes a dictionary where keys are field names and increments the usage count for each.
The dictionary values are ignored - only the keys (field names) matter.

-}
registerFieldDict : Dict String Name v -> a -> Tracker a
registerFieldDict newFields value =
    Tracker <|
        \uid d fields locals ->
            tResult uid
                d
                (Utils.mapUnionWith Basics.identity compare (+) fields (Dict.map (\_ -> toOne) newFields))
                locals
                value


toOne : a -> Int
toOne _ =
    1


{-| Register usage of multiple record fields from a list and return the given value.

Increments the usage count for each field name in the list. Useful when processing
field accesses or record patterns.

-}
registerFieldList : List Name -> a -> Tracker a
registerFieldList names value =
    Tracker <|
        \uid deps fields locals ->
            tResult uid deps (List.foldr addOne fields names) locals value


addOne : Name -> Dict String Name Int -> Dict String Name Int
addOne name fields =
    Utils.mapInsertWith Basics.identity (+) name 1 fields



-- ====== LOCAL TYPE ENVIRONMENT ======


{-| Extend the local type environment with multiple bindings for the duration of a computation.

All bindings are visible within the provided Tracker computation and are automatically
removed when that computation completes.

-}
withVarTypes : List ( Name, Can.Type ) -> Tracker a -> Tracker a
withVarTypes bindings (Tracker inner) =
    Tracker <|
        \uid deps fields locals ->
            let
                extendedLocals =
                    List.foldl (\( name, itype ) acc -> Dict.insert Basics.identity name itype acc) locals bindings
            in
            case inner uid deps fields extendedLocals of
                TResult props value ->
                    -- Restore original locals after inner computation
                    tResult props.uid props.deps props.fields locals value


{-| Look up the type of a local variable.

Returns the type if the variable is in scope, or crashes with an error message
if the variable is not found. This should not happen in well-typed code.

-}
lookupLocalType : Name -> Tracker Can.Type
lookupLocalType name =
    Tracker <|
        \uid deps fields locals ->
            case Dict.get Basics.identity name locals of
                Just itype ->
                    tResult uid deps fields locals itype

                Nothing ->
                    crash ("Local variable not in scope: " ++ name)



-- ====== MONAD OPERATIONS ======


{-| Transform the result value of a Tracker computation using the given function.

Preserves all tracked dependencies and state while applying the function to the result.

-}
map : (a -> b) -> Tracker a -> Tracker b
map func (Tracker kv) =
    Tracker <|
        \n d f l ->
            case kv n d f l of
                TResult props value ->
                    tResult props.uid props.deps props.fields props.locals (func value)


{-| Lift a pure value into a Tracker computation without tracking any dependencies.

Equivalent to `return` in Haskell's monad notation. The value is wrapped in a Tracker
that doesn't modify the state or add any dependencies.

-}
pure : a -> Tracker a
pure value =
    Tracker (\n d f l -> tResult n d f l value)


{-| Chain two Tracker computations together, threading state from first to second.

Equivalent to `>>=` (bind) in Haskell. The callback receives the result of the first
computation and can use it to produce a second computation. Dependencies and state
accumulate across both computations.

-}
andThen : (a -> Tracker b) -> Tracker a -> Tracker b
andThen callback (Tracker k) =
    Tracker <|
        \n d f l ->
            case k n d f l of
                TResult props a ->
                    case callback a of
                        Tracker kb ->
                            kb props.uid props.deps props.fields props.locals


{-| Apply a Tracker-producing function to each element of a list, accumulating results.

Sequences the Tracker computations from left to right, threading state through each step.
Returns a Tracker containing the list of all results with all dependencies accumulated.

-}
traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func =
    List.foldl (\a -> andThen (\acc -> map (\b -> acc ++ [ b ]) (func a))) (pure [])
