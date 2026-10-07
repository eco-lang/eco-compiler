module System.File.Internal exposing (Error(..))

{-| Internal; not exposed.

`Error` is defined here so that both `System.File` and `System.File.FileHandle` can build it,
while users only see the alias exposed by `System.File`.

-}

import System.File.Path exposing (Path)


{-| A file system error: the path involved, the error code (an errno name such as `"ENOENT"`)
and a human readable message.
-}
type Error
    = Error
        { path : Path
        , code : String
        , message : String
        }
