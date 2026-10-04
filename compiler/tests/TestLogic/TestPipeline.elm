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
    , runSolverMonoWithLimits
    , runSolverMonoWithReport
    , runSubstMonoWithLimits
    , runToAssigned
    , runToGlobalOpt
    , runToGlobalOptLssAllKeyedOn
    , runToGlobalOptLssArrowIdOn
    , runToGlobalOptLssOn
    , runToMlir
    , runToMono
    , runToPostSolve
    , runToTypeCheck
    , runToTypedOpt
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
`runToMono`, `runToGlobalOpt`, `runToMlir` and `runToGlobalOptLssOn` (with its
aliases) return the _cumulative artifacts_ of their stage: one record holding
that stage's output together with the outputs of the earlier stages it ran,
so that a test can inspect any of them. `runToAssigned`,
`runToGlobalOptLssOnStats` and the three `run*MonoWith*` functions return only
their own stage's result. A stage that fails gives `Err` with a message; for
canonicalization and type checking it carries only a count of errors, and for
typed optimization nothing about the error. A stage that crashes is not
caught.

From `runToTypedOpt` on, the program is first given a _synthetic main_:
`wrapWithMain` appends a `main` that binds `testValue` in a `let` and returns
`Html.text "test main"`. That `main` is a valid entry point for the typed
optimizer, and it makes `testValue` reachable from the entry point that
monomorphization starts at. A program run through these stages must define
`testValue`, or the test run crashes. `runToCanonical`, `runToTypeCheck` and
`runToPostSolve` do not add a `main`.

Two monomorphizer engines are used. `runToMono`, `runToGlobalOpt`,
`runToMlir`, `runSubstMonoWithLimits` and `expectCoverageRun` use the
substitution engine, `Compiler.Monomorphize.Monomorphize`.
`runToGlobalOptLssOn` and its two aliases, `runToGlobalOptLssOnStats`,
`runSolverMonoWithLimits` and `runSolverMonoWithReport` use the solver engine,
`Compiler.MonoSolver.Monomorphize`, which is the default engine of a build
(`Compiler.Eco.Config`).

The stages follow `Compiler.Compile` and `Builder.Generate`. Among the
differences a test can observe: the typed optimizer is given no scheme roots,
the pattern match checker is not run, neither alias forwarding nor
eta-expansion is run before monomorphization, no pruning follows the
post-monomorphization inliner, global optimization runs with the default
configuration, and MLIR comes from
`Compiler.Generate.MLIR.Backend.generateMlirModule`, not from the streaming
writers a build uses.

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
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Backend as MLIR
import Compiler.Generate.Mode as Mode
import Compiler.GlobalOpt.MonoGlobalOptimize as MonoGlobalOptimize
import Compiler.GlobalOpt.MonoInlineSimplify as MonoInlineSimplify
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.MonoSolver.Monomorphize as MonoSolver
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.Monomorphize as Monomorphize
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

-}
type alias TypeCheckArtifacts =
    { canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , nodeTypes : Array (Maybe (Can.Type Name))
    , nodeVars : Array (Maybe Vars.Variable)
    , solverState : { cells : Array Vars.PointCell }
    , annotationVars : Dict Name.Name Vars.Variable
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
constructor and a node for each kernel alias in `aliasedKernels`. `runToMono`
fills `monoGraph` from the substitution engine.

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

`monoGraph` is the graph before both passes. It comes from the substitution
engine when `runToGlobalOpt` builds the record and from the solver engine when
`runToGlobalOptLssOn` does.

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

                Ok { annotations, nodeTypes, nodeVars, solverState, annotationVars } ->
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypes
                        , nodeVars = nodeVars
                        , solverState = solverState
                        , annotationVars = annotationVars
                        }


{-| Runs `runToTypeCheck` on `srcModule` and then PostSolve on its node types,
keeping the node types from both before and after.
-}
runToPostSolve : Src.Module -> Result String PostSolveArtifacts
runToPostSolve srcModule =
    case runToTypeCheck srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, nodeVars, solverState, annotationVars } ->
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
                }


