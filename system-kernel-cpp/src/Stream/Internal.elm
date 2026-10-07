module Stream.Internal exposing (Readable(..), Transformation(..), Writable(..))

{-| Internal; not exposed.

The stream handle types are defined here so that every module in this package can build and
unwrap them, while users only see the aliases exposed by `Stream`.

-}


{-| A readable stream, identified by its stream-table id.
-}
type Readable value
    = Readable Int


{-| A writable stream, identified by its stream-table id.
-}
type Writable value
    = Writable Int


{-| A transformation, identified by its stream-table id.
-}
type Transformation read write
    = Transformation Int
