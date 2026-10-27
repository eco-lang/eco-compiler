module Builder.Elm.Outline exposing
    ( Outline(..), AppOutline(..), AppOutlineData, PkgOutline(..), PkgOutlineData
    , SrcDir(..), srcDirEncoder, srcDirDecoder
    , Exposed(..), flattenExposed
    , read, write
    , Decoder, decoder
    , getAllModulePaths
    , defaultSummary
    )

{-| Every project is described by its `elm.json` file, and this module is the
typed form of that file and the rules a file must meet to be accepted.

The parsed file is called an _outline_. A project is either an application or
a package, and the two files have different fields. An application lists its
source directories and pins every dependency to an exact version, split into
direct and indirect dependencies and again into ordinary and test ones. A
package names itself, gives a summary, a license, its own version and the
modules it exposes, and states its dependencies and the Elm version it accepts
as version constraints.

`read` decodes `<root>/elm.json` with `decoder` and then checks what decoding
cannot: that the right core packages are depended on and that every source
directory exists. Decoding and checking problems come back as an
`Exit.Outline`; a file that cannot be read at all crashes the program, as
`File.readUtf8` describes. Other checks on an outline, such as how its
dependencies fit together, are not made here. `write` turns an outline back
into `elm.json`.

The module also holds a binary encoding of a source directory, and
`getAllModulePaths`, which finds the source file of every module of a project
and of its dependencies.


# Core Types

@docs Outline, AppOutline, AppOutlineData, PkgOutline, PkgOutlineData


# Source Directories

@docs SrcDir, srcDirEncoder, srcDirDecoder


# Exposed Modules

@docs Exposed, flattenExposed


# File Operations

@docs read, write


# JSON Decoding

@docs Decoder, decoder


# Module Discovery

@docs getAllModulePaths


# Utilities

@docs defaultSummary

-}

import Basics.Extra as Basics
import Builder.File as File
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Constraint as Con
import Compiler.Elm.Licenses as Licenses
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Compiler.Parse.Primitives as P
import Data.Map as DataMap
import Dict exposing (Dict)
import System.IO exposing (FilePath)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- ====== OUTLINE ======


{-| The contents of one `elm.json` file: an application's (`App`) or a
package's (`Pkg`), told apart by its `"type"` field.
-}
type Outline
    = App AppOutline
    | Pkg PkgOutline


{-| What an application's `elm.json` says.

Every dependency is pinned to one exact version. `depsDirect` and `depsIndirect`
are the `"direct"` and `"indirect"` objects of `"dependencies"`, and
`testDirect` and `testIndirect` those of `"test-dependencies"`. `elm` is the one
Elm version the application is for.

-}
type alias AppOutlineData =
    { elm : V.Version
    , srcDirs : NE.Nonempty SrcDir
    , depsDirect : Dict Pkg.Name V.Version
    , depsIndirect : Dict Pkg.Name V.Version
    , testDirect : Dict Pkg.Name V.Version
    , testIndirect : Dict Pkg.Name V.Version
    }


{-| The outline of an application, as `AppOutlineData` describes it.
-}
type AppOutline
    = AppOutline AppOutlineData


{-| What a package's `elm.json` says.

Unlike an application's, its dependencies are version constraints, not exact
versions, and so is `elm`, the range of Elm versions it accepts. `version` is
the package's own version. A decoded `summary` is shorter than 80 characters,
as written in the file.

-}
type alias PkgOutlineData =
    { name : Pkg.Name
    , summary : String
    , license : Licenses.License
    , version : V.Version
    , exposed : Exposed
    , deps : Dict Pkg.Name Con.Constraint
    , testDeps : Dict Pkg.Name Con.Constraint
    , elm : Con.Constraint
    }


{-| The outline of a package, as `PkgOutlineData` describes it.
-}
type PkgOutline
    = PkgOutline PkgOutlineData


