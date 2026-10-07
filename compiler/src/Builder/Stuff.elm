module Builder.Stuff exposing
    ( findRoot, getElmHome
    , PackageCache, getPackageCache, package, isLocalPackage, localPackageSource, registry
    , localPackages, resolveBundledPackages, bundledPackages, bundledPackagePath
    , typedPackageArtifacts, packageCacheEncoder, packageCacheDecoder
    , withRootLock, withRootLockBuildDir, withRegistryLock
    , detailsWithBuildDir, eciWithBuildDir, ecoWithBuildDir
    , ecotWithBuildDir, interfacesWithBuildDir, objectsWithBuildDir
    , stuffWithBuildDir
    )

{-| File path management and artifact location for the Eco compiler build system.

This module centralizes all knowledge about where the compiler stores its build
artifacts, caches, and intermediate files. It handles the `eco-stuff` directory
structure, package caches, and provides utilities for finding project roots and
managing file locks.


# Project Root and Home

@docs findRoot, getElmHome


# Package Cache

@docs PackageCache, getPackageCache, package, isLocalPackage, localPackageSource, registry
@docs localPackages, resolveBundledPackages, bundledPackages, bundledPackagePath
@docs typedPackageArtifacts, packageCacheEncoder, packageCacheDecoder


# Special Directories


# File Locking

@docs withRootLock, withRootLockBuildDir, withRegistryLock


# Build Directory Variants

@docs detailsWithBuildDir, eciWithBuildDir, ecoWithBuildDir
@docs ecotWithBuildDir, interfacesWithBuildDir, objectsWithBuildDir
@docs stuffWithBuildDir

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Prelude
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
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


compilerVersion : String
compilerVersion =
    V.toChars V.compiler



-- ====== ECI and ECO ======
-- Per-module artifacts live under the build directory when one is given, next
-- to that build's d.dat / i.dat / o.dat (cache-serialization plan S12b): Build
-- and Generate must agree on the path, so there is deliberately no root-only
-- variant.


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


{-| Represents the package cache directory location, together with the
locally linked packages (`--local-package` mappings plus any bundled packages
found next to the executable), each as a `( package, seed path )` pair.
-}
type PackageCache
    = PackageCache String (List ( Pkg.Name, FilePath ))


{-| Returns the package cache directory, creating it if necessary.
-}
getPackageCache : List ( Pkg.Name, FilePath ) -> Task Never PackageCache
getPackageCache locals =
    Task.map (\dir -> PackageCache dir locals) (getCacheDir "packages")


{-| Returns the path to the package registry cache file.
-}
registry : PackageCache -> String
registry (PackageCache dir _) =
    Utils.fpCombine dir "registry.dat"


{-| Returns the directory path for a specific package version in the cache.

A locally linked package resolves to the same cache path as a downloaded one: its
source is copied from the seed path (see `localPackageSource`) into this cache
directory, and all reads and writes then use the cache so artifacts land in the
writable `~/.eco` tree rather than the (possibly read-only) seed. The copy is
refreshed whenever the seed's fingerprint changes.

-}
package : PackageCache -> Pkg.Name -> V.Version -> String
package (PackageCache dir _) name version =
    Utils.fpCombine dir (Utils.fpCombine (Pkg.toString name) (V.toChars version))


{-| Check whether a package name matches one of the locally linked packages.
-}
isLocalPackage : PackageCache -> Pkg.Name -> Bool
isLocalPackage (PackageCache _ locals) name =
    List.any (\( localPkg, _ ) -> localPkg == name) locals


{-| Returns the read-only seed path for a locally linked package, if `name`
matches one of the configured local packages (the first mapping wins). The
package source is copied from here into the cache; thereafter `package` (the
cache path) is used for all reads and writes.
-}
localPackageSource : PackageCache -> Pkg.Name -> Maybe FilePath
localPackageSource (PackageCache _ locals) name =
    lookupLocal name locals


{-| Returns every locally linked package mapping held by the cache.
-}
localPackages : PackageCache -> List ( Pkg.Name, FilePath )
localPackages (PackageCache _ locals) =
    locals


lookupLocal : Pkg.Name -> List ( Pkg.Name, FilePath ) -> Maybe FilePath
lookupLocal name locals =
    case locals of
        [] ->
            Nothing

        ( localPkg, localPath ) :: rest ->
            if localPkg == name then
                Just localPath

            else
                lookupLocal name rest


{-| The packages bundled with an Eco installation, with their location relative
to the directory holding the executable (binary in `<prefix>/bin`, packages in
`<prefix>/share/eco/...`).
-}
bundledPackages : List ( Pkg.Name, FilePath )
bundledPackages =
    [ ( Pkg.ecoKernel, "../share/eco/kernel/eco-kernel-cpp" )
    , ( Pkg.ecoSystem, "../share/eco/system/system-kernel-cpp" )
    ]


{-| Extend the local-package mappings with the bundled packages.

Explicit mappings (e.g. from `--local-package` flags) always win. For each
bundled package (`eco/kernel`, `eco/system`) that is **not already mapped**, we
look for it next to the executable (see `bundledPackages`) and append the
canonical path if the directory exists. Bundled packages that are not found are
left unmapped so the normal package cache lookup applies.

Shared by `make`, `init`, `install` and the other commands so all of them
resolve the bundled packages identically.

-}
resolveBundledPackages : List ( Pkg.Name, FilePath ) -> Task Never (List ( Pkg.Name, FilePath ))
resolveBundledPackages explicit =
    let
        missing : List ( Pkg.Name, FilePath )
        missing =
            List.filter (\( pkg, _ ) -> lookupLocal pkg explicit == Nothing) bundledPackages
    in
    case missing of
        [] ->
            Task.succeed explicit

        _ ->
            Utils.nodeGetDirname
                |> Task.andThen
                    (\binDir ->
                        List.foldl
                            (\( pkg, relPath ) acc ->
                                acc
                                    |> Task.andThen
                                        (\found ->
                                            probeBundled binDir relPath
                                                |> Task.map
                                                    (\maybePath ->
                                                        case maybePath of
                                                            Just path ->
                                                                found ++ [ ( pkg, path ) ]

                                                            Nothing ->
                                                                found
                                                    )
                                        )
                            )
                            (Task.succeed explicit)
                            missing
                    )


probeBundled : FilePath -> FilePath -> Task Never (Maybe FilePath)
probeBundled binDir relPath =
    let
        dir : FilePath
        dir =
            Utils.fpCombine binDir relPath
    in
    Utils.dirDoesDirectoryExist dir
        |> Task.andThen
            (\exists ->
                if exists then
                    Utils.dirCanonicalizePath dir |> Task.map Just

                else
                    Task.succeed Nothing
            )


{-| Returns the expected location of a bundled package next to the executable,
for error messages. `Nothing` if the package is not one of the bundled ones.
-}
bundledPackagePath : Pkg.Name -> Task Never (Maybe FilePath)
bundledPackagePath name =
    case lookupLocal name bundledPackages of
        Just relPath ->
            Utils.nodeGetDirname
                |> Task.map (\binDir -> Just (Utils.fpCombine binDir relPath))

        Nothing ->
            Task.succeed Nothing


{-| Returns the path to typed artifacts cache for a specific package version.
-}
typedPackageArtifacts : PackageCache -> Pkg.Name -> V.Version -> String
typedPackageArtifacts cache name version =
    package cache name version ++ "/typed-artifacts.dat"



-- ====== CACHE ======


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
packageCacheEncoder (PackageCache dir locals) =
    Bytes.Encode.sequence
        [ BE.string dir
        , BE.list (\( name, path ) -> Bytes.Encode.sequence [ Pkg.nameEncoder name, BE.string path ]) locals
        ]


{-| Decodes a package cache location from bytes.
-}
packageCacheDecoder : Bytes.Decode.Decoder PackageCache
packageCacheDecoder =
    Bytes.Decode.map2 PackageCache
        BD.string
        (BD.list (Bytes.Decode.map2 (\a b -> ( a, b )) Pkg.nameDecoder BD.string))
