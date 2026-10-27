module Terminal.Diff exposing
    ( run
    , Args(..)
    )

{-| A package's version number must say how far its public API moved, and the
`diff` command shows what moved: it prints the API changes between two versions
of a package, or between a published version and the package's local code.

The comparison itself, and the _magnitude_ it reduces to (MAJOR, MINOR or
PATCH), belong to `Builder.Deps.Diff`. The API of a published version is its
documentation, fetched by `Builder.Deps.Diff.getDocs`; the API of the local code
is documentation built from the package's exposed modules. This module chooses
the two sets of documentation from `Args`, compares them, and renders the result
to standard output.

The work is in three parts. An environment is set up first: the project root, if
there is one, the package cache, an HTTP manager, and a registry of published
versions that is always refreshed from the package server, so the command fails
when the refresh fails. The two sets of documentation are then obtained, older
first: for two published versions the lower is always the old one, whatever
order they were given in. Finally the changes are printed: a headline with the
magnitude, then a section for the added modules, one for the removed modules, and
one for each changed module listing its added, removed and changed declarations.

@docs run

@docs Args

-}

import Basics.Extra exposing (flip)
import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Diff as DD exposing (Changes(..), ModuleChanges(..), PackageChanges(..))
import Builder.Deps.Registry as Registry
import Builder.Eco.FEStats as FEStats
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
import Dict
import Task exposing (Task)
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| What the `diff` command compares.

`CodeVsLatest` compares the latest published version of the local package with
its code, and `CodeVsExactly` compares the given published version with the code.
`LocalInquiry` compares two published versions of the local package, and
`GlobalInquiry` two published versions of the named package, which need not be
the local one and needs no project. In both of the last two the lower version is
treated as the old one, whatever the order of the two.

The local forms need a project whose `elm.json` describes a package that the
registry lists.

-}
type Args
    = CodeVsLatest
    | CodeVsExactly V.Version
    | LocalInquiry V.Version V.Version
    | GlobalInquiry Pkg.Name V.Version V.Version


{-| Runs the `diff` command for `args`, printing the changes to standard output,
or reporting the reason it could not, as an error report.
-}
run : Args -> () -> Task Never ()
run args () =
    Reporting.attempt Exit.diffToReport
        (Task.run
            (getEnv
                |> Task.andThen (\env -> diff env args)
            )
        )



-- ====== ENVIRONMENT ======


{-| The things every comparison needs: the project root, if the command was run
inside a project, the package cache, an HTTP manager, and the registry of
published versions.
-}
type Env
    = Env EnvProps


{-| The contents of an `Env`. `maybeRoot` is `Nothing` outside a project.
-}
type alias EnvProps =
    { maybeRoot : Maybe String
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    , registry : Registry.Registry
    }


{-| Creates an `Env` from its four parts.
-}
makeEnv : Maybe String -> Stuff.PackageCache -> Http.Manager -> Registry.Registry -> Env
makeEnv maybeRoot cache manager registry =
    Env { maybeRoot = maybeRoot, cache = cache, manager = manager, registry = registry }


{-| An `Env` without its registry, while the environment is being set up.
-}
type alias EnvSetup =
    { maybeRoot : Maybe String
    , cache : Stuff.PackageCache
    , manager : Http.Manager
    }


{-| Sets up the environment: finds the project root, the package cache and an
HTTP manager, then fetches a registry refreshed from the package server. A
failed refresh fails the command, even when a cached registry exists.
-}
getEnv : Task Exit.Diff Env
getEnv =
    Task.io Stuff.findRoot
        |> Task.andThen addPackageCache
        |> Task.andThen addHttpManager
        |> Task.andThen addRegistry


{-| Pairs `maybeRoot` with the package cache.
-}
addPackageCache : Maybe String -> Task Exit.Diff ( Maybe String, Stuff.PackageCache )
addPackageCache maybeRoot =
    Task.io (Stuff.resolveBundledPackages [] |> Task.andThen Stuff.getPackageCache)
        |> Task.map (\cache -> ( maybeRoot, cache ))


{-| Adds an HTTP manager to the root and the package cache.
-}
addHttpManager : ( Maybe String, Stuff.PackageCache ) -> Task Exit.Diff EnvSetup
addHttpManager ( maybeRoot, cache ) =
    Task.io Http.getManager
        |> Task.map (\manager -> EnvSetup maybeRoot cache manager)


