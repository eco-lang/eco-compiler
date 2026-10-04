module Compiler.PackageCompilation exposing
    ( CompileResult, CompileError(..), PathwayDiscrepancy
    , parseModule
    , compileModule, compileModulesInOrder
    , monomorphize
    , errorToString
    , TypeCheckTypedResult, generateMLIRFromResult
    )

{-| Lets a test compile the source of a package module, such as elm/core's
`Elm.JsArray` or `Array`, from a string, with no files and no build, and see
whether the compiler's two pipelines agree on it.

The compiler type-checks and optimizes a module in one of two ways, called
_pathways_ here. The _erased_ pathway type-checks with
`Compiler.Type.Solve.run`, which yields only the annotations of top-level
values, and optimizes with `Compiler.LocalOpt.Erased.Module` into the graph the
JavaScript back end uses. The _typed_ pathway generates constraints that record
a solver variable for every expression and pattern, solves them with
`Compiler.Type.Solve.runWithIds`, completes the per-node types with
`Compiler.Type.PostSolve`, and optimizes with `Compiler.LocalOpt.Typed.Module`
into the typed graph that monomorphization starts from. Parsing,
canonicalization and the pattern-match check are run once and shared.

A module is compiled as a module of a given package, and the package decides
what the module may do. In a kernel package (one whose author is `elm`,
`elm-explorations` or `eco`) a module may declare infix operators and refer to
kernel modules such as `Elm.Kernel.JsArray`, which is what elm/core's own
source does; a module of elm/core itself also gets no default imports.

Comparing the pathways means comparing whether each succeeded and how many
errors each reported, once after type checking and once after optimization. If
one pathway fails and the other succeeds, or both fail with different numbers
of errors, the result is a `PathwayMismatch`. If both fail with the same number
of errors, the erased pathway's errors are reported as an ordinary
`TypeError` or `OptimizeError`, whatever either pathway's errors say. If both
succeed, nothing is compared: the typed annotations are not checked against
the erased ones, and the annotations and interface in a `CompileResult` are the
erased pathway's.

A compiled module's typed graph can then be carried on through
monomorphization and MLIR generation. That path differs from the compiler's:
it uses the substitution monomorphizer
(`Compiler.Monomorphize.Monomorphize`), starts from one defined value chosen by
name order rather than from a `main`, takes its type information from
`Compiler.Elm.Interface.Basic.testIfaces` rather than from the interfaces the
module was compiled against, and hands the result to the MLIR back end without
the global optimization passes.


# Results

@docs CompileResult, CompileError, PathwayDiscrepancy


# Parsing

@docs parseModule


# Compilation

@docs compileModule, compileModulesInOrder


# Typed Pathway - Monomorphization

@docs monomorphize


# Error Formatting

@docs errorToString


# Typed Pathway - Type-Check Result and MLIR

@docs TypeCheckTypedResult, generateMLIRFromResult

-}

import Array exposing (Array)
import Builder.GraphAssembly as GA
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Backend as MLIR
import Compiler.Generate.Mode as Mode
import Compiler.LocalOpt.Erased.Module as Optimize
import Compiler.LocalOpt.Typed.Module as TypedOptimize
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.Nitpick.PatternMatches as PatternMatches
import Compiler.Parse.Module as Parse
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanonicalizeError
import Compiler.Reporting.Error.Main as MainError
import Compiler.Reporting.Error.Syntax as Syntax
import Compiler.Reporting.Error.Type as TypeError
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Constrain.Typed.Module as TypeTyped
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Type
import Compiler.Type.Vars as Vars
import Compiler.TypedCanonical.Build as TCanBuild
import Data.Map
import Dict exposing (Dict)
import System.TypeCheck.IO as TypeCheck



-- ============================================================================
-- RESULT TYPES
-- ============================================================================


{-| Everything produced by compiling one module through both pathways.

`objects` is the erased pathway's optimized graph and `typedObjects` the typed
pathway's. `annotations` and `interface` come from the erased pathway.

-}
type alias CompileResult =
    { moduleName : ModuleName.Raw
    , source : Src.Module
    , canonical : Can.Module
    , annotations : Dict Name.Name (Can.Annotation Name)
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph Name
    , interface : I.Interface
    }


