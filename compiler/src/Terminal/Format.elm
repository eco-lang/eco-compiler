module Terminal.Format exposing
    ( run
    , Flags(..), FlagsProps, makeFlags
    )

{-| Code formatting command for standardizing Elm code style.

This module implements the `format` command which automatically formats Elm source
files according to the official Elm style guide. It can format files in place,
validate formatting without changes, or output to different destinations.


# Command Entry

@docs run


# Configuration

@docs Flags, FlagsProps, makeFlags

-}

import Builder.File as File
import Common.Format
import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as M
import Compiler.Parse.SyntaxVersion as SV
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E
import Json.Encode as Encode
import Result.Extra as Result
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)
import Utils.Main as Utils exposing (FilePath)
import Utils.Task.Extra as Task



-- RUN


{-| Configuration flags for the format command.
Wraps FlagsProps to provide a typed configuration structure.
-}
type Flags
    = Flags FlagsProps


{-| Properties defining format command behavior.
Fields specify output destination, validation mode, input source, and confirmation settings.
-}
type alias FlagsProps =
    { maybeOutput : Maybe FilePath
    , autoYes : Bool
    , doValidate : Bool
    , stdin : Bool
    }


{-| Construct format command flags from configuration parameters.
Takes output path, auto-confirmation, validation mode, and stdin flag to create Flags.
-}
makeFlags : Maybe FilePath -> Bool -> Bool -> Bool -> Flags
makeFlags maybeOutput autoYes doValidate stdin =
    Flags { maybeOutput = maybeOutput, autoYes = autoYes, doValidate = doValidate, stdin = stdin }


{-| Execute the format command with given file paths and configuration.
Resolves input files, validates or formats them according to flags, and handles results.
-}
run : List String -> Flags -> Task Never ()
run paths ((Flags props) as flags) =
    resolveElmFiles paths
        |> Task.andThen (determineFromConfig flags)
        |> Task.andThen (doIt props.autoYes)
        |> Task.andThen handleResult


determineFromConfig : Flags -> Result (List Error) (List FilePath) -> Task Never WhatToDo
determineFromConfig flags resolvedInputFiles =
    case determineWhatToDoFromConfig flags resolvedInputFiles of
        Err err ->
            IO.hPutStrLn IO.stderr (toConsoleErrorMessage err)
                |> Task.andThen (\_ -> Exit.exitFailure)

        Ok a ->
            Task.succeed a


handleResult : Bool -> Task Never ()
handleResult result =
    if result then
        Task.succeed ()

    else
        Exit.exitFailure


type WhatToDo
    = Format TransformMode
    | Validate ValidateMode


type Source
    = Stdin
    | FromFiles FilePath (List FilePath)


type Destination
    = InPlace
    | ToFile FilePath


type Mode
    = FormatMode
    | ValidateMode


determineSource : Bool -> Result (List Error) (List FilePath) -> Result ErrorMessage Source
determineSource stdin inputFiles =
    case ( stdin, inputFiles ) of
        ( _, Err fileErrors ) ->
            Err (BadInputFiles fileErrors)

        ( True, Ok [] ) ->
            Ok Stdin

        ( False, Ok [] ) ->
            Err NoInputs

        ( False, Ok (first :: rest) ) ->
            Ok (FromFiles first rest)

        ( True, Ok (_ :: _) ) ->
            Err TooManyInputs


determineDestination : Maybe FilePath -> Result ErrorMessage Destination
determineDestination output =
    case output of
        Just path ->
            Ok (ToFile path)

        Nothing ->
            Ok InPlace


determineMode : Bool -> Mode
determineMode doValidate =
    if doValidate then
        ValidateMode

    else
        FormatMode


determineWhatToDo : Source -> Destination -> Mode -> Result ErrorMessage WhatToDo
determineWhatToDo source destination mode =
    case ( mode, source, destination ) of
        ( ValidateMode, _, ToFile _ ) ->
            Err OutputAndValidate

        ( ValidateMode, Stdin, _ ) ->
            Ok (Validate ValidateStdin)

        ( ValidateMode, FromFiles first rest, _ ) ->
            Ok (Validate (ValidateFiles first rest))

        ( FormatMode, Stdin, InPlace ) ->
            Ok (Format StdinToStdout)

        ( FormatMode, Stdin, ToFile output ) ->
            Ok (Format (StdinToFile output))

        ( FormatMode, FromFiles first [], ToFile output ) ->
            Ok (Format (FileToFile first output))

        ( FormatMode, FromFiles first rest, InPlace ) ->
            Ok (Format (FilesInPlace first rest))

        ( _, FromFiles _ _, ToFile _ ) ->
            Err SingleOutputWithMultipleInputs


