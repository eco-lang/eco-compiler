module Compiler.Optimize.Typed.Names exposing
    ( Context, Tracker
    , run
    , generate
    , getVarType, withVarType, withVarTypes
    , registerGlobal, registerCtor, registerDebug, registerKernel
    , registerField, registerFieldList, registerFieldDict
    , pure, map, andThen, traverse, mapTraverse
    )

{-| Name tracking with local variable type context.

Like the regular Names tracker but maintains a context of local variable types
alongside name generation and dependency tracking. This enables type lookups
during optimization, allowing the TypedExpression optimizer to preserve type
information on every expression node.


# Types

@docs Context, Tracker


# Running

@docs run


# Name Generation

@docs generate


# Type Context

@docs getVarType, withVarType, withVarTypes


# Registration

@docs registerGlobal, registerCtor, registerDebug, registerKernel
@docs registerField, registerFieldList, registerFieldDict


# Monadic Operations

@docs pure, map, andThen, traverse, mapTraverse

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
import Utils.Main as Utils



-- CONTEXT


{-| Context for looking up types of variables.
Contains module annotations and a local scope.
-}
type alias Context =
    { annotations : TOpt.Annotations
    , locals : Dict String Name Can.Type
    }


emptyContext : TOpt.Annotations -> Context
emptyContext annotations =
    { annotations = annotations
    , locals = Dict.empty
    }



-- GENERATOR


{-| Tracker monad for name generation with type context.
Tracks unique names, dependencies, field usage, and local variable types.
-}
type Tracker a
    = Tracker
        (Context
         -> Int
         -> EverySet (List String) TOpt.Global
         -> Dict String Name Int
         -> TResult a
        )


type TResult a
    = TResult TResultProps a


type alias TResultProps =
    { uid : Int
    , deps : EverySet (List String) TOpt.Global
    , fields : Dict String Name Int
    }


{-| Helper to construct TResult with positional args (for internal use)
-}
tResult : Int -> EverySet (List String) TOpt.Global -> Dict String Name Int -> a -> TResult a
tResult uid deps fields value =
    TResult { uid = uid, deps = deps, fields = fields } value


{-| Execute a tracker computation with the given annotations context.
Returns the collected dependencies, field usage counts, and the result value.
-}
run : TOpt.Annotations -> Tracker a -> ( EverySet (List String) TOpt.Global, Dict String Name Int, a )
run annotations (Tracker k) =
    case k (emptyContext annotations) 0 EverySet.empty Dict.empty of
        TResult props value ->
            ( props.deps, props.fields, value )


{-| Generate a fresh unique name.
-}
generate : Tracker Name
generate =
    Tracker <|
        \_ uid deps fields ->
            tResult (uid + 1) deps fields (Name.fromVarIndex uid)



-- TYPE LOOKUPS


{-| Get the type of a local variable from the context.
Returns Nothing if not found (should not happen in well-typed code).
-}
getVarType : Name -> Tracker (Maybe Can.Type)
getVarType name =
    Tracker <|
        \ctx uid deps fields ->
            tResult uid deps fields (Dict.get identity name ctx.locals)


{-| Insert a local variable type into context for a sub-computation.
-}
withVarType : Name -> Can.Type -> Tracker a -> Tracker a
withVarType name tipe (Tracker k) =
    Tracker <|
        \ctx uid deps fields ->
            let
                newCtx : Context
                newCtx =
                    { ctx | locals = Dict.insert identity name tipe ctx.locals }
            in
            k newCtx uid deps fields


{-| Insert multiple local variable types into context for a sub-computation.
-}
withVarTypes : List ( Name, Can.Type ) -> Tracker a -> Tracker a
withVarTypes andThenings (Tracker k) =
    Tracker <|
        \ctx uid deps fields ->
            let
                newLocals : Dict String Name Can.Type
                newLocals =
                    List.foldl (\( n, t ) acc -> Dict.insert identity n t acc) ctx.locals andThenings

                newCtx : Context
                newCtx =
                    { ctx | locals = newLocals }
            in
            k newCtx uid deps fields



-- REGISTRATIONS


{-| Register a kernel dependency and return the provided value.
Kernel functions are JavaScript implementations accessed from Elm.
-}
registerKernel : Name -> a -> Tracker a
registerKernel home value =
    Tracker <|
        \_ uid deps fields ->
            tResult uid (EverySet.insert TOpt.toComparableGlobal (TOpt.toKernelGlobal home) deps) fields value


{-| Register a global variable as a dependency and create a VarGlobal expression.
The type must be provided by the caller.
-}
registerGlobal : A.Region -> IO.Canonical -> Name -> Can.Type -> Tracker TOpt.Expr
registerGlobal region home name tipe =
    Tracker <|
        \_ uid deps fields ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global home name
            in
            tResult uid (EverySet.insert TOpt.toComparableGlobal global deps) fields (TOpt.VarGlobal region global tipe)


{-| Register a Debug module function as a dependency and create a VarDebug expression.
Debug functions are special functions provided by the Elm Debug module.
-}
registerDebug : Name -> IO.Canonical -> A.Region -> Can.Type -> Tracker TOpt.Expr
registerDebug name home region tipe =
    Tracker <|
        \_ uid deps fields ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global ModuleName.debug name
            in
            tResult uid (EverySet.insert TOpt.toComparableGlobal global deps) fields (TOpt.VarDebug region name home Nothing tipe)


{-| Register a constructor as a dependency and create the appropriate expression.
Handles enum constructors (including True/False), unbox constructors, and normal constructors.
-}
registerCtor : A.Region -> IO.Canonical -> A.Located Name -> Index.ZeroBased -> Can.CtorOpts -> Can.Type -> Tracker TOpt.Expr
registerCtor region home (A.At _ name) index opts tipe =
    Tracker <|
        \_ uid deps fields ->
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
                    tResult uid newDeps fields (TOpt.VarGlobal region global tipe)

                Can.Enum ->
                    tResult uid newDeps fields <|
                        case name of
                            "True" ->
                                if home == ModuleName.basics then
                                    TOpt.Bool region True (Can.TType ModuleName.basics "Bool" [])

                                else
                                    TOpt.VarEnum region global index tipe

                            "False" ->
                                if home == ModuleName.basics then
                                    TOpt.Bool region False (Can.TType ModuleName.basics "Bool" [])

                                else
                                    TOpt.VarEnum region global index tipe

                            _ ->
                                TOpt.VarEnum region global index tipe

                Can.Unbox ->
                    tResult uid (EverySet.insert TOpt.toComparableGlobal identityGlobal newDeps) fields (TOpt.VarBox region global tipe)


identityGlobal : TOpt.Global
identityGlobal =
    TOpt.Global ModuleName.basics Name.identity_


{-| Register a single record field as used and return the provided value.
Increments the usage count for the field.
-}
registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \_ uid d fields ->
            tResult uid d (Utils.mapInsertWith Basics.identity (+) name 1 fields) value


{-| Register all fields from a dictionary as used and return the provided value.
Each field's usage count is incremented by one.
-}
registerFieldDict : Dict String Name v -> a -> Tracker a
registerFieldDict newFields value =
    Tracker <|
        \_ uid d fields ->
            tResult uid
                d
                (Utils.mapUnionWith Basics.identity compare (+) fields (Dict.map (\_ -> toOne) newFields))
                value


toOne : a -> Int
toOne _ =
    1


{-| Register multiple record fields from a list as used and return the provided value.
Each field's usage count is incremented by one.
-}
registerFieldList : List Name -> a -> Tracker a
registerFieldList names value =
    Tracker <|
        \_ uid deps fields ->
            tResult uid deps (List.foldr addOne fields names) value


addOne : Name -> Dict String Name Int -> Dict String Name Int
addOne name fields =
    Utils.mapInsertWith Basics.identity (+) name 1 fields



-- INSTANCES


{-| Map a function over the result of a tracker computation.
-}
map : (a -> b) -> Tracker a -> Tracker b
map func (Tracker kv) =
    Tracker <|
        \ctx n d f ->
            case kv ctx n d f of
                TResult props value ->
                    tResult props.uid props.deps props.fields (func value)


{-| Create a tracker computation that returns a pure value without effects.
-}
pure : a -> Tracker a
pure value =
    Tracker (\_ n d f -> tResult n d f value)


{-| Sequentially compose two tracker computations, passing the result of the first to the second.
-}
andThen : (a -> Tracker b) -> Tracker a -> Tracker b
andThen callback (Tracker k) =
    Tracker <|
        \ctx n d f ->
            case k ctx n d f of
                TResult props a ->
                    case callback a of
                        Tracker kb ->
                            kb ctx props.uid props.deps props.fields


{-| Apply a tracker-producing function to each element of a list and collect the results.
-}
traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func =
    List.foldl (\a -> andThen (\acc -> map (\b -> acc ++ [ b ]) (func a))) (pure [])


{-| Apply a tracker-producing function to each value in a dictionary and collect the results.
-}
mapTraverse : (k -> comparable) -> (k -> k -> Order) -> (a -> Tracker b) -> Dict comparable k a -> Tracker (Dict comparable k b)
mapTraverse toComparable keyComparison func =
    Dict.foldl keyComparison (\k a -> andThen (\c -> map (\va -> Dict.insert toComparable k va c) (func a))) (pure Dict.empty)
