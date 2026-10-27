module Builder.Elm.Details exposing
    ( Details(..), DetailsData, BuildID, ValidOutline(..)
    , Local(..), LocalData, Foreign(..), Status
    , Extras, Interfaces
    , PackageTypedArtifacts, packageTypedArtifactsDecoder
    , load, verifyInstall
    , loadObjects, loadTypedObjects, loadInterfaces
    , detailsEncoder, localEncoder, localDecoder
    )

{-| A project's own modules can only be compiled once every package it depends
on is known, downloaded and compiled, and this module is where that happens. Its
result is the _project details_: a record of the project and its dependencies
that the build of the project's own modules starts from, stored in `d.dat` so
that the work is not repeated.

The details are made from `elm.json`. Its dependencies are solved to exact
versions, and every package in the solution is then verified in parallel, one
thread per package: found in the package cache, copied in from a local package
linked with `--local-package`, or downloaded and checked against its published
hash. A package is compiled in the package cache, and its artifacts are kept
there for reuse by every project.

Two ideas decide when work can be reused.

A package's artifacts depend on the versions of its own dependencies it was
compiled against. That set of versions is the package's _fingerprint_, and a
package's cached artifacts record every fingerprint they are valid for. A
package whose cached artifacts can be read is compiled again only when the
solution gives it a fingerprint they do not record.

Stored details are reused only while they still describe the project:
`elm.json` unchanged, the same build path, the same local package sources and,
when the caller asks, the same back-end configuration (see `load`). Each reuse
raises a build counter, the `BuildID`, which the build of the project's own
modules uses to decide what to recompile (see `LocalData`).

There are two build paths, and they keep separate artifacts. The JavaScript
path compiles each package to an untyped object graph stored in its
`artifacts.dat`; the typed (MLIR) path compiles it to a typed object graph and
type environment stored in its `typed-artifacts.dat`. The details record which
path they were made for, and a typed build's details carry an empty untyped
graph. Typed artifacts are read back with `loadTypedObjects`.

Fresh details hold the interfaces and merged object graph of every
dependency, and are written to `d.dat` together with copies of both in `i.dat`
and `o.dat`. A module of a package that is not a direct dependency is visible
to the project only through its types, and the _foreign modules_, those the
project can import, are the ones its direct dependencies expose.

Most of the file is the machinery of building one package: crawling its
modules from the exposed ones, compiling them in parallel with each module
waiting on its imports through MVars, and writing the artifacts and docs. The
encoders and decoders at the end serve both the stored files (`d.dat`, `i.dat`,
`o.dat`, `artifacts.dat`, `typed-artifacts.dat`) and values passed through
MVars, which are stored in binary form.


# Core Types

@docs Details, DetailsData, BuildID, ValidOutline


# Module Status Tracking

@docs Local, LocalData, Foreign, Status


# Build Artifacts

@docs Extras, Interfaces


# Typed Artifacts

@docs PackageTypedArtifacts, packageTypedArtifactsDecoder


# Loading and Verification

@docs load, verifyInstall


# Artifact Loading

@docs loadObjects, loadTypedObjects, loadInterfaces


# Serialization

@docs detailsEncoder, localEncoder, localDecoder

-}

import Builder.BackgroundWriter as BW
import Builder.Deps.Registry as Registry
import Builder.Deps.Solver as Solver
import Builder.Deps.Website as Website
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.GraphAssembly as GA
import Builder.Http as Http
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Builder.Stuff as Stuff
import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Compile as Compile
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Eco.Config as Config
import Compiler.Elm.Constraint as Con
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Interface as I
import Compiler.Elm.Kernel as Kernel
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Module as Parse
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as Doc
import Compiler.Reporting.Error as Error
import Compiler.Reporting.Error.Syntax as Syntax
import Data.Map as EveryDict
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Result.Extra
import System.IO exposing (FilePath, MVar)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== STDLIB DICT HELPERS ======


{-| Returns the union of two dictionaries, combining the two values with `f`
where both have a key.
-}
stdUnionWith : (v -> v -> v) -> Dict comparable v -> Dict comparable v -> Dict comparable v
stdUnionWith f d1 d2 =
    Dict.merge Dict.insert (\k v1 v2 acc -> Dict.insert k (f v1 v2) acc) Dict.insert d1 d2 Dict.empty


{-| Returns the entries of `dict` for which `f` gives `Just`, holding what `f`
gave.
-}
stdMapMaybe : (v -> Maybe w) -> Dict comparable v -> Dict comparable w
stdMapMaybe f dict =
    Dict.foldl
        (\k v acc ->
            case f v of
                Just w ->
                    Dict.insert k w acc

                Nothing ->
                    acc
        )
        Dict.empty
        dict


{-| Returns the entries of `d1` whose key is also in `d2`.
-}
stdIntersection : Dict comparable a -> Dict comparable b -> Dict comparable a
stdIntersection d1 d2 =
    Dict.filter (\k _ -> Dict.member k d2) d1


{-| Runs `f` on every entry in key order, one after another, and returns a
dictionary of the results under the same keys.
-}
stdTraverseWithKey : (comparable -> a -> Task Never b) -> Dict comparable a -> Task Never (Dict comparable b)
stdTraverseWithKey f =
    Dict.foldl
        (\k a -> Task.andThen (\c -> Task.map (\va -> Dict.insert k va c) (f k a)))
        (Task.succeed Dict.empty)


{-| Runs `f` on every value in key order and returns a dictionary of the results
under the same keys.
-}
stdTraverse : (a -> Task Never b) -> Dict comparable a -> Task Never (Dict comparable b)
stdTraverse f =
    stdTraverseWithKey (\_ -> f)


{-| Runs `f` on every value in key order and discards the results.
-}
stdDictMapM_ : (a -> Task Never b) -> Dict comparable a -> Task Never ()
stdDictMapM_ f =
    Dict.foldl (\_ a acc -> Task.andThen (\_ -> Task.map (\_ -> ()) (f a)) acc) (Task.succeed ())


{-| Returns every value of the dictionary if all are `Ok`, and otherwise an `Err`
found while folding the entries in key order.
-}
stdSequenceResult : Dict comparable (Result e v) -> Result e (Dict comparable v)
stdSequenceResult =
    Dict.foldl
        (\k rv acc ->
            case ( rv, acc ) of
                ( Ok v, Ok dict ) ->
                    Ok (Dict.insert k v dict)

                ( Err e, _ ) ->
                    Err e

                ( _, Err e ) ->
                    Err e
        )
        (Ok Dict.empty)


{-| Returns every value of the dictionary if all are `Just`, and `Nothing`
otherwise.
-}
stdSequenceMaybe : Dict comparable (Maybe v) -> Maybe (Dict comparable v)
stdSequenceMaybe =
    Dict.foldl
        (\k mv acc ->
            case ( mv, acc ) of
                ( Just v, Just dict ) ->
                    Just (Dict.insert k v dict)

                _ ->
                    Nothing
        )
        (Just Dict.empty)



-- ====== DETAILS ======


{-| The contents of the project details: what a build of the project's own
modules needs to know about the project and its dependencies, and what decides
whether the stored copy in `d.dat` can be reused.

`time` is the modification time of the project's `elm.json` when the details
were made. `locals` is empty in details made by this module; the build of the
project's own modules fills it. `foreigns` holds only modules exposed by a
direct dependency. `deps` is the exact version of every package in the
solution, direct or not. `hasTypedOpt` says whether the dependencies were built
for the typed (MLIR) path rather than the JavaScript path. `configHash` is the
hash of the back-end configuration the details were made under, and
`localFingerprint` combines the fingerprints of the sources of every package
linked with `--local-package`; `load` compares both with the current ones.

-}
type alias DetailsData =
    { time : File.Time
    , outline : ValidOutline
    , buildID : BuildID
    , locals : Dict ModuleName.Raw Local
    , foreigns : Dict ModuleName.Raw Foreign
    , extras : Extras
    , deps : Dict Pkg.Name V.Version
    , hasTypedOpt : Bool
    , configHash : String
    , localFingerprint : String
    }


{-| The project details: the record `load` returns and stores in `d.dat`, with
the fields described at `DetailsData`.
-}
type Details
    = Details DetailsData


{-| A build counter. `load` adds one to it each time it reuses stored details,
and fresh details start at 0. A local module records the counter values at
which its interface last changed and at which it was last compiled (see
`LocalData`).

This is a name for `Int`, not a new type.

-}
type alias BuildID =
    Int


{-| The project's `elm.json` after its dependencies have been verified.

`ValidApp` carries the source directories of an application.

`ValidPkg` carries a package's name, its exposed modules, and the exact version
of every package in the solution: its dependencies, its test dependencies, and
their dependencies.

-}
type ValidOutline
    = ValidApp (NE.Nonempty Outline.SrcDir)
    | ValidPkg Pkg.Name (List ModuleName.Raw) (Dict Pkg.Name V.Version )


{-| What the details record about one of the project's own modules, from its
last compilation.

Two things decide whether such a module must be compiled again. `time` is the
file's modification time when it was last compiled, and any difference from the
current time, earlier or later, counts as a change, so a reverted file is
caught too. `lastChange` is the `BuildID` at which the module's interface last
changed, and `lastCompile` the `BuildID` at which the module was last compiled;
they differ when a recompilation left the interface as it was. A module whose
`lastCompile` is below the `lastChange` of one of its imports is out of date,
which can happen when a project has several entry points and some modules are
compiled less often than their imports. `Builder.Build` applies these rules.

-}
type alias LocalData =
    { path : FilePath
    , time : File.Time
    , deps : List ModuleName.Raw
    , hasMain : Bool
    , lastChange : BuildID
    , lastCompile : BuildID
    }


{-| One of the project's own modules, as the details record it (see
`LocalData`).
-}
type Local
    = Local LocalData


{-| A module that a direct dependency exposes, with the packages that expose it.

The first package is one that exposes it and the list holds every other one,
so a non-empty list means the name is ambiguous.

-}
type Foreign
    = Foreign Pkg.Name (List Pkg.Name)


{-| The interfaces and object graph of the dependencies, as the details carry
them.

`ArtifactsFresh` holds them in memory: the interfaces of every module of every
dependency, and the dependencies' merged object graph. This module writes the
whole of both into `d.dat`, so details read back from `d.dat` also hold
`ArtifactsFresh`.

`ArtifactsCached` says they are to be read from `o.dat` and `i.dat` instead.
This module never makes one; only decoding a stored value can produce it.

After a typed build the object graph is empty, because typed dependencies are
loaded with `loadTypedObjects` instead.

-}
type Extras
    = ArtifactsCached
    | ArtifactsFresh Interfaces Opt.GlobalGraph


{-| The interfaces of every module of every dependency, keyed by canonical module
name. A module of a package that is not a direct dependency appears reduced to
its types, by `Compiler.Elm.Interface.privatize`, and a module that its package
does not expose is reduced by `Compiler.Elm.Interface.private`.
-}
type alias Interfaces =
    EveryDict.Dict String ModuleName.Canonical I.DependencyInterface



-- ====== LOAD ARTIFACTS ======


{-| Returns an MVar holding the dependencies' merged object graph. With
`ArtifactsFresh` details it is filled at once from memory; with
`ArtifactsCached` a forked thread fills it from `o.dat` (under `root` and
`maybeBuildDir`), with `Nothing` when that file is missing or cannot be
decoded.
-}
loadObjects : FilePath -> Maybe String -> Details -> Task Never (MVar (Maybe Opt.GlobalGraph))
loadObjects root maybeBuildDir (Details detailsData) =
    let
        extras =
            detailsData.extras
    in
    case extras of
        ArtifactsFresh _ o ->
            Utils.newMVar (Utils.maybeEncoder Opt.globalGraphEncoder) (Just o)

        ArtifactsCached ->
            fork (Utils.maybeEncoder Opt.globalGraphEncoder) (File.readBinary Opt.globalGraphDecoder (Stuff.objectsWithBuildDir root maybeBuildDir))


{-| Returns an MVar that a forked thread fills with the typed object graph and
global type environment of every dependency in the details, merged.

Only dependencies are loaded, from each package's `typed-artifacts.dat` in the
package cache; the project's own modules are not included. `locals` is only
used to build the package-cache value.

The MVar holds `Err paths` when the `typed-artifacts.dat` of one or more
dependencies is missing or cannot be decoded. Those files live in the package
cache, outside the project, so stored details can outlive them. `load`
regenerates the details when one is missing; a file that exists but cannot be
decoded is reported only here.

-}
loadTypedObjects : List ( Pkg.Name, FilePath ) -> Details -> Task Never (MVar (Result (List FilePath) PackageTypedArtifacts))
loadTypedObjects locals (Details detailsData) =
    fork (BE.result (BE.list BE.string) packageTypedArtifactsEncoder)
        (Stuff.getPackageCache locals
            |> Task.andThen (loadPackageTypedArtifacts detailsData.deps)
        )