determineWhatToDoFromConfig : Flags -> Result (List Error) (List FilePath) -> Result ErrorMessage WhatToDo
determineWhatToDoFromConfig (Flags props) resolvedInputFiles =
    determineSource props.stdin resolvedInputFiles
        |> Result.andThen
            (\source ->
                determineDestination props.maybeOutput
                    |> Result.andThen
                        (\destination ->
                            determineWhatToDo source destination (determineMode props.doValidate)
                        )
            )


validate : ( FilePath, String ) -> Result InfoMessage ()
validate (( inputFile, inputText ) as input) =
    case format input of
        Ok modu ->
            if inputText /= modu then
                Err (FileWouldChange inputFile)

            else
                Ok ()

        Err err ->
            Err err


format : ( FilePath, String ) -> Result InfoMessage String
format ( inputFile, inputText ) =
    -- FIXME fix hardcoded projectType
    Common.Format.format (SV.fileSyntaxVersion inputFile) (M.Package Pkg.core) inputText
        |> Result.mapError
            (\_ ->
                -- FIXME show errors!
                -- let
                --     _ =
                --         Debug.log "err" err
                -- in
                ParseError inputFile []
            )


doIt : Bool -> WhatToDo -> Task Never Bool
doIt autoYes whatToDo =
    case whatToDo of
        Validate validateMode ->
            validateNoChanges validateMode

        Format transformMode ->
            applyTransformation
                ProcessingFile
                autoYes
                FilesWillBeOverwritten
                format
                transformMode



-- MESSAGES


type InfoMessage
    = ProcessingFile FilePath
    | FileWouldChange FilePath
    | ParseError FilePath (List (A.Located E.Error))
    | JsonParseError FilePath String


type PromptMessage
    = FilesWillBeOverwritten (List FilePath)


type ErrorMessage
    = BadInputFiles (List Error)
    | NoInputs
    | SingleOutputWithMultipleInputs
    | TooManyInputs
    | OutputAndValidate


showFiles : List FilePath -> String
showFiles =
    List.map (\filename -> "    " ++ filename) >> unlines


toConsolePromptMessage : PromptMessage -> String
toConsolePromptMessage promptMessage =
    case promptMessage of
        FilesWillBeOverwritten filePaths ->
            unlines
                [ "This will overwrite the following files to use Elm's preferred style:"
                , ""
                , showFiles filePaths
                , "This cannot be undone! Make sure to back up these files before proceeding."
                , ""
                , "Are you sure you want to overwrite these files with formatted versions? (y/n)"
                ]


toConsoleInfoMessage : InfoMessage -> String
toConsoleInfoMessage infoMessage =
    case infoMessage of
        ProcessingFile file ->
            "Processing file " ++ file

        FileWouldChange file ->
            "File would be changed " ++ file

        ParseError inputFile errs ->
            let
                location : FilePath
                location =
                    case errs of
                        [] ->
                            inputFile

                        (A.At (A.Region (A.Position line col) _) _) :: _ ->
                            inputFile ++ ":" ++ String.fromInt line ++ ":" ++ String.fromInt col
            in
            "Unable to parse file " ++ location ++ " To see a detailed explanation, run elm make on the file."

        JsonParseError inputFile err ->
            "Unable to parse JSON file " ++ inputFile ++ "\n\n" ++ err


jsonInfoMessage : InfoMessage -> Maybe Encode.Value
jsonInfoMessage infoMessage =
    let
        fileMessage : String -> String -> Encode.Value
        fileMessage filename message =
            Encode.object
                [ ( "path", Encode.string filename )
                , ( "message", Encode.string message )
                ]
    in
    case infoMessage of
        ProcessingFile _ ->
            Nothing

        FileWouldChange file ->
            Just (fileMessage file "File is not formatted with elm-format-0.8.7 --elm-version=0.19")

        ParseError inputFile _ ->
            Just (fileMessage inputFile "Error parsing the file")

        JsonParseError inputFile _ ->
            Just (fileMessage inputFile "Error parsing the JSON file")


