module Terminal.Uninstall exposing
    ( Args(..)
    , Flags(..)
    , run
    )

import Builder.BackgroundWriter as BW
import Builder.Deps.Solver as Solver
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.Elm.Constraint as C
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Data.Map as Dict exposing (Dict)
import System.IO as IO
import Task exposing (Task)
import Utils.Main exposing (FilePath)
import Utils.Task.Extra as Task



-- RUN


type Args
    = NoArgs
    | Uninstall Pkg.Name


type Flags
    = Flags Bool


run : Args -> Flags -> Task Never ()
run args (Flags autoYes) =
    Reporting.attempt Exit.uninstallToReport
        (Stuff.findRoot
            |> Task.andThen (handleRoot args autoYes)
        )


handleRoot : Args -> Bool -> Maybe FilePath -> Task Never (Result Exit.Uninstall ())
handleRoot args autoYes maybeRoot =
    case maybeRoot of
        Nothing ->
            Task.succeed (Err Exit.UninstallNoOutline)

        Just root ->
            handleArgs root args autoYes


handleArgs : FilePath -> Args -> Bool -> Task Never (Result Exit.Uninstall ())
handleArgs root args autoYes =
    case args of
        NoArgs ->
            Task.succeed (Err Exit.UninstallNoArgs)

        Uninstall pkg ->
            Task.run (uninstallPackage root pkg autoYes)


uninstallPackage : FilePath -> Pkg.Name -> Bool -> Task Exit.Uninstall ()
uninstallPackage root pkg autoYes =
    Task.eio Exit.UninstallBadRegistry Solver.initEnv
        |> Task.andThen (uninstallWithEnv root pkg autoYes)


uninstallWithEnv : FilePath -> Pkg.Name -> Bool -> Solver.Env -> Task Exit.Uninstall ()
uninstallWithEnv root pkg autoYes env =
    Task.eio Exit.UninstallBadOutline (Outline.read root)
        |> Task.andThen (uninstallWithOutline root pkg autoYes env)


uninstallWithOutline : FilePath -> Pkg.Name -> Bool -> Solver.Env -> Outline.Outline -> Task Exit.Uninstall ()
uninstallWithOutline root pkg autoYes env oldOutline =
    case oldOutline of
        Outline.App outline ->
            makeAppPlan env pkg outline
                |> Task.andThen (\changes -> attemptChanges root env oldOutline V.toChars changes autoYes)

        Outline.Pkg outline ->
            makePkgPlan pkg outline
                |> Task.andThen (\changes -> attemptChanges root env oldOutline C.toChars changes autoYes)



-- ATTEMPT CHANGES


type Changes vsn
    = AlreadyNotPresent
    | Changes (Dict ( String, String ) Pkg.Name (Change vsn)) Outline.Outline


attemptChanges : String -> Solver.Env -> Outline.Outline -> (a -> String) -> Changes a -> Bool -> Task Exit.Uninstall ()
attemptChanges root env oldOutline toChars changes autoYes =
    case changes of
        AlreadyNotPresent ->
            Task.io (IO.putStrLn "It is not currently installed!")

        Changes changeDict newOutline ->
            let
                widths : Widths
                widths =
                    Dict.foldr compare (widen toChars) (Widths 0 0 0) changeDict

                changeDocs : ChangeDocs
                changeDocs =
                    Dict.foldr compare (addChange toChars widths) (Docs [] [] []) changeDict
            in
            attemptChangesHelp root env oldOutline newOutline autoYes <|
                D.vcat
                    [ D.fromChars "Here is my plan:"
                    , viewChangeDocs changeDocs
                    , D.fromChars ""
                    , D.fromChars "Would you like me to update your elm.json accordingly? [Y/n]: "
                    ]


attemptChangesHelp : FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> D.Doc -> Task Exit.Uninstall ()
attemptChangesHelp root env oldOutline newOutline autoYes question =
    Task.eio Exit.UninstallBadDetails <|
        BW.withScope
            (\scope ->
                askUninstallQuestion autoYes question
                    |> Task.andThen (applyUninstallChanges scope root env oldOutline newOutline)
            )


askUninstallQuestion : Bool -> D.Doc -> Task Never Bool
askUninstallQuestion autoYes question =
    if autoYes then
        Task.succeed True

    else
        Reporting.ask question