{-| The modules a package exposes, as its `"exposed-modules"` field writes them.

`ExposedList` is a plain array of module names. `ExposedDict` is an object
whose keys are section titles, each holding an array of module names; the
sections are kept in the order the file gives them, and a decoded title is
shorter than 20 characters as written in the file.

-}
type Exposed
    = ExposedList (List ModuleName.Raw)
    | ExposedDict (List ( String, List ModuleName.Raw ))


{-| One entry of an application's `"source-directories"`, as written.

A relative path (`RelativeSrcDir`) is relative to the project root, the
directory holding `elm.json`; an absolute one is `AbsoluteSrcDir`. Both keep the
text exactly as the file gives it, which is also what is written back.

-}
type SrcDir
    = AbsoluteSrcDir FilePath
    | RelativeSrcDir FilePath



-- ====== DEFAULTS ======


{-| The placeholder summary given to a new package, for its author to replace.
-}
defaultSummary : String
defaultSummary =
    "helpful summary of your project, less than 80 characters"



-- ====== HELPERS ======


{-| Returns every exposed module name, section by section in order when the
modules are in sections.
-}
flattenExposed : Exposed -> List ModuleName.Raw
flattenExposed exposed =
    case exposed of
        ExposedList names ->
            names

        ExposedDict sections ->
            List.concatMap Tuple.second sections



-- ====== WRITE ======


{-| Writes `outline` to `<root>/elm.json`, crashing the program if the write
fails.
-}
write : FilePath -> Outline -> Task Never ()
write root outline =
    E.write (root ++ "/elm.json") (encode outline)



-- ====== JSON ENCODE ======


{-| Returns the JSON of an `elm.json` holding `outline`.
-}
encode : Outline -> E.Value
encode outline =
    case outline of
        App (AppOutline appData) ->
            E.object
                [ ( "type", E.string "application" )
                , ( "source-directories", E.list encodeSrcDir (NE.toList appData.srcDirs) )
                , ( "elm-version", V.encode appData.elm )
                , ( "dependencies"
                  , E.object
                        [ ( "direct", encodeDeps V.encode appData.depsDirect )
                        , ( "indirect", encodeDeps V.encode appData.depsIndirect )
                        ]
                  )
                , ( "test-dependencies"
                  , E.object
                        [ ( "direct", encodeDeps V.encode appData.testDirect )
                        , ( "indirect", encodeDeps V.encode appData.testIndirect )
                        ]
                  )
                ]

        Pkg (PkgOutline pkgData) ->
            E.object
                [ ( "type", E.string "package" )
                , ( "name", Pkg.encode pkgData.name )
                , ( "summary", E.string pkgData.summary )
                , ( "license", Licenses.encode pkgData.license )
                , ( "version", V.encode pkgData.version )
                , ( "exposed-modules", encodeExposed pkgData.exposed )
                , ( "elm-version", Con.encode pkgData.elm )
                , ( "dependencies", encodeDeps Con.encode pkgData.deps )
                , ( "test-dependencies", encodeDeps Con.encode pkgData.testDeps )
                ]


{-| Returns the JSON of an `"exposed-modules"` field: an array, or an object
of sections in their order.
-}
encodeExposed : Exposed -> E.Value
encodeExposed exposed =
    case exposed of
        ExposedList modules ->
            E.list encodeModule modules

        ExposedDict chunks ->
            E.object (List.map (Tuple.mapSecond (E.list encodeModule)) chunks)


{-| Returns a module name as a JSON string, unescaped.
-}
encodeModule : ModuleName.Raw -> E.Value
encodeModule name =
    E.name name


{-| Returns a JSON object of dependencies keyed by package name, with each
version or constraint encoded by `encodeValue`.
-}
encodeDeps : (a -> E.Value) -> Dict Pkg.Name a -> E.Value
encodeDeps encodeValue deps =
    E.stdDict Pkg.toJsonString encodeValue deps


