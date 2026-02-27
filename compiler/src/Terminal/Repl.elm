module Terminal.Repl exposing
    ( run
    , Flags(..)
    , Input(..), CategorizedInput(..), Lines(..), Prefill(..)
    , Output(..)
    )

{-| Interactive Read-Eval-Print Loop for Elm.

This module implements an interactive programming session where users can type
Elm expressions, declarations, imports, and type definitions, and see the results
immediately. It provides a learning environment and quick experimentation tool.


# Command Entry

@docs run


# Configuration

@docs Flags


# Input Processing

@docs Input, CategorizedInput, Lines, Prefill


# Output Generation

@docs Output

-}

import Builder.BackgroundWriter as BW
import Builder.Build as Build
import Builder.Elm.Details as Details
import Builder.Elm.Outline as Outline
import Builder.Generate as Generate
import Builder.Reporting as Reporting
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.AST.Source as Src
import Compiler.Data.Name as N
import Compiler.Elm.Constraint as C
import Compiler.Elm.Licenses as Licenses
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Parse.Declaration as PD
import Compiler.Parse.Expression as PE
import Compiler.Parse.Module as PM
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Parse.Space as PS
import Compiler.Parse.Type as PT
import Compiler.Parse.Variable as PV
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error.Syntax as ES
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Report as Report
import Control.Monad.State.Strict as State
import Data.Map as Map exposing (Dict)
import Dict
import List.Extra as List
import Maybe.Extra as Maybe
import Prelude
import System.Exit as Exit
import System.IO as IO exposing (FilePath)
import System.Process as Process
import Task exposing (Task)
import Utils.Crash exposing (crash)
import Utils.Main as Utils
import Utils.Task.Extra as Task



-- ====== RUN ======


{-| Configuration flags for the REPL session.

Contains optional interpreter path and color output setting.

-}
type Flags
    = Flags (Maybe FilePath) Bool


{-| Start an interactive REPL session.

Initializes the REPL environment, displays the welcome message, and begins
the read-eval-print loop for evaluating Elm expressions and declarations.

-}
run : () -> Flags -> Task Never ()
run () flags =
    printWelcomeMessage
        |> Task.andThen (\_ -> initSettings)
        |> Task.andThen (startReplWithSettings flags)


startReplWithSettings : Flags -> IO.ReplSettings -> Task Never ()
startReplWithSettings flags settings =
    initEnv flags
        |> Task.andThen (runReplLoop settings)


runReplLoop : IO.ReplSettings -> Env -> Task Never ()
runReplLoop settings env =
    let
        looper : M Exit.ExitCode
        looper =
            Utils.replRunInputT settings (Utils.replWithInterrupt (loop env IO.initialReplState))
    in
    State.evalStateT looper IO.initialReplState
        |> Task.andThen Exit.exitWith



-- ====== WELCOME ======


printWelcomeMessage : Task Never ()
printWelcomeMessage =
    let
        vsn : String
        vsn =
            V.toChars V.compiler

        title : D.Doc
        title =
            D.fromChars "Eco"
                |> D.plus (D.fromChars vsn)

        dashes : String
        dashes =
            String.repeat (70 - String.length vsn) "-"
    in
    D.toAnsi IO.stdout <|
        D.vcat
            [ D.black (D.fromChars "----")
                |> D.plus (D.dullcyan title)
                |> D.plus (D.black (D.fromChars dashes))
            , D.black (D.fromChars "Say :help for help and :exit to exit! More at ")
                |> D.a (D.fromChars (D.makeLink "repl"))
            , D.black (D.fromChars "--------------------------------------------------------------------------------")
            , D.fromChars ""
            ]



-- ====== ENV ======


type Env
    = Env FilePath FilePath Bool


initEnv : Flags -> Task Never Env
initEnv (Flags maybeAlternateInterpreter noColors) =
    getRoot
        |> Task.andThen (addInterpreter maybeAlternateInterpreter noColors)


