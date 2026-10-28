module Builder.Deps.Diff exposing
    ( PackageChanges(..), ModuleChanges(..), ModuleChangesData, Changes(..)
    , diff, getDocs
    , toMagnitude, moduleChangeMagnitude, bump
    )

{-| A package's version number must say how far its public API moved, and this
module works that out by comparing the API of two versions.

The API of a version is its documentation, the `docs.json` describing every
exposed module, type, value and operator (`Compiler.Elm.Docs`). `getDocs` fetches
it for one version. `diff` compares two of them, and `toMagnitude` reduces the
comparison to a _magnitude_, the class of change in `Compiler.Elm.Magnitude`:
MAJOR when something was removed or changed, MINOR when something was only added,
PATCH when the API is the same. `bump` applies it to a version.

The comparison is in two levels. Between versions, modules are added, removed or
kept. Within a kept module, each kind of declaration (unions, aliases, values and
operators) is split the same way, and a declaration present in both versions
counts as changed unless the two are _equivalent_. Doc comments play no part, so
editing only documentation is not a change.

Two declarations are equivalent when their types have the same structure and
their type variables correspond by an _equivalent renaming_: each old variable
maps to exactly one new one, no two old variables map to the same new one, and
each mapping is allowed by the variables' categories (`number`, `comparable`,
`appendable`, `compappend`, or unconstrained). A variable may stay in its
category, go from `number` to `comparable`, or become unconstrained; any other
change of category is a change. Record fields are compared regardless of order,
and a type name is compared by its last dotted segment when either side is
unqualified. A union also needs the same constructor names in the same order,
and an operator the same associativity and precedence. A union none of whose
exposed constructors has an argument is compared by constructor names only.


# Change Types

@docs PackageChanges, ModuleChanges, ModuleChangesData, Changes


# Diffing

@docs diff, getDocs


# Version Bumping

@docs toMagnitude, moduleChangeMagnitude, bump

-}

import Builder.Deps.Website as Website
import Builder.File as File
import Builder.Http as Http
import Builder.Reporting.Exit as Exit exposing (DocsProblem(..))
import Builder.Stuff as Stuff
import Compiler.Data.Name as Name
import Compiler.Elm.Compiler.Type as Type
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Magnitude as M
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V exposing (Version)
import Compiler.Json.Decode as D
import Data.Set as EverySet
import Dict exposing (Dict)
import Task exposing (Task)
import Utils.Main as Utils


{-| The differences between two versions of a package, module by module.

The constructor holds the names of the added modules, the changes in each module
present in both versions, and the names of the removed modules. As `diff` builds
it, a module appears among the changed ones only when its changes are more than
PATCH.

-}
type PackageChanges
    = PackageChanges (List ModuleName.Raw) (Dict ModuleName.Raw ModuleChanges) (List ModuleName.Raw)


{-| The changes in one module, one `Changes` per kind of declaration, each keyed
by declaration name. `binops` are the operators.
-}
type alias ModuleChangesData =
    { unions : Changes Name.Name Docs.Union
    , aliases : Changes Name.Name Docs.Alias
    , values : Changes Name.Name Docs.Value
    , binops : Changes Name.Name Docs.Binop
    }


{-| The changes in one module between two versions of a package.
-}
type ModuleChanges
    = ModuleChanges ModuleChangesData


{-| The differences between an old and a new collection of named items.

The constructor holds the items only in the new collection, the items in both
that are not equivalent (each with its old and then its new value), and the items
only in the old collection.

-}
type Changes k v
    = Changes (Dict k v) (Dict k ( v, v )) (Dict k v)


