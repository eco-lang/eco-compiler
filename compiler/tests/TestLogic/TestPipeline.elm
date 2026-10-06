module TestLogic.TestPipeline exposing
    ( CanonicalArtifacts
    , GlobalOptArtifacts
    , MlirArtifacts
    , MonoArtifacts
    , PostSolveArtifacts
    , TypeCheckArtifacts
    , TypedOptArtifacts
    , expectCoverageRun
    , expectMLIRGeneration
    , expectMonomorphization
    , interfaceAnnotations
    , runSolverMonoWithLimits
    , runSolverMonoWithLimitsNoPreMono
    , runSolverMonoWithReport
    , runSolverMonoWithReportNoPreMono
    , runSubstMonoWithLimits
    , runToAssigned
    , runToGlobalOpt
    , runToGlobalOptNoPreMono
    , runToGlobalOptStage5
    , runToMlir
    , runToMlirNoPreMono
    , runToMlirStage5
    , runToMono
    , runToMonoNoPreMono
    , runToMonoStage5
    , productionConfig
    , stage5Config
    , runToPostSolve
    , runToTypeCheck
    , runToTypedOpt
    , stampLikeCompile
    )

{-| Drives one test program through the compiler to a chosen stage, so that
every pipeline test builds its input the same way instead of assembling the
stages itself.

A test program is a `Src.Module`, and it is compiled against a mock
environment instead of real packages. It is canonicalized as a module of the
package `eco/example` against `Compiler.Elm.Interface.Basic.testIfaces`, the
hand-written interfaces of 18 modules (`Basics`, `List`, `Maybe`, `Html` and
others). Because `eco` is a kernel-package author, an `Elm.Kernel.*` reference
in a test program canonicalizes to a kernel reference. Where a build would
merge the compiled graphs of the dependencies, this module synthesizes what
monomorphization needs from the interfaces: an annotation for every interface
value, operator and constructor, and a real node only for the kernel aliases
listed in `aliasedKernels`. Any other dependency global has an annotation and
no node.

`runToCanonical`, `runToTypeCheck`, `runToPostSolve`, `runToTypedOpt`,
`runToMono`, `runToGlobalOpt` and `runToMlir` (and their `Stage5` and
`NoPreMono` variants) return the _cumulative artifacts_ of their stage: one
record holding that stage's output together with the outputs of the earlier
stages it ran, so that a test can inspect any of them. `runToAssigned` and the
three `run*MonoWith*` functions return only their own stage's result. A stage
that fails gives `Err` with a message; for canonicalization and type checking
it carries only a count of errors, and for typed optimization nothing about
the error. A stage that crashes is not caught.

From `runToTypedOpt` on, the program is first given a _synthetic main_:
`wrapWithMain` appends a `main` that returns
`Html.text (Elm.Kernel.Debug.toString testValue)`. That `main` is a valid entry point for the typed
optimizer, and it makes `testValue` reachable from the entry point that
monomorphization starts at. A program run through these stages must define
`testValue`, or the test run crashes. `runToCanonical`, `runToTypeCheck` and
`runToPostSolve` do not add a `main`.

**Tests compile the way production compiles**
(plans/staging-honesty-and-production-test-pipeline.md P1). From typed
optimization on, every runner calls the build's own steps,
`Compiler.Pipeline.Steps`, which `Builder.Generate` also calls, under a whole
`EcoConfig`:

  - `runToMono`, `runToGlobalOpt`, `runToMlir` use `productionConfig`
    (`Config.default`): the solver engine with lambda-set specialization,
    alias forwarding and η-expansion before monomorphization, the
    post-inline prune, and global optimization with its CSE / CAF steps as
    configured. MLIR is generated with the build's code generator context, in
    development mode (`eco make` without `--optimize`).
  - the `Stage5` variants use `stage5Config`, the substitution engine, which
    is how bootstrap Stage 5 compiles.
  - the `NoPreMono` variants skip the pre-monomorphization passes. They are
    not a production pipeline; a test uses one only to exercise a later pass
    on input those passes would have rewritten, and says why.
  - `runSolverMonoWithLimits`, `runSolverMonoWithReport` and
    `runSubstMonoWithLimits` stop after monomorphization under the given
    watchdog limits.

What remains different from a build is the input, not the pipeline: the
program is compiled against mock package interfaces rather than real
packages, the pattern match checker is not run, and MLIR is generated as one
module rather than streamed. `test/scripts/check-test-pipeline-production.sh`
fails the `elm-tests` target if this module ever calls a compiler pass other
than through `Compiler.Pipeline.Steps`.

-}

import Array exposing (Array)
import Builder.GraphAssembly as GA
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Eco.Config as Config
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.MLIR.Backend as MLIR
import Compiler.Generate.Mode as Mode
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Pipeline.Steps as Steps
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Compiler.Type.SolverRoots as SolverRoots
import Compiler.TypedCanonical.Build as TCanBuild
import Data.Map
import Data.Set
import Dict exposing (Dict)
import Expect
import Mlir.Mlir exposing (MlirModule)
import System.TypeCheck.IO as IO



-- ============================================================================
-- CUMULATIVE ARTIFACT TYPES
-- ============================================================================


