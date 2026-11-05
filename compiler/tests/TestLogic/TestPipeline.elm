module TestLogic.TestPipeline exposing
    ( CanonicalArtifacts
    , GlobalOptArtifacts
    , MlirArtifacts
    , MonoArtifacts
    , Outcome(..)
    , PostSolveArtifacts
    , Reports
    , Stage(..)
    , TypeCheckArtifacts
    , TypedOptArtifacts
    , expectCoverageRun
    , expectMLIRGeneration
    , expectMonomorphization
    , globalOpt
    , interfaceAnnotations
    , interfacesTypeEnv
    , productionConfig
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
    , runToPostSolve
    , runToReports
    , runToReportsThrough
    , runToTypeCheck
    , runToTypedOpt
    , stage5Config
    , stageName
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
packages, and MLIR is generated as one module rather than streamed. One step
is left out of the `runTo*` runners above: the pattern-match checker
(`Compiler.Nitpick.PatternMatches`), which `Compiler.Compile` runs between type
checking and typed optimization, so a program with a missing pattern gets
through them although `eco make` rejects it.

`runToReports` and `runToReportsThrough` are the runners for a program that
may be rejected. They run every stage a build runs, in its order and with the
pattern-match checker, and give the `Stage` that rejected the program with its
reports as the production reporters render them (`Outcome`, `Reports`), so a
test can check which error a user would see. `test/scripts/check-test-pipeline-production.sh`
fails the `elm-tests` target if this module ever calls a compiler pass other
than through `Compiler.Pipeline.Steps`.

-}

import Array exposing (Array)
import Builder.File as File
import Builder.GraphAssembly as GA
import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Builder.Reporting.ModuleError as ModuleError
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Config as Config
import Compiler.Core.Annotation as A
import Compiler.Core.Name as Name exposing (Name)
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Error as E
import Compiler.GenerateMlir.BackendModule as MLIR
import Compiler.IR.Canonical as Can
import Compiler.IR.Canonical.Interface as I
import Compiler.IR.Mono as Mono
import Compiler.IR.Source as Src
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.IR.Typed.TypeEnv as TypeEnv
import Compiler.IR.Typed.TypeVars as Vars
import Compiler.LocalOpt.Error as MainError
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Nitpick.PatternMatches as PatternMatches
import Compiler.Pipeline.Steps as Steps
import Compiler.PreMono.EntryPrep as EntryPrep
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Error as TypeError
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Solve
import Compiler.Type.SolverRoots as SolverRoots
import Compiler.Type.State.IO as IO
import Compiler.Type.TypedCanonical as TCanBuild
import Data.Map
import Data.NonEmptyList as NE
import Data.OneOrMore as OneOrMore
import Data.Set
import Dict exposing (Dict)
import Expect
import Mlir.Mlir exposing (MlirModule)
import Time



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
`Compiler.MonoOpt.GlobalOptimize.globalOptimizeWithStats` on `monoGraph`.

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
        Err errors ->
            let
                errorCount =
                    OneOrMore.destruct (::) errors |> List.length
            in
            Err ("Canonicalization failed with " ++ String.fromInt errorCount ++ " error(s)")

        Ok canonical ->
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
                Err (NE.Nonempty _ rest) ->
                    Err ("Type checking failed with " ++ String.fromInt (1 + List.length rest) ++ " error(s)")

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
    Result.map postSolveFrom (runToTypeCheck srcModule)


{-| Runs PostSolve on the node types of a type-checked program, keeping the
node types from both before and after.
-}
postSolveFrom : TypeCheckArtifacts -> PostSolveArtifacts
postSolveFrom { canonical, annotations, nodeTypes, nodeVars, solverState, annotationVars, schemeBinderVars } =
    let
        postSolveResult =
            PostSolve.postSolve
                annotations
                canonical
                nodeTypes
    in
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
    runToPostSolve (wrapWithMain srcModule)
        |> Result.andThen (typedOptFrom >> Result.mapError (\_ -> "Typed optimization produced an error"))


{-| Builds the typed local graph of a program that has been through PostSolve,
as `runToTypedOpt` describes, or gives the typed optimizer's errors.
-}
typedOptFrom : PostSolveArtifacts -> Result (OneOrMore.OneOrMore MainError.Error) TypedOptArtifacts
typedOptFrom { canonical, annotations, nodeTypesPost, kernelEnv, nodeVars, solverState, annotationVars, schemeBinderVars } =
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
        Ok localGraph ->
            Ok
                { canonical = canonical
                , annotations = stampedAnnotations
                , nodeTypes = stampedNodeTypes
                , kernelEnv = kernelEnv
                , localGraph = localGraph
                }

        Err errors ->
            Err errors


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


