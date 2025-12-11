module Builder.Deps.Solver exposing
    ( AppSolution(..)
    , Connection(..)
    , Details(..)
    , Env(..)
    , EnvData
    , Solver
    , SolverResult(..)
    , State
    , StateData
    , addToApp
    , addToTestApp
    , envDecoder
    , envEncoder
    , initEnv
    , removeFromApp
    , verify
    )

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
import Data.Map as Dict exposing (Dict)
import Task exposing (Task)
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- SOLVER


type Solver a
    = Solver (State -> Task Never (InnerSolver a))


type InnerSolver a
    = ISOk State a
    | ISBack State
    | ISErr Exit.Solver


type alias StateData =
    { cache : Stuff.PackageCache
    , connection : Connection
    , registry : Registry.Registry
    , cDict : Dict ( ( String, String ), ( Int, Int, Int ) ) ( Pkg.Name, V.Version ) Constraints
    }


type State
    = State StateData


type Constraints
    = Constraints C.Constraint (Dict ( String, String ) Pkg.Name C.Constraint)


type Connection
    = Online Http.Manager
    | Offline



-- RESULT


type SolverResult a
    = SolverOk a
    | NoSolution
    | NoOfflineSolution
    | SolverErr Exit.Solver



-- VERIFY -- used by Elm.Details


type Details
    = Details V.Version (Dict ( String, String ) Pkg.Name C.Constraint)


verify : Stuff.PackageCache -> Connection -> Registry.Registry -> Dict ( String, String ) Pkg.Name C.Constraint -> Task Never (SolverResult (Dict ( String, String ) Pkg.Name Details))
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


addDeps : State -> Pkg.Name -> V.Version -> Details
addDeps (State st) name vsn =
    case Dict.get (Tuple.mapSecond V.toComparable) ( name, vsn ) st.cDict of
        Just (Constraints _ deps) ->
            Details vsn deps

        Nothing ->
            crash "compiler bug manifesting in Deps.Solver.addDeps"


noSolution : Connection -> SolverResult a
noSolution connection =
    case connection of
        Online _ ->
            NoSolution

        Offline ->
            NoOfflineSolution



-- APP SOLUTION


type AppSolution
    = AppSolution (Dict ( String, String ) Pkg.Name V.Version) (Dict ( String, String ) Pkg.Name V.Version) Outline.AppOutline


getTransitive :
    Dict ( ( String, String ), ( Int, Int, Int ) ) ( Pkg.Name, V.Version ) Constraints
    -> Dict ( String, String ) Pkg.Name V.Version
    -> List ( Pkg.Name, V.Version )
    -> Dict ( String, String ) Pkg.Name V.Version
    -> Dict ( String, String ) Pkg.Name V.Version
getTransitive constraints solution unvisited visited =
    case unvisited of
        [] ->
            visited

        (( pkg, vsn ) as info) :: infos ->
            if Dict.member identity pkg visited then
                getTransitive constraints solution infos visited

            else
                let
                    (Constraints _ newDeps) =
                        Utils.find (Tuple.mapSecond V.toComparable) info constraints

                    newUnvisited : List ( Pkg.Name, V.Version )
                    newUnvisited =
                        Dict.toList compare (Dict.intersection Pkg.compareName solution (Dict.diff newDeps visited))

                    newVisited : Dict ( String, String ) Pkg.Name V.Version
                    newVisited =
                        Dict.insert identity pkg vsn visited
                in
                getTransitive constraints solution newUnvisited newVisited |> getTransitive constraints solution infos



-- ADD TO APP - used in Install


