module Compiler.Compile exposing
    ( Artifacts(..)
    , TypedArtifacts(..)
    , TypedArtifactsData
    , compile
    , compileTyped
    )

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Nitpick.PatternMatches as PatternMatches
import Compiler.Optimize.Module as Optimize
import Compiler.Optimize.TypedModule as TypedOptimize
import Compiler.Reporting.Error as E
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Compiler.Reporting.Result as ReportingResult
import Compiler.Type.Constrain.Module as Type
import Compiler.Type.Solve as Type
import Data.Map exposing (Dict)
import System.TypeCheck.IO as TypeCheck
import Task exposing (Task)



-- COMPILE


type Artifacts
    = Artifacts Can.Module (Dict String Name Can.Annotation) Opt.LocalGraph


{-| Artifacts that include typed optimization output for MLIR backend.
-}
type alias TypedArtifactsData =
    { canonical : Can.Module
    , annotations : Dict String Name Can.Annotation
    , objects : Opt.LocalGraph
    , typedObjects : TOpt.LocalGraph
    }


type TypedArtifacts
    = TypedArtifacts TypedArtifactsData


compile : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error Artifacts)
compile pkg ifaces modul =
    Task.succeed
        (canonicalize pkg ifaces modul
            |> (\canonicalResult ->
                    case canonicalResult of
                        Ok canonical ->
                            Result.map2 (\annotations () -> annotations)
                                (typeCheck modul canonical)
                                (nitpick canonical)
                                |> Result.andThen
                                    (\annotations ->
                                        optimize modul annotations canonical
                                            |> Result.map (\objects -> Artifacts canonical annotations objects)
                                    )

                        Err err ->
                            Err err
               )
        )


{-| Compile with typed optimization for MLIR backend.
Produces both Opt.LocalGraph and TOpt.LocalGraph.
-}
compileTyped : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Task Never (Result E.Error TypedArtifacts)
compileTyped pkg ifaces modul =
    Task.succeed
        (canonicalize pkg ifaces modul
            |> (\canonicalResult ->
                    case canonicalResult of
                        Ok canonical ->
                            Result.map2 (\annotations () -> annotations)
                                (typeCheck modul canonical)
                                (nitpick canonical)
                                |> Result.andThen
                                    (\annotations ->
                                        optimize modul annotations canonical
                                            |> Result.andThen
                                                (\objects ->
                                                    typedOptimize modul annotations canonical
                                                        |> Result.map (\typedObjects -> TypedArtifacts { canonical = canonical, annotations = annotations, objects = objects, typedObjects = typedObjects })
                                                )
                                    )

                        Err err ->
                            Err err
               )
        )



-- PHASES


canonicalize : Pkg.Name -> Dict String ModuleName.Raw I.Interface -> Src.Module -> Result E.Error Can.Module
canonicalize pkg ifaces modul =
    case Tuple.second (ReportingResult.run (Canonicalize.canonicalize pkg ifaces modul)) of
        Ok canonical ->
            Ok canonical

        Err errors ->
            Err (E.BadNames errors)


typeCheck : Src.Module -> Can.Module -> Result E.Error (Dict String Name Can.Annotation)
typeCheck modul canonical =
    case TypeCheck.unsafePerformIO (TypeCheck.andThen Type.run (Type.constrain canonical)) of
        Ok annotations ->
            Ok annotations

        Err errors ->
            Err (E.BadTypes (Localizer.fromModule modul) errors)


nitpick : Can.Module -> Result E.Error ()
nitpick canonical =
    case PatternMatches.check canonical of
        Ok () ->
            Ok ()

        Err errors ->
            Err (E.BadPatterns errors)


optimize : Src.Module -> Dict String Name.Name Can.Annotation -> Can.Module -> Result E.Error Opt.LocalGraph
optimize modul annotations canonical =
    case Tuple.second (ReportingResult.run (Optimize.optimize annotations canonical)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)


{-| Run typed optimization to produce TOpt.LocalGraph with full type information.
-}
typedOptimize : Src.Module -> Dict String Name.Name Can.Annotation -> Can.Module -> Result E.Error TOpt.LocalGraph
typedOptimize modul annotations canonical =
    case Tuple.second (ReportingResult.run (TypedOptimize.optimize annotations canonical)) of
        Ok localGraph ->
            Ok localGraph

        Err errors ->
            Err (E.BadMains (Localizer.fromModule modul) errors)