{-| Returns the typed object graphs and type environments of every package in
`deps`, merged, or the paths of the `typed-artifacts.dat` files that could not
be read.
-}
loadPackageTypedArtifacts : Dict Pkg.Name V.Version -> Stuff.PackageCache -> Task Never (Result (List FilePath) PackageTypedArtifacts)
loadPackageTypedArtifacts deps cache =
    Utils.dictTraverseWithKey (loadSinglePackageTypedArtifacts cache) deps
        |> Task.map
            (\loadedArtifacts ->
                case List.filterMap Result.Extra.error (Dict.values loadedArtifacts) of
                    [] ->
                        Ok
                            (Dict.foldl
                                (\_ loaded acc ->
                                    case loaded of
                                        Ok arts ->
                                            { typedGraph = GA.addTypedGlobalGraph arts.typedGraph acc.typedGraph
                                            , typeEnv = TypeEnv.mergeGlobalTypeEnv arts.typeEnv acc.typeEnv
                                            }

                                        Err _ ->
                                            acc
                                )
                                { typedGraph = TOpt.emptyGlobalGraph, typeEnv = TypeEnv.emptyGlobalTypeEnv }
                                loadedArtifacts
                            )

                    unreadable ->
                        Err unreadable
            )


{-| Returns the typed object graph and type environment of one package, or the
path of its `typed-artifacts.dat` if that file is missing or cannot be decoded.
The file also holds fingerprints and interfaces, which are dropped here.
-}
loadSinglePackageTypedArtifacts : Stuff.PackageCache -> Pkg.Name -> V.Version -> Task Never (Result FilePath PackageTypedArtifacts)
loadSinglePackageTypedArtifacts cache pkg vsn =
    let
        path : String
        path =
            Stuff.typedPackageArtifacts cache pkg vsn

        project : TypedArtifactCache -> PackageTypedArtifacts
        project (TypedArtifactCache _ _ typedGraph typeEnv) =
            { typedGraph = typedGraph, typeEnv = typeEnv }
    in
    File.readBinary typedArtifactCacheDecoder path
        |> Task.map (Maybe.map project >> Result.fromMaybe path)



-- ====== PACKAGE TYPED ARTIFACTS ======


{-| The typed object graph and global type environment of a set of packages,
which is what the typed path needs from dependencies.
-}
type alias PackageTypedArtifacts =
    { typedGraph : TOpt.GlobalGraph Name
    , typeEnv : TypeEnv.GlobalTypeEnv
    }


{-| Encodes typed artifacts as their graph followed by their type environment.
-}
packageTypedArtifactsEncoder : PackageTypedArtifacts -> Bytes.Encode.Encoder
packageTypedArtifactsEncoder arts =
    Bytes.Encode.sequence
        [ TOpt.globalGraphEncoder arts.typedGraph
        , TypeEnv.globalTypeEnvEncoder arts.typeEnv
        ]


{-| A decoder for typed artifacts written by `packageTypedArtifactsEncoder`.
-}
packageTypedArtifactsDecoder : Bytes.Decode.Decoder PackageTypedArtifacts
packageTypedArtifactsDecoder =
    Bytes.Decode.map2 PackageTypedArtifacts
        TOpt.globalGraphDecoder
        TypeEnv.globalTypeEnvDecoder



-- ====== LOAD TYPE ENVIRONMENTS ======


{-| Returns an MVar holding the interfaces of every dependency module. With
`ArtifactsFresh` details it is filled at once from memory; with
`ArtifactsCached` a forked thread fills it from `i.dat` (under `root` and
`maybeBuildDir`), with `Nothing` when that file is missing or cannot be
decoded.
-}
loadInterfaces : FilePath -> Maybe String -> Details -> Task Never (MVar (Maybe Interfaces))
loadInterfaces root maybeBuildDir (Details detailsData) =
    case detailsData.extras of
        ArtifactsFresh i _ ->
            Utils.newMVar (Utils.maybeEncoder interfacesEncoder) (Just i)

        ArtifactsCached ->
            fork (Utils.maybeEncoder interfacesEncoder) (File.readBinary interfacesDecoder (Stuff.interfacesWithBuildDir root maybeBuildDir))



-- ====== VERIFY INSTALL ======


{-| Verifies the dependencies of `outline` for the project at `root`: solves them,
downloads and builds whatever the package cache lacks, and writes fresh
details, as `load` does when it regenerates, without reading stored details.

The dependencies are built for the JavaScript path, the details go to the
default `eco-stuff` location with no build directory, and they record the
default configuration's hash. Progress is not reported, and package compile
errors are not printed.

-}
verifyInstall : BW.Scope -> FilePath -> Solver.Env -> Outline.Outline -> Task Never (Result Exit.Details ())
verifyInstall scope root (Solver.Env env) outline =
    localPackagesFingerprint (Stuff.localPackages env.cache)
        |> Task.andThen
            (\localFingerprint ->
                File.getTime (root ++ "/elm.json")
                    |> Task.andThen (runVerifyInstall scope root env.cache env.manager env.connection env.registry localFingerprint outline)
            )


{-| Runs `verifyInstall` once `elm.json`'s modification time `time` and the
local packages' fingerprint are known.
-}
runVerifyInstall : BW.Scope -> FilePath -> Stuff.PackageCache -> Http.Manager -> Solver.Connection -> Registry.Registry -> String -> Outline.Outline -> File.Time -> Task Never (Result Exit.Details ())
runVerifyInstall scope root cache manager connection registry localFingerprint outline time =
    let
        key : Reporting.Key msg
        key =
            Reporting.ignorer

        env : Env
        env =
            Env { key = key, scope = scope, root = root, maybeBuildDir = Nothing, cache = cache, manager = manager, connection = connection, registry = registry, needsTypedOpt = False, showPackageErrors = False, configHash = Config.hash Config.default, localFingerprint = localFingerprint }
    in
    case outline of
        Outline.Pkg pkg ->
            Task.run (Task.map (\_ -> ()) (verifyPkg env time pkg))

        Outline.App app ->
            Task.run (Task.map (\_ -> ()) (verifyApp env time app))



-- ====== LOAD ======


{-| Returns the project details for the project at `root`, reusing the stored
`d.dat` (under `maybeBuildDir`) when it is still valid and regenerating it
otherwise.

Stored details are reused, with `BuildID` raised by one, only when all of these
hold: `elm.json` has the same modification time; they were made for the same
path (typed when `needsTypedOpt`, JavaScript otherwise); the fingerprint of the
packages in `locals` is unchanged; for a typed build, every dependency's
`typed-artifacts.dat` still exists; and, when `maybeConfigHash` is `Just`, it
equals the stored hash. With `Nothing` the configuration is not compared at
all, and regenerated details store the default configuration's hash.

Regenerating reads `elm.json`, solves the dependencies, downloads and builds
any package whose cached artifacts were not built against the solved versions
of its own dependencies, and writes `o.dat`, `i.dat` and `d.dat`. The fresh
details have `BuildID` 0 and no local modules. When `showPackageErrors` is set,
a package's compile errors are printed to stderr.

-}
load : Reporting.Style -> BW.Scope -> FilePath -> Maybe String -> Maybe String -> Bool -> Bool -> List ( Pkg.Name, FilePath ) -> Registry.RegistryPolicy -> Task Never (Result Exit.Details Details)
load style scope root maybeBuildDir maybeConfigHash needsTypedOpt showPackageErrors locals registryPolicy =
    File.getTime (root ++ "/elm.json")
        |> Task.andThen (loadWithTime style scope root maybeBuildDir maybeConfigHash needsTypedOpt showPackageErrors locals registryPolicy)


{-| Continues `load` once `elm.json`'s modification time `newTime` is known, by
reading the stored details.
-}
loadWithTime : Reporting.Style -> BW.Scope -> FilePath -> Maybe String -> Maybe String -> Bool -> Bool -> List ( Pkg.Name, FilePath ) -> Registry.RegistryPolicy -> File.Time -> Task Never (Result Exit.Details Details)
loadWithTime style scope root maybeBuildDir maybeConfigHash needsTypedOpt showPackageErrors locals registryPolicy newTime =
    File.readBinary detailsDecoder (Stuff.detailsWithBuildDir root maybeBuildDir)
        |> Task.andThen (handleCachedDetails style scope root maybeBuildDir maybeConfigHash needsTypedOpt showPackageErrors locals registryPolicy newTime)


{-| Continues `load` with the stored details, if any, by computing the
fingerprint of the packages in `locals`.
-}
handleCachedDetails : Reporting.Style -> BW.Scope -> FilePath -> Maybe String -> Maybe String -> Bool -> Bool -> List ( Pkg.Name, FilePath ) -> Registry.RegistryPolicy -> File.Time -> Maybe Details -> Task Never (Result Exit.Details Details)
handleCachedDetails style scope root maybeBuildDir maybeConfigHash needsTypedOpt showPackageErrors locals registryPolicy newTime maybeDetails =
    localPackagesFingerprint locals
        |> Task.andThen (handleCachedDetailsWithFingerprint style scope root maybeBuildDir maybeConfigHash needsTypedOpt showPackageErrors locals registryPolicy newTime maybeDetails)


{-| Returns the stored details with `BuildID` raised by one if they are still
valid, and regenerated details otherwise, by the tests `load` describes.
-}
handleCachedDetailsWithFingerprint : Reporting.Style -> BW.Scope -> FilePath -> Maybe String -> Maybe String -> Bool -> Bool -> List ( Pkg.Name, FilePath ) -> Registry.RegistryPolicy -> File.Time -> Maybe Details -> String -> Task Never (Result Exit.Details Details)
handleCachedDetailsWithFingerprint style scope root maybeBuildDir maybeConfigHash needsTypedOpt showPackageErrors locals registryPolicy newTime maybeDetails localFingerprint =
    let
        resolvedConfigHash : String
        resolvedConfigHash =
            Maybe.withDefault (Config.hash Config.default) maybeConfigHash

        regenerate : Task Never (Result Exit.Details Details)
        regenerate =
            generate style scope root maybeBuildDir resolvedConfigHash localFingerprint needsTypedOpt showPackageErrors locals registryPolicy newTime
    in
    case maybeDetails of
        Nothing ->
            regenerate

        Just (Details detailsData) ->
            if detailsData.time /= newTime then
                regenerate

            else if needsTypedOpt /= detailsData.hasTypedOpt then
                -- Details made for one path lack the other path's artifacts.
                regenerate

            else if configChanged maybeConfigHash detailsData.configHash then
                regenerate

            else if localFingerprint /= detailsData.localFingerprint then
                regenerate

            else if needsTypedOpt then
                -- The package cache can lose these files while d.dat stays valid.
                typedPackageArtifactsExist locals detailsData.deps
                    |> Task.andThen
                        (\allExist ->
                            if allExist then
                                Task.succeed (Ok (Details { detailsData | buildID = detailsData.buildID + 1 }))

                            else
                                regenerate
                        )

            else
                Task.succeed (Ok (Details { detailsData | buildID = detailsData.buildID + 1 }))


{-| Returns whether the package cache holds a `typed-artifacts.dat` for every
package in `deps`. Only existence is checked.
-}
typedPackageArtifactsExist : List ( Pkg.Name, FilePath ) -> Dict Pkg.Name V.Version -> Task Never Bool
typedPackageArtifactsExist locals deps =
    Stuff.getPackageCache locals
        |> Task.andThen
            (\cache ->
                Utils.listTraverse
                    (\( pkg, vsn ) -> Utils.dirDoesFileExist (Stuff.typedPackageArtifacts cache pkg vsn))
                    (Dict.toList deps)
            )
        |> Task.map (List.all identity)


{-| Returns one string combining each local package's name with the fingerprint
of its source, as `Builder.File.fingerprintPackageSource` computes it, in
package-name order. It is stored in `d.dat` so that a change to a local
package's source makes `load` regenerate the details.
-}
localPackagesFingerprint : List ( Pkg.Name, FilePath ) -> Task Never String
localPackagesFingerprint locals =
    locals
        |> List.sortBy (\( pkg, _ ) -> Pkg.toChars pkg)
        |> Utils.listTraverse
            (\( pkg, path ) ->
                File.fingerprintPackageSource path
                    |> Task.map (\fp -> Pkg.toChars pkg ++ "=" ++ fp)
            )
        |> Task.map (String.join ";")


{-| Returns whether the configuration hash the caller supplied differs from the
stored one. With `Nothing` it is always `False`.
-}
configChanged : Maybe String -> String -> Bool
configChanged maybeConfigHash storedConfigHash =
    case maybeConfigHash of
        Just h ->
            h /= storedConfigHash

        Nothing ->
            False



-- ====== GENERATE ======


{-| Makes fresh details: reads `elm.json` and the package registry, then
verifies and builds the dependencies, reporting progress in `style`.
-}
generate : Reporting.Style -> BW.Scope -> FilePath -> Maybe String -> String -> String -> Bool -> Bool -> List ( Pkg.Name, FilePath ) -> Registry.RegistryPolicy -> File.Time -> Task Never (Result Exit.Details Details)
generate style scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors locals registryPolicy time =
    Reporting.trackDetails style
        (\key ->
            initEnv key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors locals registryPolicy
                |> Task.andThen (verifyOutline time)
        )


{-| Verifies the dependencies of the outline in `result` as a package or an
application, passing an earlier failure through.
-}
verifyOutline : File.Time -> Result Exit.Details ( Env, Outline.Outline ) -> Task Never (Result Exit.Details Details)
verifyOutline time result =
    case result of
        Err exit ->
            Task.succeed (Err exit)

        Ok ( env, outline ) ->
            case outline of
                Outline.Pkg pkg ->
                    Task.run (verifyPkg env time pkg)

                Outline.App app ->
                    Task.run (verifyApp env time app)



-- ====== ENV ======


{-| Everything that verifying and building the dependencies needs: where to
write, the package cache and registry, how to reach the network, and the
settings that go into the fresh details.
-}
type alias EnvData =
    { key : Reporting.DKey
    , scope : BW.Scope
    , root : FilePath
    , maybeBuildDir : Maybe String
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , connection : Solver.Connection
    , registry : Registry.Registry
    , needsTypedOpt : Bool
    , showPackageErrors : Bool
    , configHash : String
    , localFingerprint : String
    }


