module Builder.Deps.Registry exposing
    ( Registry(..), KnownVersions(..)
    , read, fetch, update, latest
    , getVersions, getVersions_
    , registryDecoder, registryEncoder
    , RegistryPolicy(..)
    )

{-| Choosing package versions needs to know which versions of every package
exist, and this module keeps that list, the _registry_, on disk and up to date.

The registry is a map from each package name to its known versions, newest
first, together with a count of the (package, version) entries it holds. It is
cached as `registry.dat` in the package cache (`Builder.Stuff.registry`), and
refreshed from the package server that `Builder.Deps.Website` names.

The count is what makes refreshing cheap. The server's `/all-packages/since/<n>`
endpoint lists the entries published after the first `n`, so a cached registry
asks only for what it lacks and adds it. With no cache, `/all-packages` gives
the whole list instead.

A refresh is lazy. Under the `Normal` policy, a `registry.dat` modified less than
thirty minutes ago is used without asking the server, and a refresh that finds
nothing new touches the file, so the thirty minutes start again. `ForceRefresh`
always asks.

Every request prints a line saying how long it took to stdout.


# Registry Types

@docs Registry, KnownVersions


# Loading and Updating

@docs read, fetch, update, latest


# Querying Versions

@docs getVersions, getVersions_


# Serialization

@docs registryDecoder, registryEncoder


# Policy

@docs RegistryPolicy

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
import Eco.File
import System.IO as IO
import Task exposing (Task)
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== REGISTRY ======


{-| The known versions of every package, together with the number of (package,
version) entries the registry holds, which is the offset `update` asks the
server to continue from.

Nothing checks that the count matches the map; `fetch` computes it and `update`
adds the number of new entries to it.

-}
type Registry
    = Registry Int (Dict Pkg.Name KnownVersions)


{-| The versions of one package that the registry knows: the newest, then the
older ones.

`fetch` sorts each package's versions newest first. `update` puts each new
version in front of those already known, so the order holds only if the server
lists each package's new versions newest first, and they are all newer than
those already known.

-}
type KnownVersions
    = KnownVersions V.Version (List V.Version)


{-| Whether a refresh of a cached registry may be skipped because the cache is
recent.

Under `Normal`, a `registry.dat` whose modification time is less than thirty
minutes before now is used as it is, without asking the server.

Under `ForceRefresh`, the server is always asked.

-}
type RegistryPolicy
    = Normal
    | ForceRefresh


{-| How long, in milliseconds, a cached registry is used without asking the
server under the `Normal` policy: thirty minutes.
-}
registryTtlMs : Int
registryTtlMs =
    30 * 60 * 1000



-- ====== READ ======


{-| Reads the cached registry, giving `Nothing` when there is no
`registry.dat` or it cannot be read or decoded.
-}
read : Stuff.PackageCache -> Task Never (Maybe Registry)
read cache =
    File.readBinary registryDecoder (Stuff.registry cache)



-- ====== FETCH ======


{-| Downloads the whole registry from the package server, writes it to
`registry.dat`, and returns it.

A failed request gives `RP_Http`, and a response that does not decode gives
`RP_Data`; neither writes the file. A response listing a package with no
versions does not decode.

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


{-| Returns `count` increased by the number of versions in a package's known
versions.
-}
addEntry : KnownVersions -> Int -> Int
addEntry (KnownVersions _ vs) count =
    count + 1 + List.length vs


{-| A decoder for the server's whole package list: an object from package name
to a list of versions. Each package's versions are sorted newest first, and a
package with an empty list fails the whole decode.
-}
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


{-| Brings a cached registry up to date by asking the server for the entries
after the registry's count, and returns the result.

Under `Normal`, a `registry.dat` modified less than thirty minutes ago returns
the registry unchanged without asking. Otherwise the new entries are added and
the file rewritten; when there are none, the file is only touched, which resets
the thirty minutes.

A failed request or a response that does not decode gives a `RegistryProblem`
and leaves the file alone. A failure to read the file's modification time or to
touch it crashes the program instead.

-}
update : Http.Manager -> Stuff.PackageCache -> RegistryPolicy -> Registry -> Task Never (Result Exit.RegistryProblem Registry)
update manager cache policy ((Registry size packages) as oldRegistry) =
    let
        registryPath =
            Stuff.registry cache

        doFetch =
            post manager ("/all-packages/since/" ++ String.fromInt size) (D.list newPkgDecoder) <|
                \news ->
                    case news of
                        [] ->
                            (Eco.File.touch registryPath |> IO.crashOnError)
                                |> Task.map (\_ -> oldRegistry)

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
                            File.writeBinary registryEncoder registryPath newRegistry
                                |> Task.map (\_ -> newRegistry)
    in
    case policy of
        ForceRefresh ->
            doFetch

        Normal ->
            (Eco.File.modificationTime registryPath |> IO.crashOnError)
                |> Task.andThen
                    (\mtime ->
                        Time.now
                            |> Task.andThen
                                (\now ->
                                    if Time.posixToMillis now - Time.posixToMillis mtime < registryTtlMs then
                                        Task.succeed (Ok oldRegistry)

                                    else
                                        doFetch
                                )
                    )


{-| Puts `version` in front of the known versions of `name`, adding the
package when it is not yet known.
-}
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


{-| A decoder for one entry of the server's list of new entries, a string of the
form `author/project@version`.
-}
newPkgDecoder : D.Decoder () ( Pkg.Name, V.Version )
newPkgDecoder =
    D.customString newPkgParser bail


{-| A parser for a package name, an `@`, and a version.
-}
newPkgParser : P.Parser () ( Pkg.Name, V.Version )
newPkgParser =
    P.specialize (\_ _ _ -> ()) Pkg.parser
        |> P.andThen
            (\pkg ->
                P.word1 '@' bail
                    |> P.andThen (\_ -> P.specialize (\_ _ _ -> ()) V.parser)
                    |> P.map (\vsn -> ( pkg, vsn ))
            )


{-| Returns the unit error, whatever position it is given; the decoders here
keep no detail of what failed.
-}
bail : a -> b -> ()
bail _ _ =
    ()



-- ====== LATEST ======


{-| Returns an up-to-date registry: the cached one brought up to date by
`update` under `policy`, or, when there is no usable cache, a whole one from
`fetch`.

A failed refresh is an error here, even when a cached registry exists.

-}
latest : Http.Manager -> Stuff.PackageCache -> RegistryPolicy -> Task Never (Result Exit.RegistryProblem Registry)
latest manager cache policy =
    read cache
        |> Task.andThen
            (\maybeOldRegistry ->
                case maybeOldRegistry of
                    Just oldRegistry ->
                        update manager cache policy oldRegistry

                    Nothing ->
                        fetch manager cache
            )



-- ====== GET VERSIONS ======


{-| Returns the known versions of `name`, or `Nothing` when the registry does
not list it.
-}
getVersions : Pkg.Name -> Registry -> Maybe KnownVersions
getVersions name (Registry _ versions) =
    Dict.get name versions


{-| Returns the known versions of `name`, or, when the registry does not list
it, the registry's names closest to it as `Compiler.Elm.Package.nearbyNames`
chooses them.
-}
getVersions_ : Pkg.Name -> Registry -> Result (List Pkg.Name) KnownVersions
getVersions_ name (Registry _ versions) =
    case Dict.get name versions of
        Just kvs ->
            Ok kvs

        Nothing ->
            Err (Pkg.nearbyNames name (Dict.keys versions))



-- ====== POST ======


{-| Sends a POST with no body to `path` on the package server, decodes the
response with `decoder`, and runs `callback` on the result.

A failed request gives `RP_Http`, and a response `decoder` rejects gives
`RP_Data` with the URL and the body. Whatever the outcome, a line with the URL
and the time taken, which includes `callback`, is then printed to stdout.

-}
post : Http.Manager -> String -> D.Decoder x a -> (a -> Task Never b) -> Task Never (Result Exit.RegistryProblem b)
post manager path decoder callback =
    Website.route path []
        |> Task.andThen
            (\url ->
                Time.now
                    |> Task.andThen
                        (\before ->
                            Http.post manager
                                url
                                []
                                Exit.RP_Http
                                (\body ->
                                    case D.fromByteString decoder body of
                                        Ok a ->
                                            Task.map Ok (callback a)

                                        Err _ ->
                                            Exit.RP_Data url body |> Err |> Task.succeed
                                )
                                |> Task.andThen
                                    (\result ->
                                        Time.now
                                            |> Task.andThen
                                                (\after ->
                                                    let
                                                        ms =
                                                            Time.posixToMillis after - Time.posixToMillis before
                                                    in
                                                    IO.print
                                                        ("Registry: POST " ++ url ++ " completed in " ++ String.fromInt ms ++ "ms\n")
                                                        |> Task.map (\_ -> result)
                                                )
                                    )
                        )
            )



-- ====== ENCODERS and DECODERS ======


{-| A decoder for the registry as `registryEncoder` writes it to
`registry.dat`.
-}
registryDecoder : Bytes.Decode.Decoder Registry
registryDecoder =
    Bytes.Decode.map2 Registry
        BD.int
        (BD.stdDict Pkg.nameDecoder knownVersionsDecoder)


{-| Produces the binary encoding of a registry that `registry.dat` holds.
-}
registryEncoder : Registry -> Bytes.Encode.Encoder
registryEncoder (Registry size versions) =
    Bytes.Encode.sequence
        [ BE.int size
        , BE.stdDict Pkg.nameEncoder knownVersionsEncoder versions
        ]


{-| A decoder for one package's known versions as `knownVersionsEncoder`
writes them.
-}
knownVersionsDecoder : Bytes.Decode.Decoder KnownVersions
knownVersionsDecoder =
    Bytes.Decode.map2 KnownVersions
        V.versionDecoder
        (BD.list V.versionDecoder)


{-| Produces the binary encoding of one package's known versions: the newest,
then the list of older ones.
-}
knownVersionsEncoder : KnownVersions -> Bytes.Encode.Encoder
knownVersionsEncoder (KnownVersions version versions) =
    Bytes.Encode.sequence
        [ V.versionEncoder version
        , BE.list V.versionEncoder versions
        ]
