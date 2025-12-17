module Compiler.Optimize.Names exposing
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
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- GENERATOR


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


run : Tracker a -> ( EverySet (List String) Opt.Global, Dict String Name Int, a )
run (Tracker k) =
    case k 0 EverySet.empty Dict.empty of
        TResult props value ->
            ( props.deps, props.fields, value )


generate : Tracker Name
generate =
    Tracker <|
        \uid deps fields ->
            tResult (uid + 1) deps fields (Name.fromVarIndex uid)


registerKernel : Name -> a -> Tracker a
registerKernel home value =
    Tracker <|
        \uid deps fields ->
            tResult uid (EverySet.insert Opt.toComparableGlobal (Opt.toKernelGlobal home) deps) fields value


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


registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \uid d fields ->
            tResult uid d (Utils.mapInsertWith Basics.identity (+) name 1 fields) value


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


registerFieldList : List Name -> a -> Tracker a
registerFieldList names value =
    Tracker <|
        \uid deps fields ->
            tResult uid deps (List.foldr addOne fields names) value


addOne : Name -> Dict String Name Int -> Dict String Name Int
addOne name fields =
    Utils.mapInsertWith Basics.identity (+) name 1 fields



-- INSTANCES


map : (a -> b) -> Tracker a -> Tracker b
map func (Tracker kv) =
    Tracker <|
        \n d f ->
            case kv n d f of
                TResult props value ->
                    tResult props.uid props.deps props.fields (func value)


pure : a -> Tracker a
pure value =
    Tracker (\n d f -> tResult n d f value)


andThen : (a -> Tracker b) -> Tracker a -> Tracker b
andThen callback (Tracker k) =
    Tracker <|
        \n d f ->
            case k n d f of
                TResult props a ->
                    case callback a of
                        Tracker kb ->
                            kb props.uid props.deps props.fields


traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func =
    List.foldl (\a -> andThen (\acc -> map (\b -> acc ++ [ b ]) (func a))) (pure [])


mapTraverse : (k -> comparable) -> (k -> k -> Order) -> (a -> Tracker b) -> Dict comparable k a -> Tracker (Dict comparable k b)
mapTraverse toComparable keyComparison func =
    Dict.foldl keyComparison (\k a -> andThen (\c -> map (\va -> Dict.insert toComparable k va c) (func a))) (pure Dict.empty)