{-| The environment for verifying and building dependencies (see `EnvData`).
-}
type Env
    = Env EnvData


{-| Returns the environment and the project's outline, reading the package
registry on a forked thread while `elm.json` is read.
-}
initEnv : Reporting.DKey -> BW.Scope -> FilePath -> Maybe String -> String -> String -> Bool -> Bool -> List ( Pkg.Name, FilePath ) -> Registry.RegistryPolicy -> Task Never (Result Exit.Details ( Env, Outline.Outline ))
initEnv key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors locals registryPolicy =
    fork resultRegistryProblemEnvEncoder (Solver.initEnv registryPolicy locals)
        |> Task.andThen (initEnvWithMVar key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors)


{-| Reads the project's outline and then combines it with the registry result
that `mvar` will hold.
-}
initEnvWithMVar : Reporting.DKey -> BW.Scope -> FilePath -> Maybe String -> String -> String -> Bool -> Bool -> MVar (Result Exit.RegistryProblem Solver.Env) -> Task Never (Result Exit.Details ( Env, Outline.Outline ))
initEnvWithMVar key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors mvar =
    Outline.read root
        |> Task.andThen (handleOutlineForEnv key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors mvar)


{-| Returns the environment and outline once the outline is read, or the
outline's problem.
-}
handleOutlineForEnv : Reporting.DKey -> BW.Scope -> FilePath -> Maybe String -> String -> String -> Bool -> Bool -> MVar (Result Exit.RegistryProblem Solver.Env) -> Result Exit.Outline Outline.Outline -> Task Never (Result Exit.Details ( Env, Outline.Outline ))
handleOutlineForEnv key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors mvar eitherOutline =
    case eitherOutline of
        Err problem ->
            Task.succeed (Err (Exit.DetailsBadOutline problem))

        Ok outline ->
            Utils.readMVar resultRegistryProblemEnvDecoder mvar
                |> Task.map (combineEnvAndOutline key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors outline)


{-| Builds the environment from the solver environment and the settings, or
reports that the registry could not be read.
-}
combineEnvAndOutline : Reporting.DKey -> BW.Scope -> FilePath -> Maybe String -> String -> String -> Bool -> Bool -> Outline.Outline -> Result Exit.RegistryProblem Solver.Env -> Result Exit.Details ( Env, Outline.Outline )
combineEnvAndOutline key scope root maybeBuildDir configHash localFingerprint needsTypedOpt showPackageErrors outline maybeEnv =
    case maybeEnv of
        Err problem ->
            Err (Exit.DetailsCannotGetRegistry problem)

        Ok (Solver.Env env) ->
            Ok ( Env { key = key, scope = scope, root = root, maybeBuildDir = maybeBuildDir, cache = env.cache, manager = env.manager, connection = env.connection, registry = env.registry, needsTypedOpt = needsTypedOpt, showPackageErrors = showPackageErrors, configHash = configHash, localFingerprint = localFingerprint }, outline )



-- ====== VERIFY PROJECT ======


{-| Verifies a package's dependencies: checks the supported Elm version, solves
its dependencies and test dependencies together, and builds them. Only the
dependencies (not the test dependencies) count as direct.

A package listed in both sets is reported as hand-edited dependencies.

-}
verifyPkg : Env -> File.Time -> Outline.PkgOutline -> Task Exit.Details Details
verifyPkg env time (Outline.PkgOutline pkgData) =
    if Con.goodElm pkgData.elm then
        union noDups pkgData.deps pkgData.testDeps
            |> Task.andThen (verifyConstraints env)
            |> Task.andThen
                (\solution ->
                    let
                        exposedList : List ModuleName.Raw
                        exposedList =
                            Outline.flattenExposed pkgData.exposed

                        exactDeps : Dict Pkg.Name V.Version
                        exactDeps =
                            Dict.map (\_ (Solver.Details v _) -> v) solution
                    in
                    verifyDependencies env time (ValidPkg pkgData.name exposedList exactDeps) solution pkgData.deps
                )

    else
        Task.throw (Exit.DetailsBadElmInPkg pkgData.elm)


{-| Verifies an application's dependencies: checks the supported Elm version,
solves with every listed version pinned exactly, and builds them. Only
`depsDirect` counts as direct, so test dependencies' modules are not foreign
modules of the project.

Hand-edited dependencies are reported when the solution has a different number
of packages from the listed ones, or the sets overlap as `checkAppDeps`
forbids.

-}
verifyApp : Env -> File.Time -> Outline.AppOutline -> Task Exit.Details Details
verifyApp env time ((Outline.AppOutline appData) as outline) =
    if V.isSupportedElm appData.elm then
        checkAppDeps outline
            |> Task.andThen
                (\stated ->
                    verifyConstraints env (Dict.map (\_ -> Con.exactly) stated)
                        |> Task.andThen
                            (\actual ->
                                if Dict.size stated == Dict.size actual then
                                    verifyDependencies env time (ValidApp appData.srcDirs) actual appData.depsDirect

                                else
                                    Task.throw Exit.DetailsHandEditedDependencies
                            )
                )

    else
        Task.throw (Exit.DetailsBadElmInAppOutline appData.elm)


{-| Returns every package an application lists, with its version, from all four
dependency sets.

A package may appear in both the indirect and the test-direct sets only with
the same version; any other overlap fails as hand-edited dependencies.

-}
checkAppDeps : Outline.AppOutline -> Task Exit.Details (Dict Pkg.Name V.Version)
checkAppDeps (Outline.AppOutline appData) =
    union allowEqualDups appData.depsIndirect appData.testDirect
        |> Task.andThen
            (\x ->
                union noDups appData.depsDirect appData.testIndirect
                    |> Task.andThen (\y -> union noDups x y)
            )



-- ====== VERIFY CONSTRAINTS ======


{-| Returns a solution for `constraints`, or the reason none was found.

A general no-solution is reported as a missing bundled package instead when
one of the bundled packages could not be resolved at all (see
`bundledPackagesUnresolvable`).

-}
verifyConstraints : Env -> Dict Pkg.Name Con.Constraint -> Task Exit.Details (Dict Pkg.Name Solver.Details)
verifyConstraints (Env envData) constraints =
    Task.io (Solver.verify envData.cache envData.connection envData.registry constraints)
        |> Task.andThen
            (\result ->
                case result of
                    Solver.SolverOk details ->
                        Task.succeed details

                    Solver.NoSolution ->
                        case bundledPackagesUnresolvable envData constraints of
                            pkg :: _ ->
                                Task.io (Stuff.bundledPackagePath pkg)
                                    |> Task.andThen
                                        (\maybePath ->
                                            Task.throw (Exit.DetailsBundledKernelMissing pkg (Maybe.withDefault "" maybePath))
                                        )

                            [] ->
                                Task.throw Exit.DetailsNoSolution

                    Solver.NoOfflineSolution ->
                        Task.throw Exit.DetailsNoOfflineSolution

                    Solver.SolverErr exit ->
                        Task.throw (Exit.DetailsSolverProblem exit)
            )


{-| Returns the bundled packages (`Builder.Stuff.bundledPackages`, in that order)
that are among `constraints`, are not registered as local packages, and are
absent from the registry. `verifyConstraints` reports the first such package as
`DetailsBundledKernelMissing` instead of a general no-solution.
-}
bundledPackagesUnresolvable : EnvData -> Dict Pkg.Name Con.Constraint -> List Pkg.Name
bundledPackagesUnresolvable envData constraints =
    Stuff.bundledPackages
        |> List.map Tuple.first
        |> List.filter
            (\pkg ->
                Dict.member pkg constraints
                    && not (Stuff.isLocalPackage envData.cache pkg)
                    && (case Registry.getVersions pkg envData.registry of
                            Nothing ->
                                True

                            Just _ ->
                                False
                       )
            )



-- ====== UNION ======


{-| Returns the union of two dependency dictionaries, using `tieBreaker` to
decide, or fail, where both have a package.
-}
union : (comparable -> v -> v -> Task Exit.Details v) -> Dict comparable v -> Dict comparable v -> Task Exit.Details (Dict comparable v)
union tieBreaker deps1 deps2 =
    Dict.merge
        (\k dep -> Task.map (Dict.insert k dep))
        (\k dep1 dep2 acc ->
            tieBreaker k dep1 dep2
                |> Task.andThen (\v -> Task.map (Dict.insert k v) acc)
        )
        (\k dep -> Task.map (Dict.insert k dep))
        deps1
        deps2
        (Task.succeed Dict.empty)


{-| A tie-breaker that fails as hand-edited dependencies whenever a package is
listed twice.
-}
noDups : k -> v -> v -> Task Exit.Details v
noDups _ _ _ =
    Task.throw Exit.DetailsHandEditedDependencies


{-| A tie-breaker that accepts a package listed twice with the same version and
fails as hand-edited dependencies otherwise.
-}
allowEqualDups : k -> v -> v -> Task Exit.Details v
allowEqualDups _ v1 v2 =
    if v1 == v2 then
        Task.succeed v1

    else
        Task.throw Exit.DetailsHandEditedDependencies



-- ====== FORK ======


{-| Runs `work` on a forked thread and returns at once an MVar that receives its
result. `encoder` is what the MVar needs to store the value.
-}
fork : (a -> Bytes.Encode.Encoder) -> Task Never a -> Task Never (MVar a)
fork encoder work =
    Utils.newEmptyMVar
        |> Task.andThen
            (\mvar ->
                Utils.forkIO (Task.andThen (Utils.putMVar encoder mvar) work)
                    |> Task.map (\_ -> mvar)
            )



-- ====== VERIFY DEPENDENCIES ======


{-| Verifies every package in `solution` in parallel and, if all succeed, builds
and writes the fresh details (see `writeVerifiedArtifacts`). `directDeps`
names the direct dependencies; only its keys are used.
-}
verifyDependencies : Env -> File.Time -> ValidOutline -> Dict Pkg.Name Solver.Details -> Dict Pkg.Name a -> Task Exit.Details Details
verifyDependencies ((Env envData) as env) time outline solution directDeps =
    let
        depVersions : Dict Pkg.Name V.Version
        depVersions =
            Dict.map (\_ (Solver.Details v _) -> v) solution
    in
    Task.eio identity
        (Reporting.report envData.key (Reporting.DStart (Dict.size solution))
            |> Task.andThen (\_ -> Utils.newEmptyMVar)
            |> Task.andThen (verifyAllDeps env solution)
            |> Task.andThen (finalizeDependencies envData.scope envData.root envData.maybeBuildDir envData.configHash envData.localFingerprint envData.needsTypedOpt time outline directDeps depVersions)
        )


{-| Starts one thread per package in `solution` to verify it, publishes every
package's result MVar in `mvar` so that each package's build can wait on its
own dependencies, and returns all the results.
-}
verifyAllDeps : Env -> Dict Pkg.Name Solver.Details -> MVar (Dict Pkg.Name (MVar Dep)) -> Task Never (Dict Pkg.Name Dep)
verifyAllDeps ((Env envData) as env) solution mvar =
    Stuff.withRegistryLock envData.cache
        (Utils.dictTraverseWithKey (\k v -> fork depEncoder (verifyDep env mvar solution k v)) solution)
        |> Task.andThen
            (\mvars ->
                Utils.putMVar dictNameMVarDepEncoder mvar mvars
                    |> Task.andThen (\_ -> Utils.dictTraverse (Utils.readMVar depDecoder) mvars)
            )


{-| Returns the fresh details if every package was verified, and otherwise every
package problem found. A package that failed only because one of its
dependencies did is not reported itself.
-}
finalizeDependencies : BW.Scope -> FilePath -> Maybe String -> String -> String -> Bool -> File.Time -> ValidOutline -> Dict Pkg.Name a -> Dict Pkg.Name V.Version -> Dict Pkg.Name Dep -> Task Never (Result Exit.Details Details)
finalizeDependencies scope root maybeBuildDir configHash localFingerprint needsTypedOpt time outline directDeps depVersions deps =
    case Utils.dictSequenceResult deps of
        Err _ ->
            Stuff.getElmHome
                |> Task.map
                    (\home ->
                        Err
                            (Exit.DetailsBadDeps home
                                (List.filterMap identity (Utils.eitherLefts (Dict.values deps)))
                            )
                    )

        Ok artifacts ->
            writeVerifiedArtifacts scope root maybeBuildDir configHash localFingerprint needsTypedOpt time outline directDeps artifacts depVersions


{-| Builds fresh details from the verified packages and writes `o.dat`, `i.dat`
and `d.dat` through the background writer.

The fresh details have `BuildID` 0 and no local modules. Their interfaces cover
every module of every package, reduced to types for packages outside
`directDeps`, and their foreign modules come only from `directDeps`.

-}
writeVerifiedArtifacts :
    BW.Scope
    -> FilePath
    -> Maybe String
    -> String
    -> String
    -> Bool
    -> File.Time
    -> ValidOutline
    -> Dict Pkg.Name a
    -> Dict Pkg.Name Artifacts
    -> Dict Pkg.Name V.Version
    -> Task Never (Result Exit.Details Details)