{-| The cumulative artifacts of canonicalization: the canonical module.
-}
type alias CanonicalArtifacts =
    { canonical : Can.Module
    }


{-| The cumulative artifacts of type checking with node ids: the canonical
module and what `Compiler.Type.Solve.runWithIds` returns for it.

`annotations` and `annotationVars` have no entries for let-bound names.
`nodeTypes` and `nodeVars` are indexed by node id, and `nodeTypes` is as the
solver left it, before PostSolve. `solverState` is a snapshot of the solver's
point store, taken when solving finished; it is what later resolves a
variable in `nodeVars` or `annotationVars` to its union-find root.
`schemeBinderVars` is what `constrainWithIds` records for each annotated
definition: the solver variable of each type variable its annotation binds.

-}
type alias TypeCheckArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , nodeTypes : Array (Maybe (Can.Type Name))
    , nodeVars : Array (Maybe Vars.Variable)
    , solverState : { cells : Array Vars.PointCell }
    , annotationVars : Dict Name.Name Vars.Variable
    , schemeBinderVars : Dict Name.Name (Dict Name.Name Vars.Variable)
    }


{-| The cumulative artifacts of PostSolve: the type checking artifacts, with the
node types both before and after `Compiler.Type.PostSolve.postSolve` and the
kernel type environment it builds.
-}
type alias PostSolveArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , nodeTypesPre : PostSolve.NodeTypes
    , nodeTypesPost : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , nodeVars : Array (Maybe Vars.Variable)
    , solverState : { cells : Array Vars.PointCell }
    , annotationVars : Dict Name.Name Vars.Variable
    , schemeBinderVars : Dict Name.Name (Dict Name.Name Vars.Variable)
    }


{-| The cumulative artifacts of typed optimization: the module's typed local
graph, with the canonical module, annotations, node types and kernel type
environment it was built from.

These are artifacts of the program with the synthetic `main` added, so
`canonical` and `annotations` include `main`. `annotations` and `nodeTypes`
are the `annotations` and `nodeTypesPost` of the PostSolve artifacts with
solver roots stamped into their arrows, so they can differ from those fields
of `PostSolveArtifacts`. The solver variables are not carried on.

-}
type alias TypedOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph Name
    }


{-| The cumulative artifacts of monomorphization: the typed optimization
artifacts, the global graph and global type environment built from them and
the mock interfaces, and the monomorphized graph.

`globalGraph` is the input monomorphization was given: the program's local
graph plus an annotation for every mock-interface value, operator and
constructor and a node for each kernel alias in `aliasedKernels`. `monoGraph`
comes from the engine of the runner's configuration.

-}
type alias MonoArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph Name
    , globalGraph : TOpt.GlobalGraph Name
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    }


{-| The cumulative artifacts of global optimization: the monomorphization
artifacts plus `optimizedMonoGraph`, the result of running the
post-monomorphization inliner and then
`Compiler.GlobalOpt.MonoGlobalOptimize.globalOptimize` on `monoGraph`.

`monoGraph` is the graph before both passes, from the engine of the runner's
configuration.

-}
type alias GlobalOptArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph Name
    , globalGraph : TOpt.GlobalGraph Name
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    , optimizedMonoGraph : Mono.MonoGraph
    }


{-| The cumulative artifacts of MLIR generation: the global optimization
artifacts, without the unoptimized graph, plus the generated MLIR module and
its text.

`monoGraph` here holds the graph after global optimization, the one MLIR was
generated from, unlike the field of the same name in `MonoArtifacts` and
`GlobalOptArtifacts`. `mlirOutput` is the same graph generated again and
printed as text.

-}
type alias MlirArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , nodeTypes : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , localGraph : TOpt.LocalGraph Name
    , globalGraph : TOpt.GlobalGraph Name
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , monoGraph : Mono.MonoGraph
    , mlirModule : MlirModule
    , mlirOutput : String
    }



-- ============================================================================
-- PIPELINE ENTRY POINTS
-- ============================================================================


{-| Canonicalizes `srcModule` as a module of the package `eco/example`
against the mock interfaces. An `Err` gives only the number of errors.
-}
runToCanonical : Src.Module -> Result String CanonicalArtifacts
runToCanonical srcModule =
    let
        canonResult =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule
    in
    case RResult.run canonResult of
        ( _, Err errors ) ->
            let
                errorCount =
                    OneOrMore.destruct (::) errors |> List.length
            in
            Err ("Canonicalization failed with " ++ String.fromInt errorCount ++ " error(s)")

        ( _, Ok canonical ) ->
            Ok { canonical = canonical }


{-| Canonicalizes `srcModule` and type checks it with node ids recorded, as
the typed path does. An `Err` from type checking gives only the number of
errors.
-}
runToTypeCheck : Src.Module -> Result String TypeCheckArtifacts
runToTypeCheck srcModule =
    case runToCanonical srcModule of
        Err e ->
            Err e

        Ok { canonical } ->
            case IO.unsafePerformIO (runWithIdsTypeCheck canonical) of
                Err errCount ->
                    Err ("Type checking failed with " ++ String.fromInt errCount ++ " error(s)")

                Ok { annotations, nodeTypes, nodeVars, solverState, annotationVars, schemeBinderVars } ->
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypes
                        , nodeVars = nodeVars
                        , solverState = solverState
                        , annotationVars = annotationVars
                        , schemeBinderVars = schemeBinderVars
                        }


