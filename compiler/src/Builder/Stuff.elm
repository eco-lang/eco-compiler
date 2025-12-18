module Builder.Stuff exposing
    ( findRoot, getElmHome
    , PackageCache, getPackageCache, getReplCache, package, registry
    , typedPackageArtifacts, packageCacheEncoder, packageCacheDecoder
    , details, interfaces, objects, typedObjects
    , guidai, guidao, guidato
    , prepublishDir, testDir
    , withRootLock, withRegistryLock
    )

{-| File path management and artifact location for the Elm compiler build system.

This module centralizes all knowledge about where the compiler stores its build
artifacts, caches, and intermediate files. It handles the `guida-stuff` directory
structure, package caches, and provides utilities for finding project roots and
managing file locks.


# Project Root and Home

@docs findRoot, getElmHome


# Package Cache

@docs PackageCache, getPackageCache, getReplCache, package, registry
@docs typedPackageArtifacts, packageCacheEncoder, packageCacheDecoder


# Build Artifacts

@docs details, interfaces, objects, typedObjects
@docs guidai, guidao, guidato


# Special Directories

@docs prepublishDir, testDir


# File Locking

@docs withRootLock, withRegistryLock

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
import Utils.Main as Utils



-- PATHS


stuff : String -> String
stuff root =
    root ++ "/guida-stuff/" ++ compilerVersion


{-| Returns the path to the details cache file for a project.
-}
details : String -> String
details root =
    stuff root ++ "/d.dat"


{-| Returns the path to the interfaces cache file for a project.
-}
interfaces : String -> String
interfaces root =
    stuff root ++ "/i.dat"


{-| Returns the path to the objects cache file for a project.
-}
objects : String -> String
objects root =
    stuff root ++ "/o.dat"


{-| Returns the path to the typed objects cache file for MLIR backend.
-}
typedObjects : String -> String
typedObjects root =
    stuff root ++ "/to.dat"


{-| Returns the path to the prepublish staging directory for a package.
-}
prepublishDir : String -> String
prepublishDir root =
    stuff root ++ "/prepublish"


{-| Returns the path to the test output directory.
-}
testDir : String -> String
testDir root =
    stuff root ++ "/test"


compilerVersion : String
compilerVersion =
    V.toChars V.compiler



-- ELMI and ELMO


{-| Returns the path to a module's .guidai (interface) file.
-}
guidai : String -> ModuleName.Raw -> String
guidai root name =
    toArtifactPath root name "guidai"


{-| Returns the path to a module's .guidao (optimized) file.
-}
guidao : String -> ModuleName.Raw -> String
guidao root name =
    toArtifactPath root name "guidao"


{-| Returns the path to a module's .guidato (typed optimized) file for MLIR backend.
-}
guidato : String -> ModuleName.Raw -> String
guidato root name =
    toArtifactPath root name "guidato"


toArtifactPath : String -> ModuleName.Raw -> String -> String
toArtifactPath root name ext =
    Utils.fpCombine (stuff root) (Utils.fpAddExtension (ModuleName.toHyphenPath name) ext)



-- ROOT


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



-- LOCKS


{-| Executes a task while holding an exclusive lock on the project root's guida-stuff directory.
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
                Utils.lockWithFileLock (dir ++ "/lock") Utils.LockExclusive (\_ -> work)
            )


{-| Executes a task while holding an exclusive lock on the package registry.
-}
withRegistryLock : PackageCache -> Task Never a -> Task Never a
withRegistryLock (PackageCache dir) work =
    Utils.lockWithFileLock (dir ++ "/lock") Utils.LockExclusive (\_ -> work)



-- PACKAGE CACHES


{-| Represents the package cache directory location.
-}
type PackageCache
    = PackageCache String


{-| Returns the package cache directory, creating it if necessary.
-}
getPackageCache : Task Never PackageCache
getPackageCache =
    Task.map PackageCache (getCacheDir "packages")


{-| Returns the path to the package registry cache file.
-}
registry : PackageCache -> String
registry (PackageCache dir) =
    Utils.fpCombine dir "registry.dat"


{-| Returns the directory path for a specific package version in the cache.
-}
package : PackageCache -> Pkg.Name -> V.Version -> String
package (PackageCache dir) name version =
    Utils.fpCombine dir (Utils.fpCombine (Pkg.toString name) (V.toChars version))


{-| Returns the path to typed artifacts cache for a specific package version.
-}
typedPackageArtifacts : PackageCache -> Pkg.Name -> V.Version -> String
typedPackageArtifacts cache name version =
    package cache name version ++ "/typed-artifacts.dat"



-- CACHE


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
                    root : Utils.FilePath
                    root =
                        Utils.fpCombine home (Utils.fpCombine compilerVersion projectName)
                in
                Utils.dirCreateDirectoryIfMissing True root
                    |> Task.map (\_ -> root)
            )


{-| Returns the Elm home directory, checking GUIDA\_HOME environment variable first.
-}
getElmHome : Task Never String
getElmHome =
    Utils.envLookupEnv "GUIDA_HOME"
        |> Task.andThen
            (\maybeCustomHome ->
                case maybeCustomHome of
                    Just customHome ->
                        Task.succeed customHome

                    Nothing ->
                        Utils.dirGetAppUserDataDirectory "guida"
            )



-- ENCODERS and DECODERS


{-| Encodes a package cache location to bytes.
-}
packageCacheEncoder : PackageCache -> Bytes.Encode.Encoder
packageCacheEncoder (PackageCache dir) =
    BE.string dir


{-| Decodes a package cache location from bytes.
-}
packageCacheDecoder : Bytes.Decode.Decoder PackageCache
packageCacheDecoder =
    Bytes.Decode.map PackageCache BD.string