{-| Returns the `Changes` from `old` to `new`, where an item present in both is
changed exactly when `isEquivalent` says its old and new values are not
equivalent.
-}
getChanges : (v -> v -> Bool) -> Dict comparable v -> Dict comparable v -> Changes comparable v
getChanges isEquivalent old new =
    let
        overlap : Dict comparable ( v, v )
        overlap =
            dictIntersectionWith Tuple.pair old new

        changed : Dict comparable ( v, v )
        changed =
            Dict.filter (\_ ( v1, v2 ) -> not (isEquivalent v1 v2)) overlap
    in
    Changes
        (Dict.diff new old)
        changed
        (Dict.diff old new)


{-| Returns the entries whose key is in both dictionaries, each value made by
`func` from the value in `d1` and the value in `d2`.
-}
dictIntersectionWith : (a -> b -> c) -> Dict comparable a -> Dict comparable b -> Dict comparable c
dictIntersectionWith func d1 d2 =
    Dict.merge (\_ _ acc -> acc) (\k v1 v2 acc -> Dict.insert k (func v1 v2) acc) (\_ _ acc -> acc) d1 d2 Dict.empty



-- ====== DIFF ======


{-| Returns the changes from the API in `oldDocs` to the API in `newDocs`.

Added and removed modules are always listed. A module in both is listed among
the changed ones only when `moduleChangeMagnitude` gives more than PATCH for it.

-}
diff : Docs.Documentation -> Docs.Documentation -> PackageChanges
diff oldDocs newDocs =
    let
        filterOutPatches : Dict comparable ModuleChanges -> Dict comparable ModuleChanges
        filterOutPatches chngs =
            Dict.filter (\_ chng -> moduleChangeMagnitude chng /= M.PATCH) chngs

        (Changes added changed removed) =
            getChanges (\_ _ -> False) oldDocs newDocs
    in
    PackageChanges
        (Dict.keys added)
        (filterOutPatches (Dict.map (\_ -> diffModule) changed))
        (Dict.keys removed)


{-| Returns the changes between the old and the new documentation of one module.
-}
diffModule : ( Docs.Module, Docs.Module ) -> ModuleChanges
diffModule ( Docs.Module m1, Docs.Module m2 ) =
    ModuleChanges
        { unions = getChanges isEquivalentUnion m1.unions m2.unions
        , aliases = getChanges isEquivalentAlias m1.aliases m2.aliases
        , values = getChanges isEquivalentValue m1.values m2.values
        , binops = getChanges isEquivalentBinop m1.binops m2.binops
        }



-- ====== EQUIVALENCE ======


{-| Tells whether two versions of a union type are equivalent.

They are when they have the same constructor names in the same order and each
constructor's argument types are equivalent, with the union's type variables
paired in order. Each argument type is checked on its own, together with the
variable list, so the renaming need only be consistent within one argument and
the variable list. The variable lists must have the same length, which also
covers an opaque union and one whose constructors have no arguments.

-}
isEquivalentUnion : Docs.Union -> Docs.Union -> Bool
isEquivalentUnion (Docs.Union oldComment oldVars oldCtors) (Docs.Union newComment newVars newCtors) =
    let
        equiv : List Type.Type -> List Type.Type -> Bool
        equiv oldTypes newTypes =
            let
                allEquivalent : List Bool
                allEquivalent =
                    List.map2
                        isEquivalentAlias
                        (List.map (Docs.Alias oldComment oldVars) oldTypes)
                        (List.map (Docs.Alias newComment newVars) newTypes)
            in
            (List.length oldTypes == List.length newTypes)
                && List.all identity allEquivalent
    in
    (List.length oldVars == List.length newVars)
        && (List.length oldCtors == List.length newCtors)
        && List.all identity (List.map2 (==) (List.map Tuple.first oldCtors) (List.map Tuple.first newCtors))
        && List.all identity (Dict.values (dictIntersectionWith equiv (Dict.fromList oldCtors) (Dict.fromList newCtors)))


