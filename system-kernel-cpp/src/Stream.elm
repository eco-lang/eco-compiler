module Stream exposing
    ( Readable, fromList, read, readString, readLine, readUntilClosed, cancelReadable
    , Writable, write, writeString, writeLine, enqueue, closeWritable, cancelWritable
    , log, logString, logLine
    , Error(..), errorToString
    , Transformation, pipeThrough, awaitAndPipeThrough, pipeTo
    )

{-| Everything in this package that moves data over time, such as standard input and output, a
file read or written in pieces, a child program's pipes, a network connection, an HTTP body or a
WebSocket message, is handed to the program as a stream. This module is what can be done with
one: read from it, write to it, end it, and connect streams together.

A stream has two sides. Values go into its _writable_ side and come out of its _readable_ side,
in the order they went in, unless a transformation changes them on the way. The program holds a
handle to a side: a [`Readable`](#Readable) to read from, or a [`Writable`](#Writable) to write
into. A stream made by [`fromList`](#fromList) or by
[`Stream.Transformation`](Stream-Transformation) lives in memory. A stream that another module
creates over a file, pipe or socket is handed out as one side only, and the resource is on the
other side.

Each side of an in-memory stream buffers a limited number of values, so a writer cannot run
arbitrarily far ahead of its reader. This is _backpressure_, and it is why there are two ways
to write. [`write`](#write) succeeds once the value has been _accepted_: taken from the
writable side's buffer and passed on to the readable side (through the transformation, if there
is one), or, for a stream over a resource, written to it. [`enqueue`](#enqueue) succeeds
as soon as the value is in the writable side's buffer. On an in-memory stream both wait while
that buffer is full.

A stream ends in one of two ways, and they are reported differently. It is _closed_ when its
writer says no more values will come ([`closeWritable`](#closeWritable)), or when the resource
behind it has no more to give: the values already written can still be read, and after the last
of them a read fails with `Closed`. It is _cancelled_ when something has gone wrong
([`cancelReadable`](#cancelReadable), [`cancelWritable`](#cancelWritable), a transformation that
fails, or a failure of the resource behind it): buffered values are dropped, except the bytes
[`readLine`](#readLine) has kept, and reads, writes and closes fail with `Cancelled` and a reason,
except reads after [`cancelReadable`](#cancelReadable), which fail as
[`cancelReadable`](#cancelReadable) describes. Once a stream has been handed out, this
is how a failure of its resource reaches the program. A connection reset, for example, is a read
that fails with `Cancelled`, not an error of the module that made the connection.

A side is _locked_ while an operation holds it, such as a read waiting for a value, a write
waiting for room in the buffer, or a pipe ([`pipeThrough`](#pipeThrough), [`pipeTo`](#pipeTo)),
which holds the readable side of its source and the writable side of its destination until it
finishes. Another operation that needs a locked side fails at once with `Locked`.

[`readLine`](#readLine) reads a byte stream a line at a time. The bytes it reads past the end
of a line are kept with the stream, and the next [`read`](#read), [`readString`](#readString),
[`readLine`](#readLine) or [`readUntilClosed`](#readUntilClosed) hands them out first, so line
reads and chunk reads can be mixed. A pipe does not hand them out: bytes kept by `readLine` are
not moved by [`pipeThrough`](#pipeThrough) or [`pipeTo`](#pipeTo). At the end of a stream they
can be lost, as [`readLine`](#readLine) describes.


# Readable Streams

@docs Readable, fromList, read, readString, readLine, readUntilClosed, cancelReadable


# Writable Streams

@docs Writable, write, writeString, writeLine, enqueue, closeWritable, cancelWritable


# Logging

The logging functions write to a byte stream and ignore any failure. They are for output where
there is nothing sensible to do when a write fails: if an error message cannot be written to
the terminal, there is usually nowhere else to report that either.

@docs log, logString, logLine


# Error Handling

@docs Error, errorToString


# Transformation Streams

@docs Transformation, pipeThrough, awaitAndPipeThrough, pipeTo

-}

import Bytes exposing (Bytes)
import Eco.Kernel.Stream
import Stream.Internal
import Task exposing (Task)



-- READABLE


{-| The readable side of a stream, from which values of type `value` are read. One is made by
[`fromList`](#fromList) or [`pipeThrough`](#pipeThrough), taken from a transformation with
[`Stream.Transformation.readable`](Stream-Transformation#readable), or handed out by another
module of this package.
-}
type alias Readable value =
    Stream.Internal.Readable value


{-| Creates an in-memory [`Readable`](#Readable) stream that delivers the values in the given
`List`, in order, and is then closed.

The stream's buffer is made large enough for the whole list, so the `Task` does not wait for a
reader.

-}
fromList : List a -> Task Error (Readable a)
fromList values =
    kIdentity (max 1 (List.length values)) 1
        |> Task.mapError never
        |> Task.andThen
            (\id ->
                List.foldl
                    (\value stream -> Task.andThen (enqueue value) stream)
                    (Task.succeed (Stream.Internal.Writable id))
                    values
                    |> Task.andThen closeWritable
                    |> Task.map (\_ -> Stream.Internal.Readable id)
            )


{-| Reads the next value off the stream, waiting until there is one.

Once the stream has been closed and every value written before the close has been read, or
once the reading side has been cancelled while the stream had not failed in another way, the
`Task` fails with `Closed`. If the stream has
been cancelled from its writing side or by its transformation, or its resource has failed, it
fails with `Cancelled` and the reason. While another read is waiting on the stream, or something
else such as a pipe is consuming it, it fails with `Locked`.

-}
read : Readable value -> Task Error value
read (Stream.Internal.Readable id) =
    kRead id
        |> Task.mapError decodeError


{-| Reads the next chunk of `Bytes` off the stream, as [`read`](#read) does, and converts it to
a `String`. If the chunk is not valid UTF-8, the stream is cancelled and the `Task` fails with
`Cancelled`; if by then another operation holds the reading side, the `Task` fails with `Locked`
instead and the stream is not cancelled.

Each chunk is converted on its own, so a multi-byte character split across two chunks does not
convert. [`readLine`](#readLine) assembles lines across chunks, and
[`Stream.Transformation.textDecoder`](Stream-Transformation#textDecoder) decodes a whole byte
stream however it is split.

-}
readString : Readable Bytes -> Task Error String
readString stream =
    read stream
        |> Task.andThen
            (\bytes ->
                case kUtf8ToString bytes of
                    Just str ->
                        Task.succeed str

                    Nothing ->
                        let
                            reason =
                                "Failed to convert bytes to string"
                        in
                        cancelReadable reason stream
                            |> Task.andThen (\_ -> Task.fail (Cancelled reason))
            )


{-| Reads the next line off a byte stream: everything up to the next newline (`\n`), decoded as
UTF-8, without the newline and without a carriage return (`\r`) just before it.

    countLines : Readable Bytes -> Int -> Task Error Int
    countLines stdin n =
        Stream.readLine stdin
            |> Task.andThen (\_ -> countLines stdin (n + 1))
            |> Task.onError
                (\err ->
                    case err of
                        Stream.Closed ->
                            Task.succeed n

                        _ ->
                            Task.fail err
                )

A line may be longer than the chunks the stream delivers. On the standard input stream, once it
has been closed, a last line without a newline is returned as it is, and after that the `Task`
fails with `Closed`. On other streams this is not guaranteed: when such a stream ends, the bytes
`readLine` has kept can be lost, including whole lines of the last chunk of an in-memory stream.
Bytes read past the newline are kept with the stream and handed out first by the next read, so
`readLine` can be mixed with [`read`](#read) and [`readString`](#readString). If a line is not
valid UTF-8, the stream is cancelled and the `Task` fails with `Cancelled`, or with `Locked` if by
then another operation holds the reading side. A cancel does not drop the kept bytes: after
one, the next `read` still hands them out before it fails, and `readLine` still returns any
complete lines among them. Other failures are those of [`read`](#read).

-}
readLine : Readable Bytes -> Task Error String
readLine ((Stream.Internal.Readable id) as stream) =
    kCarryLine False id
        |> Task.mapError never
        |> Task.andThen
            (\carried ->
                case carried of
                    Just line ->
                        decodeLine stream line

                    Nothing ->
                        kReadChunk id
                            |> Task.mapError decodeError
                            |> Task.andThen
                                (\chunk ->
                                    kCarryAppend chunk id
                                        |> Task.mapError never
                                        |> Task.andThen (\_ -> readLine stream)
                                )
                            |> Task.onError (readLineAtEnd stream)
            )


{-| Handles a failed chunk read in [`readLine`](#readLine). When the failure is `Closed`, returns
the kept bytes as the last line if there are any, and fails with `Closed` if there are none; any
other failure is passed on.
-}
readLineAtEnd : Readable Bytes -> Error -> Task Error String
readLineAtEnd ((Stream.Internal.Readable id) as stream) err =
    case err of
        Closed ->
            kCarryLine True id
                |> Task.mapError never
                |> Task.andThen
                    (\carried ->
                        case carried of
                            Just line ->
                                decodeLine stream line

                            Nothing ->
                                Task.fail Closed
                    )

        _ ->
            Task.fail err


{-| Decodes the bytes of one line as UTF-8. If they are not valid UTF-8, cancels `stream` and
fails with `Cancelled`, or fails with `Locked`, cancelling nothing, if another operation holds
the reading side.
-}
decodeLine : Readable Bytes -> Bytes -> Task Error String
decodeLine stream line =
    case kUtf8ToString line of
        Just str ->
            Task.succeed str

        Nothing ->
            let
                reason =
                    "Failed to convert bytes to string"
            in
            cancelReadable reason stream
                |> Task.andThen (\_ -> Task.fail (Cancelled reason))


{-| Reads every value off the stream, folding each into an accumulated value with `stepFn`,
starting from `initial`, and succeeds with the result once a read fails with `Closed`.

If `stepFn` returns an `Err`, its `String` is used as the reason to cancel the stream, and the
`Task` fails with `Cancelled` and that reason; if by then another operation holds the reading
side, the `Task` fails with `Locked` instead and the stream is not cancelled. Any other failure of
a read fails the `Task`.

-}
readUntilClosed : (a -> b -> Result String b) -> b -> Readable a -> Task Error b
readUntilClosed stepFn initial stream =
    readUntilClosedHelper stepFn initial stream


{-| Does the work of [`readUntilClosed`](#readUntilClosed), with `oldAcc` the value accumulated
so far.
-}
readUntilClosedHelper : (a -> b -> Result String b) -> b -> Readable a -> Task Error b
readUntilClosedHelper stepFn oldAcc stream =
    read stream
        |> Task.andThen
            (\newPart ->
                case stepFn newPart oldAcc of
                    Ok newAcc ->
                        readUntilClosedHelper stepFn newAcc stream

                    Err reason ->
                        cancelReadable reason stream
                            |> Task.andThen (\_ -> Task.fail (Cancelled reason))
            )
        |> Task.onError
            (\err ->
                case err of
                    Closed ->
                        Task.succeed oldAcc

                    _ ->
                        Task.fail err
            )


{-| Cancels the stream from its reading side, because the reader will not take any more values.
The `String` is the reason, a human-readable explanation of what went wrong. Values in the
stream's buffer are dropped, except the bytes [`readLine`](#readLine) has kept, and a stream over
a resource stops reading from it.

Once any kept bytes have been handed out, later reads fail with `Closed`, unless the stream had
already been cancelled in another way (from its writing side, by its transformation, or by a
failure of its resource), in which case they go on failing with `Cancelled` and that earlier
reason. If the writing side is still open, or a close of it is still in progress, writes into it
that are still waiting, that close, and later writes fail with `Cancelled` and the given reason.
While a read is waiting on the stream, or something else such as a pipe is consuming it, the
`Task` fails with `Locked` and nothing is cancelled.

-}
cancelReadable : String -> Readable value -> Task Error ()
cancelReadable reason (Stream.Internal.Readable id) =
    kCancelReadable reason id
        |> Task.mapError decodeError



-- WRITABLE


{-| The writable side of a stream, into which values of type `value` are written. One is taken
from a transformation with [`Stream.Transformation.writable`](Stream-Transformation#writable), or
handed out by another module of this package.
-}
type alias Writable value =
    Stream.Internal.Writable value


{-| Writes a value into the stream, and succeeds once the value has been accepted: passed on
to the stream's readable side (through the transformation, if there is one), or, for a stream
over a resource, written to it. On an in-memory stream with no room for the value, this waits
until a reader makes room.

Writing into a stream that has been closed or cancelled fails with `Cancelled`. While another
write is waiting for room, or a pipe is writing into the stream, it fails with `Locked`.

-}
write : value -> Writable value -> Task Error (Writable value)
write value ((Stream.Internal.Writable id) as stream) =
    kWrite value id
        |> Task.mapError decodeError
        |> Task.map (\_ -> stream)


{-| Converts the `String` to UTF-8 `Bytes` and writes them into the stream, as
[`write`](#write) does.

A lone surrogate (half of a UTF-16 pair with no partner) is converted differently by the two
backends: the JavaScript backend writes U+FFFD in its place, and the native backend writes the
surrogate's own three bytes, which are not valid UTF-8 and which [`readString`](#readString)
rejects.

-}
writeString : String -> Writable Bytes -> Task Error (Writable Bytes)
writeString str stream =
    write (kStringToUtf8 str) stream


{-| Appends a newline (`\n`) to the `String`, converts it to UTF-8 `Bytes` and writes them into
the stream, as [`write`](#write) does. A lone surrogate is converted as
[`writeString`](#writeString) describes.
-}
writeLine : String -> Writable Bytes -> Task Error (Writable Bytes)
writeLine str stream =
    write (kStringToUtf8 (str ++ "\n")) stream


{-| Queues a value to be written into the stream, and succeeds once it is in the writable side's
buffer, or, for a stream over a resource, once the write has been started.

The difference from [`write`](#write) is when the `Task` succeeds. It does not wait for a reader
to take the value, so it succeeds even if nothing is reading, as long as the buffer has room (on
an in-memory stream with a full buffer it waits for room). The price is that it cannot report
what happens to the value afterwards: if the stream is cancelled, or the write to the resource
fails, before the value is accepted, this `Task` has already succeeded.

Enqueueing into a stream that has been closed or cancelled fails with `Cancelled`, and it fails
with `Locked` in the same cases as [`write`](#write).

-}
enqueue : value -> Writable value -> Task Error (Writable value)
enqueue value ((Stream.Internal.Writable id) as stream) =
    kEnqueue value id
        |> Task.mapError decodeError
        |> Task.map (\_ -> stream)


{-| Closes the stream: no more values will be written into it. The `Task` succeeds once every
value written before the close has been accepted, and, for a stream over a resource, once the
resource has been closed (the standard streams are never closed; the close only waits for their
writes). Readers can still read the values in the buffer, and then get `Closed`.

Closing a stream that is already closed or being closed, or has been cancelled, fails with
`Cancelled`. While a write is waiting for room, or a pipe is writing into the stream, it fails
with `Locked`. If the stream is cancelled while the close waits, the `Task` fails with
`Cancelled` and the reason.

-}
closeWritable : Writable value -> Task Error ()
closeWritable (Stream.Internal.Writable id) =
    kCloseWritable id
        |> Task.mapError decodeError


{-| Cancels the stream from its writing side, because something has gone wrong. The `String` is
the reason, a human-readable explanation of what. Values in the stream's buffers are dropped,
except the bytes [`readLine`](#readLine) has kept.

On an in-memory stream, writes still in the buffer and a close still in progress fail with
`Cancelled` and the given reason, and so do reads from the readable side, including one already
waiting, once any kept bytes have been handed out. A stream over a resource stops writing to it.
Cancelling a stream that is already closed or cancelled does nothing. While a write is waiting
for room, or a pipe is writing into the stream, the `Task` fails with `Locked` and nothing is
cancelled.

-}
cancelWritable : String -> Writable value -> Task Error ()
cancelWritable reason (Stream.Internal.Writable id) =
    kCancelWritable reason id
        |> Task.mapError decodeError



-- LOGGING


{-| Writes `Bytes` into a byte stream as [`write`](#write) does, and succeeds once the write has
succeeded or failed, ignoring any failure.
-}
log : Bytes -> Writable Bytes -> Task x ()
log data stream =
    write data stream
        |> ignoreErrors


{-| Writes a `String` into a byte stream as [`writeString`](#writeString) does, ignoring any
failure.
-}
logString : String -> Writable Bytes -> Task x ()
logString data stream =
    writeString data stream
        |> ignoreErrors


{-| Writes a `String` followed by a newline into a byte stream as [`writeLine`](#writeLine)
does, ignoring any failure.

    Stream.logLine "Hello, world!" env.stdout

-}
logLine : String -> Writable Bytes -> Task x ()
logLine data stream =
    writeLine data stream
        |> ignoreErrors


{-| Turns a stream task into one that succeeds with `()` whether `task` succeeds or fails.
-}
ignoreErrors : Task Error a -> Task x ()
ignoreErrors task =
    task
        |> Task.map (\_ -> ())
        |> Task.onError (\_ -> Task.succeed ())



-- ERROR


{-| Why an operation on a stream failed.

`Closed` is the answer to a read when the stream has ended normally: it was closed, and every
value written before the close has been read. A read also gets `Closed` after the stream was
cancelled from its reading side with [`cancelReadable`](#cancelReadable), unless it had already
been cancelled in another way. Only reads fail with `Closed`; writing into a closed stream fails
with `Cancelled`.

`Cancelled` carries the reason, a human-readable explanation. A read gets it when the stream was
cancelled from its writing side or by its transformation, or its resource failed; a write or a
close gets it when the stream has been closed or cancelled, and [`pipeTo`](#pipeTo) gets it as
[`pipeTo`](#pipeTo) describes. When the resource behind a stream fails, the reason names the
problem, such as `"read ECONNRESET"` for a connection the peer reset.

`Locked` means that the side of the stream the operation needs is held by another operation,
such as a waiting read, a write waiting for room, or a pipe. A single read, write, close, cancel
or pipe that fails with `Locked` has done nothing and can be tried again once the other has
finished; a function that reads and then cancels or reads again, such as
[`readString`](#readString), [`readLine`](#readLine) or [`readUntilClosed`](#readUntilClosed), may
already have consumed values.

-}
type Error
    = Closed
    | Cancelled String
    | Locked


{-| Returns a human-readable description of an error: `"Closed"`, `"Locked"`, or
`"Cancelled: "` followed by the reason.
-}
errorToString : Error -> String
errorToString error =
    case error of
        Closed ->
            "Closed"

        Cancelled reason ->
            "Cancelled: " ++ reason

        Locked ->
            "Locked"


{-| Converts a stream kernel failure, `( kind, reason )`, into an `Error`. Kind 0 is `Closed`
and 2 is `Locked`; the kernels send 1 for a cancellation, and every kind other than 0 and 2
becomes `Cancelled` with the reason.
-}
decodeError : ( Int, String ) -> Error
decodeError ( kind, reason ) =
    case kind of
        0 ->
            Closed

        2 ->
            Locked

        _ ->
            Cancelled reason



-- TRANSFORMATION


{-| An in-memory stream whose two sides are both in the program's hands, and which may change
the values on their way through: it can alter them, drop them, or produce several from one.

A `Transformation input output` accepts `input` values on its
[`writable`](Stream-Transformation#writable) side and produces `output` values on its
[`readable`](Stream-Transformation#readable) side;
[`textEncoder`](Stream-Transformation#textEncoder), for example, makes a
`Transformation String Bytes`.

Transformations are created with the functions in
[`Stream.Transformation`](Stream-Transformation), and used with [`pipeThrough`](#pipeThrough).

-}
type alias Transformation input output =
    Stream.Internal.Transformation input output


{-| Starts moving every value of the `Readable` into the writable side of the
[`Transformation`](#Transformation), and succeeds at once with the transformation's readable
side.

The pipe locks the source and the transformation's writable side until it finishes. When the
source has closed and every value has been moved, the transformation's writable side is closed.
If the source is cancelled from its writing side, or its resource fails, the transformation is
cancelled with the same reason, so reads from the result fail with `Cancelled`. If the
transformation's writable side is cancelled, for example by cancelling the result, the source
is cancelled with the same reason. These later failures are not reported by this `Task`, which
has already succeeded.

If the source or the transformation's writable side is already locked, the `Task` fails with
`Locked`.

-}
pipeThrough : Transformation input output -> Readable input -> Task Error (Readable output)
pipeThrough (Stream.Internal.Transformation id) (Stream.Internal.Readable source) =
    kPipeThrough id source
        |> Task.mapError decodeError
        |> Task.map (\_ -> Stream.Internal.Readable id)


{-| Waits for the `Task` that builds a [`Transformation`](#Transformation), such as
[`Stream.Transformation.gunzip`](Stream-Transformation#gunzip), then pipes the `Readable` through
it as [`pipeThrough`](#pipeThrough) does. A failure of the building `Task` fails this one.
-}
awaitAndPipeThrough : Task Error (Transformation input output) -> Readable input -> Task Error (Readable output)
awaitAndPipeThrough builder source =
    Task.andThen (\transformation -> pipeThrough transformation source) builder


{-| Moves every value of the `Readable` into the `Writable`, locking both until it finishes.

When the readable side has closed and every value has been moved, the writable side is closed,
and the `Task` succeeds once that close has finished. If the readable side is cancelled from its
writing side, or its resource fails, the writable side is cancelled with the same reason. If the
writable side is cancelled (by its reader, by its transformation, or by a failure of its
resource), or it is already closed or being closed when the pipe starts, the readable side is
cancelled with that reason (`"WritableStream is closed"` for a closed one). Either way the `Task`
fails with `Cancelled` and the reason.

If either side is already locked, the `Task` fails with `Locked`.

-}
pipeTo : Writable data -> Readable data -> Task Error ()
pipeTo (Stream.Internal.Writable destination) (Stream.Internal.Readable source) =
    kPipeTo destination source
        |> Task.mapError decodeError



-- KERNELS
-- The annotations fix the kernel ABI: both kernels rely on exactly these argument and result
-- shapes. A failure is `( kind, reason )`, as `decodeError` reads it.


{-| Creates an in-memory stream whose readable side buffers up to `readCap` values and whose
writable side buffers up to `writeCap`, each at least 1, and returns its id. The arguments are
`readCap` then `writeCap`.
-}
kIdentity : Int -> Int -> Task Never Int
kIdentity =
    Eco.Kernel.Stream.identity


{-| Starts the pipe of `pipeThrough`, from the readable of the second id into the writable of the
first.
-}
kPipeThrough : Int -> Int -> Task ( Int, String ) ()
kPipeThrough =
    Eco.Kernel.Stream.pipeThrough


{-| Runs the pipe of `pipeTo`, from the readable of the second id into the writable of the first,
and succeeds when it has finished.
-}
kPipeTo : Int -> Int -> Task ( Int, String ) ()
kPipeTo =
    Eco.Kernel.Stream.pipeTo


{-| Reads the next value, handing out the bytes `readLine` has kept first, if there are any.
-}
kRead : Int -> Task ( Int, String ) a
kRead =
    Eco.Kernel.Stream.read


{-| Reads the next chunk as `kRead` does, but leaves the bytes `readLine` has kept where they
are.
-}
kReadChunk : Int -> Task ( Int, String ) Bytes
kReadChunk =
    Eco.Kernel.Stream.readChunk


{-| Takes the next line out of the bytes `readLine` has kept for the stream, without its line
ending, or gives `Nothing` if they hold no complete line. With `True` (the stream has ended), a
last line without a newline is taken too, and `Nothing` means nothing is kept.
-}
kCarryLine : Bool -> Int -> Task Never (Maybe Bytes)
kCarryLine =
    Eco.Kernel.Stream.carryLine


{-| Adds a chunk to the end of the bytes `readLine` keeps for the stream. The bytes are dropped
if the stream no longer exists.
-}
kCarryAppend : Bytes -> Int -> Task Never ()
kCarryAppend =
    Eco.Kernel.Stream.carryAppend


{-| Writes a value, succeeding once it has been accepted.
-}
kWrite : a -> Int -> Task ( Int, String ) ()
kWrite =
    Eco.Kernel.Stream.write


{-| Queues a value, succeeding as [`enqueue`](#enqueue) describes.
-}
kEnqueue : a -> Int -> Task ( Int, String ) ()
kEnqueue =
    Eco.Kernel.Stream.enqueue


{-| Closes the writable side, succeeding as [`closeWritable`](#closeWritable) describes.
-}
kCloseWritable : Int -> Task ( Int, String ) ()
kCloseWritable =
    Eco.Kernel.Stream.closeWritable


{-| Cancels the stream from its reading side with the given reason.
-}
kCancelReadable : String -> Int -> Task ( Int, String ) ()
kCancelReadable =
    Eco.Kernel.Stream.cancelReadable


{-| Cancels the stream from its writing side with the given reason.
-}
kCancelWritable : String -> Int -> Task ( Int, String ) ()
kCancelWritable =
    Eco.Kernel.Stream.cancelWritable


{-| Decodes `Bytes` as UTF-8, giving `Nothing` unless they are well-formed UTF-8 throughout.
-}
kUtf8ToString : Bytes -> Maybe String
kUtf8ToString =
    Eco.Kernel.Stream.utf8ToString


{-| Encodes a `String` as UTF-8 `Bytes`. A lone surrogate becomes U+FFFD on the JavaScript
backend and its own three bytes, which are not valid UTF-8, on the native backend.
-}
kStringToUtf8 : String -> Bytes
kStringToUtf8 =
    Eco.Kernel.Stream.stringToUtf8
