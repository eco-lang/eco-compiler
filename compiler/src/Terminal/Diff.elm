module Terminal.Diff exposing
    ( Args(..)
    , run
    )

import Basics.Extra exposing (flip)
import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Diff as DD exposing (Changes(..), ModuleChanges(..), PackageChanges(..))
import Builder.Deps.Registry as Registry
import Builder.Elm.Details as Details exposing (Details(..))
import Builder.Elm.Outline as Outline
import Builder.Http as Http
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Builder.Stuff as Stuff
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Compiler.Type as Type
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Magnitude as M
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Type as Type
import Compiler.Reporting.Render.Type.Localizer as L
import Data.Map as Dict
import Task exposing (Task)
import Utils.Task.Extra as Task



-- RUN


type Args
    = CodeVsLatest
    | CodeVsExactly V.Version
    | LocalInquiry V.Version V.Version
    | GlobalInquiry Pkg.Name V.Version V.Version


run : Args -> () -> Task Never ()
run args () =
    Reporting.attempt Exit.diffToReport
        (Task.run
            (getEnv
                |> Task.andThen (\env -> diff env args)
            )
        )



-- ENVIRONMENT


type Env
    = Env EnvProps


type alias EnvProps =
    { maybeRoot : Maybe String
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , registry : Registry.Registry
    }


makeEnv : Maybe String -> Stuff.PackageCache -> Http.Manager -> Registry.Registry -> Env
makeEnv maybeRoot cache manager registry =
    Env { maybeRoot = maybeRoot, cache = cache, manager = manager, registry = registry }


type alias EnvSetup =
    { maybeRoot : Maybe String
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    }


getEnv : Task Exit.Diff Env
getEnv =
    Task.io Stuff.findRoot
        |> Task.andThen addPackageCache
        |> Task.andThen addHttpManager
        |> Task.andThen addRegistry


addPackageCache : Maybe String -> Task Exit.Diff ( Maybe String, Stuff.PackageCache )
addPackageCache maybeRoot =
    Task.io Stuff.getPackageCache
        |> Task.map (\cache -> ( maybeRoot, cache ))


addHttpManager : ( Maybe String, Stuff.PackageCache ) -> Task Exit.Diff EnvSetup
addHttpManager ( maybeRoot, cache ) =
    Task.io Http.getManager
        |> Task.map (\manager -> EnvSetup maybeRoot cache manager)


addRegistry : EnvSetup -> Task Exit.Diff Env
addRegistry setup =
    Task.eio Exit.DiffMustHaveLatestRegistry (Registry.latest setup.manager setup.cache)
        |> Task.map (\registry -> makeEnv setup.maybeRoot setup.cache setup.manager registry)



-- DIFF


diff : Env -> Args -> Task Exit.Diff ()
diff ((Env props) as env) args =
    case args of
        GlobalInquiry name v1 v2 ->
            diffGlobalInquiry env props.registry name v1 v2

        LocalInquiry v1 v2 ->
            diffLocalInquiry env v1 v2

        CodeVsLatest ->
            diffCodeVsLatest env

        CodeVsExactly version ->
            diffCodeVsExactly env version


diffGlobalInquiry : Env -> Registry.Registry -> Pkg.Name -> V.Version -> V.Version -> Task Exit.Diff ()
diffGlobalInquiry env registry name v1 v2 =
    case Registry.getVersions_ name registry of
        Ok vsns ->
            getDocs env name vsns (V.min v1 v2)
                |> Task.andThen (fetchNewDocsAndWrite env name vsns (V.max v1 v2))

        Err suggestions ->
            Task.throw (Exit.DiffUnknownPackage name suggestions)


diffLocalInquiry : Env -> V.Version -> V.Version -> Task Exit.Diff ()
diffLocalInquiry env v1 v2 =
    readOutline env
        |> Task.andThen (diffVersions env (V.min v1 v2) (V.max v1 v2))


diffCodeVsLatest : Env -> Task Exit.Diff ()
diffCodeVsLatest env =
    readOutline env
        |> Task.andThen (diffLatestVsGenerated env)


diffCodeVsExactly : Env -> V.Version -> Task Exit.Diff ()
diffCodeVsExactly env version =
    readOutline env
        |> Task.andThen (diffVersionVsGenerated env version)