addToApp : Stuff.PackageCache -> Connection -> Registry.Registry -> Pkg.Name -> Outline.AppOutline -> Bool -> Task Never (SolverResult AppSolution)
addToApp cache connection registry pkg (Outline.AppOutline appData) forTest =
    Stuff.withRegistryLock cache <|
        let
            allIndirects : Dict ( String, String ) Pkg.Name V.Version
            allIndirects =
                Dict.union appData.depsIndirect appData.testIndirect

            allDirects : Dict ( String, String ) Pkg.Name V.Version
            allDirects =
                Dict.union appData.depsDirect appData.testDirect

            allDeps : Dict ( String, String ) Pkg.Name V.Version
            allDeps =
                Dict.union allDirects allIndirects

            attempt : (a -> C.Constraint) -> Dict ( String, String ) Pkg.Name a -> Solver (Dict ( String, String ) Pkg.Name V.Version)
            attempt toConstraint deps =
                try (Dict.insert identity pkg C.anything (Dict.map (\_ -> toConstraint) deps))
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
                                        d : Dict ( String, String ) Pkg.Name V.Version
                                        d =
                                            if forTest then
                                                Dict.intersection Pkg.compareName new appData.depsDirect

                                            else
                                                Dict.intersection Pkg.compareName new (Dict.insert identity pkg V.one appData.depsDirect)

                                        i : Dict ( String, String ) Pkg.Name V.Version
                                        i =
                                            Dict.diff (getTransitive st.cDict new (Dict.toList compare d) Dict.empty) d

                                        td : Dict ( String, String ) Pkg.Name V.Version
                                        td =
                                            if forTest then
                                                Dict.intersection Pkg.compareName new (Dict.insert identity pkg V.one appData.testDirect)

                                            else
                                                Dict.intersection Pkg.compareName new (Dict.remove identity pkg appData.testDirect)

                                        ti : Dict ( String, String ) Pkg.Name V.Version
                                        ti =
                                            Dict.diff new (Utils.mapUnions [ d, i, td ])
                                    in
                                    SolverOk (AppSolution allDeps new (Outline.AppOutline { appData | depsDirect = d, depsIndirect = i, testDirect = td, testIndirect = ti }))

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )



-- ADD TO APP - used in Test


addToTestApp : Stuff.PackageCache -> Connection -> Registry.Registry -> Pkg.Name -> C.Constraint -> Outline.AppOutline -> Task Never (SolverResult AppSolution)
addToTestApp cache connection registry pkg con (Outline.AppOutline appData) =
    Stuff.withRegistryLock cache <|
        let
            allIndirects : Dict ( String, String ) Pkg.Name V.Version
            allIndirects =
                Dict.union appData.depsIndirect appData.testIndirect

            allDirects : Dict ( String, String ) Pkg.Name V.Version
            allDirects =
                Dict.union appData.depsDirect appData.testDirect

            allDeps : Dict ( String, String ) Pkg.Name V.Version
            allDeps =
                Dict.union allDirects allIndirects

            attempt : (a -> C.Constraint) -> Dict ( String, String ) Pkg.Name a -> Solver (Dict ( String, String ) Pkg.Name V.Version)
            attempt toConstraint deps =
                try (Dict.insert identity pkg con (Dict.map (\_ -> toConstraint) deps))
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
                                        d : Dict ( String, String ) Pkg.Name V.Version
                                        d =
                                            Dict.intersection Pkg.compareName new (Dict.insert identity pkg V.one appData.depsDirect)

                                        i : Dict ( String, String ) Pkg.Name V.Version
                                        i =
                                            Dict.diff (getTransitive st.cDict new (Dict.toList compare d) Dict.empty) d

                                        td : Dict ( String, String ) Pkg.Name V.Version
                                        td =
                                            Dict.intersection Pkg.compareName new (Dict.remove identity pkg appData.testDirect)

                                        ti : Dict ( String, String ) Pkg.Name V.Version
                                        ti =
                                            Dict.diff new (Utils.mapUnions [ d, i, td ])
                                    in
                                    SolverOk (AppSolution allDeps new (Outline.AppOutline { appData | depsDirect = d, depsIndirect = i, testDirect = td, testIndirect = ti }))

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )



-- REMOVE FROM APP - used in Uninstall


