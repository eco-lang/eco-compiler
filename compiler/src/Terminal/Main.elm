module Terminal.Main exposing (main)

{-| Command-line interface entry point for the Eco compiler.

This module defines the main entry point for the compiler's command-line interface,
coordinating all available commands (repl, init, make, install, etc.) and providing
a unified interface for users interacting with the compiler through the terminal.


# Program Entry

@docs main

-}

import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)
import Terminal.Bump as Bump
import Terminal.Diff as Diff
import Terminal.Format as Format
import Terminal.Init as Init
import Terminal.Install as Install
import Terminal.Make as Make
import Terminal.Repl as Repl
import Terminal.Terminal as Terminal
import Terminal.Terminal.Chomp as Chomp
import Terminal.Terminal.Helpers as Terminal
import Terminal.Terminal.Internal as Terminal
import Terminal.Test as Test
import Terminal.Uninstall as Uninstall


{-| The main entry point for the Eco compiler CLI application.
-}
main : IO.Program
main =
    IO.run
        (app
            |> Task.andThen (\() -> Exit.exitSuccess)
        )


app : Task Never ()
app =
    Terminal.app intro
        outro
        [ repl
        , init
        , make
        , install
        , uninstall
        , bump
        , diff
        , format
        , test
        ]


intro : D.Doc
intro =
    D.vcat
        [ D.fillSep
            [ D.fromChars "Hi,"
            , D.fromChars "thank"
            , D.fromChars "you"
            , D.fromChars "for"
            , D.fromChars "trying"
            , D.fromChars "out"
            , D.green (D.fromChars "Eco")
            , D.green (D.fromChars (V.toChars V.compiler))
                |> D.a (D.fromChars ".")
            , D.fromChars "I hope you like it!"
            ]
        , D.fromChars ""
        , D.black (D.fromChars "-------------------------------------------------------------------------------")
        , D.black (D.fromChars "I highly recommend working through <https://guide.elm-lang.org> to get started.")
        , D.black (D.fromChars "It teaches many important concepts, including how to use `eco` in the terminal.")
        , D.black (D.fromChars "-------------------------------------------------------------------------------")
        ]


outro : D.Doc
outro =
    D.fillSep <|
        (List.map D.fromChars <|
            String.words <|
                "Be sure to ask on the Elm slack if you run into trouble! Folks are friendly and happy to help out. They hang out there because it is fun, so be kind to get the best results!"
        )



-- ====== INIT ======


init : Terminal.Command
init =
    let
        summary : String
        summary =
            "Start an Elm project. It creates a starter elm.json file and provides a link explaining what to do from there."

        details : String
        details =
            "The `init` command helps start Elm projects:"

        example : D.Doc
        example =
            reflow
                "It will ask permission to create an elm.json file, the one thing common to all Elm projects. It also provides a link explaining what to do from there."

        initFlags : Terminal.Flags
        initFlags =
            Terminal.flags
                |> Terminal.more (Terminal.onOff "package" "Creates a starter elm.json file for a package project.")
                |> Terminal.more (Terminal.onOff "yes" "Reply 'yes' to all automated prompts.")
    in
    Terminal.Command
        { name = "init"
        , summary = Terminal.Common summary
        , details = details
        , example = example
        , args = Terminal.noArgs
        , flags = initFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompExactly (Chomp.pure ())
                    ]
                    (Chomp.pure Init.Flags
                        |> Chomp.apply (Chomp.chompOnOffFlag "package")
                        |> Chomp.apply (Chomp.chompOnOffFlag "yes")
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags initFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Init.run args flags)
        }



-- ====== REPL ======


