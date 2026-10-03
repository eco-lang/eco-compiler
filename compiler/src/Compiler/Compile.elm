module Compiler.Compile exposing
    ( compile, compileTyped
    , Artifacts(..), TypedArtifacts(..), TypedArtifactsData
    )

{-| Orchestrates the full compilation pipeline from source to optimized artifacts.

This module provides the main entry points for compiling Elm modules. It coordinates
the complete transformation from parsed source code through canonicalization, type
checking, pattern match verification, and optimization.

The compilation pipeline consists of four phases:

1.  **Canonicalization** - Resolves all names to their home modules
2.  **Type Checking** - Infers and verifies types via constraint solving
3.  **Nitpicking** - Verifies pattern match exhaustiveness
4.  **Optimization** - Produces efficient intermediate representation


# Compilation

@docs compile, compileTyped


# Artifacts

@docs Artifacts, TypedArtifacts, TypedArtifactsData

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.LocalOpt.Erased.Module as Optimize
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Nitpick.PatternMatches as PatternMatches
import Compiler.Reporting.Error as E
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Compiler.Reporting.Result as ReportingResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Constrain.Typed.Module as TypeTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Type
import Compiler.Type.SolverRoots as SolverRoots
import Compiler.Type.Vars as Vars
import Compiler.TypedCanonical.Build as TCanBuild
import Dict
import System.IO
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)
import Utils.Main as Utils



-- ====== Artifacts ======


{-| Compilation artifacts produced by the standard compilation pipeline.

Contains the canonical AST, type annotations for all definitions, and the
optimized local graph suitable for JavaScript code generation.

-}
type Artifacts
    = Artifacts Can.Module (Dict.Dict Name (Can.Annotation Name)) Opt.LocalGraph


{-| Extended compilation artifacts with typed optimization for MLIR backend.

In addition to standard artifacts, includes a typed optimization graph that
preserves full type information throughout the optimization process. This
enables type-directed optimizations and direct lowering to MLIR.

-}
type alias TypedArtifactsData =
    { canonical : Can.Module
    , annotations : Dict.Dict Name (Can.Annotation Name)
    , objects : Opt.LocalGraph -- Opt.emptyLocalGraph on the typed path (plan S5)
    , typedObjects : TOpt.LocalGraph Name
    , typeEnv : TypeEnv.ModuleTypeEnv
    }


{-| Wrapper for typed compilation artifacts.
-}
type TypedArtifacts
    = TypedArtifacts TypedArtifactsData



-- ====== Compilation ======


{-| Compiles an Elm module through the complete pipeline.

Executes all compilation phases in sequence:

1.  Canonicalization - resolves names and imports
2.  Type checking - infers and verifies types
3.  Pattern match analysis - ensures exhaustiveness
4.  Optimization - produces efficient intermediate representation

Returns artifacts suitable for JavaScript code generation.

-}
compile : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error Artifacts)
compile pkg ifaces modul =
    let
        modName : Name
        modName =
            Src.getName modul
    in
    -- Phase logs: emit one stderr line per pipeline phase so we can see
    -- which phase the compiler is working in (canonicalize / type-check /
    -- nitpick / optimize). Each phase boundary is also a Task scheduling
    -- point, so even when the pipeline is single-threaded the GC has a
    -- chance to interleave between phases. The original implementation
    -- ran the whole pipeline inside one Task.succeed, which made the
    -- outside world blind to per-phase progress.
    phase modName "canonicalize"
        |> Task.map (\_ -> canonicalize pkg ifaces modul)
        |> Task.andThen
            (\canonicalResult ->
                case canonicalResult of
                    Ok canonical ->
                        phase modName "type-check"
                            |> Task.map (\_ -> typeCheck modul canonical)
                            |> Task.andThen
                                (\tcResult ->
                                    phase modName "nitpick"
                                        |> Task.map (\_ -> nitpick canonical)
                                        |> Task.andThen
                                            (\nitpickResult ->
                                                case Result.map2 (\annotations () -> annotations) tcResult nitpickResult of
                                                    Ok annotations ->
                                                        phase modName "optimize"
                                                            |> Task.map
                                                                (\_ ->
                                                                    optimize modul annotations canonical
                                                                        |> Result.map (\objects -> Artifacts canonical annotations objects)
                                                                )

                                                    Err err ->
                                                        Task.succeed (Err err)
                                            )
                                )

                    Err err ->
                        Task.succeed (Err err)
            )


