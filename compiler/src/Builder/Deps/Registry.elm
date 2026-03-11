module Builder.Deps.Registry exposing
    ( Registry(..), KnownVersions(..)
    , read, fetch, update, latest
    , getVersions, getVersions_
    , registryDecoder, registryEncoder
    )

{-| Manages the package registry, which tracks all available Elm packages and their versions.

The registry is cached locally and synchronized with the package server at package.elm-lang.org.
This module handles fetching, updating, and querying the registry for dependency resolution.


# Registry Types

@docs Registry, KnownVersions


# Loading and Updating

@docs read, fetch, update, latest


# Querying Versions

@docs getVersions, getVersions_


# Serialization

@docs registryDecoder, registryEncoder

-}

import Basics.Extra exposing (flip)
import Builder.Deps.Website as Website
import Builder.File as File
import Builder.Http as Http
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Bytes.Decode
import Bytes.Encode
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Compiler.Parse.Primitives as P
import Dict exposing (Dict)
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== REGISTRY ======


{-| The package registry maps package names to their available versions.
Contains a count of entries for incremental updates and a dictionary of packages.
-}
type Registry
    = Registry Int (Dict Pkg.Name KnownVersions)


{-| Available versions of a package, with the latest version first followed by older versions.
-}
type KnownVersions
    = KnownVersions V.Version (List V.Version)



-- ====== READ ======


{-| Read the cached registry from disk. Returns Nothing if the cache doesn't exist or is invalid.
-}
read : Stuff.PackageCache -> Task Never (Maybe Registry)
read cache =
    File.readBinary registryDecoder (Stuff.registry cache)



-- ====== FETCH ======


{-| Fetch the complete registry from the package server and cache it locally.
Use this for initial registry download or when the cache is missing.
-}
fetch : Http.Manager -> Stuff.PackageCache -> Task Never (Result Exit.RegistryProblem Registry)
fetch manager cache =
    post manager "/all-packages" allPkgsDecoder <|
        \versions ->
            let
                size : Int
                size =
                    Dict.foldr (\_ -> addEntry) 0 versions

                registry : Registry
                registry =
                    Registry size versions

                path : String
                path =
                    Stuff.registry cache
            in
            File.writeBinary registryEncoder path registry
                |> Task.map (\_ -> registry)


addEntry : KnownVersions -> Int -> Int
addEntry (KnownVersions _ vs) count =
    count + 1 + List.length vs


allPkgsDecoder : D.Decoder () (Dict Pkg.Name KnownVersions)
allPkgsDecoder =
    let
        keyDecoder : D.KeyDecoder () Pkg.Name
        keyDecoder =
            Pkg.keyDecoder bail

        versionsDecoder : D.Decoder () (List V.Version)
        versionsDecoder =
            D.list (D.mapError (\_ -> ()) V.decoder)

        toKnownVersions : List V.Version -> D.Decoder () KnownVersions
        toKnownVersions versions =
            case List.sortWith (flip V.compare) versions of
                v :: vs ->
                    D.pure (KnownVersions v vs)

                [] ->
                    D.failure ()
    in
    D.stdDict keyDecoder (D.andThen toKnownVersions versionsDecoder)



-- ====== UPDATE ======


{-| Update an existing registry by fetching only new package versions since the last sync.
Returns the updated registry, or the original if no updates are available.
-}
update : Http.Manager -> Stuff.PackageCache -> Registry -> Task Never (Result Exit.RegistryProblem Registry)
update manager cache ((Registry size packages) as oldRegistry) =
    post manager ("/all-packages/since/" ++ String.fromInt size) (D.list newPkgDecoder) <|
        \news ->
            case news of
                [] ->
                    Task.succeed oldRegistry

                _ :: _ ->
                    let
                        newSize : Int
                        newSize =
                            size + List.length news

                        newPkgs : Dict Pkg.Name KnownVersions
                        newPkgs =
                            List.foldr addNew packages news

                        newRegistry : Registry
                        newRegistry =
                            Registry newSize newPkgs
                    in
                    File.writeBinary registryEncoder (Stuff.registry cache) newRegistry
                        |> Task.map (\_ -> newRegistry)