{-| Tells whether two versions of a type alias are equivalent: the types have the
same structure, the variable lists have the same length, and the variables they
pair, in order and wherever they occur in the types, form an equivalent renaming.
-}
isEquivalentAlias : Docs.Alias -> Docs.Alias -> Bool
isEquivalentAlias (Docs.Alias _ oldVars oldType) (Docs.Alias _ newVars newType) =
    case diffType oldType newType of
        Nothing ->
            False

        Just renamings ->
            (List.length oldVars == List.length newVars)
                && isEquivalentRenaming (List.map2 Tuple.pair oldVars newVars ++ renamings)


{-| Tells whether two versions of a value are equivalent, which is when their
types are, as for an alias with no variables.
-}
isEquivalentValue : Docs.Value -> Docs.Value -> Bool
isEquivalentValue (Docs.Value c1 t1) (Docs.Value c2 t2) =
    isEquivalentAlias (Docs.Alias c1 [] t1) (Docs.Alias c2 [] t2)


{-| Tells whether two versions of an operator are equivalent: equivalent types,
and the same associativity and precedence.
-}
isEquivalentBinop : Docs.Binop -> Docs.Binop -> Bool
isEquivalentBinop (Docs.Binop data1) (Docs.Binop data2) =
    isEquivalentAlias (Docs.Alias data1.comment [] data1.tipe) (Docs.Alias data2.comment [] data2.tipe)
        && (data1.associativity == data2.associativity)
        && (data1.precedence == data2.precedence)



-- ====== DIFF TYPES ======


{-| Returns the pairs of old and new type variable names found at the same
places in the two types, or `Nothing` when the types differ in structure or in a
type name.

The pairs are not checked here; a variable may appear in several pairs, and
`isEquivalentRenaming` decides whether they are consistent. A record's extension
variable is paired like any other variable.

-}
diffType : Type.Type -> Type.Type -> Maybe (List ( Name.Name, Name.Name ))
diffType oldType newType =
    case ( oldType, newType ) of
        ( Type.Var oldName, Type.Var newName ) ->
            Just [ ( oldName, newName ) ]

        ( Type.Lambda a b, Type.Lambda a_ b_ ) ->
            Maybe.map2 (++) (diffType a a_) (diffType b b_)

        ( Type.Type oldName oldArgs, Type.Type newName newArgs ) ->
            if not (isSameName oldName newName) || List.length oldArgs /= List.length newArgs then
                Nothing

            else
                Maybe.map List.concat (Utils.zipWithM diffType oldArgs newArgs)

        ( Type.Record fields maybeExt, Type.Record fields_ maybeExt_ ) ->
            case ( maybeExt, maybeExt_ ) of
                ( Nothing, Just _ ) ->
                    Nothing

                ( Just _, Nothing ) ->
                    Nothing

                ( Nothing, Nothing ) ->
                    diffFields fields fields_

                ( Just oldExt, Just newExt ) ->
                    Maybe.map ((::) ( oldExt, newExt )) (diffFields fields fields_)

        ( Type.Unit, Type.Unit ) ->
            Just []

        ( Type.Tuple a b cs, Type.Tuple x y zs ) ->
            if List.length cs /= List.length zs then
                Nothing

            else
                Maybe.map3 (\aVars bVars cVars -> aVars ++ bVars ++ cVars)
                    (diffType a x)
                    (diffType b y)
                    (Maybe.map List.concat (Utils.zipWithM diffType cs zs))

        _ ->
            Nothing


{-| Tells whether two type names refer to the same type.

When either name has no dots, only the last dotted segment of each is compared,
so `List` matches `List.List`. This allows for very old documentation, which does
not qualify type names. Otherwise the full names must be equal.

-}
isSameName : Name.Name -> Name.Name -> Bool
isSameName oldFullName newFullName =
    let
        dedot : String -> List String
        dedot name =
            List.reverse (String.split "." name)
    in
    case ( dedot oldFullName, dedot newFullName ) of
        ( oldName :: [], newName :: _ ) ->
            oldName == newName

        ( oldName :: _, newName :: [] ) ->
            oldName == newName

        _ ->
            oldFullName == newFullName