{-| The configuration of a default `eco make`: `Compiler.Config.default`
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


{-| The name of a canonical module, the root module a test program's `main` is
looked up in.
-}
moduleHome : Can.Module -> ModuleName.Canonical
moduleHome (Can.Module m) =
    m.name


{-| Runs `runToTypedOpt` on `srcModule` and then the build's steps up to and
including monomorphization (`Compiler.Pipeline.Steps`: `prepareRoot`, `preMono`,
`checkMinted`, `monomorphize`, `checkStageArity`, `checkLayout`) under
`ecoConfig`. The `Maybe String` is the LSS report, when the configuration asks
for one.
-}
monoWith : Config.EcoConfig -> PreMonoPasses -> Src.Module -> Result String ( MonoArtifacts, Maybe String )
monoWith ecoConfig passes srcModule =
    runToTypedOpt srcModule
        |> Result.andThen
            (monoStepsFrom ecoConfig passes
                >> Result.mapError (\monoErr -> "Monomorphization failed: " ++ monoErr)
            )


{-| The steps of `monoWith` after typed optimization, giving a failed step's
message as the step returned it.
-}
monoStepsFrom : Config.EcoConfig -> PreMonoPasses -> TypedOptArtifacts -> Result String ( MonoArtifacts, Maybe String )
monoStepsFrom ecoConfig passes { canonical, annotations, nodeTypes, kernelEnv, localGraph } =
    let
        globalGraph =
            localGraphToGlobalGraph localGraph

        globalTypeEnv =
            buildGlobalTypeEnv canonical

        prepared =
            Steps.prepareRoot ecoConfig (moduleHome canonical) globalGraph

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
(`Steps.inline`, `Steps.prune`, `Steps.checkPruned`, `globalOpt`,
`Steps.checkStageArity`, `Steps.checkClosureStaging`).
-}
globalOptWith : Config.EcoConfig -> PreMonoPasses -> Src.Module -> Result String GlobalOptArtifacts
globalOptWith ecoConfig passes srcModule =
    monoWith ecoConfig passes srcModule
        |> Result.andThen (Tuple.first >> globalOptStepsFrom ecoConfig)


{-| Returns the graph after the build's whole global optimization step:
`Steps.globalOptCore`, then `Steps.cse`, `Steps.dedupe` and `Steps.hoist`,
which the build runs as separate tasks.
-}
globalOpt : Config.EcoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, Steps.GlobalOptResult )
globalOpt ecoConfig g =
    Steps.globalOptCore ecoConfig g
        |> Steps.cse ecoConfig
        |> Steps.dedupe ecoConfig
        |> Steps.hoist ecoConfig


{-| The steps of `globalOptWith` after monomorphization.
-}
globalOptStepsFrom : Config.EcoConfig -> MonoArtifacts -> Result String GlobalOptArtifacts
globalOptStepsFrom ecoConfig a =
    let
        simplified =
            Steps.prune ecoConfig (Tuple.first (Steps.inline ecoConfig a.monoGraph))
    in
    Steps.checkPruned ecoConfig simplified
        |> Result.andThen (\_ -> Steps.checkStageArity (Tuple.first (globalOpt ecoConfig simplified)))
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