diffVersions : Env -> V.Version -> V.Version -> ( Pkg.Name, Registry.KnownVersions ) -> Task Exit.Diff ()
diffVersions env oldVersion newVersion ( name, vsns ) =
    getDocs env name vsns oldVersion
        |> Task.andThen (fetchNewDocsAndWrite env name vsns newVersion)


diffLatestVsGenerated : Env -> ( Pkg.Name, Registry.KnownVersions ) -> Task Exit.Diff ()
diffLatestVsGenerated env ( name, vsns ) =
    getLatestDocs env name vsns
        |> Task.andThen (fetchGeneratedDocsAndWrite env)


diffVersionVsGenerated : Env -> V.Version -> ( Pkg.Name, Registry.KnownVersions ) -> Task Exit.Diff ()
diffVersionVsGenerated env version ( name, vsns ) =
    getDocs env name vsns version
        |> Task.andThen (fetchGeneratedDocsAndWrite env)


fetchNewDocsAndWrite : Env -> Pkg.Name -> Registry.KnownVersions -> V.Version -> Docs.Documentation -> Task Exit.Diff ()
fetchNewDocsAndWrite env name vsns newVersion oldDocs =
    getDocs env name vsns newVersion
        |> Task.andThen (writeDiff oldDocs)


fetchGeneratedDocsAndWrite : Env -> Docs.Documentation -> Task Exit.Diff ()
fetchGeneratedDocsAndWrite env oldDocs =
    generateDocs env
        |> Task.andThen (writeDiff oldDocs)



-- GET DOCS


getDocs : Env -> Pkg.Name -> Registry.KnownVersions -> V.Version -> Task Exit.Diff Docs.Documentation
getDocs (Env props) name (Registry.KnownVersions latest previous) version =
    if latest == version || List.member version previous then
        Task.eio (Exit.DiffDocsProblem version) <| DD.getDocs props.cache props.manager name version

    else
        Task.throw <| Exit.DiffUnknownVersion version (latest :: previous)


getLatestDocs : Env -> Pkg.Name -> Registry.KnownVersions -> Task Exit.Diff Docs.Documentation
getLatestDocs (Env props) name (Registry.KnownVersions latest _) =
    Task.eio (Exit.DiffDocsProblem latest) <| DD.getDocs props.cache props.manager name latest



-- READ OUTLINE


readOutline : Env -> Task Exit.Diff ( Pkg.Name, Registry.KnownVersions )
readOutline (Env props) =
    case props.maybeRoot of
        Nothing ->
            Task.throw Exit.DiffNoOutline

        Just root ->
            Task.io (Outline.read root)
                |> Task.andThen (validateOutlineResult props.registry)


validateOutlineResult : Registry.Registry -> Result Exit.Outline Outline.Outline -> Task Exit.Diff ( Pkg.Name, Registry.KnownVersions )
validateOutlineResult registry result =
    case result of
        Err err ->
            Task.throw (Exit.DiffBadOutline err)

        Ok outline ->
            validateOutline registry outline


validateOutline : Registry.Registry -> Outline.Outline -> Task Exit.Diff ( Pkg.Name, Registry.KnownVersions )
validateOutline registry outline =
    case outline of
        Outline.App _ ->
            Task.throw Exit.DiffApplication

        Outline.Pkg (Outline.PkgOutline pkgData) ->
            case Registry.getVersions pkgData.name registry of
                Just vsns ->
                    Task.succeed ( pkgData.name, vsns )

                Nothing ->
                    Task.throw Exit.DiffUnpublished



-- GENERATE DOCS


generateDocs : Env -> Task Exit.Diff Docs.Documentation
generateDocs (Env props) =
    case props.maybeRoot of
        Nothing ->
            Task.throw Exit.DiffNoOutline

        Just root ->
            Task.eio Exit.DiffBadDetails (BW.withScope (\scope -> Details.load Reporting.silent scope root))
                |> Task.andThen (buildDocsFromDetails root)


buildDocsFromDetails : String -> Details -> Task Exit.Diff Docs.Documentation
buildDocsFromDetails root ((Details detailsData) as details) =
    case detailsData.outline of
        Details.ValidApp _ ->
            Task.throw Exit.DiffApplication

        Details.ValidPkg _ exposed _ ->
            buildDocsFromExposed root details exposed