{-| Returns the variable pairs of two records' fields, as `diffType` does for
types, or `Nothing` when the records do not have the same field names. Field
order does not matter.
-}
diffFields : List ( Name.Name, Type.Type ) -> List ( Name.Name, Type.Type ) -> Maybe (List ( Name.Name, Name.Name ))
diffFields oldRawFields newRawFields =
    if List.length oldRawFields /= List.length newRawFields then
        Nothing

    else
        let
            sort : List ( comparable, b ) -> List ( comparable, b )
            sort fields =
                List.sortBy Tuple.first fields

            oldFields : List ( Name.Name, Type.Type )
            oldFields =
                sort oldRawFields

            newFields : List ( Name.Name, Type.Type )
            newFields =
                sort newRawFields
        in
        if List.any identity (List.map2 (/=) (List.map Tuple.first oldFields) (List.map Tuple.first newFields)) then
            Nothing

        else
            Maybe.map List.concat (Utils.zipWithM diffType (List.map Tuple.second oldFields) (List.map Tuple.second newFields))



-- ====== TYPE VARIABLES ======


{-| Tells whether a list of old and new variable pairs, as `diffType` collects
them, is an equivalent renaming: each old name pairs with a single new name, no
two old names share a new name, and `compatibleVars` allows every pair.
-}
isEquivalentRenaming : List ( Name.Name, Name.Name ) -> Bool
isEquivalentRenaming varPairs =
    let
        renamings : List ( Name.Name, List Name.Name )
        renamings =
            Dict.toList (List.foldr insert Dict.empty varPairs)

        insert : ( Name.Name, Name.Name ) -> Dict Name.Name (List Name.Name) -> Dict Name.Name (List Name.Name)
        insert ( old, new ) dict =
            Dict.update old
                (\mv ->
                    Just
                        (case mv of
                            Nothing ->
                                [ new ]

                            Just existing ->
                                new :: existing
                        )
                )
                dict

        verify : ( a, List b ) -> Maybe ( a, b )
        verify ( old, news ) =
            case news of
                [] ->
                    Nothing

                new :: rest ->
                    if List.all ((==) new) rest then
                        Just ( old, new )

                    else
                        Nothing

        allUnique : List comparable -> Bool
        allUnique list =
            List.length list == EverySet.size (EverySet.fromList identity list)
    in
    case Utils.maybeMapM verify renamings of
        Nothing ->
            False

        Just verifiedRenamings ->
            List.all compatibleVars verifiedRenamings
                && allUnique (List.map Tuple.second verifiedRenamings)


{-| Tells whether an old type variable may become the new one: either may keep
its category, `number` may become `comparable`, and any variable may become
unconstrained.
-}
compatibleVars : ( Name.Name, Name.Name ) -> Bool
compatibleVars ( old, new ) =
    case ( categorizeVar old, categorizeVar new ) of
        ( CompAppend, CompAppend ) ->
            True

        ( Comparable, Comparable ) ->
            True

        ( Appendable, Appendable ) ->
            True

        ( Number, Number ) ->
            True

        ( Number, Comparable ) ->
            True

        ( _, Var ) ->
            True

        _ ->
            False


{-| The kind of constraint a type variable's name puts on it, as
`Compiler.Data.Name` reads it from the name's prefix. `Var` is an unconstrained
variable.
-}
type TypeVarCategory
    = CompAppend
    | Comparable
    | Appendable
    | Number
    | Var


{-| Returns the category of the type variable called `name`.
-}
categorizeVar : Name.Name -> TypeVarCategory
categorizeVar name =
    if Name.isCompappendType name then
        CompAppend

    else if Name.isComparableType name then
        Comparable

    else if Name.isAppendableType name then
        Appendable

    else if Name.isNumberType name then
        Number

    else
        Var



