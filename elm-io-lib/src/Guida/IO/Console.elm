module Guida.IO.Console exposing
    ( Ports
    , ConsoleApi, consoleApi
    , Handle, stdout, stderr
    , putStr, putStrLn
    , hPutStr, hPutStrLn
    , getLine, replGetInputLine
    , Error(..), errorToString
    )

{-| Console IO operations for Guida IO.

@docs Ports
@docs ConsoleApi, consoleApi


# Handles

@docs Handle, stdout, stderr


# Output (Fire-and-Forget)

@docs putStr, putStrLn
@docs hPutStr, hPutStrLn


# Input (Call-and-Response)

@docs getLine, replGetInputLine


# Error Handling

@docs Error, errorToString

-}

import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)
import Procedure
import Procedure.Channel as Channel
import Procedure.Program



-- PORTS


{-| The ports that need to be wired up to the TypeScript console handlers.
-}
type alias Ports msg =
    { -- Output (fire-and-forget, no response needed)
      consoleWrite : { fd : Int, content : String } -> Cmd msg

    -- Input (call-and-response)
    , consoleGetLine : { id : String } -> Cmd msg
    , consoleReplGetInputLine : { id : String, prompt : String } -> Cmd msg

    -- Response subscription
    , consoleResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg
    }



-- HANDLES


{-| A file handle for console output.
-}
type Handle
    = Handle Int


{-| Standard output handle.
-}
stdout : Handle
stdout =
    Handle 1


{-| Standard error handle.
-}
stderr : Handle
stderr =
    Handle 2



-- API


{-| The Console API providing all console operations.
-}
type alias ConsoleApi msg =
    { putStr : String -> Cmd msg
    , putStrLn : String -> Cmd msg
    , hPutStr : Handle -> String -> Cmd msg
    , hPutStrLn : Handle -> String -> Cmd msg
    , getLine : (Result Error String -> msg) -> Cmd msg
    , replGetInputLine : String -> (Result Error (Maybe String) -> msg) -> Cmd msg
    }


{-| Creates an instance of the Console API.
-}
consoleApi : (Procedure.Program.Msg msg -> msg) -> Ports msg -> ConsoleApi msg
consoleApi pt ports =
    { putStr = putStr ports
    , putStrLn = putStrLn ports
    , hPutStr = hPutStr ports
    , hPutStrLn = hPutStrLn ports
    , getLine = getLine pt ports
    , replGetInputLine = replGetInputLine pt ports
    }



-- ERROR HANDLING


{-| Possible errors from console operations.
-}
type Error
    = ConsoleError String
    | DecodeError String
    | EndOfInput


{-| Convert an error to a human-readable string.
-}
errorToString : Error -> String
errorToString error =
    case error of
        ConsoleError msg ->
            "Console error: " ++ msg

        DecodeError msg ->
            "Decode error: " ++ msg

        EndOfInput ->
            "End of input"



-- RESPONSE DECODERS


decodeStringResponse : { a | type_ : String, payload : Value } -> Result Error String
decodeStringResponse res =
    case res.type_ of
        "Content" ->
            case Decode.decodeValue Decode.string res.payload of
                Ok content ->
                    Ok content

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "Error" ->
            case Decode.decodeValue (Decode.field "message" Decode.string) res.payload of
                Ok message ->
                    Err (ConsoleError message)

                Err _ ->
                    Err (ConsoleError "Unknown error")

        _ ->
            Err (DecodeError ("Unknown response type: " ++ res.type_))


decodeMaybeStringResponse : { a | type_ : String, payload : Value } -> Result Error (Maybe String)
decodeMaybeStringResponse res =
    case res.type_ of
        "Content" ->
            case Decode.decodeValue Decode.string res.payload of
                Ok content ->
                    Ok (Just content)

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "EndOfInput" ->
            Ok Nothing

        "Error" ->
            case Decode.decodeValue (Decode.field "message" Decode.string) res.payload of
                Ok message ->
                    Err (ConsoleError message)

                Err _ ->
                    Err (ConsoleError "Unknown error")

        _ ->
            Err (DecodeError ("Unknown response type: " ++ res.type_))



-- OUTPUT OPERATIONS (FIRE-AND-FORGET)


{-| Write a string to standard output.
-}
putStr : Ports msg -> String -> Cmd msg
putStr ports content =
    ports.consoleWrite { fd = 1, content = content }


{-| Write a string to standard output with a newline.
-}
putStrLn : Ports msg -> String -> Cmd msg
putStrLn ports content =
    ports.consoleWrite { fd = 1, content = content ++ "\n" }


{-| Write a string to a handle.
-}
hPutStr : Ports msg -> Handle -> String -> Cmd msg
hPutStr ports (Handle fd) content =
    ports.consoleWrite { fd = fd, content = content }


{-| Write a string to a handle with a newline.
-}
hPutStrLn : Ports msg -> Handle -> String -> Cmd msg
hPutStrLn ports handle content =
    hPutStr ports handle (content ++ "\n")



-- INPUT OPERATIONS (CALL-AND-RESPONSE)


{-| Read a line from standard input.
-}
getLine :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> (Result Error String -> msg)
    -> Cmd msg
getLine pt ports toMsg =
    Channel.open (\key -> ports.consoleGetLine { id = key })
        |> Channel.connect ports.consoleResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeStringResponse res |> toMsg)


{-| Read a line from standard input with a prompt (for REPL use).
Returns Nothing if end of input is reached.
-}
replGetInputLine :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error (Maybe String) -> msg)
    -> Cmd msg
replGetInputLine pt ports prompt toMsg =
    Channel.open (\key -> ports.consoleReplGetInputLine { id = key, prompt = prompt })
        |> Channel.connect ports.consoleResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeMaybeStringResponse res |> toMsg)