buildDocsFromExposed : String -> Details -> List Name.Name -> Task Exit.Diff Docs.Documentation
buildDocsFromExposed root details exposed =
    case exposed of
        [] ->
            Task.throw Exit.DiffNoExposed

        e :: es ->
            Task.eio Exit.DiffBadBuild <|
                Build.fromExposed Docs.bytesDecoder Docs.bytesEncoder Reporting.silent root details Build.keepDocs (NE.Nonempty e es)



-- WRITE DIFF


writeDiff : Docs.Documentation -> Docs.Documentation -> Task Exit.Diff ()
writeDiff oldDocs newDocs =
    let
        changes : PackageChanges
        changes =
            DD.diff oldDocs newDocs

        localizer : L.Localizer
        localizer =
            L.fromNames (Dict.union oldDocs newDocs)
    in
    Task.io (Help.toStdout (toDoc localizer changes |> D.a (D.fromChars "\n")))



-- TO DOC


toDoc : L.Localizer -> PackageChanges -> D.Doc
toDoc localizer ((PackageChanges added changed removed) as changes) =
    if List.isEmpty added && Dict.isEmpty changed && List.isEmpty removed then
        D.fromChars "No API changes detected, so this is a"
            |> D.plus (D.green (D.fromChars "PATCH"))
            |> D.plus (D.fromChars "change.")

    else
        let
            magDoc : D.Doc
            magDoc =
                D.fromChars (M.toChars (DD.toMagnitude changes))

            header : D.Doc
            header =
                D.fromChars "This is a"
                    |> D.plus (D.green magDoc)
                    |> D.plus (D.fromChars "change.")

            addedChunk : List Chunk
            addedChunk =
                if List.isEmpty added then
                    []

                else
                    [ Chunk "ADDED MODULES" M.MINOR <|
                        D.vcat <|
                            List.map D.fromName added
                    ]

            removedChunk : List Chunk
            removedChunk =
                if List.isEmpty removed then
                    []

                else
                    [ Chunk "REMOVED MODULES" M.MAJOR <|
                        D.vcat <|
                            List.map D.fromName removed
                    ]

            chunks : List Chunk
            chunks =
                addedChunk ++ removedChunk ++ List.map (changesToChunk localizer) (Dict.toList compare changed)
        in
        D.vcat (header :: D.fromChars "" :: List.map chunkToDoc chunks)


type Chunk
    = Chunk String M.Magnitude D.Doc


chunkToDoc : Chunk -> D.Doc
chunkToDoc (Chunk title magnitude details) =
    let
        header : D.Doc
        header =
            D.fromChars "----"
                |> D.plus (D.fromChars title)
                |> D.plus (D.fromChars "-")
                |> D.plus (D.fromChars (M.toChars magnitude))
                |> D.plus (D.fromChars "----")
    in
    D.vcat
        [ D.dullcyan header
        , D.fromChars ""
        , D.indent 4 details
        , D.fromChars ""
        , D.fromChars ""
        ]


changesToChunk : L.Localizer -> ( Name.Name, ModuleChanges ) -> Chunk
changesToChunk localizer ( name, (ModuleChanges changesData) as changes ) =
    let
        magnitude : M.Magnitude
        magnitude =
            DD.moduleChangeMagnitude changes

        ( unionAdd, unionChange, unionRemove ) =
            changesToDocTriple compare (unionToDoc localizer) changesData.unions

        ( aliasAdd, aliasChange, aliasRemove ) =
            changesToDocTriple compare (aliasToDoc localizer) changesData.aliases

        ( valueAdd, valueChange, valueRemove ) =
            changesToDocTriple compare (valueToDoc localizer) changesData.values

        ( binopAdd, binopChange, binopRemove ) =
            changesToDocTriple compare (binopToDoc localizer) changesData.binops
    in
    Chunk name magnitude <|
        D.vcat <|
            List.intersperse (D.fromChars "") <|
                List.filterMap identity <|
                    [ changesToDoc "Added" unionAdd aliasAdd valueAdd binopAdd
                    , changesToDoc "Removed" unionRemove aliasRemove valueRemove binopRemove
                    , changesToDoc "Changed" unionChange aliasChange valueChange binopChange
                    ]


