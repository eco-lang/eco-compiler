module Terminal.Test exposing
    ( Flags(..)
    , Report(..)
    , format
    , parseReport
    , run
    )

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Deps.Registry as Registry
import Builder.Deps.Solver as Solver
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.Generate as Generate
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Constraint as C
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Parse.Module as Parse
import Compiler.Parse.SyntaxVersion as SV
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Json.Encode as Encode
import Maybe.Extra as Maybe
import Regex exposing (Regex)
import System.Exit as Exit
import System.IO as IO
import System.Process as Process
import Task exposing (Task)
import Terminal.Terminal.Internal exposing (Parser(..))
import Utils.Crash exposing (crash)
import Utils.Main as Utils exposing (FilePath)
import Utils.Task.Extra as Task



-- RUN


type Flags
    = Flags (Maybe Int) (Maybe Int) (Maybe Report)


run : List String -> Flags -> Task Never ()
run paths flags =
    Stuff.findRoot
        |> Task.andThen (runWithRoot paths flags)


runWithRoot : List String -> Flags -> Maybe String -> Task Never ()
runWithRoot paths flags maybeRoot =
    Reporting.attemptWithStyle style Exit.testToReport <|
        case maybeRoot of
            Just root ->
                runHelp root paths flags

            Nothing ->
                Task.succeed (Err Exit.TestNoOutline)


runHelp : String -> List String -> Flags -> Task Never (Result Exit.Test ())
runHelp root testFileGlobs flags =
    (initTestDir root
        |> Task.andThen (setupTestEnvironment root)
        |> Task.andThen (\_ -> runTestsPhase root testFileGlobs flags)
        |> Task.map (\_ -> ())
    )
        |> Task.run
        |> Stuff.withRootLock root


{-| Initialize test directory and get node dirname
-}
initTestDir : FilePath -> Task Exit.Test FilePath
initTestDir root =
    Utils.dirCreateDirectoryIfMissing True (Stuff.testDir root)
        |> Task.andThen (\_ -> Utils.nodeGetDirname)
        |> Task.io


{-| Context for setting up test environment
-}
type alias TestSetupContext =
    { nodeDirname : FilePath
    , baseOutline : Outline.Outline
    , testsDirExists : Bool
    , env : Solver.Env
    }


{-| Set up the test environment by reading outline and initializing solver
-}
setupTestEnvironment : FilePath -> FilePath -> Task Exit.Test ()
setupTestEnvironment root nodeDirname =
    Task.eio Exit.TestBadOutline (Outline.read root)
        |> Task.andThen (checkTestsDirAndInitEnv nodeDirname)
        |> Task.andThen (processOutlineAndApplyChanges root)


checkTestsDirAndInitEnv : FilePath -> Outline.Outline -> Task Exit.Test TestSetupContext
checkTestsDirAndInitEnv nodeDirname baseOutline =
    Task.io (Utils.dirDoesDirectoryExist "tests")
        |> Task.andThen (initEnvWithContext nodeDirname baseOutline)


initEnvWithContext : FilePath -> Outline.Outline -> Bool -> Task Exit.Test TestSetupContext
initEnvWithContext nodeDirname baseOutline testsDirExists =
    Task.eio Exit.TestBadRegistry Solver.initEnv
        |> Task.map
            (\env ->
                { nodeDirname = nodeDirname
                , baseOutline = baseOutline
                , testsDirExists = testsDirExists
                , env = env
                }
            )


processOutlineAndApplyChanges : FilePath -> TestSetupContext -> Task Exit.Test ()
processOutlineAndApplyChanges root { nodeDirname, baseOutline, testsDirExists, env } =
    let
        newSrcDirs : NE.Nonempty Outline.SrcDir -> NE.Nonempty Outline.SrcDir
        newSrcDirs srcDirs =
            srcDirs
                |> addOptionalTests testsDirExists
                |> NE.map makeRelativePathsPortable
                |> NE.cons (Outline.AbsoluteSrcDir (Utils.fpCombine nodeDirname "../libraries/test/src"))
                |> NE.cons (Outline.RelativeSrcDir "src")
    in
    buildTestOutline env newSrcDirs baseOutline
        |> Task.andThen (attemptChanges root env)


addOptionalTests : Bool -> NE.Nonempty Outline.SrcDir -> NE.Nonempty Outline.SrcDir
addOptionalTests testsDirExists =
    if testsDirExists then
        NE.cons (Outline.RelativeSrcDir "tests")

    else
        identity


makeRelativePathsPortable : Outline.SrcDir -> Outline.SrcDir
makeRelativePathsPortable srcDir =
    case srcDir of
        Outline.AbsoluteSrcDir _ ->
            srcDir

        Outline.RelativeSrcDir path ->
            Outline.RelativeSrcDir ("../../../" ++ path)