{-| Returns a source directory as the JSON string it was written as.
-}
encodeSrcDir : SrcDir -> E.Value
encodeSrcDir srcDir =
    case srcDir of
        AbsoluteSrcDir dir ->
            E.string dir

        RelativeSrcDir dir ->
            E.string dir



-- ====== PARSE AND VERIFY ======


{-| Reads `<root>/elm.json` and returns its outline, or the first problem
found.

The file must decode with `decoder`. A package must then depend on `elm/core`
in `"dependencies"`, unless it is `elm/core` itself. An application must have
`elm/core` as a direct dependency and `elm/json` as a direct or indirect one,
and every source directory must exist. Test dependencies are not looked at.

There is also a check that no two source directories name the same directory
once canonicalised, but it never reports one: it groups the directories with
`Utils.dictFromListWith`, which always returns an empty dictionary.

The program crashes if the file cannot be read.

-}
read : FilePath -> Task Never (Result Exit.Outline Outline)
read root =
    File.readUtf8 (root ++ "/elm.json")
        |> Task.andThen (parseAndValidateOutline root)


{-| Returns the outline that `bytes`, the text of the `elm.json` in `root`,
decodes to and passes the checks `read` makes, or the first problem found.
-}
parseAndValidateOutline : FilePath -> String -> Task Never (Result Exit.Outline Outline)
parseAndValidateOutline root bytes =
    case D.fromByteString decoder bytes of
        Err err ->
            Err (Exit.OutlineHasBadStructure err) |> Task.succeed

        Ok outline ->
            validateOutline root outline


{-| Returns `outline` if it passes the checks `read` makes after decoding, or
the first problem found.
-}
validateOutline : FilePath -> Outline -> Task Never (Result Exit.Outline Outline)
validateOutline root outline =
    case outline of
        Pkg (PkgOutline pkgData) ->
            validatePkgOutline pkgData.name pkgData.deps outline

        App (AppOutline appData) ->
            validateAppOutline root appData.srcDirs appData.depsDirect appData.depsIndirect outline


{-| Returns `outline`, the outline of package `pkg`, unless `deps` lacks
`elm/core` and `pkg` is not `elm/core` itself.
-}
validatePkgOutline : Pkg.Name -> Dict Pkg.Name a -> Outline -> Task Never (Result Exit.Outline Outline)
validatePkgOutline pkg deps outline =
    Task.succeed <|
        if not (Dict.member Pkg.core deps) && pkg /= Pkg.core then
            Err Exit.OutlineNoPkgCore

        else
            Ok outline


{-| Returns the application `outline` if `direct` holds `elm/core`, `direct` or
`indirect` holds `elm/json`, and the source directories pass the checks of
`checkSrcDirsAndDuplicates`; otherwise the first problem found.
-}
validateAppOutline : FilePath -> NE.Nonempty SrcDir -> Dict Pkg.Name a -> Dict Pkg.Name b -> Outline -> Task Never (Result Exit.Outline Outline)
validateAppOutline root srcDirs direct indirect outline =
    if not (Dict.member Pkg.core direct) then
        Err Exit.OutlineNoAppCore |> Task.succeed

    else if not (Dict.member Pkg.json direct) && not (Dict.member Pkg.json indirect) then
        Err Exit.OutlineNoAppJson |> Task.succeed

    else
        Utils.filterM (isSrcDirMissing root) (NE.toList srcDirs)
            |> Task.andThen (checkSrcDirsAndDuplicates root srcDirs outline)


{-| Returns an error naming `badDirs`, the source directories found missing, if
there are any, and otherwise the result of looking for two of `srcDirs` that
name the same directory.
-}
checkSrcDirsAndDuplicates : FilePath -> NE.Nonempty SrcDir -> Outline -> List SrcDir -> Task Never (Result Exit.Outline Outline)
checkSrcDirsAndDuplicates root srcDirs outline badDirs =
    case List.map toGiven badDirs of
        d :: ds ->
            Err (Exit.OutlineHasMissingSrcDirs d ds) |> Task.succeed

        [] ->
            detectDuplicates root (NE.toList srcDirs)
                |> Task.map (checkForDuplicateSrcDirs outline)