changesToDocTriple : (k -> k -> Order) -> (k -> v -> D.Doc) -> Changes comparable k v -> ( List D.Doc, List D.Doc, List D.Doc )
changesToDocTriple keyComparison entryToDoc (Changes added changed removed) =
    let
        indented : ( k, v ) -> D.Doc
        indented ( name, value ) =
            D.indent 4 (entryToDoc name value)

        diffed : ( k, ( v, v ) ) -> D.Doc
        diffed ( name, ( oldValue, newValue ) ) =
            D.vcat
                [ D.fromChars "  - " |> D.a (entryToDoc name oldValue)
                , D.fromChars "  + " |> D.a (entryToDoc name newValue)
                , D.fromChars ""
                ]
    in
    ( List.map indented (Dict.toList keyComparison added)
    , List.map diffed (Dict.toList keyComparison changed)
    , List.map indented (Dict.toList keyComparison removed)
    )


changesToDoc : String -> List D.Doc -> List D.Doc -> List D.Doc -> List D.Doc -> Maybe D.Doc
changesToDoc categoryName unions aliases values binops =
    if List.isEmpty unions && List.isEmpty aliases && List.isEmpty values && List.isEmpty binops then
        Nothing

    else
        Just <|
            D.vcat <|
                D.append (D.fromChars categoryName) (D.fromChars ":")
                    :: unions
                    ++ aliases
                    ++ binops
                    ++ values


unionToDoc : L.Localizer -> Name.Name -> Docs.Union -> D.Doc
unionToDoc localizer name (Docs.Union _ tvars ctors) =
    let
        setup : D.Doc
        setup =
            D.fromChars "type"
                |> D.plus (D.fromName name)
                |> D.plus (D.hsep (List.map D.fromName tvars))

        ctorDoc : ( Name.Name, List Type.Type ) -> D.Doc
        ctorDoc ( ctor, tipes ) =
            typeDoc localizer (Type.Type ctor tipes)
    in
    D.hang 4
        (D.sep
            (setup
                :: List.map2 (flip D.plus)
                    (D.fromChars "=" :: List.repeat (List.length ctors - 1) (D.fromChars "|"))
                    (List.map ctorDoc ctors)
            )
        )


aliasToDoc : L.Localizer -> Name.Name -> Docs.Alias -> D.Doc
aliasToDoc localizer name (Docs.Alias _ tvars tipe) =
    let
        declaration : D.Doc
        declaration =
            D.plus (D.fromChars "type")
                (D.plus (D.fromChars "alias")
                    (D.plus (D.hsep (List.map D.fromName (name :: tvars)))
                        (D.fromChars "=")
                    )
                )
    in
    D.hang 4 (D.sep [ declaration, typeDoc localizer tipe ])


valueToDoc : L.Localizer -> Name.Name -> Docs.Value -> D.Doc
valueToDoc localizer name (Docs.Value _ tipe) =
    D.hang 4 <| D.sep [ D.fromName name |> D.plus (D.fromChars ":"), typeDoc localizer tipe ]


binopToDoc : L.Localizer -> Name.Name -> Docs.Binop -> D.Doc
binopToDoc localizer name (Docs.Binop data) =
    let
        details : D.Doc
        details =
            D.plus (D.fromChars "    (")
                (D.plus (D.fromName assoc)
                    (D.plus (D.fromChars "/")
                        (D.plus (D.fromInt data.precedence)
                            (D.fromChars ")")
                        )
                    )
                )

        assoc : String
        assoc =
            case data.associativity of
                Binop.Left ->
                    "left"

                Binop.Non ->
                    "non"

                Binop.Right ->
                    "right"
    in
    D.plus (D.fromChars "(")
        (D.plus (D.fromName name)
            (D.plus (D.fromChars ")")
                (D.plus (D.fromChars ":")
                    (D.plus (typeDoc localizer data.tipe)
                        (D.black details)
                    )
                )
            )
        )


typeDoc : L.Localizer -> Type.Type -> D.Doc
typeDoc localizer tipe =
    Type.toDoc localizer Type.None tipe