{-| Adds the synthetic `main` to `srcModule` with `wrapWithMain`, runs it
through PostSolve, and builds its typed local graph.

Between PostSolve and the typed optimizer it does what `Compiler.Compile`
does at that point: it resolves the node and annotation variables to their
union-find roots and stamps solver roots into the arrows of the node types
and annotations. Without this step every arrow in a test program would carry
`NoArrow`, and the solver engine, which gives arrows that share a solver root
one identity, would find none to share. The typed optimizer is given an empty
scheme-roots table, where `Compiler.Compile` passes the roots of the solver's
scheme variables.

Any error from the typed optimizer gives the same `Err` message.

-}
runToTypedOpt : Src.Module -> Result String TypedOptArtifacts
runToTypedOpt srcModule =
    case runToPostSolve (wrapWithMain srcModule) of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypesPost, kernelEnv, nodeVars, solverState, annotationVars } ->
            let
                rootedNodeVars =
                    SolverRoots.normalizeNodeVars solverState nodeVars

                rootedAnnotationVars =
                    SolverRoots.normalizeAnnotationVars solverState annotationVars

                stampedNodeTypes =
                    Array.indexedMap
                        (\i maybeType ->
                            case ( maybeType, Maybe.withDefault Nothing (Array.get i rootedNodeVars) ) of
                                ( Just t, Just v ) ->
                                    Just (SolverRoots.stampArrowRoots solverState t v)

                                _ ->
                                    maybeType
                        )
                        nodeTypesPost

                stampedAnnotations =
                    Dict.map
                        (\defName ann ->
                            case Dict.get defName rootedAnnotationVars of
                                Just annotVar ->
                                    SolverRoots.stampArrowRootsInAnnotation solverState ann annotVar

                                Nothing ->
                                    ann
                        )
                        annotations

                typedModule =
                    TCanBuild.fromCanonical canonical stampedNodeTypes rootedNodeVars
            in
            case RResult.run (TypedOptimize.optimizeTyped stampedAnnotations stampedNodeTypes rootedNodeVars kernelEnv rootedAnnotationVars Dict.empty typedModule) of
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


{-| Runs `runToTypedOpt` on `srcModule` and monomorphizes the result with the
substitution engine, starting from `main`.
-}
runToMono : Src.Module -> Result String MonoArtifacts
runToMono srcModule =
    case runToTypedOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph } ->
            let
                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical
            in
            case monomorphizeAny globalTypeEnv globalGraph of
                Err monoErr ->
                    Err ("Monomorphization failed: " ++ monoErr)

                Ok monoGraph ->
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypes
                        , kernelEnv = kernelEnv
                        , localGraph = localGraph
                        , globalGraph = globalGraph
                        , globalTypeEnv = globalTypeEnv
                        , monoGraph = monoGraph
                        }


{-| Returns the global graph of `runToMono` for `srcModule` after
`Compiler.Monomorphize.EntryPrep.assign` has given it its ids, which is the
kind of graph the pre-monomorphization passes work on in a build.

It uses the assignment flags of the substitution engine, `( False, False )`,
so arrows that share a solver root are not given a shared identity. It runs
the whole of `runToMono`, monomorphization included, so it fails whenever
`runToMono` does.

-}
runToAssigned : Src.Module -> Result String EntryPrep.Assigned
runToAssigned srcModule =
    Result.map
        (\artifacts -> EntryPrep.assign ( False, False ) "main" artifacts.globalGraph)
        (runToMono srcModule)