{-| Phase boundary used as a Task scheduling point. Returning a fresh
`Task.succeed ()` between phases lets the runtime interleave GC and other
work between canonicalize/type-check/nitpick/optimize even when the pipeline
is otherwise single-threaded.
-}
phase : Name -> String -> Task Never ()
phase _ _ =
    Task.succeed ()


{-| Compiles an Elm module with typed optimization for native code generation.

Performs canonicalization, type checking, nitpicking and typed optimization, producing:

  - `Opt.LocalGraph` - always `Opt.emptyLocalGraph`: the erased optimizer does not run
    on the typed path (plan S5), because nothing on that path reads the erased graph
  - `TOpt.LocalGraph Name` - Typed optimized IR with preserved type information

The typed optimization phase preserves type information needed for monomorphization
and direct lowering to MLIR/LLVM.

-}
compileTyped : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error TypedArtifacts)
compileTyped pkg ifaces modul =
    let
        modName : Name
        modName =
            Src.getName modul
    in
    phase modName "canonicalize"
        |> Task.map (\_ -> canonicalize pkg ifaces modul)
        |> Task.andThen
            (\canonicalResult ->
                case canonicalResult of
                    Ok canonical ->
                        let
                            moduleTypeEnv : TypeEnv.ModuleTypeEnv
                            moduleTypeEnv =
                                TypeEnv.fromCanonical canonical
                        in
                        phase modName "type-check"
                            |> Task.andThen (\_ -> stampGuardEnabled)
                            |> Task.andThen
                                (\census ->
                                    case typeCheckTyped modul canonical census of
                                        Ok { annotations, typedCanonical, nodeTypes, kernelEnv, nodeVars, annotationVars, allSchemeRoots, stampWalked, stampSkipped, annWalked, annSkipped } ->
                                            -- Stamping-guard census (§8.3.2),
                                            -- env-gated so it costs one env
                                            -- read per module and prints
                                            -- nothing on a normal build. One
                                            -- line PER MODULE, summed
                                            -- externally: the alternative was
                                            -- plumbing a counter from the
                                            -- type-check phase to a report
                                            -- rendered in the mono phase.
                                            emitStampGuard census modName stampWalked stampSkipped annWalked annSkipped
                                                |> Task.andThen
                                                    (\_ -> phase modName "nitpick")
                                                |> Task.map (\_ -> nitpick canonical)
                                                |> Task.andThen
                                                    (\nitpickResult ->
                                                        case nitpickResult of
                                                            Ok () ->
                                                                -- Plan S5: the erased optimizer no longer runs on the
                                                                -- typed path. Its graph was never read there (no .eco
                                                                -- write, stripUntypedGraph discarded it), and the
                                                                -- typed optimizer raises the identical BadMains errors.
                                                                phase modName "typed-opt"
                                                                    |> Task.map
                                                                        (\_ ->
                                                                            typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots typedCanonical
                                                                                |> Result.map
                                                                                    (\typedObjects ->
                                                                                        TypedArtifacts
                                                                                            { canonical = canonical
                                                                                            , annotations = annotations
                                                                                            , objects =
                                                                                                case typedObjects of
                                                                                                    TOpt.LocalGraph d ->
                                                                                                        Opt.typedPathStub (d.main /= Nothing)
                                                                                            , typedObjects = typedObjects
                                                                                            , typeEnv = moduleTypeEnv
                                                                                            }
                                                                                    )
                                                                        )

                                                            Err err ->
                                                                Task.succeed (Err err)
                                                    )

                                        Err err ->
                                            Task.succeed (Err err)
                                )

                    Err err ->
                        Task.succeed (Err err)
            )