{-| Runs `runToTypeCheck` on `srcModule` and then PostSolve on its node types,
keeping the node types from both before and after.
-}
runToPostSolve : Src.Module -> Result String PostSolveArtifacts
runToPostSolve srcModule =
    case runToTypeCheck srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, nodeVars, solverState, annotationVars, schemeBinderVars } ->
            let
                postSolveResult =
                    PostSolve.postSolve
                        annotations
                        canonical
                        nodeTypes
            in
            Ok
                { canonical = canonical
                , annotations = annotations
                , nodeTypesPre = nodeTypes
                , nodeTypesPost = postSolveResult.nodeTypes
                , kernelEnv = postSolveResult.kernelEnv
                , nodeVars = nodeVars
                , solverState = solverState
                , annotationVars = annotationVars
                , schemeBinderVars = schemeBinderVars
                }


{-| Adds the synthetic `main` to `srcModule` with `wrapWithMain`, runs it
through PostSolve, and builds its typed local graph.

Between PostSolve and the typed optimizer it does what `Compiler.Compile`
does at that point, through `stampLikeCompile`: it resolves the node and
annotation variables to their union-find roots, stamps solver roots into the
arrows of the node types and annotations, and gives the typed optimizer the
normalized scheme roots of every definition. Without this step every arrow in
a test program would carry `NoArrow`, and the solver engine, which gives
arrows that share a solver root one identity, would find none to share.

Any error from the typed optimizer gives the same `Err` message.

-}
runToTypedOpt : Src.Module -> Result String TypedOptArtifacts
runToTypedOpt srcModule =
    case runToPostSolve (wrapWithMain srcModule) of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypesPost, kernelEnv, nodeVars, solverState, annotationVars, schemeBinderVars } ->
            let
                stamped =
                    stampLikeCompile
                        { solverState = solverState
                        , annotations = annotations
                        , annotationVars = annotationVars
                        , nodeTypes = nodeTypesPost
                        , nodeVars = nodeVars
                        , schemeBinderVars = schemeBinderVars
                        }

                stampedAnnotations =
                    stamped.annotations

                stampedNodeTypes =
                    stamped.nodeTypes

                typedModule =
                    TCanBuild.fromCanonical canonical stampedNodeTypes stamped.nodeVars
            in
            case RResult.run (TypedOptimize.optimizeTyped stampedAnnotations stampedNodeTypes stamped.nodeVars kernelEnv stamped.annotationVars stamped.schemeRoots typedModule) of
                ( _, Ok localGraph ) ->
                    Ok
                        { canonical = canonical
                        , annotations = stampedAnnotations
                        , nodeTypes = stampedNodeTypes
                        , kernelEnv = kernelEnv
                        , localGraph = localGraph
                        }

                ( _, Err _ ) ->
                    Err "Typed optimization produced an error"


{-| Does what `Compiler.Compile.typeCheckTyped` does between PostSolve and the
typed optimizer, which that module does not expose: resolves the node and
annotation variables to their union-find roots, stamps each node type and each
annotation with the solver roots of its arrows, and computes the scheme roots
the typed optimizer is given. A definition's scheme roots are the normalized
`schemeBinderVars` when its annotation is written, and otherwise the binder
roots extracted from its inferred annotation, if there are any.

`nodeTypes` are the node types after PostSolve. This must stay in step with
`Compiler.Compile`; nothing checks that it does.

-}
stampLikeCompile :
    { solverState : { cells : Array Vars.PointCell }
    , annotations : Dict Name.Name (Can.Annotation Name)
    , annotationVars : Dict Name.Name Vars.Variable
    , nodeTypes : Array (Maybe (Can.Type Name))
    , nodeVars : Array (Maybe Vars.Variable)
    , schemeBinderVars : Dict Name.Name (Dict Name.Name Vars.Variable)
    }
    ->
        { annotations : Dict Name.Name (Can.Annotation Name)
        , annotationVars : Dict Name.Name Vars.Variable
        , nodeTypes : Array (Maybe (Can.Type Name))
        , nodeVars : Array (Maybe Vars.Variable)
        , schemeRoots : SolverRoots.AllSchemeRoots
        }
stampLikeCompile input =
    let
        solverState =
            input.solverState

        rootedNodeVars =
            SolverRoots.normalizeNodeVars solverState input.nodeVars

        rootedAnnotationVars =
            SolverRoots.normalizeAnnotationVars solverState input.annotationVars

        annotatedSchemeRoots =
            SolverRoots.normalizeAllSchemeRoots solverState input.schemeBinderVars

        schemeRoots =
            Dict.foldl
                (\defName annotation acc ->
                    if Dict.member defName annotatedSchemeRoots then
                        acc

                    else
                        case Dict.get defName input.annotationVars of
                            Just annotVar ->
                                let
                                    roots =
                                        SolverRoots.extractBinderRootsFromInferred solverState annotation annotVar
                                in
                                if Dict.isEmpty roots then
                                    acc

                                else
                                    Dict.insert defName roots acc

                            Nothing ->
                                acc
                )
                annotatedSchemeRoots
                input.annotations

        stampedNodeTypes =
            Array.indexedMap
                (\i maybeType ->
                    case ( maybeType, Maybe.withDefault Nothing (Array.get i rootedNodeVars) ) of
                        ( Just t, Just v ) ->
                            Just (SolverRoots.stampArrowRoots solverState t v)

                        _ ->
                            maybeType
                )
                input.nodeTypes

        stampedAnnotations =
            Dict.map
                (\defName ann ->
                    case Dict.get defName rootedAnnotationVars of
                        Just annotVar ->
                            SolverRoots.stampArrowRootsInAnnotation solverState ann annotVar

                        Nothing ->
                            ann
                )
                input.annotations
    in
    { annotations = stampedAnnotations
    , annotationVars = rootedAnnotationVars
    , nodeTypes = stampedNodeTypes
    , nodeVars = rootedNodeVars
    , schemeRoots = schemeRoots
    }


