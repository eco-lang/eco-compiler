module Terminal.Install exposing
    ( run
    , Args(..), Flags(..)
    )

{-| Package installation command for managing dependencies.

This module implements the `install` command which fetches packages from the
Elm package registry and adds them to the project's elm.json file. It handles
dependency resolution, version constraints, and distinguishes between regular
dependencies and test dependencies.


# Command Entry

@docs run


# Configuration Types

@docs Args, Flags

-}

import Builder.BackgroundWriter as BW
import Builder.Deps.Registry as Registry
import Builder.Deps.Solver as Solver
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.Elm.Constraint as C
import Compiler.Elm.Licenses as Licenses
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Dict exposing (Dict)
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| Arguments for the install command.

NoArgs means show help message, Install means add the named package.

-}
type Args
    = NoArgs
    | Install Pkg.Name


{-| Configuration flags for the install command.

Contains flags for test dependencies and auto-yes to skip confirmation prompts.

-}
type Flags
    = Flags Bool Bool


{-| Add a package to the project's dependencies.

Fetches package information from the registry, resolves version constraints,
updates elm.json, and verifies the project builds with the new dependency.

-}
run : Args -> Flags -> Task Never ()
run args (Flags forTest autoYes) =
    Reporting.attempt Exit.installToReport
        (Stuff.findRoot
            |> Task.andThen (handleRoot args forTest autoYes)
        )


handleRoot : Args -> Bool -> Bool -> Maybe FilePath -> Task Never (Result Exit.Install ())
handleRoot args forTest autoYes maybeRoot =
    case maybeRoot of
        Nothing ->
            Task.succeed (Err Exit.InstallNoOutline)

        Just root ->
            handleArgs root args forTest autoYes


handleArgs : FilePath -> Args -> Bool -> Bool -> Task Never (Result Exit.Install ())
handleArgs root args forTest autoYes =
    case args of
        NoArgs ->
            Stuff.getElmHome
                |> Task.map (\elmHome -> Err (Exit.InstallNoArgs elmHome))

        Install pkg ->
            Task.run (installPackage root pkg forTest autoYes)


installPackage : FilePath -> Pkg.Name -> Bool -> Bool -> Task Exit.Install ()
installPackage root pkg forTest autoYes =
    Task.eio Exit.InstallBadRegistry (Solver.initEnv Nothing)
        |> Task.andThen (installWithEnv root pkg forTest autoYes)


installWithEnv : FilePath -> Pkg.Name -> Bool -> Bool -> Solver.Env -> Task Exit.Install ()
installWithEnv root pkg forTest autoYes env =
    Task.eio Exit.InstallBadOutline (Outline.read root)
        |> Task.andThen (installWithOutline root pkg forTest autoYes env)


installWithOutline : FilePath -> Pkg.Name -> Bool -> Bool -> Solver.Env -> Outline.Outline -> Task Exit.Install ()
installWithOutline root pkg forTest autoYes env oldOutline =
    case oldOutline of
        Outline.App outline ->
            makeAppPlan env pkg outline forTest
                |> Task.andThen (\changes -> attemptChanges root env oldOutline V.toChars changes autoYes)

        Outline.Pkg outline ->
            makePkgPlan env pkg outline forTest
                |> Task.andThen (\changes -> attemptChanges root env oldOutline C.toChars changes autoYes)



-- ====== ATTEMPT CHANGES ======


type Changes vsn
    = AlreadyInstalled
    | PromoteTest Outline.Outline
    | PromoteIndirect Outline.Outline
    | Changes (Dict Pkg.Name (Change vsn)) Outline.Outline