{-| Runs `runToMono` on `srcModule`, then the post-monomorphization inliner
(`Compiler.GlobalOpt.MonoInlineSimplify.optimize`) and
`Compiler.GlobalOpt.MonoGlobalOptimize.globalOptimize`, both with the default
configuration. What the global optimizer does is described in
`Compiler.GlobalOpt.MonoGlobalOptimize`.
-}
runToGlobalOpt : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOpt srcModule =
    case runToMono srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph, globalGraph, globalTypeEnv, monoGraph } ->
            let
                ( simplifiedGraph, _ ) =
                    MonoInlineSimplify.optimize Config.default.inline monoGraph

                optimizedMonoGraph =
                    MonoGlobalOptimize.globalOptimize simplifiedGraph
            in
            Ok
                { canonical = canonical
                , annotations = annotations
                , nodeTypes = nodeTypes
                , kernelEnv = kernelEnv
                , localGraph = localGraph
                , globalGraph = globalGraph
                , globalTypeEnv = globalTypeEnv
                , monoGraph = monoGraph
                , optimizedMonoGraph = optimizedMonoGraph
                }


{-| Runs `runToTypedOpt` on `srcModule`, monomorphizes with the solver engine
and the default lambda-set specialization configuration, which has
lambda-set specialization on, and then runs the inliner and global optimizer
as `runToGlobalOpt` does.

This is the engine and lambda-set configuration of a default build.
`runToGlobalOptLssArrowIdOn` and `runToGlobalOptLssAllKeyedOn` are the same
function under other names.

-}
runToGlobalOptLssOn : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOptLssOn =
    runToGlobalOptLssKeyedWith


{-| Runs `runToGlobalOptLssOn`; it is the same function under another name.
-}
runToGlobalOptLssArrowIdOn : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOptLssArrowIdOn =
    runToGlobalOptLssKeyedWith


{-| Runs `runToGlobalOptLssOn`; it is the same function under another name.
-}
runToGlobalOptLssAllKeyedOn : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOptLssAllKeyedOn =
    runToGlobalOptLssKeyedWith


{-| Runs the pipeline `runToGlobalOptLssOn` describes; `runToGlobalOptLssOn`
and its two aliases are bound to this function.
-}
runToGlobalOptLssKeyedWith : Src.Module -> Result String GlobalOptArtifacts
runToGlobalOptLssKeyedWith srcModule =
    case runToTypedOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph } ->
            let
                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical

                defaultLss =
                    Config.defaultLss

                lssOn =
                    { defaultLss | enabled = True }
            in
            case MonoSolver.monomorphize lssOn "main" globalTypeEnv globalGraph of
                Err monoErr ->
                    Err ("Monomorphization (solver + lss) failed: " ++ monoErr)

                Ok monoGraph ->
                    let
                        ( simplifiedGraph, _ ) =
                            MonoInlineSimplify.optimize Config.default.inline monoGraph

                        optimizedMonoGraph =
                            MonoGlobalOptimize.globalOptimize simplifiedGraph
                    in
                    Ok
                        { canonical = canonical
                        , annotations = annotations
                        , nodeTypes = nodeTypes
                        , kernelEnv = kernelEnv
                        , localGraph = localGraph
                        , globalGraph = globalGraph
                        , globalTypeEnv = globalTypeEnv
                        , monoGraph = monoGraph
                        , optimizedMonoGraph = optimizedMonoGraph
                        }


{-| Runs `runToTypedOpt` on `srcModule` and monomorphizes the result with the
solver engine under the given `limits` and `lssConfig`, returning the graph
without global optimization.

The limits are the specialization watchdog's, so a test can give small ones
and check that a program whose specializations keep growing ends in `Err`.

-}
runSolverMonoWithLimits : Config.SpecLimits -> Config.LssConfig -> Src.Module -> Result String Mono.MonoGraph
runSolverMonoWithLimits limits lssConfig srcModule =
    case runToTypedOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, localGraph } ->
            let
                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical
            in
            Result.map Tuple.first
                (MonoSolver.monomorphizeWithReport lssConfig limits "main" globalTypeEnv globalGraph)