repl : Terminal.Command
repl =
    let
        summary : String
        summary =
            "Open up an interactive programming session. Type in Elm expressions like (2 + 2) or (String.length \"test\") and see if they equal four!"

        details : String
        details =
            "The `repl` command opens up an interactive programming session:"

        example : D.Doc
        example =
            reflow
                ("Start working through <https://guide.elm-lang.org> to learn how to use this! "
                    ++ "It has a whole chapter that uses the REPL for everything, so that is probably the quickest way to get started."
                )

        replFlags : Terminal.Flags
        replFlags =
            Terminal.flags
                |> Terminal.more (Terminal.flag "interpreter" interpreter "Path to a alternate JS interpreter, like node or nodejs.")
                |> Terminal.more
                    (Terminal.onOff "no-colors"
                        ("Turn off the colors in the REPL. This can help if you are having trouble reading the values. "
                            ++ "Some terminals use a custom color scheme that diverges significantly from the standard ANSI colors, "
                            ++ "so another path may be to pick a more standard color scheme."
                        )
                    )
    in
    Terminal.Command
        { name = "repl"
        , summary = Terminal.Common summary
        , details = details
        , example = example
        , args = Terminal.noArgs
        , flags = replFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompExactly (Chomp.pure ())
                    ]
                    (Chomp.pure Repl.Flags
                        |> Chomp.apply (Chomp.chompNormalFlag "interpreter" interpreter Just)
                        |> Chomp.apply (Chomp.chompOnOffFlag "no-colors")
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags replFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Repl.run args flags)
        }


interpreter : Terminal.Parser
interpreter =
    Terminal.Parser
        { singular = "interpreter"
        , plural = "interpreters"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "node", "nodejs" ]
        }



-- ====== MAKE ======


make : Terminal.Command
make =
    let
        details : String
        details =
            "The `make` command compiles Elm code into JS or HTML:"

        example : D.Doc
        example =
            stack
                [ reflow "For example:"
                , D.green (D.fromChars "eco make src/Main.elm") |> D.indent 4
                , reflow
                    "This tries to compile an Elm file named src/Main.elm, generating an index.html file if possible."
                ]

        makeFlags : Terminal.Flags
        makeFlags =
            Terminal.flags
                |> Terminal.more
                    (Terminal.onOff "debug"
                        ("Turn on the time-travelling debugger. It allows you to rewind and replay events. "
                            ++ "The events can be imported/exported into a file, which makes for very precise bug reports!"
                        )
                    )
                |> Terminal.more
                    (Terminal.onOff "optimize"
                        ("Turn on optimizations to make code smaller and faster. For example, the compiler renames "
                            ++ "record fields to be as short as possible and unboxes values to reduce allocation."
                        )
                    )
                |> Terminal.more (Terminal.onOff "sourcemaps" "Add source maps to resulting JavaScript code.")
                |> Terminal.more
                    (Terminal.flag "output"
                        Make.output
                        ("Specify the name of the resulting JS file. For example --output=assets/eco.js "
                            ++ "to generate the JS at assets/eco.js or --output=/dev/null to generate no output at all!"
                        )
                    )
                |> Terminal.more
                    (Terminal.flag "report"
                        Make.reportType
                        ("You can say --report=json to get error messages as JSON. "
                            ++ "This is only really useful if you are an editor plugin. Humans should avoid it!"
                        )
                    )
                |> Terminal.more
                    (Terminal.flag "docs"
                        Make.docsFile
                        ("Generate a JSON file of documentation for a package. Eventually it will be possible to preview docs "
                            ++ "with `reactor` because it is quite hard to deal with these JSON files directly."
                        )
                    )
                |> Terminal.more
                    (Terminal.onOff "Xpackage-errors"
                        "Show full compilation errors when a package dependency fails to compile (experimental)."
                    )
                |> Terminal.more
                    (Terminal.flag "builddir"
                        Make.buildDir
                        ("Specify a subdirectory under eco-stuff/1.0.0/ for build artifacts. "
                            ++ "Enables parallel builds with different builddirs to avoid cache conflicts."
                        )
                    )
    in
    Terminal.Command
        { name = "make"
        , summary = Terminal.Uncommon
        , details = details
        , example = example
        , args = Terminal.zeroOrMore Terminal.elmFile
        , flags = makeFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompMultiple (Chomp.pure identity) Terminal.elmFile Terminal.parseElmFile
                    ]
                    (Chomp.pure (\debug_ optimize_ withSourceMaps_ output_ report_ docs_ showPackageErrors_ buildDir_ -> Make.Flags { debug = debug_, optimize = optimize_, withSourceMaps = withSourceMaps_, output = output_, report = report_, docs = docs_, showPackageErrors = showPackageErrors_, buildDir = buildDir_ })
                        |> Chomp.apply (Chomp.chompOnOffFlag "debug")
                        |> Chomp.apply (Chomp.chompOnOffFlag "optimize")
                        |> Chomp.apply (Chomp.chompOnOffFlag "sourcemaps")
                        |> Chomp.apply (Chomp.chompNormalFlag "output" Make.output Make.parseOutput)
                        |> Chomp.apply (Chomp.chompNormalFlag "report" Make.reportType Make.parseReportType)
                        |> Chomp.apply (Chomp.chompNormalFlag "docs" Make.docsFile Make.parseDocsFile)
                        |> Chomp.apply (Chomp.chompOnOffFlag "Xpackage-errors")
                        |> Chomp.apply (Chomp.chompNormalFlag "builddir" Make.buildDir Make.parseBuildDir)
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags makeFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Make.run args flags)
        }



