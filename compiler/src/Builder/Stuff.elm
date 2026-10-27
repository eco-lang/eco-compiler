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

{-| Names the places on disk where the compiler keeps what it builds, so that
every module that reads or writes an artifact agrees on where it is.

There are two such places. The first belongs to a project: the _stuff
directory_, `<root>/eco-stuff/<compiler version>`, where `<root>` is the
directory holding the project's `elm.json`. It holds the project-level caches
`d.dat` (details), `i.dat` (interfaces) and `o.dat` (objects), and one file per
module: `.eci` (interface), `.eco` (object) and `.ecot` (typed object), named
by the module's hyphenated name. A _build dir_ is an optional subdirectory of
the stuff directory; when one is given, all of these files go there instead, so
that several builds of one project can run side by side with separate
artifacts and separate locks. There is no per-module path function that ignores
the build dir, so a writer and a reader of the same artifact must pass the same
one.

The second place belongs to the user: the _eco home_, which is `$ECO_HOME` when
that is set and otherwise the application data directory named `eco`. The
package cache is `<eco home>/<compiler version>/packages`. A downloaded package
version lives in `<cache>/<author>/<project>/<version>`.

A package can also be _locally linked_: mapped to a directory of source, its
_seed path_, instead of being downloaded. A `PackageCache` carries these
mappings. A linked package still has its cache directory, given by `package`,
which is where its artifacts are written; this module only names the paths and
does not copy anything. `resolveBundledPackages` links the bundled packages
(`eco/kernel` and `eco/system`) that are not mapped explicitly, when it finds
them installed alongside the executable.

Not every file name is chosen here: some modules append a file name such as
`elm.json` or `artifacts.dat` to a path from this module themselves.

The locks are exclusive file locks on a file named `lock` inside the directory
they guard.


# Project Root and Home

@docs findRoot, getElmHome


# Package Cache

@docs PackageCache, getPackageCache, package, isLocalPackage, localPackageSource, registry
@docs localPackages, resolveBundledPackages, bundledPackages, bundledPackagePath
@docs typedPackageArtifacts, packageCacheEncoder, packageCacheDecoder


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


{-| Returns the stuff directory of the project at `root`, ignoring any build
dir.
-}
stuff : String -> String
stuff root =
    root ++ "/eco-stuff/" ++ compilerVersion


{-| Returns the stuff directory of the project at `root`, or the build dir
inside it when `maybeBuildDir` is given.
-}
stuffWithBuildDir : String -> Maybe String -> String
stuffWithBuildDir root maybeBuildDir =
    case maybeBuildDir of
        Nothing ->
            stuff root

        Just buildDir ->
            stuff root ++ "/" ++ buildDir


{-| Returns the path of the details cache file, `d.dat`, in the directory
`stuffWithBuildDir` gives for the same arguments.
-}
detailsWithBuildDir : String -> Maybe String -> String
detailsWithBuildDir root maybeBuildDir =
    stuffWithBuildDir root maybeBuildDir ++ "/d.dat"


{-| Returns the path of the interfaces cache file, `i.dat`, in the directory
`stuffWithBuildDir` gives for the same arguments.
-}
interfacesWithBuildDir : String -> Maybe String -> String
interfacesWithBuildDir root maybeBuildDir =
    stuffWithBuildDir root maybeBuildDir ++ "/i.dat"


{-| Returns the path of the objects cache file, `o.dat`, in the directory
`stuffWithBuildDir` gives for the same arguments.
-}
objectsWithBuildDir : String -> Maybe String -> String
objectsWithBuildDir root maybeBuildDir =
    stuffWithBuildDir root maybeBuildDir ++ "/o.dat"


{-| The compiler's version as text, which names the version directory under
`eco-stuff` and under the eco home, so that compilers of different versions
keep separate caches.
-}
compilerVersion : String
compilerVersion =
    V.toChars V.compiler



-- ====== ECI and ECO ======


{-| Returns the path of the artifact with extension `ext` for module `name`,
in the directory `stuffWithBuildDir` gives for `root` and `maybeBuildDir`.
-}
toArtifactPathWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String -> String
toArtifactPathWithBuildDir root maybeBuildDir name ext =
    Utils.fpCombine (stuffWithBuildDir root maybeBuildDir) (Utils.fpAddExtension (ModuleName.toHyphenPath name) ext)


{-| Returns the path of module `name`'s `.eci` (interface) file, in the
directory `stuffWithBuildDir` gives for `root` and `maybeBuildDir`.
-}
eciWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String
eciWithBuildDir root maybeBuildDir name =
    toArtifactPathWithBuildDir root maybeBuildDir name "eci"


{-| Returns the path of module `name`'s `.eco` (object) file, in the
directory `stuffWithBuildDir` gives for `root` and `maybeBuildDir`.
-}
ecoWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String
ecoWithBuildDir root maybeBuildDir name =
    toArtifactPathWithBuildDir root maybeBuildDir name "eco"


{-| Returns the path of module `name`'s `.ecot` (typed object) file, in the
directory `stuffWithBuildDir` gives for `root` and `maybeBuildDir`.
-}
ecotWithBuildDir : String -> Maybe String -> ModuleName.Raw -> String
ecotWithBuildDir root maybeBuildDir name =
    toArtifactPathWithBuildDir root maybeBuildDir name "ecot"



-- ====== ROOT ======


{-| Finds the project root: the nearest directory, starting from the current
directory and moving up through its parents, that contains an `elm.json`.
Gives `Nothing` if there is none.
-}
findRoot : Task Never (Maybe String)
findRoot =
    Utils.dirGetCurrentDirectory
        |> Task.andThen
            (\dir ->
                findRootHelp (Utils.fpSplitDirectories dir)
            )


{-| Returns the path made of the longest prefix of `dirs` whose directory
contains an `elm.json`, or `Nothing` if no prefix does.
-}
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


{-| Runs `work` while holding the exclusive lock of the stuff directory of the
project at `root`, creating that directory first if it is missing.

This lock ignores build dirs, so it is not the lock `withRootLockBuildDir`
takes for a build dir.

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


{-| Runs `work` while holding the exclusive lock of the directory
`stuffWithBuildDir` gives for `root` and `maybeBuildDir`, creating that
directory first if it is missing.

Each build dir has its own lock, so builds in different build dirs do not wait
for each other. With `Nothing` this is the same lock `withRootLock` takes.

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


{-| Runs `work` while holding the exclusive lock of the package cache
directory; callers take it around access to the registry and cached packages.
Unlike the other locks, this one does not create the directory first.
-}
withRegistryLock : PackageCache -> Task Never a -> Task Never a
withRegistryLock (PackageCache dir _) work =
    Utils.lockWithFileLock (dir ++ "/lock") IO.LockExclusive (\_ -> work)



-- ====== PACKAGE CACHES ======


{-| The user's package cache: the directory downloaded packages live in,
together with the locally linked packages, each as a package name and its seed
path.

A value is made by `getPackageCache`, which creates the directory, or read
back by `packageCacheDecoder`.

-}
type PackageCache
    = PackageCache String (List ( Pkg.Name, FilePath ))


{-| Returns the package cache `<eco home>/<compiler version>/packages`,
creating its directory if it is missing, with `locals` as its locally linked
packages.
-}
getPackageCache : List ( Pkg.Name, FilePath ) -> Task Never PackageCache
getPackageCache locals =
    Task.map (\dir -> PackageCache dir locals) (getCacheDir "packages")


{-| Returns the path of the cached package registry, `registry.dat` in the
package cache directory.
-}
registry : PackageCache -> String
registry (PackageCache dir _) =
    Utils.fpCombine dir "registry.dat"


{-| Returns the directory of version `version` of package `name` in the
package cache, `<cache>/<author>/<project>/<version>`.

A locally linked package gets the same path as a downloaded one; the seed path
is not consulted here (see `localPackageSource`).

-}
package : PackageCache -> Pkg.Name -> V.Version -> String
package (PackageCache dir _) name version =
    Utils.fpCombine dir (Utils.fpCombine (Pkg.toString name) (V.toChars version))


{-| Returns whether `name` is one of the cache's locally linked packages.
-}
isLocalPackage : PackageCache -> Pkg.Name -> Bool
isLocalPackage (PackageCache _ locals) name =
    List.any (\( localPkg, _ ) -> localPkg == name) locals


{-| Returns the seed path of `name` if it is a locally linked package, taking
the first mapping when there are several.
-}
localPackageSource : PackageCache -> Pkg.Name -> Maybe FilePath
localPackageSource (PackageCache _ locals) name =
    lookupLocal name locals


{-| Returns every locally linked package of the cache, with its seed path, in
the order they were given.
-}
localPackages : PackageCache -> List ( Pkg.Name, FilePath )
localPackages (PackageCache _ locals) =
    locals


{-| Returns the path paired with the first occurrence of `name` in `locals`, or
`Nothing` if it does not occur.
-}
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


{-| The packages bundled with an Eco installation, each with its location
relative to the directory holding the executable: the executable is expected
in `<prefix>/bin` and the packages under `<prefix>/share/eco`.
-}
bundledPackages : List ( Pkg.Name, FilePath )
bundledPackages =
    [ ( Pkg.ecoKernel, "../share/eco/kernel/eco-kernel-cpp" )
    , ( Pkg.ecoSystem, "../share/eco/system/system-kernel-cpp" )
    ]


{-| Returns the mappings `explicit` extended with the bundled packages that are
found installed alongside the executable.

`explicit` is kept unchanged and first. Each package of `bundledPackages`
that `explicit` does not map is looked for at its location relative to the
directory `Utils.nodeGetDirname` reports; if that directory exists, its
canonical path is appended as the package's seed path. A bundled package that
is not found is left unmapped, so it is looked up in the package cache like
any other.

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


{-| Returns the canonical path of `relPath` taken relative to `binDir`, or
`Nothing` if no directory exists there.
-}
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


{-| Returns where bundled package `name` is expected relative to the executable,
whether or not it is there, or `Nothing` if `name` is not a bundled package.
The path is not canonicalized.
-}
bundledPackagePath : Pkg.Name -> Task Never (Maybe FilePath)
bundledPackagePath name =
    case lookupLocal name bundledPackages of
        Just relPath ->
            Utils.nodeGetDirname
                |> Task.map (\binDir -> Just (Utils.fpCombine binDir relPath))

        Nothing ->
            Task.succeed Nothing


{-| Returns the path of the typed artifacts file, `typed-artifacts.dat`, in
the cache directory `package` gives for `name` and `version`.
-}
typedPackageArtifacts : PackageCache -> Pkg.Name -> V.Version -> String
typedPackageArtifacts cache name version =
    package cache name version ++ "/typed-artifacts.dat"



-- ====== CACHE ======


{-| Returns the directory `<eco home>/<compiler version>/<projectName>`,
creating it if it is missing.
-}
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


{-| Returns the eco home: the value of the `ECO_HOME` environment variable when
it is set, and otherwise the application data directory named `eco`.
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


{-| Encodes a package cache, its directory and its locally linked packages, as
`packageCacheDecoder` reads it.
-}
packageCacheEncoder : PackageCache -> Bytes.Encode.Encoder
packageCacheEncoder (PackageCache dir locals) =
    Bytes.Encode.sequence
        [ BE.string dir
        , BE.list (\( name, path ) -> Bytes.Encode.sequence [ Pkg.nameEncoder name, BE.string path ]) locals
        ]


{-| A decoder for a package cache, its directory and its locally linked
packages, as `packageCacheEncoder` writes it.
-}
packageCacheDecoder : Bytes.Decode.Decoder PackageCache
packageCacheDecoder =
    Bytes.Decode.map2 PackageCache
        BD.string
        (BD.list (Bytes.Decode.map2 (\a b -> ( a, b )) Pkg.nameDecoder BD.string))
