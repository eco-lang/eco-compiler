module Terminal.Uninstall exposing
    ( run
    , Args(..), Flags(..)
    )

{-| The `uninstall` command: it removes one package from the dependencies in
the project's `elm.json`, after showing what will change and asking first,
unless `--yes` is given, in which case nothing is shown or asked.

The change shown before anything is written is the _plan_: every package that
would be added, changed or removed, with its version or constraint before and
after. How the plan is made depends on the kind of project.

For an application, the package must be a direct dependency, ordinary or test;
one that is only an indirect dependency is reported as not installed. The rest
of the dependencies are re-solved without it, as
`Builder.Deps.Solver.removeFromApp` describes, so the plan can show indirect
dependencies changing or dropping out as well, and lists exact versions.

For a package project, the package's constraint is deleted from the
dependencies and the test dependencies. Nothing is solved, so the plan is that
one removal, shown as a constraint.

Once the plan is accepted, the new `elm.json` is written and the dependencies
are verified with `Builder.Elm.Details.verifyInstall`. If verification fails,
the old `elm.json` is written back. Every error ends the program through
`Builder.Reporting.attempt`, which prints the report and exits with failure.


# Command Entry

@docs run


# Configuration

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
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import Dict exposing (Dict)
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| The package the command was asked to remove, if one was named.

`NoArgs` is reported as an error, since there is nothing to remove.

-}
type Args
    = NoArgs
    | Uninstall Pkg.Name


{-| The command's options. The `Bool` is the `--yes` switch: when it is
`True` the plan is neither shown nor asked about, and is carried out at once.
-}
type Flags
    = Flags Bool


{-| Removes the package named in `args` from the dependencies of the project
the current directory belongs to, after showing the plan and asking for
confirmation, both of which the `--yes` flag skips.

On success it prints "Success!". It is an error, reported and ending the
program with failure, when no `elm.json` is found, no package is named, the
registry or `elm.json` cannot be read, no solution exists for an application,
the solver fails, or verifying the new dependencies fails; in the last case
the old `elm.json` is restored first.

-}
run : Args -> Flags -> Task Never ()
run args (Flags autoYes) =
    Reporting.attempt Exit.uninstallToReport
        (Stuff.findRoot
            |> Task.andThen (handleRoot args autoYes)
        )


{-| Returns the outcome of uninstalling from the project at `maybeRoot`, or
`UninstallNoOutline` when no project root was found.
-}
handleRoot : Args -> Bool -> Maybe FilePath -> Task Never (Result Exit.Uninstall ())
handleRoot args autoYes maybeRoot =
    case maybeRoot of
        Nothing ->
            Task.succeed (Err Exit.UninstallNoOutline)

        Just root ->
            handleArgs root args autoYes


{-| Returns the outcome of uninstalling the package `args` names from the
project at `root`, or `UninstallNoArgs` when it names none.
-}
handleArgs : FilePath -> Args -> Bool -> Task Never (Result Exit.Uninstall ())
handleArgs root args autoYes =
    case args of
        NoArgs ->
            Task.succeed (Err Exit.UninstallNoArgs)

        Uninstall pkg ->
            Task.run (uninstallPackage root pkg autoYes)


{-| Loads the package registry, with any bundled packages found beside the
executable, and uninstalls `pkg` from the project at `root` with it.
-}
uninstallPackage : FilePath -> Pkg.Name -> Bool -> Task Exit.Uninstall ()
uninstallPackage root pkg autoYes =
    Task.eio Exit.UninstallBadRegistry (Stuff.resolveBundledPackages [] |> Task.andThen (Solver.initEnv Registry.Normal))
        |> Task.andThen (uninstallWithEnv root pkg autoYes)


{-| Reads the project's `elm.json` and uninstalls `pkg` from it.
-}
uninstallWithEnv : FilePath -> Pkg.Name -> Bool -> Solver.Env -> Task Exit.Uninstall ()
uninstallWithEnv root pkg autoYes env =
    Task.eio Exit.UninstallBadOutline (Outline.read root)
        |> Task.andThen (uninstallWithOutline root pkg autoYes env)


{-| Makes the plan for removing `pkg` from `oldOutline`, an application's or a
package's, and carries it out. An application's plan shows versions and a
package's shows constraints.
-}
uninstallWithOutline : FilePath -> Pkg.Name -> Bool -> Solver.Env -> Outline.Outline -> Task Exit.Uninstall ()
uninstallWithOutline root pkg autoYes env oldOutline =
    case oldOutline of
        Outline.App outline ->
            makeAppPlan env pkg outline
                |> Task.andThen (\changes -> attemptChanges root env oldOutline V.toChars changes autoYes)

        Outline.Pkg outline ->
            makePkgPlan pkg outline
                |> Task.andThen (\changes -> attemptChanges root env oldOutline C.toChars changes autoYes)