writeVerifiedArtifacts scope root maybeBuildDir configHash localFingerprint needsTypedOpt time outline directDeps artifacts depVersions =
    let
        objs : Opt.GlobalGraph
        objs =
            Dict.foldr (\_ -> addObjects) Opt.empty artifacts

        ifaces : Interfaces
        ifaces =
            Dict.foldr (addInterfaces directDeps) EveryDict.empty artifacts

        foreigns : Dict ModuleName.Raw Foreign
        foreigns =
            Dict.map (\_ -> OneOrMore.destruct Foreign) (Dict.foldr gatherForeigns Dict.empty (Dict.filter (\k _ -> Dict.member k directDeps) artifacts))

        details : Details
        details =
            Details
                { time = time
                , outline = outline
                , buildID = 0
                , locals = Dict.empty
                , foreigns = foreigns
                , extras = ArtifactsFresh ifaces objs
                , deps = depVersions
                , hasTypedOpt = needsTypedOpt
                , configHash = configHash
                , localFingerprint = localFingerprint
                }
    in
    BW.writeBinary Opt.globalGraphEncoder scope (Stuff.objectsWithBuildDir root maybeBuildDir) objs
        |> Task.andThen (\_ -> BW.writeBinary interfacesEncoder scope (Stuff.interfacesWithBuildDir root maybeBuildDir) ifaces)
        |> Task.andThen (\_ -> BW.writeBinary detailsEncoder scope (Stuff.detailsWithBuildDir root maybeBuildDir) details)
        |> Task.map (\_ -> Ok details)


{-| Merges one package's object graph into `graph`.
-}
addObjects : Artifacts -> Opt.GlobalGraph -> Opt.GlobalGraph
addObjects (Artifacts _ objs) graph =
    GA.addOptGlobalGraph objs graph


{-| Adds a package's module interfaces, keyed by canonical name, reducing every
one to its types when the package is not in `directDeps`.
-}
addInterfaces : Dict Pkg.Name a -> Pkg.Name -> Artifacts -> Interfaces -> Interfaces
addInterfaces directDeps pkg (Artifacts ifaces _) dependencyInterfaces =
    EveryDict.union
        dependencyInterfaces
        (EveryDict.fromList ModuleName.toComparableCanonical
            (List.map (Tuple.mapFirst (ModuleName.Canonical pkg))
                (Dict.toList
                    (if Dict.member pkg directDeps then
                        ifaces

                     else
                        Dict.map (\_ -> I.privatize) ifaces
                    )
                )
            )
        )


{-| Adds a package's exposed modules to a map from module name to the packages
that expose it.
-}
gatherForeigns : Pkg.Name -> Artifacts -> Dict ModuleName.Raw (OneOrMore.OneOrMore Pkg.Name) -> Dict ModuleName.Raw (OneOrMore.OneOrMore Pkg.Name)
gatherForeigns pkg (Artifacts ifaces _) foreigns =
    let
        isPublic : I.DependencyInterface -> Maybe (OneOrMore.OneOrMore Pkg.Name)
        isPublic di =
            case di of
                I.Public _ ->
                    Just (OneOrMore.one pkg)

                I.Private _ _ _ ->
                    Nothing
    in
    stdUnionWith OneOrMore.more foreigns (stdMapMaybe isPublic ifaces)



-- ====== VERIFY DEPENDENCY ======


{-| What building one package yields for the project: its modules' interfaces
(whole for exposed modules, reduced to types otherwise) and its object graph,
which is empty when the package was built for the typed path.
-}
type Artifacts
    = Artifacts (Dict ModuleName.Raw I.DependencyInterface) Opt.GlobalGraph


{-| The outcome of verifying one package. `Err Nothing` means it could not be
built because one of its own dependencies failed, which is reported for that
dependency instead.

This is a name for `Result`, not a new type.

-}
type alias Dep =
    Result (Maybe Exit.DetailsBadDep) Artifacts


{-| What verifying one package needs. `fingerprint` is the solved version of each
of the package's own direct dependencies.
-}
type alias VerifyDepContext =
    { key : Reporting.DKey
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , depsMVar : MVar (Dict Pkg.Name (MVar Dep))
    , pkg : Pkg.Name
    , vsn : V.Version
    , details : Solver.Details
    , fingerprint : Dict Pkg.Name V.Version
    , needsTypedOpt : Bool
    , showPackageErrors : Bool
    }


{-| Verifies one package of the solution: refreshes it if it is a local package,
uses the package cache if it already holds the package's source, and downloads
it otherwise, then builds it unless its cached artifacts were built against
the same versions of its dependencies.
-}
verifyDep : Env -> MVar (Dict Pkg.Name (MVar Dep)) -> Dict Pkg.Name Solver.Details -> Pkg.Name -> Solver.Details -> Task Never Dep
verifyDep (Env envData) depsMVar solution pkg ((Solver.Details vsn directDeps) as details) =
    let
        fingerprint : Dict Pkg.Name V.Version
        fingerprint =
            Utils.dictIntersectionWith (\(Solver.Details v _) _ -> v) solution directDeps

        ctx : VerifyDepContext
        ctx =
            { key = envData.key, cache = envData.cache, manager = envData.manager, depsMVar = depsMVar, pkg = pkg, vsn = vsn, details = details, fingerprint = fingerprint, needsTypedOpt = envData.needsTypedOpt, showPackageErrors = envData.showPackageErrors }
    in
    Utils.dirDoesDirectoryExist (Stuff.package envData.cache pkg vsn ++ "/src")
        |> Task.andThen (handleDepExistence ctx)


{-| Chooses how to verify a package, given whether the cache holds its `src/`
directory: a local package is always seeded from its source, whatever the
cache holds.
-}
handleDepExistence : VerifyDepContext -> Bool -> Task Never Dep
handleDepExistence ctx exists =
    if Stuff.isLocalPackage ctx.cache ctx.pkg then
        seedLocalPackage ctx

    else if exists then
        handleCachedDep ctx

    else
        downloadAndBuildDep ctx


{-| Seeds (or refreshes) a locally linked package in the cache, then verifies it
as a cached package. The `--local-package` path, the _seed_, is treated as a
read-only source: its `src/` and `elm.json` are copied into the writable cache
directory, and the package is built there like any other cached dependency, so
`artifacts.dat`, `typed-artifacts.dat` and `docs.json` land in the package
cache, not in the seed. A seed with no `src/` directory is reported as a local
package that was not found.

The copy is kept in step with the seed through a fingerprint (see
`Builder.File.fingerprintPackageSource`) stored in `eco-local-fingerprint` in
the cache directory. When the seed's fingerprint differs from the stored one
(or none is stored), the cache directory is replaced, under the registry lock:

1.  the whole cache directory is removed, which also deletes stale `src/` files,
    `artifacts.dat`, `typed-artifacts.dat`, `docs.json` and the old fingerprint;
2.  the seed is copied in afresh;
3.  the fingerprint is written **last**.

The copy is not staged in a temporary directory and renamed into place, since
no directory-rename operation is available. Writing the fingerprint last gives
the same protection: an interrupted refresh leaves no fingerprint, so the next
build sees a mismatch and refreshes again. The fingerprint is checked again
inside the lock so that concurrent refreshes do not repeat the copy.

-}
seedLocalPackage : VerifyDepContext -> Task Never Dep
seedLocalPackage ctx =
    case Stuff.localPackageSource ctx.cache ctx.pkg of
        Just source ->
            Utils.dirDoesDirectoryExist (source ++ "/src")
                |> Task.andThen
                    (\sourceExists ->
                        if sourceExists then
                            File.fingerprintPackageSource source
                                |> Task.andThen (refreshLocalPackageIfStale ctx source)
                                |> Task.andThen (\_ -> handleCachedDep ctx)

                        else
                            Task.succeed (Err (Just (Exit.BD_LocalPackageNotFound ctx.pkg)))
                    )

        Nothing ->
            Task.succeed (Err (Just (Exit.BD_LocalPackageNotFound ctx.pkg)))


{-| Replaces the cache copy of a local package with a fresh copy of `source`,
unless the cache already holds a copy with fingerprint `fingerprint` (see
`seedLocalPackage`).
-}
refreshLocalPackageIfStale : VerifyDepContext -> FilePath -> String -> Task Never ()
refreshLocalPackageIfStale ctx source fingerprint =
    let
        cacheDir : FilePath
        cacheDir =
            Stuff.package ctx.cache ctx.pkg ctx.vsn

        refresh : Task Never ()
        refresh =
            Utils.dirRemoveDirectoryRecursive cacheDir
                |> Task.andThen (\_ -> File.copyPackageSource source cacheDir)
                |> Task.andThen (\_ -> File.writeUtf8 (localFingerprintPath cacheDir) fingerprint)
    in
    isLocalCopyFresh cacheDir fingerprint
        |> Task.andThen
            (\fresh ->
                if fresh then
                    Task.succeed ()

                else
                    Stuff.withRegistryLock ctx.cache
                        (isLocalCopyFresh cacheDir fingerprint
                            |> Task.andThen
                                (\freshInLock ->
                                    if freshInLock then
                                        Task.succeed ()

                                    else
                                        refresh
                                )
                        )
            )


{-| Returns whether the cache copy at `cacheDir` was made from a seed with
fingerprint `fingerprint`: its `src/` exists and its stored fingerprint, with
surrounding whitespace trimmed, matches.
-}
isLocalCopyFresh : FilePath -> String -> Task Never Bool
isLocalCopyFresh cacheDir fingerprint =
    Utils.dirDoesDirectoryExist (cacheDir ++ "/src")
        |> Task.andThen
            (\srcExists ->
                if srcExists then
                    File.exists (localFingerprintPath cacheDir)
                        |> Task.andThen
                            (\fpExists ->
                                if fpExists then
                                    File.readUtf8 (localFingerprintPath cacheDir)
                                        |> Task.map (\stored -> String.trim stored == fingerprint)

                                else
                                    Task.succeed False
                            )

                else
                    Task.succeed False
            )


{-| Returns the path of the file holding the seed fingerprint in a local
package's cache directory.
-}
localFingerprintPath : FilePath -> FilePath
localFingerprintPath cacheDir =
    cacheDir ++ "/eco-local-fingerprint"


{-| Reports a package as found in the cache and checks its cached artifacts.
-}
handleCachedDep : VerifyDepContext -> Task Never Dep
handleCachedDep ctx =
    Reporting.report ctx.key Reporting.DCached
        |> Task.andThen (\_ -> checkArtifactCache ctx)