{-| Returns `outline`, or an error when `maybeDups` holds a directory and two
entries that both name it.
-}
checkForDuplicateSrcDirs : Outline -> Maybe ( FilePath, ( FilePath, FilePath ) ) -> Result Exit.Outline Outline
checkForDuplicateSrcDirs outline maybeDups =
    case maybeDups of
        Nothing ->
            Ok outline

        Just ( canonicalDir, ( dir1, dir2 ) ) ->
            Err (Exit.OutlineHasDuplicateSrcDirs canonicalDir dir1 dir2)


{-| Returns whether the source directory is missing, resolved against `root`.
-}
isSrcDirMissing : FilePath -> SrcDir -> Task Never Bool
isSrcDirMissing root srcDir =
    Task.map not (Utils.dirDoesDirectoryExist (toAbsolute root srcDir))


{-| Returns a source directory's path as the file wrote it.
-}
toGiven : SrcDir -> FilePath
toGiven srcDir =
    case srcDir of
        AbsoluteSrcDir dir ->
            dir

        RelativeSrcDir dir ->
            dir


{-| Returns a source directory's path, joined to `root` with `Utils.fpCombine`
when it is relative.
-}
toAbsolute : FilePath -> SrcDir -> FilePath
toAbsolute root srcDir =
    case srcDir of
        AbsoluteSrcDir dir ->
            dir

        RelativeSrcDir dir ->
            Utils.fpCombine root dir


{-| Returns the canonical path of a directory that two of `srcDirs` both name,
with the two entries as written, or `Nothing`.

The entries are grouped by canonical path with `Utils.dictFromListWith`, which
never adds a key, so the grouping is empty and the result is always `Nothing`.
The paths are still canonicalised.

-}
detectDuplicates : FilePath -> List SrcDir -> Task Never (Maybe ( FilePath, ( FilePath, FilePath ) ))
detectDuplicates root srcDirs =
    Utils.listTraverse (toPair root) srcDirs
        |> Task.map
            (\pairs ->
                Utils.dictFromListWith OneOrMore.more pairs
                    |> Utils.dictMapMaybe isDup
                    |> Dict.toList
                    |> List.head
            )


{-| Returns a source directory's canonical path, paired with the path as written.
-}
toPair : FilePath -> SrcDir -> Task Never ( FilePath, OneOrMore.OneOrMore FilePath )
toPair root srcDir =
    Utils.dirCanonicalizePath (toAbsolute root srcDir)
        |> Task.map (\key -> ( key, OneOrMore.one (toGiven srcDir) ))


{-| Returns the first two paths when there are at least two.
-}
isDup : OneOrMore.OneOrMore FilePath -> Maybe ( FilePath, FilePath )
isDup paths =
    case paths of
        OneOrMore.One _ ->
            Nothing

        OneOrMore.More a b ->
            Just (OneOrMore.getFirstTwo a b)



-- ====== GET ALL MODULE PATHS ======