-- ====== Helpers ======
-- ====== Internal Compilation Phases ======
-- Converts source AST to canonical form, resolving all names and imports.


canonicalize : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Result E.Error Can.Module
canonicalize pkg ifaces modul =
    case Tuple.second (ReportingResult.run (Canonicalize.canonicalize pkg ifaces modul)) of
        Ok canonical ->
            Ok canonical

        Err errors ->
            Err (E.BadNames errors)



-- Infers and verifies types for all definitions in the canonical module.


typeCheck : Src.Module -> Can.Module -> Result E.Error (Dict.Dict Name (Can.Annotation Name))
typeCheck modul canonical =
    case TypeErased.constrain canonical |> TypeCheck.andThen Type.run |> TypeCheck.unsafePerformIO of
        Ok annotations ->
            Ok annotations

        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)



-- Type checks a module and produces a TypedCanonical module with per-expression types.


{-| Type check a module and produce both annotations and a TypedCanonical module.

This function extends the standard type checking to also build a TypedCanonical
module where every expression is paired with its inferred type. This is useful
for downstream phases that need access to per-expression type information.

Also runs the PostSolve phase to fix remaining Group B expression types (Str, Chr, Float, Unit) and compute
kernel function types for typed optimization.

-}
typeCheckTyped :
    Src.Module
    -> Can.Module
    -> Bool
    ->
        Result
            E.Error
            { annotations : Dict.Dict Name (Can.Annotation Name)
            , typedCanonical : TCan.Module
            , nodeTypes : TCan.ExprTypes
            , nodeVars : TCan.ExprVars
            , kernelEnv : KernelTypes.KernelTypeEnv
            , annotationVars : Dict.Dict Name Vars.Variable
            , allSchemeRoots : SolverRoots.AllSchemeRoots

            -- Stamping-guard census (plans/lss-provenance-ratio-census.md
            -- §8.3.2): how many node types ENTERED the arrow-root walk versus
            -- were skipped for want of a solver variable. This is the one
            -- number that splits the `stampwalk:` census's `none` bucket into
            -- "the walk failed at the root" (repairable) and "the walk never
            -- ran" (not repairable by fixing the walk).
            , stampWalked : Int
            , stampSkipped : Int
            , annWalked : Int
            , annSkipped : Int
            }