{-| Reads the package's cached artifacts for the requested path
(`typed-artifacts.dat` when typed, `artifacts.dat` otherwise) and reuses or
rebuilds them.
-}
checkArtifactCache : VerifyDepContext -> Task Never Dep
checkArtifactCache ctx =
    if ctx.needsTypedOpt then
        File.readBinary typedArtifactCacheDecoder (Stuff.typedPackageArtifacts ctx.cache ctx.pkg ctx.vsn)
            |> Task.andThen (handleTypedArtifactCache ctx)

    else
        File.readBinary artifactCacheDecoder (Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/artifacts.dat")
            |> Task.andThen (handleArtifactCache ctx)


{-| Reuses a package's `artifacts.dat` when it was built against the solved
versions of the package's dependencies, and builds the package otherwise,
keeping the fingerprints already recorded.
-}
handleArtifactCache : VerifyDepContext -> Maybe ArtifactCache -> Task Never Dep
handleArtifactCache ctx maybeCache =
    case maybeCache of
        Nothing ->
            build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint EverySet.empty ctx.needsTypedOpt ctx.showPackageErrors

        Just (ArtifactCache fingerprints artifacts) ->
            if EverySet.member toComparableFingerprint ctx.fingerprint fingerprints then
                Task.map (\_ -> Ok artifacts) (Reporting.report ctx.key Reporting.DBuilt)

            else
                build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint fingerprints ctx.needsTypedOpt ctx.showPackageErrors


{-| Reuses a package's `typed-artifacts.dat` when it was built against the
solved versions of the package's dependencies, and builds the package
otherwise. The object graph in the returned `Artifacts` is empty, because the
typed path loads typed objects with `loadTypedObjects` instead.
-}
handleTypedArtifactCache : VerifyDepContext -> Maybe TypedArtifactCache -> Task Never Dep
handleTypedArtifactCache ctx maybeCache =
    case maybeCache of
        Nothing ->
            build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint EverySet.empty ctx.needsTypedOpt ctx.showPackageErrors

        Just (TypedArtifactCache fingerprints ifaces _ _) ->
            if EverySet.member toComparableFingerprint ctx.fingerprint fingerprints then
                Task.map (\_ -> Ok (Artifacts ifaces Opt.empty)) (Reporting.report ctx.key Reporting.DBuilt)

            else
                build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint fingerprints ctx.needsTypedOpt ctx.showPackageErrors


{-| Reports a package as requested, then downloads and builds it.
-}
downloadAndBuildDep : VerifyDepContext -> Task Never Dep
downloadAndBuildDep ctx =
    Reporting.report ctx.key Reporting.DRequested
        |> Task.andThen (\_ -> downloadAndHandleResult ctx)


{-| Downloads a package into the cache and continues with the result.
-}
downloadAndHandleResult : VerifyDepContext -> Task Never Dep
downloadAndHandleResult ctx =
    downloadPackage ctx.cache ctx.manager ctx.pkg ctx.vsn
        |> Task.andThen (handleDownloadResult ctx)


{-| Builds a package after a successful download, or reports the download
failure.
-}
handleDownloadResult : VerifyDepContext -> Result Exit.PackageProblem () -> Task Never Dep
handleDownloadResult ctx result =
    case result of
        Err problem ->
            Reporting.report ctx.key (Reporting.DFailed ctx.pkg ctx.vsn)
                |> Task.map (\_ -> Err (Just (Exit.BD_BadDownload ctx.pkg ctx.vsn problem)))

        Ok () ->
            Reporting.report ctx.key (Reporting.DReceived ctx.pkg ctx.vsn)
                |> Task.andThen (\_ -> build ctx.key ctx.cache ctx.depsMVar ctx.pkg ctx.details ctx.fingerprint EverySet.empty ctx.needsTypedOpt ctx.showPackageErrors)



-- ====== ARTIFACT CACHE ======


{-| The contents of a package's `artifacts.dat`: every fingerprint the stored
artifacts are valid for, and the artifacts. One build is valid for several
fingerprints because rebuilding a package against a new set of dependency
versions adds the new fingerprint to those already recorded.
-}
type ArtifactCache
    = ArtifactCache (EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint) Artifacts


{-| The contents of a package's `typed-artifacts.dat`: the fingerprints the
stored artifacts are valid for, the interfaces, the typed object graph and the
global type environment. It holds interfaces and fingerprints as well, so that
it is self-contained: a package built for the typed path writes only this
file, and one built for the JavaScript path writes only `artifacts.dat`.
-}
type TypedArtifactCache
    = TypedArtifactCache (EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint) (Dict ModuleName.Raw I.DependencyInterface) (TOpt.GlobalGraph Name) TypeEnv.GlobalTypeEnv


{-| The exact version of each of a package's direct dependencies, as one build of
the package was compiled against them. Cached artifacts are reused only for a
fingerprint they record.
-}
type alias Fingerprint =
    Dict Pkg.Name V.Version


{-| Returns a comparable form of a fingerprint, for keeping fingerprints in a
set.
-}
toComparableFingerprint : Fingerprint -> List ( ( String, String ), ( Int, Int, Int ) )
toComparableFingerprint fingerprint =
    Dict.toList fingerprint
        |> List.map (Tuple.mapSecond V.toComparable)



-- ====== BUILD ======


{-| What building one package needs. `fingerprint` is the set of dependency
versions this build is against, and `fingerprints` the ones the cached
artifacts were already valid for.
-}
type alias BuildContext =
    { key : Reporting.DKey
    , cache : Stuff.PackageCache
    , pkg : Pkg.Name
    , vsn : V.Version
    , fingerprint : Fingerprint
    , fingerprints : EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint
    , needsTypedOpt : Bool
    , showPackageErrors : Bool
    }


{-| Builds a package from the cache: reads its `elm.json`, waits for its own
dependencies, crawls and compiles its modules, and writes its artifacts. An
`elm.json` that cannot be read or describes an application makes the build
broken.
-}
build :
    Reporting.DKey
    -> Stuff.PackageCache
    -> MVar (Dict Pkg.Name (MVar Dep))
    -> Pkg.Name
    -> Solver.Details
    -> Fingerprint
    -> EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint
    -> Bool
    -> Bool
    -> Task Never Dep
build key cache depsMVar pkg (Solver.Details vsn _) f fs needsTypedOpt showPackageErrors =
    let
        ctx : BuildContext
        ctx =
            { key = key, cache = cache, pkg = pkg, vsn = vsn, fingerprint = f, fingerprints = fs, needsTypedOpt = needsTypedOpt, showPackageErrors = showPackageErrors }
    in
    Outline.read (Stuff.package cache pkg vsn)
        |> Task.andThen
            (\eitherOutline ->
                case eitherOutline of
                    Err _ ->
                        reportBuildBroken ctx

                    Ok (Outline.App _) ->
                        reportBuildBroken ctx

                    Ok (Outline.Pkg (Outline.PkgOutline pkgData)) ->
                        buildPackage ctx depsMVar pkgData.exposed pkgData.deps
            )


{-| Reports a package as broken and returns the failure for it.
-}
reportBuildBroken : BuildContext -> Task Never Dep
reportBuildBroken { key, pkg, vsn, fingerprint } =
    Reporting.report key Reporting.DBroken
        |> Task.map (\_ -> Err (Just (Exit.BD_BadBuild pkg vsn fingerprint)))


{-| Waits for the results of the package's own dependencies (`deps`) and builds
the package with them.
-}
buildPackage : BuildContext -> MVar (Dict Pkg.Name (MVar Dep)) -> Outline.Exposed -> Dict Pkg.Name Con.Constraint -> Task Never Dep
buildPackage ctx depsMVar exposed deps =
    Utils.readMVar dictPkgNameMVarDepDecoder depsMVar
        |> Task.andThen
            (\allDeps ->
                Utils.dictTraverse (Utils.readMVar depDecoder) (Dict.filter (\k _ -> Dict.member k deps) allDeps)
                    |> Task.andThen (buildWithDirectDeps ctx exposed)
            )


{-| Builds the package once its dependencies' results are in: crawls from the
exposed modules and compiles what it finds. If a dependency failed, the
package fails with `Err Nothing`, so no problem is listed for it.
-}
buildWithDirectDeps : BuildContext -> Outline.Exposed -> Dict Pkg.Name Dep -> Task Never Dep
buildWithDirectDeps ctx exposed directDeps =
    case Utils.dictSequenceResult directDeps of
        Err _ ->
            Reporting.report ctx.key Reporting.DBroken
                |> Task.map (\_ -> Err Nothing)

        Ok directArtifacts ->
            let
                src : String
                src =
                    Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src"

                foreignDeps : Dict ModuleName.Raw ForeignInterface
                foreignDeps =
                    gatherForeignInterfaces directArtifacts

                exposedDict : Dict ModuleName.Raw ()
                exposedDict =
                    Dict.fromList (List.map (\k -> ( k, () )) (Outline.flattenExposed exposed))
            in
            getDocsStatus ctx.cache ctx.pkg ctx.vsn
                |> Task.andThen (crawlPackageModules ctx foreignDeps src exposedDict)
                |> Task.andThen (compilePackageModules ctx exposedDict)


{-| Crawls the package's modules from its exposed modules and returns the status
of every module found, or a failure if any module could not be resolved.
-}
crawlPackageModules :
    BuildContext
    -> Dict ModuleName.Raw ForeignInterface
    -> String
    -> Dict ModuleName.Raw ()
    -> DocsStatus
    -> Task Never (Result Dep ( DocsStatus, Dict ModuleName.Raw Status ))
crawlPackageModules ctx foreignDeps src exposedDict docsStatus =
    Utils.newEmptyMVar
        |> Task.andThen (forkCrawlModules ctx foreignDeps src exposedDict docsStatus)


{-| Starts a crawl thread for every exposed module and waits for the crawl to
finish.
-}
forkCrawlModules :
    BuildContext
    -> Dict ModuleName.Raw ForeignInterface
    -> String
    -> Dict ModuleName.Raw ()
    -> DocsStatus
    -> MVar (Dict ModuleName.Raw (MVar (Maybe Status)))
    -> Task Never (Result Dep ( DocsStatus, Dict ModuleName.Raw Status ))
forkCrawlModules ctx foreignDeps src exposedDict docsStatus mvar =
    stdTraverseWithKey (always << fork (BE.maybe statusEncoder) << crawlModule foreignDeps mvar ctx.pkg src docsStatus) exposedDict
        |> Task.andThen (waitAndCollectCrawlResults ctx docsStatus mvar)


{-| Publishes the crawl MVars of the exposed modules, waits for them, and then
collects the status of every module the crawl reached, including imports
added while it ran.
-}
waitAndCollectCrawlResults :
    BuildContext
    -> DocsStatus
    -> MVar (Dict ModuleName.Raw (MVar (Maybe Status)))
    -> Dict ModuleName.Raw (MVar (Maybe Status))
    -> Task Never (Result Dep ( DocsStatus, Dict ModuleName.Raw Status ))
waitAndCollectCrawlResults ctx docsStatus mvar mvars =
    Utils.putMVar statusDictEncoder mvar mvars
        |> Task.andThen (\_ -> stdDictMapM_ (Utils.readMVar (BD.maybe statusDecoder)) mvars)
        |> Task.andThen (\_ -> Utils.readMVar statusDictDecoder mvar)
        |> Task.andThen (stdTraverse (Utils.readMVar (BD.maybe statusDecoder)))
        |> Task.andThen (finalizeCrawlResults ctx docsStatus)


{-| Returns the statuses of the crawled modules, or a broken build if any module
could not be resolved.
-}
finalizeCrawlResults :
    BuildContext
    -> DocsStatus
    -> Dict ModuleName.Raw (Maybe Status)
    -> Task Never (Result Dep ( DocsStatus, Dict ModuleName.Raw Status ))
finalizeCrawlResults ctx docsStatus maybeStatuses =
    case stdSequenceMaybe maybeStatuses of
        Nothing ->
            reportBuildBroken ctx
                |> Task.map Err

        Just statuses ->
            Task.succeed (Ok ( docsStatus, statuses ))


{-| Compiles every crawled module in parallel and writes the package's
artifacts, passing a crawl failure through.
-}
compilePackageModules : BuildContext -> Dict ModuleName.Raw () -> Result Dep ( DocsStatus, Dict ModuleName.Raw Status ) -> Task Never Dep
compilePackageModules ctx exposedDict crawlResult =
    case crawlResult of
        Err dep ->
            Task.succeed dep

        Ok ( docsStatus, statuses ) ->
            Utils.newEmptyMVar
                |> Task.andThen (forkCompileModules ctx exposedDict docsStatus statuses)


{-| Starts a compile thread for every crawled module and waits for all of them.
-}
forkCompileModules :
    BuildContext
    -> Dict ModuleName.Raw ()
    -> DocsStatus
    -> Dict ModuleName.Raw Status
    -> MVar (Dict ModuleName.Raw (MVar (Result Error.Module DResult)))
    -> Task Never Dep
forkCompileModules ctx exposedDict docsStatus statuses rmvar =
    stdTraverse (fork resultErrorModuleDResultEncoder << compile ctx rmvar) statuses
        |> Task.andThen (waitAndCollectCompileResults ctx exposedDict docsStatus rmvar)


{-| Publishes the result MVars so that each module can wait on its imports,
collects every result, and writes the package's artifacts.
-}
waitAndCollectCompileResults :
    BuildContext
    -> Dict ModuleName.Raw ()
    -> DocsStatus
    -> MVar (Dict ModuleName.Raw (MVar (Result Error.Module DResult)))
    -> Dict ModuleName.Raw (MVar (Result Error.Module DResult))
    -> Task Never Dep
waitAndCollectCompileResults ctx exposedDict docsStatus rmvar rmvars =
    Utils.putMVar dictRawMVarResultErrorModuleDResultEncoder rmvar rmvars
        |> Task.andThen (\_ -> stdTraverse (Utils.readMVar resultErrorModuleDResultDecoder) rmvars)
        |> Task.andThen (writePackageArtifacts ctx exposedDict docsStatus)


{-| Writes a package's artifacts and returns them when every module compiled,
and reports the package broken otherwise.

A typed build writes `typed-artifacts.dat` and returns an empty object graph;
a JavaScript build writes `artifacts.dat`. Either adds the current fingerprint
to those already recorded. The package's `docs.json` is written first when it
was missing. Compile errors are printed to stderr only when
`showPackageErrors` is set.

-}
writePackageArtifacts : BuildContext -> Dict ModuleName.Raw () -> DocsStatus -> Dict ModuleName.Raw (Result Error.Module DResult) -> Task Never Dep
writePackageArtifacts ctx exposedDict docsStatus resultDict =
    let
        ( errors, successes ) =
            partitionResults resultDict
    in
    case errors of
        [] ->
            let
                ifaces : Dict ModuleName.Raw I.DependencyInterface
                ifaces =
                    gatherInterfaces exposedDict successes

                fingerprints : EverySet (List ( ( String, String ), ( Int, Int, Int ) )) Fingerprint
                fingerprints =
                    EverySet.insert toComparableFingerprint ctx.fingerprint ctx.fingerprints

                ( artifacts, writeCache ) =
                    if ctx.needsTypedOpt then
                        let
                            typedGraph : TOpt.GlobalGraph Name
                            typedGraph =
                                gatherTypedObjects successes

                            typeEnv : TypeEnv.GlobalTypeEnv
                            typeEnv =
                                gatherTypeEnvs successes

                            typedPath : String
                            typedPath =
                                Stuff.typedPackageArtifacts ctx.cache ctx.pkg ctx.vsn
                        in
                        ( Artifacts ifaces Opt.empty
                        , File.writeBinary typedArtifactCacheEncoder
                            typedPath
                            (TypedArtifactCache fingerprints ifaces typedGraph typeEnv)
                        )

                    else
                        let
                            objects : Opt.GlobalGraph
                            objects =
                                gatherObjects successes

                            path : String
                            path =
                                Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/artifacts.dat"

                            arts : Artifacts
                            arts =
                                Artifacts ifaces objects
                        in
                        ( arts
                        , File.writeBinary artifactCacheEncoder
                            path
                            (ArtifactCache fingerprints arts)
                        )
            in
            writeDocs ctx.cache ctx.pkg ctx.vsn docsStatus successes
                |> Task.andThen (\_ -> writeCache)
                |> Task.andThen (\_ -> Reporting.report ctx.key Reporting.DBuilt)
                |> Task.map (\_ -> Ok artifacts)

        firstErr :: restErrs ->
            if ctx.showPackageErrors then
                printPackageCompileErrors ctx.cache ctx.pkg ctx.vsn firstErr restErrs
                    |> Task.andThen (\_ -> reportBuildBroken ctx)

            else
                reportBuildBroken ctx


{-| Splits compile results into the errors and the successful results. Errors
with an empty `source` are dropped: they mark modules that were not compiled
because an import failed (see `compile`), and the import's own error is the
one to report.
-}
partitionResults : Dict ModuleName.Raw (Result Error.Module ok) -> ( List Error.Module, Dict ModuleName.Raw ok )
partitionResults dict =
    Dict.foldl
        (\k result ( errs, oks ) ->
            case result of
                Err e ->
                    if String.isEmpty e.source then
                        ( errs, oks )

                    else
                        ( e :: errs, oks )

                Ok v ->
                    ( errs, Dict.insert k v oks )
        )
        ( [], Dict.empty )
        dict


{-| Prints a package's compile errors to stderr in the format used for the
project's own modules, followed by a note naming the package and version.
-}
printPackageCompileErrors : Stuff.PackageCache -> Pkg.Name -> V.Version -> Error.Module -> List Error.Module -> Task Never ()
printPackageCompileErrors cache pkg vsn firstErr restErrs =
    let
        pkgRoot : String
        pkgRoot =
            Stuff.package cache pkg vsn ++ "/src"

        errorDoc : Doc.Doc
        errorDoc =
            Error.toDoc pkgRoot firstErr restErrs

        footer : Doc.Doc
        footer =
            Doc.vcat
                [ Doc.fromChars ""
                , Doc.dullyellow (Doc.fromChars "-- NOTE -----------------------------------------------------------------------")
                , Doc.fromChars ""
                , Doc.reflow ("The errors above occurred while compiling package: " ++ Pkg.toChars pkg ++ " " ++ V.toChars vsn)
                , Doc.reflow "This is not an error in your code."
                ]

        fullDoc : Doc.Doc
        fullDoc =
            Doc.vcat [ errorDoc, footer ]
    in
    Help.toStderr fullDoc



-- ====== GATHER ======


{-| Merges the object graphs of the compiled modules and the package's own
kernel modules into one graph.
-}
gatherObjects : Dict ModuleName.Raw DResult -> Opt.GlobalGraph
gatherObjects results =
    Dict.foldr addLocalOptGraph Opt.empty results


{-| Adds a module's object graph, or a kernel module's code, to `graph`.
-}
addLocalOptGraph : ModuleName.Raw -> DResult -> Opt.GlobalGraph -> Opt.GlobalGraph
addLocalOptGraph name status graph =
    case status of
        RLocal _ objs _ _ _ ->
            GA.addOptLocalGraph objs graph

        RForeign _ ->
            graph

        RKernelLocal cs ->
            GA.addOptKernel name cs graph

        RKernelForeign ->
            graph


{-| Merges the typed object graphs of the compiled modules into one graph.
-}
gatherTypedObjects : Dict ModuleName.Raw DResult -> TOpt.GlobalGraph Name
gatherTypedObjects results =
    Dict.foldr addTypedLocalOptGraph TOpt.emptyGlobalGraph results


{-| Adds a module's typed object graph to `graph`, if it has one. Kernel modules
have none.
-}
addTypedLocalOptGraph : ModuleName.Raw -> DResult -> TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
addTypedLocalOptGraph _ status graph =
    case status of
        RLocal _ _ maybeTypedObjs _ _ ->
            case maybeTypedObjs of
                Just typedObjs ->
                    GA.addTypedLocalGraph typedObjs graph

                Nothing ->
                    graph

        RForeign _ ->
            graph

        RKernelLocal _ ->
            graph

        RKernelForeign ->
            graph


{-| Collects the type environments of the compiled modules into one global type
environment.
-}
gatherTypeEnvs : Dict ModuleName.Raw DResult -> TypeEnv.GlobalTypeEnv
gatherTypeEnvs results =
    Dict.foldr addTypeEnv TypeEnv.emptyGlobal results


{-| Adds a module's type environment to `acc`, if it has one.
-}
addTypeEnv : ModuleName.Raw -> DResult -> TypeEnv.GlobalTypeEnv -> TypeEnv.GlobalTypeEnv
addTypeEnv _ status acc =
    case status of
        RLocal _ _ _ maybeEnv _ ->
            case maybeEnv of
                Just moduleEnv ->
                    EveryDict.insert ModuleName.toComparableCanonical moduleEnv.home moduleEnv acc

                Nothing ->
                    acc

        RForeign _ ->
            acc

        RKernelLocal _ ->
            acc

        RKernelForeign ->
            acc


{-| Returns the interfaces of the package's compiled modules: whole for an exposed
module and reduced to types (`Compiler.Elm.Interface.private`) for any other.
Every module in `exposed` must have a result; a missing one crashes.
-}
gatherInterfaces : Dict ModuleName.Raw () -> Dict ModuleName.Raw DResult -> Dict ModuleName.Raw I.DependencyInterface
gatherInterfaces exposed artifacts =
    let
        onLeft : comparable -> b -> c -> d
        onLeft _ _ _ =
            crash "compiler bug manifesting in Elm.Details.gatherInterfaces"

        onBoth : comparable -> () -> DResult -> Dict comparable I.DependencyInterface -> Dict comparable I.DependencyInterface
        onBoth k () iface =
            toLocalInterface I.public iface
                |> Maybe.map (Dict.insert k)
                |> Maybe.withDefault identity

        onRight : comparable -> DResult -> Dict comparable I.DependencyInterface -> Dict comparable I.DependencyInterface
        onRight k iface =
            toLocalInterface I.private iface
                |> Maybe.map (Dict.insert k)
                |> Maybe.withDefault identity
    in
    Dict.merge onLeft onBoth onRight exposed artifacts Dict.empty


{-| Applies `func` to the interface of a module compiled from this package, and
returns `Nothing` for any other kind of result.
-}
toLocalInterface : (I.Interface -> a) -> DResult -> Maybe a
toLocalInterface func result =
    case result of
        RLocal iface _ _ _ _ ->
            Just (func iface)

        RForeign _ ->
            Nothing

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- ====== GATHER FOREIGN INTERFACES ======


{-| What a module name means when a package being built imports it from one of
its dependencies. It is `ForeignAmbiguous` when more than one dependency
exposes that name, and `ForeignSpecific` with the interface when exactly one
does.
-}
type ForeignInterface
    = ForeignAmbiguous
    | ForeignSpecific I.Interface


{-| Returns, for every module name exposed by one of `directArtifacts`, the
interface behind it, or `ForeignAmbiguous` if more than one package exposes
it.
-}
gatherForeignInterfaces : Dict Pkg.Name Artifacts -> Dict ModuleName.Raw ForeignInterface
gatherForeignInterfaces directArtifacts =
    let
        finalize : I.Interface -> List I.Interface -> ForeignInterface
        finalize i is =
            case is of
                [] ->
                    ForeignSpecific i

                _ :: _ ->
                    ForeignAmbiguous

        gather : Pkg.Name -> Artifacts -> Dict ModuleName.Raw (OneOrMore.OneOrMore I.Interface) -> Dict ModuleName.Raw (OneOrMore.OneOrMore I.Interface)
        gather _ (Artifacts ifaces _) buckets =
            stdUnionWith OneOrMore.more buckets (stdMapMaybe isPublic ifaces)

        isPublic : I.DependencyInterface -> Maybe (OneOrMore.OneOrMore I.Interface)
        isPublic di =
            case di of
                I.Public iface ->
                    Just (OneOrMore.one iface)

                I.Private _ _ _ ->
                    Nothing
    in
    Dict.foldr gather Dict.empty directArtifacts |> Dict.map (\_ -> OneOrMore.destruct finalize)



-- ====== CRAWL ======


{-| The crawl's shared record of every module reached so far, each with the MVar
its crawl result will arrive in. `Nothing` there means the module could not be
resolved.
-}
type alias StatusDict =
    Dict ModuleName.Raw (MVar (Maybe Status))


{-| What the crawl of a package found a module name to be.

`SLocal` is a module with source in the package, carrying whether docs are
needed, the names it imports, and the parsed module. `SForeign` is a module
provided by exactly one dependency. `SKernelLocal` is a kernel module of a
kernel package with its parsed code. `SKernelForeign` is a kernel module name
with no `.js` file in the package.

-}
type Status
    = SLocal DocsStatus (Dict ModuleName.Raw ()) Src.Module
    | SForeign I.Interface
    | SKernelLocal (List Kernel.Chunk)
    | SKernelForeign


{-| Returns the status of module `name` of the package whose sources are in `src`,
crawling its imports first, or `Nothing` if it cannot be resolved.
-}
crawlModule : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> Task Never (Maybe Status)
crawlModule foreignDeps mvar pkg src docsStatus name =
    let
        elmPath : FilePath
        elmPath =
            Utils.fpCombine src (Utils.fpAddExtension (ModuleName.toFilePath name) "elm")
    in
    File.exists elmPath
        |> Task.andThen (resolveCrawlAction foreignDeps mvar pkg src docsStatus name elmPath)


{-| Decides what module `name` is, given whether its `.elm` file exists.

A name that several dependencies expose cannot be resolved, nor can one that a
dependency exposes and the package also defines. A kernel name in a kernel
package is looked for as a `.js` file. Anything else needs its `.elm` file.

-}
resolveCrawlAction : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> FilePath -> Bool -> Task Never (Maybe Status)
resolveCrawlAction foreignDeps mvar pkg src docsStatus name elmPath elmExists =
    case Dict.get name foreignDeps of
        Just ForeignAmbiguous ->
            Task.succeed Nothing

        Just (ForeignSpecific iface) ->
            if elmExists then
                Task.succeed Nothing

            else
                Task.succeed (Just (SForeign iface))

        Nothing ->
            if elmExists then
                crawlFile foreignDeps mvar pkg src docsStatus name elmPath

            else if Pkg.isKernel pkg && Name.isKernel name then
                crawlKernel foreignDeps mvar pkg src name

            else
                Task.succeed Nothing


{-| Reads a module's source file and crawls it.
-}
crawlFile : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> FilePath -> Task Never (Maybe Status)
crawlFile foreignDeps mvar pkg src docsStatus expectedName path =
    File.readUtf8 path
        |> Task.andThen (parseAndCrawlFile foreignDeps mvar pkg src docsStatus expectedName)


{-| Parses a module's source and, if it parses and declares the expected name,
crawls its imports and returns it as a local module. Anything else cannot be
resolved.
-}
parseAndCrawlFile : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> DocsStatus -> ModuleName.Raw -> String -> Task Never (Maybe Status)
parseAndCrawlFile foreignDeps mvar pkg src docsStatus expectedName bytes =
    case Parse.fromByteString (Parse.Package pkg) bytes of
        Ok ((Src.Module srcData) as modul) ->
            case srcData.name of
                Just (A.At _ actualName) ->
                    if expectedName == actualName then
                        crawlImports foreignDeps mvar pkg src srcData.imports
                            |> Task.map (\deps -> Just (SLocal docsStatus deps modul))

                    else
                        Task.succeed Nothing

                Nothing ->
                    Task.succeed Nothing

        _ ->
            Task.succeed Nothing


{-| Starts crawls for the imports not yet in the shared crawl record, waits for
them, and returns the set of imported names.
-}
crawlImports : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> List Src.Import -> Task Never (Dict ModuleName.Raw ())
crawlImports foreignDeps mvar pkg src imports =
    Utils.takeMVar statusDictDecoder mvar
        |> Task.andThen (forkCrawlNewImports foreignDeps mvar pkg src imports)


{-| Starts a crawl thread for every import not already in `statusDict`, then
waits for them.
-}
forkCrawlNewImports : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> List Src.Import -> StatusDict -> Task Never (Dict ModuleName.Raw ())
forkCrawlNewImports foreignDeps mvar pkg src imports statusDict =
    let
        deps : Dict Name.Name ()
        deps =
            Dict.fromList (List.map (\i -> ( Src.getImportName i, () )) imports)

        news : Dict Name.Name ()
        news =
            Dict.diff deps statusDict
    in
    stdTraverseWithKey (always << fork (BE.maybe statusEncoder) << crawlModule foreignDeps mvar pkg src DocsNotNeeded) news
        |> Task.andThen (waitForCrawledImports mvar statusDict deps)


{-| Puts the extended crawl record back and waits for the newly started crawls
to finish, returning the imported names.
-}
waitForCrawledImports : MVar StatusDict -> StatusDict -> Dict Name.Name () -> Dict ModuleName.Raw (MVar (Maybe Status)) -> Task Never (Dict ModuleName.Raw ())
waitForCrawledImports mvar statusDict deps mvars =
    Utils.putMVar statusDictEncoder mvar (Dict.union mvars statusDict)
        |> Task.andThen (\_ -> stdDictMapM_ (Utils.readMVar (BD.maybe statusDecoder)) mvars)
        |> Task.map (\_ -> deps)


{-| Returns the status of a kernel module from its `.js` file in the package.
-}
crawlKernel : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> ModuleName.Raw -> Task Never (Maybe Status)
crawlKernel foreignDeps mvar pkg src name =
    let
        path : FilePath
        path =
            Utils.fpCombine src (Utils.fpAddExtension (ModuleName.toFilePath name) "js")
    in
    File.exists path
        |> Task.andThen (handleKernelExistence foreignDeps mvar pkg src path)


{-| Parses a kernel module's `.js` file if it exists, and records the name as a
foreign kernel module otherwise.
-}
handleKernelExistence : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> FilePath -> Bool -> Task Never (Maybe Status)
handleKernelExistence foreignDeps mvar pkg src path exists =
    if exists then
        File.readUtf8 path
            |> Task.andThen (parseAndCrawlKernel foreignDeps mvar pkg src)

    else
        Task.succeed (Just SKernelForeign)


{-| Parses a kernel module's code, crawls the modules it imports, and returns it
as a local kernel module, or `Nothing` if the code does not parse.
-}
parseAndCrawlKernel : Dict ModuleName.Raw ForeignInterface -> MVar StatusDict -> Pkg.Name -> FilePath -> String -> Task Never (Maybe Status)
parseAndCrawlKernel foreignDeps mvar pkg src bytes =
    case Kernel.fromByteString pkg (stdMapMaybe getDepHome foreignDeps) bytes of
        Nothing ->
            Task.succeed Nothing

        Just (Kernel.Content imports chunks) ->
            crawlImports foreignDeps mvar pkg src (List.map Src.c1Value imports)
                |> Task.map (\_ -> Just (SKernelLocal chunks))


{-| Returns the package that provides a foreign module, when exactly one does.
-}
getDepHome : ForeignInterface -> Maybe Pkg.Name
getDepHome fi =
    case fi of
        ForeignSpecific (I.Interface iface) ->
            Just iface.home

        ForeignAmbiguous ->
            Nothing



-- ====== COMPILE ======


{-| The result of compiling one module of a package.

`RLocal` carries the interface, the object graph, and, for a typed build only,
the typed object graph and type environment, followed by the module's docs
when they were needed and could be made. `RForeign` carries the interface of a
module from a dependency. `RKernelLocal` carries a kernel module's code, and
`RKernelForeign` stands for a kernel module with no code in the package.

-}
type DResult
    = RLocal I.Interface Opt.LocalGraph (Maybe (TOpt.LocalGraph Name)) (Maybe TypeEnv.ModuleTypeEnv) (Maybe Docs.Module)
    | RForeign I.Interface
    | RKernelLocal (List Kernel.Chunk)
    | RKernelForeign


{-| Compiles one crawled module once its imports have results, using the typed
compiler when the build is typed.

If any import failed, the module is not compiled; its error has an empty
`source` and a placeholder `ModuleBadEnd 0 0` syntax error, which marks it as
blocked rather than wrong.

-}
compile : BuildContext -> MVar (Dict ModuleName.Raw (MVar (Result Error.Module DResult))) -> Status -> Task Never (Result Error.Module DResult)
compile ctx mvar status =
    case status of
        SLocal docsStatus deps modul ->
            Utils.readMVar moduleNameRawMVarResultErrorModuleDResultDecoder mvar
                |> Task.andThen
                    (\resultsDict ->
                        stdTraverse (Utils.readMVar resultErrorModuleDResultDecoder) (stdIntersection resultsDict deps)
                            |> Task.andThen
                                (\depResults ->
                                    if hasAnyError depResults then
                                        Task.succeed (Err { name = Src.getName modul, absolutePath = "", modificationTime = File.zeroTime, source = "", error = Error.BadSyntax (Syntax.ParseError (Syntax.ModuleBadEnd 0 0)) })

                                    else
                                        case stdSequenceResult depResults of
                                            Err _ ->
                                                -- Should not happen since we checked hasAnyError above
                                                Task.succeed (Err { name = Src.getName modul, absolutePath = "", modificationTime = File.zeroTime, source = "", error = Error.BadSyntax (Syntax.ParseError (Syntax.ModuleBadEnd 0 0)) })

                                            Ok results ->
                                                let
                                                    ifaces : Dict ModuleName.Raw I.Interface
                                                    ifaces =
                                                        stdMapMaybe getInterface results
                                                in
                                                if ctx.needsTypedOpt then
                                                    Compile.compileTyped ctx.pkg ifaces modul
                                                        |> Task.andThen (handleTypedCompileResult ctx modul docsStatus)

                                                else
                                                    Compile.compile ctx.pkg ifaces modul
                                                        |> Task.andThen (handleCompileResult ctx modul docsStatus)
                                )
                    )

        SForeign iface ->
            Task.succeed (Ok (RForeign iface))

        SKernelLocal chunks ->
            Task.succeed (Ok (RKernelLocal chunks))

        SKernelForeign ->
            Task.succeed (Ok RKernelForeign)


{-| Returns whether any result in `dict` is an error.
-}
hasAnyError : Dict ModuleName.Raw (Result e v) -> Bool
hasAnyError dict =
    Dict.foldl (\_ result acc -> acc || Result.Extra.isErr result) False dict


{-| Returns the result of compiling a module for the JavaScript path. On an
error it reads the module's source and modification time so that the error can
be shown.
-}
handleCompileResult : BuildContext -> Src.Module -> DocsStatus -> Result Error.Error Compile.Artifacts -> Task Never (Result Error.Module DResult)
handleCompileResult ctx modul docsStatus result =
    case result of
        Err err ->
            let
                name : ModuleName.Raw
                name =
                    Src.getName modul

                path : FilePath
                path =
                    Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src/" ++ ModuleName.toFilePath name ++ ".elm"
            in
            Task.map2
                (\time source ->
                    Err
                        { name = name
                        , absolutePath = path
                        , modificationTime = time
                        , source = source
                        , error = err
                        }
                )
                (File.getTime path)
                (File.readUtf8 path)

        Ok (Compile.Artifacts canonical annotations objects) ->
            let
                iface : I.Interface
                iface =
                    I.fromModule ctx.pkg canonical annotations

                docs : Maybe Docs.Module
                docs =
                    makeDocs docsStatus canonical
            in
            Task.succeed (Ok (RLocal iface objects Nothing Nothing docs))


{-| Returns the result of compiling a module for the typed path. On an error it
reads the module's source and modification time so that the error can be
shown.
-}
handleTypedCompileResult : BuildContext -> Src.Module -> DocsStatus -> Result Error.Error Compile.TypedArtifacts -> Task Never (Result Error.Module DResult)
handleTypedCompileResult ctx modul docsStatus result =
    case result of
        Err err ->
            let
                name : ModuleName.Raw
                name =
                    Src.getName modul

                path : FilePath
                path =
                    Stuff.package ctx.cache ctx.pkg ctx.vsn ++ "/src/" ++ ModuleName.toFilePath name ++ ".elm"
            in
            Task.map2
                (\time source ->
                    Err
                        { name = name
                        , absolutePath = path
                        , modificationTime = time
                        , source = source
                        , error = err
                        }
                )
                (File.getTime path)
                (File.readUtf8 path)

        Ok (Compile.TypedArtifacts data) ->
            let
                iface : I.Interface
                iface =
                    I.fromModule ctx.pkg data.canonical data.annotations

                docs : Maybe Docs.Module
                docs =
                    makeDocs docsStatus data.canonical
            in
            Task.succeed (Ok (RLocal iface data.objects (Just data.typedObjects) (Just data.typeEnv) docs))


{-| Returns the interface of a compiled or foreign module, and `Nothing` for a
kernel module.
-}
getInterface : DResult -> Maybe I.Interface
getInterface result =
    case result of
        RLocal iface _ _ _ _ ->
            Just iface

        RForeign iface ->
            Just iface

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- ====== MAKE DOCS ======


{-| Whether a package's docs must be generated while it is built. Only the
package's exposed modules are ever marked as needing them.
-}
type DocsStatus
    = DocsNeeded
    | DocsNotNeeded


{-| Returns whether the package's docs are needed, which is when the cache holds
no `docs.json` for it.
-}
getDocsStatus : Stuff.PackageCache -> Pkg.Name -> V.Version -> Task Never DocsStatus
getDocsStatus cache pkg vsn =
    File.exists (Stuff.package cache pkg vsn ++ "/docs.json")
        |> Task.map
            (\exists ->
                if exists then
                    DocsNotNeeded

                else
                    DocsNeeded
            )


{-| Returns the docs of a module when they are needed and can be made, and
`Nothing` otherwise.
-}
makeDocs : DocsStatus -> Can.Module -> Maybe Docs.Module
makeDocs status modul =
    case status of
        DocsNeeded ->
            case Docs.fromModule modul of
                Ok docs ->
                    Just docs

                Err _ ->
                    Nothing

        DocsNotNeeded ->
            Nothing


{-| Writes the package's `docs.json` from the docs of its compiled modules, when
the docs were needed.
-}
writeDocs : Stuff.PackageCache -> Pkg.Name -> V.Version -> DocsStatus -> Dict ModuleName.Raw DResult -> Task Never ()
writeDocs cache pkg vsn status results =
    case status of
        DocsNeeded ->
            E.writeUgly (Stuff.package cache pkg vsn ++ "/docs.json")
                (Docs.encode (stdMapMaybe toDocs results))

        DocsNotNeeded ->
            Task.succeed ()


{-| Returns the docs a compile result carries, if any.
-}
toDocs : DResult -> Maybe Docs.Module
toDocs result =
    case result of
        RLocal _ _ _ _ docs ->
            docs

        RForeign _ ->
            Nothing

        RKernelLocal _ ->
            Nothing

        RKernelForeign ->
            Nothing



-- ====== DOWNLOAD PACKAGE ======


{-| Downloads a package version into the cache: fetches its `endpoint.json` for
the archive's URL and expected hash, downloads the archive, and unpacks it
only if its SHA matches the expected hash.
-}
downloadPackage : Stuff.PackageCache -> Http.Manager -> Pkg.Name -> V.Version -> Task Never (Result Exit.PackageProblem ())
downloadPackage cache manager pkg vsn =
    Website.metadata pkg vsn "endpoint.json"
        |> Task.andThen
            (\url ->
                Http.get manager url [] identity (Task.succeed << Ok)
                    |> Task.andThen
                        (\eitherByteString ->
                            case eitherByteString of
                                Err err ->
                                    Task.succeed (Err (Exit.PP_BadEndpointRequest err))

                                Ok byteString ->
                                    case D.fromByteString endpointDecoder byteString of
                                        Err _ ->
                                            Task.succeed (Err (Exit.PP_BadEndpointContent url))

                                        Ok ( endpoint, expectedHash ) ->
                                            Http.getArchive endpoint (Exit.PP_BadArchiveContent endpoint) <|
                                                \( sha, archive ) ->
                                                    if expectedHash == Http.shaToChars sha then
                                                        Task.map Ok (File.writePackage (Stuff.package cache pkg vsn) archive)

                                                    else
                                                        Task.succeed (Err (Exit.PP_BadArchiveHash endpoint expectedHash (Http.shaToChars sha)))
                        )
            )


{-| A decoder for a package's `endpoint.json`, giving the archive's URL and its
expected hash.
-}
endpointDecoder : D.Decoder e ( String, String )
endpointDecoder =
    D.field "url" D.string
        |> D.andThen
            (\url ->
                D.field "hash" D.string
                    |> D.map (\hash -> ( url, hash ))
            )



-- ====== ENCODERS and DECODERS ======


{-| Encodes project details in the format of `d.dat`.
-}
detailsEncoder : Details -> Bytes.Encode.Encoder
detailsEncoder (Details detailsData) =
    Bytes.Encode.sequence
        [ File.timeEncoder detailsData.time
        , validOutlineEncoder detailsData.outline
        , BE.int detailsData.buildID
        , BE.stdDict ModuleName.rawEncoder localEncoder detailsData.locals
        , BE.stdDict ModuleName.rawEncoder foreignEncoder detailsData.foreigns
        , extrasEncoder detailsData.extras
        , BE.stdDict Pkg.nameEncoder V.versionEncoder detailsData.deps
        , BE.bool detailsData.hasTypedOpt
        , BE.string detailsData.configHash
        , BE.string detailsData.localFingerprint
        ]


{-| A decoder for project details in the format `detailsEncoder` writes.
-}
detailsDecoder : Bytes.Decode.Decoder Details
detailsDecoder =
    File.timeDecoder
        |> Bytes.Decode.andThen
            (\time ->
                validOutlineDecoder
                    |> Bytes.Decode.andThen
                        (\outline ->
                            BD.int
                                |> Bytes.Decode.andThen
                                    (\buildID ->
                                        BD.stdDict ModuleName.rawDecoder localDecoder
                                            |> Bytes.Decode.andThen
                                                (\locals ->
                                                    BD.stdDict ModuleName.rawDecoder foreignDecoder
                                                        |> Bytes.Decode.andThen
                                                            (\foreigns ->
                                                                extrasDecoder
                                                                    |> Bytes.Decode.andThen
                                                                        (\extras ->
                                                                            BD.stdDict Pkg.nameDecoder V.versionDecoder
                                                                                |> Bytes.Decode.andThen
                                                                                    (\deps ->
                                                                                        BD.bool
                                                                                            |> Bytes.Decode.andThen
                                                                                                (\hasTypedOpt ->
                                                                                                    Bytes.Decode.map2 Tuple.pair BD.string BD.string
                                                                                                        |> Bytes.Decode.map
                                                                                                            (\( configHash, localFingerprint ) ->
                                                                                                                Details
                                                                                                                    { time = time
                                                                                                                    , outline = outline
                                                                                                                    , buildID = buildID
                                                                                                                    , locals = locals
                                                                                                                    , foreigns = foreigns
                                                                                                                    , extras = extras
                                                                                                                    , deps = deps
                                                                                                                    , hasTypedOpt = hasTypedOpt
                                                                                                                    , configHash = configHash
                                                                                                                    , localFingerprint = localFingerprint
                                                                                                                    }
                                                                                                            )
                                                                                                )
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


{-| Encodes the dependencies' interfaces, as stored in `i.dat` and `d.dat`.
-}
interfacesEncoder : Interfaces -> Bytes.Encode.Encoder
interfacesEncoder =
    BE.assocListDict ModuleName.canonicalEncoder I.dependencyInterfaceEncoder


{-| A decoder for interfaces in the format `interfacesEncoder` writes.
-}
interfacesDecoder : Bytes.Decode.Decoder Interfaces
interfacesDecoder =
    BD.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder I.dependencyInterfaceDecoder


{-| Encodes the result of reading the registry, so that it can pass through an
MVar.
-}
resultRegistryProblemEnvEncoder : Result Exit.RegistryProblem Solver.Env -> Bytes.Encode.Encoder
resultRegistryProblemEnvEncoder =
    BE.result Exit.registryProblemEncoder Solver.envEncoder


{-| A decoder for the result of reading the registry, as it passes through an
MVar.
-}
resultRegistryProblemEnvDecoder : Bytes.Decode.Decoder (Result Exit.RegistryProblem Solver.Env)
resultRegistryProblemEnvDecoder =
    BD.result Exit.registryProblemDecoder Solver.envDecoder


{-| Encodes the outcome of verifying a package.
-}
depEncoder : Dep -> Bytes.Encode.Encoder
depEncoder dep =
    BE.result (BE.maybe Exit.detailsBadDepEncoder) artifactsEncoder dep


{-| A decoder for the outcome of verifying a package.
-}
depDecoder : Bytes.Decode.Decoder Dep
depDecoder =
    BD.result (BD.maybe Exit.detailsBadDepDecoder) artifactsDecoder


{-| Encodes a package's interfaces and object graph.
-}
artifactsEncoder : Artifacts -> Bytes.Encode.Encoder
artifactsEncoder (Artifacts ifaces objects) =
    Bytes.Encode.sequence
        [ BE.stdDict ModuleName.rawEncoder I.dependencyInterfaceEncoder ifaces
        , Opt.globalGraphEncoder objects
        ]


{-| A decoder for a package's interfaces and object graph.
-}
artifactsDecoder : Bytes.Decode.Decoder Artifacts
artifactsDecoder =
    Bytes.Decode.map2 Artifacts
        (BD.stdDict ModuleName.rawDecoder I.dependencyInterfaceDecoder)
        Opt.globalGraphDecoder


{-| Encodes the map from package name to the MVar of its verification outcome.
-}
dictNameMVarDepEncoder : Dict Pkg.Name (MVar Dep) -> Bytes.Encode.Encoder
dictNameMVarDepEncoder =
    BE.stdDict Pkg.nameEncoder Utils.mVarEncoder


{-| Encodes the contents of `artifacts.dat`.
-}
artifactCacheEncoder : ArtifactCache -> Bytes.Encode.Encoder
artifactCacheEncoder (ArtifactCache fingerprints artifacts) =
    Bytes.Encode.sequence
        [ BE.everySet fingerprintEncoder fingerprints
        , artifactsEncoder artifacts
        ]


{-| A decoder for the contents of `artifacts.dat`.
-}
artifactCacheDecoder : Bytes.Decode.Decoder ArtifactCache
artifactCacheDecoder =
    Bytes.Decode.map2 ArtifactCache
        (BD.everySet toComparableFingerprint fingerprintDecoder)
        artifactsDecoder


{-| Encodes the contents of `typed-artifacts.dat`.
-}
typedArtifactCacheEncoder : TypedArtifactCache -> Bytes.Encode.Encoder
typedArtifactCacheEncoder (TypedArtifactCache fingerprints ifaces typedGraph typeEnv) =
    Bytes.Encode.sequence
        [ BE.everySet fingerprintEncoder fingerprints
        , BE.stdDict ModuleName.rawEncoder I.dependencyInterfaceEncoder ifaces
        , TOpt.globalGraphEncoder typedGraph
        , TypeEnv.globalTypeEnvEncoder typeEnv
        ]


{-| A decoder for the contents of `typed-artifacts.dat`.
-}
typedArtifactCacheDecoder : Bytes.Decode.Decoder TypedArtifactCache
typedArtifactCacheDecoder =
    Bytes.Decode.map4 TypedArtifactCache
        (BD.everySet toComparableFingerprint fingerprintDecoder)
        (BD.stdDict ModuleName.rawDecoder I.dependencyInterfaceDecoder)
        TOpt.globalGraphDecoder
        TypeEnv.globalTypeEnvDecoder


{-| A decoder for the map from package name to the MVar of its verification
outcome.
-}
dictPkgNameMVarDepDecoder : Bytes.Decode.Decoder (Dict Pkg.Name (MVar Dep))
dictPkgNameMVarDepDecoder =
    BD.stdDict Pkg.nameDecoder Utils.mVarDecoder


{-| Encodes a crawl status.
-}
statusEncoder : Status -> Bytes.Encode.Encoder
statusEncoder status =
    case status of
        SLocal docsStatus deps modul ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , docsStatusEncoder docsStatus
                , BE.list ModuleName.rawEncoder (Dict.keys deps)
                , Src.moduleEncoder modul
                ]

        SForeign iface ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , I.interfaceEncoder iface
                ]

        SKernelLocal chunks ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.list Kernel.chunkEncoder chunks
                ]

        SKernelForeign ->
            Bytes.Encode.unsignedInt8 3


{-| A decoder for a crawl status.
-}
statusDecoder : Bytes.Decode.Decoder Status
statusDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 SLocal
                            docsStatusDecoder
                            (BD.list ModuleName.rawDecoder
                                |> Bytes.Decode.map (Dict.fromList << List.map (\dep -> ( dep, () )))
                            )
                            Src.moduleDecoder

                    1 ->
                        Bytes.Decode.map SForeign I.interfaceDecoder

                    2 ->
                        Bytes.Decode.map SKernelLocal (BD.list Kernel.chunkDecoder)

                    3 ->
                        Bytes.Decode.succeed SKernelForeign

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes the map from module name to the MVar of its compile result.
-}
dictRawMVarResultErrorModuleDResultEncoder : Dict ModuleName.Raw (MVar (Result Error.Module DResult)) -> Bytes.Encode.Encoder
dictRawMVarResultErrorModuleDResultEncoder =
    BE.stdDict ModuleName.rawEncoder Utils.mVarEncoder


{-| A decoder for the map from module name to the MVar of its compile result.
-}
moduleNameRawMVarResultErrorModuleDResultDecoder : Bytes.Decode.Decoder (Dict ModuleName.Raw (MVar (Result Error.Module DResult)))
moduleNameRawMVarResultErrorModuleDResultDecoder =
    BD.stdDict ModuleName.rawDecoder Utils.mVarDecoder


{-| Encodes a module's compile result.
-}
resultErrorModuleDResultEncoder : Result Error.Module DResult -> Bytes.Encode.Encoder
resultErrorModuleDResultEncoder result =
    case result of
        Err errorModule ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Error.moduleEncoder errorModule
                ]

        Ok dResult ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , dResultEncoder dResult
                ]


{-| A decoder for a module's compile result.
-}
resultErrorModuleDResultDecoder : Bytes.Decode.Decoder (Result Error.Module DResult)
resultErrorModuleDResultDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Err Error.moduleDecoder

                    1 ->
                        Bytes.Decode.map Ok dResultDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a successful module compile result.
-}
dResultEncoder : DResult -> Bytes.Encode.Encoder
dResultEncoder dResult =
    case dResult of
        RLocal ifaces objects typedObjects typeEnv docs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , I.interfaceEncoder ifaces
                , Opt.localGraphEncoder objects
                , BE.maybe TOpt.localGraphEncoder typedObjects
                , BE.maybe TypeEnv.moduleTypeEnvEncoder typeEnv
                , BE.maybe Docs.bytesModuleEncoder docs
                ]

        RForeign iface ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , I.interfaceEncoder iface
                ]

        RKernelLocal chunks ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.list Kernel.chunkEncoder chunks
                ]

        RKernelForeign ->
            Bytes.Encode.unsignedInt8 3


