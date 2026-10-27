module Compiler.Compile exposing
    ( compile, compileTyped
    , Artifacts(..), TypedArtifacts(..), TypedArtifactsData
    )

{-| Turns one parsed module into the per-module results the rest of the
compiler builds on, or into the error that stops it.

There are two front ends, one per back end. Both canonicalize the module
(resolve every name to the module that defines it), type check it, check that
its pattern matches are exhaustive and have no redundant patterns
(_nitpicking_), and optimize it into a local graph of definitions.

`compile` is the _erased path_, used for JavaScript: the type checker yields
only each definition's annotation, and the erased optimizer
(`Compiler.LocalOpt.Erased.Module`) produces an `Opt.LocalGraph`.

`compileTyped` is the _typed path_, used for native code. It is dominated by
one fact: the solver's union-find store, in which variables the type checker
proved equal share one _root_, exists only while this module is type checking.
So everything the typed back end needs from it is copied out here: node and
annotation variables are replaced by their roots, the _scheme roots_ of each
definition that has any are recorded, and `Compiler.Type.PostSolve` fills in the remaining
expression types and the types of kernel functions. Then, in the node types
and annotations that have a solver variable, the function arrows the stamping
walk reaches are _stamped_ with the index of their root, as
`Compiler.Type.SolverRoots` describes. The typed optimizer (`Compiler.LocalOpt.Typed.Module`) produces a
`TOpt.LocalGraph`. The erased optimizer does not run on this path.

Errors are wrapped by phase: canonicalization errors in `E.BadNames`, type
errors in `E.BadTypes`, pattern errors in `E.BadPatterns`, and optimizer errors
in `E.BadMains`.


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
import Compiler.AST.TypeVars as Vars
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
import Compiler.TypedCanonical.Build as TCanBuild
import Dict
import System.IO
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)
import Utils.Main as Utils



-- ====== Artifacts ======


{-| What the erased path produces for one module: the canonical module, the
annotation of each top-level definition by name, and the erased local graph.
-}
type Artifacts
    = Artifacts Can.Module (Dict.Dict Name (Can.Annotation Name)) Opt.LocalGraph


{-| What the typed path produces for one module.

`annotations` have their arrows stamped with solver roots where they have a
solver variable. `objects` is not an erased graph: it is `Opt.typedPathStub`, which is empty except that it records
whether the module has a `main`. `typedObjects` is the typed local graph, and
`typeEnv` is the module's type environment, built from the canonical module
by `TypeEnv.fromCanonical`.

-}
type alias TypedArtifactsData =
    { canonical : Can.Module
    , annotations : Dict.Dict Name (Can.Annotation Name)
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph Name
    , typeEnv : TypeEnv.ModuleTypeEnv
    }


{-| What the typed path produces for one module, as described at
`TypedArtifactsData`.
-}
type TypedArtifacts
    = TypedArtifacts TypedArtifactsData



-- ====== Compilation ======