{-| The configuration of a default `eco make`: `Compiler.Eco.Config.default`
(the solver engine with lambda-set specialization, the pre-monomorphization
passes, the post-inline prune). `runToMono`, `runToGlobalOpt` and `runToMlir`
compile under it.
-}
productionConfig : Config.EcoConfig
productionConfig =
    Config.default


{-| The configuration of bootstrap Stage 5, the other pipeline the project
runs (`compiler/CMakeLists.txt`, `ECO_MONO_ENGINE=subst`): the default with
the substitution engine. The `*Stage5` runners compile under it.
-}
stage5Config : Config.EcoConfig
stage5Config =
    let
        d =
            Config.default

        m =
            d.mono
    in
    { d | mono = { m | engine = Config.EngineSubst } }


{-| Whether a runner runs the pre-monomorphization passes. Only the
`*NoPreMono` runners skip them.
-}
type PreMonoPasses
    = WithPreMono
    | WithoutPreMono


{-| Runs `runToTypedOpt` on `srcModule` and then the build's steps up to and
including monomorphization (`Compiler.Pipeline.Steps`: `prepare`, `preMono`,
`checkMinted`, `monomorphize`, `checkStageArity`, `checkLayout`) under
`ecoConfig`. The `Maybe String` is the LSS report, when the configuration asks
for one.
-}
monoWith : Config.EcoConfig -> PreMonoPasses -> Src.Module -> Result String ( MonoArtifacts, Maybe String )
monoWith ecoConfig passes srcModule =
    case runToTypedOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph } ->
            let
                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical

                prepared =
                    Steps.prepare ecoConfig globalGraph

                assigned =
                    case passes of
                        WithPreMono ->
                            (Steps.preMono ecoConfig prepared).assigned

                        WithoutPreMono ->
                            prepared
            in
            Steps.checkMinted ecoConfig assigned
                |> Result.andThen (\_ -> Steps.monomorphize ecoConfig globalTypeEnv assigned)
                |> Result.andThen
                    (\( g, report ) ->
                        Steps.checkStageArity g
                            |> Result.andThen (Steps.checkLayout ecoConfig)
                            |> Result.map (\g1 -> ( g1, report ))
                    )
                |> Result.mapError (\monoErr -> "Monomorphization failed: " ++ monoErr)
                |> Result.map
                    (\( monoGraph, report ) ->
                        ( { canonical = canonical
                          , annotations = annotations
                          , nodeTypes = nodeTypes
                          , kernelEnv = kernelEnv
                          , localGraph = localGraph
                          , globalGraph = globalGraph
                          , globalTypeEnv = globalTypeEnv
                          , monoGraph = monoGraph
                          }
                        , report
                        )
                    )


{-| `monoWith`, then the build's post-monomorphization steps
(`Compiler.Pipeline.Steps`: `inline`, `prune`, `checkPruned`, `globalOpt`,
`checkStageArity`, `checkClosureStaging`).
-}
globalOptWith : Config.EcoConfig -> PreMonoPasses -> Src.Module -> Result String GlobalOptArtifacts
globalOptWith ecoConfig passes srcModule =
    monoWith ecoConfig passes srcModule
        |> Result.andThen
            (\( a, _ ) ->
                let
                    simplified =
                        Steps.prune ecoConfig (Tuple.first (Steps.inline ecoConfig a.monoGraph))
                in
                Steps.checkPruned ecoConfig simplified
                    |> Result.andThen (\_ -> Steps.checkStageArity (Tuple.first (Steps.globalOpt ecoConfig simplified)))
                    |> Result.andThen (Steps.checkClosureStaging ecoConfig)
                    |> Result.map
                        (\optimizedMonoGraph ->
                            { canonical = a.canonical
                            , annotations = a.annotations
                            , nodeTypes = a.nodeTypes
                            , kernelEnv = a.kernelEnv
                            , localGraph = a.localGraph
                            , globalGraph = a.globalGraph
                            , globalTypeEnv = a.globalTypeEnv
                            , monoGraph = a.monoGraph
                            , optimizedMonoGraph = optimizedMonoGraph
                            }
                        )
            )