attemptChanges : String -> Solver.Env -> Outline.Outline -> (a -> String) -> Changes a -> Bool -> Task Exit.Install ()
attemptChanges root env oldOutline toChars changes autoYes =
    case changes of
        AlreadyInstalled ->
            Task.io (IO.printLn "It is already installed!")

        PromoteIndirect newOutline ->
            attemptChangesHelp root env oldOutline newOutline autoYes <|
                D.vcat
                    [ D.fillSep
                        [ D.fromChars "I"
                        , D.fromChars "found"
                        , D.fromChars "it"
                        , D.fromChars "in"
                        , D.fromChars "your"
                        , D.fromChars "elm.json"
                        , D.fromChars "file,"
                        , D.fromChars "but"
                        , D.fromChars "in"
                        , D.fromChars "the"
                        , D.dullyellow (D.fromChars "\"indirect\"")
                        , D.fromChars "dependencies."
                        ]
                    , D.fillSep
                        [ D.fromChars "Should"
                        , D.fromChars "I"
                        , D.fromChars "move"
                        , D.fromChars "it"
                        , D.fromChars "into"
                        , D.green (D.fromChars "\"direct\"")
                        , D.fromChars "dependencies"
                        , D.fromChars "for"
                        , D.fromChars "more"
                        , D.fromChars "general"
                        , D.fromChars "use?"
                        , D.fromChars "[Y/n]: "
                        ]
                    ]

        PromoteTest newOutline ->
            attemptChangesHelp root env oldOutline newOutline autoYes <|
                D.vcat
                    [ D.fillSep
                        [ D.fromChars "I"
                        , D.fromChars "found"
                        , D.fromChars "it"
                        , D.fromChars "in"
                        , D.fromChars "your"
                        , D.fromChars "elm.json"
                        , D.fromChars "file,"
                        , D.fromChars "but"
                        , D.fromChars "in"
                        , D.fromChars "the"
                        , D.dullyellow (D.fromChars "\"test-dependencies\"")
                        , D.fromChars "field."
                        ]
                    , D.fillSep
                        [ D.fromChars "Should"
                        , D.fromChars "I"
                        , D.fromChars "move"
                        , D.fromChars "it"
                        , D.fromChars "into"
                        , D.green (D.fromChars "\"dependencies\"")
                        , D.fromChars "for"
                        , D.fromChars "more"
                        , D.fromChars "general"
                        , D.fromChars "use?"
                        , D.fromChars "[Y/n]: "
                        ]
                    ]

        Changes changeDict newOutline ->
            let
                widths : Widths
                widths =
                    Dict.foldr (widen toChars) (Widths 0 0 0) changeDict

                changeDocs : ChangeDocs
                changeDocs =
                    Dict.foldr (addChange toChars widths) (Docs [] [] []) changeDict
            in
            attemptChangesHelp root env oldOutline newOutline autoYes <|
                D.vcat
                    [ D.fromChars "Here is my plan:"
                    , viewChangeDocs changeDocs
                    , D.fromChars ""
                    , D.fromChars "Would you like me to update your elm.json accordingly? [Y/n]: "
                    ]


attemptChangesHelp : FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> D.Doc -> Task Exit.Install ()
attemptChangesHelp root env oldOutline newOutline autoYes question =
    Task.eio Exit.InstallBadDetails <|
        BW.withScope
            (\scope ->
                askInstallQuestion autoYes question
                    |> Task.andThen (applyInstallChanges scope root env oldOutline newOutline)
            )


askInstallQuestion : Bool -> D.Doc -> Task Never Bool
askInstallQuestion autoYes question =
    if autoYes then
        Task.succeed True

    else
        Reporting.ask question


applyInstallChanges : BW.Scope -> FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> Task Never (Result Exit.Details ())
applyInstallChanges scope root env oldOutline newOutline approved =
    if approved then
        Outline.write root newOutline
            |> Task.andThen (\_ -> Details.verifyInstall scope root env newOutline)
            |> Task.andThen (handleInstallResult root oldOutline)

    else
        IO.printLn "Okay, I did not change anything!"
            |> Task.map (\_ -> Ok ())


handleInstallResult : FilePath -> Outline.Outline -> Result Exit.Details () -> Task Never (Result Exit.Details ())
handleInstallResult root oldOutline result =
    case result of
        Err exit ->
            Outline.write root oldOutline
                |> Task.map (\_ -> Err exit)

        Ok () ->
            IO.printLn "Success!"
                |> Task.map (\_ -> Ok ())



-- ====== MAKE APP PLAN ======


makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Bool -> Task Exit.Install (Changes V.Version)
makeAppPlan (Solver.Env env) pkg ((Outline.AppOutline appData) as outline) forTest =
    if forTest then
        makeAppPlanForTest env.cache env.connection env.registry pkg appData outline

    else
        makeAppPlanForDeps env.cache env.connection env.registry pkg appData outline


makeAppPlanForTest :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> Outline.AppOutlineData
    -> Outline.AppOutline
    -> Task Exit.Install (Changes V.Version)
