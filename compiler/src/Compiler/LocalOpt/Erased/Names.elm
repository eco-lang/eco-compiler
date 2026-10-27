module Compiler.LocalOpt.Erased.Names exposing
    ( Tracker
    , run
    , generate
    , registerGlobal, registerKernel, registerCtor, registerDebug
    , registerField, registerFieldDict, registerFieldList
    , pure, map, andThen, traverse, mapTraverse
    )

{-| Lowering a definition to the erased optimized form has to record, alongside
the expression it builds, what that expression refers to, and this module is
the bookkeeping that does so.

A `Tracker` is a computation that produces a value while carrying three pieces
of state from one step to the next:

  - The _dependency set_: every global, constructor, kernel module and `Debug`
    function the expression refers to.
  - The _field counts_: for each record field name, how many times it was
    registered.
  - A counter from which fresh temporary names are made.

`run` starts a computation with all three empty and returns the first two with
the result. The counter starts at 0 on every `run`, so a generated name is
unique only within one `run`.

The `register*` functions are where state is added; `pure`, `map`, `andThen`,
`traverse` and `mapTraverse` combine computations, each passing the state on
in order.


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
import Data.Map as DataMap
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)



-- ====== CORE TYPE ======


{-| A computation that produces an `a` while adding to a dependency set and
field counts and drawing fresh names, as the module docstring describes.
Outside this module, a value is made by the functions here and only taken apart
by `run`.
-}
type Tracker a
    = Tracker
        (Int
         -> EverySet String Opt.Global
         -> Dict Name Int
         -> TResult a
        )


{-| The state left by a computation, together with the value it produced.
-}
type TResult a
    = TResult TResultProps a


{-| The three pieces of state: the next name index, the dependency set and the
field counts.
-}
type alias TResultProps =
    { uid : Int
    , deps : EverySet String Opt.Global
    , fields : Dict Name Int
    }


{-| Builds a `TResult` from the three pieces of state and the value.
-}
tResult : Int -> EverySet String Opt.Global -> Dict Name Int -> a -> TResult a
tResult uid deps fields value =
    TResult { uid = uid, deps = deps, fields = fields } value



-- ====== RUNNING ======


{-| Runs a computation from an empty dependency set, empty field counts and a
name counter of 0, and returns the dependency set, the field counts and the
value it produced.
-}
run : Tracker a -> ( EverySet String Opt.Global, Dict Name Int, a )
run (Tracker k) =
    case k 0 EverySet.empty Dict.empty of
        TResult props value ->
            ( props.deps, props.fields, value )



-- ====== NAME GENERATION ======


{-| A fresh temporary name: `_v0`, `_v1` and so on, in order, within one `run`.

The counter restarts with every `run`, so the same name can be produced in two
runs. None can clash with a name from source, as `Name.fromVarIndex` describes.

-}
generate : Tracker Name
generate =
    Tracker <|
        \uid deps fields ->
            tResult (uid + 1) deps fields (Name.fromVarIndex uid)



-- ====== DEPENDENCY REGISTRATION ======


{-| Adds a dependency on a kernel module and returns `value` unchanged.

The module is given by its kernel prefix (`Elm` or `Eco`) and home, and the
dependency is the global `Opt.toKernelGlobal` makes from them.

-}
registerKernel : Name -> Name -> a -> Tracker a
registerKernel kernelPrefix home value =
    Tracker <|
        \uid deps fields ->
            tResult uid (EverySet.insert Opt.toComparableGlobal (Opt.toKernelGlobal kernelPrefix home) deps) fields value


{-| Adds a dependency on the global `name` of module `home` and returns a
`VarGlobal` reference to it.
-}
registerGlobal : A.Region -> ModuleName.Canonical -> Name -> Tracker Opt.Expr
registerGlobal region home name =
    Tracker <|
        \uid deps fields ->
            let
                global : Opt.Global
                global =
                    Opt.Global home name
            in
            tResult uid (EverySet.insert Opt.toComparableGlobal global deps) fields (Opt.VarGlobal region global)


{-| Adds a dependency on `Debug.name` and returns a `VarDebug` reference to it.

`home` is the module the reference appears in, not `Debug`, and is carried in
the `VarDebug`. The `VarDebug` is built with no unhandled-value name.

-}
registerDebug : Name -> ModuleName.Canonical -> A.Region -> Tracker Opt.Expr
registerDebug name home region =
    Tracker <|
        \uid deps fields ->
            let
                global : Opt.Global
                global =
                    Opt.Global ModuleName.debug name
            in
            tResult uid (EverySet.insert Opt.toComparableGlobal global deps) fields (Opt.VarDebug region name home Nothing)