{-| `globalOptWith`, then MLIR generation through the build's code generator
context (`Compiler.Generate.MLIR.Backend.generateMlirModule ecoConfig`), in
development mode, as `eco make` without `--optimize`.
-}
mlirWith : Config.EcoConfig -> PreMonoPasses -> Src.Module -> Result String MlirArtifacts
mlirWith ecoConfig passes srcModule =
    globalOptWith ecoConfig passes srcModule
        |> Result.map
            (\a ->
                let
                    mlirModule =
                        MLIR.generateMlirModule ecoConfig (Mode.Dev Nothing) a.optimizedMonoGraph
                in
                { canonical = a.canonical
                , annotations = a.annotations
                , nodeTypes = a.nodeTypes
                , kernelEnv = a.kernelEnv
                , localGraph = a.localGraph
                , globalGraph = a.globalGraph
                , globalTypeEnv = a.globalTypeEnv
                , monoGraph = a.optimizedMonoGraph
                , mlirModule = mlirModule
                , mlirOutput = MLIR.generateProgram ecoConfig (Mode.Dev Nothing) a.optimizedMonoGraph
                }
            )


{-| Compiles `srcModule` the way a default `eco make` does, up to and including
monomorphization: `productionConfig`, pre-monomorphization passes included.
-}
runToMono : Src.Module -> Result String MonoArtifacts
runToMono =
    monoWith productionConfig WithPreMono >> Result.map Tuple.first


{-| `runToMono`, then the post-monomorphization inliner, the post-inline prune
and global optimization, as a default build runs them.
-}
runToGlobalOpt : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOpt =
    globalOptWith productionConfig WithPreMono


{-| `runToGlobalOpt`, then MLIR generation in development mode. `mlirOutput`
is the printed text of `mlirModule`.
-}
runToMlir : Src.Module -> Result String MlirArtifacts
runToMlir =
    mlirWith productionConfig WithPreMono


{-| `runToMono` under `stage5Config` (the substitution engine, as bootstrap
Stage 5 compiles).
-}
runToMonoStage5 : Src.Module -> Result String MonoArtifacts
runToMonoStage5 =
    monoWith stage5Config WithPreMono >> Result.map Tuple.first


{-| `runToGlobalOpt` under `stage5Config`.
-}
runToGlobalOptStage5 : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOptStage5 =
    globalOptWith stage5Config WithPreMono


{-| `runToMlir` under `stage5Config`.
-}
runToMlirStage5 : Src.Module -> Result String MlirArtifacts
runToMlirStage5 =
    mlirWith stage5Config WithPreMono


{-| `runToMono` WITHOUT the pre-monomorphization passes. Not a production
pipeline: a test may use it only to exercise a later pass on input that alias
forwarding or η-expansion would have rewritten first, and each caller says why
in a comment.
-}
runToMonoNoPreMono : Src.Module -> Result String MonoArtifacts
runToMonoNoPreMono =
    monoWith productionConfig WithoutPreMono >> Result.map Tuple.first


{-| `runToGlobalOpt` without the pre-monomorphization passes; see
`runToMonoNoPreMono`.
-}
runToGlobalOptNoPreMono : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOptNoPreMono =
    globalOptWith productionConfig WithoutPreMono


{-| `runToMlir` without the pre-monomorphization passes; see
`runToMonoNoPreMono`.
-}
runToMlirNoPreMono : Src.Module -> Result String MlirArtifacts
runToMlirNoPreMono =
    mlirWith productionConfig WithoutPreMono


{-| The global graph of `srcModule` after `Compiler.Pipeline.Steps.prepare`
has given it its ids under `productionConfig`, which is the kind of graph the
pre-monomorphization passes work on in a build.
-}
runToAssigned : Src.Module -> Result String EntryPrep.Assigned
runToAssigned srcModule =
    Result.map
        (\{ localGraph } -> Steps.prepare productionConfig (localGraphToGlobalGraph localGraph))
        (runToTypedOpt srcModule)


{-| `runToMono` with the solver engine under the given watchdog `limits` and
`lssConfig`, returning the monomorphized graph. A test can give small limits
and check that a program whose specializations keep growing ends in `Err`.
-}
runSolverMonoWithLimits : Config.SpecLimits -> Config.LssConfig -> Src.Module -> Result String Mono.MonoGraph
runSolverMonoWithLimits limits lssConfig =
    monoWith (withMono Config.EngineSolver limits lssConfig) WithPreMono
        >> Result.map (Tuple.first >> .monoGraph)


{-| `runSolverMonoWithLimits` with `report` set in `lssConfig`, returning the
rendered lambda-set specialization report alongside the graph so that a test
can check its counter lines.
-}
runSolverMonoWithReport : Config.SpecLimits -> Config.LssConfig -> Src.Module -> Result String ( Mono.MonoGraph, Maybe String )
runSolverMonoWithReport limits lssConfig =
    monoWith (withMono Config.EngineSolver limits { lssConfig | report = True }) WithPreMono
        >> Result.map (Tuple.mapFirst .monoGraph)


{-| `runSolverMonoWithLimits` without the pre-monomorphization passes; see
`runToMonoNoPreMono` for when a test may use it.
-}
runSolverMonoWithLimitsNoPreMono : Config.SpecLimits -> Config.LssConfig -> Src.Module -> Result String Mono.MonoGraph
runSolverMonoWithLimitsNoPreMono limits lssConfig =
    monoWith (withMono Config.EngineSolver limits lssConfig) WithoutPreMono
        >> Result.map (Tuple.first >> .monoGraph)