buildTestOutline : Solver.Env -> (NE.Nonempty Outline.SrcDir -> NE.Nonempty Outline.SrcDir) -> Outline.Outline -> Task Exit.Test Outline.AppOutline
buildTestOutline env newSrcDirs baseOutline =
    case baseOutline of
        Outline.App (Outline.AppOutline appData) ->
            Outline.AppOutline
                { elm = appData.elm
                , srcDirs = newSrcDirs appData.srcDirs
                , depsDirect = Dict.union appData.depsDirect appData.testDirect
                , depsIndirect = Dict.union appData.depsIndirect appData.testIndirect
                , testDirect = Dict.empty
                , testIndirect = Dict.empty
                }
                |> addRequiredTestPackages env

        Outline.Pkg (Outline.PkgOutline pkgData) ->
            Outline.AppOutline
                { elm = V.elmCompiler
                , srcDirs = newSrcDirs (NE.singleton (Outline.RelativeSrcDir "src"))
                , depsDirect = Dict.empty
                , depsIndirect = Dict.empty
                , testDirect = Dict.empty
                , testIndirect = Dict.empty
                }
                |> makePkgPlan env (Dict.union pkgData.deps pkgData.testDeps)
                |> Task.andThen (addRequiredTestPackages env)


addRequiredTestPackages : Solver.Env -> Outline.AppOutline -> Task Exit.Test Outline.AppOutline
addRequiredTestPackages env outline =
    -- TODO changes should only be done to the `tests/elm.json`
    -- in case the top level `elm.json` had changes! This will improve performance!
    makeAppPlan env Pkg.core outline
        |> Task.andThen (makeAppPlan env Pkg.json)
        |> Task.andThen (makeAppPlan env Pkg.time)
        |> Task.andThen (makeAppPlan env Pkg.random)


{-| Run the test execution phase
-}
runTestsPhase : FilePath -> List String -> Flags -> Task Exit.Test ()
runTestsPhase root testFileGlobs flags =
    let
        paths : List String
        paths =
            case testFileGlobs of
                [] ->
                    [ root ++ "/tests" ]

                _ ->
                    testFileGlobs
    in
    resolveElmFiles paths
        |> Task.andThen (extractTestModules paths)
        |> Task.map (List.filterMap identity)
        |> Task.andThen (generateAndRunTests root testFileGlobs flags)
        |> Task.io


extractTestModules : List String -> Result (List Error) (List FilePath) -> Task Never (List (Maybe ( FilePath, ( String, List String ) )))
extractTestModules paths resolvedInputFiles =
    case resolvedInputFiles of
        Ok inputFiles ->
            Utils.listTraverse (extractTestModuleIfMatches paths) inputFiles

        Err _ ->
            Task.succeed []


extractTestModuleIfMatches : List String -> FilePath -> Task Never (Maybe ( FilePath, ( String, List String ) ))
extractTestModuleIfMatches paths inputFile =
    case List.filter (\path -> String.startsWith path inputFile) paths of
        _ :: [] ->
            extractExposedPossiblyTests inputFile
                |> Task.map (Maybe.map (Tuple.pair inputFile))

        _ ->
            Task.succeed Nothing


generateAndRunTests : FilePath -> List String -> Flags -> List ( FilePath, ( String, List String ) ) -> Task Never ()
generateAndRunTests root testFileGlobs flags exposedList =
    Utils.dirCreateDirectoryIfMissing True (Stuff.testDir root ++ "/src/Test/Generated")
        |> Task.andThen (\_ -> generateTestMain root testFileGlobs flags exposedList)
        |> Task.andThen (writeTestMainFile root)
        |> Task.andThen (\_ -> compileTests root)
        |> Task.andThen executeTests
        |> Task.map (\_ -> ())


generateTestMain : FilePath -> List String -> Flags -> List ( FilePath, ( String, List String ) ) -> Task Never String
generateTestMain root testFileGlobs flags exposedList =
    let
        testModules : List { moduleName : String, possiblyTests : List String }
        testModules =
            List.map
                (\( _, ( moduleName, possiblyTests ) ) ->
                    { moduleName = moduleName
                    , possiblyTests = possiblyTests
                    }
                )
                exposedList
    in
    testGeneratedMain testModules testFileGlobs (List.map Tuple.first exposedList) flags


writeTestMainFile : FilePath -> String -> Task Never ()
writeTestMainFile root mainContent =
    IO.writeString (Stuff.testDir root ++ "/src/Test/Generated/Main.elm") mainContent


compileTests : FilePath -> Task Never String
compileTests root =
    Reporting.terminal
        |> Task.andThen (compileTestsWithStyle root)


