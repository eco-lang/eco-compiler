module Compiler.Data.IndexName exposing
    ( fromIndex, fromInt
    )

{-| Generate short alphabetic names from indices.

This module provides functions to convert numeric indices to short alphabetic
names suitable for variable naming. It is placed in the Data layer to be
accessible from both LocalOpt and Generate layers.

@docs fromIndex, fromInt

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name as Name


{-| Convert a zero-based index to a short alphabetic name.

    fromIndex Index.first == "a"
    fromIndex Index.second == "b"
    fromIndex Index.third == "c"

-}
fromIndex : Index.ZeroBased -> Name.Name
fromIndex index =
    fromInt (Index.toMachine index)


{-| Convert an integer to a short alphabetic name.

Uses a simple scheme:

  - 0-25: lowercase letters a-z
  - 26-51: uppercase letters A-Z
  - 52+: extends with multi-character names

-}
fromInt : Int -> Name.Name
fromInt n =
    if n < 26 then
        -- lowercase a-z
        Name.fromWords [ Char.fromCode (97 + n) ]

    else if n < 52 then
        -- uppercase A-Z
        Name.fromWords [ Char.fromCode (65 + n - 26) ]

    else
        -- For larger indices, use multi-character names
        -- This is a simplified version - full version is in Generate.JavaScript.Name
        let
            base =
                n - 52

            first =
                modBy 52 base

            rest =
                base // 52
        in
        if rest == 0 then
            Name.fromWords [ Char.fromCode (97 + first), '0' ]

        else
            Name.fromWords [ Char.fromCode (97 + modBy 26 first), Char.fromCode (48 + modBy 10 rest) ]