{-| `runSolverMonoWithReport` without the pre-monomorphization passes; see
`runToMonoNoPreMono` for when a test may use it.
-}
runSolverMonoWithReportNoPreMono : Config.SpecLimits -> Config.LssConfig -> Src.Module -> Result String ( Mono.MonoGraph, Maybe String )
runSolverMonoWithReportNoPreMono limits lssConfig =
    monoWith (withMono Config.EngineSolver limits { lssConfig | report = True }) WithoutPreMono
        >> Result.map (Tuple.mapFirst .monoGraph)


{-| `runToMonoStage5` (the substitution engine) under the given watchdog
`limits`, as `runSolverMonoWithLimits` does for the solver engine.
-}
runSubstMonoWithLimits : Config.SpecLimits -> Src.Module -> Result String Mono.MonoGraph
runSubstMonoWithLimits limits =
    monoWith (withMono Config.EngineSubst limits Config.default.mono.lss) WithPreMono
        >> Result.map (Tuple.first >> .monoGraph)


{-| `productionConfig` with the given engine, watchdog limits and LSS
configuration.
-}
withMono : Config.MonoEngine -> Config.SpecLimits -> Config.LssConfig -> Config.EcoConfig
withMono engine limits lssConfig =
    let
        d =
            productionConfig

        m =
            d.mono
    in
    { d | mono = { m | engine = engine, limits = limits, lss = lssConfig } }



-- ============================================================================
-- LOW-LEVEL HELPERS
-- ============================================================================


{-| Builds the IO action that generates `modul`'s constraints with node ids
recorded and solves them, giving the solver's results or the number of type
errors.
-}
runWithIdsTypeCheck : Can.Module -> IO.IO (Result Int { annotations : Dict Name.Name (Can.Annotation Name), nodeTypes : Array (Maybe (Can.Type Name)), nodeVars : Array (Maybe Vars.Variable), solverState : { cells : Array Vars.PointCell }, annotationVars : Dict Name.Name Vars.Variable, schemeBinderVars : Dict Name.Name (Dict Name.Name Vars.Variable) })
runWithIdsTypeCheck modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars, schemeBinderVars ) ->
                Solve.runWithIds constraint nodeVars
                    |> IO.map (\result -> ( result, schemeBinderVars ))
            )
        |> IO.map
            (\( result, schemeBinderVars ) ->
                case result of
                    Ok data ->
                        Ok
                            { annotations = data.annotations
                            , nodeTypes = data.nodeTypes
                            , nodeVars = data.nodeVars
                            , solverState = data.solverState
                            , annotationVars = data.annotationVars
                            , schemeBinderVars = schemeBinderVars
                            }

                    Err (NE.Nonempty _ rest) ->
                        Err (1 + List.length rest)
            )


{-| Builds the global graph that monomorphization is given for a program whose
typed local graph is `localGraph`.

In a build, each dependency's own typed graph is merged in, bringing its nodes
and annotations. Here the dependencies are the mock interfaces, which have no
code, so the graph is the program's own local graph, merged in as
`Builder.GraphAssembly.addTypedLocalGraph` merges any local graph, plus an
annotation for every interface value, operator and constructor, and a node
for each kernel alias in `aliasedKernels`. Where a synthesized entry and a
program entry have the same global, the synthesized one is kept. Fields,
scheme roots and variable supers come from the program alone.

-}
localGraphToGlobalGraph : TOpt.LocalGraph Name -> TOpt.GlobalGraph Name
localGraphToGlobalGraph localGraph =
    let
        (TOpt.GlobalGraph nodes fields annotations roots varSupers) =
            GA.addTypedLocalGraph localGraph TOpt.emptyGlobalGraph

        crossModuleAnnotations =
            interfaceAnnotations Basic.testIfaces
    in
    TOpt.GlobalGraph (Data.Map.union (kernelAliasNodes Basic.testIfaces) nodes) fields (Data.Map.union crossModuleAnnotations annotations) roots varSupers


{-| The dependency values, as (module, value) pairs, that get a real node in
the mock global graph: each is an eta-free alias of a kernel function, such as
`cons = Elm.Kernel.List.cons`.

A dependency global with no node is not specialized from code; the
substitution engine makes it a `MonoExtern`. The solver engine recognizes a
global as a kernel alias only from such a node
(`Compiler.MonoSolver.LssInfer.kernelAliasOf`), so these values get the node
a build would have. `List.map2` gives tests a kernel alias one of whose
arguments is a function.

The list should name only values that elm/core's own source defines as such
an alias, or the mock graph stops matching a build. Nothing checks this.

-}
aliasedKernels : List ( Name, Name )
aliasedKernels =
    [ ( "List", "cons" )
    , ( "List", "map2" )
    ]