{-| Compiles `modul` of package `pkg` along the erased path, given the
interfaces of the modules it imports.

Type checking and nitpicking both run before either result is looked at, and
when both fail the type error is the one returned. The optimizer runs only
when both succeed.

-}
compile : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error Artifacts)
compile pkg ifaces modul =
    phase
        |> Task.map (\_ -> canonicalize pkg ifaces modul)
        |> Task.andThen
            (\canonicalResult ->
                case canonicalResult of
                    Ok canonical ->
                        phase
                            |> Task.map (\_ -> typeCheck modul canonical)
                            |> Task.andThen
                                (\tcResult ->
                                    phase
                                        |> Task.map (\_ -> nitpick canonical)
                                        |> Task.andThen
                                            (\nitpickResult ->
                                                case Result.map2 (\annotations () -> annotations) tcResult nitpickResult of
                                                    Ok annotations ->
                                                        phase
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


{-| A task that does nothing and succeeds, placed between the phases of
`compile` and `compileTyped`. Each phase runs in a `Task.map` or
`Task.andThen` after one of these, rather than all of them being computed
before the first task starts.
-}
phase : Task Never ()
phase =
    Task.succeed ()


{-| Compiles `modul` of package `pkg` along the typed path, given the
interfaces of the modules it imports.

Unlike `compile`, nitpicking runs only once type checking has succeeded. When
the `ECO_STAMP_GUARD_CENSUS` environment variable is `1`, `true` or `yes`, one
line per module is written to stderr counting the node types and annotations
that the arrow-root stamping did and did not enter (see `typeCheckTyped`).

-}
compileTyped : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error TypedArtifacts)
compileTyped pkg ifaces modul =
    let
        modName : Name
        modName =
            Src.getName modul
    in
    phase
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
                        phase
                            |> Task.andThen (\_ -> stampGuardEnabled)
                            |> Task.andThen
                                (\census ->
                                    case typeCheckTyped modul canonical census of
                                        Ok { annotations, typedCanonical, nodeTypes, kernelEnv, nodeVars, annotationVars, allSchemeRoots, stampWalked, stampSkipped, annWalked, annSkipped } ->
                                            emitStampGuard census modName stampWalked stampSkipped annWalked annSkipped
                                                |> Task.andThen
                                                    (\_ -> phase)
                                                |> Task.map (\_ -> nitpick canonical)
                                                |> Task.andThen
                                                    (\nitpickResult ->
                                                        case nitpickResult of
                                                            Ok () ->
                                                                phase
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



-- ====== Internal Compilation Phases ======


{-| Canonicalizes `modul`, wrapping any naming errors in `E.BadNames`.
-}
canonicalize : Pkg.Name -> Dict.Dict ModuleName.Raw I.Interface -> Src.Module -> Result E.Error Can.Module
canonicalize pkg ifaces modul =
    case Tuple.second (ReportingResult.run (Canonicalize.canonicalize pkg ifaces modul)) of
        Ok canonical ->
            Ok canonical

        Err errors ->
            Err (E.BadNames errors)


{-| Type checks `canonical` along the erased path, returning the annotation of
each top-level definition, or the type errors in `E.BadTypes`.
-}
typeCheck : Src.Module -> Can.Module -> Result E.Error (Dict.Dict Name (Can.Annotation Name))
typeCheck modul canonical =
    case TypeErased.constrain canonical |> TypeCheck.andThen Type.run |> TypeCheck.unsafePerformIO of
        Ok annotations ->
            Ok annotations

        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)


{-| Type checks `canonical` along the typed path and copies out of the solver
everything the typed back end needs, before the solver's state is dropped.

On success it returns the annotations and node types with every arrow the
stamping walk reaches stamped with its solver root, the node and annotation
variables replaced by their roots, the scheme roots of each definition that
has any, the
kernel type environment from `PostSolve`, and the `TypedCanonical` module built
from the stamped node types. Scheme roots of a definition with a written
annotation come from the type checker's binder variables; those of any other
definition are found by walking its inferred annotation, and a definition for
which that walk finds none gets no entry.

A node type or annotation without a solver variable is not stamped. When
`census` is true, the four counts report how many node types (of those
present) and annotations had a variable and so entered the walk, and how many
were skipped; when it is false they are all zero.

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

            -- Stamping counts, all zero unless `census` is true
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
                rootedNodeVars =
                    SolverRoots.normalizeNodeVars solverState nodeVars

                rootedAnnotationVars =
                    SolverRoots.normalizeAnnotationVars solverState annotationVars

                annotatedSchemeRoots =
                    SolverRoots.normalizeAllSchemeRoots solverState schemeBinderVars

                inferredSchemeRoots =
                    Dict.foldl
                        (\defName annotation acc ->
                            if Dict.member defName annotatedSchemeRoots then
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

                normalizedSchemeRoots =
                    Dict.foldl
                        (\defName roots acc -> Dict.insert defName roots acc)
                        annotatedSchemeRoots
                        inferredSchemeRoots

                postSolveResult =
                    PostSolve.postSolve annotations canonical nodeTypes

                fixedNodeTypes =
                    postSolveResult.nodeTypes

                kernelEnv =
                    postSolveResult.kernelEnv

                -- Stamped here because this is the last point where `solverState`
                -- is live. Unconditional: the stamps are part of the cached artifact.
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

                -- Counted with the same condition as the stamping above.
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


{-| Writes one `[stampguard]` line to stderr when `census` is true, giving the
four stamping counts from `typeCheckTyped` and the module name; does nothing
otherwise.

`skipped` counts the node types the walk never entered for want of a solver
variable; `walked` counts those it entered, whether or not every arrow was
stamped.

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


{-| A task reading whether the `ECO_STAMP_GUARD_CENSUS` environment variable is
`1`, `true` or `yes`. When it is not, the stamping counts are not computed.
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


{-| Checks the pattern matches of `canonical` for missing and redundant
patterns, wrapping any errors in `E.BadPatterns`.
-}
nitpick : Can.Module -> Result E.Error ()
nitpick canonical =
    case PatternMatches.check canonical of
        Ok () ->
            Ok ()

        Err errors ->
            Err (E.BadPatterns errors)


{-| Runs the erased optimizer over `canonical`, wrapping any errors in
`E.BadMains`.
-}
optimize : Src.Module -> Dict.Dict Name.Name (Can.Annotation Name) -> Can.Module -> Result E.Error Opt.LocalGraph
optimize modul annotations canonical =
    case Tuple.second (ReportingResult.run (Optimize.optimize annotations canonical)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)


{-| Runs the typed optimizer over the typed canonical module and the solver
information copied out of the type check, wrapping any errors in `E.BadMains`.
-}
typedOptimizeFromTyped : Src.Module -> Dict.Dict Name.Name (Can.Annotation Name) -> TCan.ExprTypes -> TCan.ExprVars -> KernelTypes.KernelTypeEnv -> Dict.Dict Name.Name Vars.Variable -> SolverRoots.AllSchemeRoots -> TCan.Module -> Result E.Error (TOpt.LocalGraph Name)
typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots tcanModule =
    case Tuple.second (ReportingResult.run (TypedOptimize.optimizeTyped annotations nodeTypes nodeVars kernelEnv annotationVars allSchemeRoots tcanModule)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)
