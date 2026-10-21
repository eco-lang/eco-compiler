module Stream.Internal exposing
    ( Readable(..), Transformation(..), Writable(..)
    , Failure(..), Reason(..), decodeReason, encodeFailure, failure
    )

{-| The stream handle types, defined here so that every module of this package can build
and unwrap them, while users see them only through the aliases `Stream` exposes, which
hide the constructors. Internal; not exposed.

A stream in this package lives in the kernel, not in Elm. The kernel keeps a stream table
whose entries are _stream pairs_: a pair has a writable side, into which values go, and a
readable side, from which values come out, though some kinds of stream use only one of
them. Elm holds only the pair's _stream-table id_, an integer it passes to kernel
functions.

One id names both sides of its pair. Which side a handle means follows from its type and
the kernel function it is given, so rewrapping an id as another of these types moves
between the sides of one pair: `Stream.fromList` writes into a `Writable` and hands back
the same id as a `Readable`, and a `Transformation`'s readable and writable are its own id
wrapped as a `Readable` and a `Writable`. Nothing in the types says whether a particular
`Readable` and `Writable` belong to one pair or to two.

The type parameters are phantom: a handle holds only the id. Nothing checks that the values
on a stream are of the type a handle names; that is up to the code that wraps the id.

-}


{-| The readable side of a stream pair, from which values of type `value` are read.
-}
type Readable value
    = Readable Int


{-| The writable side of a stream pair, into which values of type `value` are written.
-}
type Writable value
    = Writable Int


{-| A stream pair whose writable side takes `input` values and whose readable side gives
`output` values, held as the pair rather than as one of its sides.
-}
type Transformation input output
    = Transformation Int


{-| The failure of the resource behind a stream, as `Stream.Failed` carries it.

`origin` names the kind of resource that failed, and so which module can read the failure back
as its own error: `"socket"` (`Socket.fromStreamFailure`), `"tls"` (`Socket.Tls`), `"file"`
(`FileSystem`), `"websocket"` (`WebSocket`) and `"http"` (`Http.Stream`); `"pipe"`, `"stdio"`
and `"codec"` have no module of their own. `code` is the resource's code for the failure, such as
an errno name (`"ECONNRESET"`), and `message` is the text `Stream.failureToString` gives.

-}
type Failure
    = Failure { origin : String, code : String, message : String }


{-| Makes a failure from its origin, code and message.
-}
failure : String -> String -> String -> Failure
failure origin code message =
    Failure { origin = origin, code = code, message = message }


{-| What a cancellation reason from a kernel means. The kernels mark the reasons they make
themselves, so that a program's own reason, which they pass on as it is, is never mistaken for
one of theirs.
-}
type Reason
    = FailureReason Failure
    | EndedReason
    | ProgramReason String


{-| Reads a reason as the kernels write it. A reason starting with U+0001 is a resource failure,
`origin`, `code` and `message` separated by U+001F; one starting with U+0002 means the stream
had ended (it is `Stream.Closed` for a write or a close); anything else is a reason a program
gave.
-}
decodeReason : String -> Reason
decodeReason reason =
    if String.startsWith "\u{0001}" reason then
        case String.split "\u{001F}" (String.dropLeft 1 reason) of
            origin :: code :: rest ->
                FailureReason (failure origin code (String.join "\u{001F}" rest))

            _ ->
                FailureReason (failure "" "" (String.dropLeft 1 reason))

    else if String.startsWith "\u{0002}" reason then
        EndedReason

    else
        ProgramReason reason


{-| Writes a failure as a kernel reason, the inverse of `decodeReason` for a failure. Elm code
that fails a stream on behalf of a resource uses it.
-}
encodeFailure : Failure -> String
encodeFailure (Failure f) =
    "\u{0001}" ++ f.origin ++ "\u{001F}" ++ f.code ++ "\u{001F}" ++ f.message