{-| What stopped a module from compiling, named by the phase that failed.

`ParseError`, `CanonicalizeError` and `PatternError` carry the errors of the
shared parse, canonicalization and pattern-match check. The pattern-match
check runs only once both pathways have type-checked.

`TypeError` and `OptimizeError` carry the erased pathway's errors, and occur
only when both pathways failed in that phase with the same number of errors.

`MonomorphizeError` carries a message. Only `monomorphize` and
`generateMLIRFromResult` produce it.

`PathwayMismatch` means the two pathways disagreed, as `PathwayDiscrepancy`
describes.

-}
type CompileError
    = ParseError Syntax.Error
    | CanonicalizeError (OneOrMore.OneOrMore CanonicalizeError.Error)
    | TypeError (NE.Nonempty TypeError.Error)
    | PatternError (NE.Nonempty PatternMatches.Error)
    | OptimizeError (OneOrMore.OneOrMore MainError.Error)
    | MonomorphizeError String
    | PathwayMismatch PathwayDiscrepancy


{-| A phase in which the erased and typed pathways disagreed, with both
pathways' results for that phase. Disagreeing means that one pathway failed
while the other succeeded, or that both failed with different numbers of
errors.

`TypeCheckMismatch` carries the two type-checking results.

`OptimizeMismatch` carries the two optimization results. It occurs only when
both pathways type-checked and the pattern-match check passed.

-}
type PathwayDiscrepancy
    = TypeCheckMismatch
        { erasedResult : Result (NE.Nonempty TypeError.Error) (Dict Name.Name (Can.Annotation Name))
        , typedResult : Result (NE.Nonempty TypeError.Error) TypeCheckTypedResult
        }
    | OptimizeMismatch
        { erasedResult : Result (OneOrMore.OneOrMore MainError.Error) Opt.LocalGraph
        , typedResult : Result (OneOrMore.OneOrMore MainError.Error) (TOpt.LocalGraph Name)
        }


{-| What type checking on the typed pathway produces for one module, which is
what its optimizer needs.

`nodeTypes` are the per-node types after `Compiler.Type.PostSolve` has
completed them, and `typedCanonical` is built from those. `nodeVars` and
`annotationVars` are the solver variables recorded for each node and for each
top-level annotation.

-}
type alias TypeCheckTypedResult =
    { annotations : Dict Name.Name (Can.Annotation Name)
    , typedCanonical : TCan.Module
    , nodeTypes : TCan.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , nodeVars : Array (Maybe Vars.Variable)
    , annotationVars : Dict Name.Name Vars.Variable
    }



-- ============================================================================
-- PARSING
-- ============================================================================


{-| Parses `source` as a module of the package `pkg`.

The package decides what is accepted. A module of a kernel package may declare
infix operators and be an effect module, and a module of elm/core gets no
default imports. Kernel references such as `Elm.Kernel.JsArray.empty` parse as
ordinary qualified names in any package; it is canonicalization that accepts
them.

-}
parseModule : Pkg.Name -> String -> Result Syntax.Error Src.Module
parseModule pkg source =
    Parse.fromByteString (Parse.Package pkg) source



-- ============================================================================
-- SINGLE MODULE COMPILATION
-- ============================================================================


{-| Compiles a parsed module of the package `pkg` through both pathways,
against `ifaces`, the interfaces of the modules it may import, keyed by the
name an import uses.

The module is canonicalized, type-checked on both pathways, checked for
pattern-match errors, and optimized on both pathways. The first phase to fail
gives the error. After type checking and again after optimization, one pathway
failing while the other succeeds, or both failing with different numbers of
errors, gives a `PathwayMismatch`; both failing with the same number gives the
erased pathway's errors. When everything succeeds nothing is compared, and the
result's annotations and interface are the erased pathway's.

-}
compileModule :
    Pkg.Name
    -> Dict ModuleName.Raw I.Interface
    -> Src.Module
    -> Result CompileError CompileResult