{-| Does what `runSolverMonoWithLimits` does with `report` set in `lssConfig`,
and returns the rendered lambda-set specialization report alongside the
graph, so that a test can check the report's counter lines.
`Compiler.MonoSolver.Monomorphize` gives the report as `Just` whenever
`report` is set.
-}
runSolverMonoWithReport : Config.SpecLimits -> Config.LssConfig -> Src.Module -> Result String ( Mono.MonoGraph, Maybe String )
runSolverMonoWithReport limits lssConfig srcModule =
    case runToTypedOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, localGraph } ->
            let
                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical
            in
            MonoSolver.monomorphizeWithReport { lssConfig | report = True } limits "main" globalTypeEnv globalGraph


{-| Runs `runToTypedOpt` on `srcModule` and monomorphizes the result with the
substitution engine under the given watchdog `limits`, as
`runSolverMonoWithLimits` does for the solver engine.
-}
runSubstMonoWithLimits : Config.SpecLimits -> Src.Module -> Result String Mono.MonoGraph
runSubstMonoWithLimits limits srcModule =
    case runToTypedOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, localGraph } ->
            let
                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical
            in
            Monomorphize.monomorphizeWithLimits limits "main" globalTypeEnv globalGraph


{-| Runs `runToGlobalOpt` on `srcModule` and generates MLIR from the optimized
graph in development mode.

The text in `mlirOutput` comes from a second generation of the same graph.
That generation always succeeds, so `runToMlir` fails only when an earlier
stage does.

-}
runToMlir : Src.Module -> Result String MlirArtifacts
runToMlir srcModule =
    case runToGlobalOpt srcModule of
        Err e ->
            Err e

        Ok { canonical, annotations, nodeTypes, kernelEnv, localGraph, globalGraph, globalTypeEnv, optimizedMonoGraph } ->
            let
                mlirModule =
                    MLIR.generateMlirModule (Mode.Dev Nothing) optimizedMonoGraph

                mlirOutput =
                    case runMLIRGeneration optimizedMonoGraph of
                        Ok output ->
                            output

                        Err _ ->
                            ""
            in
            Ok
                { canonical = canonical
                , annotations = annotations
                , nodeTypes = nodeTypes
                , kernelEnv = kernelEnv
                , localGraph = localGraph
                , globalGraph = globalGraph
                , globalTypeEnv = globalTypeEnv
                , monoGraph = optimizedMonoGraph
                , mlirModule = mlirModule
                , mlirOutput = mlirOutput
                }



-- ============================================================================
-- LOW-LEVEL HELPERS
-- ============================================================================