compileTestsWithStyle : FilePath -> Reporting.Style -> Task Never String
compileTestsWithStyle root terminalStyle =
    Reporting.attemptWithStyle terminalStyle Exit.testToReport <|
        Utils.dirWithCurrentDirectory (Stuff.testDir root)
            (runMake (Stuff.testDir root) "src/Test/Generated/Main.elm")


executeTests : String -> Task Never Exit.ExitCode
executeTests content =
    IO.hPutStrLn IO.stdout "Starting tests"
        |> Task.andThen (\_ -> getInterpreter)
        |> Task.andThen (runInterpreterWithContent content)


runInterpreterWithContent : String -> FilePath -> Task Never Exit.ExitCode
runInterpreterWithContent content interpreter =
    let
        finalContent : String
        finalContent =
            before
                ++ "\nvar Elm = (function(module) {\n"
                ++ addKernelTestChecking content
                ++ "\nreturn this.Elm;\n})({});\n"
                ++ after
    in
    interpret interpreter finalContent


interpret : FilePath -> String -> Task Never Exit.ExitCode
interpret interpreter javascript =
    let
        createProcess : { cmdspec : Process.CmdSpec, std_out : Process.StdStream, std_err : Process.StdStream, std_in : Process.StdStream }
        createProcess =
            Process.proc interpreter []
                |> (\cp -> { cp | std_in = Process.CreatePipe })
    in
    Process.withCreateProcess createProcess <|
        \stdinHandle _ _ handle ->
            case stdinHandle of
                Just stdin ->
                    writeAndWaitForProcess stdin handle javascript

                Nothing ->
                    crash "not implemented"


writeAndWaitForProcess : IO.Handle -> Process.ProcessHandle -> String -> Task Never Exit.ExitCode
writeAndWaitForProcess stdin handle javascript =
    Utils.builderHPutBuilder stdin javascript
        |> Task.andThen (\_ -> IO.hClose stdin)
        |> Task.andThen (\_ -> Process.waitForProcess handle)


testVariantDefinition : Regex
testVariantDefinition =
    Maybe.withDefault Regex.never <|
        Regex.fromStringWith { caseInsensitive = False, multiline = True }
            ("^var\\s+\\$elm_explorations\\$test\\$Test\\$Internal\\$"
                ++ "(?:ElmTestVariant__\\w+|UnitTest|FuzzTest|Labeled|Skipped|Only|Batch)"
                ++ "\\s*=\\s*(?:\\w+\\(\\s*)?function\\s*\\([\\w, ]*\\)\\s*\\{\\s*return *\\{"
            )


checkDefinition : Regex
checkDefinition =
    Maybe.withDefault Regex.never <|
        Regex.fromStringWith { caseInsensitive = False, multiline = True }
            "^(var\\s+\\$author\\$project\\$Test\\$Runner\\$Node\\$check)\\s*=\\s*\\$author\\$project\\$Test\\$Runner\\$Node\\$checkHelperReplaceMe___;?$"


addKernelTestChecking : String -> String
addKernelTestChecking content =
    "var __elmTestSymbol = Symbol(\"elmTestSymbol\");\n"
        ++ (content
                |> Regex.replace testVariantDefinition (\{ match } -> match ++ "__elmTestSymbol: __elmTestSymbol, ")
                |> Regex.replaceAtMost 1
                    checkDefinition
                    (\{ submatches } ->
                        case submatches of
                            (Just firstSubmatch) :: _ ->
                                firstSubmatch ++ " = value => value && value.__elmTestSymbol === __elmTestSymbol ? $elm$core$Maybe$Just(value) : $elm$core$Maybe$Nothing;"

                            _ ->
                                crash "addKernelTestChecking: no submatches found"
                    )
           )


before : String
before =
    """// Apply Node polyfills as necessary.
var window = {
  Date: Date,
  addEventListener: function () {},
  removeEventListener: function () {},
};

var location = {
  href: '',
  host: '',
  hostname: '',
  protocol: '',
  origin: '',
  port: '',
  pathname: '',
  search: '',
  hash: '',
  username: '',
  password: '',
};
var document = { body: {}, createTextNode: function () {}, location: location };

if (typeof FileList === 'undefined') {
  FileList = function () {};
}

if (typeof File === 'undefined') {
  File = function () {};
}

if (typeof XMLHttpRequest === 'undefined') {
  XMLHttpRequest = function () {
    return {
      addEventListener: function () {},
      open: function () {},
      send: function () {},
    };
  };

  var oldConsoleWarn = console.warn;
  console.warn = function () {
    if (
      arguments.length === 1 &&
      arguments[0].indexOf('Compiled in DEV mode') === 0
    )
      return;
    return oldConsoleWarn.apply(console, arguments);
  };
}

if (typeof FormData === 'undefined') {
  FormData = function () {
    this._data = [];
  };
  FormData.prototype.append = function () {
    this._data.push(Array.prototype.slice.call(arguments));
  };
}
"""