removeFromApp : Stuff.PackageCache -> Connection -> Registry.Registry -> Pkg.Name -> Outline.AppOutline -> Task Never (SolverResult AppSolution)
removeFromApp cache connection registry pkg (Outline.AppOutline appData) =
    Stuff.withRegistryLock cache <|
        let
            allDirects : Dict ( String, String ) Pkg.Name V.Version
            allDirects =
                Dict.union appData.depsDirect appData.testDirect
        in
        case try (Dict.map (\_ -> C.exactly) (Dict.remove identity pkg allDirects)) of
            Solver solver ->
                solver (State { cache = cache, connection = connection, registry = registry, cDict = Dict.empty })
                    |> Task.map
                        (\result ->
                            case result of
                                ISOk (State st) new ->
                                    let
                                        allIndirects : Dict ( String, String ) Pkg.Name V.Version
                                        allIndirects =
                                            Dict.union appData.depsIndirect appData.testIndirect

                                        allDeps : Dict ( String, String ) Pkg.Name V.Version
                                        allDeps =
                                            Dict.union allDirects allIndirects

                                        d : Dict ( String, String ) Pkg.Name V.Version
                                        d =
                                            Dict.remove identity pkg appData.depsDirect

                                        i : Dict ( String, String ) Pkg.Name V.Version
                                        i =
                                            Dict.diff (getTransitive st.cDict new (Dict.toList compare d) Dict.empty) d

                                        td : Dict ( String, String ) Pkg.Name V.Version
                                        td =
                                            Dict.remove identity pkg appData.testDirect

                                        ti : Dict ( String, String ) Pkg.Name V.Version
                                        ti =
                                            Dict.diff new (Utils.mapUnions [ d, i, td ])
                                    in
                                    SolverOk (AppSolution allDeps new (Outline.AppOutline { appData | depsDirect = d, depsIndirect = i, testDirect = td, testIndirect = ti }))

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )



-- TRY


try : Dict ( String, String ) Pkg.Name C.Constraint -> Solver (Dict ( String, String ) Pkg.Name V.Version)
try constraints =
    exploreGoals (Goals constraints Dict.empty)



-- EXPLORE GOALS


type Goals
    = Goals (Dict ( String, String ) Pkg.Name C.Constraint) (Dict ( String, String ) Pkg.Name V.Version)


exploreGoals : Goals -> Solver (Dict ( String, String ) Pkg.Name V.Version)
exploreGoals (Goals pending solved) =
    let
        compare : ( Pkg.Name, C.Constraint ) -> Pkg.Name
        compare =
            Tuple.first
    in
    case Utils.mapMinViewWithKey identity Basics.compare compare pending of
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


addVersion : Goals -> Pkg.Name -> V.Version -> Solver Goals
addVersion (Goals pending solved) name version =
    getConstraints name version
        |> andThen
            (\(Constraints elm deps) ->
                if C.goodElm elm then
                    foldM (addConstraint solved) pending (Dict.toList compare deps)
                        |> map
                            (\newPending ->
                                Goals newPending (Dict.insert identity name version solved)
                            )

                else
                    backtrack
            )


addConstraint : Dict ( String, String ) Pkg.Name V.Version -> Dict ( String, String ) Pkg.Name C.Constraint -> ( Pkg.Name, C.Constraint ) -> Solver (Dict ( String, String ) Pkg.Name C.Constraint)
addConstraint solved unsolved ( name, newConstraint ) =
    case Dict.get identity name solved of
        Just version ->
            if C.satisfies newConstraint version then
                pure unsolved

            else
                backtrack

        Nothing ->
            case Dict.get identity name unsolved of
                Nothing ->
                    pure (Dict.insert identity name newConstraint unsolved)

                Just oldConstraint ->
                    case C.intersect oldConstraint newConstraint of
                        Nothing ->
                            backtrack

                        Just mergedConstraint ->
                            if oldConstraint == mergedConstraint then
                                pure unsolved

                            else
                                pure (Dict.insert identity name mergedConstraint unsolved)



-- GET RELEVANT VERSIONS


getRelevantVersions : Pkg.Name -> C.Constraint -> Solver ( V.Version, List V.Version )
getRelevantVersions name constraint =
    Solver <|
        \((State st) as state) ->
            case Registry.getVersions name st.registry of
                Just (Registry.KnownVersions newest previous) ->
                    case List.filter (C.satisfies constraint) (newest :: previous) of
                        [] ->
                            Task.succeed (ISBack state)

                        v :: vs ->
                            Task.succeed (ISOk state ( v, vs ))

                Nothing ->
                    Task.succeed (ISBack state)



-- GET CONSTRAINTS