addNew : ( Pkg.Name, V.Version ) -> Dict Pkg.Name KnownVersions -> Dict Pkg.Name KnownVersions
addNew ( name, version ) versions =
    let
        add : Maybe KnownVersions -> KnownVersions
        add maybeKnowns =
            case maybeKnowns of
                Just (KnownVersions v vs) ->
                    KnownVersions version (v :: vs)

                Nothing ->
                    KnownVersions version []
    in
    Dict.update name (add >> Just) versions



-- ====== NEW PACKAGE DECODER ======


newPkgDecoder : D.Decoder () ( Pkg.Name, V.Version )
newPkgDecoder =
    D.customString newPkgParser bail


newPkgParser : P.Parser () ( Pkg.Name, V.Version )
newPkgParser =
    P.specialize (\_ _ _ -> ()) Pkg.parser
        |> P.andThen
            (\pkg ->
                P.word1 '@' bail
                    |> P.andThen (\_ -> P.specialize (\_ _ _ -> ()) V.parser)
                    |> P.map (\vsn -> ( pkg, vsn ))
            )


bail : a -> b -> ()
bail _ _ =
    ()



-- ====== LATEST ======


{-| Get the latest registry, either by reading the cache and updating it, or fetching it fresh.
This is the primary entry point for obtaining an up-to-date registry.
-}
latest : Http.Manager -> Stuff.PackageCache -> Task Never (Result Exit.RegistryProblem Registry)
latest manager cache =
    read cache
        |> Task.andThen
            (\maybeOldRegistry ->
                case maybeOldRegistry of
                    Just oldRegistry ->
                        update manager cache oldRegistry

                    Nothing ->
                        fetch manager cache
            )



-- ====== GET VERSIONS ======


{-| Look up available versions for a package name. Returns Nothing if the package isn't in the registry.
-}
getVersions : Pkg.Name -> Registry -> Maybe KnownVersions
getVersions name (Registry _ versions) =
    Dict.get name versions


{-| Look up available versions for a package name, providing suggested alternatives if not found.
Returns nearby package names (by edit distance) when the package doesn't exist.
-}
getVersions_ : Pkg.Name -> Registry -> Result (List Pkg.Name) KnownVersions
getVersions_ name (Registry _ versions) =
    case Dict.get name versions of
        Just kvs ->
            Ok kvs

        Nothing ->
            Err (Pkg.nearbyNames name (Dict.keys versions))



-- ====== POST ======


post : Http.Manager -> String -> D.Decoder x a -> (a -> Task Never b) -> Task Never (Result Exit.RegistryProblem b)
post manager path decoder callback =
    Website.route path []
        |> Task.andThen
            (\url ->
                Http.post manager url [] Exit.RP_Http <|
                    \body ->
                        case D.fromByteString decoder body of
                            Ok a ->
                                Task.map Ok (callback a)

                            Err _ ->
                                Exit.RP_Data url body |> Err |> Task.succeed
            )



-- ====== ENCODERS and DECODERS ======


{-| Binary decoder for reading a registry from disk cache.
-}
registryDecoder : Bytes.Decode.Decoder Registry
registryDecoder =
    Bytes.Decode.map2 Registry
        BD.int
        (BD.stdDict Pkg.nameDecoder knownVersionsDecoder)


{-| Binary encoder for writing a registry to disk cache.
-}
registryEncoder : Registry -> Bytes.Encode.Encoder
registryEncoder (Registry size versions) =
    Bytes.Encode.sequence
        [ BE.int size
        , BE.stdDict Pkg.nameEncoder knownVersionsEncoder versions
        ]


knownVersionsDecoder : Bytes.Decode.Decoder KnownVersions
knownVersionsDecoder =
    Bytes.Decode.map2 KnownVersions
        V.versionDecoder
        (BD.list V.versionDecoder)


knownVersionsEncoder : KnownVersions -> Bytes.Encode.Encoder
knownVersionsEncoder (KnownVersions version versions) =
    Bytes.Encode.sequence
        [ V.versionEncoder version
        , BE.list V.versionEncoder versions
        ]