after : String
after =
    """// Run the Elm app.
var app = Elm.Test.Generated.Main.init({ flags: Date.now() });

var report = 'console';

var nextResultToPrint = null;
var results = new Map();
var failures = 0;
var todos = [];
var testsToRun = -1;
var startingTime = Date.now();

function printResult(result) {
    switch (report) {
        case 'console':
            switch (result.type) {
                case 'begin':
                    console.log(makeWindowsSafe(result.output));
                    break;
                case 'complete':
                    switch (result.status) {
                        case 'pass':
                            // passed tests should be printed only if they contain distributionReport
                            if (result.distributionReport !== undefined) {
                                console.log(makeWindowsSafe(result.distributionReport));
                            }
                            break;
                        case 'todo':
                            // todos will be shown in the SUMMARY only.
                            break;
                        case 'fail':
                            console.log(makeWindowsSafe(result.failure));
                            break;
                        default:
                            throw new Error(`Unexpected result.status: ${result.status}`);
                    }
                    break;
                case 'summary':
                    console.log(makeWindowsSafe(result.summary));
                    break;
                default:
                    throw new Error(`Unexpected result.type: ${result.type}`);
            }
            break;

        case 'json':
            console.log(JSON.stringify(result));
            break;

        case 'junit':
            // JUnit does everything at once in SUMMARY, elsewhere
            break;
    }
}

function flushResults() {
    // Only print any results if we're ready - that is, nextResultToPrint
    // is no longer null. (BEGIN changes it from null to 0.)
    if (nextResultToPrint !== null) {
        var result = results.get(nextResultToPrint);

        while (
            // If there are no more results to print, then we're done.
            nextResultToPrint < testsToRun &&
            // Otherwise, keep going until we have no result available to print.
            typeof result !== 'undefined'
        ) {
            printResult(result);
            nextResultToPrint++;
            result = results.get(nextResultToPrint);
        }
    }
}

function handleResults(response) {
    // TODO print progress bar - e.g. "Running test 5 of 20" on a bar!
    // -- yikes, be careful though...test the scenario where test
    // authors put Debug.log in their tests - does that mess
    // everything up re: the line feed? Seems like it would...
    // ...so maybe a bar is not best. Can we do better? Hm.
    // Maybe the answer is to print the thing, then Immediately
    // backtrack the line feed, so that if someone else does more
    // logging, it will overwrite our status update and that's ok?

    Object.keys(response.results).forEach(function (index) {
        var result = response.results[index];
        results.set(parseInt(index), result);

        switch (report) {
            case 'console':
                switch (result.status) {
                    case 'pass':
                        // It's a PASS; no need to take any action.
                        break;
                    case 'todo':
                        todos.push(result);
                        break;
                    case 'fail':
                        failures++;
                        break;
                    default:
                        throw new Error(`Unexpected result.status: ${result.status}`);
                }
                break;
            case 'junit':
                if (typeof result.failure !== 'undefined') {
                    failures++;
                }
                break;
            case 'json':
                if (result.status === 'fail') {
                    failures++;
                } else if (result.status === 'todo') {
                    todos.push({ labels: result.labels, todo: result.failures[0] });
                }
                break;
        }
    });

    flushResults();
}

function makeWindowsSafe(text) {
    return process.platform === 'win32' ? windowsify(text) : text;
}

// Fix Windows Unicode problems. Credit to https://github.com/sindresorhus/figures for the Windows compat idea!
var windowsSubstitutions = [
    [/[↓✗►]/g, '>'],
    [/╵│╷╹┃╻/g, '|'],
    [/═/g, '='],
    [/▔/g, '-'],
    [/✔/g, '√'],
];

function windowsify(str) {
    return windowsSubstitutions.reduce(function (result /*: string */, sub) {
        return result.replace(sub[0], sub[1]);
    }, str);
}

// Use ports for inter-process communication.
app.ports.elmTestPort__send.subscribe(function (msg) {
    var response = JSON.parse(msg);

    switch (response.type) {
        case 'FINISHED':
            handleResults(response);

            // Print the summmary.
            app.ports.elmTestPort__receive.send(
                {
                    type: 'SUMMARY',
                    duration: Date.now() - startingTime,
                    failures: failures,
                    todos: todos,
                }
            );

            break;
        case 'SUMMARY':
            flushResults();

            if (response.exitCode === 1) {
                // The tests could not even run. At the time of this writing, the
                // only case is “No exposed values of type Test found”. That
                // _could_ have been caught at compile time, but the current
                // architecture needs to actually run the JS to figure out which
                // exposed values are of type Test. That’s why this type of
                // response is handled differently than others.
                console.error(response.message);
            } else {
                printResult(response.message);

                if (report === 'junit') {
                    var xml = response.message;
                    var values = Array.from(results.values());

                    xml.testsuite.testcase = xml.testsuite.testcase.concat(values);

                    // The XmlBuilder by default does not remove characters that are
                    // invalid in XML, like backspaces. However, we can pass it an
                    // `invalidCharReplacement` option to tell it how to handle
                    // those characters, rather than crashing. In an attempt to
                    // retain useful information in the output, we try and output a
                    // hex-encoded unicode codepoint for the invalid character. For
                    // example, the start of a terminal escape (`\u{001B}` in Elm) will be output as a
                    // literal `\u{001B}`.
                    var invalidCharReplacement = function (char) {
                        return (
                            '\\\\u{' +
                            char.codePointAt(0).toString(16).padStart(4, '0') +
                            '}'
                        );
                    };

                    console.log(
                        XmlBuilder.create(xml, {
                            invalidCharReplacement: invalidCharReplacement,
                        }).end()
                    );
                }
            }

            // resolve(response.exitCode);
            break;
        case 'BEGIN':
            testsToRun = response.testCount;

            if (!isMachineReadable(report)) {
                var headline = 'elm-test """ ++ V.toChars V.elmCompiler ++ """';
                var bar = '-'.repeat(headline.length);

                console.log('\\n' + headline + '\\n' + bar + '\\n');
            }

            printResult(response.message);

            // Now we're ready to print results!
            nextResultToPrint = 0;

            flushResults();

            break;
        case 'RESULTS':
            handleResults(response);

            break;
        case 'ERROR':
            throw new Error(response.message);
        default:
            throw new Error(
                'Unrecognized message from worker:' + response.type
            );
    }
});

function isMachineReadable(report) {
  switch (report) {
    case 'json':
    case 'junit':
      return true;
    case 'console':
      return false;
  }
}

app.ports.elmTestPort__receive.send({ type: 'TEST', index: -1 });"""