makeAppPlanForTest cache connection registry pkg appData outline =
    if Dict.member pkg appData.testDirect then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg appData.testIndirect of
            Just vsn ->
                Outline.AppOutline
                    { appData
                        | testDirect = Dict.insert pkg vsn appData.testDirect
                        , testIndirect = Dict.remove pkg appData.testIndirect
                    }
                    |> Outline.App
                    |> PromoteTest
                    |> Task.succeed

            Nothing ->
                addAppPackageFromScratch cache connection registry pkg outline True


makeAppPlanForDeps :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> Outline.AppOutlineData
    -> Outline.AppOutline
    -> Task Exit.Install (Changes V.Version)
makeAppPlanForDeps cache connection registry pkg appData outline =
    if Dict.member pkg appData.depsDirect then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg appData.depsIndirect of
            Just vsn ->
                Outline.AppOutline
                    { appData
                        | depsDirect = Dict.insert pkg vsn appData.depsDirect
                        , depsIndirect = Dict.remove pkg appData.depsIndirect
                    }
                    |> Outline.App
                    |> PromoteIndirect
                    |> Task.succeed

            Nothing ->
                case Dict.get pkg appData.testDirect of
                    Just vsn ->
                        Outline.AppOutline
                            { appData
                                | depsDirect = Dict.insert pkg vsn appData.depsDirect
                                , testDirect = Dict.remove pkg appData.testDirect
                            }
                            |> Outline.App
                            |> PromoteTest
                            |> Task.succeed

                    Nothing ->
                        case Dict.get pkg appData.testIndirect of
                            Just vsn ->
                                Outline.AppOutline
                                    { appData
                                        | depsDirect = Dict.insert pkg vsn appData.depsDirect
                                        , testIndirect = Dict.remove pkg appData.testIndirect
                                    }
                                    |> Outline.App
                                    |> PromoteTest
                                    |> Task.succeed

                            Nothing ->
                                addAppPackageFromScratch cache connection registry pkg outline False


addAppPackageFromScratch :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> Outline.AppOutline
    -> Bool
    -> Task Exit.Install (Changes V.Version)
addAppPackageFromScratch cache connection registry pkg outline forTest =
    case Registry.getVersions_ pkg registry of
        Err suggestions ->
            throwUnknownPackageError connection pkg suggestions

        Ok _ ->
            Task.io (Solver.addToApp cache connection registry pkg outline forTest)
                |> Task.andThen (handleAppSolverResult pkg)


handleAppSolverResult : Pkg.Name -> Solver.SolverResult Solver.AppSolution -> Task Exit.Install (Changes V.Version)
handleAppSolverResult pkg result =
    case result of
        Solver.SolverOk (Solver.AppSolution old new app) ->
            Task.succeed (Changes (detectChanges old new) (Outline.App app))

        Solver.NoSolution ->
            Task.throw (Exit.InstallNoOnlineAppSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.InstallNoOfflineAppSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.InstallHadSolverTrouble exit)


throwUnknownPackageError : Solver.Connection -> Pkg.Name -> List Pkg.Name -> Task Exit.Install a
throwUnknownPackageError connection pkg suggestions =
    case connection of
        Solver.Online _ ->
            Task.throw (Exit.InstallUnknownPackageOnline pkg suggestions)

        Solver.Offline ->
            Task.throw (Exit.InstallUnknownPackageOffline pkg suggestions)



-- ====== MAKE PACKAGE PLAN ======


type alias PkgOutlineInfo =
    { name : Pkg.Name
    , summary : String
    , license : Licenses.License
    , version : V.Version
    , exposed : Outline.Exposed
    , deps : Dict Pkg.Name C.Constraint
    , test : Dict Pkg.Name C.Constraint
    , elmVersion : C.Constraint
    }


makePkgPlan : Solver.Env -> Pkg.Name -> Outline.PkgOutline -> Bool -> Task Exit.Install (Changes C.Constraint)
makePkgPlan (Solver.Env env) pkg (Outline.PkgOutline pkgData) forTest =
    let
        info =
            PkgOutlineInfo pkgData.name pkgData.summary pkgData.license pkgData.version pkgData.exposed pkgData.deps pkgData.testDeps pkgData.elm
    in
    if forTest then
        makePkgPlanForTest env.cache env.connection env.registry pkg info

    else
        makePkgPlanForDeps env.cache env.connection env.registry pkg info