{-| Adds a dependency on the constructor `name` of module `home` and returns a
reference to it, shaped by the constructor options of its type.

For `Normal`, the reference is a `VarGlobal`. For `Enum`, it is a `VarEnum`
carrying `index`, except that `True` and `False` of `Basics` become `Bool`
literals; the dependency is added for them too. For `Unbox`, it is a `VarBox`,
and a dependency on `Basics.identity` is added as well.

-}
registerCtor : A.Region -> ModuleName.Canonical -> A.Located Name -> Index.ZeroBased -> Can.CtorOpts -> Tracker Opt.Expr
registerCtor region home (A.At _ name) index opts =
    Tracker <|
        \uid deps fields ->
            let
                global : Opt.Global
                global =
                    Opt.Global home name

                newDeps : EverySet String Opt.Global
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


{-| The global `Basics.identity`.
-}
identity : Opt.Global
identity =
    Opt.Global ModuleName.basics Name.identity_


{-| Adds 1 to the count of field `name` and returns `value` unchanged.
-}
registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \uid d fields ->
            tResult uid d (insertWith (+) name 1 fields) value


{-| Adds 1 to the count of each field named by a key of `newFields`, whose
values are ignored, and returns `value` unchanged.
-}
registerFieldDict : Dict Name v -> a -> Tracker a
registerFieldDict newFields value =
    Tracker <|
        \uid d fields ->
            tResult uid
                d
                (unionWith (+) fields (Dict.map (\_ _ -> 1) newFields))
                value


{-| Adds 1 to the count of each field in `names`, once per occurrence, and
returns `value` unchanged.
-}
registerFieldList : List Name -> a -> Tracker a
registerFieldList names value =
    Tracker <|
        \uid deps fields ->
            tResult uid deps (List.foldr addOne fields names) value


{-| Adds 1 to the count of field `name`.
-}
addOne : Name -> Dict Name Int -> Dict Name Int
addOne name fields =
    insertWith (+) name 1 fields


{-| Inserts `v` at `k`, or, where `k` already holds a value, replaces it with
`f v` applied to that value.
-}
insertWith : (a -> a -> a) -> comparable -> a -> Dict comparable a -> Dict comparable a
insertWith f k v =
    Dict.update k (Maybe.map (f v) >> Maybe.withDefault v >> Just)


{-| Returns every entry of `a` and `b`, combining the two values with `f` where
both hold a key.
-}
unionWith : (a -> a -> a) -> Dict comparable a -> Dict comparable a -> Dict comparable a
unionWith f a b =
    Dict.merge Dict.insert (\k va vb acc -> Dict.insert k (f va vb) acc) Dict.insert a b Dict.empty



-- ====== MONAD OPERATIONS ======


{-| Returns the computation that runs the given one and applies `func` to its value.
-}
map : (a -> b) -> Tracker a -> Tracker b
map func (Tracker kv) =
    Tracker <|
        \n d f ->
            case kv n d f of
                TResult props value ->
                    tResult props.uid props.deps props.fields (func value)


{-| Returns a computation that produces `value` and leaves the state unchanged.
-}
pure : a -> Tracker a
pure value =
    Tracker (\n d f -> tResult n d f value)


{-| Returns the computation that runs the given one, passes its value to
`callback`, and runs the computation `callback` returns on the state the first
left.
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


{-| Returns a computation that runs `callback` from `loopState`, again on each
`Loop` state it produces, until it produces `Done`, whose value is the result.
-}
loop : (state -> Tracker (Step state a)) -> state -> Tracker a
loop callback loopState =
    Tracker
        (\n d f ->
            loopHelper callback loopState n d f
        )


{-| Runs the loop of `loop` on the given state. It calls itself in tail
position, so a long loop does not grow the stack.
-}
loopHelper :
    (state -> Tracker (Step state a))
    -> state
    -> Int
    -> EverySet String Opt.Global
    -> Dict Name Int
    -> TResult a
loopHelper callback loopState n d f =
    case callback loopState of
        Tracker k ->
            case k n d f of
                TResult props (Loop newState) ->
                    loopHelper callback newState props.uid props.deps props.fields

                TResult props (Done a) ->
                    TResult props a


{-| Returns a computation that runs `func` on each element of `list`, first to
last, and produces the list of their values in the same order.
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


{-| Returns a computation that runs `func` on each value of `dict`, in ascending
key order, and produces a dictionary of their values under the same keys.
-}
mapTraverse : (k -> comparable) -> (a -> Tracker b) -> DataMap.Dict comparable k a -> Tracker (DataMap.Dict comparable k b)
mapTraverse toComparable func dict =
    loop
        (\( pairs, acc ) ->
            case pairs of
                [] ->
                    pure (Done acc)

                ( k, a ) :: rest ->
                    map (\b -> Loop ( rest, DataMap.insert toComparable k b acc )) (func a)
        )
        ( DataMap.toList dict, DataMap.empty )