{-| A decoder for a successful module compile result.
-}
dResultDecoder : Bytes.Decode.Decoder DResult
dResultDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map5 RLocal
                            I.interfaceDecoder
                            Opt.localGraphDecoder
                            (BD.maybe TOpt.localGraphDecoder)
                            (BD.maybe TypeEnv.moduleTypeEnvDecoder)
                            (BD.maybe Docs.bytesModuleDecoder)

                    1 ->
                        Bytes.Decode.map RForeign I.interfaceDecoder

                    2 ->
                        Bytes.Decode.map RKernelLocal (BD.list Kernel.chunkDecoder)

                    3 ->
                        Bytes.Decode.succeed RKernelForeign

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes the crawl record.
-}
statusDictEncoder : StatusDict -> Bytes.Encode.Encoder
statusDictEncoder statusDict =
    BE.stdDict ModuleName.rawEncoder Utils.mVarEncoder statusDict


{-| A decoder for the crawl record.
-}
statusDictDecoder : Bytes.Decode.Decoder StatusDict
statusDictDecoder =
    BD.stdDict ModuleName.rawDecoder Utils.mVarDecoder


{-| Encodes what the details record about one of the project's own modules.
-}
localEncoder : Local -> Bytes.Encode.Encoder
localEncoder (Local localData) =
    Bytes.Encode.sequence
        [ BE.string localData.path
        , File.timeEncoder localData.time
        , BE.list ModuleName.rawEncoder localData.deps
        , BE.bool localData.hasMain
        , BE.int localData.lastChange
        , BE.int localData.lastCompile
        ]