applyUninstallChanges : BW.Scope -> FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> Task Never (Result Exit.Details ())
applyUninstallChanges scope root env oldOutline newOutline approved =
    if approved then
        Outline.write root newOutline
            |> Task.andThen (\_ -> Details.verifyInstall scope root env newOutline)
            |> Task.andThen (handleUninstallResult root oldOutline)

    else
        IO.putStrLn "Okay, I did not change anything!"
            |> Task.map (\_ -> Ok ())


handleUninstallResult : FilePath -> Outline.Outline -> Result Exit.Details () -> Task Never (Result Exit.Details ())
handleUninstallResult root oldOutline result =
    case result of
        Err exit ->
            Outline.write root oldOutline
                |> Task.map (\_ -> Err exit)

        Ok () ->
            IO.putStrLn "Success!"
                |> Task.map (\_ -> Ok ())



-- MAKE APP PLAN


makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Task Exit.Uninstall (Changes V.Version)
makeAppPlan (Solver.Env cache _ connection registry) pkg ((Outline.AppOutline _ _ direct _ testDirect _) as outline) =
    case Dict.get identity pkg (Dict.union direct testDirect) of
        Just _ ->
            Task.io (Solver.removeFromApp cache connection registry pkg outline)
                |> Task.andThen (handleAppSolverResult pkg)

        Nothing ->
            Task.succeed AlreadyNotPresent


handleAppSolverResult : Pkg.Name -> Solver.SolverResult Solver.AppSolution -> Task Exit.Uninstall (Changes V.Version)
handleAppSolverResult pkg result =
    case result of
        Solver.SolverOk (Solver.AppSolution old new app) ->
            Task.succeed (Changes (detectChanges old new) (Outline.App app))

        Solver.NoSolution ->
            Task.throw (Exit.UninstallNoOnlineAppSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.UninstallNoOfflineAppSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.UninstallHadSolverTrouble exit)



-- MAKE PACKAGE PLAN


makePkgPlan : Pkg.Name -> Outline.PkgOutline -> Task Exit.Uninstall (Changes C.Constraint)
makePkgPlan pkg (Outline.PkgOutline name summary license version exposed deps test elmVersion) =
    let
        old : Dict ( String, String ) Pkg.Name C.Constraint
        old =
            Dict.union deps test
    in
    if Dict.member identity pkg old then
        let
            new : Dict ( String, String ) Pkg.Name C.Constraint
            new =
                Dict.remove identity pkg old

            changes : Dict ( String, String ) Pkg.Name (Change C.Constraint)
            changes =
                detectChanges old new
        in
        Task.succeed <|
            Changes changes <|
                Outline.Pkg <|
                    Outline.PkgOutline name
                        summary
                        license
                        version
                        exposed
                        (Dict.remove identity pkg deps)
                        (Dict.remove identity pkg test)
                        elmVersion

    else
        Task.succeed AlreadyNotPresent



-- CHANGES


type Change a
    = Insert a
    | Change a a
    | Remove a


detectChanges : Dict ( String, String ) Pkg.Name a -> Dict ( String, String ) Pkg.Name a -> Dict ( String, String ) Pkg.Name (Change a)
detectChanges old new =
    Dict.merge compare
        (\k v -> Dict.insert identity k (Remove v))
        (\k oldElem newElem acc ->
            case keepChange k oldElem newElem of
                Just change ->
                    Dict.insert identity k change acc

                Nothing ->
                    acc
        )
        (\k v -> Dict.insert identity k (Insert v))
        old
        new
        Dict.empty


keepChange : k -> v -> v -> Maybe (Change v)
keepChange _ old new =
    if old == new then
        Nothing

    else
        Just (Change old new)



-- VIEW CHANGE DOCS


type ChangeDocs
    = Docs (List D.Doc) (List D.Doc) (List D.Doc)


viewChangeDocs : ChangeDocs -> D.Doc
viewChangeDocs (Docs inserts changes removes) =
    D.indent 2 <|
        D.vcat <|
            List.concat <|
                [ viewNonZero "Add:" inserts
                , viewNonZero "Change:" changes
                , viewNonZero "Remove:" removes
                ]


viewNonZero : String -> List D.Doc -> List D.Doc
viewNonZero title entries =
    if List.isEmpty entries then
        []

    else
        [ D.fromChars ""
        , D.fromChars title
        , D.indent 2 (D.vcat entries)
        ]



-- VIEW CHANGE


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



-- WIDTHS


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
