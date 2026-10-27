module Builder.Deps.Solver exposing
    ( Solver, SolverResult(..), State
    , Env(..), EnvData, Connection(..), initEnv
    , Details(..)
    , AppSolution(..), addToApp, removeFromApp
    , verify
    , envEncoder, envDecoder
    )

{-| A project names the packages it needs with version constraints, and each of
those packages names its own; this module picks one version of every package
involved so that all of those constraints hold at once.

A _constraint_ is a range of versions (`Compiler.Elm.Constraint`). Every package
version carries two kinds of them in its `elm.json`: the range of Elm versions it
works with, and a range for each package it depends on. The solver learns a
version's constraints only by reading that `elm.json`, so solving and fetching
are interleaved: a version's `elm.json` is read, usually from the package cache
or the package website, when the search considers that version.

The search is a backtracking depth-first search. It keeps a set of _pending_
packages, each with the constraint it must satisfy, and a set of _solved_ ones,
each with its chosen version. It takes the pending package whose name sorts
first and tries the registry's versions of it that satisfy its constraint, in
the order the registry lists them. A candidate is rejected unless its Elm
range admits a supported Elm (`Compiler.Elm.Constraint.goodElm`). Otherwise its
dependency constraints are merged into the pending set. A merge fails, and the
search _backtracks_ to the next candidate, when a dependency is already solved at
a version outside the new range, or when two ranges for the same pending package
have no overlap. When no candidate is left the failure passes up to the previous
choice. The search ends when nothing is pending.

Two things change what the search may use. A _local package_ is one linked into
the package cache from a directory on disk (`Builder.Stuff.localPackageSource`);
the solver offers it only at version 1.0.0 and reads its `elm.json` from that
directory. And whether the solver is _online_ (`Connection`) decides what it may
use: offline, a version is eligible only if its `elm.json` and its `src`
directory are already on disk where the solver looks for them (the package
cache, or a local package's own directory).

Most of this file is that search, written in a small state monad, `Solver`,
whose state carries the constraints read so far. Every entry point solves while
holding the package cache's registry lock (`Builder.Stuff.withRegistryLock`).


# Solver Types

@docs Solver, SolverResult, State


# Environment

@docs Env, EnvData, Connection, initEnv


# Dependency Details

@docs Details


# Application Solutions

@docs AppSolution, addToApp, removeFromApp


# Package Verification

@docs verify


# Serialization

@docs envEncoder, envDecoder

-}

import Builder.Deps.Registry as Registry
import Builder.Deps.Website as Website
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.Http as Http
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Bytes.Decode
import Bytes.Encode
import Compiler.Elm.Constraint as C
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Dict exposing (Dict)
import System.IO as IO
import Task exposing (Task)
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== SOLVER ======


{-| A step of the dependency search, which runs as a task and ends in one of
three ways: it succeeds with a value, it backtracks so that the next alternative
is tried, or it fails with an `Exit.Solver` error that ends the whole search.

A failure is not a backtrack. A package `elm.json` that cannot be downloaded or
decoded fails the search, while an unmet constraint, or a version that is
unavailable offline or not in the registry, backtracks.

-}
type Solver a
    = Solver (State -> Task Never (InnerSolver a))


{-| The outcome of running one `Solver` step, with the state it leaves.

`ISOk` is success with a value. `ISBack` means no choice made by this step
works and the caller's next alternative should be tried. `ISErr` ends the
search.

-}
type InnerSolver a
    = ISOk State a
    | ISBack State
    | ISErr Exit.Solver


{-| What the search carries from step to step: where to read packages from and
the constraints of every package version read so far.

`cDict` maps a package name and version, in their comparable forms, to that
version's constraints.

-}
type alias StateData =
    { cache : Stuff.PackageCache
    , connection : Connection
    , registry : Registry.Registry
    , cDict : Dict ( ( String, String ), ( Int, Int, Int ) ) Constraints
    }


{-| The state a `Solver` runs in. Each entry point starts one with no package
versions read yet.
-}
type State
    = State StateData


{-| What one package version's `elm.json` requires: the range of Elm versions,
then the range for each package it depends on.
-}
type Constraints
    = Constraints C.Constraint (Dict Pkg.Name C.Constraint)


{-| Whether the solver may use the network.

`Online` carries the HTTP manager used to download a package `elm.json` that
is not in the cache. `Offline` permits no download, and a version is then
eligible only when both its `elm.json` and its `src` directory are already on
disk where the solver looks for them (the package cache, or a local package's
own directory).

-}
type Connection
    = Online Http.Manager
    | Offline



-- ====== RESULT ======


{-| The outcome of a whole solve.

`SolverOk` carries the solution.

`NoSolution` and `NoOfflineSolution` both mean the search ran out of
alternatives. Which one is returned depends only on the connection the solve
ran with, `Online` or `Offline`, not on why the search failed.

`SolverErr` means the search stopped on an error: a package `elm.json` that
could not be downloaded, or that did not decode as a package outline. An
`elm.json` read from disk that does not decode is deleted before this is
returned.

-}
type SolverResult a
    = SolverOk a
    | NoSolution
    | NoOfflineSolution
    | SolverErr Exit.Solver



-- ====== VERIFY ======


{-| One package in a solution: the version chosen, and the dependency
constraints that version's `elm.json` declares.
-}
type Details
    = Details V.Version (Dict Pkg.Name C.Constraint)


{-| Solves `constraints` and returns `Details` for every package in the
solution, the indirect dependencies included.

The `Details` of a package holds the constraints its own `elm.json` declares on
its direct dependencies, not the versions chosen for them.

-}
verify : Stuff.PackageCache -> Connection -> Registry.Registry -> Dict Pkg.Name C.Constraint -> Task Never (SolverResult (Dict Pkg.Name Details))
verify cache connection registry constraints =
    Stuff.withRegistryLock cache <|
        case try constraints of
            Solver solver ->
                solver (State { cache = cache, connection = connection, registry = registry, cDict = Dict.empty })
                    |> Task.map
                        (\result ->
                            case result of
                                ISOk s a ->
                                    SolverOk (Dict.map (addDeps s) a)

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )


{-| Returns the `Details` of `name` at `vsn`, taking its dependency constraints
from those the search read. Crashes if the search never read them, which cannot
happen for a version the search chose.
-}
addDeps : State -> Pkg.Name -> V.Version -> Details
addDeps (State st) name vsn =
    case Dict.get (Tuple.mapSecond V.toComparable ( name, vsn )) st.cDict of
        Just (Constraints _ deps) ->
            Details vsn deps

        Nothing ->
            crash "compiler bug manifesting in Deps.Solver.addDeps"


{-| Returns the no-solution result that matches `connection`.
-}
noSolution : Connection -> SolverResult a
noSolution connection =
    case connection of
        Online _ ->
            NoSolution

        Offline ->
            NoOfflineSolution



-- ====== APP SOLUTION ======


{-| The result of changing an application's dependencies: every dependency
version before the change, every dependency version after it, and the
application outline rewritten to the new versions.

In the rewritten outline, the direct dependencies keep the packages the old
outline listed as direct, with the change applied. The indirect dependencies
are what the direct ones need and are not themselves direct. The test
dependencies, direct and indirect, are the rest of the solution.

-}
type AppSolution
    = AppSolution (Dict Pkg.Name V.Version) (Dict Pkg.Name V.Version) Outline.AppOutline


{-| Returns `visited` extended with every package reachable from `unvisited`
through the dependency constraints in `constraints`, each at its version in
`solution`.

A dependency that is not in `solution` is not followed. The packages in
`unvisited` are added even if `solution` does not contain them.

-}
getTransitive :
    Dict ( ( String, String ), ( Int, Int, Int ) ) Constraints
    -> Dict Pkg.Name V.Version
    -> List ( Pkg.Name, V.Version )
    -> Dict Pkg.Name V.Version
    -> Dict Pkg.Name V.Version
getTransitive constraints solution unvisited visited =
    case unvisited of
        [] ->
            visited

        (( pkg, vsn ) as info) :: infos ->
            if Dict.member pkg visited then
                getTransitive constraints solution infos visited

            else
                let
                    (Constraints _ newDeps) =
                        Utils.dictFind (Tuple.mapSecond V.toComparable info) constraints

                    newUnvisited : List ( Pkg.Name, V.Version )
                    newUnvisited =
                        Dict.toList (Dict.filter (\k _ -> Dict.member k (Dict.diff newDeps visited)) solution)

                    newVisited : Dict Pkg.Name V.Version
                    newVisited =
                        Dict.insert pkg vsn visited
                in
                getTransitive constraints solution newUnvisited newVisited |> getTransitive constraints solution infos



-- ====== ADD TO APP ======


{-| Solves the application's dependencies with `pkg` added at any version,
and returns the old and new versions with the rewritten outline.

The other packages are held as tightly as a solution allows. Each of these is
tried in turn, and the first that solves is used: every current dependency,
direct and indirect, at its exact version; the direct ones at their exact
versions; the direct ones up to their next minor version; up to their next
major version; and the direct ones at any version.

When `forTest` is true, `pkg` becomes a direct test dependency; otherwise it
becomes a direct dependency and is removed from the direct test dependencies.

-}
addToApp : Stuff.PackageCache -> Connection -> Registry.Registry -> Pkg.Name -> Outline.AppOutline -> Bool -> Task Never (SolverResult AppSolution)
addToApp cache connection registry pkg (Outline.AppOutline appData) forTest =
    Stuff.withRegistryLock cache <|
        let
            allIndirects : Dict Pkg.Name V.Version
            allIndirects =
                Dict.union appData.depsIndirect appData.testIndirect

            allDirects : Dict Pkg.Name V.Version
            allDirects =
                Dict.union appData.depsDirect appData.testDirect

            allDeps : Dict Pkg.Name V.Version
            allDeps =
                Dict.union allDirects allIndirects

            attempt : (a -> C.Constraint) -> Dict Pkg.Name a -> Solver (Dict Pkg.Name V.Version)
            attempt toConstraint deps =
                try (Dict.insert pkg C.anything (Dict.map (\_ -> toConstraint) deps))
        in
        case
            oneOf
                (attempt C.exactly allDeps)
                [ attempt C.exactly allDirects
                , attempt C.untilNextMinor allDirects
                , attempt C.untilNextMajor allDirects
                , attempt (\_ -> C.anything) allDirects
                ]
        of
            Solver solver ->
                solver (State { cache = cache, connection = connection, registry = registry, cDict = Dict.empty })
                    |> Task.map
                        (\result ->
                            case result of
                                ISOk (State st) new ->
                                    let
                                        d : Dict Pkg.Name V.Version
                                        d =
                                            if forTest then
                                                Dict.intersect new appData.depsDirect

                                            else
                                                Dict.intersect new (Dict.insert pkg V.one appData.depsDirect)

                                        i : Dict Pkg.Name V.Version
                                        i =
                                            Dict.diff (getTransitive st.cDict new (Dict.toList d) Dict.empty) d

                                        td : Dict Pkg.Name V.Version
                                        td =
                                            if forTest then
                                                Dict.intersect new (Dict.insert pkg V.one appData.testDirect)

                                            else
                                                Dict.intersect new (Dict.remove pkg appData.testDirect)

                                        ti : Dict Pkg.Name V.Version
                                        ti =
                                            Dict.diff new (List.foldr Dict.union Dict.empty [ d, i, td ])
                                    in
                                    SolverOk (AppSolution allDeps new (Outline.AppOutline { appData | depsDirect = d, depsIndirect = i, testDirect = td, testIndirect = ti }))

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )



-- ====== REMOVE FROM APP ======


{-| Solves the application's dependencies with `pkg` removed from the direct
ones, and returns the old and new versions with the rewritten outline.

Every other direct dependency, test ones included, is held at its exact
version. Indirect dependencies are not constrained, so they are re-solved, and
one that nothing needs any more drops out. If something else still needs `pkg`,
it stays, as an indirect dependency.

-}
removeFromApp : Stuff.PackageCache -> Connection -> Registry.Registry -> Pkg.Name -> Outline.AppOutline -> Task Never (SolverResult AppSolution)
removeFromApp cache connection registry pkg (Outline.AppOutline appData) =
    Stuff.withRegistryLock cache <|
        let
            allDirects : Dict Pkg.Name V.Version
            allDirects =
                Dict.union appData.depsDirect appData.testDirect
        in
        case try (Dict.map (\_ -> C.exactly) (Dict.remove pkg allDirects)) of
            Solver solver ->
                solver (State { cache = cache, connection = connection, registry = registry, cDict = Dict.empty })
                    |> Task.map
                        (\result ->
                            case result of
                                ISOk (State st) new ->
                                    let
                                        allIndirects : Dict Pkg.Name V.Version
                                        allIndirects =
                                            Dict.union appData.depsIndirect appData.testIndirect

                                        allDeps : Dict Pkg.Name V.Version
                                        allDeps =
                                            Dict.union allDirects allIndirects

                                        d : Dict Pkg.Name V.Version
                                        d =
                                            Dict.remove pkg appData.depsDirect

                                        i : Dict Pkg.Name V.Version
                                        i =
                                            Dict.diff (getTransitive st.cDict new (Dict.toList d) Dict.empty) d

                                        td : Dict Pkg.Name V.Version
                                        td =
                                            Dict.remove pkg appData.testDirect

                                        ti : Dict Pkg.Name V.Version
                                        ti =
                                            Dict.diff new (List.foldr Dict.union Dict.empty [ d, i, td ])
                                    in
                                    SolverOk (AppSolution allDeps new (Outline.AppOutline { appData | depsDirect = d, depsIndirect = i, testDirect = td, testIndirect = ti }))

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )



-- ====== TRY ======


{-| Produces the search for a version of every package in `constraints`, and of
every package they depend on, that satisfies all of the constraints.
-}
try : Dict Pkg.Name C.Constraint -> Solver (Dict Pkg.Name V.Version)
try constraints =
    exploreGoals (Goals constraints Dict.empty)



-- ====== EXPLORE GOALS ======


{-| The search's progress: the pending packages with the constraint each must
satisfy, then the solved packages with the version chosen for each.
-}
type Goals
    = Goals (Dict Pkg.Name C.Constraint) (Dict Pkg.Name V.Version)


{-| Produces the search that solves every pending package in `Goals`, taking them
in name order and trying each one's eligible versions in registry order, and returns
the solved set.
-}
exploreGoals : Goals -> Solver (Dict Pkg.Name V.Version)
exploreGoals (Goals pending solved) =
    case dictMinViewWithKey pending of
        Nothing ->
            pure solved

        Just ( ( name, constraint ), otherPending ) ->
            let
                goals1 : Goals
                goals1 =
                    Goals otherPending solved

                addVsn : V.Version -> Solver Goals
                addVsn =
                    addVersion goals1 name
            in
            getRelevantVersions name constraint
                |> andThen (\( v, vs ) -> oneOf (addVsn v) (List.map addVsn vs))
                |> andThen (\goals2 -> exploreGoals goals2)


{-| Produces the step that solves `name` at `version`: it backtracks if that
version's Elm range admits no supported Elm or a dependency constraint cannot be
merged in, and otherwise returns the goals with the dependency constraints added
to the pending set.
-}
addVersion : Goals -> Pkg.Name -> V.Version -> Solver Goals
addVersion (Goals pending solved) name version =
    getConstraints name version
        |> andThen
            (\(Constraints elm deps) ->
                if C.goodElm elm then
                    foldM (addConstraint solved) pending (Dict.toList deps)
                        |> map
                            (\newPending ->
                                Goals newPending (Dict.insert name version solved)
                            )

                else
                    backtrack
            )


{-| Produces the step that adds the constraint `newConstraint` on `name` to the
pending constraints `unsolved`.

It backtracks if `name` is already solved at a version outside the constraint,
or if the constraint and the pending one for `name` do not overlap. A pending
constraint is replaced by the intersection of the two.

-}
addConstraint : Dict Pkg.Name V.Version -> Dict Pkg.Name C.Constraint -> ( Pkg.Name, C.Constraint ) -> Solver (Dict Pkg.Name C.Constraint)
addConstraint solved unsolved ( name, newConstraint ) =
    case Dict.get name solved of
        Just version ->
            if C.satisfies newConstraint version then
                pure unsolved

            else
                backtrack

        Nothing ->
            case Dict.get name unsolved of
                Nothing ->
                    pure (Dict.insert name newConstraint unsolved)

                Just oldConstraint ->
                    case C.intersect oldConstraint newConstraint of
                        Nothing ->
                            backtrack

                        Just mergedConstraint ->
                            if oldConstraint == mergedConstraint then
                                pure unsolved

                            else
                                pure (Dict.insert name mergedConstraint unsolved)



-- ====== GET RELEVANT VERSIONS ======


{-| Produces the step that returns the versions of `name` satisfying
`constraint`, the first one apart, or backtracks if there are none.

A local package has only version 1.0.0. Any other package has the versions the
registry lists, in the registry's order; a package the registry does not list
backtracks.

-}
getRelevantVersions : Pkg.Name -> C.Constraint -> Solver ( V.Version, List V.Version )
getRelevantVersions name constraint =
    Solver <|
        \((State st) as state) ->
            if Stuff.isLocalPackage st.cache name then
                case List.filter (C.satisfies constraint) [ V.one ] of
                    [] ->
                        Task.succeed (ISBack state)

                    v :: vs ->
                        Task.succeed (ISOk state ( v, vs ))

            else
                case Registry.getVersions name st.registry of
                    Just (Registry.KnownVersions newest previous) ->
                        case List.filter (C.satisfies constraint) (newest :: previous) of
                            [] ->
                                Task.succeed (ISBack state)

                            v :: vs ->
                                Task.succeed (ISOk state ( v, vs ))

                    Nothing ->
                        Task.succeed (ISBack state)



-- ====== GET CONSTRAINTS ======


{-| Produces the step that returns the constraints of `pkg` at `vsn`, reading its
`elm.json` the first time and remembering it in the state.

The `elm.json` is read from the local package's directory for a local package,
and from the package cache otherwise. When it is not there, it is downloaded and
written to that same place; offline, a missing one backtracks instead.

-}
getConstraints : Pkg.Name -> V.Version -> Solver Constraints
getConstraints pkg vsn =
    Solver <|
        \((State st) as state) ->
            let
                key : ( Pkg.Name, V.Version )
                key =
                    ( pkg, vsn )
            in
            case Dict.get (Tuple.mapSecond V.toComparable key) st.cDict of
                Just cs ->
                    Task.succeed (ISOk state cs)

                Nothing ->
                    let
                        -- A local package may not be copied into the cache yet,
                        -- so its elm.json is read from its source directory.
                        home : String
                        home =
                            case Stuff.localPackageSource st.cache pkg of
                                Just source ->
                                    source

                                Nothing ->
                                    Stuff.package st.cache pkg vsn

                        ctx : ConstraintLoadContext
                        ctx =
                            { state = state
                            , cache = st.cache
                            , connection = st.connection
                            , registry = st.registry
                            , cDict = st.cDict
                            , key = key
                            , pkg = pkg
                            , vsn = vsn
                            , home = home
                            , path = home ++ "/elm.json"
                            }
                    in
                    File.exists ctx.path
                        |> Task.andThen (loadConstraintsFromCacheOrNetwork ctx)


{-| Everything the steps that load one package version's constraints need: the
state they started from, the package and version, and where its `elm.json` is.

`home` is the directory the `elm.json` and `src` are looked for in, and `path`
is the `elm.json` inside it.

-}
type alias ConstraintLoadContext =
    { state : State
    , cache : Stuff.PackageCache
    , connection : Connection
    , registry : Registry.Registry
    , cDict : Dict ( ( String, String ), ( Int, Int, Int ) ) Constraints
    , key : ( Pkg.Name, V.Version )
    , pkg : Pkg.Name
    , vsn : V.Version
    , home : String
    , path : String
    }


{-| Loads the constraints from `ctx.path` when `outlineExists`, and otherwise
from the package website, or backtracks when offline.
-}
loadConstraintsFromCacheOrNetwork : ConstraintLoadContext -> Bool -> Task Never (InnerSolver Constraints)
loadConstraintsFromCacheOrNetwork ctx outlineExists =
    if outlineExists then
        loadConstraintsFromCache ctx

    else
        loadConstraintsFromNetwork ctx


{-| Reads the `elm.json` at `ctx.path` and returns its constraints.
-}
loadConstraintsFromCache : ConstraintLoadContext -> Task Never (InnerSolver Constraints)
loadConstraintsFromCache ctx =
    File.readUtf8 ctx.path
        |> Task.andThen (parseAndValidateCachedConstraints ctx)


{-| Decodes the `elm.json` text `bytes` read from `ctx.path` and returns its constraints.

If it does not decode as a package outline, the file at `ctx.path` is deleted
and the search fails with `SolverBadCacheData`; it does not backtrack.

-}
parseAndValidateCachedConstraints : ConstraintLoadContext -> String -> Task Never (InnerSolver Constraints)
parseAndValidateCachedConstraints ctx bytes =
    case D.fromByteString constraintsDecoder bytes of
        Ok cs ->
            validateCachedConstraints ctx cs

        Err _ ->
            File.remove ctx.path
                |> Task.map (\_ -> ISErr (Exit.SolverBadCacheData ctx.pkg ctx.vsn))


{-| Returns `cs` with the state that remembers them.

Offline, it backtracks instead, from the state before they were read, when the
package has no `src` directory under `ctx.home`.

-}
validateCachedConstraints : ConstraintLoadContext -> Constraints -> Task Never (InnerSolver Constraints)
validateCachedConstraints ctx cs =
    let
        newState : State
        newState =
            State { cache = ctx.cache, connection = ctx.connection, registry = ctx.registry, cDict = Dict.insert (Tuple.mapSecond V.toComparable ctx.key) cs ctx.cDict }
    in
    case ctx.connection of
        Online _ ->
            Task.succeed (ISOk newState cs)

        Offline ->
            Utils.dirDoesDirectoryExist (ctx.home ++ "/src")
                |> Task.map (checkSrcExists ctx.state newState cs)


{-| Returns `cs` with `newState` if `srcExists`, and otherwise backtracks with
`oldState`.
-}
checkSrcExists : State -> State -> Constraints -> Bool -> InnerSolver Constraints
checkSrcExists oldState newState cs srcExists =
    if srcExists then
        ISOk newState cs

    else
        ISBack oldState


{-| Downloads the package version's `elm.json` and returns its constraints, or
backtracks when offline.
-}
loadConstraintsFromNetwork : ConstraintLoadContext -> Task Never (InnerSolver Constraints)
loadConstraintsFromNetwork ctx =
    case ctx.connection of
        Offline ->
            Task.succeed (ISBack ctx.state)

        Online manager ->
            Website.metadata ctx.pkg ctx.vsn "elm.json"
                |> Task.andThen (fetchAndCacheConstraints ctx manager)


{-| Downloads the `elm.json` at `url` and returns its constraints.
-}
fetchAndCacheConstraints : ConstraintLoadContext -> Http.Manager -> String -> Task Never (InnerSolver Constraints)
fetchAndCacheConstraints ctx manager url =
    Http.get manager url [] identity (Task.succeed << Ok)
        |> Task.andThen (handleHttpResult ctx url)


{-| Returns the constraints in the downloaded body, or fails the search with
`SolverBadHttp` when the download failed.
-}
handleHttpResult : ConstraintLoadContext -> String -> Result Http.Error String -> Task Never (InnerSolver Constraints)
handleHttpResult ctx url result =
    case result of
        Err httpProblem ->
            Task.succeed (ISErr (Exit.SolverBadHttp ctx.pkg ctx.vsn httpProblem))

        Ok body ->
            parseAndCacheConstraints ctx url body


{-| Decodes the downloaded `elm.json` `body` and caches it, or fails the search
with `SolverBadHttpData` when it does not decode as a package outline.
-}
parseAndCacheConstraints : ConstraintLoadContext -> String -> String -> Task Never (InnerSolver Constraints)
parseAndCacheConstraints ctx url body =
    case D.fromByteString constraintsDecoder body of
        Ok cs ->
            cacheConstraintsAndReturn ctx cs body

        Err _ ->
            Task.succeed (ISErr (Exit.SolverBadHttpData ctx.pkg ctx.vsn url))


{-| Writes `body` to `ctx.path`, creating `ctx.home` if needed, and returns `cs`
with the state that remembers them.
-}
cacheConstraintsAndReturn : ConstraintLoadContext -> Constraints -> String -> Task Never (InnerSolver Constraints)
cacheConstraintsAndReturn ctx cs body =
    let
        newState : State
        newState =
            State { cache = ctx.cache, connection = ctx.connection, registry = ctx.registry, cDict = Dict.insert (Tuple.mapSecond V.toComparable ctx.key) cs ctx.cDict }
    in
    Utils.dirCreateDirectoryIfMissing True ctx.home
        |> Task.andThen (\_ -> File.writeUtf8 ctx.path body)
        |> Task.map (\_ -> ISOk newState cs)


{-| A decoder for the constraints of a package `elm.json`. An application
`elm.json` fails to decode, as does anything `Outline.decoder` rejects.
-}
constraintsDecoder : D.Decoder () Constraints
constraintsDecoder =
    D.mapError (\_ -> ()) Outline.decoder
        |> D.andThen
            (\outline ->
                case outline of
                    Outline.Pkg (Outline.PkgOutline pkgData) ->
                        D.pure (Constraints pkgData.elm pkgData.deps)

                    Outline.App _ ->
                        D.failure ()
            )



-- ====== ENVIRONMENT ======


{-| What a command needs before it can solve: the package cache, an HTTP
manager, the connection to solve with, and the registry of known package
versions.

`manager` is present even when `connection` is `Offline`.

-}
type alias EnvData =
    { cache : Stuff.PackageCache
    , manager : Http.Manager
    , connection : Connection
    , registry : Registry.Registry
    }


{-| The solver environment, as `initEnv` builds it.
-}
type Env
    = Env EnvData


{-| Builds the solver environment: an HTTP manager, the package cache with the
local packages `locals` linked in, and the registry.

With no registry in the cache, the registry is downloaded, and a failure is the
error returned. With one, it is refreshed as `policy` and
`Builder.Deps.Registry.update` decide; if the refresh fails, the cached registry
is used and the environment is `Offline`. Otherwise the environment is
`Online`.

-}
initEnv : Registry.RegistryPolicy -> List ( Pkg.Name, IO.FilePath ) -> Task Never (Result Exit.RegistryProblem Env)
initEnv policy locals =
    Utils.newEmptyMVar
        |> Task.andThen (forkHttpManagerAndInitCache policy locals)


{-| Builds the environment as `initEnv` describes, creating the HTTP manager on a
separate thread that hands it over through `mvar`.
-}
forkHttpManagerAndInitCache : Registry.RegistryPolicy -> List ( Pkg.Name, IO.FilePath ) -> IO.MVar Http.Manager -> Task Never (Result Exit.RegistryProblem Env)
forkHttpManagerAndInitCache policy locals mvar =
    Utils.forkIO (Http.getManager |> Task.andThen (Utils.putMVar Http.managerEncoder mvar))
        |> Task.andThen (\_ -> Stuff.getPackageCache locals)
        |> Task.andThen (\cache -> initEnvWithCache policy cache mvar)


{-| Builds the environment over `cache`, reading its registry while holding
the registry lock.
-}
initEnvWithCache : Registry.RegistryPolicy -> Stuff.PackageCache -> IO.MVar Http.Manager -> Task Never (Result Exit.RegistryProblem Env)
initEnvWithCache policy cache mvar =
    Stuff.withRegistryLock cache
        (Registry.read cache
            |> Task.andThen (loadRegistry policy cache mvar)
        )


{-| Builds the environment from the cached registry `maybeRegistry`, waiting
for the HTTP manager in `mvar` first.
-}
loadRegistry : Registry.RegistryPolicy -> Stuff.PackageCache -> IO.MVar Http.Manager -> Maybe Registry.Registry -> Task Never (Result Exit.RegistryProblem Env)
loadRegistry policy cache mvar maybeRegistry =
    Utils.readMVar Http.managerDecoder mvar
        |> Task.andThen
            (\manager ->
                case maybeRegistry of
                    Nothing ->
                        fetchNewRegistry cache manager

                    Just cachedRegistry ->
                        updateCachedRegistry policy cache manager cachedRegistry
            )


{-| Builds an `Online` environment from a freshly downloaded registry, or
returns the download's error.
-}
fetchNewRegistry : Stuff.PackageCache -> Http.Manager -> Task Never (Result Exit.RegistryProblem Env)
fetchNewRegistry cache manager =
    Registry.fetch manager cache
        |> Task.map
            (\eitherRegistry ->
                case eitherRegistry of
                    Ok latestRegistry ->
                        Env { cache = cache, manager = manager, connection = Online manager, registry = latestRegistry } |> Ok

                    Err problem ->
                        Err problem
            )


{-| Builds an `Online` environment from `cachedRegistry` refreshed, or an
`Offline` one from `cachedRegistry` unchanged when the refresh fails.
-}
updateCachedRegistry : Registry.RegistryPolicy -> Stuff.PackageCache -> Http.Manager -> Registry.Registry -> Task Never (Result Exit.RegistryProblem Env)
updateCachedRegistry policy cache manager cachedRegistry =
    Registry.update manager cache policy cachedRegistry
        |> Task.map
            (\eitherRegistry ->
                case eitherRegistry of
                    Ok latestRegistry ->
                        Env { cache = cache, manager = manager, connection = Online manager, registry = latestRegistry } |> Ok

                    Err _ ->
                        Env { cache = cache, manager = manager, connection = Offline, registry = cachedRegistry } |> Ok
            )



-- ====== HELPERS ======


{-| Returns the entry with the smallest key and the dictionary without it, or
`Nothing` for an empty dictionary.
-}
dictMinViewWithKey : Dict comparable v -> Maybe ( ( comparable, v ), Dict comparable v )
dictMinViewWithKey dict =
    case Dict.toList dict of
        first :: tail ->
            Just ( first, Dict.fromList tail )

        [] ->
            Nothing



-- ====== INSTANCES ======


{-| Produces a step that applies `func` to the value of a successful one.
-}
map : (a -> b) -> Solver a -> Solver b
map func (Solver solver) =
    Solver <|
        \state ->
            solver state
                |> Task.map
                    (\result ->
                        case result of
                            ISOk stateA arg ->
                                ISOk stateA (func arg)

                            ISBack stateA ->
                                ISBack stateA

                            ISErr e ->
                                ISErr e
                    )


{-| Produces a step that succeeds with `a` and leaves the state unchanged.
-}
pure : a -> Solver a
pure a =
    Solver (\state -> Task.succeed (ISOk state a))


{-| Produces a step that runs `callback` on the value of a successful one. A
backtrack or an error is passed on without running it.
-}
andThen : (a -> Solver b) -> Solver a -> Solver b
andThen callback (Solver solverA) =
    Solver <|
        \state ->
            solverA state
                |> Task.andThen
                    (\resA ->
                        case resA of
                            ISOk stateA a ->
                                case callback a of
                                    Solver solverB ->
                                        solverB stateA

                            ISBack stateA ->
                                Task.succeed (ISBack stateA)

                            ISErr e ->
                                Task.succeed (ISErr e)
                    )


{-| Produces a step that tries `solver`, then each of `solvers` in turn while the
one before backtracks. Each alternative starts from the state the previous one
backtracked with. An error stops the search.
-}
oneOf : Solver a -> List (Solver a) -> Solver a
oneOf ((Solver solverHead) as solver) solvers =
    case solvers of
        [] ->
            solver

        s :: ss ->
            Solver <|
                \state0 ->
                    solverHead state0
                        |> Task.andThen
                            (\result ->
                                case result of
                                    ISOk stateA arg ->
                                        Task.succeed (ISOk stateA arg)

                                    ISBack stateA ->
                                        let
                                            (Solver solverTail) =
                                                oneOf s ss
                                        in
                                        solverTail stateA

                                    ISErr e ->
                                        Task.succeed (ISErr e)
                            )


{-| A step that backtracks, so that the next alternative is tried.
-}
backtrack : Solver a
backtrack =
    Solver <|
        \state ->
            Task.succeed (ISBack state)


{-| Produces a step that runs `f` over the list from the left, threading the
accumulator, and stops at the first backtrack or error.
-}
foldM : (b -> a -> Solver b) -> b -> List a -> Solver b
foldM f b =
    List.foldl (\a -> andThen (\acc -> f acc a)) (pure b)



-- ====== ENCODERS and DECODERS ======


{-| A binary encoder for an environment, which `envDecoder` reads back.
-}
envEncoder : Env -> Bytes.Encode.Encoder
envEncoder (Env env) =
    Bytes.Encode.sequence
        [ Stuff.packageCacheEncoder env.cache
        , Http.managerEncoder env.manager
        , connectionEncoder env.connection
        , Registry.registryEncoder env.registry
        ]


{-| A binary decoder for an environment written by `envEncoder`.
-}
envDecoder : Bytes.Decode.Decoder Env
envDecoder =
    Bytes.Decode.map4 (\cache manager connection registry -> Env { cache = cache, manager = manager, connection = connection, registry = registry })
        Stuff.packageCacheDecoder
        Http.managerDecoder
        connectionDecoder
        Registry.registryDecoder


{-| Produces a binary encoder for `connection`: a tag byte, 0 for `Online` followed
by its manager, and 1 for `Offline`.
-}
connectionEncoder : Connection -> Bytes.Encode.Encoder
connectionEncoder connection =
    case connection of
        Online manager ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Http.managerEncoder manager
                ]

        Offline ->
            Bytes.Encode.unsignedInt8 1


{-| A binary decoder for a connection written by `connectionEncoder`. Any
other tag fails.
-}
connectionDecoder : Bytes.Decode.Decoder Connection
connectionDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Online Http.managerDecoder

                    1 ->
                        Bytes.Decode.succeed Offline

                    _ ->
                        Bytes.Decode.fail
            )