makePkgPlanForTest :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> PkgOutlineInfo
    -> Task Exit.Install (Changes C.Constraint)
makePkgPlanForTest cache connection registry pkg info =
    if Dict.member pkg info.test then
        Task.succeed AlreadyInstalled

    else
        case Registry.getVersions_ pkg registry of
            Err suggestions ->
                throwUnknownPackageError connection pkg suggestions

            Ok (Registry.KnownVersions _ _) ->
                let
                    cons =
                        Dict.insert pkg C.anything info.test
                in
                Task.io (Solver.verify cache connection registry cons)
                    |> Task.andThen (handlePkgTestSolverResult pkg info)


handlePkgTestSolverResult :
    Pkg.Name
    -> PkgOutlineInfo
    -> Solver.SolverResult (Dict Pkg.Name Solver.Details)
    -> Task Exit.Install (Changes C.Constraint)
handlePkgTestSolverResult pkg info result =
    case result of
        Solver.SolverOk solution ->
            let
                (Solver.Details vsn _) =
                    Utils.dictFind pkg solution

                con =
                    C.untilNextMajor vsn

                newTest =
                    Dict.insert pkg con info.test

                changes =
                    detectChanges info.test newTest

                news =
                    Utils.dictMapMaybe keepNew changes
            in
            Outline.PkgOutline
                { name = info.name
                , summary = info.summary
                , license = info.license
                , version = info.version
                , exposed = info.exposed
                , deps = info.deps
                , testDeps = addNews (Just pkg) news info.test
                , elm = info.elmVersion
                }
                |> Outline.Pkg
                |> Changes changes
                |> Task.succeed

        Solver.NoSolution ->
            Task.throw (Exit.InstallNoOnlinePkgSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.InstallNoOfflinePkgSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.InstallHadSolverTrouble exit)


makePkgPlanForDeps :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> PkgOutlineInfo
    -> Task Exit.Install (Changes C.Constraint)
makePkgPlanForDeps cache connection registry pkg info =
    if Dict.member pkg info.deps then
        Task.succeed AlreadyInstalled

    else
        case Dict.get pkg info.test of
            Just con ->
                Outline.PkgOutline
                    { name = info.name
                    , summary = info.summary
                    , license = info.license
                    , version = info.version
                    , exposed = info.exposed
                    , deps = Dict.insert pkg con info.deps
                    , testDeps = Dict.remove pkg info.test
                    , elm = info.elmVersion
                    }
                    |> Outline.Pkg
                    |> PromoteTest
                    |> Task.succeed

            Nothing ->
                addPkgDependencyFromScratch cache connection registry pkg info


addPkgDependencyFromScratch :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> PkgOutlineInfo
    -> Task Exit.Install (Changes C.Constraint)
addPkgDependencyFromScratch cache connection registry pkg info =
    case Registry.getVersions_ pkg registry of
        Err suggestions ->
            throwUnknownPackageError connection pkg suggestions

        Ok (Registry.KnownVersions _ _) ->
            let
                old =
                    Dict.union info.deps info.test

                cons =
                    Dict.insert pkg C.anything old
            in
            Task.io (Solver.verify cache connection registry cons)
                |> Task.andThen (handlePkgDepsSolverResult pkg info old)


handlePkgDepsSolverResult :
    Pkg.Name
    -> PkgOutlineInfo
    -> Dict Pkg.Name C.Constraint
    -> Solver.SolverResult (Dict Pkg.Name Solver.Details)
    -> Task Exit.Install (Changes C.Constraint)
handlePkgDepsSolverResult pkg info old result =
    case result of
        Solver.SolverOk solution ->
            let
                (Solver.Details vsn _) =
                    Utils.dictFind pkg solution

                con =
                    C.untilNextMajor vsn

                new =
                    Dict.insert pkg con old

                changes =
                    detectChanges old new

                news =
                    Utils.dictMapMaybe keepNew changes
            in
            Outline.PkgOutline
                { name = info.name
                , summary = info.summary
                , license = info.license
                , version = info.version
                , exposed = info.exposed
                , deps = addNews (Just pkg) news info.deps
                , testDeps = addNews Nothing news info.test
                , elm = info.elmVersion
                }
                |> Outline.Pkg
                |> Changes changes
                |> Task.succeed

        Solver.NoSolution ->
            Task.throw (Exit.InstallNoOnlinePkgSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.InstallNoOfflinePkgSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.InstallHadSolverTrouble exit)