getConstraints : Pkg.Name -> V.Version -> Solver Constraints
getConstraints pkg vsn =
    Solver <|
        \((State st) as state) ->
            let
                key : ( Pkg.Name, V.Version )
                key =
                    ( pkg, vsn )
            in
            case Dict.get (Tuple.mapSecond V.toComparable) key st.cDict of
                Just cs ->
                    Task.succeed (ISOk state cs)

                Nothing ->
                    let
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
                            , home = Stuff.package st.cache pkg vsn
                            , path = Stuff.package st.cache pkg vsn ++ "/elm.json"
                            }
                    in
                    File.exists ctx.path
                        |> Task.andThen (loadConstraintsFromCacheOrNetwork ctx)


type alias ConstraintLoadContext =
    { state : State
    , cache : Stuff.PackageCache
    , connection : Connection
    , registry : Registry.Registry
    , cDict : Dict ( ( String, String ), ( Int, Int, Int ) ) ( Pkg.Name, V.Version ) Constraints
    , key : ( Pkg.Name, V.Version )
    , pkg : Pkg.Name
    , vsn : V.Version
    , home : String
    , path : String
    }


loadConstraintsFromCacheOrNetwork : ConstraintLoadContext -> Bool -> Task Never (InnerSolver Constraints)
loadConstraintsFromCacheOrNetwork ctx outlineExists =
    if outlineExists then
        loadConstraintsFromCache ctx

    else
        loadConstraintsFromNetwork ctx


loadConstraintsFromCache : ConstraintLoadContext -> Task Never (InnerSolver Constraints)
loadConstraintsFromCache ctx =
    File.readUtf8 ctx.path
        |> Task.andThen (parseAndValidateCachedConstraints ctx)


parseAndValidateCachedConstraints : ConstraintLoadContext -> String -> Task Never (InnerSolver Constraints)
parseAndValidateCachedConstraints ctx bytes =
    case D.fromByteString constraintsDecoder bytes of
        Ok cs ->
            validateCachedConstraints ctx cs

        Err _ ->
            File.remove ctx.path
                |> Task.map (\_ -> ISErr (Exit.SolverBadCacheData ctx.pkg ctx.vsn))


validateCachedConstraints : ConstraintLoadContext -> Constraints -> Task Never (InnerSolver Constraints)
validateCachedConstraints ctx cs =
    let
        newState : State
        newState =
            State { cache = ctx.cache, connection = ctx.connection, registry = ctx.registry, cDict = Dict.insert (Tuple.mapSecond V.toComparable) ctx.key cs ctx.cDict }
    in
    case ctx.connection of
        Online _ ->
            Task.succeed (ISOk newState cs)

        Offline ->
            Utils.dirDoesDirectoryExist (ctx.home ++ "/src")
                |> Task.map (checkSrcExists ctx.state newState cs)


checkSrcExists : State -> State -> Constraints -> Bool -> InnerSolver Constraints
checkSrcExists oldState newState cs srcExists =
    if srcExists then
        ISOk newState cs

    else
        ISBack oldState


loadConstraintsFromNetwork : ConstraintLoadContext -> Task Never (InnerSolver Constraints)
loadConstraintsFromNetwork ctx =
    case ctx.connection of
        Offline ->
            Task.succeed (ISBack ctx.state)

        Online manager ->
            Website.metadata ctx.pkg ctx.vsn "elm.json"
                |> Task.andThen (fetchAndCacheConstraints ctx manager)


fetchAndCacheConstraints : ConstraintLoadContext -> Http.Manager -> String -> Task Never (InnerSolver Constraints)
fetchAndCacheConstraints ctx manager url =
    Http.get manager url [] identity (Task.succeed << Ok)
        |> Task.andThen (handleHttpResult ctx url)


handleHttpResult : ConstraintLoadContext -> String -> Result Http.Error String -> Task Never (InnerSolver Constraints)
handleHttpResult ctx url result =
    case result of
        Err httpProblem ->
            Task.succeed (ISErr (Exit.SolverBadHttp ctx.pkg ctx.vsn httpProblem))

        Ok body ->
            parseAndCacheConstraints ctx url body


parseAndCacheConstraints : ConstraintLoadContext -> String -> String -> Task Never (InnerSolver Constraints)
parseAndCacheConstraints ctx url body =
    case D.fromByteString constraintsDecoder body of
        Ok cs ->
            cacheConstraintsAndReturn ctx cs body

        Err _ ->
            Task.succeed (ISErr (Exit.SolverBadHttpData ctx.pkg ctx.vsn url))