addInterpreter : Maybe FilePath -> Bool -> FilePath -> Task Never Env
addInterpreter maybeAlternateInterpreter noColors root =
    getInterpreter maybeAlternateInterpreter
        |> Task.map (\interpreter -> Env root interpreter (not noColors))



-- ====== LOOP ======


type Outcome
    = Loop IO.ReplState
    | End Exit.ExitCode


type alias M a =
    State.StateT IO.ReplState a


loop : Env -> IO.ReplState -> Utils.ReplInputT Exit.ExitCode
loop env state =
    read
        |> Task.andThen (evalInput env state)
        |> Task.andThen (handleOutcome env)


evalInput : Env -> IO.ReplState -> Input -> Utils.ReplInputT Outcome
evalInput env state input =
    Utils.liftIOInputT (eval env state input)


handleOutcome : Env -> Outcome -> Utils.ReplInputT Exit.ExitCode
handleOutcome env outcome =
    case outcome of
        Loop loopState ->
            Utils.liftInputT (State.put loopState)
                |> Task.andThen (\_ -> loop env loopState)

        End exitCode ->
            Task.succeed exitCode



-- ====== READ ======


{-| Represents a categorized line of user input in the REPL.

Can be an import, type definition, port declaration, value declaration,
expression, or a REPL command (reset, exit, skip, help).

-}
type Input
    = Import ModuleName.Raw String
    | Type N.Name String
    | Port
    | Decl N.Name String
    | Expr String
      --
    | Reset
    | Exit
    | Skip
    | Help (Maybe String)


read : Utils.ReplInputT Input
read =
    Utils.replGetInputLine "> "
        |> Task.andThen processInitialLine


processInitialLine : Maybe String -> Utils.ReplInputT Input
processInitialLine maybeLine =
    case maybeLine of
        Nothing ->
            Task.succeed Exit

        Just chars ->
            let
                lines : Lines
                lines =
                    Lines (stripLegacyBackslash chars) []
            in
            processCategorizedInput lines


processCategorizedInput : Lines -> Utils.ReplInputT Input
processCategorizedInput lines =
    case categorize lines of
        Done input ->
            Task.succeed input

        Continue p ->
            readMore lines p


readMore : Lines -> Prefill -> Utils.ReplInputT Input
readMore previousLines prefill =
    Utils.replGetInputLineWithInitial "| " ( renderPrefill prefill, "" )
        |> Task.andThen (processContinuedLine previousLines)


processContinuedLine : Lines -> Maybe String -> Utils.ReplInputT Input
processContinuedLine previousLines input =
    case input of
        Nothing ->
            Task.succeed Skip

        Just chars ->
            let
                lines : Lines
                lines =
                    addLine (stripLegacyBackslash chars) previousLines
            in
            processCategorizedInput lines



{- For compatibility with 0.19.0 such that readers of "Programming Elm" by @jfairbank
   can get through the REPL section successfully.
   TODO: Remove stripLegacyBackslash in next MAJOR release.
-}


stripLegacyBackslash : String -> String
stripLegacyBackslash chars =
    case String.toList chars of
        [] ->
            ""

        (_ :: _) as charsList ->
            if Prelude.last charsList == '\\' then
                String.fromList (Prelude.init charsList)

            else
                chars


{-| Pre-filled text for multi-line input continuation.

Provides either indentation or the start of a definition name to help
users continue typing multi-line declarations.

-}
type Prefill
    = Indent
    | DefStart N.Name


renderPrefill : Prefill -> String
renderPrefill lineStart =
    case lineStart of
        Indent ->
            "  "

        DefStart name ->
            name ++ " "



-- ====== LINES ======


{-| Accumulates multiple lines of user input.

Stores the most recent line and a reversed list of previous lines for
efficient appending during multi-line input.

-}
type Lines
    = Lines String (List String)


addLine : String -> Lines -> Lines
addLine line (Lines x xs) =
    Lines line (x :: xs)