-- ====== MAGNITUDE ======


{-| Returns `version` raised by the magnitude of `changes`, as `toMagnitude`
gives it.
-}
bump : PackageChanges -> Version -> Version
bump changes version =
    case toMagnitude changes of
        M.PATCH ->
            V.bumpPatch version

        M.MINOR ->
            V.bumpMinor version

        M.MAJOR ->
            V.bumpMajor version


{-| Returns the magnitude of the changes to a package: the largest of MAJOR if
any module was removed, MINOR if any was added, and `moduleChangeMagnitude` of
each changed module, or PATCH when there are none of these.
-}
toMagnitude : PackageChanges -> M.Magnitude
toMagnitude (PackageChanges added changed removed) =
    let
        addMag : M.Magnitude
        addMag =
            if List.isEmpty added then
                M.PATCH

            else
                M.MINOR

        removeMag : M.Magnitude
        removeMag =
            if List.isEmpty removed then
                M.PATCH

            else
                M.MAJOR

        changeMags : List M.Magnitude
        changeMags =
            List.map moduleChangeMagnitude (Dict.values changed)
    in
    Utils.listMaximum M.compare (addMag :: removeMag :: changeMags)


{-| Returns the magnitude of the changes to one module: MAJOR if any declaration
was removed or changed, otherwise MINOR if any was added, otherwise PATCH.
-}
moduleChangeMagnitude : ModuleChanges -> M.Magnitude
moduleChangeMagnitude (ModuleChanges changes) =
    Utils.listMaximum M.compare
        [ changeMagnitude changes.unions
        , changeMagnitude changes.aliases
        , changeMagnitude changes.values
        , changeMagnitude changes.binops
        ]


{-| Returns MAJOR if any item was removed or changed, otherwise MINOR if any was
added, otherwise PATCH.
-}
changeMagnitude : Changes comparable v -> M.Magnitude
changeMagnitude (Changes added changed removed) =
    if not (Dict.isEmpty removed) || not (Dict.isEmpty changed) then
        M.MAJOR

    else if not (Dict.isEmpty added) then
        M.MINOR

    else
        M.PATCH



-- ====== GET DOCS ======


{-| Returns the documentation of version `version` of package `name`.

It is read from `docs.json` in the package's directory in `cache` when that file
exists. A cached file that does not decode is deleted and `DP_Cache` returned;
the documentation is not fetched again in the same call. Otherwise it is
downloaded from the package website and, when it decodes, written to the cache.
A failed request gives `DP_Http`, and a body that does not decode gives
`DP_Data` with the URL and the body, and is not cached.

-}
getDocs : Stuff.PackageCache -> Http.Manager -> Pkg.Name -> V.Version -> Task Never (Result Exit.DocsProblem Docs.Documentation)
getDocs cache manager name version =
    let
        home : String
        home =
            Stuff.package cache name version

        path : String
        path =
            home ++ "/docs.json"
    in
    File.exists path
        |> Task.andThen
            (\exists ->
                if exists then
                    File.readUtf8 path
                        |> Task.andThen
                            (\bytes ->
                                case D.fromByteString Docs.decoder bytes of
                                    Ok docs ->
                                        Task.succeed (Ok docs)

                                    Err _ ->
                                        File.remove path
                                            |> Task.map (\_ -> Err DP_Cache)
                            )

                else
                    Website.metadata name version "docs.json"
                        |> Task.andThen
                            (\url ->
                                Http.get manager url [] Exit.DP_Http <|
                                    \body ->
                                        case D.fromByteString Docs.decoder body of
                                            Ok docs ->
                                                Utils.dirCreateDirectoryIfMissing True home
                                                    |> Task.andThen (\_ -> File.writeUtf8 path body)
                                                    |> Task.map (\_ -> Ok docs)

                                            Err _ ->
                                                Task.succeed (Err (DP_Data url body))
                            )
            )
