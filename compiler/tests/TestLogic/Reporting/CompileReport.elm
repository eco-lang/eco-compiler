module TestLogic.Reporting.CompileReport exposing (expectReportContains, reportOf)

{-| Compiles the text of one application module through the compiler's own
phases and returns the error report a user would see, so that a test can check
what the compiler tells the user about a real erroneous program.

The text goes through `Compiler.Parse.Module.fromByteString`. The stand-in
interfaces lack some default imports (such as `Debug` and `Platform`), so the
parsed module's imports are replaced by those of
`Compiler.AST.SourceBuilder.makeModule`, as the local-optimization tests do;
the program may therefore use only `Basics`-level names and must not import
anything. The module then goes through the two
front-end phases of `Compiler.Compile.compile`, repeated here because
`Compiler.Compile` exposes them only inside a `Task`: canonicalization (as
package `eco/example`, against the stand-in interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`), giving `BadNames`, and the type
checker of the erased path, giving `BadTypes` with the module's localizer. The
first phase that fails gives the
`Compiler.Reporting.Error.Error`, whose reports are laid out as the terminal
shows them, by `Compiler.Reporting.Error.toDoc` for a module at
`/project/src/Main.elm` and the root `/project`, and rendered without colour by
`Compiler.Reporting.Doc.toString`.

A module that compiles gives the text `"no error"`.

-}

import Builder.File as File
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (makeModule, unitExpr)
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Parse.Module as M
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error as Error
import Compiler.Reporting.Render.Type.Localizer as Localizer
import Compiler.Reporting.Result as ReportingResult
import Compiler.Type.Constrain.Erased.Module as TypeErased
import Compiler.Type.Solve as Type
import Expect
import System.TypeCheck.IO as TypeCheck
import Time


{-| Returns the rendered reports for `source`, or `"no error"`.
-}
reportOf : String -> String
reportOf source =
    let
        result : Result Error.Error ()
        result =
            M.fromByteString M.Application source
                |> Result.mapError Error.BadSyntax
                |> Result.map withTestImports
                |> Result.andThen
                    (\modul ->
                        case Tuple.second (ReportingResult.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces modul)) of
                            Err errors ->
                                Err (Error.BadNames errors)

                            Ok canonical ->
                                case TypeErased.constrain canonical |> TypeCheck.andThen Type.run |> TypeCheck.unsafePerformIO of
                                    Ok _ ->
                                        Ok ()

                                    Err errors ->
                                        Err (Error.BadTypes (Localizer.fromModule modul) errors)
                    )
    in
    case result of
        Ok () ->
            "no error"

        Err err ->
            Error.toDoc "/project"
                { name = "Main"
                , absolutePath = "/project/src/Main.elm"
                , modificationTime = File.Time (Time.millisToPosix 0)
                , source = source
                , error = err
                }
                []
                |> D.toString


{-| Replaces the imports of `modul` by those of a `SourceBuilder` module, which
the stand-in interfaces can resolve.
-}
withTestImports : Src.Module -> Src.Module
withTestImports (Src.Module m) =
    let
        (Src.Module template) =
            makeModule "unused" unitExpr
    in
    Src.Module { m | imports = template.imports }


{-| Passes when the report for `source` contains `expected`; on failure shows
the whole report.
-}
expectReportContains : String -> String -> Expect.Expectation
expectReportContains expected source =
    let
        report : String
        report =
            reportOf source
    in
    if String.contains expected report then
        Expect.pass

    else
        Expect.fail ("Expected the report to contain:\n" ++ expected ++ "\n\nbut the report is:\n" ++ report)
