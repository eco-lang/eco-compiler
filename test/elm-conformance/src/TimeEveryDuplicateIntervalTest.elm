module TimeEveryDuplicateIntervalTest exposing (main)

{-| Several `Time.every` subscriptions with the same interval and different messages all tick, and
each round gives every one of them the same time, in subscription order.

Three subscriptions share 20 ms: `A`, `B`, and `C` wrapped by `Sub.map Wrap`. Once any of them
has ticked five times the program drops its subscriptions and reports 100 ms later. It checks
that each one ticked at least four times, that the times line up round by round, and that the
first round arrived as A, B, C.

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


{-| Marks the model done and asks for a `Report` 100 ms later, the first time any subscription has
five ticks.
-}
stopIfDone : Model -> ( Model, Cmd Msg )
stopIfDone model =
    if not model.done && (List.length model.a >= 5 || List.length model.b >= 5 || List.length model.c >= 5) then
        ( { model | done = True }, Task.perform (\_ -> Report) (Process.sleep 100) )

    else
        ( model, Cmd.none )


{-| Returns whether the three lists of tick times agree round by round, oldest first, as far as
the shortest list goes.
-}
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