-- ====== INSTALL ======


install : Terminal.Command
install =
    let
        details : String
        details =
            "The `install` command fetches packages from <https://package.elm-lang.org> for use in your project:"

        example : D.Doc
        example =
            stack
                [ reflow
                    "For example, if you want to get packages for HTTP and JSON, you would say:"
                , [ D.fromChars "eco install elm/http"
                  , D.fromChars "eco install elm/json"
                  ]
                    |> D.vcat
                    |> D.green
                    |> D.indent 4
                , reflow
                    "Notice that you must say the AUTHOR name and PROJECT name! After running those commands, you could say `import Http` or `import Json.Decode` in your code."
                , reflow
                    "What if two projects use different versions of the same package? No problem! Each project is independent, so there cannot be conflicts like that!"
                ]

        installArgs : Terminal.Args
        installArgs =
            Terminal.oneOf
                [ Terminal.require0
                , Terminal.require1 Terminal.package
                ]

        installFlags : Terminal.Flags
        installFlags =
            Terminal.flags
                |> Terminal.more (Terminal.onOff "test" "Install as a test-dependency.")
                |> Terminal.more (Terminal.onOff "yes" "Reply 'yes' to all automated prompts.")
    in
    Terminal.Command
        { name = "install"
        , summary = Terminal.Uncommon
        , details = details
        , example = example
        , args = installArgs
        , flags = installFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompExactly (Chomp.pure Install.NoArgs)
                    , Chomp.chompExactly
                        (Chomp.pure Install.Install
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.package Terminal.parsePackage
                                        |> Chomp.map (\arg -> func arg)
                                )
                        )
                    ]
                    (Chomp.pure Install.Flags
                        |> Chomp.apply (Chomp.chompOnOffFlag "test")
                        |> Chomp.apply (Chomp.chompOnOffFlag "yes")
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags installFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Install.run args flags)
        }



-- ====== UNINSTALL ======


uninstall : Terminal.Command
uninstall =
    let
        details : String
        details =
            "The `uninstall` command removes packages your project:"

        example : D.Doc
        example =
            stack
                [ reflow
                    "For example, if you want to remove the HTTP and JSON packages, you would say:"
                , [ D.fromChars "eco uninstall elm/http"
                  , D.fromChars "eco uninstall elm/json"
                  ]
                    |> D.vcat
                    |> D.green
                    |> D.indent 4
                ]

        uninstallArgs : Terminal.Args
        uninstallArgs =
            Terminal.oneOf
                [ Terminal.require0
                , Terminal.require1 Terminal.package
                ]

        uninstallFlags : Terminal.Flags
        uninstallFlags =
            Terminal.flags
                |> Terminal.more (Terminal.onOff "yes" "Reply 'yes' to all automated prompts.")
    in
    Terminal.Command
        { name = "uninstall"
        , summary = Terminal.Uncommon
        , details = details
        , example = example
        , args = uninstallArgs
        , flags = uninstallFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompExactly (Chomp.pure Uninstall.NoArgs)
                    , Chomp.chompExactly
                        (Chomp.pure Uninstall.Uninstall
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.package Terminal.parsePackage
                                        |> Chomp.map (\arg -> func arg)
                                )
                        )
                    ]
                    (Chomp.pure Uninstall.Flags
                        |> Chomp.apply (Chomp.chompOnOffFlag "yes")
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags uninstallFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Uninstall.run args flags)
        }





