port module ValuesService exposing (main)

{-| The program `embed_host.js` drives in its `values` scenarios, built both for the JS backend and
as a Node addon (run-node-addon-tests.sh), so that the two can be compared. It is a fixture, not an
E2E test: it never ends on its own.

At start it sends its flags, a record of every kind of flags field, straight back out on `flagsOut`.
After that, for each JSON port payload type `T` it has a pair of ports, `tIn` and `tOut`, and sends
every value that arrives on `tIn` back out on `tOut`.

-}

import Array exposing (Array)
import Json.Encode as Encode
import Platform


type alias Flags =
    { name : String
    , count : Int
    , ratio : Float
    , on : Bool
    , some : Maybe Int
    , none : Maybe Int
    , ints : List Int
    , strings : Array String
    , pair : ( Int, String )
    , nested : { inner : { deep : List ( Bool, Float ) } }
    , json : Encode.Value
    , unit : ()
    }


type alias Record =
    { id : Int
    , tags : List String
    , child : { ok : Bool }
    }


port flagsOut : Flags -> Cmd msg


port stringIn : (String -> msg) -> Sub msg


port stringOut : String -> Cmd msg


port intIn : (Int -> msg) -> Sub msg


port intOut : Int -> Cmd msg


port floatIn : (Float -> msg) -> Sub msg


port floatOut : Float -> Cmd msg


port boolIn : (Bool -> msg) -> Sub msg


port boolOut : Bool -> Cmd msg


port unitIn : (() -> msg) -> Sub msg


port unitOut : () -> Cmd msg


port maybeIn : (Maybe Int -> msg) -> Sub msg


port maybeOut : Maybe Int -> Cmd msg


port listIn : (List Int -> msg) -> Sub msg


port listOut : List Int -> Cmd msg


port arrayIn : (Array String -> msg) -> Sub msg


port arrayOut : Array String -> Cmd msg


port tuple2In : (( Int, String ) -> msg) -> Sub msg


port tuple2Out : ( Int, String ) -> Cmd msg


port tuple3In : (( Bool, Float, String ) -> msg) -> Sub msg


port tuple3Out : ( Bool, Float, String ) -> Cmd msg


port recordIn : (Record -> msg) -> Sub msg


port recordOut : Record -> Cmd msg


port jsonIn : (Encode.Value -> msg) -> Sub msg


port jsonOut : Encode.Value -> Cmd msg


{-| Each message carries the command that sends its value back out.
-}
type Msg
    = Echo (Cmd Msg)


update : Msg -> () -> ( (), Cmd Msg )
update (Echo cmd) model =
    ( model, cmd )


subscriptions : () -> Sub Msg
subscriptions _ =
    Sub.batch
        [ stringIn (Echo << stringOut)
        , intIn (Echo << intOut)
        , floatIn (Echo << floatOut)
        , boolIn (Echo << boolOut)
        , unitIn (Echo << unitOut)
        , maybeIn (Echo << maybeOut)
        , listIn (Echo << listOut)
        , arrayIn (Echo << arrayOut)
        , tuple2In (Echo << tuple2Out)
        , tuple3In (Echo << tuple3Out)
        , recordIn (Echo << recordOut)
        , jsonIn (Echo << jsonOut)
        ]


main : Program Flags () Msg
main =
    Platform.worker
        { init = \flags -> ( (), flagsOut flags )
        , update = update
        , subscriptions = subscriptions
        }