testGeneratedMain :
    List
        { moduleName : String
        , possiblyTests : List String
        }
    -> List String
    -> List String
    -> Flags
    -> Task Never String
testGeneratedMain testModules testFileGlobs testFilePaths (Flags maybeSeed maybeRuns report) =
    let
        seedIO : Task Never Int
        seedIO =
            case maybeSeed of
                Just seedValue ->
                    Task.succeed seedValue

                Nothing ->
                    Utils.nodeMathRandom
                        |> Task.map (\seedRandom -> floor (seedRandom * 407199254740991) + 1000)

        imports : List String
        imports =
            List.map (\mod -> "import " ++ mod.moduleName) testModules

        possiblyTestsList : List String
        possiblyTestsList =
            List.map makeModuleTuple testModules
    in
    seedIO
        |> Task.map
            (\seedValue ->
                """module Test.Generated.Main exposing (main)

""" ++ String.join "\n" imports ++ """

import Test.Reporter.Reporter exposing (Report(..))
import Console.Text exposing (UseColor(..))
import Test.Runner.Node
import Test

main : Test.Runner.Node.TestProgram
main =
    Test.Runner.Node.run
        { runs = """ ++ String.fromInt (Maybe.withDefault 100 maybeRuns) ++ """
        , report = """ ++ generateElmReportVariant report ++ """
        , seed = """ ++ String.fromInt seedValue ++ """
        , processes = 1
        , globs =
            """ ++ indentAllButFirstLine 12 (List.map (Encode.encode 0 << Encode.string) testFileGlobs) ++ """
        , paths =
            """ ++ indentAllButFirstLine 12 (List.map (Encode.encode 0 << Encode.string) testFilePaths) ++ """
        }
        """ ++ indentAllButFirstLine 8 possiblyTestsList
            )


indentAllButFirstLine : Int -> List String -> String
indentAllButFirstLine indent list =
    case list of
        [] ->
            "[]"

        head :: rest ->
            "[ "
                ++ head
                ++ String.concat (List.map (\entry -> "\n" ++ String.repeat indent " " ++ ", " ++ entry) rest)
                ++ "\n"
                ++ String.repeat indent " "
                ++ "]"


makeModuleTuple : { moduleName : String, possiblyTests : List String } -> String
makeModuleTuple mod =
    let
        list : List String
        list =
            List.map (\test -> "Test.Runner.Node.check " ++ mod.moduleName ++ "." ++ test)
                mod.possiblyTests
    in
    "( \""
        ++ mod.moduleName
        ++ "\"\n"
        ++ String.repeat 10 " "
        ++ ", "
        ++ indentAllButFirstLine 12 list
        ++ "\n"
        ++ String.repeat 10 " "
        ++ ")"


