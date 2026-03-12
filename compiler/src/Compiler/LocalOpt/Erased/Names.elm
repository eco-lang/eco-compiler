module Compiler.LocalOpt.Erased.Names exposing
    ( Tracker
    , run
    , generate
    , registerGlobal, registerKernel, registerCtor, registerDebug
    , registerField, registerFieldDict, registerFieldList
    , pure, map, andThen, traverse, mapTraverse
    )

{-| Tracks names and dependencies during optimization.

This module provides a state monad (Tracker) that threads through the optimization
process, collecting information about:

  - Global dependencies (functions, constructors, kernels used)
  - Field names accessed across the module
  - Fresh variable names for generated temporaries

The collected dependency information is used by the code generator to determine
which imports and definitions are actually needed in the final output.


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

@docs pure, map, andThen, traverse, mapTraverse

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Control.Loop exposing (Step(..))
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- ====== CORE TYPE ======


{-| State monad that tracks name generation and dependencies during optimization.

Threads through three pieces of state:

  - A unique ID counter for generating fresh variable names
  - A set of global dependencies (functions, constructors, kernels)
  - A dictionary tracking field name usage counts

-}
type Tracker a
    = Tracker
        (Int
         -> EverySet (List String) Opt.Global
         -> Dict String Name Int
         -> TResult a
        )


type TResult a
    = TResult TResultProps a


type alias TResultProps =
    { uid : Int
    , deps : EverySet (List String) Opt.Global
    , fields : Dict String Name Int
    }


{-| Helper to construct TResult with positional args
-}
tResult : Int -> EverySet (List String) Opt.Global -> Dict String Name Int -> a -> TResult a
tResult uid deps fields value =
    TResult { uid = uid, deps = deps, fields = fields } value



-- ====== RUNNING ======


{-| Execute a Tracker computation, returning collected dependencies, fields, and the result value.

Returns a tuple of:

  - Global dependencies (functions, constructors, kernels used)
  - Field names and their usage counts
  - The computed result value

-}
run : Tracker a -> ( EverySet (List String) Opt.Global, Dict String Name Int, a )
run (Tracker k) =
    case k 0 EverySet.empty Dict.empty of
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
        \uid deps fields ->
            tResult (uid + 1) deps fields (Name.fromVarIndex uid)



-- ====== DEPENDENCY REGISTRATION ======


{-| Register a dependency on a kernel function and return the given value.

Kernel functions are JavaScript primitives exposed to Elm code.
Registering them ensures they are included in the final output.

-}
registerKernel : Name -> a -> Tracker a
registerKernel home value =
    Tracker <|
        \uid deps fields ->
            tResult uid (EverySet.insert Opt.toComparableGlobal (Opt.toKernelGlobal home) deps) fields value


{-| Register a dependency on a global function or value and return a reference to it.

Creates a VarGlobal expression referencing the function/value and adds it to the
dependency set so the code generator knows to import it.

-}
registerGlobal : A.Region -> IO.Canonical -> Name -> Tracker Opt.Expr
registerGlobal region home name =
    Tracker <|
        \uid deps fields ->
            let
                global : Opt.Global
                global =
                    Opt.Global home name
            in
            tResult uid (EverySet.insert Opt.toComparableGlobal global deps) fields (Opt.VarGlobal region global)


{-| Register a dependency on a Debug module function and return a debug variable reference.

Debug functions are special-cased to support conditional compilation and removal
in production builds. The home module is tracked for context.

-}
registerDebug : Name -> IO.Canonical -> A.Region -> Tracker Opt.Expr
registerDebug name home region =
    Tracker <|
        \uid deps fields ->
            let
                global : Opt.Global
                global =
                    Opt.Global ModuleName.debug name
            in
            tResult uid (EverySet.insert Opt.toComparableGlobal global deps) fields (Opt.VarDebug region name home Nothing)


{-| Register a dependency on a type constructor and return an optimized expression.

Handles three cases based on constructor options:

  - Normal: Regular constructor, returns VarGlobal
  - Enum: Zero-argument constructor, returns VarEnum (or Bool for True/False in Basics)
  - Unbox: Single-argument constructor, returns VarBox and registers identity dependency

-}
registerCtor : A.Region -> IO.Canonical -> A.Located Name -> Index.ZeroBased -> Can.CtorOpts -> Tracker Opt.Expr
registerCtor region home (A.At _ name) index opts =
    Tracker <|
        \uid deps fields ->
            let
                global : Opt.Global
                global =
                    Opt.Global home name

                newDeps : EverySet (List String) Opt.Global
                newDeps =
                    EverySet.insert Opt.toComparableGlobal global deps
            in
            case opts of
                Can.Normal ->
                    tResult uid newDeps fields (Opt.VarGlobal region global)

                Can.Enum ->
                    tResult uid newDeps fields <|
                        case name of
                            "True" ->
                                if home == ModuleName.basics then
                                    Opt.Bool region True

                                else
                                    Opt.VarEnum region global index

                            "False" ->
                                if home == ModuleName.basics then
                                    Opt.Bool region False

                                else
                                    Opt.VarEnum region global index

                            _ ->
                                Opt.VarEnum region global index

                Can.Unbox ->
                    tResult uid (EverySet.insert Opt.toComparableGlobal identity newDeps) fields (Opt.VarBox region global)


identity : Opt.Global
identity =
    Opt.Global ModuleName.basics Name.identity_


{-| Register usage of a record field name and return the given value.

Increments the usage count for the field name, which is used by the code generator
to determine optimal field name mangling strategies.

-}
registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \uid d fields ->
            tResult uid d (Utils.mapInsertWith Basics.identity (+) name 1 fields) value


{-| Register usage of multiple record fields from a dictionary and return the given value.

Takes a dictionary where keys are field names and increments the usage count for each.
The dictionary values are ignored - only the keys (field names) matter.

-}
registerFieldDict : Dict String Name v -> a -> Tracker a
registerFieldDict newFields value =
    Tracker <|
        \uid d fields ->
            tResult uid
                d
                (Utils.mapUnionWith Basics.identity compare (+) fields (Dict.map (\_ -> toOne) newFields))
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
        \uid deps fields ->
            tResult uid deps (List.foldr addOne fields names) value


addOne : Name -> Dict String Name Int -> Dict String Name Int
addOne name fields =
    Utils.mapInsertWith Basics.identity (+) name 1 fields



-- ====== MONAD OPERATIONS ======


{-| Transform the result value of a Tracker computation using the given function.

Preserves all tracked dependencies and state while applying the function to the result.

-}
map : (a -> b) -> Tracker a -> Tracker b
map func (Tracker kv) =
    Tracker <|
        \n d f ->
            case kv n d f of
                TResult props value ->
                    tResult props.uid props.deps props.fields (func value)


{-| Lift a pure value into a Tracker computation without tracking any dependencies.

Equivalent to `return` in Haskell's monad notation. The value is wrapped in a Tracker
that doesn't modify the state or add any dependencies.

-}
pure : a -> Tracker a
pure value =
    Tracker (\n d f -> tResult n d f value)


{-| Chain two Tracker computations together, threading state from first to second.

Equivalent to `>>=` (bind) in Haskell. The callback receives the result of the first
computation and can use it to produce a second computation. Dependencies and state
accumulate across both computations.

-}
andThen : (a -> Tracker b) -> Tracker a -> Tracker b
andThen callback (Tracker k) =
    Tracker <|
        \n d f ->
            case k n d f of
                TResult props a ->
                    case callback a of
                        Tracker kb ->
                            kb props.uid props.deps props.fields


{-| Execute a tail-recursive loop in the Tracker monad.
-}
loop : (state -> Tracker (Step state a)) -> state -> Tracker a
loop callback loopState =
    Tracker
        (\n d f ->
            loopHelper callback loopState n d f
        )


loopHelper :
    (state -> Tracker (Step state a))
    -> state
    -> Int
    -> EverySet (List String) Opt.Global
    -> Dict String Name Int
    -> TResult a
loopHelper callback loopState n d f =
    case callback loopState of
        Tracker k ->
            case k n d f of
                TResult props (Loop newState) ->
                    loopHelper callback newState props.uid props.deps props.fields

                TResult props (Done a) ->
                    TResult props a


{-| Apply a Tracker-producing function to each element of a list, accumulating results.

Sequences the Tracker computations from left to right, threading state through each step.
Returns a Tracker containing the list of all results with all dependencies accumulated.

-}
traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func list =
    loop
        (\( remaining, acc ) ->
            case remaining of
                [] ->
                    pure (Done (List.reverse acc))

                a :: rest ->
                    map (\b -> Loop ( rest, b :: acc )) (func a)
        )
        ( list, [] )


{-| Apply a Tracker-producing function to each value in a dictionary, accumulating results.

Like traverse but for dictionaries. Sequences computations across all dictionary entries,
threading state through each step. Returns a Tracker containing a dictionary with
transformed values and all accumulated dependencies.

-}
mapTraverse : (k -> comparable) -> (k -> k -> Order) -> (a -> Tracker b) -> Dict comparable k a -> Tracker (Dict comparable k b)
mapTraverse toComparable keyComparison func dict =
    loop
        (\( pairs, acc ) ->
            case pairs of
                [] ->
                    pure (Done acc)

                ( k, a ) :: rest ->
                    map (\b -> Loop ( rest, Dict.insert toComparable k b acc )) (func a)
        )
        ( Dict.toList keyComparison dict, Dict.empty )
