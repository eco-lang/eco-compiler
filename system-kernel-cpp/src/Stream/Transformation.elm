module Stream.Transformation exposing
    ( identity, identityWith, null, CustomAction(..), custom, customWith
    , readable, writable
    , textEncoder, textDecoder
    , gzip, gunzip, deflate, inflate, deflateRaw, inflateRaw
    )

{-| Create [`Transformation`](Stream#Transformation) streams: readable-writable stream pairs that
transform, batch or drop the values passing through them. Use them with
[`Stream.pipeThrough`](Stream#pipeThrough):

    Stream.Transformation.gunzip
        |> Task.andThen (\gunzip -> Stream.pipeThrough gunzip compressed)

The `Transformation` type and the piping functions live in [`Stream`](Stream).

Compared with gren-lang/core, the names drop the `Transformation` suffix
(`identityTransformation` is [`identity`](#identity)), the variants with options are named
`…With`, and the compression codecs take zlib's names (`gzipDecompression` is
[`gunzip`](#gunzip), `deflateDecompression` is [`inflate`](#inflate)).
[`customWith`](#customWith) never uses a write capacity below 1, and the built-in text and
compression transformations buffer one chunk on their readable side (WHATWG uses zero there, so a
`write` would wait until someone reads).


# Building Transformations

@docs identity, identityWith, null, CustomAction, custom, customWith


# Using Transformations

@docs readable, writable


# Text

@docs textEncoder, textDecoder


# Compression

@docs gzip, gunzip, deflate, inflate, deflateRaw, inflateRaw

-}

import Bytes exposing (Bytes)
import Eco.Kernel.Stream
import Stream exposing (Readable, Transformation, Writable)
import Stream.Internal
import Task exposing (Task)



-- BUILDING TRANSFORMATIONS


{-| A [`Transformation`](Stream#Transformation) that doesn't actually transform the data written to
the writable stream. Both of its buffers hold a single value.

This can be useful as a communication primitive. You can pass on the readable stream, allowing
one-way communication with some other part of your code base.

-}
identity : Task x (Transformation data data)
identity =
    identityWith { readCapacity = 1, writeCapacity = 1 }


{-| Same as [`identity`](#identity), but allows you to set the
capacity of the streams. The capacity decides how many chunks a stream will store in its buffer.
When a buffer is full, the stream stops accepting new chunks until it has room. Capacities below
1 are treated as 1.

If you attempt to write to a [`Writable`](Stream#Writable) stream with a full buffer, the write will only
succeed when there's room in the buffer again. Reading from a [`Readable`](Stream#Readable) stream with
values in its buffer succeeds instantly; if the buffer is empty, the read succeeds once there's a
value to be read.

-}
identityWith : { readCapacity : Int, writeCapacity : Int } -> Task x (Transformation data data)
identityWith options =
    kIdentity (max 1 options.readCapacity) (max 1 options.writeCapacity)
        |> Task.map Stream.Internal.Transformation
        |> Task.mapError never


{-| A [`Transformation`](Stream#Transformation) that ignores all data written to it. The readable
stream never outputs data, but is closed whenever the writable stream is closed.
-}
null : data -> Task x (Transformation data data)
null initialState =
    custom (\state _ -> UpdateState state) initialState


{-| When defining a custom [`Transformation`](Stream#Transformation), you need to specify how the data
coming in is handled.

  - `UpdateState`: Update the internal state of the [`Transformation`](Stream#Transformation); no values
    are passed to the readable stream.
  - `Send`: Update the internal state and make chunks available for reading.
  - `Close`: Make the given chunks available for reading, and close the streams.
  - `Cancel`: Cancel both streams with a human-readable error message.

-}
type CustomAction state value
    = UpdateState state
    | Send { state : state, send : List value }
    | Close (List value)
    | Cancel String


{-| Create your very own [`Transformation`](Stream#Transformation). The stream pair holds state, and is
free to alter, batch, combine or even drop whatever data is coming in. The function is called
with the current state and each value written to the stream, and decides what happens next.
-}
custom : (state -> input -> CustomAction state output) -> state -> Task x (Transformation input output)
custom fn initialState =
    customWith fn
        { initialState = initialState
        , readCapacity = 1
        , writeCapacity = 1
        }


{-| Same as [`custom`](#custom), except you can define the capacity
of each stream.

A write capacity below 1 is treated as 1, and a read capacity below 0 as 0. A read capacity of 0
means a value is only transformed once someone is waiting to read the result. (gren allowed a
write capacity of 0, which made the stream unable to accept any value.)

-}
customWith :
    (state -> input -> CustomAction state output)
    -> { initialState : state, readCapacity : Int, writeCapacity : Int }
    -> Task x (Transformation input output)
customWith fn options =
    kCustom (customAction fn) options.initialState (max 0 options.readCapacity) (max 1 options.writeCapacity)
        |> Task.map Stream.Internal.Transformation
        |> Task.mapError never


{-| The action the kernel calls for each value (plans/eco-system-library.md §3.5):
`( ctor, state, ( values, reason ) )` with ctor 0 UpdateState, 1 Send, 2 Close, 3 Cancel.
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


{-| Retrieve the [`Readable`](Stream#Readable) stream of a [`Transformation`](Stream#Transformation).
-}
readable : Transformation input output -> Readable output
readable (Stream.Internal.Transformation id) =
    Stream.Internal.Readable id


{-| Retrieve the [`Writable`](Stream#Writable) stream of a [`Transformation`](Stream#Transformation).
-}
writable : Transformation input output -> Writable input
writable (Stream.Internal.Transformation id) =
    Stream.Internal.Writable id



-- BUILT-IN TRANSFORMATIONS


{-| Transform each `String` into UTF-8 `Bytes`. Empty strings produce no output.
-}
textEncoder : Task x (Transformation String Bytes)
textEncoder =
    codec kTextEncoder


{-| Transform UTF-8 `Bytes` into `String`s. A multi-byte character split across two chunks is
decoded correctly, and a leading byte order mark is removed.

The decoder is lenient: invalid byte sequences are replaced by the replacement character
U+FFFD rather than cancelling the streams. Chunks that decode to nothing produce no output.

-}
textDecoder : Task x (Transformation Bytes String)
textDecoder =
    codec kTextDecoder


{-| Compress `Bytes` using the `gzip` format.
-}
gzip : Task x (Transformation Bytes Bytes)
gzip =
    codec (kCompressor 0)


{-| Compress `Bytes` using the `deflate` algorithm, in the zlib format.
-}
deflate : Task x (Transformation Bytes Bytes)
deflate =
    codec (kCompressor 1)


{-| Compress `Bytes` using the `deflate` algorithm, without leading headers or a trailing
checksum.
-}
deflateRaw : Task x (Transformation Bytes Bytes)
deflateRaw =
    codec (kCompressor 2)


{-| Decompress `Bytes` in the `gzip` format.

If the data is corrupt, continues past the end of the compressed data, or ends before it is
complete (when the writable stream is closed), both streams are cancelled with a description of
the problem.

-}
gunzip : Task x (Transformation Bytes Bytes)
gunzip =
    codec (kDecompressor 0)


{-| Decompress `Bytes` compressed with the `deflate` algorithm, in the zlib format.
-}
inflate : Task x (Transformation Bytes Bytes)
inflate =
    codec (kDecompressor 1)


{-| Decompress `Bytes` compressed with the `deflate` algorithm, without leading headers or a
trailing checksum.
-}
inflateRaw : Task x (Transformation Bytes Bytes)
inflateRaw =
    codec (kDecompressor 2)


{-| Wrap a codec pair id. The codec streams buffer one chunk on each side.
-}
codec : Task Never Int -> Task x (Transformation read write)
codec kernel =
    kernel
        |> Task.map Stream.Internal.Transformation
        |> Task.mapError never



-- KERNELS
-- The annotations fix the kernel ABI (plans/eco-system-library.md Appendix B.2).


kIdentity : Int -> Int -> Task Never Int
kIdentity =
    Eco.Kernel.Stream.identity


kCustom : (s -> a -> ( Int, s, ( List b, String ) )) -> s -> Int -> Int -> Task Never Int
kCustom =
    Eco.Kernel.Stream.custom


kTextEncoder : Task Never Int
kTextEncoder =
    Eco.Kernel.Stream.textEncoder


kTextDecoder : Task Never Int
kTextDecoder =
    Eco.Kernel.Stream.textDecoder


kCompressor : Int -> Task Never Int
kCompressor =
    Eco.Kernel.Stream.compressor


kDecompressor : Int -> Task Never Int
kDecompressor =
    Eco.Kernel.Stream.decompressor