generateElmReportVariant : Maybe Report -> String
generateElmReportVariant maybeReport =
    case maybeReport of
        Just Json ->
            "JsonReport"

        Just JUnit ->
            "JUnitReport"

        _ ->
            "ConsoleReport UseColor"



-- GET INFORMATION


style : Reporting.Style
style =
    Reporting.silent


extractExposedPossiblyTests : String -> Task Never (Maybe ( String, List String ))
extractExposedPossiblyTests path =
    File.readUtf8 path
        |> Task.map (parseExposedValues path)


parseExposedValues : FilePath -> String -> Maybe ( String, List String )
parseExposedValues path bytes =
    case Parse.fromByteString (SV.fileSyntaxVersion path) Parse.Application bytes of
        Ok (Src.Module srcData) ->
            case srcData.name of
                Just (A.At _ name) ->
                    Just ( name, extractExposedNames (A.toValue srcData.exports) )

                Nothing ->
                    Nothing

        _ ->
            Nothing


extractExposedNames : Src.Exposing -> List Name
extractExposedNames exposing_ =
    case exposing_ of
        Src.Open _ _ ->
            []

        Src.Explicit (A.At _ exposedList) ->
            List.filterMap extractLowerName exposedList


extractLowerName : ( a, Src.Exposed ) -> Maybe Name
extractLowerName ( _, exposedValue ) =
    case exposedValue of
        Src.Lower (A.At _ lowerName) ->
            Just lowerName

        Src.Upper _ _ ->
            Nothing

        Src.Operator _ _ ->
            Nothing



-- COMMAND LINE


type FileType
    = IsFile
    | IsDirectory
    | DoesNotExist


stat : FilePath -> Task Never FileType
stat path =
    Utils.dirDoesFileExist path
        |> Task.andThen (checkDirectoryStatus path)


checkDirectoryStatus : FilePath -> Bool -> Task Never FileType
checkDirectoryStatus path isFile =
    Utils.dirDoesDirectoryExist path
        |> Task.map (determineFileType isFile)


determineFileType : Bool -> Bool -> FileType
determineFileType isFile isDirectory =
    case ( isFile, isDirectory ) of
        ( True, _ ) ->
            IsFile

        ( _, True ) ->
            IsDirectory

        ( False, False ) ->
            DoesNotExist



-- RESOLVE FILES


type Error
    = FileDoesNotExist FilePath
    | NoElmFiles FilePath


resolveFile : FilePath -> Task Never (Result Error (List FilePath))
resolveFile path =
    stat path
        |> Task.andThen (resolveFileByType path)


resolveFileByType : FilePath -> FileType -> Task Never (Result Error (List FilePath))
resolveFileByType path fileType =
    case fileType of
        IsFile ->
            Task.succeed (Ok [ path ])

        IsDirectory ->
            findAllGuidaAndElmFiles path
                |> Task.map (validateElmFiles path)

        DoesNotExist ->
            Task.succeed (Err (FileDoesNotExist path))


validateElmFiles : FilePath -> List FilePath -> Result Error (List FilePath)
validateElmFiles path elmFiles =
    case elmFiles of
        [] ->
            Err (NoElmFiles path)

        _ ->
            Ok elmFiles


resolveElmFiles : List FilePath -> Task Never (Result (List Error) (List FilePath))
resolveElmFiles inputFiles =
    Task.mapM resolveFile inputFiles
        |> Task.map collectErrors
        |> Task.map
            (\result ->
                case result of
                    Err ls ->
                        Err ls

                    Ok files ->
                        Ok (List.concat files)
            )


collectErrors : List (Result e v) -> Result (List e) (List v)
collectErrors =
    List.foldl
        (\next acc ->
            case ( next, acc ) of
                ( Err e, Ok _ ) ->
                    Err [ e ]

                ( Err e, Err es ) ->
                    Err (e :: es)

                ( Ok v, Ok vs ) ->
                    Ok (v :: vs)

                ( Ok _, Err es ) ->
                    Err es
        )
        (Ok [])



-- FILESYSTEM


collectFiles : (a -> Task Never (List a)) -> a -> Task Never (List a)
collectFiles children root =
    children root
        |> Task.andThen (\xs -> Task.mapM (collectFiles children) xs)
        |> Task.map (\subChildren -> root :: List.concat subChildren)


listDir : FilePath -> Task Never (List FilePath)
listDir path =
    Utils.dirListDirectory path
        |> Task.map (List.map (\file -> path ++ "/" ++ file))