typeCheckTyped modul canonical census =
    let
        ioResult =
            TypeTyped.constrainWithIds canonical
                |> TypeCheck.andThen
                    (\( constraint, nodeVars, schemeBinderVars ) ->
                        Type.runWithIds constraint nodeVars
                            |> TypeCheck.map (\result -> ( result, schemeBinderVars ))
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        ( Err errors, _ ) ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)

        ( Ok { annotations, annotationVars, nodeTypes, nodeVars, solverState }, schemeBinderVars ) ->
            let
                -- Normalize solver vars to union-find roots
                rootedNodeVars =
                    SolverRoots.normalizeNodeVars solverState nodeVars

                rootedAnnotationVars =
                    SolverRoots.normalizeAnnotationVars solverState annotationVars

                -- Normalize scheme binder vars to roots (from annotated Can.TypedDef defs)
                annotatedSchemeRoots =
                    SolverRoots.normalizeAllSchemeRoots solverState schemeBinderVars

                -- Extract binder roots for unannotated Can.Def defs (Step 2.4)
                inferredSchemeRoots =
                    Dict.foldl
                        (\defName annotation acc ->
                            if Dict.member defName annotatedSchemeRoots then
                                -- Already has roots from Can.TypedDef path
                                acc

                            else
                                case Dict.get defName annotationVars of
                                    Just annotVar ->
                                        let
                                            roots =
                                                SolverRoots.extractBinderRootsFromInferred
                                                    solverState
                                                    annotation
                                                    annotVar
                                        in
                                        if Dict.isEmpty roots then
                                            acc

                                        else
                                            Dict.insert defName roots acc

                                    Nothing ->
                                        acc
                        )
                        Dict.empty
                        annotations

                -- Merge annotated + inferred roots
                normalizedSchemeRoots =
                    Dict.foldl
                        (\defName roots acc -> Dict.insert defName roots acc)
                        annotatedSchemeRoots
                        inferredSchemeRoots

                -- Run PostSolve to fix remaining Group B types and compute kernel env
                postSolveResult =
                    PostSolve.postSolve annotations canonical nodeTypes

                fixedNodeTypes =
                    postSolveResult.nodeTypes

                kernelEnv =
                    postSolveResult.kernelEnv

                -- Phase 2b (plans/lss-unknown-elimination.md §4.9): stamp every
                -- arrow with its own union-find ROOT INDEX, here and nowhere
                -- else, because THIS is the last point where `solverState` is
                -- live. Downstream, `AssignMVarIds` resolves each
                -- `(moduleKey, rootIdx)` to a global `ArrowId`, so two arrows
                -- the type checker unified end up sharing one lambda-set slot.
                --
                -- Unconditional, NOT flag-gated: the index rides `Can.Type` and
                -- therefore the cached artifact, so gating it here would key
                -- the on-disk format to a mono-time flag. Solver-root arrow ids
                -- gates whether AssignMVarIds USES it.
                --
                -- The index is meaningless without its module, and the walk
                -- leaves any subtree it cannot follow in lockstep as `NoArrow`
                -- (degrading to a Phase-2a occurrence id, never to a wrong id).
                stampedNodeTypes =
                    Array.indexedMap
                        (\i maybeType ->
                            case ( maybeType, Maybe.withDefault Nothing (Array.get i rootedNodeVars) ) of
                                ( Just t, Just v ) ->
                                    Just (SolverRoots.stampArrowRoots solverState t v)

                                _ ->
                                    maybeType
                        )
                        fixedNodeTypes

                -- Census of THIS guard (§8.3.2). The `( Just t, Just v )` arm
                -- is the only one that enters the walk; everything else is a
                -- node the walk never saw, which no repair to
                -- `stampArrowRoots` can reach. Counted over the same array and
                -- with the same condition as the stamping above, so the two
                -- cannot drift.
                --
                -- Gated on `census` and allocation-free. It used to run on
                -- every compile of every module and to build a whole second
                -- array — one `( maybeType, maybeVar )` tuple per expression
                -- node — just to fold it down to two Ints that a normal build
                -- never prints. The indexed loop below reads both arrays in
                -- place; its Int accumulators are unboxed and its tuple result
                -- is multi-value, so nothing is allocated.
                stampGuardCounts =
                    if census then
                        stampGuardGo 0 0 0

                    else
                        ( 0, 0 )

                nodeTypeCount : Int
                nodeTypeCount =
                    Array.length fixedNodeTypes

                stampGuardGo : Int -> Int -> Int -> ( Int, Int )
                stampGuardGo i walked skipped =
                    if i >= nodeTypeCount then
                        ( walked, skipped )

                    else
                        case Maybe.withDefault Nothing (Array.get i fixedNodeTypes) of
                            Nothing ->
                                stampGuardGo (i + 1) walked skipped

                            Just _ ->
                                case Maybe.withDefault Nothing (Array.get i rootedNodeVars) of
                                    Just _ ->
                                        stampGuardGo (i + 1) (walked + 1) skipped

                                    Nothing ->
                                        stampGuardGo (i + 1) walked (skipped + 1)

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

                -- The SECOND stamping guard (§8.3.2). Censused separately from
                -- the node-type guard because a skip here has the same
                -- consequence — a type the walk never entered — and the two
                -- populations are very different sizes (annotations are
                -- per-def; node types are per-expression).
                annGuardCounts =
                    if census then
                        Dict.foldl
                            (\defName _ ( walked, skipped ) ->
                                case Dict.get defName rootedAnnotationVars of
                                    Just _ ->
                                        ( walked + 1, skipped )

                                    Nothing ->
                                        ( walked, skipped + 1 )
                            )
                            ( 0, 0 )
                            annotations

                    else
                        ( 0, 0 )
            in
            Ok
                { annotations = stampedAnnotations
                , typedCanonical = TCanBuild.fromCanonical canonical stampedNodeTypes rootedNodeVars
                , nodeTypes = stampedNodeTypes
                , kernelEnv = kernelEnv
                , nodeVars = rootedNodeVars
                , annotationVars = rootedAnnotationVars
                , allSchemeRoots = normalizedSchemeRoots
                , stampWalked = Tuple.first stampGuardCounts
                , stampSkipped = Tuple.second stampGuardCounts
                , annWalked = Tuple.first annGuardCounts
                , annSkipped = Tuple.second annGuardCounts
                }