isBlank : Lines -> Bool
isBlank (Lines prev rev) =
    List.isEmpty rev && String.all ((==) ' ') prev


isSingleLine : Lines -> Bool
isSingleLine (Lines _ rev) =
    List.isEmpty rev


endsWithBlankLine : Lines -> Bool
endsWithBlankLine (Lines prev _) =
    String.all ((==) ' ') prev


linesToByteString : Lines -> String
linesToByteString (Lines prev rev) =
    Utils.unlines (List.reverse (prev :: rev))


getFirstLine : Lines -> String
getFirstLine (Lines x xs) =
    case xs of
        [] ->
            x

        y :: ys ->
            getFirstLine (Lines y ys)



-- ====== CATEGORIZE INPUT ======


{-| Result of analyzing user input to determine if it's complete.

Either the input is complete and can be evaluated (Done), or more lines
are needed and a prefill suggestion is provided (Continue).

-}
type CategorizedInput
    = Done Input
    | Continue Prefill


categorize : Lines -> CategorizedInput
categorize lines =
    if isBlank lines then
        Done Skip

    else if startsWithColon lines then
        Done (toCommand lines)

    else if startsWithKeyword "import" lines then
        attemptImport lines

    else
        attemptDeclOrExpr lines


attemptImport : Lines -> CategorizedInput
attemptImport lines =
    let
        src : String
        src =
            linesToByteString lines

        parser : P.Parser () (Src.C1 Src.Import)
        parser =
            P.specialize (\_ _ _ -> ()) PM.chompImport
    in
    case P.fromByteString parser (\_ _ -> ()) src of
        Ok ( _, Src.Import ( _, A.At _ name ) _ _ ) ->
            Done (Import name src)

        Err () ->
            ifFail lines (Import "ERR" src)


ifFail : Lines -> Input -> CategorizedInput
ifFail lines input =
    if endsWithBlankLine lines then
        Done input

    else
        Continue Indent


ifDone : Lines -> Input -> CategorizedInput
ifDone lines input =
    if isSingleLine lines || endsWithBlankLine lines then
        Done input

    else
        Continue Indent


attemptDeclOrExpr : Lines -> CategorizedInput
attemptDeclOrExpr lines =
    let
        src : String
        src =
            linesToByteString lines

        declParser : P.Parser ( Row, Col ) ( PD.Decl, A.Position )
        declParser =
            P.specialize (toDeclPosition src) (P.map (Tuple.mapFirst Src.c2Value) PD.declaration)
    in
    case P.fromByteString declParser Tuple.pair src of
        Ok ( decl, _ ) ->
            case decl of
                PD.Value _ (A.At _ (Src.Value v)) ->
                    let
                        ( _, A.At _ name ) =
                            v.name
                    in
                    ifDone lines (Decl name src)

                PD.Union _ (A.At _ (Src.Union ( _, A.At _ name ) _ _)) ->
                    ifDone lines (Type name src)

                PD.Alias _ (A.At _ (Src.Alias aliasData)) ->
                    let
                        ( _, A.At _ name ) =
                            aliasData.name
                    in
                    ifDone lines (Type name src)

                PD.Port _ _ ->
                    Done Port

        Err declPosition ->
            if startsWithKeyword "type" lines then
                ifFail lines (Type "ERR" src)

            else if startsWithKeyword "port" lines then
                Done Port

            else
                let
                    exprParser : P.Parser ( Row, Col ) ( Src.C1 Src.Expr, A.Position )
                    exprParser =
                        P.specialize (toExprPosition src) PE.expression
                in
                case P.fromByteString exprParser Tuple.pair src of
                    Ok _ ->
                        ifDone lines (Expr src)

                    Err exprPosition ->
                        if exprPosition >= declPosition then
                            ifFail lines (Expr src)

                        else
                            case P.fromByteString annotation (\_ _ -> ()) src of
                                Ok name ->
                                    Continue (DefStart name)

                                Err () ->
                                    ifFail lines (Decl "ERR" src)


