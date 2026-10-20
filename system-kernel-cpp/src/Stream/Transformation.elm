module Stream.Transformation exposing
    ( identity, identityWith, null, CustomAction(..), custom, customWith
    , readable, writable
    , textEncoder, textDecoder
    , gzip, gunzip, deflate, inflate, deflateRaw, inflateRaw
    )

{-| A [`Transformation`](Stream#Transformation) is an in-memory stream that changes the values
passing through it, and this module is where transformations are made: ones that pass values on
unchanged, ones driven by an Elm function, and built-in ones for text and compression.

    Stream.Transformation.gunzip
        |> Task.andThen (\gunzip -> Stream.pipeThrough gunzip compressed)

Everything here that makes a transformation is a `Task`, not a `Transformation`. Each run of the
task creates a new transformation with nothing in it. [`readable`](#readable) and
[`writable`](#writable) give its two sides: values written into the writable side come out,
transformed, on the readable side. Reading, writing, closing, cancelling and piping work on those
sides as [`Stream`](Stream) describes.

Each side has a _capacity_, a number of values. The writable side holds up to its capacity of
values written but not yet transformed, and the readable side holds results not yet read. A value
is transformed as it leaves the writable side, which happens only while the readable side holds
fewer results than its capacity (or, at a read capacity of 0, while a reader waits; see
[`customWith`](#customWith)), so a reader that falls behind fills the readable side first, then
the writable side, after which a write waits for room, as [`Stream.write`](Stream#write)
describes. A [`Stream.write`](Stream#write) into a transformation succeeds once its value has
been transformed, not once the results have been read.

A transformation that fails is cancelled on both sides: results not yet read are dropped, and
writes still waiting, later writes and a close fail with `Cancelled` and the reason, as do later
reads, apart from bytes [`Stream.readLine`](Stream#readLine) has kept, which can still be read.
This happens, for example, when a custom transformation's step returns `Cancel`, and when a
decompressor fails, as each decompressor describes.


# Building Transformations

An _identity_ transformation passes every value on unchanged. A _custom_ transformation calls an
Elm function, its _step_, for each value written, with a state the step carries from one value to
the next; [`CustomAction`](#CustomAction) is what a step returns.

@docs identity, identityWith, null, CustomAction, custom, customWith


# Using Transformations

@docs readable, writable


# Text

The text transformations convert between `String` and UTF-8 `Bytes`, and never fail. Neither
produces an empty value: an input that yields nothing yet, such as an empty string, produces no
output. Each side has a capacity of one value.

@docs textEncoder, textDecoder


# Compression

Six transformations from `Bytes` to `Bytes`, using zlib, in three formats: gzip, deflate data in
the zlib format, which adds a header and a checksum, and raw deflate data, which has neither. Each
side has a capacity of one value, but one value written can produce several outputs. Each output is
at most 64 KiB.

A compressor does not produce output for every value written: zlib holds data back until it has
enough to emit, and writes the rest when the writable side is closed, so a reader may get nothing
until then.

A decompressor that fails cancels the transformation, with a description of the problem, as
described above. A `write` of the value that carried the bad data fails, and a close fails when the
compressed data was incomplete.

@docs gzip, gunzip, deflate, inflate, deflateRaw, inflateRaw

-}

import Bytes exposing (Bytes)
import Eco.Kernel.Stream
import Stream exposing (Readable, Transformation, Writable)
import Stream.Internal
import Task exposing (Task)



-- BUILDING TRANSFORMATIONS


{-| A task that creates an identity transformation, whose sides each have a capacity of one value.

Handing its readable side to another part of a program gives that part a one-way channel from
whoever holds the writable side.

-}
identity : Task x (Transformation data data)
identity =
    identityWith { readCapacity = 1, writeCapacity = 1 }


{-| Creates an identity transformation, as [`identity`](#identity) does, with the given
capacities. A capacity below 1 is raised to 1.
-}
identityWith : { readCapacity : Int, writeCapacity : Int } -> Task x (Transformation data data)
identityWith options =
    kIdentity (max 1 options.readCapacity) (max 1 options.writeCapacity)
        |> Task.map Stream.Internal.Transformation
        |> Task.mapError never


{-| Creates a transformation that accepts every value written into it and drops it. Its readable
side never gives a value, and is closed when the writable side is closed.

The argument becomes the step's state, which nothing reads, so any value will do. Each side
has a capacity of one value.

-}
null : data -> Task x (Transformation data data)
null initialState =
    custom (\state _ -> UpdateState state) initialState


{-| What a custom transformation's step does with one value written into it: carry on with a new
state, possibly producing values, or end the transformation.

`UpdateState` carries the new state and produces nothing.

`Send` carries the new state and the values to make readable, in order. All of them are put in
the readable side's buffer, even beyond its capacity; no further value is transformed until
readers have brought the buffer back below its capacity, or, at a read capacity of 0, emptied it
and wait for more.

`Close` ends the transformation after the values it carries. They are made readable, and once
they and the values before them have been read, reads fail with `Closed`. Writes still waiting to
be transformed, a close in progress, and every later write or close fail with
`Cancelled "TransformStream has been terminated"`.

`Cancel` cancels the transformation on both sides with the given reason, as the module
documentation describes.

With `Close` and `Cancel`, the write of the value that produced them still succeeds.

-}
type CustomAction state value
    = UpdateState state
    | Send { state : state, send : List value }
    | Close (List value)
    | Cancel String


{-| Creates a custom transformation. For each value written, in order, the step is called with the
current state and the value, and the [`CustomAction`](#CustomAction) it returns says what happens.
The second argument is the first state. Each side has a capacity of one value.

The step is called only for values written. Closing the writable side does not call it, so
anything the step holds in its state, such as a partial batch, is not produced at the close; the
readable side closes once its buffered values have been read.

-}
custom : (state -> input -> CustomAction state output) -> state -> Task x (Transformation input output)
custom fn initialState =
    customWith fn
        { initialState = initialState
        , readCapacity = 1
        , writeCapacity = 1
        }


{-| Creates a custom transformation, as [`custom`](#custom) does, with the given first state and
capacities.

A write capacity below 1 is raised to 1, and a read capacity below 0 to 0. With a read capacity of
0, a value is transformed only when nothing is buffered on the readable side and a read is waiting
on it, or a pipe out of it is ready for a value.

-}
customWith :
    (state -> input -> CustomAction state output)
    -> { initialState : state, readCapacity : Int, writeCapacity : Int }
    -> Task x (Transformation input output)
customWith fn options =
    kCustom (customAction fn) options.initialState (max 0 options.readCapacity) (max 1 options.writeCapacity)
        |> Task.map Stream.Internal.Transformation
        |> Task.mapError never


{-| Encodes the action `toAction` returns for `state` and `input` as the tuple the kernel reads,
`( ctor, state, ( values, reason ) )`, with ctor 0 for `UpdateState`, 1 for `Send`, 2 for `Close`
and 3 for `Cancel`. A field the action does not use holds the given `state`, `[]` or `""`.
-}
customAction : (state -> input -> CustomAction state output) -> state -> input -> ( Int, state, ( List output, String ) )
customAction toAction state input =
    case toAction state input of
        UpdateState newState ->
            ( 0, newState, ( [], "" ) )

        Send send ->
            ( 1, send.state, ( send.send, "" ) )

        Close values ->
            ( 2, state, ( values, "" ) )

        Cancel reason ->
            ( 3, state, ( [], reason ) )


{-| Returns the readable side of a transformation, from which its output values are read.
-}
readable : Transformation input output -> Readable output
readable (Stream.Internal.Transformation id) =
    Stream.Internal.Readable id


{-| Returns the writable side of a transformation, into which its input values are written.
-}
writable : Transformation input output -> Writable input
writable (Stream.Internal.Transformation id) =
    Stream.Internal.Writable id



-- BUILT-IN TRANSFORMATIONS


{-| A task that creates a transformation from `String`s to their UTF-8 encoding as `Bytes`.

A surrogate pair split across two strings is encoded as the one character it stands for. A lone
surrogate becomes U+FFFD, on both backends, unlike [`Stream.writeString`](Stream#writeString).

-}
textEncoder : Task x (Transformation String Bytes)
textEncoder =
    codec kTextEncoder


{-| A task that creates a transformation from UTF-8 `Bytes` to `String`s.

The bytes may be split anywhere: a character split across two chunks is decoded whole. Invalid
bytes are replaced by the replacement character U+FFFD, rather than cancelling the transformation,
and so is a character left incomplete when the writable side is closed. A byte order mark at the
very start is removed.

-}
textDecoder : Task x (Transformation Bytes String)
textDecoder =
    codec kTextDecoder


{-| A task that creates a transformation that compresses `Bytes` into the gzip format.
-}
gzip : Task x (Transformation Bytes Bytes)
gzip =
    codec (kCompressor 0)


{-| A task that creates a transformation that compresses `Bytes` into deflate data in the zlib
format.
-}
deflate : Task x (Transformation Bytes Bytes)
deflate =
    codec (kCompressor 1)


{-| A task that creates a transformation that compresses `Bytes` into raw deflate data, with no
header or checksum.
-}
deflateRaw : Task x (Transformation Bytes Bytes)
deflateRaw =
    codec (kCompressor 2)


{-| A task that creates a transformation that decompresses gzip-format `Bytes`.

The transformation is cancelled when the data cannot be decompressed, or when the writable side
is closed before the compressed data is complete. Data after the end of the compressed data is
treated differently by the two backends: the native backend cancels the transformation; on the
JavaScript backend, whether such data is decompressed, ignored or cancels the transformation depends
on the data and on how it was split into written values.

-}
gunzip : Task x (Transformation Bytes Bytes)
gunzip =
    codec (kDecompressor 0)


{-| A task that creates a transformation that decompresses deflate data in the zlib format.

The transformation is cancelled when the data cannot be decompressed, or when the writable side
is closed before the compressed data is complete. Data after the end of the compressed data
cancels it on the native backend, and is ignored on the JavaScript backend.

-}
inflate : Task x (Transformation Bytes Bytes)
inflate =
    codec (kDecompressor 1)


{-| A task that creates a transformation that decompresses raw deflate data, which has no header
or checksum.

The transformation is cancelled when the data cannot be decompressed, or when the writable side
is closed before the compressed data is complete. Data after the end of the compressed data
cancels it on the native backend, and is ignored on the JavaScript backend.

-}
inflateRaw : Task x (Transformation Bytes Bytes)
inflateRaw =
    codec (kDecompressor 2)


{-| Turns a kernel task that creates a codec pair, one of the built-in text or compression
transformations, into a task that creates the `Transformation` over the pair's id.
-}
codec : Task Never Int -> Task x (Transformation read write)
codec kernel =
    kernel
        |> Task.map Stream.Internal.Transformation
        |> Task.mapError never



-- KERNELS
-- The annotations fix the kernel ABI: both kernels rely on exactly these argument and result
-- shapes.


{-| Creates an identity pair whose readable side has the first number as its capacity and whose
writable side the second, each raised to at least 1, and gives its id.
-}
kIdentity : Int -> Int -> Task Never Int
kIdentity =
    Eco.Kernel.Stream.identity


{-| Creates a custom pair from the encoded step, the first state, the read capacity (raised to at
least 0) and the write capacity (raised to at least 1), and gives its id.
-}
kCustom : (s -> a -> ( Int, s, ( List b, String ) )) -> s -> Int -> Int -> Task Never Int
kCustom =
    Eco.Kernel.Stream.custom


{-| A kernel task that creates a text encoder pair, whose sides each have capacity one, and gives
its id.
-}
kTextEncoder : Task Never Int
kTextEncoder =
    Eco.Kernel.Stream.textEncoder


{-| A kernel task that creates a text decoder pair, whose sides each have capacity one, and gives
its id.
-}
kTextDecoder : Task Never Int
kTextDecoder =
    Eco.Kernel.Stream.textDecoder


{-| Creates a compressor pair, whose sides each have capacity one, and gives its id. The algorithm
is 0 for gzip, 1 for deflate in the zlib format and 2 for raw deflate; any other number is raw
deflate in both kernels.
-}
kCompressor : Int -> Task Never Int
kCompressor =
    Eco.Kernel.Stream.compressor


{-| Creates a decompressor pair, whose sides each have capacity one, and gives its id. The
algorithm is numbered as for `kCompressor`.
-}
kDecompressor : Int -> Task Never Int
kDecompressor =
    Eco.Kernel.Stream.decompressor
