module Eco.MVar exposing
    ( MVar(..)
    , new, read, take, put, drop
    )

{-| MVar concurrency primitives via XHR: create, read, take, and put.

MVars are mutable variables that can be empty or full. Operations on empty
or full MVars block until the MVar reaches the required state.

This is the XHR-based bootstrap implementation. Unlike the kernel variant
(in eco-kernel-cpp) which is type-erased (values stay in JS memory), the
XHR variant requires explicit Bytes encoder/decoder parameters because
values must cross the HTTP boundary as raw bytes.

Kernel API: `read : MVar a -> Task Never a`
XHR API: `read : Bytes.Decode.Decoder a -> MVar a -> Task Never a`

The compiler's MVar call sites (in Utils/Main.elm) already provide
encoder/decoder at every use, so this API divergence is transparent.


# Types

@docs MVar


# Operations

@docs new, read, take, put, drop

-}

import Bytes.Decode
import Bytes.Encode
import Eco.XHR
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| An opaque mutable variable that can hold a value of type `a`.
An MVar is either empty or contains exactly one value.
-}
type MVar a
    = MVar Int


{-| Create a new empty MVar.
-}
new : Task Never (MVar a)
new =
    Eco.XHR.jsonTask "MVar.new"
        Encode.null
        Decode.int
        |> Task.map MVar


{-| Read the value from an MVar without removing it.
Blocks if the MVar is empty. Returns raw bytes decoded via the provided decoder.
-}
read : Bytes.Decode.Decoder a -> MVar a -> Task Never a
read decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.read"
        (Encode.object [ ( "id", Encode.int id ) ])
        decoder


{-| Take the value from an MVar, leaving it empty.
Blocks if the MVar is empty. Returns raw bytes decoded via the provided decoder.
-}
take : Bytes.Decode.Decoder a -> MVar a -> Task Never a
take decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.take"
        (Encode.object [ ( "id", Encode.int id ) ])
        decoder


{-| Put a value into an MVar. Blocks if the MVar is already full.
The value is encoded to raw bytes via the provided encoder.
-}
put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
put encoder (MVar id) value =
    Eco.XHR.sendBytesTask "MVar.put"
        [ Http.header "X-Eco-MVar-Id" (String.fromInt id) ]
        (Bytes.Encode.encode (encoder value))


{-| Destroy an MVar, removing it from the store entirely.
The XHR variant sends a drop request to the server.
-}
drop : MVar a -> Task Never ()
drop (MVar id) =
    Eco.XHR.jsonTask "MVar.drop"
        (Encode.object [ ( "id", Encode.int id ) ])
        (Decode.succeed ())
        |> Task.map (\_ -> ())
