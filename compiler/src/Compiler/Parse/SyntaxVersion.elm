module Compiler.Parse.SyntaxVersion exposing (SyntaxVersion, decoder, encoder, fileSyntaxVersion)

{-| Syntax version for distinguishing Elm vs Guida syntax.
Re-exports from Compiler.AST.SyntaxVersion for backward compatibility.

@docs SyntaxVersion, decoder, encoder, fileSyntaxVersion

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.SyntaxVersion as SV


{-| The `SyntaxVersion` type is used to specify which syntax version to work
with. Re-exported from Compiler.AST.SyntaxVersion.
-}
type alias SyntaxVersion =
    SV.SyntaxVersion


{-| Returns the syntax version based on a filepath.
Files ending in .elm use Elm syntax, all others use Guida syntax.
-}
fileSyntaxVersion : String -> SyntaxVersion
fileSyntaxVersion =
    SV.fileSyntaxVersion


{-| Encodes a SyntaxVersion to bytes for serialization.
-}
encoder : SyntaxVersion -> Bytes.Encode.Encoder
encoder =
    SV.encoder


{-| Decodes a SyntaxVersion from bytes for deserialization.
-}
decoder : Bytes.Decode.Decoder SyntaxVersion
decoder =
    SV.decoder
