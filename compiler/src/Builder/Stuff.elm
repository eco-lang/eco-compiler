module Builder.Stuff exposing
    ( findRoot, getElmHome
    , PackageCache, getPackageCache, getReplCache, package, isLocalPackage, registry
    , typedPackageArtifacts, packageCacheEncoder, packageCacheDecoder
    , eci, eco, ecot
    , testDir
    , withRootLock, withRootLockBuildDir, withRegistryLock
    , detailsWithBuildDir, eciWithBuildDir, ecoWithBuildDir
    , ecotWithBuildDir, interfacesWithBuildDir, objectsWithBuildDir, typedObjectsWithBuildDir
    )

{-| File path management and artifact location for the Eco compiler build system.

This module centralizes all knowledge about where the compiler stores its build
artifacts, caches, and intermediate files. It handles the `eco-stuff` directory
structure, package caches, and provides utilities for finding project roots and
managing file locks.


# Project Root and Home

@docs findRoot, getElmHome


# Package Cache

@docs PackageCache, getPackageCache, getReplCache, package, registry
@docs typedPackageArtifacts, packageCacheEncoder, packageCacheDecoder


# Build Artifacts

@docs eci, eco, ecot


# Special Directories

@docs testDir


# File Locking

@docs withRootLock, withRootLockBuildDir, withRegistryLock


# Build Directory Variants

@docs detailsWithBuildDir, eciWithBuildDir, ecoWithBuildDir
@docs ecotWithBuildDir, interfacesWithBuildDir, objectsWithBuildDir, typedObjectsWithBuildDir

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Prelude
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import System.IO as IO exposing (FilePath)
import Utils.Main as Utils



-- ====== PATHS ======


stuff : String -> String
stuff root =
    root ++ "/eco-stuff/" ++ compilerVersion


{-| Get the stuff directory with an optional build subdirectory for parallel builds.
-}
stuffWithBuildDir : String -> Maybe String -> String
stuffWithBuildDir root maybeBuildDir =
    case maybeBuildDir of
        Nothing ->
            stuff root

        Just buildDir ->
            stuff root ++ "/" ++ buildDir


{-| Returns the path to the details cache file with optional build subdirectory.
-}
detailsWithBuildDir : String -> Maybe String -> String
detailsWithBuildDir root maybeBuildDir =
    stuffWithBuildDir root maybeBuildDir ++ "/d.dat"


{-| Returns the path to the interfaces cache file with optional build subdirectory.
-}
interfacesWithBuildDir : String -> Maybe String -> String
interfacesWithBuildDir root maybeBuildDir =
    stuffWithBuildDir root maybeBuildDir ++ "/i.dat"


{-| Returns the path to the objects cache file with optional build subdirectory.
-}
objectsWithBuildDir : String -> Maybe String -> String
objectsWithBuildDir root maybeBuildDir =
    stuffWithBuildDir root maybeBuildDir ++ "/o.dat"


{-| Returns the path to the typed objects cache file with optional build subdirectory.
-}
typedObjectsWithBuildDir : String -> Maybe String -> String
typedObjectsWithBuildDir root maybeBuildDir =
    stuffWithBuildDir root maybeBuildDir ++ "/to.dat"


{-| Returns the path to the test output directory.
-}
testDir : String -> String
testDir root =
    stuff root ++ "/test"


compilerVersion : String
compilerVersion =
    V.toChars V.compiler



-- ====== ECI and ECO ======


{-| Returns the path to a module's .eci (interface) file.
-}
eci : String -> ModuleName.Raw -> String
eci root name =
    toArtifactPath root name "eci"


{-| Returns the path to a module's .eco (object) file.
-}
eco : String -> ModuleName.Raw -> String
eco root name =
    toArtifactPath root name "eco"


{-| Returns the path to a module's .ecot (typed object) file for MLIR backend.
-}
ecot : String -> ModuleName.Raw -> String
ecot root name =
    toArtifactPath root name "ecot"


toArtifactPath : String -> ModuleName.Raw -> String -> String
toArtifactPath root name ext =
    Utils.fpCombine (stuff root) (Utils.fpAddExtension (ModuleName.toHyphenPath name) ext)


toArtifactPathWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String -> String
toArtifactPathWithBuildDir root maybeBuildDir name ext =
    Utils.fpCombine (stuffWithBuildDir root maybeBuildDir) (Utils.fpAddExtension (ModuleName.toHyphenPath name) ext)


{-| Returns the path to a module's .eci (interface) file with optional build subdirectory.
-}
eciWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String
eciWithBuildDir root maybeBuildDir name =
    toArtifactPathWithBuildDir root maybeBuildDir name "eci"


{-| Returns the path to a module's .eco (object) file with optional build subdirectory.
-}
ecoWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String
ecoWithBuildDir root maybeBuildDir name =
    toArtifactPathWithBuildDir root maybeBuildDir name "eco"


{-| Returns the path to a module's .ecot (typed object) file with optional build subdirectory.
-}
ecotWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String
ecotWithBuildDir root maybeBuildDir name =
    toArtifactPathWithBuildDir root maybeBuildDir name "ecot"



-- ====== ROOT ======


{-| Searches for the project root by looking for elm.json in the current directory and parent directories.
-}
findRoot : Task Never (Maybe String)
findRoot =
    Utils.dirGetCurrentDirectory
        |> Task.andThen
            (\dir ->
                findRootHelp (Utils.fpSplitDirectories dir)
            )


findRootHelp : List String -> Task Never (Maybe String)
findRootHelp dirs =
    case dirs of
        [] ->
            Task.succeed Nothing

        _ :: _ ->
            Utils.dirDoesFileExist (Utils.fpJoinPath dirs ++ "/elm.json")
                |> Task.andThen
                    (\exists ->
                        if exists then
                            Task.succeed (Just (Utils.fpJoinPath dirs))

                        else
                            findRootHelp (Prelude.init dirs)
                    )



-- ====== LOCKS ======


{-| Executes a task while holding an exclusive lock on the project root's eco-stuff directory.
-}
withRootLock : String -> Task Never a -> Task Never a
withRootLock root work =
    let
        dir : String
        dir =
            stuff root
    in
    Utils.dirCreateDirectoryIfMissing True dir
        |> Task.andThen
            (\_ ->
                Utils.lockWithFileLock (dir ++ "/lock") IO.LockExclusive (\_ -> work)
            )


{-| Executes a task while holding an exclusive lock on the project's eco-stuff directory,
using a builddir-specific lock file when --builddir is specified. This enables parallel
compilation with different builddirs without lock contention.
-}
withRootLockBuildDir : String -> Maybe String -> Task Never a -> Task Never a
withRootLockBuildDir root maybeBuildDir work =
    let
        dir : String
        dir =
            stuffWithBuildDir root maybeBuildDir
    in
    Utils.dirCreateDirectoryIfMissing True dir
        |> Task.andThen
            (\_ ->
                Utils.lockWithFileLock (dir ++ "/lock") IO.LockExclusive (\_ -> work)
            )


{-| Executes a task while holding an exclusive lock on the package registry.
-}
withRegistryLock : PackageCache -> Task Never a -> Task Never a
withRegistryLock (PackageCache dir _) work =
    Utils.lockWithFileLock (dir ++ "/lock") IO.LockExclusive (\_ -> work)



-- ====== PACKAGE CACHES ======


{-| Represents the package cache directory location.
-}
type PackageCache
    = PackageCache String (Maybe ( Pkg.Name, FilePath ))


{-| Returns the package cache directory, creating it if necessary.
-}
getPackageCache : Maybe ( Pkg.Name, FilePath ) -> Task Never PackageCache
getPackageCache maybeLocal =
    Task.map (\dir -> PackageCache dir maybeLocal) (getCacheDir "packages")


{-| Returns the path to the package registry cache file.
-}
registry : PackageCache -> String
registry (PackageCache dir _) =
    Utils.fpCombine dir "registry.dat"


{-| Returns the directory path for a specific package version in the cache.
-}
package : PackageCache -> Pkg.Name -> V.Version -> String
package (PackageCache dir maybeLocal) name version =
    case maybeLocal of
        Just ( localPkg, localPath ) ->
            if localPkg == name then
                localPath

            else
                Utils.fpCombine dir (Utils.fpCombine (Pkg.toString name) (V.toChars version))

        Nothing ->
            Utils.fpCombine dir (Utils.fpCombine (Pkg.toString name) (V.toChars version))


isLocalPackage : PackageCache -> Pkg.Name -> Bool
isLocalPackage (PackageCache _ maybeLocal) name =
    case maybeLocal of
        Just ( localPkg, _ ) ->
            localPkg == name

        Nothing ->
            False


{-| Returns the path to typed artifacts cache for a specific package version.
-}
typedPackageArtifacts : PackageCache -> Pkg.Name -> V.Version -> String
typedPackageArtifacts cache name version =
    package cache name version ++ "/typed-artifacts.dat"



-- ====== CACHE ======


{-| Returns the REPL cache directory, creating it if necessary.
-}
getReplCache : Task Never String
getReplCache =
    getCacheDir "repl"


getCacheDir : String -> Task Never String
getCacheDir projectName =
    getElmHome
        |> Task.andThen
            (\home ->
                let
                    root : FilePath
                    root =
                        Utils.fpCombine home (Utils.fpCombine compilerVersion projectName)
                in
                Utils.dirCreateDirectoryIfMissing True root
                    |> Task.map (\_ -> root)
            )


{-| Returns the Elm home directory, checking ECO\_HOME environment variable first.
-}
getElmHome : Task Never String
getElmHome =
    Utils.envLookupEnv "ECO_HOME"
        |> Task.andThen
            (\maybeCustomHome ->
                case maybeCustomHome of
                    Just customHome ->
                        Task.succeed customHome

                    Nothing ->
                        Utils.dirGetAppUserDataDirectory "eco"
            )



-- ====== ENCODERS and DECODERS ======


{-| Encodes a package cache location to bytes.
-}
packageCacheEncoder : PackageCache -> Bytes.Encode.Encoder
packageCacheEncoder (PackageCache dir maybeLocal) =
    Bytes.Encode.sequence
        [ BE.string dir
        , BE.maybe (\( name, path ) -> Bytes.Encode.sequence [ Pkg.nameEncoder name, BE.string path ]) maybeLocal
        ]


{-| Decodes a package cache location from bytes.
-}
packageCacheDecoder : Bytes.Decode.Decoder PackageCache
packageCacheDecoder =
    Bytes.Decode.map2 PackageCache
        BD.string
        (BD.maybe (Bytes.Decode.map2 (\a b -> ( a, b )) Pkg.nameDecoder BD.string))