{-| `globalOptWith`, then MLIR generation through the build's code generator
context (`Compiler.GenerateMlir.BackendModule.generateMlirModule ecoConfig`), in
development mode, as `eco make` without `--optimize`.
-}
mlirWith : Config.EcoConfig -> PreMonoPasses -> Src.Module -> Result String MlirArtifacts
mlirWith ecoConfig passes srcModule =
    globalOptWith ecoConfig passes srcModule
        |> Result.map
            (\a ->
                let
                    mlirModule =
                        MLIR.generateMlirModule ecoConfig a.optimizedMonoGraph
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
                , mlirOutput = MLIR.generateProgram ecoConfig a.optimizedMonoGraph
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


{-| The global graph of `srcModule` after `Compiler.Pipeline.Steps.prepareRoot`
has given it its ids under `productionConfig`, which is the kind of graph the
pre-monomorphization passes work on in a build.
-}
runToAssigned : Src.Module -> Result String EntryPrep.Assigned
runToAssigned srcModule =
    Result.map
        (\{ canonical, localGraph } -> Steps.prepareRoot productionConfig (moduleHome canonical) (localGraphToGlobalGraph localGraph))
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
-- REJECTION REPORTS
-- ============================================================================


{-| A stage of compilation that can reject a program, in the order a build
reaches them. The first four are the phases of `Compiler.Compile.compileTyped`:

  - `Canonicalize`: canonicalization, whose errors are `Compiler.Error.BadNames`;
  - `TypeCheck`: type checking along the typed path (`BadTypes`);
  - `PatternMatch`: pattern-match checking, `Compiler.Nitpick.PatternMatches`
    (`BadPatterns`);
  - `TypedOptimize`: the typed optimizer, which checks `main` (`BadMains`).

`Monomorphize` is every step of the build after `Compiler.Compile`, from
`Compiler.Pipeline.Steps.prepareRoot` to `checkClosureStaging`, whose failures
`Builder.Generate` reports as `Builder.Reporting.Exit.GenerateMonomorphizationError`.

-}
type Stage
    = Canonicalize
    | TypeCheck
    | PatternMatch
    | TypedOptimize
    | Monomorphize


{-| What `runToReports` makes of a program: `Accepted` when no stage rejects
it, or `Rejected` with the reports of the stage that did.
-}
type Outcome
    = Accepted
    | Rejected Reports


{-| The reports of a rejected program: the `stage` that rejected it, the title
of each report in order, and `text`, all the reports rendered without colour as
the terminal shows them.
-}
type alias Reports =
    { stage : Stage
    , titles : List String
    , text : String
    }


{-| The name of a stage, for failure messages.
-}
stageName : Stage -> String
stageName stage =
    case stage of
        Canonicalize ->
            "canonicalization"

        TypeCheck ->
            "type checking"

        PatternMatch ->
            "pattern-match checking"

        TypedOptimize ->
            "typed optimization"

        Monomorphize ->
            "monomorphization"


{-| Compiles `srcModule` as far as it gets, the way `eco make` does: the
phases of `Compiler.Compile.compileTyped` in its order (canonicalization, type
checking, pattern-match checking, typed optimization), then the build's steps
after it, as `runToGlobalOpt` runs them under `productionConfig`. It gives the
stage that rejected the program and that stage's reports, or `Accepted`.

The reports are made by the production reporters, so a test sees the titles
and wording a user sees. A phase of `Compiler.Compile` fails with a
`Compiler.Error.Error`, which `Builder.Reporting.ModuleError.toDoc` lays out
for the module `src/Test.elm` of the project `/project`; a later step fails
with a message that `Builder.Reporting.Exit.makeToReport` turns into a
`GenerateMonomorphizationError` report (`MONOMORPHIZATION ERROR`, or `STAGE
ARITY LIMIT` for a message that starts so). A test program has no source text,
so the module's source is given as blank lines, as many as the module's
definitions span: a report quotes blank lines where it would quote code, and
the rest of its text is unchanged.

The program gets the synthetic `main` of `wrapWithMain` only when it defines
`testValue` and no `main`; a program with a `main` of its own keeps it, so
that its `main` can be the one rejected. A program with neither has no entry
point, and is `Accepted` once typed optimization accepts it, since there is
nothing for the build's later steps to start from.

MLIR is not generated: its generation reports no error, only a crash.

-}
runToReports : Src.Module -> Outcome
runToReports =
    runToReportsThrough Monomorphize


{-| `runToReports`, stopping after `last`: a program that gets through `last`
is `Accepted` without the later stages being run. A check that needs only the
early stages uses this, as they cost far less than monomorphization.
-}
runToReportsThrough : Stage -> Src.Module -> Outcome
runToReportsThrough last srcModule0 =
    let
        srcModule =
            withEntryPoint srcModule0

        localizer =
            Localizer.fromModule srcModule

        reject stage error =
            Rejected (renderModuleError stage srcModule error)

        continueAfter stage next =
            if stage == last then
                Accepted

            else
                next ()
    in
    case RResult.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        Err errors ->
            reject Canonicalize (E.BadNames errors)

        Ok canonical ->
            continueAfter Canonicalize <|
                \() ->
                    case IO.unsafePerformIO (runWithIdsTypeCheck canonical) of
                        Err errors ->
                            reject TypeCheck (E.BadTypes localizer errors)

                        Ok tc ->
                            continueAfter TypeCheck <|
                                \() ->
                                    case PatternMatches.check canonical of
                                        Err errors ->
                                            reject PatternMatch (E.BadPatterns errors)

                                        Ok () ->
                                            continueAfter PatternMatch <|
                                                \() ->
                                                    typedOptimizeForReports last localizer srcModule canonical tc


{-| The stages of `runToReportsThrough` from typed optimization on.
-}
typedOptimizeForReports :
    Stage
    -> Localizer.Localizer
    -> Src.Module
    -> Can.Module
    ->
        { annotations : Dict Name.Name (Can.Annotation Name)
        , nodeTypes : Array (Maybe (Can.Type Name))
        , nodeVars : Array (Maybe Vars.Variable)
        , solverState : { cells : Array Vars.PointCell }
        , annotationVars : Dict Name.Name Vars.Variable
        , schemeBinderVars : Dict Name.Name (Dict Name.Name Vars.Variable)
        }
    -> Outcome
typedOptimizeForReports last localizer srcModule canonical tc =
    let
        artifacts =
            { canonical = canonical
            , annotations = tc.annotations
            , nodeTypes = tc.nodeTypes
            , nodeVars = tc.nodeVars
            , solverState = tc.solverState
            , annotationVars = tc.annotationVars
            , schemeBinderVars = tc.schemeBinderVars
            }
    in
    case typedOptFrom (postSolveFrom artifacts) of
        Err errors ->
            Rejected (renderModuleError TypedOptimize srcModule (E.BadMains localizer errors))

        Ok typed ->
            if last == TypedOptimize || not (hasMain typed.localGraph) then
                Accepted

            else
                case
                    monoStepsFrom productionConfig WithPreMono typed
                        |> Result.andThen (Tuple.first >> globalOptStepsFrom productionConfig)
                of
                    Err message ->
                        Rejected (renderGenerateError message)

                    Ok _ ->
                        Accepted


{-| Whether a typed local graph has a `main`.
-}
hasMain : TOpt.LocalGraph Name -> Bool
hasMain (TOpt.LocalGraph data) =
    data.main /= Nothing


{-| `srcModule` with the synthetic `main` of `wrapWithMain` when it defines
`testValue` and no `main`, and as it is otherwise.
-}
withEntryPoint : Src.Module -> Src.Module
withEntryPoint ((Src.Module data) as srcModule) =
    let
        names =
            List.map
                (\(A.At _ (Src.Value vdata)) ->
                    let
                        ( _, A.At _ name ) =
                            vdata.name
                    in
                    name
                )
                data.values
    in
    if List.member "testValue" names && not (List.member "main" names) then
        wrapWithMain srcModule

    else
        srcModule


{-| The reports of `error`, a failure of one of the phases of
`Compiler.Compile`, as `Builder.Reporting.ModuleError.toDoc` lays them out.
-}
renderModuleError : Stage -> Src.Module -> E.Error -> Reports
renderModuleError stage srcModule error =
    let
        text =
            ModuleError.toDoc "/project"
                { name = Src.getName srcModule
                , absolutePath = "/project/src/Test.elm"
                , modificationTime = File.Time (Time.millisToPosix 0)
                , source = blankSource srcModule
                , error = error
                }
                []
                |> D.toString
    in
    { stage = stage, titles = reportTitles text, text = text }


{-| The report of a failed step after `Compiler.Compile`, whose message is
`message`, as `Builder.Generate` reports it.
-}
renderGenerateError : String -> Reports
renderGenerateError message =
    let
        text =
            Exit.makeToReport (Exit.MakeBadGenerate (Exit.GenerateMonomorphizationError message))
                |> Help.reportToDoc
                |> D.toString
    in
    { stage = Monomorphize, titles = reportTitles text, text = text }


{-| Source text of blank lines standing in for the text of `srcModule`, one
more than the last row any of its values, custom types and aliases reaches, so
that every region a report quotes is within it.
-}
blankSource : Src.Module -> String
blankSource (Src.Module data) =
    let
        endRow (A.At (A.Region _ (A.Position row _)) _) =
            row

        lastRow =
            List.maximum
                (List.map endRow data.values
                    ++ List.map endRow data.unions
                    ++ List.map endRow data.aliases
                )
                |> Maybe.withDefault 0
    in
    String.repeat (lastRow + 1) "\n"


{-| The titles of the reports in `text`, in order: the title in each report's
heading bar, a line `-- TITLE ----- path` (the path is left out of a report
that is about no file).
-}
reportTitles : String -> List String
reportTitles text =
    List.filterMap barTitle (String.lines text)


{-| The title in `line` when it is a report's heading bar: `--`, the title,
and a run of dashes, then nothing or a space and a path.
-}
barTitle : String -> Maybe String
barTitle line =
    if String.startsWith "-- " line then
        let
            rest =
                String.dropLeft 3 line

            isBarEnd i =
                let
                    after =
                        String.dropLeft (i + 1) rest

                    dashes =
                        countLeading '-' after

                    tail =
                        String.dropLeft dashes after
                in
                dashes >= 1 && (tail == "" || String.startsWith " " tail)
        in
        String.indexes " -" rest
            |> List.filter isBarEnd
            |> List.head
            |> Maybe.map (\i -> String.left i rest)

    else
        Nothing


{-| The number of times `c` repeats at the start of `s`.
-}
countLeading : Char -> String -> Int
countLeading c s =
    String.length s - String.length (dropWhileChar c s)


{-| `s` without the copies of `c` at its start.
-}
dropWhileChar : Char -> String -> String
dropWhileChar c s =
    case String.uncons s of
        Just ( first, rest ) ->
            if first == c then
                dropWhileChar c rest

            else
                s

        Nothing ->
            s



-- ============================================================================
-- LOW-LEVEL HELPERS
-- ============================================================================


{-| Builds the IO action that generates `modul`'s constraints with node ids
recorded and solves them, giving the solver's results or the type errors.
-}
runWithIdsTypeCheck : Can.Module -> IO.IO (Result (NE.Nonempty TypeError.Error) { annotations : Dict Name.Name (Can.Annotation Name), nodeTypes : Array (Maybe (Can.Type Name)), nodeVars : Array (Maybe Vars.Variable), solverState : { cells : Array Vars.PointCell }, annotationVars : Dict Name.Name Vars.Variable, schemeBinderVars : Dict Name.Name (Dict Name.Name Vars.Variable) })
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
                            { annotations = Dict.map (\_ entry -> entry.annotation) data.annotations
                            , nodeTypes = data.nodeTypes
                            , nodeVars = data.nodeVars
                            , solverState = data.solverState
                            , annotationVars = Dict.map (\_ entry -> entry.var) data.annotations
                            , schemeBinderVars = schemeBinderVars
                            }

                    Err errors ->
                        Err errors
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
(`Compiler.Monomorphize.Solver.LssInfer.kernelAliasOf`), so these values get the node
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


{-| Returns the global type environment of the interfaces in `ifaces`, each
module named by its key in `ifaces` together with the package its interface
records. Every custom type and alias an interface holds is taken, whatever its
visibility, as `Compiler.IR.Canonical.Interface.extractUnion` and
`extractAlias` return it.
-}
interfacesTypeEnv : Dict ModuleName.Raw I.Interface -> TypeEnv.GlobalTypeEnv
interfacesTypeEnv ifaces =
    Dict.foldl
        (\moduleName (I.Interface data) acc ->
            let
                moduleTypeEnv =
                    { home = ModuleName.Canonical data.home moduleName
                    , unions = Dict.map (\_ iUnion -> I.extractUnion iUnion) data.unions
                    , aliases = Dict.map (\_ iAlias -> I.extractAlias iAlias) data.aliases
                    }
            in
            Data.Map.insert ModuleName.toComparableCanonical moduleTypeEnv.home moduleTypeEnv acc
        )
        Data.Map.empty
        ifaces


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
            interfacesTypeEnv Basic.testIfaces
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
                    ( []
                    , A.At A.zero
                        (Src.Call
                            (A.At A.zero (Src.VarQual Src.LowVar "Elm.Kernel.Debug" "toString"))
                            ( [], testValueRef )
                            []
                        )
                    )
                    []
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


{-| Creates an expectation that the graph has a node array that is not empty.
-}
verifyMonoGraph : Mono.MonoGraph -> Expect.Expectation
verifyMonoGraph (Mono.MonoGraph data) =
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