startsWithColon : Lines -> Bool
startsWithColon lines =
    case List.dropWhile ((==) ' ') (String.toList (getFirstLine lines)) of
        [] ->
            False

        c :: _ ->
            c == ':'


toCommand : Lines -> Input
toCommand lines =
    case List.dropWhile ((==) ' ') (String.toList (getFirstLine lines)) |> List.drop 1 |> String.fromList of
        "reset" ->
            Reset

        "exit" ->
            Exit

        "quit" ->
            Exit

        "help" ->
            Help Nothing

        rest ->
            Help (Just (String.fromList (List.takeWhile ((/=) ' ') (String.toList rest))))


startsWithKeyword : String -> Lines -> Bool
startsWithKeyword keyword lines =
    let
        line : String
        line =
            getFirstLine lines
    in
    String.startsWith keyword line
        && (case List.drop (String.length keyword) (String.toList line) of
                [] ->
                    True

                c :: _ ->
                    not (Char.isAlphaNum c)
           )


toExprPosition : String -> ES.Expr -> Row -> Col -> ( Row, Col )
toExprPosition src expr row col =
    let
        decl : ES.Decl
        decl =
            ES.DeclDef N.replValueToPrint (ES.DeclDefBody expr row col) row col
    in
    toDeclPosition src decl row col


toDeclPosition : String -> ES.Decl -> Row -> Col -> ( Row, Col )
toDeclPosition src decl r c =
    let
        err : ES.Error
        err =
            ES.ParseError (ES.Declarations decl r c)

        report : Report.Report
        report =
            ES.toReport (Code.toSource src) err

        (Report.Report props) =
            report

        (A.Region (A.Position row col) _) =
            props.region
    in
    ( row, col )


annotation : P.Parser () N.Name
annotation =
    let
        err : Row -> Col -> ()
        err _ _ =
            ()

        err_ : x -> Row -> Col -> ()
        err_ _ _ _ =
            ()
    in
    PV.lower err
        |> P.andThen
            (\name ->
                PS.chompAndCheckIndent err_ err
                    |> P.andThen (\_ -> P.word1 ':' err)
                    |> P.andThen (\_ -> PS.chompAndCheckIndent err_ err)
                    |> P.andThen (\_ -> P.specialize err_ (PT.expression []))
                    |> P.andThen (\_ -> PS.checkFreshLine err)
                    |> P.map (\_ -> name)
            )



-- ====== EVAL ======


eval : Env -> IO.ReplState -> Input -> Task Never Outcome
eval env ((IO.ReplState imports types decls) as state) input =
    case input of
        Skip ->
            Task.succeed (Loop state)

        Exit ->
            Task.succeed (End Exit.ExitSuccess)

        Reset ->
            IO.putStrLn "<reset>"
                |> Task.map (\_ -> Loop IO.initialReplState)

        Help maybeUnknownCommand ->
            IO.putStrLn (toHelpMessage maybeUnknownCommand)
                |> Task.map (\_ -> Loop state)

        Import name src ->
            let
                newState : IO.ReplState
                newState =
                    IO.ReplState (Dict.insert name src imports) types decls
            in
            Task.map Loop (attemptEval env state newState OutputNothing)

        Type name src ->
            let
                newState : IO.ReplState
                newState =
                    IO.ReplState imports (Dict.insert name src types) decls
            in
            Task.map Loop (attemptEval env state newState OutputNothing)

        Port ->
            IO.putStrLn "I cannot handle port declarations."
                |> Task.map (\_ -> Loop state)

        Decl name src ->
            let
                newState : IO.ReplState
                newState =
                    IO.ReplState imports types (Dict.insert name src decls)
            in
            Task.map Loop (attemptEval env state newState (OutputDecl name))

        Expr src ->
            Task.map Loop (attemptEval env state state (OutputExpr src))



