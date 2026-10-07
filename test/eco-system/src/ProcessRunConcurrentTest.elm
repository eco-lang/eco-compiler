module ProcessRunConcurrentTest exposing (main)

{-| Twenty `run`s in parallel (one Elm process each, via `Task.attempt`) all
report their own exit codes and output (plans/eco-system-library.md Phase 5
step 5.4): a regression check for the WaitService lanes, the reap-before-
submit (`unclaimed_`) path and the per-run collectors.
-}

-- CHECK: results: 20 all-correct: True
-- EXIT: 0

import Dict exposing (Dict)
import ProcessTestHelp exposing (bytesToString, noShell)
import Stream.Log
import System
import System.Process as P
import Task


count : Int
count =
    20


type Msg
    = Done Int (Result P.FailedRun P.SuccessfulRun)
    | Logged


type alias Model =
    { env : System.Environment
    , results : Dict Int ( Int, String )
    }


runOne : Int -> Cmd Msg
runOne i =
    let
        -- Alternate between immediate exits and short sleeps so children
        -- finish in a different order than they were started.
        script =
            (if modBy 3 i == 0 then
                "sleep 0.2; "

             else if modBy 3 i == 1 then
                "sleep 0.05; "

             else
                ""
            )
                ++ "printf 'out"
                ++ String.fromInt i
                ++ "'; exit "
                ++ String.fromInt (modBy 7 i)
    in
    Task.attempt (Done i) (P.run "sh" [ "-c", script ] noShell)


outcome : Result P.FailedRun P.SuccessfulRun -> ( Int, String )
outcome result =
    case result of
        Ok r ->
            ( 0, bytesToString r.stdout )

        Err (P.ProgramError e) ->
            ( e.exitCode, bytesToString e.stdout )

        Err (P.InitError e) ->
            ( -1000, e.errorCode )


correct : Int -> ( Int, String ) -> Bool
correct i ( code, out ) =
    code == modBy 7 i && out == "out" ++ String.fromInt i


main : System.Program Model Msg
main =
    System.defineProgram
        { init =
            \env ->
                ( { env = env, results = Dict.empty }
                , Cmd.batch (List.map runOne (List.range 0 (count - 1)))
                )
        , update =
            \msg model ->
                case msg of
                    Done i result ->
                        let
                            results =
                                Dict.insert i (outcome result) model.results
                        in
                        ( { model | results = results }
                        , if Dict.size results == count then
                            Task.perform (\_ -> Logged)
                                (Stream.Log.line model.env.stdout
                                    ("results: "
                                        ++ String.fromInt (Dict.size results)
                                        ++ " all-correct: "
                                        ++ (if List.all (\( k, v ) -> correct k v) (Dict.toList results) then
                                                "True"

                                            else
                                                "False " ++ Debug.toString (Dict.toList results)
                                           )
                                    )
                                )

                          else
                            Cmd.none
                        )

                    Logged ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