{-| Returns the path of the source file of every module of the project in
`root` and of its dependencies, keyed by the module's canonical name.

Every `.elm` file under a source directory, at any depth, counts as a module,
named by its path below that directory.

For an application, its modules are found in its source directories and are
given the placeholder package name `Pkg.dummyName`; its dependencies are its
direct and indirect ones, at their pinned versions, and test dependencies are
left out. For a package, its own modules are looked for under `<root>/st.src`,
and each dependency is taken at the lower bound of its constraint. A dependency's
modules are looked for under `st.src` in its package cache directory. Only the
listed dependencies are visited, not theirs in turn.

When `read` returns a problem, the result is empty; when it crashes, so does
this. A directory that is looked in and does not exist crashes the program, as
`Utils.dirListDirectory` describes.

-}
getAllModulePaths : FilePath -> Task Never (DataMap.Dict String ModuleName.Canonical FilePath)
getAllModulePaths root =
    read root
        |> Task.andThen
            (\outlineResult ->
                case outlineResult of
                    Err _ ->
                        Task.succeed DataMap.empty

                    Ok outline ->
                        case outline of
                            App (AppOutline appData) ->
                                let
                                    deps : Dict Pkg.Name V.Version
                                    deps =
                                        Dict.union appData.depsDirect appData.depsIndirect

                                    absoluteSrcDirs : List FilePath
                                    absoluteSrcDirs =
                                        List.map (toAbsolute root) (NE.toList appData.srcDirs)
                                in
                                getAllModulePathsHelper Pkg.dummyName absoluteSrcDirs deps

                            Pkg (PkgOutline pkgData) ->
                                let
                                    deps : Dict Pkg.Name V.Version
                                    deps =
                                        Dict.map (\_ -> Con.lowerBound) pkgData.deps
                                in
                                getAllModulePathsHelper pkgData.name [ root ++ "/st.src" ] deps
            )


{-| Returns the modules found under `packageSrcDirs`, as modules of package
`packageName`, together with those of every package in `deps` at the version
given. Where both hold the same canonical name, a dependency's entry is kept.
-}
getAllModulePathsHelper : Pkg.Name -> List FilePath -> Dict Pkg.Name V.Version -> Task Never (DataMap.Dict String ModuleName.Canonical FilePath)
getAllModulePathsHelper packageName packageSrcDirs deps =
    Utils.listTraverse recursiveFindFiles packageSrcDirs
        |> Task.andThen
            (\files ->
                Utils.dictTraverseWithKey resolvePackagePaths deps
                    |> Task.andThen
                        (\dependencyRoots ->
                            Utils.dictTraverse (\( pkgName, pkgRoot ) -> getAllModulePathsHelper pkgName [ pkgRoot ++ "/st.src" ] Dict.empty) dependencyRoots
                                |> Task.map
                                    (\dependencyMaps ->
                                        let
                                            asMap : DataMap.Dict String ModuleName.Canonical FilePath
                                            asMap =
                                                List.concat files
                                                    |> List.map (\( root, fp ) -> ( ModuleName.Canonical packageName (moduleNameFromFilePath root fp), fp ))
                                                    |> DataMap.fromList ModuleName.toComparableCanonical
                                        in
                                        Dict.foldr (\_ -> DataMap.union) asMap dependencyMaps
                                    )
                        )
            )


{-| Returns the path of every `.elm` file under `root`, each paired with `root`.
-}
recursiveFindFiles : FilePath -> Task Never (List ( FilePath, FilePath ))
recursiveFindFiles root =
    recursiveFindFilesHelp root
        |> Task.map (List.map (Tuple.pair root))


{-| Returns the path of every `.elm` file under `root`, at any depth, those in
subdirectories first.
-}
recursiveFindFilesHelp : FilePath -> Task Never (List FilePath)
recursiveFindFilesHelp root =
    Utils.dirListDirectory root
        |> Task.andThen
            (\dirContents ->
                let
                    ( elmFiles, others ) =
                        List.partition (hasExtension ".elm") dirContents
                in
                Utils.filterM (\fp -> Utils.dirDoesDirectoryExist (root ++ "/" ++ fp)) others
                    |> Task.andThen
                        (\subDirectories ->
                            Utils.listTraverse (\subDirectory -> recursiveFindFilesHelp (root ++ "/" ++ subDirectory)) subDirectories
                                |> Task.map
                                    (\filesFromSubDirs ->
                                        List.concat filesFromSubDirs ++ List.map (\fp -> root ++ "/" ++ fp) elmFiles
                                    )
                        )
            )


{-| Returns whether `path` ends in extension `ext`, which includes its `.`.
-}
hasExtension : String -> FilePath -> Bool
hasExtension ext path =
    ext == Utils.fpTakeExtension path