{-| Builds the IO action that generates `modul`'s constraints with node ids
recorded and solves them, giving the solver's results or the number of type
errors.
-}
runWithIdsTypeCheck : Can.Module -> IO.IO (Result Int { annotations : Dict Name.Name (Can.Annotation Name), nodeTypes : Array (Maybe (Can.Type Name)), nodeVars : Array (Maybe Vars.Variable), solverState : { cells : Array Vars.PointCell }, annotationVars : Dict Name.Name Vars.Variable })
runWithIdsTypeCheck modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars, _ ) ->
                Solve.runWithIds constraint nodeVars
            )
        |> IO.map
            (\result ->
                case result of
                    Ok data ->
                        Ok
                            { annotations = data.annotations
                            , nodeTypes = data.nodeTypes
                            , nodeVars = data.nodeVars
                            , solverState = data.solverState
                            , annotationVars = data.annotationVars
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


{-| Monomorphizes `globalGraph` with the substitution engine and its default
limits, starting from `main`. Monomorphization can still fail; the `Err`
carries the engine's message.
-}
monomorphizeAny : TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphizeAny globalTypeEnv globalGraph =
    Monomorphize.monomorphize "main" globalTypeEnv globalGraph


{-| Returns the module with the synthetic `main` appended to its values:

    main =
        let
            _tv =
                testValue
        in
        Html.text "test main"

It also appends `import Html exposing (text)` unless the module already has an
import of `Html`. The `main` has no annotation; its type is that of the mock
`Html.text`'s result, a `VirtualDom.Node`, which the typed optimizer accepts as
a static `main`.

A module with no `testValue` crashes the test run (`Debug.todo`). A module
that already defines `main` gets a second one, so canonicalization fails.

-}
wrapWithMain : Src.Module -> Src.Module
wrapWithMain (Src.Module data) =
    let
        valueNames =
            List.filterMap
                (\(A.At _ (Src.Value vdata)) ->
                    let
                        ( _, A.At _ name ) =
                            vdata.name
                    in
                    if name == "main" then
                        Nothing

                    else
                        Just name
                )
                data.values

        defs =
            if List.member "testValue" valueNames then
                [ Src.Define
                    (A.At A.zero "_tv")
                    []
                    ( [], varRef "testValue" )
                    Nothing
                ]

            else
                Debug.todo "Test module must define 'testValue' — see SourceIR test standard"

        body =
            A.At A.zero
                (Src.Call
                    (A.At A.zero (Src.VarQual Src.LowVar "Html" "text"))
                    [ ( [], A.At A.zero (Src.Str "test main" False) ) ]
                )

        mainExpr =
            case defs of
                [] ->
                    body

                _ ->
                    A.At A.zero
                        (Src.Let
                            (List.map (\d -> ( ( [], [] ), A.At A.zero d )) defs)
                            []
                            body
                        )

        mainValue =
            Src.Value
                { comments = []
                , name = ( [], A.At A.zero "main" )
                , args = []
                , body = ( [], mainExpr )
                , tipe = Nothing
                }

        hasHtmlImport =
            List.any
                (\(Src.Import ( _, A.At _ importName ) _ _) -> importName == "Html")
                data.imports

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
                if hasHtmlImport then
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


{-| Generates MLIR text for `monoGraph` through the MLIR back end's code
generator interface, in development mode. It never returns `Err`.
-}
runMLIRGeneration : Mono.MonoGraph -> Result String String
runMLIRGeneration monoGraph =
    let
        config =
            { sourceMaps = CodeGen.NoSourceMaps
            , leadingLines = 0
            , mode = Mode.Dev Nothing
            , graph = monoGraph
            }

        output =
            MLIR.backend.generate config
    in
    Ok (CodeGen.outputToString output)



-- ============================================================================
-- EXPECTATION HELPERS
-- ============================================================================


{-| Creates an expectation that `srcModule` gets through `runToTypedOpt`, and
then runs the rest of the substitution-engine pipeline on it (monomorphization,
the inliner, global optimization and MLIR generation) only so that the code
runs.

It fails only when a stage up to typed optimization returns `Err`. A
monomorphization `Err` passes, and so does any outcome after it; nothing is
recorded about them. A stage that crashes still ends the test.

-}
expectCoverageRun : Src.Module -> Expect.Expectation
expectCoverageRun srcModule =
    case runToTypedOpt srcModule of
        Err msg ->
            Expect.fail ("Invalid test case (frontend failure): " ++ msg)

        Ok typedOptArtifacts ->
            let
                { canonical, localGraph } =
                    typedOptArtifacts

                globalGraph =
                    localGraphToGlobalGraph localGraph

                globalTypeEnv =
                    buildGlobalTypeEnv canonical
            in
            case monomorphizeAny globalTypeEnv globalGraph of
                Err _ ->
                    Expect.pass

                Ok monoGraph ->
                    let
                        ( simplifiedGraph, _ ) =
                            MonoInlineSimplify.optimize Config.default.inline monoGraph

                        optimizedMonoGraph =
                            MonoGlobalOptimize.globalOptimize simplifiedGraph
                    in
                    case runMLIRGeneration optimizedMonoGraph of
                        Err _ ->
                            Expect.pass

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