fileList : FilePath -> Task Never (List FilePath)
fileList =
    collectFiles fileChildren


fileChildren : FilePath -> Task Never (List FilePath)
fileChildren path =
    if isSkippable path then
        Task.succeed []

    else
        Utils.dirDoesDirectoryExist path
            |> Task.andThen (listDirIfDirectory path)


listDirIfDirectory : FilePath -> Bool -> Task Never (List FilePath)
listDirIfDirectory path isDirectory =
    if isDirectory then
        listDir path

    else
        Task.succeed []


isSkippable : FilePath -> Bool
isSkippable path =
    List.any identity
        [ hasFilename "elm-stuff" path
        , hasFilename "node_modules" path
        , hasFilename ".git" path
        ]


hasExtension : String -> FilePath -> Bool
hasExtension ext path =
    ext == Utils.fpTakeExtension path


findAllGuidaAndElmFiles : FilePath -> Task Never (List FilePath)
findAllGuidaAndElmFiles inputFile =
    fileList inputFile
        |> Task.map (List.filter (\path -> hasExtension ".guida" path || hasExtension ".elm" path))


hasFilename : String -> FilePath -> Bool
hasFilename name path =
    name == Utils.fpTakeFileName path


{-| FROM INSTALL
-}



-- ATTEMPT CHANGES


attemptChanges : FilePath -> Solver.Env -> Outline.AppOutline -> Task Exit.Test ()
attemptChanges root env appOutline =
    Task.eio Exit.TestBadDetails <|
        BW.withScope
            (\scope ->
                let
                    newOutline : Outline.Outline
                    newOutline =
                        Outline.App appOutline
                in
                Outline.write (Stuff.testDir root) newOutline
                    |> Task.andThen (\_ -> Details.verifyInstall scope root env newOutline)
            )



-- MAKE APP PLAN


makeAppPlan : Solver.Env -> Pkg.Name -> Outline.AppOutline -> Task Exit.Test Outline.AppOutline
makeAppPlan (Solver.Env env) pkg ((Outline.AppOutline appData) as outline) =
    if Dict.member identity pkg appData.depsDirect then
        Task.succeed outline

    else
        case Dict.get identity pkg appData.depsIndirect of
            Just vsn ->
                Task.succeed <|
                    Outline.AppOutline
                        { appData
                            | depsDirect = Dict.insert identity pkg vsn appData.depsDirect
                            , depsIndirect = Dict.remove identity pkg appData.depsIndirect
                        }

            Nothing ->
                case Dict.get identity pkg appData.testDirect of
                    Just vsn ->
                        Task.succeed <|
                            Outline.AppOutline
                                { appData
                                    | depsDirect = Dict.insert identity pkg vsn appData.depsDirect
                                    , testDirect = Dict.remove identity pkg appData.testDirect
                                }

                    Nothing ->
                        case Dict.get identity pkg appData.testIndirect of
                            Just vsn ->
                                Task.succeed <|
                                    Outline.AppOutline
                                        { appData
                                            | depsDirect = Dict.insert identity pkg vsn appData.depsDirect
                                            , testIndirect = Dict.remove identity pkg appData.testIndirect
                                        }

                            Nothing ->
                                addAppPackageFromScratch env.cache env.connection env.registry pkg outline


addAppPackageFromScratch :
    Stuff.PackageCache
    -> Solver.Connection
    -> Registry.Registry
    -> Pkg.Name
    -> Outline.AppOutline
    -> Task Exit.Test Outline.AppOutline
addAppPackageFromScratch cache connection registry pkg outline =
    case Registry.getVersions_ pkg registry of
        Err suggestions ->
            throwUnknownPackageError connection pkg suggestions

        Ok _ ->
            Task.io (Solver.addToApp cache connection registry pkg outline False)
                |> Task.andThen (handleAppSolverResult pkg)


throwUnknownPackageError : Solver.Connection -> Pkg.Name -> List Pkg.Name -> Task Exit.Test a
throwUnknownPackageError connection pkg suggestions =
    case connection of
        Solver.Online _ ->
            Task.throw (Exit.TestUnknownPackageOnline pkg suggestions)

        Solver.Offline ->
            Task.throw (Exit.TestUnknownPackageOffline pkg suggestions)


handleAppSolverResult : Pkg.Name -> Solver.SolverResult Solver.AppSolution -> Task Exit.Test Outline.AppOutline
handleAppSolverResult pkg result =
    case result of
        Solver.SolverOk (Solver.AppSolution _ _ app) ->
            Task.succeed app

        Solver.NoSolution ->
            Task.throw (Exit.TestNoOnlineAppSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.TestNoOfflineAppSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.TestHadSolverTrouble exit)



