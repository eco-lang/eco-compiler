module Compiler.Canonicalize.Environment.Foreign exposing (FResult, createInitialEnv)

{-| Before a module's own declarations can be canonicalized, every name its
imports make available has to be in scope. This module builds that starting
environment from the import list and the interfaces of the imported modules.

An import makes names available in two ways. Every public value, type and
constructor of the imported module can be written _qualified_, with the import's
alias, or its module name when there is no alias, as the prefix. The names its
`exposing` clause lists can also be written _unqualified_, bare. Operators are
only ever unqualified.

Two imports may make the same name available. Where the names merge, a clash is
recorded as an ambiguity (`Env.Ambiguous`, built by `Env.mergeInfo`) rather than
reported here. Names merge for `exposing (..)`, for explicitly listed values,
for the constructors of an explicitly listed `Type(..)`, and for qualified names
under a shared prefix. An explicitly listed type name or operator does not
merge: it replaces any earlier entry of the same name.

What an import cannot do is name something that is not there: an explicitly
listed name the module does not expose is an error, as is `(..)` on an alias.

The type `List` is in scope before any import is read.

@docs FResult, createInitialEnv

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Environment as Env
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as Error
import Compiler.Reporting.Result as ReportingResult
import Dict exposing (Dict)
import Utils.Crash exposing (crash)
import Utils.Main as Utils


{-| A reporting result whose errors are canonicalization errors.
-}
type alias FResult i w a =
    ReportingResult.RResult i w Error.Error a


{-| Builds the environment for the module `home` from its `imports`, reading each
imported module's interface from `ifaces`.

Every import must have an entry in `ifaces`; a missing one crashes the compiler.
The imports are read in order, and the result is the error of the first import
that fails.

When `home` belongs to a kernel package, imports of kernel modules
(`Elm.Kernel.*`, `Eco.Kernel.*`) are left out, and such an import written with
`as` crashes the compiler. Elsewhere a kernel import is read like any other.

-}
createInitialEnv : ModuleName.Canonical -> Dict ModuleName.Raw I.Interface -> List Src.Import -> FResult i w Env.Env
createInitialEnv home ifaces imports =
    Utils.foldM (addImport ifaces) emptyState (toSafeImports home imports)
        |> ReportingResult.map
            (\{ vars, types, ctors, binops, q_vars, q_types, q_ctors } ->
                Env.Env home
                    (Dict.map (\_ -> infoToVar) vars)
                    types
                    ctors
                    binops
                    q_vars
                    q_types
                    q_ctors
            )


{-| Returns the variable entry for an imported value: one foreign definition,
or several when the name is ambiguous.
-}
infoToVar : Env.Info (Can.Annotation Name) -> Env.Var
infoToVar info =
    case info of
        Env.Specific home tipe ->
            Env.Foreign home tipe

        Env.Ambiguous h hs ->
            Env.Foreigns h hs



-- ====== STATE ======


{-| The environment as built so far, one import at a time: the unqualified
names of each kind, and the qualified names grouped by prefix. Operators have
no qualified form.
-}
type alias State =
    { vars : Env.Exposed (Can.Annotation Name)
    , types : Env.Exposed Env.Type
    , ctors : Env.Exposed Env.Ctor
    , binops : Env.Exposed Env.Binop
    , q_vars : Env.Qualified (Can.Annotation Name)
    , q_types : Env.Qualified Env.Type
    , q_ctors : Env.Qualified Env.Ctor
    }


{-| The state before any import is read, in which only `List` is in scope.
-}
emptyState : State
emptyState =
    State Dict.empty emptyTypes Dict.empty Dict.empty Dict.empty Dict.empty Dict.empty


{-| The unqualified types in scope before any import is read: the `List` type
of `elm/core`, which takes one type argument.
-}
emptyTypes : Env.Exposed Env.Type
emptyTypes =
    Dict.fromList [ ( "List", Env.Specific ModuleName.list (Env.Union 1 ModuleName.list) ) ]



-- ====== TO SAFE IMPORTS ======


{-| Returns `imports` without its kernel imports when the module's package is a
kernel package, and unchanged otherwise.
-}
toSafeImports : ModuleName.Canonical -> List Src.Import -> List Src.Import
toSafeImports (ModuleName.Canonical package _) imports =
    if Pkg.isKernel package then
        List.filter isNormal imports

    else
        imports


{-| Tells whether an import is of an ordinary module rather than a kernel module.

Crashes the compiler for a kernel import written with `as`.

-}
isNormal : Src.Import -> Bool
isNormal (Src.Import ( _, A.At _ name ) maybeAlias _) =
    if Name.isKernel name then
        case maybeAlias of
            Nothing ->
                False

            Just _ ->
                crash "kernel imports cannot use `as`"

    else
        True



-- ====== ADD IMPORTS ======


{-| Adds one import to `state`.

All the public names of the imported module are added under the import's prefix.
For `exposing (..)` they are all added unqualified too, operators included, and
merged with what is already there. For an explicit list each listed name is
added in turn by `addExposedValue`, and the first one that fails gives the error.

A union whose constructors are not exposed still contributes its type, and an
alias of a closed record contributes its record constructor.

-}
addImport : Dict ModuleName.Raw I.Interface -> State -> Src.Import -> FResult i w State
addImport ifaces state (Src.Import ( _, A.At _ name ) maybeAlias ( _, exposing_ )) =
    let
        (I.Interface iface) =
            Utils.dictFind name ifaces

        prefix : Name
        prefix =
            Maybe.withDefault name (Maybe.map Src.c2Value maybeAlias)

        home : ModuleName.Canonical
        home =
            ModuleName.Canonical iface.home name

        rawTypeInfo : Dict Name ( Env.Type, Env.Exposed Env.Ctor )
        rawTypeInfo =
            Dict.union
                (Dict.toList iface.unions
                    |> List.filterMap (\( k, a ) -> Maybe.map (Tuple.pair k) (unionToType home k a))
                    |> Dict.fromList
                )
                (Dict.toList iface.aliases
                    |> List.filterMap (\( k, a ) -> Maybe.map (Tuple.pair k) (aliasToType home k a))
                    |> Dict.fromList
                )

        vars : Dict Name (Env.Info (Can.Annotation Name))
        vars =
            Dict.toList iface.values
                |> List.map (\( k, v ) -> ( k, Env.Specific home v ))
                |> Dict.fromList

        types : Dict Name (Env.Info Env.Type)
        types =
            Dict.map (\_ -> Tuple.first >> Env.Specific home) rawTypeInfo

        ctors : Env.Exposed Env.Ctor
        ctors =
            Dict.foldr (\_ -> Tuple.second >> addExposed) Dict.empty rawTypeInfo

        qvs2 : Env.Qualified (Can.Annotation Name)
        qvs2 =
            addQualified prefix vars state.q_vars

        qts2 : Env.Qualified Env.Type
        qts2 =
            addQualified prefix types state.q_types

        qcs2 : Env.Qualified Env.Ctor
        qcs2 =
            addQualified prefix ctors state.q_ctors
    in
    case exposing_ of
        Src.Open _ _ ->
            let
                vs2 : Env.Exposed (Can.Annotation Name)
                vs2 =
                    addExposed state.vars vars

                ts2 : Env.Exposed Env.Type
                ts2 =
                    addExposed state.types types

                cs2 : Env.Exposed Env.Ctor
                cs2 =
                    addExposed state.ctors ctors

                bs2 : Env.Exposed Env.Binop
                bs2 =
                    addExposed state.binops (Dict.map (binopToBinop home) iface.binops)
            in
            ReportingResult.ok (State vs2 ts2 cs2 bs2 qvs2 qts2 qcs2)

        Src.Explicit (A.At _ exposedList) ->
            Utils.foldM
                (addExposedValue home vars rawTypeInfo iface.binops)
                (State state.vars state.types state.ctors state.binops qvs2 qts2 qcs2)
                (List.map Src.c2Value exposedList)


{-| Returns the union of two sets of names, with a name present in both merged
into one entry by `Env.mergeInfo`.
-}
addExposed : Env.Exposed a -> Env.Exposed a -> Env.Exposed a
addExposed =
    Utils.dictUnionWith Env.mergeInfo


{-| Adds `exposed` to `qualified` under `prefix`, merging with the names already
under that prefix.
-}
addQualified : Name -> Env.Exposed a -> Env.Qualified a -> Env.Qualified a
addQualified prefix exposed qualified =
    Utils.dictInsertWith addExposed prefix exposed qualified



-- ====== UNION ======


{-| Returns the type entry for an imported union and its constructors, or
`Nothing` when the interface does not make the union public.
-}
unionToType : ModuleName.Canonical -> Name -> I.Union -> Maybe ( Env.Type, Env.Exposed Env.Ctor )
unionToType home name union =
    Maybe.map (unionToTypeHelp home name) (I.toPublicUnion union)


{-| Returns the type entry for a public union and an entry for each of its
constructors. A union whose constructors are not exposed reaches here with no
constructors.
-}
unionToTypeHelp : ModuleName.Canonical -> Name -> Can.Union -> ( Env.Type, Env.Exposed Env.Ctor )
unionToTypeHelp home name ((Can.Union unionData) as union) =
    let
        addCtor : Can.Ctor -> Dict Name (Env.Info Env.Ctor) -> Dict Name (Env.Info Env.Ctor)
        addCtor (Can.Ctor c) dict =
            Dict.insert c.name (Env.Specific home (Env.Ctor home name union c.index c.args)) dict
    in
    ( Env.Union (List.length unionData.vars) home
    , List.foldl addCtor Dict.empty unionData.alts
    )



-- ====== ALIAS ======


{-| Returns the type entry for an imported alias and its record constructor, or
`Nothing` when the interface does not make the alias public.
-}
aliasToType : ModuleName.Canonical -> Name -> I.Alias -> Maybe ( Env.Type, Env.Exposed Env.Ctor )
aliasToType home name alias =
    Maybe.map (aliasToTypeHelp home name) (I.toPublicAlias alias)


{-| Returns the type entry for a public alias, with a record constructor when
the alias is of a closed record (one with no extension variable).

The record constructor is a function taking the fields in the order
`Can.fieldsToList` gives and returning the alias type.

-}
aliasToTypeHelp : ModuleName.Canonical -> Name -> Can.Alias -> ( Env.Type, Env.Exposed Env.Ctor )
aliasToTypeHelp home name (Can.Alias vars tipe) =
    ( Env.Alias (List.length vars) home vars tipe
    , case tipe of
        Can.TRecord fields Nothing ->
            let
                avars : List ( Name, Can.Type Name )
                avars =
                    List.map (\var -> ( var, Can.TVar var )) vars

                alias_ : Can.Type Name
                alias_ =
                    List.foldr
                        (\( _, t1 ) t2 -> Can.tLambda t1 t2)
                        (Can.TAlias home name avars (Can.Filled tipe))
                        (Can.fieldsToList fields)
            in
            Dict.singleton name (Env.Specific home (Env.RecordCtor home vars alias_))

        _ ->
            Dict.empty
    )



-- ====== BINOP ======


{-| Returns the entry for the operator `op` exported by the module `home`.
-}
binopToBinop : ModuleName.Canonical -> Name -> I.Binop -> Env.Info Env.Binop
binopToBinop home op (I.Binop data) =
    Env.Specific home (Env.Binop { op = op, home = home, name = data.name, annotation = data.annotation, associativity = data.associativity, precedence = data.precedence })



-- ====== ADD EXPOSED VALUE ======


{-| Adds one name from an import's explicit `exposing` list to the unqualified
names in `state`, or fails with an import error.

A lower-case name is a value and is merged with any earlier entry. An operator,
and a type name, replace any earlier entry. A type listed without `(..)` adds
only the type when it is a union, and, for an alias of a closed record, also its
record constructor. A type listed with `(..)` adds a union's constructors,
merged with earlier entries, and is an error for an alias. An unknown
capitalized name that is the constructor of one of the module's public unions
is reported as an attempt to import a constructor by name.

-}
addExposedValue :
    ModuleName.Canonical
    -> Env.Exposed (Can.Annotation Name)
    -> Dict Name ( Env.Type, Env.Exposed Env.Ctor )
    -> Dict Name I.Binop
    -> State
    -> Src.Exposed
    -> FResult i w State
addExposedValue home vars types binops state exposed =
    case exposed of
        Src.Lower (A.At region name) ->
            case Dict.get name vars of
                Just info ->
                    ReportingResult.ok { state | vars = Utils.dictInsertWith Env.mergeInfo name info state.vars }

                Nothing ->
                    ReportingResult.throw (Error.ImportExposingNotFound region home name (Dict.keys vars))

        Src.Upper (A.At region name) ( _, privacy ) ->
            case privacy of
                Src.Private ->
                    case Dict.get name types of
                        Just ( tipe, ctors ) ->
                            case tipe of
                                Env.Union _ _ ->
                                    let
                                        ts2 : Dict Name (Env.Info Env.Type)
                                        ts2 =
                                            Dict.insert name (Env.Specific home tipe) state.types
                                    in
                                    ReportingResult.ok { state | types = ts2 }

                                Env.Alias _ _ _ _ ->
                                    let
                                        ts2 : Dict Name (Env.Info Env.Type)
                                        ts2 =
                                            Dict.insert name (Env.Specific home tipe) state.types

                                        cs2 : Env.Exposed Env.Ctor
                                        cs2 =
                                            addExposed state.ctors ctors
                                    in
                                    ReportingResult.ok { state | types = ts2, ctors = cs2 }

                        Nothing ->
                            case checkForCtorMistake name types of
                                tipe :: _ ->
                                    Error.ImportCtorByName region name tipe |> ReportingResult.throw

                                [] ->
                                    Error.ImportExposingNotFound region home name (Dict.keys types) |> ReportingResult.throw

                Src.Public dotDotRegion ->
                    case Dict.get name types of
                        Just ( tipe, ctors ) ->
                            case tipe of
                                Env.Union _ _ ->
                                    let
                                        ts2 : Dict Name (Env.Info Env.Type)
                                        ts2 =
                                            Dict.insert name (Env.Specific home tipe) state.types

                                        cs2 : Env.Exposed Env.Ctor
                                        cs2 =
                                            addExposed state.ctors ctors
                                    in
                                    ReportingResult.ok { state | types = ts2, ctors = cs2 }

                                Env.Alias _ _ _ _ ->
                                    ReportingResult.throw (Error.ImportOpenAlias dotDotRegion name)

                        Nothing ->
                            ReportingResult.throw (Error.ImportExposingNotFound region home name (Dict.keys types))

        Src.Operator region op ->
            case Dict.get op binops of
                Just binop ->
                    let
                        bs2 : Dict Name (Env.Info Env.Binop)
                        bs2 =
                            Dict.insert op (binopToBinop home op binop) state.binops
                    in
                    ReportingResult.ok { state | binops = bs2 }

                Nothing ->
                    ReportingResult.throw (Error.ImportExposingNotFound region home op (Dict.keys binops))


{-| Returns the names of the unions in `types` that have a constructor named
`givenName`.
-}
checkForCtorMistake : Name -> Dict Name ( Env.Type, Env.Exposed Env.Ctor ) -> List Name
checkForCtorMistake givenName types =
    let
        addMatches : a -> ( b, Dict Name (Env.Info Env.Ctor) ) -> List Name -> List Name
        addMatches _ ( _, exposedCtors ) matches =
            Dict.foldr addMatch matches exposedCtors

        addMatch : Name -> Env.Info Env.Ctor -> List Name -> List Name
        addMatch ctorName info matches =
            if ctorName /= givenName then
                matches

            else
                case info of
                    Env.Specific _ (Env.Ctor _ tipeName _ _ _) ->
                        tipeName :: matches

                    Env.Specific _ (Env.RecordCtor _ _ _) ->
                        matches

                    Env.Ambiguous _ _ ->
                        matches
    in
    Dict.foldr addMatches [] types