toConsoleErrorMessage : ErrorMessage -> String
toConsoleErrorMessage errorMessage =
    case errorMessage of
        BadInputFiles filePaths ->
            unlines
                [ "There was a problem reading one or more of the specified INPUT paths:"
                , ""
                , unlines (List.map (\fp -> "    " ++ toConsoleError fp) filePaths)
                , "Please check the given paths."
                ]

        SingleOutputWithMultipleInputs ->
            unlines
                [ "Can't write to the OUTPUT path, because multiple .elm files have been specified."
                , ""
                , "Please remove the --output argument. The .elm files in INPUT will be formatted in place."
                ]

        TooManyInputs ->
            "Too many input sources! Please only provide one of either INPUT or --stdin"

        OutputAndValidate ->
            "Cannot use --output and --validate together"

        NoInputs ->
            "No file inputs provided. Use the --stdin flag to format input from standard input."



-- COMMAND LINE


type FileType
    = IsFile
    | IsDirectory
    | DoesNotExist


readUtf8FileWithPath : FilePath -> Task Never ( FilePath, String )
readUtf8FileWithPath filePath =
    File.readUtf8 filePath
        |> Task.map (Tuple.pair filePath)


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


getYesOrNo : Task Never Bool
getYesOrNo =
    IO.hFlush IO.stdout
        |> Task.andThen (\_ -> IO.getLine)
        |> Task.andThen parseYesOrNo


parseYesOrNo : String -> Task Never Bool
parseYesOrNo input =
    case input of
        "y" ->
            Task.succeed True

        "n" ->
            Task.succeed False

        _ ->
            IO.putStr "Must type 'y' for yes or 'n' for no: "
                |> Task.andThen (\_ -> getYesOrNo)


type ValidateMode
    = ValidateStdin
    | ValidateFiles FilePath (List FilePath)



-- INFO FORMATTER


approve : Bool -> PromptMessage -> Task Never Bool
approve autoYes prompt =
    if autoYes then
        Task.succeed True

    else
        putStrLn False (toConsolePromptMessage prompt)
            |> Task.andThen (\_ -> getYesOrNo)


putStrLn : Bool -> String -> Task Never ()
putStrLn usingStdout =
    -- we log to stdout unless it is being used for file output (in that case, we log to stderr)
    if usingStdout then
        IO.hPutStrLn IO.stderr

    else
        IO.putStrLn


resultsToJsonString : List (Result (Maybe String) ()) -> String
resultsToJsonString results =
    let
        lines : List String
        lines =
            List.filterMap extractError results

        extractError : Result (Maybe String) () -> Maybe String
        extractError res =
            case res of
                Err info ->
                    info

                Ok () ->
                    Nothing
    in
    if List.isEmpty lines then
        "[]"

    else
        "[" ++ String.join "\n," lines ++ "\n]"



-- RESOLVE FILES


type Error
    = FileDoesNotExist FilePath
    | NoElmFiles FilePath


toConsoleError : Error -> String
toConsoleError error =
    case error of
        FileDoesNotExist path ->
            path ++ ": No such file or directory"

        NoElmFiles path ->
            path ++ ": Directory does not contain any *.elm files"


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
            findAllElmFiles path
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



-- TRANSFORM FILES


type TranformFilesResult a
    = NoChange FilePath a
    | Changed FilePath a


updateFile : TranformFilesResult String -> Task Never ()
updateFile result =
    case result of
        NoChange _ _ ->
            Task.succeed ()

        Changed outputFile outputText ->
            File.writeUtf8 outputFile outputText


readStdin : Task Never ( FilePath, String )
readStdin =
    File.readStdin
        |> Task.map (Tuple.pair "<STDIN>")


checkChange : ( FilePath, a ) -> a -> TranformFilesResult a
checkChange ( inputFile, inputText ) outputText =
    if inputText == outputText then
        NoChange inputFile outputText

    else
        Changed inputFile outputText


readFromFile : (FilePath -> Task Never ()) -> FilePath -> Task Never ( FilePath, String )
readFromFile onProcessingFile filePath =
    onProcessingFile filePath
        |> Task.andThen (\_ -> readUtf8FileWithPath filePath)


type TransformMode
    = StdinToStdout
    | StdinToFile FilePath
    | FileToStdout FilePath
    | FileToFile FilePath FilePath
    | FilesInPlace FilePath (List FilePath)