-- ====== ATTEMPT EVAL ======


{-| Describes what kind of output should be generated after evaluation.

OutputNothing for imports/types, OutputDecl for named declarations,
OutputExpr for expressions that should be printed.

-}
type Output
    = OutputNothing
    | OutputDecl N.Name
    | OutputExpr String


attemptEval : Env -> IO.ReplState -> IO.ReplState -> Output -> Task Never IO.ReplState
attemptEval (Env root interpreter ansi) oldState newState output =
    BW.withScope (buildAndGenerate root ansi newState output)
        |> Task.andThen (handleEvalResult interpreter oldState newState)


buildAndGenerate : FilePath -> Bool -> IO.ReplState -> Output -> BW.Scope -> Task Never (Result Exit.Repl (Maybe String))
buildAndGenerate root ansi newState output scope =
    Stuff.withRootLock root
        (Task.run
            (Task.eio Exit.ReplBadDetails (Details.load Reporting.silent scope root Nothing False False)
                |> Task.andThen (buildAndGenerateWithDetails root ansi newState output)
            )
        )


buildAndGenerateWithDetails : FilePath -> Bool -> IO.ReplState -> Output -> Details.Details -> Task Exit.Repl (Maybe String)
buildAndGenerateWithDetails root ansi newState output details =
    Task.eio identity (Build.fromRepl root details (toByteString newState output))
        |> Task.andThen (generateOutput root details ansi output)


generateOutput : FilePath -> Details.Details -> Bool -> Output -> Build.ReplArtifacts -> Task Exit.Repl (Maybe String)
generateOutput root details ansi output artifacts =
    Utils.maybeTraverseTask
        (Task.mapError Exit.ReplBadGenerate
            << Task.map CodeGen.outputToString
            << Generate.repl Generate.javascriptBackend root details ansi artifacts
        )
        (toPrintName output)


handleEvalResult : FilePath -> IO.ReplState -> IO.ReplState -> Result Exit.Repl (Maybe String) -> Task Never IO.ReplState
handleEvalResult interpreter oldState newState result =
    case result of
        Err exit ->
            Exit.toStderr (Exit.replToReport exit)
                |> Task.map (\_ -> oldState)

        Ok Nothing ->
            Task.succeed newState

        Ok (Just javascript) ->
            interpret interpreter javascript
                |> Task.map (selectState oldState newState)


selectState : IO.ReplState -> IO.ReplState -> Exit.ExitCode -> IO.ReplState
selectState oldState newState exitCode =
    case exitCode of
        Exit.ExitSuccess ->
            newState

        Exit.ExitFailure _ ->
            oldState


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



-- ====== TO BYTESTRING ======


toByteString : IO.ReplState -> Output -> String
toByteString (IO.ReplState imports types decls) output =
    String.concat
        [ "module "
        , N.replModule
        , " exposing (..)\n"
        , Dict.foldr (\_ -> (++)) "" imports
        , Dict.foldr (\_ -> (++)) "" types
        , Dict.foldr (\_ -> (++)) "" decls
        , outputToBuilder output
        ]


outputToBuilder : Output -> String
outputToBuilder output =
    N.replValueToPrint
        ++ " ="
        ++ (case output of
                OutputNothing ->
                    " ()\n"

                OutputDecl _ ->
                    " ()\n"

                OutputExpr expr ->
                    List.foldr (\line rest -> "\n  " ++ line ++ rest) "\n" (Utils.lines expr)
           )



-- ====== TO PRINT NAME ======


toPrintName : Output -> Maybe N.Name
toPrintName output =
    case output of
        OutputNothing ->
            Nothing

        OutputDecl name ->
            Just name

        OutputExpr _ ->
            Just N.replValueToPrint



-- ====== HELP MESSAGES ======


