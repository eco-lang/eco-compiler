module TimeEveryDuplicateIntervalTest exposing (main)

{-| TIME-07 (plans/kernel-lib-bug-fixes.md): several `Time.every` subscriptions with the same
interval and different taggers must all tick. elm/time's effect manager keeps, per interval, the
LIST of taggers and sends each of them the one `Time.now` of that tick (`Dict` of interval to
taggers; the round goes out in subscription order). Before the fix the native manager (TimeEffectManager.cpp)
kept one tagger per interval, so only the last-declared one (`Wrap C`) was delivered and
`a ticked` / `b ticked` printed False; it now keeps them all (`IntervalState.taggerEncs`).

Three subscriptions share 20 ms: `A`, `B` and `Sub.map Wrap (Time.every 20 C)`. The program stops
(Sub.none) once any tagger has 5 ticks, waits 100 ms for the rest of that round, then reports.
Expected output recorded from Elm on node.

-}

-- CHECK: dup: "a ticked: True"
-- CHECK: dup: "b ticked: True"
-- CHECK: dup: "c ticked: True"
-- CHECK: dup: "same time per round: True"
-- CHECK: dup: "first round: A,B,C"

import Platform
import Process
import Task
import Time


type Inner
    = C Time.Posix


type Msg
    = A Time.Posix
    | B Time.Posix
    | Wrap Inner
    | Report


type alias Model =
    { a : List Int
    , b : List Int
    , c : List Int
    , order : List String
    , done : Bool
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { a = [], b = [], c = [], order = [], done = False }, Cmd.none )


record : String -> Model -> Model
record name model =
    { model | order = model.order ++ [ name ] }


stopIfDone : Model -> ( Model, Cmd Msg )
stopIfDone model =
    if not model.done && (List.length model.a >= 5 || List.length model.b >= 5 || List.length model.c >= 5) then
        ( { model | done = True }, Task.perform (\_ -> Report) (Process.sleep 100) )

    else
        ( model, Cmd.none )


sameTimes : List Int -> List Int -> List Int -> Bool
sameTimes a b c =
    List.map3 (\x y z -> x == y && y == z) (List.reverse a) (List.reverse b) (List.reverse c)
        |> List.all identity


bool : Bool -> String
bool v =
    if v then
        "True"

    else
        "False"


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        A t ->
            stopIfDone (record "A" { model | a = Time.posixToMillis t :: model.a })

        B t ->
            stopIfDone (record "B" { model | b = Time.posixToMillis t :: model.b })

        Wrap (C t) ->
            stopIfDone (record "C" { model | c = Time.posixToMillis t :: model.c })

        Report ->
            let
                _ =
                    Debug.log "dup" ("a ticked: " ++ bool (List.length model.a >= 4))

                _ =
                    Debug.log "dup" ("b ticked: " ++ bool (List.length model.b >= 4))

                _ =
                    Debug.log "dup" ("c ticked: " ++ bool (List.length model.c >= 4))

                _ =
                    Debug.log "dup" ("same time per round: " ++ bool (sameTimes model.a model.b model.c))

                _ =
                    Debug.log "dup" ("first round: " ++ String.join "," (List.take 3 model.order))
            in
            ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.done then
        Sub.none

    else
        Sub.batch
            [ Time.every 20 A
            , Time.every 20 B
            , Sub.map Wrap (Time.every 20 C)
            ]


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