applyTransformation : (FilePath -> InfoMessage) -> Bool -> (List FilePath -> PromptMessage) -> (( FilePath, String ) -> Result InfoMessage String) -> TransformMode -> Task Never Bool
applyTransformation processingFile autoYes confirmPrompt transform mode =
    let
        usesStdout : Bool
        usesStdout =
            case mode of
                StdinToStdout ->
                    True

                StdinToFile _ ->
                    True

                FileToStdout _ ->
                    True

                FileToFile _ _ ->
                    False

                FilesInPlace _ _ ->
                    False

        onInfo : InfoMessage -> Task Never ()
        onInfo info =
            if usesStdout then
                IO.hPutStrLn IO.stderr (toConsoleInfoMessage info)

            else
                IO.putStrLn (toConsoleInfoMessage info)
    in
    case mode of
        StdinToStdout ->
            readStdin
                |> Task.andThen (logErrorOr onInfo IO.putStr << transform)

        StdinToFile outputFile ->
            readStdin
                |> Task.andThen (logErrorOr onInfo (File.writeUtf8 outputFile) << transform)

        FileToStdout inputFile ->
            readUtf8FileWithPath inputFile
                |> Task.andThen (logErrorOr onInfo IO.putStr << transform)

        FileToFile inputFile outputFile ->
            readFromFile (onInfo << processingFile) inputFile
                |> Task.andThen (logErrorOr onInfo (File.writeUtf8 outputFile) << transform)

        FilesInPlace first rest ->
            let
                formatFile : FilePath -> Task Never Bool
                formatFile file =
                    readFromFile (onInfo << processingFile) file
                        |> Task.andThen (\i -> Result.map (checkChange i) (transform i) |> logErrorOr onInfo updateFile)
            in
            approve autoYes (confirmPrompt (first :: rest))
                |> Task.andThen (formatFilesIfApproved formatFile first rest)


formatFilesIfApproved : (FilePath -> Task Never Bool) -> FilePath -> List FilePath -> Bool -> Task Never Bool
formatFilesIfApproved formatFile first rest canOverwrite =
    if canOverwrite then
        Task.mapM formatFile (first :: rest)
            |> Task.map (List.all identity)

    else
        Task.succeed True


validateNoChanges : ValidateMode -> Task Never Bool
validateNoChanges mode =
    case mode of
        ValidateStdin ->
            readStdin
                |> Task.andThen validateStdinContent

        ValidateFiles first rest ->
            Task.mapM validateFileContent (first :: rest)
                |> Task.andThen outputValidationResults


newValidate : FilePath -> String -> Result (Maybe String) ()
newValidate filePath content =
    case validate ( filePath, content ) of
        Err info ->
            Err (Maybe.map (Encode.encode 0) (jsonInfoMessage info))

        Ok value ->
            Ok value


validateStdinContent : ( FilePath, String ) -> Task Never Bool
validateStdinContent ( filePath, content ) =
    let
        result =
            newValidate filePath content
    in
    IO.putStrLn (resultsToJsonString [ result ])
        |> Task.map (\_ -> Result.isOk result)


validateFileContent : FilePath -> Task Never (Result (Maybe String) ())
validateFileContent filePath =
    File.readUtf8 filePath
        |> Task.map (newValidate filePath)


outputValidationResults : List (Result (Maybe String) ()) -> Task Never Bool
outputValidationResults results =
    IO.putStrLn (resultsToJsonString results)
        |> Task.map (\_ -> List.all Result.isOk results)


logErrorOr : (error -> Task Never ()) -> (a -> Task Never ()) -> Result error a -> Task Never Bool
logErrorOr onInfo fn result =
    case result of
        Err message ->
            onInfo message
                |> Task.map (\_ -> False)

        Ok value ->
            fn value
                |> Task.map (\_ -> True)



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


findAllElmFiles : FilePath -> Task Never (List FilePath)
findAllElmFiles inputFile =
    fileList inputFile
        |> Task.map (List.filter (hasExtension ".elm"))


hasFilename : String -> FilePath -> Bool
hasFilename name path =
    name == Utils.fpTakeFileName path



-- PRELUDE


unlines : List String -> String
unlines =
    List.map (\line -> line ++ "\n")
        >> String.concat