{-| Returns the module name of `filePath`, a file under `root`: its path below
`root` without the extension, with `/` turned into `.`.
-}
moduleNameFromFilePath : FilePath -> FilePath -> Name.Name
moduleNameFromFilePath root filePath =
    filePath
        |> String.dropLeft (String.length root + 1)
        |> Utils.fpDropExtension
        |> String.replace "/" "."


{-| Returns `pkgName` paired with its package cache directory for version `vsn`.
-}
resolvePackagePaths : Pkg.Name -> V.Version -> Task Never ( Pkg.Name, FilePath )
resolvePackagePaths pkgName vsn =
    Stuff.resolveBundledPackages []
        |> Task.andThen Stuff.getPackageCache
        |> Task.map (\packageCache -> ( pkgName, Stuff.package packageCache pkgName vsn ))



-- ====== JSON DECODE ======


{-| A JSON decoder of part of an `elm.json`, whose problems are
`Exit.OutlineProblem`s.
-}
type alias Decoder a =
    D.Decoder Exit.OutlineProblem a


{-| A decoder for a whole `elm.json`, read as an application or a package
according to its `"type"` field; any other `"type"` fails with `OP_BadType`.

It decodes only. The checks `read` makes afterwards are not made here.

-}
decoder : Decoder Outline
decoder =
    let
        application : String
        application =
            "application"

        package : String
        package =
            "package"
    in
    D.field "type" D.string
        |> D.andThen
            (\tipe ->
                if tipe == application then
                    D.map App appDecoder

                else if tipe == package then
                    D.map Pkg pkgDecoder

                else
                    D.failure Exit.OP_BadType
            )


{-| A decoder for the fields of an application's `elm.json`.
-}
appDecoder : Decoder AppOutline
appDecoder =
    D.pure (\elm srcDirs depsDirect depsIndirect testDirect testIndirect -> AppOutline { elm = elm, srcDirs = srcDirs, depsDirect = depsDirect, depsIndirect = depsIndirect, testDirect = testDirect, testIndirect = testIndirect })
        |> D.apply (D.field "elm-version" versionDecoder)
        |> D.apply (D.field "source-directories" dirsDecoder)
        |> D.apply (D.field "dependencies" (D.field "direct" (depsDecoder versionDecoder)))
        |> D.apply (D.field "dependencies" (D.field "indirect" (depsDecoder versionDecoder)))
        |> D.apply (D.field "test-dependencies" (D.field "direct" (depsDecoder versionDecoder)))
        |> D.apply (D.field "test-dependencies" (D.field "indirect" (depsDecoder versionDecoder)))


{-| A decoder for the fields of a package's `elm.json`.
-}
pkgDecoder : Decoder PkgOutline
pkgDecoder =
    D.pure (\name summary license version exposed deps testDeps elm -> PkgOutline { name = name, summary = summary, license = license, version = version, exposed = exposed, deps = deps, testDeps = testDeps, elm = elm })
        |> D.apply (D.field "name" nameDecoder)
        |> D.apply (D.field "summary" summaryDecoder)
        |> D.apply (D.field "license" (Licenses.decoder Exit.OP_BadLicense))
        |> D.apply (D.field "version" versionDecoder)
        |> D.apply (D.field "exposed-modules" exposedDecoder)
        |> D.apply (D.field "dependencies" (depsDecoder constraintDecoder))
        |> D.apply (D.field "test-dependencies" (depsDecoder constraintDecoder))
        |> D.apply (D.field "elm-version" constraintDecoder)



-- ====== JSON DECODE HELPERS ======


{-| A decoder for a package name.
-}
nameDecoder : Decoder Pkg.Name
nameDecoder =
    D.mapError (Basics.uncurry Exit.OP_BadPkgName) Pkg.decoder


{-| A decoder for a package summary, which fails with `OP_BadSummaryTooLong`
unless its text, as written in the file, is shorter than 80 characters.
-}
summaryDecoder : Decoder String
summaryDecoder =
    D.customString
        (boundParser 80 Exit.OP_BadSummaryTooLong)
        (\_ _ -> Exit.OP_BadSummaryTooLong)