{-| A decoder for what the details record about one of the project's own
modules, in the format `localEncoder` writes.
-}
localDecoder : Bytes.Decode.Decoder Local
localDecoder =
    BD.map6 (\path time deps hasMain lastChange lastCompile -> Local { path = path, time = time, deps = deps, hasMain = hasMain, lastChange = lastChange, lastCompile = lastCompile })
        BD.string
        File.timeDecoder
        (BD.list ModuleName.rawDecoder)
        BD.bool
        BD.int
        BD.int


{-| Encodes a verified outline.
-}
validOutlineEncoder : ValidOutline -> Bytes.Encode.Encoder
validOutlineEncoder validOutline =
    case validOutline of
        ValidApp srcDirs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.nonempty Outline.srcDirEncoder srcDirs
                ]

        ValidPkg pkg exposedList exactDeps ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , Pkg.nameEncoder pkg
                , BE.list ModuleName.rawEncoder exposedList
                , BE.stdDict Pkg.nameEncoder V.versionEncoder exactDeps
                ]


{-| A decoder for a verified outline.
-}
validOutlineDecoder : Bytes.Decode.Decoder ValidOutline
validOutlineDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map ValidApp (BD.nonempty Outline.srcDirDecoder)

                    1 ->
                        Bytes.Decode.map3 ValidPkg
                            Pkg.nameDecoder
                            (BD.list ModuleName.rawDecoder)
                            (BD.stdDict Pkg.nameDecoder V.versionDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a foreign module's providing packages.
-}
foreignEncoder : Foreign -> Bytes.Encode.Encoder
foreignEncoder (Foreign dep deps) =
    Bytes.Encode.sequence
        [ Pkg.nameEncoder dep
        , BE.list Pkg.nameEncoder deps
        ]


