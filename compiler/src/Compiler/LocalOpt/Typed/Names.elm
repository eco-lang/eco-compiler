module Compiler.LocalOpt.Typed.Names exposing
    ( Tracker
    , run
    , generate
    , registerGlobal, registerKernel, registerCtor, registerDebug
    , registerField, registerFieldDict, registerFieldList
    , pure, map, andThen, traverse
    , withVarTypes, lookupLocalType
    )

{-| The state that typed local optimization carries while it rewrites code,
and the operations that read and change it.

Optimizing an expression produces more than the new expression. It also has to
record which other definitions the result refers to, its _dependencies_, so
that later phases know what to include; how often each record field name is
used; and it has to invent names for temporaries it introduces. On the typed
path it also needs the type of every local variable it meets, because each
optimized node carries a type and a local reference is typed by its binding.

`Tracker` is a state monad holding all four. `run` starts it with a counter of
0 and everything empty, and returns the dependencies, the field counts and the
result.

The _local type environment_ is a map from local variable names to their types.
It is scoped: `withVarTypes` adds bindings for one sub-computation and puts the
previous environment back after it, and `lookupLocalType` reads it, crashing
when a name is absent.

The `register*` functions add a dependency or field use and, for a reference,
return the optimized expression that stands for it.


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
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Control.Loop exposing (Step(..))
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Utils.Crash exposing (crash)



-- ====== CORE TYPE ======


{-| A computation producing an `a` that reads and updates the optimizer's
state: the counter for fresh names, the set of global dependencies, the use
count of each record field name, and the local type environment.

Values are built with `pure`, `generate`, the `register*` functions and
`lookupLocalType`, combined with `map`, `andThen`, `traverse` and
`withVarTypes`, and executed with `run`.
-}
type Tracker a
    = Tracker
        (Int
         -> EverySet String TOpt.Global
         -> Dict Name Int
         -> Dict Name (Can.Type Name)
         -> TResult a
        )


{-| The state after a `Tracker` step, together with the value it produced.
-}
type TResult a
    = TResult TResultProps a


{-| The four pieces of state a `Tracker` threads. `uid` is the index the next
fresh name will use.
-}
type alias TResultProps =
    { uid : Int
    , deps : EverySet String TOpt.Global
    , fields : Dict Name Int
    , locals : Dict Name (Can.Type Name)
    }


{-| Builds a `TResult` from the four pieces of state and the value.
-}
tResult : Int -> EverySet String TOpt.Global -> Dict Name Int -> Dict Name (Can.Type Name) -> a -> TResult a
tResult uid deps fields locals value =
    TResult { uid = uid, deps = deps, fields = fields, locals = locals } value



-- ====== RUNNING ======


{-| Runs a `Tracker` from a counter of 0, no dependencies, no field uses and an
empty local type environment, and returns the dependencies it registered, the
use count of each field name, and its result.

Each run starts the counter again, so names from `generate` are unique only
within one run.

-}
run : Tracker a -> ( EverySet String TOpt.Global, Dict Name Int, a )
run (Tracker k) =
    case k 0 EverySet.empty Dict.empty Dict.empty of
        TResult props value ->
            ( props.deps, props.fields, value )



-- ====== NAME GENERATION ======


{-| Returns a fresh name, `_v` followed by the counter, and advances the counter.

The names are distinct within one `run`, and a later run starts again from
`_v0`. They cannot collide with a name from source code, which cannot begin
with an underscore.

-}
generate : Tracker Name
generate =
    Tracker <|
        \uid deps fields locals ->
            tResult (uid + 1) deps fields locals (Name.fromVarIndex uid)



-- ====== DEPENDENCY REGISTRATION ======


{-| Returns `value`, after registering a dependency on the kernel module `home`.

The dependency is on the module as a whole, as `TOpt.toKernelGlobal` names it,
not on any one function in it.

-}
registerKernel : Name -> a -> Tracker a
registerKernel home value =
    Tracker <|
        \uid deps fields locals ->
            tResult uid (EverySet.insert TOpt.toComparableGlobal (TOpt.toKernelGlobal home) deps) fields locals value


{-| Returns a `VarGlobal` reference to `name` in module `home`, with type
`itype` and solver variable `tvar`, after registering it as a dependency.
-}
registerGlobal : A.Region -> ModuleName.Canonical -> Name -> Can.Type Name -> Maybe Vars.Variable -> Tracker (TOpt.Expr Name)
registerGlobal region home name itype tvar =
    Tracker <|
        \uid deps fields locals ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global home name
            in
            tResult uid (EverySet.insert TOpt.toComparableGlobal global deps) fields locals (TOpt.VarGlobal region global { tipe = itype, tvar = tvar })


{-| Returns a `VarDebug` reference to the `Debug` function `name`, with type
`itype` and solver variable `tvar`, after registering that function of the
`Debug` module as a dependency.

`home` is carried in the `VarDebug`, not used for the dependency, and the
reference's optional name is `Nothing`.

-}
registerDebug : Name -> ModuleName.Canonical -> A.Region -> Can.Type Name -> Maybe Vars.Variable -> Tracker (TOpt.Expr Name)
registerDebug name home region itype tvar =
    Tracker <|
        \uid deps fields locals ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global ModuleName.debug name
            in
            tResult uid (EverySet.insert TOpt.toComparableGlobal global deps) fields locals (TOpt.VarDebug region name home Nothing { tipe = itype, tvar = tvar })


{-| Returns a reference to the constructor `name` of module `home`, after
registering the constructor as a dependency. The reference's form follows
`opts`, the shape of the constructor's type (see `Can.CtorOpts`).

For `Normal` it is a `VarGlobal`. For `Enum` it is a `VarEnum` carrying
`index`, except that `True` and `False` of `Basics` become a `Bool` literal
whose type is `Bool` rather than `itype`. For `Unbox` it is a `VarBox`, and
`Basics.identity` is registered as a dependency as well.

-}
registerCtor : A.Region -> ModuleName.Canonical -> A.Located Name -> Index.ZeroBased -> Can.CtorOpts -> Can.Type Name -> Maybe Vars.Variable -> Tracker (TOpt.Expr Name)
registerCtor region home (A.At _ name) index opts itype tvar =
    Tracker <|
        \uid deps fields locals ->
            let
                global : TOpt.Global
                global =
                    TOpt.Global home name

                newDeps : EverySet String TOpt.Global
                newDeps =
                    EverySet.insert TOpt.toComparableGlobal global deps
            in
            case opts of
                Can.Normal ->
                    tResult uid newDeps fields locals (TOpt.VarGlobal region global { tipe = itype, tvar = tvar })

                Can.Enum ->
                    let
                        boolType =
                            Can.TType ModuleName.basics "Bool" []

                        meta =
                            { tipe = itype, tvar = tvar }

                        boolMeta =
                            { tipe = boolType, tvar = tvar }
                    in
                    tResult uid newDeps fields locals <|
                        case name of
                            "True" ->
                                if home == ModuleName.basics then
                                    TOpt.Bool region True boolMeta

                                else
                                    TOpt.VarEnum region global index meta

                            "False" ->
                                if home == ModuleName.basics then
                                    TOpt.Bool region False boolMeta

                                else
                                    TOpt.VarEnum region global index meta

                            _ ->
                                TOpt.VarEnum region global index meta

                Can.Unbox ->
                    tResult uid (EverySet.insert TOpt.toComparableGlobal identity newDeps) fields locals (TOpt.VarBox region global { tipe = itype, tvar = tvar })


{-| The global for `Basics.identity`, which `registerCtor` adds as a dependency
of every `Unbox` constructor.
-}
identity : TOpt.Global
identity =
    TOpt.Global ModuleName.basics Name.identity_


{-| Returns `value`, after adding one to the use count of the field `name`.
-}
registerField : Name -> a -> Tracker a
registerField name value =
    Tracker <|
        \uid d fields locals ->
            tResult uid d (insertWith (+) name 1 fields) locals value


{-| Returns `value`, after adding one to the use count of each key of
`newFields`; the dictionary's values are ignored.
-}
registerFieldDict : Dict Name v -> a -> Tracker a
registerFieldDict newFields value =
    Tracker <|
        \uid d fields locals ->
            tResult uid
                d
                (unionWith (+) fields (Dict.map (\_ _ -> 1) newFields))
                locals
                value


{-| Returns a function that stores `v` at `k` in a dictionary, or, where `k`
already holds a value `old`, stores `f v old` there.
-}
insertWith : (a -> a -> a) -> comparable -> a -> Dict comparable a -> Dict comparable a
insertWith f k v =
    Dict.update k (Maybe.map (f v) >> Maybe.withDefault v >> Just)


{-| Returns the union of `a` and `b`, with `f` combining the two values of a key
present in both.
-}
unionWith : (a -> a -> a) -> Dict comparable a -> Dict comparable a -> Dict comparable a
unionWith f a b =
    Dict.merge Dict.insert (\k va vb acc -> Dict.insert k (f va vb) acc) Dict.insert a b Dict.empty


{-| Returns `value`, after adding one to the use count of each name in `names`,
once per occurrence.
-}
registerFieldList : List Name -> a -> Tracker a
registerFieldList names value =
    Tracker <|
        \uid deps fields locals ->
            tResult uid deps (List.foldr addOne fields names) locals value


{-| Returns `fields` with one added to the use count of `name`.
-}
addOne : Name -> Dict Name Int -> Dict Name Int
addOne name fields =
    insertWith (+) name 1 fields



-- ====== LOCAL TYPE ENVIRONMENT ======


{-| Runs the given computation with `bindings` added to the local type
environment, and afterwards restores the environment it started with.

A binding replaces any type the name already had, and a later binding in the
list replaces an earlier one of the same name. The counter, dependencies and
field counts the computation leaves are kept.

-}
withVarTypes : List ( Name, Can.Type Name ) -> Tracker a -> Tracker a
withVarTypes bindings (Tracker inner) =
    Tracker <|
        \uid deps fields locals ->
            let
                extendedLocals =
                    List.foldl (\( name, itype ) acc -> Dict.insert name itype acc) locals bindings
            in
            case inner uid deps fields extendedLocals of
                TResult props value ->
                    tResult props.uid props.deps props.fields locals value


{-| Returns the type of the local variable `name` from the local type
environment, and crashes if the name has no binding there.
-}
lookupLocalType : Name -> Tracker (Can.Type Name)
lookupLocalType name =
    Tracker <|
        \uid deps fields locals ->
            case Dict.get name locals of
                Just itype ->
                    tResult uid deps fields locals itype

                Nothing ->
                    crash ("Local variable not in scope: " ++ name)



-- ====== MONAD OPERATIONS ======


{-| Returns a computation with the same effect on the state, whose result is
`func` applied to the original result.
-}
map : (a -> b) -> Tracker a -> Tracker b
map func (Tracker kv) =
    Tracker <|
        \n d f l ->
            case kv n d f l of
                TResult props value ->
                    tResult props.uid props.deps props.fields props.locals (func value)


{-| Returns a computation that leaves the state unchanged and produces `value`.
-}
pure : a -> Tracker a
pure value =
    Tracker (\n d f l -> tResult n d f l value)


{-| Returns a computation that runs the given one, passes its result to
`callback`, and runs the computation `callback` returns on the state the first
left, the local type environment included.
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


{-| Returns a computation that runs `callback` on `loopState`, and again on each
new state it returns as `Loop`, threading the tracker state through, until it
returns `Done`, whose value is the result. It runs without growing the stack.
-}
loop : (state -> Tracker (Step state a)) -> state -> Tracker a
loop callback loopState =
    Tracker
        (\n d f l ->
            loopHelper callback loopState n d f l
        )


{-| Runs the loop of `loop` from `loopState` and the given tracker state.
-}
loopHelper :
    (state -> Tracker (Step state a))
    -> state
    -> Int
    -> EverySet String TOpt.Global
    -> Dict Name Int
    -> Dict Name (Can.Type Name)
    -> TResult a
loopHelper callback loopState n d f l =
    case callback loopState of
        Tracker k ->
            case k n d f l of
                TResult props (Loop newState) ->
                    loopHelper callback newState props.uid props.deps props.fields props.locals

                TResult props (Done a) ->
                    TResult props a


{-| Returns a computation that runs `func` on each element of `list` from left
to right, threading the state through, and produces the results in list order.
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
