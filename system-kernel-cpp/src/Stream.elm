module Stream exposing
    ( Readable, fromList, read, readBytesAsString, readUntilClosed, cancelReadable
    , Writable, write, writeStringAsBytes, writeLineAsBytes, enqueue, closeWritable, cancelWritable
    , Error(..), errorToString
    , Transformation, identityTransformation, identityTransformationWithOptions, nullTransformation, CustomTransformationAction(..), customTransformation, customTransformationWithOptions, readable, writable, pipeThrough, awaitAndPipeThrough, pipeTo
    , textEncoder, textDecoder, gzipCompression, deflateCompression, deflateRawCompression, gzipDecompression, deflateDecompression, deflateRawDecompression
    )

{-| When moving a lot of data out of and into memory, it's rare for the entire chunk of data to
be moved in a single piece. When reading data from a file on disk, or when retrieving data from a
remote web service, it's common to retrieve one chunk of data at a time and then reassemble those
chunks when we have all the pieces. In most cases, this process is handled for you automatically.

However, it can be useful to operate on these chunks as they come in. If you're reading a
compressed file from disk, decompressing the chunks as they come in allows you to utilize the
pause between receiving them, increasing the perceived performance of the operation. It also
allows you to save memory by not having to store the entire compressed file in memory before
beginning the decompression process.

Streams are the abstraction that allows us to work on data that is in transit. They can also
serve as a tool for communication between different parts of your code base.

We have three kinds of streams: readable streams, writable streams, and transformation streams.

This module is a port of the `Stream` module of gren-lang/core 7.5.0. The deliberate differences
are: `fromArray` is called [`fromList`](#fromList); [`enqueue`](#enqueue) on a closed stream fails
with `Cancelled` instead of producing an unhandled rejection; and
[`customTransformationWithOptions`](#customTransformationWithOptions) never uses a write capacity
below 1.


# Readable Streams

@docs Readable, fromList, read, readBytesAsString, readUntilClosed, cancelReadable


# Writable Streams

@docs Writable, write, writeStringAsBytes, writeLineAsBytes, enqueue, closeWritable, cancelWritable


# Error Handling

@docs Error, errorToString


# Transformation Streams

@docs Transformation, identityTransformation, identityTransformationWithOptions, nullTransformation, CustomTransformationAction, customTransformation, customTransformationWithOptions, readable, writable, pipeThrough, awaitAndPipeThrough, pipeTo


# Useful Transformation Streams

@docs textEncoder, textDecoder, gzipCompression, deflateCompression, deflateRawCompression, gzipDecompression, deflateDecompression, deflateRawDecompression

-}

import Bytes exposing (Bytes)
import Stream.Internal
import Task exposing (Task)



-- READABLE


{-| A source of data. You can only read data out of a `Readable` stream, not write data into it.
-}
type alias Readable value =
    Stream.Internal.Readable value


{-| Create a [`Readable`](#Readable) stream that delivers the values in the provided `List`, in
order, before closing.

This was called `fromArray` in gren.

-}
fromList : List a -> Task Error (Readable a)
fromList values =
    Debug.todo "Implement System API"


{-| Read a value off the stream. The `Task` will not succeed until a value can be read.

Once the stream has been closed and every buffered value has been read, the `Task` fails with
`Closed`. If the stream has been cancelled, it fails with `Cancelled` and the cancellation reason.
Only one read can wait on a stream at a time; a second concurrent read fails with `Locked`.

-}
read : Readable value -> Task Error value
read stream =
    Debug.todo "Implement System API"


{-| Read `Bytes` off the stream and attempt to convert them into a `String`. The bytes must be
valid UTF-8. If the conversion fails, the stream is cancelled and the `Task` fails with
`Cancelled`.

Each call reads a single chunk. A multi-byte character split across two chunks will not convert;
use [`textDecoder`](#textDecoder) when reading text from a byte stream in pieces.

-}
readBytesAsString : Readable Bytes -> Task Error String
readBytesAsString stream =
    Debug.todo "Implement System API"


{-| Read values off the stream, incrementally building a value with the provided function, until
the stream is closed or some error occurs. When the stream closes, the accumulated value is the
result of the `Task`.

If the provided function returns an `Err`, the attached `String` is used as the cancellation
reason for the stream, and the `Task` fails with `Cancelled`.

-}
readUntilClosed : (a -> b -> Result String b) -> b -> Readable a -> Task Error b
readUntilClosed stepFn initial stream =
    Debug.todo "Implement System API"


{-| Cancel the stream. This indicates a fatal error, and the given `String` should explain in a
human-readable way what that error is. If the stream contains a buffer, the buffer is dropped.

It will not be possible to read another value out of this stream: later reads fail with `Closed`.
Writes into the other end of the stream fail with `Cancelled` and the given reason.

-}
cancelReadable : String -> Readable value -> Task Error ()
cancelReadable reason stream =
    Debug.todo "Implement System API"



-- WRITABLE


{-| A destination for data. You can only write data into a `Writable` stream, not read data out
of it.
-}
type alias Writable value =
    Stream.Internal.Writable value


{-| Write a value into the stream. The returned `Task` only succeeds when the written value has
been accepted, meaning it has been passed on to a [`Readable`](#Readable) stream or its buffer, or,
for a stream backed by a file or other device, written out.

Writing to a closed stream fails with `Cancelled`.

-}
write : value -> Writable value -> Task Error (Writable value)
write value stream =
    Debug.todo "Implement System API"


{-| Convert the given `String` to UTF-8 `Bytes` and write it to the stream.
-}
writeStringAsBytes : String -> Writable Bytes -> Task Error (Writable Bytes)
writeStringAsBytes str stream =
    Debug.todo "Implement System API"


{-| Same as [`writeStringAsBytes`](#writeStringAsBytes) except a newline character is appended to
the `String` before conversion.
-}
writeLineAsBytes : String -> Writable Bytes -> Task Error (Writable Bytes)
writeLineAsBytes str stream =
    Debug.todo "Implement System API"


{-| Queue a value to be written into the stream. The returned `Task` succeeds when the value is
in the stream's buffer.

The difference between this and [`write`](#write) is when the `Task` succeeds. Because the `Task`
from this function succeeds once the value is in a buffer, we won't be able to detect if the stream
is cancelled before the value is passed on to somewhere else. On the other hand, we can assume the
`Task` succeeds as long as there is room in the buffer, even if no one is actively reading from
the stream.

Enqueueing on a closed stream fails with `Cancelled`. (In gren this produced an unhandled
rejection instead.) In general you should prefer [`write`](#write), and reach for this function if
you experience problems.

-}
enqueue : value -> Writable value -> Task Error (Writable value)
enqueue value stream =
    Debug.todo "Implement System API"


{-| Close the stream. This indicates that no new values will be added to the stream after this
point. The `Task` succeeds once all values written before the close have been passed on, and
readers on the other end receive `Closed` once they have read everything.

Closing a stream that is already closed fails with `Cancelled`.

-}
closeWritable : Writable value -> Task Error ()
closeWritable stream =
    Debug.todo "Implement System API"


{-| Cancel the stream. This indicates a fatal error, and the given `String` should explain in a
human-readable way what that error is. If the stream contains a buffer, the buffer is dropped.

Writes that are still waiting fail with `Cancelled`, and reads from the other end of the stream
fail with `Cancelled` and the given reason.

-}
cancelWritable : String -> Writable value -> Task Error ()
cancelWritable reason stream =
    Debug.todo "Implement System API"



-- ERROR


{-| The different kinds of errors that can happen when operating on a stream.

  - `Closed`: The stream will never accept or produce another value.
  - `Cancelled`: The stream has been terminated, possibly because something went wrong. The
    associated `String` contains a human readable error message.
  - `Locked`: The stream is already being read from or written to, or is part of a pipe. You
    might have to retry the operation.

-}
type Error
    = Closed
    | Cancelled String
    | Locked


{-| Give a human readable description of an error.
-}
errorToString : Error -> String
errorToString error =
    Debug.todo "Implement System API"



-- TRANSFORMATION


{-| A readable-writable stream pair. Whatever is written to the writable stream can be retrieved
from the readable stream. After data is written, and before it is placed on the readable stream,
it goes through a transformation function. This function can alter the data, or even drop it
entirely.
-}
type alias Transformation read write =
    Stream.Internal.Transformation read write


{-| A [`Transformation`](#Transformation) that doesn't actually transform the data written to
the writable stream. Both of its buffers hold a single value.

This can be useful as a communication primitive. You can pass on the readable stream, allowing
one-way communication with some other part of your code base.

-}
identityTransformation : Task x (Transformation data data)
identityTransformation =
    Debug.todo "Implement System API"


{-| Same as [`identityTransformation`](#identityTransformation), but allows you to set the
capacity of the streams. The capacity decides how many chunks a stream will store in its buffer.
When a buffer is full, the stream stops accepting new chunks until it has room. Capacities below
1 are treated as 1.

If you attempt to write to a [`Writable`](#Writable) stream with a full buffer, the write will only
succeed when there's room in the buffer again. Reading from a [`Readable`](#Readable) stream with
values in its buffer succeeds instantly; if the buffer is empty, the read succeeds once there's a
value to be read.

-}
identityTransformationWithOptions : { readCapacity : Int, writeCapacity : Int } -> Task x (Transformation data data)
identityTransformationWithOptions options =
    Debug.todo "Implement System API"


{-| A [`Transformation`](#Transformation) that ignores all data written to it. The readable
stream never outputs data, but is closed whenever the writable stream is closed.
-}
nullTransformation : data -> Task x (Transformation data data)
nullTransformation initialState =
    Debug.todo "Implement System API"


{-| When defining a custom [`Transformation`](#Transformation), you need to specify how the data
coming in is handled.

  - `UpdateState`: Update the internal state of the [`Transformation`](#Transformation); no values
    are passed to the readable stream.
  - `Send`: Update the internal state and make chunks available for reading.
  - `Close`: Make the given chunks available for reading, and close the streams.
  - `Cancel`: Cancel both streams with a human-readable error message.

-}
type CustomTransformationAction state value
    = UpdateState state
    | Send { state : state, send : List value }
    | Close (List value)
    | Cancel String


{-| Create your very own [`Transformation`](#Transformation). The stream pair holds state, and is
free to alter, batch, combine or even drop whatever data is coming in. The function is called
with the current state and each value written to the stream, and decides what happens next.
-}
customTransformation : (state -> input -> CustomTransformationAction state output) -> state -> Task x (Transformation input output)
customTransformation fn initialState =
    Debug.todo "Implement System API"


{-| Same as [`customTransformation`](#customTransformation), except you can define the capacity
of each stream.

A write capacity below 1 is treated as 1, and a read capacity below 0 as 0. A read capacity of 0
means a value is only transformed once someone is waiting to read the result. (gren allowed a
write capacity of 0, which made the stream unable to accept any value.)

-}
customTransformationWithOptions :
    (state -> input -> CustomTransformationAction state output)
    -> { initialState : state, readCapacity : Int, writeCapacity : Int }
    -> Task x (Transformation input output)
customTransformationWithOptions fn options =
    Debug.todo "Implement System API"


{-| Retrieve the [`Readable`](#Readable) stream of a [`Transformation`](#Transformation).
-}
readable : Transformation read write -> Readable read
readable transformation =
    Debug.todo "Implement System API"


{-| Retrieve the [`Writable`](#Writable) stream of a [`Transformation`](#Transformation).
-}
writable : Transformation read write -> Writable write
writable transformation =
    Debug.todo "Implement System API"


{-| When data becomes available on a [`Readable`](#Readable) stream, immediately write that data
to the [`Transformation`](#Transformation). This locks both streams, and closing one will close the
other.

On success, the [`Readable`](#Readable) stream of the [`Transformation`](#Transformation) is
returned. If either stream is already locked, the `Task` fails with `Locked`.

-}
pipeThrough : Transformation input output -> Readable input -> Task Error (Readable output)
pipeThrough transformation source =
    Debug.todo "Implement System API"


{-| Same as [`pipeThrough`](#pipeThrough), except the [`Transformation`](#Transformation) is
resolved from a `Task`, such as [`gzipDecompression`](#gzipDecompression).
-}
awaitAndPipeThrough : Task Error (Transformation input output) -> Readable input -> Task Error (Readable output)
awaitAndPipeThrough builder source =
    Debug.todo "Implement System API"


{-| When data becomes available on a [`Readable`](#Readable) stream, immediately write that data
to the [`Writable`](#Writable) stream. This locks both streams.

When the readable stream closes, the writable stream is closed as well, and the `Task` succeeds.
If either stream is cancelled, the other one is cancelled with the same reason and the `Task`
fails with `Cancelled`.

-}
pipeTo : Writable data -> Readable data -> Task Error ()
pipeTo destination source =
    Debug.todo "Implement System API"



-- BUILT-IN TRANSFORMATIONS


{-| Transform each `String` into UTF-8 `Bytes`. Empty strings produce no output.
-}
textEncoder : Task x (Transformation String Bytes)
textEncoder =
    Debug.todo "Implement System API"


{-| Transform UTF-8 `Bytes` into `String`s. A multi-byte character split across two chunks is
decoded correctly, and a leading byte order mark is removed.

The decoder is lenient: invalid byte sequences are replaced by the replacement character
U+FFFD rather than cancelling the streams. Chunks that decode to nothing produce no output.

-}
textDecoder : Task x (Transformation Bytes String)
textDecoder =
    Debug.todo "Implement System API"


{-| Compress `Bytes` using the `gzip` format.
-}
gzipCompression : Task x (Transformation Bytes Bytes)
gzipCompression =
    Debug.todo "Implement System API"


{-| Compress `Bytes` using the `deflate` algorithm, in the zlib format.
-}
deflateCompression : Task x (Transformation Bytes Bytes)
deflateCompression =
    Debug.todo "Implement System API"


{-| Compress `Bytes` using the `deflate` algorithm, without leading headers or a trailing
checksum.
-}
deflateRawCompression : Task x (Transformation Bytes Bytes)
deflateRawCompression =
    Debug.todo "Implement System API"


{-| Decompress `Bytes` in the `gzip` format.
-}
gzipDecompression : Task x (Transformation Bytes Bytes)
gzipDecompression =
    Debug.todo "Implement System API"


{-| Decompress `Bytes` compressed with the `deflate` algorithm, in the zlib format.
-}
deflateDecompression : Task x (Transformation Bytes Bytes)
deflateDecompression =
    Debug.todo "Implement System API"


{-| Decompress `Bytes` compressed with the `deflate` algorithm, without leading headers or a
trailing checksum.
-}
deflateRawDecompression : Task x (Transformation Bytes Bytes)
deflateRawDecompression =
    Debug.todo "Implement System API"