-- ====== BUMP ======


bump : Terminal.Command
bump =
    let
        details : String
        details =
            "The `bump` command figures out the next version number based on API changes:"

        example : D.Doc
        example =
            reflow <|
                "Say you just published version 1.0.0, but then decided to remove a function. "
                    ++ "I will compare the published API to what you have locally, figure out that it is a MAJOR change, "
                    ++ "and bump your version number to 2.0.0. I do this with all packages, "
                    ++ "so there cannot be MAJOR changes hiding in PATCH releases in Elm!"
    in
    Terminal.Command
        { name = "bump"
        , summary = Terminal.Uncommon
        , details = details
        , example = example
        , args = Terminal.noArgs
        , flags = Terminal.noFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompExactly (Chomp.pure ())
                    ]
                    (Chomp.pure ()
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags Terminal.noFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Bump.run args flags)
        }



-- ====== DIFF ======


diff : Terminal.Command
diff =
    let
        details : String
        details =
            "The `diff` command detects API changes:"

        example : D.Doc
        example =
            stack
                [ reflow
                    "For example, to see what changed in the HTML package between versions 1.0.0 and 2.0.0, you can say:"
                , D.fromChars "elm diff elm/html 1.0.0 2.0.0" |> D.green |> D.indent 4
                , reflow
                    "Sometimes a MAJOR change is not actually very big, so this can help you plan your upgrade timelines."
                ]

        diffArgs : Terminal.Args
        diffArgs =
            Terminal.oneOf
                [ Terminal.require0
                , Terminal.require1 Terminal.version
                , Terminal.require2 Terminal.version Terminal.version
                , Terminal.require3 Terminal.package Terminal.version Terminal.version
                ]
    in
    Terminal.Command
        { name = "diff"
        , summary = Terminal.Uncommon
        , details = details
        , example = example
        , args = diffArgs
        , flags = Terminal.noFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompExactly (Chomp.pure Diff.CodeVsLatest)
                    , Chomp.chompExactly
                        (Chomp.pure Diff.CodeVsExactly
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.version Terminal.parseVersion
                                        |> Chomp.map (\arg -> func arg)
                                )
                        )
                    , Chomp.chompExactly
                        (Chomp.pure Diff.LocalInquiry
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.version Terminal.parseVersion
                                        |> Chomp.map (\arg -> func arg)
                                )
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.version Terminal.parseVersion
                                        |> Chomp.map (\arg -> func arg)
                                )
                        )
                    , Chomp.chompExactly
                        (Chomp.pure Diff.GlobalInquiry
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.package Terminal.parsePackage
                                        |> Chomp.map (\arg -> func arg)
                                )
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.version Terminal.parseVersion
                                        |> Chomp.map (\arg -> func arg)
                                )
                            |> Chomp.andThen
                                (\func ->
                                    Chomp.chompArg (List.length chunks) Terminal.version Terminal.parseVersion
                                        |> Chomp.map (\arg -> func arg)
                                )
                        )
                    ]
                    (Chomp.pure ()
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags Terminal.noFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Diff.run args flags)
        }



-- ====== FORMAT ======