{-| Builds a node for each `aliasedKernels` entry found in `ifaces`, keyed by
its global: a definition whose body is a reference to the `Elm` kernel of the
same module and name, typed with the body of the value's annotation, with no
dependencies. An entry whose module or value is not in `ifaces` is skipped.
-}
kernelAliasNodes : Dict Name I.Interface -> Data.Map.Dict String TOpt.Global (TOpt.Node Name)
kernelAliasNodes ifaces =
    List.foldl
        (\( moduleName, valueName ) acc ->
            case Dict.get moduleName ifaces of
                Just (I.Interface idata) ->
                    case Dict.get valueName idata.values of
                        Just (Can.Forall _ tipe) ->
                            Data.Map.insert TOpt.toComparableGlobal
                                (TOpt.Global (ModuleName.Canonical idata.home moduleName) valueName)
                                (TOpt.Define
                                    (TOpt.VarKernel A.zero "Elm" moduleName valueName { tipe = tipe, tvar = Nothing })
                                    Data.Set.empty
                                    { tipe = tipe, tvar = Nothing }
                                )
                                acc

                        Nothing ->
                            acc

                Nothing ->
                    acc
        )
        Data.Map.empty
        aliasedKernels


{-| Returns an annotation, keyed by global, for every value, every union
constructor and every operator's function in `ifaces`. Each interface module's
globals are homed in the package its interface names.
-}
interfaceAnnotations : Dict Name I.Interface -> Data.Map.Dict String TOpt.Global (Can.Annotation Name)
interfaceAnnotations ifaces =
    Dict.foldl
        (\moduleName (I.Interface idata) acc ->
            let
                home =
                    ModuleName.Canonical idata.home moduleName
            in
            acc
                |> addValueAnnotations home idata.values
                |> addUnionAnnotations home idata.unions
                |> addBinopAnnotations home idata.binops
        )
        Data.Map.empty
        ifaces


{-| Adds the annotation of each of `values` to `acc`, keyed by its global in
`home`.
-}
addValueAnnotations : ModuleName.Canonical -> Dict Name (Can.Annotation Name) -> Data.Map.Dict String TOpt.Global (Can.Annotation Name) -> Data.Map.Dict String TOpt.Global (Can.Annotation Name)
addValueAnnotations home values acc =
    Dict.foldl
        (\name ann a ->
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home name) ann a
        )
        acc
        values


{-| Adds the annotation of each of `binops` to `acc`, keyed by the global of
the function the operator names (such as `add` for `+`), not by the operator.
-}
addBinopAnnotations : ModuleName.Canonical -> Dict Name I.Binop -> Data.Map.Dict String TOpt.Global (Can.Annotation Name) -> Data.Map.Dict String TOpt.Global (Can.Annotation Name)
addBinopAnnotations home binops acc =
    Dict.foldl
        (\_ (I.Binop bdata) a ->
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home bdata.name) bdata.annotation a
        )
        acc
        binops


{-| Adds an annotation for every constructor of each of `unions` to `acc`,
whether the interface exposes the union open, closed or privately.
-}
addUnionAnnotations : ModuleName.Canonical -> Dict Name I.Union -> Data.Map.Dict String TOpt.Global (Can.Annotation Name) -> Data.Map.Dict String TOpt.Global (Can.Annotation Name)
addUnionAnnotations home unions acc =
    Dict.foldl
        (\typeName iUnion a ->
            let
                union =
                    case iUnion of
                        I.OpenUnion u ->
                            u

                        I.ClosedUnion u ->
                            u

                        I.PrivateUnion u ->
                            u
            in
            addCtorAnnotations home typeName union a
        )
        acc
        unions


{-| Adds an annotation for each constructor of the union `typeName` to `acc`.

A constructor's type is the function from its arguments to the union type
applied to the union's type variables, quantified over those variables. It is
built the way `Compiler.LocalOpt.Typed.Module` types the constructor nodes of
a compiled module.

-}
addCtorAnnotations : ModuleName.Canonical -> Name -> Can.Union -> Data.Map.Dict String TOpt.Global (Can.Annotation Name) -> Data.Map.Dict String TOpt.Global (Can.Annotation Name)
addCtorAnnotations home typeName (Can.Union unionData) acc =
    List.foldl
        (\(Can.Ctor c) a ->
            let
                resultType =
                    Can.TType home typeName (List.map Can.TVar unionData.vars)

                ctorType =
                    List.foldr Can.tLambda resultType c.args

                freeVars =
                    List.foldl (\v dict -> Dict.insert v () dict) Dict.empty unionData.vars

                ctorAnn =
                    Can.Forall freeVars ctorType
            in
            Data.Map.insert TOpt.toComparableGlobal (TOpt.Global home c.name) ctorAnn a
        )
        acc
        unionData.alts


{-| Builds the global type environment for monomorphizing `canModule`: the
type environment of every mock interface module plus that of `canModule`.
Where both have an entry for one module, the interface's is kept.
-}
buildGlobalTypeEnv : Can.Module -> TypeEnv.GlobalTypeEnv
buildGlobalTypeEnv canModule =
    let
        moduleTypeEnv =
            TypeEnv.fromCanonical canModule

        interfaceTypeEnv =
            TypeEnv.fromInterfaces Basic.testIfaces
    in
    TypeEnv.mergeGlobalTypeEnv
        interfaceTypeEnv
        (Data.Map.singleton ModuleName.toComparableCanonical moduleTypeEnv.home moduleTypeEnv)