{-| A decoder for a foreign module's providing packages.
-}
foreignDecoder : Bytes.Decode.Decoder Foreign
foreignDecoder =
    Bytes.Decode.map2 Foreign
        Pkg.nameDecoder
        (BD.list Pkg.nameDecoder)


{-| Encodes the dependencies' artifacts as the details carry them; for
`ArtifactsFresh` that is every interface and the whole object graph.
-}
extrasEncoder : Extras -> Bytes.Encode.Encoder
extrasEncoder extras =
    case extras of
        ArtifactsCached ->
            Bytes.Encode.unsignedInt8 0

        ArtifactsFresh ifaces objs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , interfacesEncoder ifaces
                , Opt.globalGraphEncoder objs
                ]


{-| A decoder for the dependencies' artifacts as `extrasEncoder` writes them.
-}
extrasDecoder : Bytes.Decode.Decoder Extras
extrasDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed ArtifactsCached

                    1 ->
                        Bytes.Decode.map2 ArtifactsFresh
                            interfacesDecoder
                            Opt.globalGraphDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a fingerprint.
-}
fingerprintEncoder : Fingerprint -> Bytes.Encode.Encoder
fingerprintEncoder =
    BE.stdDict Pkg.nameEncoder V.versionEncoder


{-| A decoder for a fingerprint.
-}
fingerprintDecoder : Bytes.Decode.Decoder Fingerprint
fingerprintDecoder =
    BD.stdDict Pkg.nameDecoder V.versionDecoder


{-| Encodes whether docs are needed.
-}
docsStatusEncoder : DocsStatus -> Bytes.Encode.Encoder
docsStatusEncoder docsStatus =
    Bytes.Encode.unsignedInt8
        (case docsStatus of
            DocsNeeded ->
                0

            DocsNotNeeded ->
                1
        )


{-| A decoder for whether docs are needed.
-}
docsStatusDecoder : Bytes.Decode.Decoder DocsStatus
docsStatusDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed DocsNeeded

                    1 ->
                        Bytes.Decode.succeed DocsNotNeeded

                    _ ->
                        Bytes.Decode.fail
            )
