module Builder.Elm.Outline exposing
    ( Outline(..), AppOutline(..), AppOutlineData, PkgOutline(..), PkgOutlineData
    , SrcDir(..), srcDirEncoder, srcDirDecoder
    , Exposed(..), flattenExposed
    , read, write
    , Decoder, decoder
    , getAllModulePaths
    , defaultSummary
    )

{-| Project outline parsing and validation for elm.json files.

This module handles reading, parsing, and validating elm.json configuration files
for both application and package projects. It validates dependencies, source
directories, exposed modules, and enforces structural constraints.


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
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils exposing (FilePath)



-- OUTLINE


type Outline
    = App AppOutline
    | Pkg PkgOutline


type alias AppOutlineData =
    { elm : V.Version
    , srcDirs : NE.Nonempty SrcDir
    , depsDirect : Dict ( String, String ) Pkg.Name V.Version
    , depsIndirect : Dict ( String, String ) Pkg.Name V.Version
    , testDirect : Dict ( String, String ) Pkg.Name V.Version
    , testIndirect : Dict ( String, String ) Pkg.Name V.Version
    }


type AppOutline
    = AppOutline AppOutlineData


type alias PkgOutlineData =
    { name : Pkg.Name
    , summary : String
    , license : Licenses.License
    , version : V.Version
    , exposed : Exposed
    , deps : Dict ( String, String ) Pkg.Name Con.Constraint
    , testDeps : Dict ( String, String ) Pkg.Name Con.Constraint
    , elm : Con.Constraint
    }


type PkgOutline
    = PkgOutline PkgOutlineData


type Exposed
    = ExposedList (List ModuleName.Raw)
    | ExposedDict (List ( String, List ModuleName.Raw ))


type SrcDir
    = AbsoluteSrcDir FilePath
    | RelativeSrcDir FilePath



-- DEFAULTS


defaultSummary : String
defaultSummary =
    "helpful summary of your project, less than 80 characters"



-- HELPERS


flattenExposed : Exposed -> List ModuleName.Raw
flattenExposed exposed =
    case exposed of
        ExposedList names ->
            names

        ExposedDict sections ->
            List.concatMap Tuple.second sections



-- WRITE


write : FilePath -> Outline -> Task Never ()
write root outline =
    E.write (root ++ "/elm.json") (encode outline)



-- JSON ENCODE


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


encodeExposed : Exposed -> E.Value
encodeExposed exposed =
    case exposed of
        ExposedList modules ->
            E.list encodeModule modules

        ExposedDict chunks ->
            E.object (List.map (Tuple.mapSecond (E.list encodeModule)) chunks)


encodeModule : ModuleName.Raw -> E.Value
encodeModule name =
    E.name name


encodeDeps : (a -> E.Value) -> Dict ( String, String ) Pkg.Name a -> E.Value
encodeDeps encodeValue deps =
    E.dict Pkg.compareName Pkg.toJsonString encodeValue deps


encodeSrcDir : SrcDir -> E.Value
encodeSrcDir srcDir =
    case srcDir of
        AbsoluteSrcDir dir ->
            E.string dir

        RelativeSrcDir dir ->
            E.string dir



-- PARSE AND VERIFY


read : FilePath -> Task Never (Result Exit.Outline Outline)
read root =
    File.readUtf8 (root ++ "/elm.json")
        |> Task.andThen (parseAndValidateOutline root)


parseAndValidateOutline : FilePath -> String -> Task Never (Result Exit.Outline Outline)
parseAndValidateOutline root bytes =
    case D.fromByteString decoder bytes of
        Err err ->
            Err (Exit.OutlineHasBadStructure err) |> Task.succeed

        Ok outline ->
            validateOutline root outline


validateOutline : FilePath -> Outline -> Task Never (Result Exit.Outline Outline)
validateOutline root outline =
    case outline of
        Pkg (PkgOutline pkgData) ->
            validatePkgOutline pkgData.name pkgData.deps outline

        App (AppOutline appData) ->
            validateAppOutline root appData.srcDirs appData.depsDirect appData.depsIndirect outline


validatePkgOutline : Pkg.Name -> Dict ( String, String ) Pkg.Name a -> Outline -> Task Never (Result Exit.Outline Outline)
validatePkgOutline pkg deps outline =
    Task.succeed <|
        if not (Dict.member identity Pkg.core deps) && pkg /= Pkg.core then
            Err Exit.OutlineNoPkgCore

        else
            Ok outline


validateAppOutline : FilePath -> NE.Nonempty SrcDir -> Dict ( String, String ) Pkg.Name a -> Dict ( String, String ) Pkg.Name b -> Outline -> Task Never (Result Exit.Outline Outline)
validateAppOutline root srcDirs direct indirect outline =
    if not (Dict.member identity Pkg.core direct) then
        Err Exit.OutlineNoAppCore |> Task.succeed

    else if not (Dict.member identity Pkg.json direct) && not (Dict.member identity Pkg.json indirect) then
        Err Exit.OutlineNoAppJson |> Task.succeed

    else
        Utils.filterM (isSrcDirMissing root) (NE.toList srcDirs)
            |> Task.andThen (checkSrcDirsAndDuplicates root srcDirs outline)


checkSrcDirsAndDuplicates : FilePath -> NE.Nonempty SrcDir -> Outline -> List SrcDir -> Task Never (Result Exit.Outline Outline)
checkSrcDirsAndDuplicates root srcDirs outline badDirs =
    case List.map toGiven badDirs of
        d :: ds ->
            Err (Exit.OutlineHasMissingSrcDirs d ds) |> Task.succeed

        [] ->
            detectDuplicates root (NE.toList srcDirs)
                |> Task.map (checkForDuplicateSrcDirs outline)


checkForDuplicateSrcDirs : Outline -> Maybe ( FilePath, ( FilePath, FilePath ) ) -> Result Exit.Outline Outline
checkForDuplicateSrcDirs outline maybeDups =
    case maybeDups of
        Nothing ->
            Ok outline

        Just ( canonicalDir, ( dir1, dir2 ) ) ->
            Err (Exit.OutlineHasDuplicateSrcDirs canonicalDir dir1 dir2)


isSrcDirMissing : FilePath -> SrcDir -> Task Never Bool
isSrcDirMissing root srcDir =
    Task.map not (Utils.dirDoesDirectoryExist (toAbsolute root srcDir))


toGiven : SrcDir -> FilePath
toGiven srcDir =
    case srcDir of
        AbsoluteSrcDir dir ->
            dir

        RelativeSrcDir dir ->
            dir


toAbsolute : FilePath -> SrcDir -> FilePath
toAbsolute root srcDir =
    case srcDir of
        AbsoluteSrcDir dir ->
            dir

        RelativeSrcDir dir ->
            Utils.fpCombine root dir


detectDuplicates : FilePath -> List SrcDir -> Task Never (Maybe ( FilePath, ( FilePath, FilePath ) ))
detectDuplicates root srcDirs =
    Utils.listTraverse (toPair root) srcDirs
        |> Task.map
            (\pairs ->
                Utils.mapFromListWith identity OneOrMore.more pairs |> Utils.mapMapMaybe identity compare isDup |> Utils.mapLookupMin
            )


toPair : FilePath -> SrcDir -> Task Never ( FilePath, OneOrMore.OneOrMore FilePath )
toPair root srcDir =
    Utils.dirCanonicalizePath (toAbsolute root srcDir)
        |> Task.map (\key -> ( key, OneOrMore.one (toGiven srcDir) ))


isDup : OneOrMore.OneOrMore FilePath -> Maybe ( FilePath, FilePath )
isDup paths =
    case paths of
        OneOrMore.One _ ->
            Nothing

        OneOrMore.More a b ->
            Just (OneOrMore.getFirstTwo a b)



-- GET ALL MODULE PATHS


getAllModulePaths : FilePath -> Task Never (Dict (List String) TypeCheck.Canonical FilePath)
getAllModulePaths root =
    read root
        |> Task.andThen
            (\outlineResult ->
                case outlineResult of
                    Err _ ->
                        Task.succeed Dict.empty

                    Ok outline ->
                        case outline of
                            App (AppOutline appData) ->
                                let
                                    deps : Dict ( String, String ) Pkg.Name V.Version
                                    deps =
                                        Dict.union appData.depsDirect appData.depsIndirect

                                    absoluteSrcDirs : List FilePath
                                    absoluteSrcDirs =
                                        List.map (toAbsolute root) (NE.toList appData.srcDirs)
                                in
                                getAllModulePathsHelper Pkg.dummyName absoluteSrcDirs deps

                            Pkg (PkgOutline pkgData) ->
                                let
                                    deps : Dict ( String, String ) Pkg.Name V.Version
                                    deps =
                                        Dict.map (\_ -> Con.lowerBound) pkgData.deps
                                in
                                getAllModulePathsHelper pkgData.name [ root ++ "/st.src" ] deps
            )


getAllModulePathsHelper : Pkg.Name -> List FilePath -> Dict ( String, String ) Pkg.Name V.Version -> Task Never (Dict (List String) TypeCheck.Canonical FilePath)
getAllModulePathsHelper packageName packageSrcDirs deps =
    Utils.listTraverse recursiveFindFiles packageSrcDirs
        |> Task.andThen
            (\files ->
                Utils.mapTraverseWithKey identity compare resolvePackagePaths deps
                    |> Task.andThen
                        (\dependencyRoots ->
                            Utils.mapTraverse identity compare (\( pkgName, pkgRoot ) -> getAllModulePathsHelper pkgName [ pkgRoot ++ "/st.src" ] Dict.empty) dependencyRoots
                                |> Task.map
                                    (\dependencyMaps ->
                                        let
                                            asMap : Dict (List String) TypeCheck.Canonical FilePath
                                            asMap =
                                                List.concat files
                                                    |> List.map (\( root, fp ) -> ( TypeCheck.Canonical packageName (moduleNameFromFilePath root fp), fp ))
                                                    |> Dict.fromList ModuleName.toComparableCanonical
                                        in
                                        Dict.foldr compare (\_ -> Dict.union) asMap dependencyMaps
                                    )
                        )
            )


recursiveFindFiles : FilePath -> Task Never (List ( FilePath, FilePath ))
recursiveFindFiles root =
    recursiveFindFilesHelp root
        |> Task.map (List.map (Tuple.pair root))


recursiveFindFilesHelp : FilePath -> Task Never (List FilePath)
recursiveFindFilesHelp root =
    Utils.dirListDirectory root
        |> Task.andThen
            (\dirContents ->
                let
                    ( elmFiles, ( guidaFiles, others ) ) =
                        List.partition (hasExtension ".elm") dirContents
                            |> Tuple.mapSecond (List.partition (hasExtension ".guida"))
                in
                Utils.filterM (\fp -> Utils.dirDoesDirectoryExist (root ++ "/" ++ fp)) others
                    |> Task.andThen
                        (\subDirectories ->
                            Utils.listTraverse (\subDirectory -> recursiveFindFilesHelp (root ++ "/" ++ subDirectory)) subDirectories
                                |> Task.map
                                    (\filesFromSubDirs ->
                                        List.concat filesFromSubDirs ++ List.map (\fp -> root ++ "/" ++ fp) (elmFiles ++ guidaFiles)
                                    )
                        )
            )


hasExtension : String -> FilePath -> Bool
hasExtension ext path =
    ext == Utils.fpTakeExtension path


moduleNameFromFilePath : FilePath -> FilePath -> Name.Name
moduleNameFromFilePath root filePath =
    filePath
        |> String.dropLeft (String.length root + 1)
        |> Utils.fpDropExtension
        |> String.replace "/" "."


resolvePackagePaths : Pkg.Name -> V.Version -> Task Never ( Pkg.Name, FilePath )
resolvePackagePaths pkgName vsn =
    Stuff.getPackageCache
        |> Task.map (\packageCache -> ( pkgName, Stuff.package packageCache pkgName vsn ))



-- JSON DECODE


type alias Decoder a =
    D.Decoder Exit.OutlineProblem a


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


appDecoder : Decoder AppOutline
appDecoder =
    D.pure (\elm srcDirs depsDirect depsIndirect testDirect testIndirect -> AppOutline { elm = elm, srcDirs = srcDirs, depsDirect = depsDirect, depsIndirect = depsIndirect, testDirect = testDirect, testIndirect = testIndirect })
        |> D.apply (D.field "elm-version" versionDecoder)
        |> D.apply (D.field "source-directories" dirsDecoder)
        |> D.apply (D.field "dependencies" (D.field "direct" (depsDecoder versionDecoder)))
        |> D.apply (D.field "dependencies" (D.field "indirect" (depsDecoder versionDecoder)))
        |> D.apply (D.field "test-dependencies" (D.field "direct" (depsDecoder versionDecoder)))
        |> D.apply (D.field "test-dependencies" (D.field "indirect" (depsDecoder versionDecoder)))


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



-- JSON DECODE HELPERS


nameDecoder : Decoder Pkg.Name
nameDecoder =
    D.mapError (Basics.uncurry Exit.OP_BadPkgName) Pkg.decoder


summaryDecoder : Decoder String
summaryDecoder =
    D.customString
        (boundParser 80 Exit.OP_BadSummaryTooLong)
        (\_ _ -> Exit.OP_BadSummaryTooLong)


versionDecoder : Decoder V.Version
versionDecoder =
    D.mapError (Basics.uncurry Exit.OP_BadVersion) V.decoder


constraintDecoder : Decoder Con.Constraint
constraintDecoder =
    D.mapError Exit.OP_BadConstraint Con.decoder


depsDecoder : Decoder a -> Decoder (Dict ( String, String ) Pkg.Name a)
depsDecoder valueDecoder =
    D.dict identity (Pkg.keyDecoder Exit.OP_BadDependencyName) valueDecoder


dirsDecoder : Decoder (NE.Nonempty SrcDir)
dirsDecoder =
    D.map (NE.map toSrcDir) (D.nonEmptyList D.string Exit.OP_NoSrcDirs)


toSrcDir : FilePath -> SrcDir
toSrcDir path =
    if Utils.fpIsRelative path then
        RelativeSrcDir path

    else
        AbsoluteSrcDir path



-- EXPOSED MODULES DECODER


exposedDecoder : Decoder Exposed
exposedDecoder =
    D.oneOf
        [ D.map ExposedList (D.list moduleDecoder)
        , D.map ExposedDict (D.pairs headerKeyDecoder (D.list moduleDecoder))
        ]


moduleDecoder : Decoder ModuleName.Raw
moduleDecoder =
    D.mapError (Basics.uncurry Exit.OP_BadModuleName) ModuleName.decoder


headerKeyDecoder : D.KeyDecoder Exit.OutlineProblem String
headerKeyDecoder =
    D.KeyDecoder
        (boundParser 20 Exit.OP_BadModuleHeaderTooLong)
        (\_ _ -> Exit.OP_BadModuleHeaderTooLong)



-- BOUND PARSER


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