-- MAKE PACKAGE PLAN


makePkgPlan : Solver.Env -> Dict ( String, String ) Pkg.Name C.Constraint -> Outline.AppOutline -> Task Exit.Test Outline.AppOutline
makePkgPlan env cons outline =
    makePkgPlanHelp env (Dict.toList Pkg.compareName cons) outline


makePkgPlanHelp : Solver.Env -> List ( Pkg.Name, C.Constraint ) -> Outline.AppOutline -> Task Exit.Test Outline.AppOutline
makePkgPlanHelp ((Solver.Env envData) as env) cons outline =
    case cons of
        [] ->
            Task.succeed outline

        ( pkg, con ) :: remainingCons ->
            Task.io (Solver.addToTestApp envData.cache envData.connection envData.registry pkg con outline)
                |> Task.andThen (handlePkgSolverResult env pkg remainingCons)


handlePkgSolverResult : Solver.Env -> Pkg.Name -> List ( Pkg.Name, C.Constraint ) -> Solver.SolverResult Solver.AppSolution -> Task Exit.Test Outline.AppOutline
handlePkgSolverResult env pkg remainingCons result =
    case result of
        Solver.SolverOk (Solver.AppSolution _ _ app) ->
            makePkgPlanHelp env remainingCons app

        Solver.NoSolution ->
            Task.throw (Exit.TestNoOnlinePkgSolution pkg)

        Solver.NoOfflineSolution ->
            Task.throw (Exit.TestNoOfflinePkgSolution pkg)

        Solver.SolverErr exit ->
            Task.throw (Exit.TestHadSolverTrouble exit)



-- GET INTERPRETER


getInterpreter : Task Never FilePath
getInterpreter =
    findNodeExecutable
        |> Task.andThen (requireInterpreter "node` or `nodejs")


findNodeExecutable : Task Never (Maybe FilePath)
findNodeExecutable =
    Utils.dirFindExecutable "node"
        |> Task.andThen tryNodeJsIfNotFound


tryNodeJsIfNotFound : Maybe FilePath -> Task Never (Maybe FilePath)
tryNodeJsIfNotFound exe1 =
    Utils.dirFindExecutable "nodejs"
        |> Task.map (Maybe.or exe1)


requireInterpreter : String -> Maybe FilePath -> Task Never FilePath
requireInterpreter name maybePath =
    case maybePath of
        Just path ->
            Task.succeed path

        Nothing ->
            reportMissingInterpreterAndExit name


reportMissingInterpreterAndExit : String -> Task Never FilePath
reportMissingInterpreterAndExit name =
    IO.hPutStrLn IO.stderr (exeNotFound name)
        |> Task.andThen (\_ -> Exit.exitFailure)


exeNotFound : String -> String
exeNotFound name =
    "The TEST relies on node.js to execute JavaScript code outside the browser.\n"
        ++ "I could not find executable `"
        ++ name
        ++ "` on your PATH though!\n\n"
        ++ "You can install node.js from <http://nodejs.org/>. If it is already installed\n"
        ++ "but has a different name, use the --interpreter flag."


{-| FROM MAKE
-}
runMake : String -> String -> Task Never (Result Exit.Test String)
runMake root path =
    BW.withScope
        (\scope ->
            Task.run <|
                (Task.eio Exit.TestBadDetails (Details.load style scope root False)
                    |> Task.andThen (buildAndGenerate root path)
                )
        )


buildAndGenerate : FilePath -> FilePath -> Details.Details -> Task Exit.Test String
buildAndGenerate root path details =
    buildPaths root details (NE.Nonempty path [])
        |> Task.andThen (toBuilder 0 root details)


buildPaths : FilePath -> Details.Details -> NE.Nonempty FilePath -> Task Exit.Test Build.Artifacts
buildPaths root details paths =
    Build.fromPaths style root details False paths |> Task.eio Exit.TestCannotBuild



-- TO BUILDER


toBuilder : Int -> FilePath -> Details.Details -> Build.Artifacts -> Task Exit.Test String
toBuilder leadingLines root details artifacts =
    Generate.dev Generate.javascriptBackend False leadingLines root details artifacts |> Task.map CodeGen.outputToString |> Task.mapError Exit.TestBadGenerate



-- PARSERS


type Report
    = Json
    | JUnit
    | Console


format : Parser
format =
    Parser
        { singular = "format"
        , plural = "formats"
        , suggest = \_ -> Task.succeed []
        , examples = \_ -> Task.succeed [ "json", "junit", "console" ]
        }


parseReport : String -> Maybe Report
parseReport report =
    case report of
        "json" ->
            Just Json

        "junit" ->
            Just JUnit

        "console" ->
            Just Console

        _ ->
            Nothing