-- Verifies pattern match exhaustiveness and detects redundant patterns.


{-| Stamping-guard census (plans/lss-provenance-ratio-census.md §8.3.2).

Splits the `stampwalk:` census's `none` bucket, which conflates two populations
needing opposite work: a type the walk ENTERED and failed at the root (a walk
failure, repairable by fixing `stampArrowRoots`) versus one it never entered for
want of a solver variable (not repairable there at all).

Emitted per module on stderr rather than plumbed to the LSS report, because the
count arises in the TYPE-CHECK phase and that report renders in the MONO phase;
threading it would touch `Compile`, `Build` and `Generate` for a diagnostic. Sum
the lines externally.

`ECO_STAMP_GUARD_CENSUS=1`. Off by default, so a normal build pays one env read
per module and prints nothing.

-}
emitStampGuard : Bool -> Name -> Int -> Int -> Int -> Int -> Task Never ()
emitStampGuard census modName walked skipped annW annS =
    if census then
        System.IO.writeLn System.IO.stderr
            ("[stampguard] walked="
                ++ String.fromInt walked
                ++ " skipped="
                ++ String.fromInt skipped
                ++ " annWalked="
                ++ String.fromInt annW
                ++ " annSkipped="
                ++ String.fromInt annS
                ++ " module="
                ++ modName
            )

    else
        Task.succeed ()


{-| Read `ECO_STAMP_GUARD_CENSUS` once per module. The flag now gates the
COUNTING as well as the printing: off (the default) the two guard censuses are
not computed at all, so a normal build pays this env read and nothing else.
-}
stampGuardEnabled : Task Never Bool
stampGuardEnabled =
    Utils.envLookupEnv "ECO_STAMP_GUARD_CENSUS"
        |> Task.map
            (\maybeVal ->
                case maybeVal of
                    Just v ->
                        v == "1" || v == "true" || v == "yes"

                    Nothing ->
                        False
            )


nitpick : Can.Module -> Result E.Error ()
nitpick canonical =
    case PatternMatches.check canonical of
        Ok () ->
            Ok ()

        Err errors ->
            Err (E.BadPatterns errors)



-- Optimizes the canonical module to produce efficient intermediate representation.


optimize : Src.Module -> Dict.Dict Name.Name (Can.Annotation Name) -> Can.Module -> Result E.Error Opt.LocalGraph
optimize modul annotations canonical =
    case Tuple.second (ReportingResult.run (Optimize.optimize annotations canonical)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)



-- Performs typed optimization preserving full type information for MLIR backend.
-- Performs typed optimization from a TypedCanonical module.


typedOptimizeFromTyped : Src.Module -> Dict.Dict Name.Name (Can.Annotation Name) -> TCan.ExprTypes -> TCan.ExprVars -> KernelTypes.KernelTypeEnv -> Dict.Dict Name.Name Vars.Variable -> SolverRoots.AllSchemeRoots -> TCan.Module -> Result E.Error (TOpt.LocalGraph Name)
typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots tcanModule =
    case Tuple.second (ReportingResult.run (TypedOptimize.optimizeTyped annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots tcanModule)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)