toHelpMessage : Maybe String -> String
toHelpMessage maybeBadCommand =
    case maybeBadCommand of
        Nothing ->
            genericHelpMessage

        Just command ->
            "I do not recognize the :" ++ command ++ " command. " ++ genericHelpMessage


genericHelpMessage : String
genericHelpMessage =
    "Valid commands include:\n\n  :exit    Exit the REPL\n  :help    Show this information\n  :reset   Clear all previous imports and definitions\n\nMore info at " ++ D.makeLink "repl" ++ "\n"



-- ====== GET ROOT ======


getRoot : Task Never FilePath
getRoot =
    Stuff.findRoot
        |> Task.andThen handleMaybeRoot


handleMaybeRoot : Maybe FilePath -> Task Never FilePath
handleMaybeRoot maybeRoot =
    case maybeRoot of
        Just root ->
            Task.succeed root

        Nothing ->
            Stuff.getReplCache
                |> Task.andThen createTempProject


createTempProject : FilePath -> Task Never FilePath
createTempProject cache =
    let
        root : String
        root =
            cache ++ "/tmp"
    in
    Utils.dirCreateDirectoryIfMissing True (root ++ "/src")
        |> Task.andThen (\_ -> writeTempOutlineAndReturnRoot root)


writeTempOutlineAndReturnRoot : FilePath -> Task Never FilePath
writeTempOutlineAndReturnRoot root =
    writeTempOutline root
        |> Task.map (\_ -> root)


writeTempOutline : FilePath -> Task Never ()
writeTempOutline root =
    Outline.PkgOutline
        { name = Pkg.dummyName
        , summary = Outline.defaultSummary
        , license = Licenses.bsd3
        , version = V.one
        , exposed = Outline.ExposedList []
        , deps = defaultDeps
        , testDeps = Map.empty
        , elm = C.defaultElm
        }
        |> Outline.Pkg
        |> Outline.write root


defaultDeps : Dict ( String, String ) Pkg.Name C.Constraint
defaultDeps =
    Map.fromList identity
        [ ( Pkg.core, C.anything )
        , ( Pkg.json, C.anything )
        , ( Pkg.html, C.anything )
        ]



-- ====== GET INTERPRETER ======


getInterpreter : Maybe String -> Task Never FilePath
getInterpreter maybeName =
    case maybeName of
        Just name ->
            getInterpreterHelp name (Utils.dirFindExecutable name)

        Nothing ->
            getInterpreterHelp "node` or `nodejs" findNodeExecutable


findNodeExecutable : Task Never (Maybe FilePath)
findNodeExecutable =
    Utils.dirFindExecutable "node"
        |> Task.andThen addNodejsFallback


addNodejsFallback : Maybe FilePath -> Task Never (Maybe FilePath)
addNodejsFallback exe1 =
    Utils.dirFindExecutable "nodejs"
        |> Task.map (\exe2 -> Maybe.or exe1 exe2)


getInterpreterHelp : String -> Task Never (Maybe FilePath) -> Task Never FilePath
getInterpreterHelp name findExe =
    findExe
        |> Task.andThen (requireInterpreter name)


requireInterpreter : String -> Maybe FilePath -> Task Never FilePath
requireInterpreter name maybePath =
    case maybePath of
        Just path ->
            Task.succeed path

        Nothing ->
            IO.hPutStrLn IO.stderr (exeNotFound name)
                |> Task.andThen (\_ -> Exit.exitFailure)


exeNotFound : String -> String
exeNotFound name =
    "The REPL relies on node.js to execute JavaScript code outside the browser.\n"
        ++ "I could not find executable `"
        ++ name
        ++ "` on your PATH though!\n\n"
        ++ "You can install node.js from <http://nodejs.org/>. If it is already installed\n"
        ++ "but has a different name, use the --interpreter flag."



-- ====== SETTINGS ======


initSettings : Task Never IO.ReplSettings
initSettings =
    Stuff.getReplCache
        |> Task.map
            (\_ ->
                IO.ReplSettings
            )
