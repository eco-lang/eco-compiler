module Compiler.Reporting.Warning exposing
    ( Warning(..), Context(..)
    , toReport
    )

{-| Compiler warnings for code quality issues.

This module defines warnings that the compiler can emit for code that is
syntactically correct but potentially problematic. Unlike errors, warnings
do not prevent compilation but help developers write cleaner, more
maintainable code.


# Types

@docs Warning, Context


# Reporting

@docs toReport

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Render.Type as RT
import Compiler.Reporting.Render.Type.Localizer as L
import Compiler.Reporting.Report as Report exposing (Report)



-- ALL POSSIBLE WARNINGS


{-| Represents a compiler warning that indicates potentially problematic code.

Warnings are issued for code quality issues such as unused imports, unused
variables, or missing type annotations. Unlike errors, warnings do not prevent
compilation.
-}
type Warning
    = UnusedImport A.Region Name
    | UnusedVariable A.Region Context Name
    | MissingTypeAnnotation A.Region Name Can.Type


{-| Describes the context where an unused variable was found.

The context affects how the warning message is phrased and what suggestions
are provided to the user.
-}
type Context
    = Def
    | Pattern



-- TO REPORT


{-| Converts a warning into a formatted report for display to the user.

Takes a type localizer for rendering type annotations, the source code for
context snippets, and the warning itself. Returns a formatted report with
appropriate title, region highlighting, and helpful messages.
-}
toReport : L.Localizer -> Code.Source -> Warning -> Report
toReport localizer source warning =
    case warning of
        UnusedImport region moduleName ->
            ( D.reflow ("Nothing from the `" ++ moduleName ++ "` module is used in this file.")
            , D.fromChars "I recommend removing unused imports."
            )
                |> Code.toSnippet source region Nothing
                |> Report.report "unused import" region []

        UnusedVariable region context name ->
            let
                title : String
                title =
                    defOrPat context "unused definition" "unused variable"
            in
            ( D.reflow ("You are not using `" ++ name ++ "` anywhere.")
            , D.stack
                [ D.reflow <|
                    "Is there a typo? Maybe you intended to use `"
                        ++ name
                        ++ "` somewhere but typed another name instead?"
                , D.reflow <|
                    defOrPat context
                        "If you are sure there is no typo, remove the definition. This way future readers will not have to wonder why it is there!"
                        ("If you are sure there is no typo, replace `"
                            ++ name
                            ++ "` with _ so future readers will not have to wonder why it is there!"
                        )
                ]
            )
                |> Code.toSnippet source region Nothing
                |> Report.report title region []

        MissingTypeAnnotation region name inferredType ->
            ( D.reflow <|
                case Type.deepDealias inferredType of
                    Can.TLambda _ _ ->
                        "The `" ++ name ++ "` function has no type annotation."

                    _ ->
                        "The `" ++ name ++ "` definition has no type annotation."
            , D.stack
                [ D.fromChars "I inferred the type annotation myself though! You can copy it into your code:"
                , D.sep
                    [ D.fromName name |> D.a (D.fromChars " :")
                    , RT.canToDoc localizer RT.None inferredType
                    ]
                    |> D.hang 4
                    |> D.green
                ]
            )
                |> Code.toSnippet source region Nothing
                |> Report.report "missing type annotation" region []


defOrPat : Context -> a -> a -> a
defOrPat context def pat =
    case context of
        Def ->
            def

        Pattern ->
            pat
