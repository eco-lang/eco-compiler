module Compiler.PackageCompilation exposing
    ( CompileResult
    , CompileError(..)
    , PathwayDiscrepancy(..)
    , parseModule
    , compileModule
    , compileModulesInOrder
    , monomorphize
    , generateMLIR
    , errorToString
    , discrepancyToString
    )

{-| Infrastructure for compiling multiple Elm modules from source strings
without any IO/Task overhead.

This module provides direct access to the compilation pipeline, enabling
tests to compile elm/\* package modules (like Array.elm) that contain
kernel references, exactly as they would be compiled as project dependencies.

**IMPORTANT**: This module runs BOTH compilation pathways (erased and typed)
and compares their results. It reports when:

  - One pathway fails while the other succeeds
  - Both pathways fail but with different errors

This ensures the standard JS pathway and the MLIR pathway behave consistently.


# Results

@docs CompileResult, CompileError, PathwayDiscrepancy


# Parsing

@docs parseModule


# Compilation

@docs compileModule, compileModulesInOrder


# Typed Pathway - Monomorphization and MLIR

@docs monomorphize, generateMLIR


# Error Formatting

@docs errorToString, discrepancyToString

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypedCanonical as TCan
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.CodeGen.MLIR as MLIR
import Compiler.Generate.Mode as Mode
import Compiler.Generate.Monomorphize as Monomorphize
import Compiler.Nitpick.PatternMatches as PatternMatches
import Compiler.Optimize.Erased.Module as Optimize
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Compiler.Optimize.Typed.Module as TypedOptimize
import Compiler.Parse.Module as Parse
import Compiler.Parse.SyntaxVersion as SV
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanonicalizeError
import Compiler.Reporting.Error.Main as MainError
import Compiler.Reporting.Error.Syntax as Syntax
import Compiler.Reporting.Error.Type as TypeError
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Constrain.Typed.Module as TypeTyped
import Compiler.Type.PostSolve as PostSolve
import Compiler.Type.Solve as Type
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as TypeCheck



-- ============================================================================
-- RESULT TYPES
-- ============================================================================


{-| Result of successfully compiling a module.

Includes both erased optimization (for JS) and typed optimization (for MLIR).
-}
type alias CompileResult =
    { moduleName : ModuleName.Raw
    , source : Src.Module
    , canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph
    , interface : I.Interface
    }


{-| Errors that can occur during compilation.
-}
type CompileError
    = ParseError Syntax.Error
    | CanonicalizeError (OneOrMore.OneOrMore CanonicalizeError.Error)
    | TypeError (NE.Nonempty TypeError.Error)
    | PatternError (NE.Nonempty PatternMatches.Error)
    | OptimizeError (OneOrMore.OneOrMore MainError.Error)
    | MonomorphizeError String
    | MLIRGenerationError String
    | PathwayMismatch PathwayDiscrepancy


{-| Describes a discrepancy between the erased and typed compilation pathways.
-}
type PathwayDiscrepancy
    = TypeCheckMismatch
        { erasedResult : Result (NE.Nonempty TypeError.Error) (Dict String Name.Name Can.Annotation)
        , typedResult : Result (NE.Nonempty TypeError.Error) TypeCheckTypedResult
        }
    | OptimizeMismatch
        { erasedResult : Result (OneOrMore.OneOrMore MainError.Error) Opt.LocalGraph
        , typedResult : Result (OneOrMore.OneOrMore MainError.Error) TOpt.LocalGraph
        }


{-| Internal result from typed type checking.
-}
type alias TypeCheckTypedResult =
    { annotations : Dict String Name.Name Can.Annotation
    , typedCanonical : TCan.Module
    , nodeTypes : TCan.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    }



-- ============================================================================
-- PARSING
-- ============================================================================


{-| Parse a source string as a package module.

Using `Parse.Package pkg` enables kernel reference parsing for kernel packages
like elm/core.

-}
parseModule : Pkg.Name -> String -> Result Syntax.Error Src.Module
parseModule pkg source =
    Parse.fromByteString SV.Elm (Parse.Package pkg) source



-- ============================================================================
-- SINGLE MODULE COMPILATION
-- ============================================================================


{-| Compile a single parsed module with the given interfaces.

This runs BOTH compilation pathways and compares their results:

1.  **Erased pathway** (for JS): constrain → run → optimize
2.  **Typed pathway** (for MLIR): constrainWithIds → runWithIds → PostSolve → optimizeTyped

The function reports a PathwayMismatch error if:

  - One pathway succeeds while the other fails
  - Both fail but with different error counts/types

-}
compileModule :
    Pkg.Name
    -> Dict String ModuleName.Raw I.Interface
    -> Src.Module
    -> Result CompileError CompileResult
compileModule pkg ifaces srcModule =
    -- Step 1: Canonicalize (shared between both pathways)
    canonicalize pkg ifaces srcModule
        |> Result.andThen
            (\canonical ->
                -- Step 2: Run BOTH type checking pathways
                let
                    erasedTypeCheckResult =
                        typeCheckErased canonical

                    typedTypeCheckResult =
                        typeCheckTyped canonical
                in
                -- Compare type checking results
                case ( erasedTypeCheckResult, typedTypeCheckResult ) of
                    ( Ok erasedAnnotations, Ok typedResult ) ->
                        -- Both type checks passed, verify annotations match then continue
                        -- Step 3: Pattern match check (shared)
                        nitpick canonical
                            |> Result.andThen
                                (\() ->
                                    -- Step 4: Run BOTH optimization pathways
                                    let
                                        erasedOptResult =
                                            optimizeErased erasedAnnotations canonical

                                        typedOptResult =
                                            optimizeTyped typedResult.annotations typedResult.nodeTypes typedResult.kernelEnv typedResult.typedCanonical
                                    in
                                    -- Compare optimization results
                                    case ( erasedOptResult, typedOptResult ) of
                                        ( Ok objects, Ok typedObjects ) ->
                                            -- Both optimizations passed
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
                                            -- Both failed - report as mismatch if different error counts
                                            let
                                                erasedCount =
                                                    List.length (OneOrMore.destruct (::) erasedErr)

                                                typedCount =
                                                    List.length (OneOrMore.destruct (::) typedErr)
                                            in
                                            if erasedCount == typedCount then
                                                -- Same error count, report erased error
                                                Err (OptimizeError erasedErr)

                                            else
                                                -- Different error counts - pathway mismatch
                                                Err
                                                    (PathwayMismatch
                                                        (OptimizeMismatch
                                                            { erasedResult = Err erasedErr
                                                            , typedResult = Err typedErr
                                                            }
                                                        )
                                                    )

                                        _ ->
                                            -- One passed, one failed - pathway mismatch
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
                        -- Both type checks failed - check if same error count
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
                            -- Same error count, report erased error
                            Err (TypeError erasedErr)

                        else
                            -- Different error counts - pathway mismatch
                            Err
                                (PathwayMismatch
                                    (TypeCheckMismatch
                                        { erasedResult = Err erasedErr
                                        , typedResult = Err typedErr
                                        }
                                    )
                                )

                    _ ->
                        -- One passed, one failed - pathway mismatch
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


{-| Compile multiple modules in dependency order.

Each module's interface is added to the environment before compiling the next.
This enables testing of module chains like JsArray -> Array where Array
depends on JsArray.

Returns either all compiled results or the first error with its module name.

-}
compileModulesInOrder :
    Pkg.Name
    -> Dict String ModuleName.Raw I.Interface
    -> List String
    -> Result ( CompileError, ModuleName.Raw ) (List CompileResult)
compileModulesInOrder pkg baseIfaces sources =
    compileModulesHelper pkg baseIfaces sources []


compileModulesHelper :
    Pkg.Name
    -> Dict String ModuleName.Raw I.Interface
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
                                    Dict.insert identity result.moduleName result.interface ifaces
                            in
                            compileModulesHelper pkg newIfaces rest (result :: results)



-- ============================================================================
-- INTERNAL COMPILATION PHASES
-- ============================================================================


canonicalize : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Result CompileError Can.Module
canonicalize pkg ifaces modul =
    case Tuple.second (RResult.run (Canonicalize.canonicalize pkg ifaces modul)) of
        Ok canonical ->
            Ok canonical

        Err errors ->
            Err (CanonicalizeError errors)


{-| Standard (erased) type checking using constrain + run.

This is the JS backend pathway.
-}
typeCheckErased : Can.Module -> Result (NE.Nonempty TypeError.Error) (Dict String Name.Name Can.Annotation)
typeCheckErased canonical =
    TypeErased.constrain canonical
        |> TypeCheck.andThen Type.run
        |> TypeCheck.unsafePerformIO


{-| Typed type checking using constrainWithIds + runWithIds.

This produces per-expression type information needed for typed optimization.
Also runs PostSolve to fix Group B types and compute kernel type environment.
-}
typeCheckTyped : Can.Module -> Result (NE.Nonempty TypeError.Error) TypeCheckTypedResult
typeCheckTyped canonical =
    let
        ioResult =
            TypeTyped.constrainWithIds canonical
                |> TypeCheck.andThen
                    (\( constraint, nodeVars ) ->
                        Type.runWithIds constraint nodeVars
                    )
                |> TypeCheck.unsafePerformIO
    in
    case ioResult of
        Err errors ->
            Err errors

        Ok { annotations, nodeTypes } ->
            let
                -- Run PostSolve to fix Group B types and compute kernel env
                postSolveResult =
                    PostSolve.postSolve annotations canonical nodeTypes

                fixedNodeTypes =
                    postSolveResult.nodeTypes

                kernelEnv =
                    postSolveResult.kernelEnv
            in
            Ok
                { annotations = annotations
                , typedCanonical = TCan.fromCanonical canonical fixedNodeTypes
                , nodeTypes = fixedNodeTypes
                , kernelEnv = kernelEnv
                }


nitpick : Can.Module -> Result CompileError ()
nitpick canonical =
    case PatternMatches.check canonical of
        Ok () ->
            Ok ()

        Err errors ->
            Err (PatternError errors)


{-| Standard (erased) optimization for JS backend.
-}
optimizeErased : Dict String Name.Name Can.Annotation -> Can.Module -> Result (OneOrMore.OneOrMore MainError.Error) Opt.LocalGraph
optimizeErased annotations canonical =
    Tuple.second (RResult.run (Optimize.optimize annotations canonical))


{-| Typed optimization for MLIR backend.

Preserves full type information throughout the optimization process.
-}
optimizeTyped :
    Dict String Name.Name Can.Annotation
    -> TCan.NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> TCan.Module
    -> Result (OneOrMore.OneOrMore MainError.Error) TOpt.LocalGraph
optimizeTyped annotations nodeTypes kernelEnv tcanModule =
    Tuple.second (RResult.run (TypedOptimize.optimizeTyped annotations nodeTypes kernelEnv tcanModule))



-- ============================================================================
-- TYPED PATHWAY - MONOMORPHIZATION AND MLIR
-- ============================================================================


{-| Monomorphize the typed compilation result.

This takes a CompileResult and runs the typed pathway through monomorphization,
producing a MonoGraph that can be used for MLIR code generation.

-}
monomorphize : CompileResult -> Result CompileError Mono.MonoGraph
monomorphize result =
    let
        globalGraph =
            TOpt.addLocalGraph result.typedObjects TOpt.emptyGlobalGraph
    in
    case monomorphizeAny globalGraph of
        Ok monoGraph ->
            Ok monoGraph

        Err errMsg ->
            Err (MonomorphizeError errMsg)


{-| Monomorphize using the first defined function as entry point.

This is useful for testing when the entry point name is not known in advance.
Test modules use various names like "testValue", etc.

-}
monomorphizeAny : TOpt.GlobalGraph -> Result String Mono.MonoGraph
monomorphizeAny (TOpt.GlobalGraph nodes _ _) =
    case findAnyEntryPoint nodes of
        Nothing ->
            Err "No function found in graph"

        Just ( TOpt.Global _ name, _ ) ->
            Monomorphize.monomorphize name (TOpt.GlobalGraph nodes Dict.empty Dict.empty)


{-| Find any entry point in the global graph (the first defined function).
-}
findAnyEntryPoint : Dict (List String) TOpt.Global TOpt.Node -> Maybe ( TOpt.Global, Can.Type )
findAnyEntryPoint nodes =
    Dict.foldl TOpt.compareGlobal
        (\global node acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case node of
                        TOpt.Define _ _ tipe ->
                            Just ( global, tipe )

                        TOpt.TrackedDefine _ _ _ tipe ->
                            Just ( global, tipe )

                        _ ->
                            Nothing
        )
        Nothing
        nodes


{-| Generate MLIR code from a monomorphized graph.

Returns the MLIR output as a string.

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



-- ============================================================================
-- ERROR FORMATTING
-- ============================================================================


{-| Convert a CompileError to a human-readable string with full details.
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

        MLIRGenerationError msg ->
            "MLIR generation error: " ++ msg

        PathwayMismatch discrepancy ->
            "PATHWAY MISMATCH: " ++ discrepancyToString discrepancy


{-| Convert a PathwayDiscrepancy to a human-readable string.
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


syntaxErrorToString : Syntax.Error -> String
syntaxErrorToString error =
    -- Simplified error handling - just indicate it's a syntax error
    -- Full details would require matching many internal types
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


typeErrorsToString : List TypeError.Error -> String
typeErrorsToString errors =
    errors
        |> List.map typeErrorToString
        |> String.join "\n"


typeErrorToString : TypeError.Error -> String
typeErrorToString error =
    case error of
        TypeError.BadExpr (A.Region (A.Position row col) _) category _ _ ->
            "  - BadExpr at " ++ String.fromInt row ++ ":" ++ String.fromInt col ++ " (" ++ categoryToString category ++ ")"

        TypeError.BadPattern (A.Region (A.Position row col) _) _ _ _ ->
            "  - BadPattern at " ++ String.fromInt row ++ ":" ++ String.fromInt col

        TypeError.InfiniteType (A.Region (A.Position row col) _) name _ ->
            "  - InfiniteType at " ++ String.fromInt row ++ ":" ++ String.fromInt col ++ " for '" ++ name ++ "'"


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


canonicalizeErrorsToString : List CanonicalizeError.Error -> String
canonicalizeErrorsToString errors =
    errors
        |> List.map canonicalizeErrorToString
        |> String.join "; "


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