-- ====== ATTEMPT CHANGES ======


{-| The plan for an uninstall: either the package is not a dependency to remove,
or the changes to show, keyed by package, together with the outline to write.
-}
type Changes vsn
    = AlreadyNotPresent
    | Changes (Dict Pkg.Name (Change vsn)) Outline.Outline


{-| Shows the plan in `changes` and carries it out if accepted, or carries it
out unshown when `autoYes` is set, or prints "It is not currently installed!"
when there is nothing to remove. `toChars` renders a version or constraint
in the plan.
-}
attemptChanges : String -> Solver.Env -> Outline.Outline -> (a -> String) -> Changes a -> Bool -> Task Exit.Uninstall ()
attemptChanges root env oldOutline toChars changes autoYes =
    case changes of
        AlreadyNotPresent ->
            Task.io (IO.printLn "It is not currently installed!")

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


{-| Asks `question` (or skips asking when `autoYes` is set), then, if the answer
is yes, writes `newOutline` and verifies it, restoring `oldOutline` if the
verification fails. Writes started during verification are finished before
the result is returned.
-}
attemptChangesHelp : FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> D.Doc -> Task Exit.Uninstall ()
attemptChangesHelp root env oldOutline newOutline autoYes question =
    Task.eio Exit.UninstallBadDetails <|
        BW.withScope
            (\scope ->
                askUninstallQuestion autoYes question
                    |> Task.andThen (applyUninstallChanges scope root env oldOutline newOutline)
            )


{-| Returns the answer to `question`, or yes without asking when `autoYes` is
set. `Builder.Reporting.ask` says which answers count as yes.
-}
askUninstallQuestion : Bool -> D.Doc -> Task Never Bool
askUninstallQuestion autoYes question =
    if autoYes then
        Task.succeed True

    else
        Reporting.ask question


{-| Writes `newOutline` and verifies the dependencies it names when `approved`;
otherwise prints that nothing was changed and leaves `elm.json` alone.
-}
applyUninstallChanges : BW.Scope -> FilePath -> Solver.Env -> Outline.Outline -> Outline.Outline -> Bool -> Task Never (Result Exit.Details ())
applyUninstallChanges scope root env oldOutline newOutline approved =
    if approved then
        Outline.write root newOutline
            |> Task.andThen (\_ -> Details.verifyInstall scope root env newOutline)
            |> Task.andThen (handleUninstallResult root oldOutline)

    else
        IO.printLn "Okay, I did not change anything!"
            |> Task.map (\_ -> Ok ())


{-| Prints "Success!" after a successful verification. After a failed one,
writes `oldOutline` back to `elm.json` and returns the failure.
-}
handleUninstallResult : FilePath -> Outline.Outline -> Result Exit.Details () -> Task Never (Result Exit.Details ())
handleUninstallResult root oldOutline result =
    case result of
        Err exit ->
            Outline.write root oldOutline
                |> Task.map (\_ -> Err exit)

        Ok () ->
            IO.printLn "Success!"
                |> Task.map (\_ -> Ok ())



-- ====== MAKE APP PLAN ======


{-| Makes the plan for removing `pkg` from an application, or `AlreadyNotPresent`
when `pkg` is neither a direct nor a test-direct dependency. The plan compares
every dependency version before and after re-solving without `pkg`.
-}
makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Task Exit.Uninstall (Changes V.Version)
makeAppPlan (Solver.Env env) pkg ((Outline.AppOutline appData) as outline) =
    case Dict.get pkg (Dict.union appData.depsDirect appData.testDirect) of
        Just _ ->
            Task.io (Solver.removeFromApp env.cache env.connection env.registry pkg outline)
                |> Task.andThen (handleAppSolverResult pkg)

        Nothing ->
            Task.succeed AlreadyNotPresent


{-| Turns the solver's answer for removing `pkg` into a plan, or into the
uninstall error for no solution online, no solution offline, or a solver
failure.
-}
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



-- ====== MAKE PACKAGE PLAN ======


{-| Makes the plan for removing `pkg` from a package project, or
`AlreadyNotPresent` when `pkg` is in neither its dependencies nor its test
dependencies. The new outline lacks `pkg` in both, and the plan shows its one
removal. When `pkg` is in both, the constraint shown is the one from the
dependencies.
-}
makePkgPlan : Pkg.Name -> Outline.PkgOutline -> Task Exit.Uninstall (Changes C.Constraint)
makePkgPlan pkg (Outline.PkgOutline pkgData) =
    let
        old : Dict Pkg.Name C.Constraint
        old =
            Dict.union pkgData.deps pkgData.testDeps
    in
    if Dict.member pkg old then
        let
            new : Dict Pkg.Name C.Constraint
            new =
                Dict.remove pkg old

            changes : Dict Pkg.Name (Change C.Constraint)
            changes =
                detectChanges old new
        in
        Outline.PkgOutline
            { pkgData
                | deps = Dict.remove pkg pkgData.deps
                , testDeps = Dict.remove pkg pkgData.testDeps
            }
            |> Outline.Pkg
            |> Changes changes
            |> Task.succeed

    else
        Task.succeed AlreadyNotPresent



