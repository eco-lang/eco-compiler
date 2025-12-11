module Compiler.Optimize.TypedNames exposing
    ( Context
    , Tracker
    , andThen
    , generate
    , getAnnotations
    , getVarType
    , insertVarType
    , insertVarTypes
    , lookupGlobalType
    , map
    , mapTraverse
    , pure
    , registerCtor
    , registerDebug
    , registerField
    , registerFieldDict
    , registerFieldList
    , registerGlobal
    , registerKernel
    , run
    , traverse
    , withVarType
    , withVarTypes
    )

{-| Name tracking for typed optimization.

Like Names.elm but also tracks local variable types in a context.
This allows us to look up the type of any local variable during optimization.

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


run : TOpt.Annotations -> Tracker a -> ( EverySet (List String) TOpt.Global, Dict String Name Int, a )
run annotations (Tracker k) =
    case k (emptyContext annotations) 0 EverySet.empty Dict.empty of
        TResult props value ->
            ( props.deps, props.fields, value )


generate : Tracker Name
generate =
    Tracker <|
        \_ uid deps fields ->
            tResult (uid + 1) deps fields (Name.fromVarIndex uid)


getAnnotations : Tracker TOpt.Annotations
getAnnotations =
    Tracker <|
        \ctx uid deps fields ->
            tResult uid deps fields ctx.annotations



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


{-| Insert a variable type into the context permanently (for let andThenings)
-}
insertVarType : Name -> Can.Type -> Tracker ()
insertVarType name tipe =
    Tracker <|
        \_ uid deps fields ->
            tResult uid deps fields ()


{-| Insert multiple variable types
-}
insertVarTypes : List ( Name, Can.Type ) -> Tracker ()
insertVarTypes andThenings =
    Tracker <|
        \_ uid deps fields ->
            tResult uid deps fields ()


{-| Look up the type of a global variable from annotations.
-}
lookupGlobalType : Name -> Tracker (Maybe Can.Type)
lookupGlobalType name =
    Tracker <|
        \ctx uid deps fields ->
            let
                tipe : Maybe Can.Type
                tipe =
                    Dict.get identity name ctx.annotations
                        |> Maybe.map (\(Can.Forall _ t) -> t)
            in
            tResult uid deps fields tipe



-- REGISTRATIONS


registerKernel : Name -> a -> Tracker a
registerKernel home value =
    Tracker <|
        \_ uid deps fields ->
            tResult uid (EverySet.insert TOpt.toComparableGlobal (TOpt.toKernelGlobal home) deps) fields value



-- Register a global and return a VarGlobal with its type
-- The type must be provided by the caller


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


registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \_ uid d fields ->
            tResult uid d (Utils.mapInsertWith Basics.identity (+) name 1 fields) value


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


registerFieldList : List Name -> a -> Tracker a
registerFieldList names value =
    Tracker <|
        \_ uid deps fields ->
            tResult uid deps (List.foldr addOne fields names) value


addOne : Name -> Dict String Name Int -> Dict String Name Int
addOne name fields =
    Utils.mapInsertWith Basics.identity (+) name 1 fields



-- INSTANCES


map : (a -> b) -> Tracker a -> Tracker b
map func (Tracker kv) =
    Tracker <|
        \ctx n d f ->
            case kv ctx n d f of
                TResult props value ->
                    tResult props.uid props.deps props.fields (func value)


pure : a -> Tracker a
pure value =
    Tracker (\_ n d f -> tResult n d f value)


andThen : (a -> Tracker b) -> Tracker a -> Tracker b
andThen callback (Tracker k) =
    Tracker <|
        \ctx n d f ->
            case k ctx n d f of
                TResult props a ->
                    case callback a of
                        Tracker kb ->
                            kb ctx props.uid props.deps props.fields


traverse : (a -> Tracker b) -> List a -> Tracker (List b)
traverse func =
    List.foldl (\a -> andThen (\acc -> map (\b -> acc ++ [ b ]) (func a))) (pure [])


mapTraverse : (k -> comparable) -> (k -> k -> Order) -> (a -> Tracker b) -> Dict comparable k a -> Tracker (Dict comparable k b)
mapTraverse toComparable keyComparison func =
    Dict.foldl keyComparison (\k a -> andThen (\c -> map (\va -> Dict.insert toComparable k va c) (func a))) (pure Dict.empty)