{-| A decoder for an exact version.
-}
versionDecoder : Decoder V.Version
versionDecoder =
    D.mapError (Basics.uncurry Exit.OP_BadVersion) V.decoder


{-| A decoder for a version constraint.
-}
constraintDecoder : Decoder Con.Constraint
constraintDecoder =
    D.mapError Exit.OP_BadConstraint Con.decoder


{-| Produces a decoder for an object of dependencies keyed by package name, with
each value read by `valueDecoder`.
-}
depsDecoder : Decoder a -> Decoder (Dict Pkg.Name a)
depsDecoder valueDecoder =
    D.stdDict (Pkg.keyDecoder Exit.OP_BadDependencyName) valueDecoder


{-| A decoder for a non-empty array of source directories, each classed as
relative or absolute; an empty array fails with `OP_NoSrcDirs`.
-}
dirsDecoder : Decoder (NE.Nonempty SrcDir)
dirsDecoder =
    D.map (NE.map toSrcDir) (D.nonEmptyList D.string Exit.OP_NoSrcDirs)


{-| Returns `path` as a relative or an absolute source directory, as
`Utils.fpIsRelative` judges it.
-}
toSrcDir : FilePath -> SrcDir
toSrcDir path =
    if Utils.fpIsRelative path then
        RelativeSrcDir path

    else
        AbsoluteSrcDir path



-- ====== EXPOSED MODULES DECODER ======


{-| A decoder for `"exposed-modules"`, tried first as an array of module names
and then as an object of sections.
-}
exposedDecoder : Decoder Exposed
exposedDecoder =
    D.oneOf
        [ D.map ExposedList (D.list moduleDecoder)
        , D.map ExposedDict (D.pairs headerKeyDecoder (D.list moduleDecoder))
        ]


{-| A decoder for a module name.
-}
moduleDecoder : Decoder ModuleName.Raw
moduleDecoder =
    D.mapError (Basics.uncurry Exit.OP_BadModuleName) ModuleName.decoder


{-| A key decoder for a section title of `"exposed-modules"`, which fails with
`OP_BadModuleHeaderTooLong` unless the title, as written in the file, is
shorter than 20 characters.
-}
headerKeyDecoder : D.KeyDecoder Exit.OutlineProblem String
headerKeyDecoder =
    D.KeyDecoder
        (boundParser 20 Exit.OP_BadModuleHeaderTooLong)
        (\_ _ -> Exit.OP_BadModuleHeaderTooLong)



-- ====== BOUND PARSER ======


{-| Produces a parser that reads all of the remaining text and succeeds with it
when it is shorter than `bound`, and otherwise fails with `tooLong`.
-}
boundParser : Int -> x -> P.Parser x String
boundParser bound tooLong =
    P.Parser <|
        \(P.State st) ->
            let
                len : Int
                len =
                    st.end - st.pos

                newCol : P.Col
                newCol =
                    st.col + len
            in
            if len < bound then
                P.Cok (String.slice st.pos st.end st.src) (P.State { st | pos = st.end, col = newCol })

            else
                P.Cerr st.row newCol (\_ _ -> tooLong)


{-| Returns the binary encoding of a source directory: a tag byte, 0 for
absolute and 1 for relative, then the path. `srcDirDecoder` reads it back.
-}
srcDirEncoder : SrcDir -> Bytes.Encode.Encoder
srcDirEncoder srcDir =
    case srcDir of
        AbsoluteSrcDir dir ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string dir
                ]

        RelativeSrcDir dir ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string dir
                ]


{-| A decoder for the binary encoding `srcDirEncoder` writes. Any tag other than
0 or 1 fails.
-}
srcDirDecoder : Bytes.Decode.Decoder SrcDir
srcDirDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map AbsoluteSrcDir BD.string

                    1 ->
                        Bytes.Decode.map RelativeSrcDir BD.string

                    _ ->
                        Bytes.Decode.fail
            )