-- ====== CHANGES ======


{-| What happens to one package's version or constraint under the plan. `Change`
carries the old value and then the new one.
-}
type Change a
    = Insert a
    | Change a a
    | Remove a


{-| Returns the differences between `old` and `new`: a `Remove` for each package
only in `old`, an `Insert` for each only in `new`, and a `Change` for each in
both with different values. A package whose value is the same is left out.
-}
detectChanges : Dict Pkg.Name a -> Dict Pkg.Name a -> Dict Pkg.Name (Change a)
detectChanges old new =
    Dict.merge
        (\k v -> Dict.insert k (Remove v))
        (\k oldElem newElem acc ->
            case keepChange oldElem newElem of
                Just change ->
                    Dict.insert k change acc

                Nothing ->
                    acc
        )
        (\k v -> Dict.insert k (Insert v))
        old
        new
        Dict.empty


{-| Returns a `Change` from `old` to `new`, or `Nothing` when they are equal.
-}
keepChange : v -> v -> Maybe (Change v)
keepChange old new =
    if old == new then
        Nothing

    else
        Just (Change old new)



-- ====== VIEW CHANGE DOCS ======


{-| The rendered lines of a plan, sorted into additions, changes and removals, in
that order.
-}
type ChangeDocs
    = Docs (List D.Doc) (List D.Doc) (List D.Doc)


{-| Lays out a plan as its "Add:", "Change:" and "Remove:" sections, each left out
when it has no lines, indented by two spaces.
-}
viewChangeDocs : ChangeDocs -> D.Doc
viewChangeDocs (Docs inserts changes removes) =
    [ viewNonZero "Add:" inserts
    , viewNonZero "Change:" changes
    , viewNonZero "Remove:" removes
    ]
        |> List.concat
        |> D.vcat
        |> D.indent 2


{-| Returns a blank line, `title`, and `entries` indented by two spaces, or no
lines at all when `entries` is empty.
-}
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


{-| Renders `change` for package `name` and adds its line to the matching section.
Folding a plan's `Dict` from the right with this keeps each section in package
order.
-}
addChange : (a -> String) -> Widths -> Pkg.Name -> Change a -> ChangeDocs -> ChangeDocs
addChange toChars widths name change (Docs inserts changes removes) =
    case change of
        Insert new ->
            Docs (viewInsert toChars widths name new :: inserts) changes removes

        Change old new ->
            Docs inserts (viewChange toChars widths name old new :: changes) removes

        Remove old ->
            Docs inserts changes (viewRemove toChars widths name old :: removes)


{-| Renders a plan line for a package being added: its name, then its new value
right-aligned to the width of the old-value column.
-}
viewInsert : (a -> String) -> Widths -> Pkg.Name -> a -> D.Doc
viewInsert toChars (Widths nameWidth leftWidth _) name new =
    viewName nameWidth name
        |> D.plus (pad leftWidth (toChars new))


{-| Renders a plan line for a package whose value changes: its name, the old
value, an arrow, and the new value, with each value right-aligned to its
column's width.
-}
viewChange : (a -> String) -> Widths -> Pkg.Name -> a -> a -> D.Doc
viewChange toChars (Widths nameWidth leftWidth rightWidth) name old new =
    D.hsep
        [ viewName nameWidth name
        , pad leftWidth (toChars old)
        , D.fromChars "=>"
        , pad rightWidth (toChars new)
        ]


{-| Renders a plan line for a package being removed: its name, then its old value
right-aligned to the width of the old-value column.
-}
viewRemove : (a -> String) -> Widths -> Pkg.Name -> a -> D.Doc
viewRemove toChars (Widths nameWidth leftWidth _) name old =
    viewName nameWidth name
        |> D.plus (pad leftWidth (toChars old))


{-| Renders the package name of a plan line. `D.fill` indents rather than pads,
so the name is preceded by `width` plus three spaces and is not padded to a
column.
-}
viewName : Int -> Pkg.Name -> D.Doc
viewName width name =
    D.fill (width + 3) (D.fromPackage name)


{-| Renders `string` right-aligned to `width` by putting spaces before it. A
string already that wide or wider gets none.
-}
pad : Int -> String -> D.Doc
pad width string =
    D.fromChars (String.repeat (width - String.length string) " ")
        |> D.a (D.fromChars string)



-- ====== WIDTHS ======


{-| The column widths of a plan, in characters: the longest package name, the
longest old value (counting added packages' values too), and the longest new
value of a changed package.
-}
type Widths
    = Widths Int Int Int


{-| Returns the widths widened to fit the line `change` makes for `pkg`.
-}
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
