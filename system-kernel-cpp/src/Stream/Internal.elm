module Stream.Internal exposing (Readable(..), Transformation(..), Writable(..))

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
