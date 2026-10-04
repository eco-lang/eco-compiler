module Eco.MVar exposing
    ( MVar(..)
    , new, read, take, put, drop
    )

{-| Lets a program running on stock Elm share values between tasks through
MVars, which the eco-io server that `Eco.XHR` describes holds for it.

An _MVar_ is a cell that is either empty or holds one value. `new` makes an
empty one, `put` fills it, `take` returns its value and leaves it empty, `read`
returns its value and leaves it full, and `drop` discards it. Each operation is
one eco-io request, and this module relies on eco-io for what the operations
mean: eco-io holds every MVar and its value, and it answers a `read` or `take`
of an empty MVar, or a `put` to a full one, only once the MVar has changed
state. Until eco-io answers, the task waits.

Because a value is held outside the program, it travels to eco-io and back as
bytes. That is why `put` takes an encoder and `read` and `take` take a decoder.
The decoder must read what the encoder wrote, and the types cannot check this.
The native build's twin of this module takes the same encoder and decoder and
ignores them, so callers are written against one set of signatures.

Every operation is a `Task Never`. A request that fails, in any of the ways
`Eco.XHR` describes, crashes the program through `Eco.XHR.orCrash`. A reply that
cannot be decoded, such as bytes that a decoder cannot read, also crashes the
program, inside `Eco.XHR`.

@docs MVar
@docs new, read, take, put, drop

-}

import Bytes.Decode
import Bytes.Encode
import Eco.XHR
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| An MVar holding values of type `a`, named by the id that eco-io gave it
when `new` made it.

The constructor `MVar` carries that id. It is exposed, so an `MVar` can be made
from any `Int`, for any `a`, and holding one does not mean that eco-io knows its
id.

-}
type MVar a
    = MVar Int


{-| Asks eco-io for a new, empty MVar.
-}
new : Task Never (MVar a)
new =
    Eco.XHR.jsonTask "MVar.new"
        Encode.null
        Decode.int
        |> Eco.XHR.orCrash
        |> Task.map MVar


{-| Returns the value held in the MVar, as `decoder` reads it, and leaves the
MVar full. Waits while the MVar is empty.
-}
read : Bytes.Decode.Decoder a -> MVar a -> Task Never a
read decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.read"
        (Encode.object [ ( "id", Encode.int id ) ])
        decoder
        |> Eco.XHR.orCrash


{-| Returns the value held in the MVar, as `decoder` reads it, and leaves the
MVar empty. Waits while the MVar is empty.
-}
take : Bytes.Decode.Decoder a -> MVar a -> Task Never a
take decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.take"
        (Encode.object [ ( "id", Encode.int id ) ])
        decoder
        |> Eco.XHR.orCrash


{-| Puts `value`, as `encoder` writes it, into the MVar. Waits while the MVar
is full.
-}
put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
put encoder (MVar id) value =
    Eco.XHR.sendBytesTask "MVar.put"
        [ Http.header "X-Eco-MVar-Id" (String.fromInt id) ]
        (Bytes.Encode.encode (encoder value))
        |> Eco.XHR.orCrash


{-| Asks eco-io to discard the MVar, together with any value it holds.
-}
drop : MVar a -> Task Never ()
drop (MVar id) =
    Eco.XHR.jsonTask "MVar.drop"
        (Encode.object [ ( "id", Encode.int id ) ])
        (Decode.succeed ())
        |> Eco.XHR.orCrash
        |> Task.map (\_ -> ())