format : Terminal.Command
format =
    let
        details : String
        details =
            "The `format` command formats Elm code in place."

        example : D.Doc
        example =
            stack
                [ reflow "For example:"
                , D.green (D.fromChars "eco format src/Main.elm") |> D.indent 4
                , reflow "This tries to format an Elm file named src/Main.elm, formatting it in place."
                ]

        formatArgs : Terminal.Args
        formatArgs =
            Terminal.zeroOrMore Terminal.filePath

        formatFlags : Terminal.Flags
        formatFlags =
            Terminal.flags
                |> Terminal.more (Terminal.flag "output" output "Write output to FILE instead of overwriting the given source file.")
                |> Terminal.more (Terminal.onOff "yes" "Reply 'yes' to all automated prompts.")
                |> Terminal.more (Terminal.onOff "validate" "Check if files are formatted without changing them.")
                |> Terminal.more (Terminal.onOff "stdin" "Read from stdin, output to stdout.")
    in
    Terminal.Command
        { name = "format"
        , summary = Terminal.Uncommon
        , details = details
        , example = example
        , args = formatArgs
        , flags = formatFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompMultiple (Chomp.pure identity) Terminal.filePath Terminal.parseFilePath
                    ]
                    (Chomp.pure Format.makeFlags
                        |> Chomp.apply (Chomp.chompNormalFlag "output" output Just)
                        |> Chomp.apply (Chomp.chompOnOffFlag "yes")
                        |> Chomp.apply (Chomp.chompOnOffFlag "validate")
                        |> Chomp.apply (Chomp.chompOnOffFlag "stdin")
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags formatFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Format.run args flags)
        }


output : Terminal.Parser
output =
    Terminal.Parser
        { singular = "output"
        , plural = "outputs"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed []
        }



-- ====== TEST ======


test : Terminal.Command
test =
    let
        details : String
        details =
            "The `test` command runs tests."

        example : D.Doc
        example =
            stack
                [ reflow "For example:"
                , D.green (D.fromChars "eco test") |> D.indent 4
                , reflow "Run tests in the tests/ folder."
                , D.green (D.fromChars "eco test src/Main.elm") |> D.indent 4
                , reflow "Run tests in files matching the glob."
                ]

        testArgs : Terminal.Args
        testArgs =
            Terminal.zeroOrMore Terminal.filePath

        testFlags : Terminal.Flags
        testFlags =
            Terminal.flags
                |> Terminal.more (Terminal.flag "fuzz" int "Run with a specific fuzzer seed (default: random)")
                |> Terminal.more (Terminal.flag "seed" int "Define how many times each fuzz-test should run (default: 100)")
                |> Terminal.more (Terminal.flag "report" Test.format "Specify which format to use for reporting test results (choices: \"json\", \"junit\", \"console\", default: \"console\")")
    in
    Terminal.Command
        { name = "test"
        , summary = Terminal.Uncommon
        , details = details
        , example = example
        , args = testArgs
        , flags = testFlags
        , run =
            \chunks ->
                Chomp.chomp Nothing
                    chunks
                    [ Chomp.chompMultiple (Chomp.pure identity) Terminal.filePath Terminal.parseFilePath
                    ]
                    (Chomp.pure Test.Flags
                        |> Chomp.apply (Chomp.chompNormalFlag "seed" int parseInt)
                        |> Chomp.apply (Chomp.chompNormalFlag "fuzz" int parseInt)
                        |> Chomp.apply (Chomp.chompNormalFlag "report" Test.format Test.parseReport)
                        |> Chomp.andThen
                            (\value ->
                                Chomp.checkForUnknownFlags testFlags
                                    |> Chomp.map (\_ -> value)
                            )
                    )
                    |> Tuple.second
                    |> Result.map (\( args, flags ) -> Test.run args flags)
        }


int : Terminal.Parser
int =
    Terminal.Parser
        { singular = "int"
        , plural = "ints"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed []
        }


parseInt : String -> Maybe Int
parseInt =
    String.toInt



-- ====== HELPERS ======


stack : List D.Doc -> D.Doc
stack docs =
    List.intersperse (D.fromChars "") docs |> D.vcat


reflow : String -> D.Doc
reflow string =
    String.words string |> List.map D.fromChars |> D.fillSep