{-| Completes `setup` with a registry that is always refreshed from the package
server (`Registry.ForceRefresh`), failing with `DiffMustHaveLatestRegistry` when
the refresh fails.
-}
addRegistry : EnvSetup -> Task Exit.Diff Env
addRegistry setup =
    Task.eio Exit.DiffMustHaveLatestRegistry (Registry.latest setup.manager setup.cache Registry.ForceRefresh)
        |> Task.map (\registry -> makeEnv setup.maybeRoot setup.cache setup.manager registry)



-- ====== DIFF ======


{-| Runs the comparison that `args` asks for in `env`.
-}
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


{-| Prints the changes between versions `v1` and `v2` of package `name`, taking
the lower as the old one. Fails with `DiffUnknownPackage`, carrying nearby
names, when the registry does not list `name`.
-}
diffGlobalInquiry : Env -> Registry.Registry -> Pkg.Name -> V.Version -> V.Version -> Task Exit.Diff ()
diffGlobalInquiry env registry name v1 v2 =
    case Registry.getVersions_ name registry of
        Ok vsns ->
            getDocs env name vsns (V.min v1 v2)
                |> Task.andThen (fetchNewDocsAndWrite env name vsns (V.max v1 v2))

        Err suggestions ->
            Task.throw (Exit.DiffUnknownPackage name suggestions)


{-| Prints the changes between versions `v1` and `v2` of the local package,
taking the lower as the old one.
-}
diffLocalInquiry : Env -> V.Version -> V.Version -> Task Exit.Diff ()
diffLocalInquiry env v1 v2 =
    readOutline env
        |> Task.andThen (diffVersions env (V.min v1 v2) (V.max v1 v2))


{-| Prints the changes from the latest published version of the local package
to its code.
-}
diffCodeVsLatest : Env -> Task Exit.Diff ()
diffCodeVsLatest env =
    readOutline env
        |> Task.andThen (diffLatestVsGenerated env)


{-| Prints the changes from published version `version` of the local package to
its code.
-}
diffCodeVsExactly : Env -> V.Version -> Task Exit.Diff ()
diffCodeVsExactly env version =
    readOutline env
        |> Task.andThen (diffVersionVsGenerated env version)


{-| Prints the changes from `oldVersion` to `newVersion` of package `name`.
-}
diffVersions : Env -> V.Version -> V.Version -> ( Pkg.Name, Registry.KnownVersions ) -> Task Exit.Diff ()
diffVersions env oldVersion newVersion ( name, vsns ) =
    getDocs env name vsns oldVersion
        |> Task.andThen (fetchNewDocsAndWrite env name vsns newVersion)


{-| Prints the changes from the latest published version of package `name` to
the local code.
-}
diffLatestVsGenerated : Env -> ( Pkg.Name, Registry.KnownVersions ) -> Task Exit.Diff ()
diffLatestVsGenerated env ( name, vsns ) =
    getLatestDocs env name vsns
        |> Task.andThen (fetchGeneratedDocsAndWrite env)


{-| Prints the changes from published version `version` of package `name` to the
local code.
-}
diffVersionVsGenerated : Env -> V.Version -> ( Pkg.Name, Registry.KnownVersions ) -> Task Exit.Diff ()
diffVersionVsGenerated env version ( name, vsns ) =
    getDocs env name vsns version
        |> Task.andThen (fetchGeneratedDocsAndWrite env)


{-| Fetches the documentation of `newVersion` and prints the changes to it from
`oldDocs`.
-}
fetchNewDocsAndWrite : Env -> Pkg.Name -> Registry.KnownVersions -> V.Version -> Docs.Documentation -> Task Exit.Diff ()
fetchNewDocsAndWrite env name vsns newVersion oldDocs =
    getDocs env name vsns newVersion
        |> Task.andThen (writeDiff oldDocs)


{-| Builds the documentation of the local code and prints the changes to it
from `oldDocs`.
-}
fetchGeneratedDocsAndWrite : Env -> Docs.Documentation -> Task Exit.Diff ()
fetchGeneratedDocsAndWrite env oldDocs =
    generateDocs env
        |> Task.andThen (writeDiff oldDocs)



-- ====== GET DOCS ======