compileModule pkg ifaces srcModule =
    canonicalize pkg ifaces srcModule
        |> Result.andThen
            (\canonical ->
                let
                    erasedTypeCheckResult =
                        typeCheckErased canonical

                    typedTypeCheckResult =
                        typeCheckTyped canonical
                in
                case ( erasedTypeCheckResult, typedTypeCheckResult ) of
                    ( Ok erasedAnnotations, Ok typedResult ) ->
                        nitpick canonical
                            |> Result.andThen
                                (\() ->
                                    let
                                        erasedOptResult =
                                            optimizeErased erasedAnnotations canonical

                                        typedOptResult =
                                            optimizeTyped typedResult.annotations typedResult.nodeTypes typedResult.nodeVars typedResult.kernelEnv typedResult.annotationVars typedResult.typedCanonical
                                    in
                                    case ( erasedOptResult, typedOptResult ) of
                                        ( Ok objects, Ok typedObjects ) ->
                                            Ok
                                                { moduleName = Src.getName srcModule
                                                , source = srcModule
                                                , canonical = canonical
                                                , annotations = erasedAnnotations
                                                , objects = objects
                                                , typedObjects = typedObjects
                                                , interface = I.fromModule pkg canonical erasedAnnotations
                                                }

                                        ( Err erasedErr, Err typedErr ) ->
                                            let
                                                erasedCount =
                                                    List.length (OneOrMore.destruct (::) erasedErr)

                                                typedCount =
                                                    List.length (OneOrMore.destruct (::) typedErr)
                                            in
                                            if erasedCount == typedCount then
                                                Err (OptimizeError erasedErr)

                                            else
                                                Err
                                                    (PathwayMismatch
                                                        (OptimizeMismatch
                                                            { erasedResult = Err erasedErr
                                                            , typedResult = Err typedErr
                                                            }
                                                        )
                                                    )

                                        _ ->
                                            Err
                                                (PathwayMismatch
                                                    (OptimizeMismatch
                                                        { erasedResult = erasedOptResult
                                                        , typedResult = typedOptResult
                                                        }
                                                    )
                                                )
                                )

                    ( Err erasedErr, Err typedErr ) ->
                        let
                            (NE.Nonempty _ erasedRest) =
                                erasedErr

                            (NE.Nonempty _ typedRest) =
                                typedErr

                            erasedCount =
                                1 + List.length erasedRest

                            typedCount =
                                1 + List.length typedRest
                        in
                        if erasedCount == typedCount then
                            Err (TypeError erasedErr)

                        else
                            Err
                                (PathwayMismatch
                                    (TypeCheckMismatch
                                        { erasedResult = Err erasedErr
                                        , typedResult = Err typedErr
                                        }
                                    )
                                )

                    _ ->
                        Err
                            (PathwayMismatch
                                (TypeCheckMismatch
                                    { erasedResult = erasedTypeCheckResult
                                    , typedResult = typedTypeCheckResult
                                    }
                                )
                            )
            )



-- ============================================================================
-- MULTI-MODULE COMPILATION
-- ============================================================================


{-| Parses and compiles each of `sources` in turn as a module of the package
`pkg`, as `compileModule` does, starting from the interfaces `baseIfaces`.

Each compiled module's interface is added to the interfaces the next module is
compiled against, replacing any base interface of the same name, so `sources`
must list a module after the modules it imports. Returns the results in the
order of `sources`, or the first failure with the name of the module that
failed. A source that does not parse has no name yet and is reported as
`"unknown"`.

-}
compileModulesInOrder :
    Pkg.Name
    -> Dict ModuleName.Raw I.Interface
    -> List String
    -> Result ( CompileError, ModuleName.Raw ) (List CompileResult)
compileModulesInOrder pkg baseIfaces sources =
    compileModulesHelper pkg baseIfaces sources []


{-| Compiles `sources` as `compileModulesInOrder` does, against `ifaces`, with
`results` holding the modules already compiled, most recent first.
-}
compileModulesHelper :
    Pkg.Name
    -> Dict ModuleName.Raw I.Interface
    -> List String
    -> List CompileResult
    -> Result ( CompileError, ModuleName.Raw ) (List CompileResult)
compileModulesHelper pkg ifaces sources results =
    case sources of
        [] ->
            Ok (List.reverse results)

        source :: rest ->
            case parseModule pkg source of
                Err syntaxErr ->
                    Err ( ParseError syntaxErr, "unknown" )

                Ok srcModule ->
                    let
                        moduleName =
                            Src.getName srcModule
                    in
                    case compileModule pkg ifaces srcModule of
                        Err err ->
                            Err ( err, moduleName )

                        Ok result ->
                            let
                                newIfaces =
                                    Dict.insert result.moduleName result.interface ifaces
                            in
                            compileModulesHelper pkg newIfaces rest (result :: results)



