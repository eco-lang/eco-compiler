module RTTrusted exposing (program)

{-| RTTrusted is an Elm program type for implementing trusted realtime nodes.

In an elm-realtime system, there can be a trusted node that is also written in Elm.

The trusted node can examine and operate on any realtime events, that pass through it.

The trusted node is responsible for generating model snapshots from event logs.

@docs program

-}

import Json.Decode exposing (Value)
import Realtime exposing (RTMessage, Snapshot)


type Error
    = Error


{-| The program type for the trusted node.
-}
program :
    -- These should be subscriptions and commands.
    { init : flags -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }
    -> Platform.Program flags model msg
program =
    Platform.worker


{-| An API for events to be processed by the realtime node.
-}
type alias RTTrustedAPI a msg =
    { compact :
        ({ session : Value
         , snapshot : Maybe (Snapshot a)
         , events : List RTMessage
         }
         -> msg
        )
        -> Sub msg
    , compacted :
        { session : Value
        , snapshot : Snapshot a
        }
        -> Cmd msg
    }



--===========
-- Snapshots
--
--initialSnapshot : RTMessage -> Maybe (Snapshot Value)
--stepSnapshot : RTMessage -> Snapshot Value -> Snapshot Value