{-| Returns the documentation of `version` of package `name`, by way of
`Builder.Deps.Diff.getDocs`. A version the registry does not list for `name`
fails with `DiffUnknownVersion`, carrying the listed versions, before anything
is fetched.
-}
getDocs : Env -> Pkg.Name -> Registry.KnownVersions -> V.Version -> Task Exit.Diff Docs.Documentation
getDocs (Env props) name (Registry.KnownVersions latest previous) version =
    if latest == version || List.member version previous then
        DD.getDocs props.cache props.manager name version |> Task.eio (Exit.DiffDocsProblem version)

    else
        Exit.DiffUnknownVersion version (latest :: previous) |> Task.throw


{-| Returns the documentation of the latest version of package `name` that the
registry lists.
-}
getLatestDocs : Env -> Pkg.Name -> Registry.KnownVersions -> Task Exit.Diff Docs.Documentation
getLatestDocs (Env props) name (Registry.KnownVersions latest _) =
    DD.getDocs props.cache props.manager name latest |> Task.eio (Exit.DiffDocsProblem latest)



-- ====== READ OUTLINE ======


{-| Returns the name and the published versions of the local package. Fails
with `DiffNoOutline` outside a project.
-}
readOutline : Env -> Task Exit.Diff ( Pkg.Name, Registry.KnownVersions )
readOutline (Env props) =
    case props.maybeRoot of
        Nothing ->
            Task.throw Exit.DiffNoOutline

        Just root ->
            Task.io (Outline.read root)
                |> Task.andThen (validateOutlineResult props.registry)


{-| Returns the name and the published versions of the package that `result`
describes, or fails with `DiffBadOutline` when `elm.json` could not be read.
-}
validateOutlineResult : Registry.Registry -> Result Exit.Outline Outline.Outline -> Task Exit.Diff ( Pkg.Name, Registry.KnownVersions )
validateOutlineResult registry result =
    case result of
        Err err ->
            Task.throw (Exit.DiffBadOutline err)

        Ok outline ->
            validateOutline registry outline


{-| Returns the name and the published versions of the package `outline`
describes. Fails with `DiffApplication` for an application and with
`DiffUnpublished` for a package the registry does not list.
-}
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



-- ====== GENERATE DOCS ======


{-| Builds the documentation of the local package's exposed modules. Fails with
`DiffNoOutline` outside a project and with `DiffBadDetails` when the project's
details cannot be loaded.
-}
generateDocs : Env -> Task Exit.Diff Docs.Documentation
generateDocs (Env props) =
    case props.maybeRoot of
        Nothing ->
            Task.throw Exit.DiffNoOutline

        Just root ->
            Task.eio Exit.DiffBadDetails (BW.withScope (\scope -> Stuff.resolveBundledPackages [] |> Task.andThen (\locals -> Details.load Reporting.silent scope root Nothing Nothing False False locals Registry.Normal)))
                |> Task.andThen (buildDocsFromDetails root)


{-| Builds the documentation of the exposed modules that `details` lists for a
package, failing with `DiffApplication` for an application.
-}
buildDocsFromDetails : String -> Details -> Task Exit.Diff Docs.Documentation
buildDocsFromDetails root ((Details detailsData) as details) =
    case detailsData.outline of
        Details.ValidApp _ ->
            Task.throw Exit.DiffApplication

        Details.ValidPkg _ exposed _ ->
            buildDocsFromExposed root details exposed


{-| Compiles the project at `root` from the modules in `exposed` and returns
their documentation. Fails with `DiffNoExposed` when `exposed` is empty and with
`DiffBadBuild` when the build fails.
-}
buildDocsFromExposed : String -> Details -> List Name.Name -> Task Exit.Diff Docs.Documentation
buildDocsFromExposed root details exposed =
    case exposed of
        [] ->
            Task.throw Exit.DiffNoExposed

        e :: es ->
            Build.fromExposed Reporting.silent root Nothing Nothing details Build.keepDocs FEStats.disabled (NE.Nonempty e es) |> Task.eio Exit.DiffBadBuild



-- ====== WRITE DIFF ======


{-| Prints the changes from `oldDocs` to `newDocs` to standard output.

Types from any module of either version are printed without their module's
name; types from other modules are printed with it.

-}
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



-- ====== TO DOC ======