-- ============================================================================
-- INTERNAL COMPILATION PHASES
-- ============================================================================


{-| Canonicalizes a module of the package `pkg` against `ifaces`, discarding
any warnings.
-}
canonicalize : Pkg.Name -> Dict ModuleName.Raw I.Interface -> Src.Module -> Result CompileError Can.Module
canonicalize pkg ifaces modul =
    case Tuple.second (RResult.run (Canonicalize.canonicalize pkg ifaces modul)) of
        Ok canonical ->
            Ok canonical

        Err errors ->
            Err (CanonicalizeError errors)


{-| Type-checks a canonical module on the erased pathway, returning the
annotations of its top-level values or the solver's errors.
-}
typeCheckErased : Can.Module -> Result (NE.Nonempty TypeError.Error) (Dict Name.Name (Can.Annotation Name))
typeCheckErased canonical =
    TypeErased.constrain canonical
        |> TypeCheck.andThen Type.run
        |> TypeCheck.unsafePerformIO


{-| Type-checks a canonical module on the typed pathway, returning everything
the typed optimizer needs, or the solver's errors.

The solver's per-node types are passed through `Compiler.Type.PostSolve`, which
completes them and computes the kernel type environment, before the typed
canonical module is built from them.

-}
typeCheckTyped : Can.Module -> Result (NE.Nonempty TypeError.Error) TypeCheckTypedResult
typeCheckTyped canonical =
    let
        ioResult =
            TypeTyped.constrainWithIds canonical
                |> TypeCheck.andThen
                    (\( constraint, nodeVars, _ ) ->
                        Type.runWithIds constraint nodeVars
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        Err errors ->
            Err errors

        Ok { annotations, annotationVars, nodeTypes, nodeVars } ->
            let
                postSolveResult =
                    PostSolve.postSolve annotations canonical nodeTypes

                fixedNodeTypes =
                    postSolveResult.nodeTypes

                kernelEnv =
                    postSolveResult.kernelEnv
            in
            Ok
                { annotations = annotations
                , typedCanonical = TCanBuild.fromCanonical canonical fixedNodeTypes nodeVars
                , nodeTypes = fixedNodeTypes
                , kernelEnv = kernelEnv
                , nodeVars = nodeVars
                , annotationVars = annotationVars
                }


{-| Runs the pattern-match check of `Compiler.Nitpick.PatternMatches` on a
canonical module.
-}
nitpick : Can.Module -> Result CompileError ()
nitpick canonical =
    case PatternMatches.check canonical of
        Ok () ->
            Ok ()

        Err errors ->
            Err (PatternError errors)


{-| Optimizes a type-checked module on the erased pathway, using its erased
`annotations`, discarding any warnings.
-}
optimizeErased : Dict Name.Name (Can.Annotation Name) -> Can.Module -> Result (OneOrMore.OneOrMore MainError.Error) Opt.LocalGraph
optimizeErased annotations canonical =
    Tuple.second (RResult.run (Optimize.optimize annotations canonical))


{-| Optimizes a typed canonical module on the typed pathway, discarding any
warnings.

The optimizer is given an empty map of scheme roots. `Compiler.Compile`
instead stamps solver roots onto the node types and annotations and passes the
solver's scheme roots, so the typed graph built here can differ from the
compiler's.

-}
optimizeTyped : Dict Name.Name (Can.Annotation Name) -> TCan.ExprTypes -> TCan.ExprVars -> KernelTypes.KernelTypeEnv -> Dict Name.Name Vars.Variable -> TCan.Module -> Result (OneOrMore.OneOrMore MainError.Error) (TOpt.LocalGraph Name)
optimizeTyped annotations nodeTypes nodeVars kernelEnv annotationVars tcanModule =
    Tuple.second (RResult.run (TypedOptimize.optimizeTyped annotations nodeTypes nodeVars kernelEnv annotationVars Dict.empty tcanModule))



-- ============================================================================
-- TYPED PATHWAY - MONOMORPHIZATION AND MLIR
-- ============================================================================


{-| Monomorphizes the typed graph of `result` with the substitution engine,
`Compiler.Monomorphize.Monomorphize`, or gives a `MonomorphizeError` with its
message.

The graph holds only this module's definitions. The candidates for the entry
point are the module's top-level values and the constructors of its closed
record aliases, and the one chosen is the candidate whose name sorts first as
a string. Capitals sort before lower case, so a record alias constructor wins
over any value, and the choice need not be a function. A recursive function,
whether it calls itself or belongs to a mutually recursive group, is not a
candidate. A module with no candidate fails.

Type information comes from the module's own types together with the
interfaces of `Compiler.Elm.Interface.Basic.testIfaces`, which include mocks of
`Elm.JsArray` and `Array`, whatever interfaces the module was compiled
against. The module's own types replace any interface's for the same module.

-}
monomorphize : CompileResult -> Result CompileError Mono.MonoGraph
monomorphize result =
    monomorphizeWithIfaces extendedTestIfaces result


{-| Monomorphizes the typed graph of `result` as `monomorphize` does, taking
type information from `ifaces` and the module's own types.
-}
monomorphizeWithIfaces : Dict ModuleName.Raw I.Interface -> CompileResult -> Result CompileError Mono.MonoGraph
monomorphizeWithIfaces ifaces result =
    let
        globalGraph =
            GA.addTypedLocalGraph result.typedObjects TOpt.emptyGlobalGraph

        globalTypeEnv =
            buildGlobalTypeEnvWithIfaces ifaces result.canonical
    in
    case monomorphizeAny globalTypeEnv globalGraph of
        Ok monoGraph ->
            Ok monoGraph

        Err errMsg ->
            Err (MonomorphizeError errMsg)


{-| Returns the unions and aliases of every module in `ifaces` together with
those of `canModule`, which replace any interface's entry for the same module.
-}
buildGlobalTypeEnvWithIfaces : Dict ModuleName.Raw I.Interface -> Can.Module -> TypeEnv.GlobalTypeEnv
buildGlobalTypeEnvWithIfaces ifaces canModule =
    let
        ifaceTypeEnv =
            TypeEnv.fromInterfaces ifaces

        moduleTypeEnv =
            TypeEnv.fromCanonical canModule
    in
    Data.Map.insert ModuleName.toComparableCanonical moduleTypeEnv.home moduleTypeEnv ifaceTypeEnv


{-| The interfaces `monomorphize` takes type information from. They are exactly
`Compiler.Elm.Interface.Basic.testIfaces`.
-}
extendedTestIfaces : Dict ModuleName.Raw I.Interface
extendedTestIfaces =
    Basic.testIfaces


{-| Monomorphizes a typed global graph from the entry point that
`findAnyEntryPoint` chooses. With no entry point the error is
`"No function found in graph"`; any other error is the monomorphizer's.

The graph's field counts and annotations are emptied before it is handed to
the monomorphizer; its nodes, scheme roots and super-types are kept.

-}
monomorphizeAny : TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph
monomorphizeAny globalTypeEnv (TOpt.GlobalGraph nodes _ _ schemeRoots varSupers) =
    case findAnyEntryPoint nodes of
        Nothing ->
            Err "No function found in graph"

        Just ( TOpt.Global _ name, _ ) ->
            Monomorphize.monomorphize name globalTypeEnv (TOpt.GlobalGraph nodes Dict.empty Data.Map.empty schemeRoots varSupers)


{-| Returns the global name and type of the first `Define` or `TrackedDefine`
node of `nodes`, in the order of the nodes' keys.

A key is the home module followed by the name, compared as a string; the
`TOpt.compareGlobal` passed to the fold is ignored. Within one module that
makes it the definition whose name sorts first, and since a closed record
alias's constructor is a `Define` and capitals sort first, such a constructor
is chosen over any value. Recursive definitions are `Cycle` nodes and are
never chosen.

-}
findAnyEntryPoint : Data.Map.Dict String TOpt.Global (TOpt.Node Name) -> Maybe ( TOpt.Global, Can.Type Name )
findAnyEntryPoint nodes =
    Data.Map.foldl
        (\global node acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case node of
                        TOpt.Define _ _ meta ->
                            Just ( global, meta.tipe )

                        TOpt.TrackedDefine _ _ _ meta ->
                            Just ( global, meta.tipe )

                        _ ->
                            Nothing
        )
        Nothing
        nodes


{-| Returns the MLIR text the MLIR back end generates for `monoGraph` in
development mode, without source maps.

The graph goes to the back end as monomorphization left it, without the global
optimization passes the compiler runs first.

-}
generateMLIR : Mono.MonoGraph -> String
generateMLIR monoGraph =
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
    CodeGen.outputToString output


{-| Monomorphizes the typed graph of `result` as `monomorphize` does and returns
the MLIR text the MLIR back end generates for it, in development mode.

The monomorphized graph goes to the back end without the global optimization
passes the compiler runs first. The result is an `Err` only when
monomorphization fails.

-}
generateMLIRFromResult : CompileResult -> Result CompileError String
generateMLIRFromResult result =
    case monomorphize result of
        Err err ->
            Err err

        Ok monoGraph ->
            Ok (generateMLIR monoGraph)



-- ============================================================================
-- ERROR FORMATTING
-- ============================================================================


{-| Returns a short description of a `CompileError` for a test failure message.

The detail varies by phase. A parse error names its kind, or is just
`"Syntax error"` when the parser itself failed. Canonicalization errors are
counted and listed one phrase each, and type errors counted and listed one
line each with the row and column where each starts. Pattern-match and
optimization errors give only a count, and a monomorphization error gives its
message. A pathway mismatch gives each pathway's outcome and,
for type checking, the type errors of each pathway that failed.

-}
errorToString : CompileError -> String
errorToString error =
    case error of
        ParseError syntaxErr ->
            "Parse error: " ++ syntaxErrorToString syntaxErr

        CanonicalizeError errors ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                count =
                    List.length errorList
            in
            "Canonicalize error (" ++ String.fromInt count ++ " error(s)): " ++ canonicalizeErrorsToString errorList

        TypeError errors ->
            let
                (NE.Nonempty first rest) =
                    errors

                count =
                    1 + List.length rest
            in
            "Type error (" ++ String.fromInt count ++ " error(s)):\n" ++ typeErrorsToString (first :: rest)

        PatternError errors ->
            let
                (NE.Nonempty _ rest) =
                    errors

                count =
                    1 + List.length rest
            in
            "Pattern match error (" ++ String.fromInt count ++ " error(s))"

        OptimizeError errors ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                count =
                    List.length errorList
            in
            "Optimization error (" ++ String.fromInt count ++ " error(s))"

        MonomorphizeError msg ->
            "Monomorphization error: " ++ msg

        PathwayMismatch discrepancy ->
            "PATHWAY MISMATCH: " ++ discrepancyToString discrepancy


{-| Returns a description of a `PathwayDiscrepancy`: whether each pathway passed
or failed, with its error count, and for a type-checking mismatch the type
errors of each pathway that failed.
-}
discrepancyToString : PathwayDiscrepancy -> String
discrepancyToString discrepancy =
    case discrepancy of
        TypeCheckMismatch { erasedResult, typedResult } ->
            let
                erasedStatus =
                    case erasedResult of
                        Ok _ ->
                            "PASSED"

                        Err errors ->
                            let
                                (NE.Nonempty _ rest) =
                                    errors
                            in
                            "FAILED (" ++ String.fromInt (1 + List.length rest) ++ " error(s))"

                typedStatus =
                    case typedResult of
                        Ok _ ->
                            "PASSED"

                        Err errors ->
                            let
                                (NE.Nonempty _ rest) =
                                    errors
                            in
                            "FAILED (" ++ String.fromInt (1 + List.length rest) ++ " error(s))"

                details =
                    case ( erasedResult, typedResult ) of
                        ( Err erasedErrors, Ok _ ) ->
                            let
                                (NE.Nonempty first rest) =
                                    erasedErrors
                            in
                            "\n  Erased errors:\n" ++ typeErrorsToString (first :: rest)

                        ( Ok _, Err typedErrors ) ->
                            let
                                (NE.Nonempty first rest) =
                                    typedErrors
                            in
                            "\n  Typed errors:\n" ++ typeErrorsToString (first :: rest)

                        ( Err erasedErrors, Err typedErrors ) ->
                            let
                                (NE.Nonempty ef er) =
                                    erasedErrors

                                (NE.Nonempty tf tr) =
                                    typedErrors
                            in
                            "\n  Erased errors:\n"
                                ++ typeErrorsToString (ef :: er)
                                ++ "\n  Typed errors:\n"
                                ++ typeErrorsToString (tf :: tr)

                        _ ->
                            ""
            in
            "Type checking mismatch!\n  Erased pathway: "
                ++ erasedStatus
                ++ "\n  Typed pathway: "
                ++ typedStatus
                ++ details

        OptimizeMismatch { erasedResult, typedResult } ->
            let
                erasedStatus =
                    case erasedResult of
                        Ok _ ->
                            "PASSED"

                        Err errors ->
                            "FAILED (" ++ String.fromInt (List.length (OneOrMore.destruct (::) errors)) ++ " error(s))"

                typedStatus =
                    case typedResult of
                        Ok _ ->
                            "PASSED"

                        Err errors ->
                            "FAILED (" ++ String.fromInt (List.length (OneOrMore.destruct (::) errors)) ++ " error(s))"
            in
            "Optimization mismatch!\n  Erased pathway: " ++ erasedStatus ++ "\n  Typed pathway: " ++ typedStatus


{-| Returns a phrase naming the kind of a syntax error. The two module-name
errors also give a module name. An error from the parser itself is only
`"Syntax error"`, with no position or detail.
-}
syntaxErrorToString : Syntax.Error -> String
syntaxErrorToString error =
    case error of
        Syntax.ModuleNameUnspecified name ->
            "Module name unspecified: " ++ name

        Syntax.ModuleNameMismatch expected _ ->
            "Module name mismatch, expected: " ++ expected

        Syntax.UnexpectedPort _ ->
            "Unexpected port declaration"

        Syntax.NoPorts _ ->
            "Ports not allowed"

        Syntax.NoPortsInPackage _ ->
            "Ports not allowed in packages"

        Syntax.NoPortModulesInPackage _ ->
            "Port modules not allowed in packages"

        Syntax.NoEffectsOutsideKernel _ ->
            "Effect modules only allowed in kernel packages"

        Syntax.ParseError _ ->
            "Syntax error"


{-| Returns one line per type error, as `typeErrorToString` describes it.
-}
typeErrorsToString : List TypeError.Error -> String
typeErrorsToString errors =
    errors
        |> List.map typeErrorToString
        |> String.join "\n"


{-| Returns a one-line description of a type error: its kind and the row and
column where its region starts, plus the category of a mismatched expression
or the variable name of an infinite type.
-}
typeErrorToString : TypeError.Error -> String
typeErrorToString error =
    case error of
        TypeError.BadExpr (A.Region (A.Position row col) _) category _ _ ->
            "  - BadExpr at " ++ String.fromInt row ++ ":" ++ String.fromInt col ++ " (" ++ categoryToString category ++ ")"

        TypeError.BadPattern (A.Region (A.Position row col) _) _ _ _ ->
            "  - BadPattern at " ++ String.fromInt row ++ ":" ++ String.fromInt col

        TypeError.InfiniteType (A.Region (A.Position row col) _) name _ ->
            "  - InfiniteType at " ++ String.fromInt row ++ ":" ++ String.fromInt col ++ " for '" ++ name ++ "'"


{-| Returns the name of an expression category, without any name or detail the
category carries.
-}
categoryToString : TypeError.Category -> String
categoryToString category =
    case category of
        TypeError.List ->
            "List"

        TypeError.Number ->
            "Number"

        TypeError.Float ->
            "Float"

        TypeError.String ->
            "String"

        TypeError.Char ->
            "Char"

        TypeError.If ->
            "If"

        TypeError.Case ->
            "Case"

        TypeError.CallResult _ ->
            "CallResult"

        TypeError.Lambda ->
            "Lambda"

        TypeError.Accessor _ ->
            "Accessor"

        TypeError.Access _ ->
            "Access"

        TypeError.Record ->
            "Record"

        TypeError.Tuple ->
            "Tuple"

        TypeError.Unit ->
            "Unit"

        TypeError.Shader ->
            "Shader"

        TypeError.Effects ->
            "Effects"

        TypeError.Local _ ->
            "Local"

        TypeError.Foreign _ ->
            "Foreign"


{-| Returns the canonicalization errors described as `canonicalizeErrorToString`
does, separated by semicolons.
-}
canonicalizeErrorsToString : List CanonicalizeError.Error -> String
canonicalizeErrorsToString errors =
    errors
        |> List.map canonicalizeErrorToString
        |> String.join "; "


{-| Returns a short phrase naming the kind of a canonicalization error and,
for most kinds, the name it concerns. No positions are given.
-}
canonicalizeErrorToString : CanonicalizeError.Error -> String
canonicalizeErrorToString error =
    case error of
        CanonicalizeError.AnnotationTooShort _ _ _ _ ->
            "Annotation too short"

        CanonicalizeError.AmbiguousVar _ _ name _ _ ->
            "Ambiguous variable: " ++ name

        CanonicalizeError.AmbiguousType _ _ name _ _ ->
            "Ambiguous type: " ++ name

        CanonicalizeError.AmbiguousVariant _ _ name _ _ ->
            "Ambiguous variant: " ++ name

        CanonicalizeError.AmbiguousBinop _ name _ _ ->
            "Ambiguous binary operator: " ++ name

        CanonicalizeError.BadArity _ _ name _ _ ->
            "Bad arity: " ++ name

        CanonicalizeError.Binop _ name _ ->
            "Binary operator error: " ++ name

        CanonicalizeError.DuplicateDecl name _ _ ->
            "Duplicate declaration: " ++ name

        CanonicalizeError.DuplicateType name _ _ ->
            "Duplicate type: " ++ name

        CanonicalizeError.DuplicateCtor name _ _ ->
            "Duplicate constructor: " ++ name

        CanonicalizeError.DuplicateBinop name _ _ ->
            "Duplicate binary operator: " ++ name

        CanonicalizeError.DuplicateField name _ _ ->
            "Duplicate field: " ++ name

        CanonicalizeError.DuplicateAliasArg _ name _ _ ->
            "Duplicate alias argument: " ++ name

        CanonicalizeError.DuplicateUnionArg _ name _ _ ->
            "Duplicate union argument: " ++ name

        CanonicalizeError.DuplicatePattern _ name _ _ ->
            "Duplicate pattern: " ++ name

        CanonicalizeError.EffectNotFound _ name ->
            "Effect not found: " ++ name

        CanonicalizeError.EffectFunctionNotFound _ name ->
            "Effect function not found: " ++ name

        CanonicalizeError.ExportDuplicate name _ _ ->
            "Duplicate export: " ++ name

        CanonicalizeError.ExportNotFound _ _ name _ ->
            "Export not found: " ++ name

        CanonicalizeError.ExportOpenAlias _ name ->
            "Cannot export alias with (..): " ++ name

        CanonicalizeError.ImportCtorByName _ name _ ->
            "Constructor imported by name: " ++ name

        CanonicalizeError.ImportNotFound _ name _ ->
            "Import not found: " ++ name

        CanonicalizeError.ImportOpenAlias _ name ->
            "Cannot import alias with (..): " ++ name

        CanonicalizeError.ImportExposingNotFound _ _ name _ ->
            "Import exposing not found: " ++ name

        CanonicalizeError.NotFoundVar _ _ name _ ->
            "Variable not found: " ++ name

        CanonicalizeError.NotFoundType _ _ name _ ->
            "Type not found: " ++ name

        CanonicalizeError.NotFoundVariant _ _ name _ ->
            "Variant not found: " ++ name

        CanonicalizeError.NotFoundBinop _ name _ ->
            "Binary operator not found: " ++ name

        CanonicalizeError.PatternHasRecordCtor _ name ->
            "Pattern has record constructor: " ++ name

        CanonicalizeError.PortPayloadInvalid _ name _ _ ->
            "Invalid port payload: " ++ name

        CanonicalizeError.PortTypeInvalid _ name _ ->
            "Invalid port type: " ++ name

        CanonicalizeError.RecursiveAlias _ name _ _ _ ->
            "Recursive alias: " ++ name

        CanonicalizeError.RecursiveDecl _ name _ ->
            "Recursive declaration: " ++ name

        CanonicalizeError.RecursiveLet (A.At _ name) _ ->
            "Recursive let: " ++ name

        CanonicalizeError.Shadowing name _ _ ->
            "Shadowing: " ++ name

        CanonicalizeError.TupleLargerThanThree _ ->
            "Tuple larger than 3 elements"

        CanonicalizeError.TypeVarsUnboundInUnion _ name _ _ _ ->
            "Unbound type variables in union: " ++ name

        CanonicalizeError.TypeVarsMessedUpInAlias _ name _ _ _ ->
            "Type variables messed up in alias: " ++ name