cacheConstraintsAndReturn : ConstraintLoadContext -> Constraints -> String -> Task Never (InnerSolver Constraints)
cacheConstraintsAndReturn ctx cs body =
    let
        newState : State
        newState =
            State { cache = ctx.cache, connection = ctx.connection, registry = ctx.registry, cDict = Dict.insert (Tuple.mapSecond V.toComparable) ctx.key cs ctx.cDict }
    in
    Utils.dirCreateDirectoryIfMissing True ctx.home
        |> Task.andThen (\_ -> File.writeUtf8 ctx.path body)
        |> Task.map (\_ -> ISOk newState cs)


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



-- ENVIRONMENT


type alias EnvData =
    { cache : Stuff.PackageCache
    , manager : Http.Manager
    , connection : Connection
    , registry : Registry.Registry
    }


type Env
    = Env EnvData


initEnv : Task Never (Result Exit.RegistryProblem Env)
initEnv =
    Utils.newEmptyMVar
        |> Task.andThen forkHttpManagerAndInitCache


forkHttpManagerAndInitCache : Utils.MVar Http.Manager -> Task Never (Result Exit.RegistryProblem Env)
forkHttpManagerAndInitCache mvar =
    Utils.forkIO (Http.getManager |> Task.andThen (Utils.putMVar Http.managerEncoder mvar))
        |> Task.andThen (\_ -> Stuff.getPackageCache)
        |> Task.andThen (\cache -> initEnvWithCache cache mvar)


{-| Initialize environment with a package cache.
-}
initEnvWithCache : Stuff.PackageCache -> Utils.MVar Http.Manager -> Task Never (Result Exit.RegistryProblem Env)
initEnvWithCache cache mvar =
    Stuff.withRegistryLock cache
        (Registry.read cache
            |> Task.andThen (loadRegistry cache mvar)
        )


{-| Load or fetch the registry.
-}
loadRegistry : Stuff.PackageCache -> Utils.MVar Http.Manager -> Maybe Registry.Registry -> Task Never (Result Exit.RegistryProblem Env)
loadRegistry cache mvar maybeRegistry =
    Utils.readMVar Http.managerDecoder mvar
        |> Task.andThen
            (\manager ->
                case maybeRegistry of
                    Nothing ->
                        fetchNewRegistry cache manager

                    Just cachedRegistry ->
                        updateCachedRegistry cache manager cachedRegistry
            )


{-| Fetch a new registry when none is cached.
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


{-| Update a cached registry, falling back to offline mode on failure.
-}
updateCachedRegistry : Stuff.PackageCache -> Http.Manager -> Registry.Registry -> Task Never (Result Exit.RegistryProblem Env)
updateCachedRegistry cache manager cachedRegistry =
    Registry.update manager cache cachedRegistry
        |> Task.map
            (\eitherRegistry ->
                case eitherRegistry of
                    Ok latestRegistry ->
                        Env { cache = cache, manager = manager, connection = Online manager, registry = latestRegistry } |> Ok

                    Err _ ->
                        Env { cache = cache, manager = manager, connection = Offline, registry = cachedRegistry } |> Ok
            )



-- INSTANCES


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


pure : a -> Solver a
pure a =
    Solver (\state -> Task.succeed (ISOk state a))


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


backtrack : Solver a
backtrack =
    Solver <|
        \state ->
            Task.succeed (ISBack state)


foldM : (b -> a -> Solver b) -> b -> List a -> Solver b
foldM f b =
    List.foldl (\a -> andThen (\acc -> f acc a)) (pure b)



-- ENCODERS and DECODERS


envEncoder : Env -> Bytes.Encode.Encoder
envEncoder (Env env) =
    Bytes.Encode.sequence
        [ Stuff.packageCacheEncoder env.cache
        , Http.managerEncoder env.manager
        , connectionEncoder env.connection
        , Registry.registryEncoder env.registry
        ]


envDecoder : Bytes.Decode.Decoder Env
envDecoder =
    Bytes.Decode.map4 (\cache manager connection registry -> Env { cache = cache, manager = manager, connection = connection, registry = registry })
        Stuff.packageCacheDecoder
        Http.managerDecoder
        connectionDecoder
        Registry.registryDecoder


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
