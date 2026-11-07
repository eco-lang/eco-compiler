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

The built compiler (`guida.js`) does not encode values either:
`scripts/replacements.js` replaces `stash` and the two `unstashing` functions
below, so that `put` sends eco-io a 12-byte token for the value, which stays a
JavaScript object in `bin/eco-io-handler.js`, and `read` and `take` return that
object. Unpatched, as in this source, they encode and decode.

`read`, `take` and `put` fail with an `IOError` when their request fails, in
any of the ways `Eco.XHR` describes, as it does for an MVar that was dropped:
the native kernel module fails them in that case too. `new` and `drop` cannot
fail, so their error type is free; a request of theirs that fails crashes the
program through `Eco.XHR.orCrash`. A reply that cannot be decoded, such as
bytes that a decoder cannot read, crashes the program, inside `Eco.XHR`.

@docs MVar
@docs new, read, take, put, drop

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Eco.IO.Error as IOErr exposing (IOError)
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
new : Task x (MVar a)
new =
    Eco.XHR.jsonTask "MVar.new"
        Encode.null
        Decode.int
        |> Eco.XHR.orCrash
        |> Task.mapError never
        |> Task.map MVar


{-| Returns the value held in the MVar, as `decoder` reads it, and leaves the
MVar full. Waits while the MVar is empty.
-}
read : Bytes.Decode.Decoder a -> MVar a -> Task IOError a
read decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.read"
        (Encode.object [ ( "id", Encode.int id ) ])
        (unstashing decoder)
        |> Task.mapError IOErr.ofKernelTuple


{-| Returns the value held in the MVar, as `decoder` reads it, and leaves the
MVar empty. Waits while the MVar is empty.
-}
take : Bytes.Decode.Decoder a -> MVar a -> Task IOError a
take decoder (MVar id) =
    Eco.XHR.bytesTask "MVar.take"
        (Encode.object [ ( "id", Encode.int id ) ])
        (unstashingTaken decoder)
        |> Task.mapError IOErr.ofKernelTuple


{-| Puts `value`, as `encoder` writes it, into the MVar. Waits while the MVar
is full.
-}
put : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task IOError ()
put encoder (MVar id) value =
    Eco.XHR.sendBytesTask "MVar.put"
        [ Http.header "X-Eco-MVar-Id" (String.fromInt id) ]
        (stash encoder value)
        |> Task.mapError IOErr.ofKernelTuple


{-| Asks eco-io to discard the MVar, together with any value it holds.

A task still waiting on it (a `read` or `take` of it while empty, or a `put`
to it while full) can then never be answered with a value: the eco-io handler
in `bin/eco-io-handler.js` fails those requests, and the tasks fail. So does
any later request naming a dropped MVar.

-}
drop : MVar a -> Task x ()
drop (MVar id) =
    Eco.XHR.jsonTask "MVar.drop"
        (Encode.object [ ( "id", Encode.int id ) ])
        (Decode.succeed ())
        |> Eco.XHR.orCrash
        |> Task.mapError never
        |> Task.map (\_ -> ())



-- ====== STASH ======
-- scripts/replacements.js replaces these three definitions in guida.js by name, and fails the
-- build when it cannot find one; keep each a top-level function of this exact name and arity.


{-| Returns the bytes that `put` sends for `value`: `value` as `encoder` writes it. In
`guida.js`, a token for `value`, which eco-io-handler.js keeps as it is.
-}
stash : (a -> Bytes.Encode.Encoder) -> a -> Bytes
stash encoder value =
    Bytes.Encode.encode (encoder value)


{-| The decoder `read` uses: `decoder`. In `guida.js`, it returns the value a token stands for
and leaves the value stashed, and reads anything else with `decoder`.
-}
unstashing : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder a
unstashing decoder =
    decoder


{-| The decoder `take` uses: `decoder`. In `guida.js`, it returns the value a token stands for
and releases it, as the MVar no longer holds it, and reads anything else with `decoder`.
-}
unstashingTaken : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder a
unstashingTaken decoder =
    decoder