{-| Returns the module with the synthetic `main` appended to its values:

    main =
        Html.text (Elm.Kernel.Debug.toString testValue)

`main` USES `testValue`, as a real program uses what it computes. An unused
binding would be dead code: the inliner drops it, and the post-inline prune
then removes `testValue` and everything only it reaches, so the program under
test would never reach code generation
(plans/staging-honesty-and-production-test-pipeline.md P1.4).

It also appends `import Html exposing (text)` unless the module already has an
import of `Html`; when that import has an alias, `main` calls `text` through
the alias instead of `Html`. The `main` has no annotation; its type is that of the mock
`Html.text`'s result, a `VirtualDom.Node`, which the typed optimizer accepts as
a static `main`.

A module with no `testValue` crashes the test run (`Debug.todo`). A module
that already defines `main` gets a second one, so canonicalization fails.

-}
wrapWithMain : Src.Module -> Src.Module
wrapWithMain (Src.Module data) =
    let
        valueNames =
            List.map
                (\(A.At _ (Src.Value vdata)) ->
                    let
                        ( _, A.At _ name ) =
                            vdata.name
                    in
                    name
                )
                data.values

        testValueRef =
            if List.member "testValue" valueNames then
                varRef "testValue"

            else
                Debug.todo "Test module must define 'testValue' — see SourceIR test standard"

        -- The existing `import Html`, if any, and the alias it gives the module.
        htmlImportAlias =
            List.filterMap
                (\(Src.Import ( _, A.At _ importName ) maybeAlias _) ->
                    if importName == "Html" then
                        Just (Maybe.map Tuple.second maybeAlias)

                    else
                        Nothing
                )
                data.imports
                |> List.head

        htmlQualifier =
            case htmlImportAlias of
                Just (Just alias) ->
                    alias

                _ ->
                    "Html"

        mainExpr =
            A.At A.zero
                (Src.Call
                    (A.At A.zero (Src.VarQual Src.LowVar htmlQualifier "text"))
                    [ ( []
                      , A.At A.zero
                            (Src.Call
                                (A.At A.zero (Src.VarQual Src.LowVar "Elm.Kernel.Debug" "toString"))
                                [ ( [], testValueRef ) ]
                            )
                      )
                    ]
                )

        mainValue =
            Src.Value
                { comments = []
                , name = ( [], A.At A.zero "main" )
                , args = []
                , body = ( [], mainExpr )
                , tipe = Nothing
                }

        htmlImport =
            Src.Import
                ( [], A.At A.zero "Html" )
                Nothing
                ( ( [], [] )
                , Src.Explicit
                    (A.At A.zero
                        [ ( ( [], [] ), Src.Lower (A.At A.zero "text") ) ]
                    )
                )
    in
    Src.Module
        { data
            | values = data.values ++ [ A.At A.zero mainValue ]
            , imports =
                if htmlImportAlias /= Nothing then
                    data.imports

                else
                    data.imports ++ [ htmlImport ]
        }


{-| Builds a reference to the unqualified lower-case variable `name`, with no
source region.
-}
varRef : Name.Name -> Src.Expr
varRef name =
    A.At A.zero (Src.Var Src.LowVar name)



-- ============================================================================
-- EXPECTATION HELPERS
-- ============================================================================


{-| Creates an expectation that `srcModule` gets through `runToTypedOpt`, and
then through the rest of the production pipeline (`runToMlir`) only so that the
code runs.

It fails when any stage returns `Err`; what the stages produce is not checked.
A stage that crashes still ends the test.

-}
expectCoverageRun : Src.Module -> Expect.Expectation
expectCoverageRun srcModule =
    case runToTypedOpt srcModule of
        Err msg ->
            Expect.fail ("Invalid test case (frontend failure): " ++ msg)

        Ok _ ->
            case runToMlir srcModule of
                Err msg ->
                    Expect.fail msg

                Ok _ ->
                    Expect.pass


{-| Creates an expectation that `runToMono` succeeds on `srcModule` and gives a
graph with a `main` and a node array that is not empty.
-}
expectMonomorphization : Src.Module -> Expect.Expectation
expectMonomorphization srcModule =
    case runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            verifyMonoGraph monoGraph


{-| Creates an expectation that `runToMlir` succeeds on `srcModule` and gives
MLIR text that is not empty and contains `func.func` or `eco.`.
-}
expectMLIRGeneration : Src.Module -> Expect.Expectation
expectMLIRGeneration srcModule =
    case runToMlir srcModule of
        Err msg ->
            Expect.fail msg

        Ok { mlirOutput } ->
            verifyMLIROutput mlirOutput


{-| Creates an expectation that the graph has a `main` and a node array that is
not empty.
-}
verifyMonoGraph : Mono.MonoGraph -> Expect.Expectation
verifyMonoGraph (Mono.MonoGraph data) =
    case data.main of
        Nothing ->
            Expect.fail "Monomorphized graph has no main entry point"

        Just _ ->
            if Array.isEmpty data.nodes then
                Expect.fail "Monomorphized graph has no nodes"

            else
                Expect.pass


{-| Creates an expectation that `output` is not empty and contains `func.func`
or `eco.` somewhere. The graph argument is not used.
-}
verifyMLIROutput : String -> Expect.Expectation
verifyMLIROutput output =
    if String.isEmpty output then
        Expect.fail "MLIR output is empty"

    else if not (String.contains "func.func" output || String.contains "eco." output) then
        Expect.fail "MLIR output doesn't contain expected operations"

    else
        Expect.pass