{-| Renders `changes` as a headline giving their magnitude, followed by a
section for the added modules, one for the removed modules, and one for each
changed module. With no changes at all, it renders only a line saying the change
is a PATCH.
-}
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
                    [ List.map D.fromName added |> D.vcat |> Chunk "ADDED MODULES" M.MINOR
                    ]

            removedChunk : List Chunk
            removedChunk =
                if List.isEmpty removed then
                    []

                else
                    [ List.map D.fromName removed |> D.vcat |> Chunk "REMOVED MODULES" M.MAJOR
                    ]

            chunks : List Chunk
            chunks =
                addedChunk ++ removedChunk ++ List.map (changesToChunk localizer) (Dict.toList changed)
        in
        D.vcat (header :: D.fromChars "" :: List.map chunkToDoc chunks)


{-| One section of the printed changes: its title, the magnitude shown beside
the title, and its body.
-}
type Chunk
    = Chunk String M.Magnitude D.Doc


{-| Renders a section as a banner holding its title and magnitude, then its
body indented by four, then two blank lines.
-}
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


{-| Builds the section for module `name`: its magnitude, and an "Added", a
"Removed" and a "Changed" block, in that order, leaving out any that would be
empty. Within each block, unions come first, then aliases, then operators, then
values.
-}
changesToChunk : L.Localizer -> ( Name.Name, ModuleChanges ) -> Chunk
changesToChunk localizer ( name, (ModuleChanges changesData) as changes ) =
    let
        magnitude : M.Magnitude
        magnitude =
            DD.moduleChangeMagnitude changes

        ( unionAdd, unionChange, unionRemove ) =
            changesToDocTriple (unionToDoc localizer) changesData.unions

        ( aliasAdd, aliasChange, aliasRemove ) =
            changesToDocTriple (aliasToDoc localizer) changesData.aliases

        ( valueAdd, valueChange, valueRemove ) =
            changesToDocTriple (valueToDoc localizer) changesData.values

        ( binopAdd, binopChange, binopRemove ) =
            changesToDocTriple (binopToDoc localizer) changesData.binops
    in
    [ changesToDoc "Added" unionAdd aliasAdd valueAdd binopAdd
    , changesToDoc "Removed" unionRemove aliasRemove valueRemove binopRemove
    , changesToDoc "Changed" unionChange aliasChange valueChange binopChange
    ]
        |> List.filterMap identity
        |> List.intersperse (D.fromChars "")
        |> D.vcat
        |> Chunk name magnitude


{-| Renders the added, the changed and the removed entries of one kind of
declaration with `entryToDoc`, in that order. An added or removed entry is
indented by four; a changed one is its old form after a `-` and its new form
after a `+`, then a blank line.
-}
changesToDocTriple : (k -> v -> D.Doc) -> Changes k v -> ( List D.Doc, List D.Doc, List D.Doc )
changesToDocTriple entryToDoc (Changes added changed removed) =
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
    ( List.map indented (Dict.toList added)
    , List.map diffed (Dict.toList changed)
    , List.map indented (Dict.toList removed)
    )


{-| Renders one block headed by `categoryName`, or `Nothing` when all four lists
are empty.
-}
changesToDoc : String -> List D.Doc -> List D.Doc -> List D.Doc -> List D.Doc -> Maybe D.Doc
changesToDoc categoryName unions aliases values binops =
    if List.isEmpty unions && List.isEmpty aliases && List.isEmpty values && List.isEmpty binops then
        Nothing

    else
        (D.append (D.fromChars categoryName) (D.fromChars ":")
            :: unions
            ++ aliases
            ++ binops
            ++ values
        )
            |> D.vcat
            |> Just


{-| Renders a custom type declaration with its type variables and constructors.
-}
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


{-| Renders a type alias declaration.

`D.plus` puts its second argument first, so the nested calls here print the
header words in reverse order: the alias's name and variables after `=`, then
`alias`, then `type`.

-}
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


{-| Renders a value as its name and type annotation.
-}
valueToDoc : L.Localizer -> Name.Name -> Docs.Value -> D.Doc
valueToDoc localizer name (Docs.Value _ tipe) =
    D.sep [ D.fromName name |> D.plus (D.fromChars ":"), typeDoc localizer tipe ] |> D.hang 4


{-| Renders an operator with its type, associativity and precedence.

`D.plus` puts its second argument first, so the nested calls here print their
parts in reverse order: `)`, the precedence, `/`, the associativity, `(`, the
type, `:`, `)`, the operator name and `(`.

-}
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


{-| Renders `tipe` under `localizer`, without parentheses at the top level.
-}
typeDoc : L.Localizer -> Type.Type -> D.Doc
typeDoc localizer tipe =
    Type.toDoc localizer Type.None tipe