addNews : Maybe Pkg.Name -> Dict Pkg.Name C.Constraint -> Dict Pkg.Name C.Constraint -> Dict Pkg.Name C.Constraint
addNews pkg new old =
    Dict.merge
        Dict.insert
        (\k _ n -> Dict.insert k n)
        (\k c acc ->
            if Just k == pkg then
                Dict.insert k c acc

            else
                acc
        )
        old
        new
        Dict.empty



-- ====== CHANGES ======


type Change a
    = Insert a
    | Change a a
    | Remove a


detectChanges : Dict Pkg.Name a -> Dict Pkg.Name a -> Dict Pkg.Name (Change a)
detectChanges old new =
    Dict.merge
        (\k v -> Dict.insert k (Remove v))
        (\k oldElem newElem acc ->
            case keepChange k oldElem newElem of
                Just change ->
                    Dict.insert k change acc

                Nothing ->
                    acc
        )
        (\k v -> Dict.insert k (Insert v))
        old
        new
        Dict.empty


keepChange : k -> v -> v -> Maybe (Change v)
keepChange _ old new =
    if old == new then
        Nothing

    else
        Just (Change old new)


keepNew : Change a -> Maybe a
keepNew change =
    case change of
        Insert a ->
            Just a

        Change _ a ->
            Just a

        Remove _ ->
            Nothing



-- ====== VIEW CHANGE DOCS ======


type ChangeDocs
    = Docs (List D.Doc) (List D.Doc) (List D.Doc)


viewChangeDocs : ChangeDocs -> D.Doc
viewChangeDocs (Docs inserts changes removes) =
    [ viewNonZero "Add:" inserts
    , viewNonZero "Change:" changes
    , viewNonZero "Remove:" removes
    ]
        |> List.concat
        |> D.vcat
        |> D.indent 2


viewNonZero : String -> List D.Doc -> List D.Doc
viewNonZero title entries =
    if List.isEmpty entries then
        []

    else
        [ D.fromChars ""
        , D.fromChars title
        , D.indent 2 (D.vcat entries)
        ]



-- ====== VIEW CHANGE ======


addChange : (a -> String) -> Widths -> Pkg.Name -> Change a -> ChangeDocs -> ChangeDocs
addChange toChars widths name change (Docs inserts changes removes) =
    case change of
        Insert new ->
            Docs (viewInsert toChars widths name new :: inserts) changes removes

        Change old new ->
            Docs inserts (viewChange toChars widths name old new :: changes) removes

        Remove old ->
            Docs inserts changes (viewRemove toChars widths name old :: removes)


viewInsert : (a -> String) -> Widths -> Pkg.Name -> a -> D.Doc
viewInsert toChars (Widths nameWidth leftWidth _) name new =
    viewName nameWidth name
        |> D.plus (pad leftWidth (toChars new))


viewChange : (a -> String) -> Widths -> Pkg.Name -> a -> a -> D.Doc
viewChange toChars (Widths nameWidth leftWidth rightWidth) name old new =
    D.hsep
        [ viewName nameWidth name
        , pad leftWidth (toChars old)
        , D.fromChars "=>"
        , pad rightWidth (toChars new)
        ]


viewRemove : (a -> String) -> Widths -> Pkg.Name -> a -> D.Doc
viewRemove toChars (Widths nameWidth leftWidth _) name old =
    viewName nameWidth name
        |> D.plus (pad leftWidth (toChars old))


viewName : Int -> Pkg.Name -> D.Doc
viewName width name =
    D.fill (width + 3) (D.fromPackage name)


pad : Int -> String -> D.Doc
pad width string =
    D.fromChars (String.repeat (width - String.length string) " ")
        |> D.a (D.fromChars string)



-- ====== WIDTHS ======


type Widths
    = Widths Int Int Int


widen : (a -> String) -> Pkg.Name -> Change a -> Widths -> Widths
widen toChars pkg change (Widths name left right) =
    let
        toLength : a -> Int
        toLength a =
            String.length (toChars a)

        newName : Int
        newName =
            max name (String.length (Pkg.toChars pkg))
    in
    case change of
        Insert new ->
            Widths newName (max left (toLength new)) right

        Change old new ->
            Widths newName (max left (toLength old)) (max right (toLength new))

        Remove old ->
            Widths newName (max left (toLength old)) right
