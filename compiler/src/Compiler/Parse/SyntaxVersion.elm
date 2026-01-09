module Compiler.Parse.SyntaxVersion exposing (SyntaxVersion(..), decoder, encoder, fileSyntaxVersion)

{-| Compiler.Parse.SyntaxVersion

@docs SyntaxVersion, decoder, encoder, fileSyntaxVersion

-}

import Bytes.Decode
import Bytes.Encode


{-| The `SyntaxVersion` type is used to specify which syntax version to work
with. It provides options to differentiate between the "legacy" Elm syntax,
which the Guida language builds upon, and the new Guida-specific syntax.

This type is useful when building parsers that need to distinguish between
the two syntactic styles and adapt behavior accordingly.

-}
type SyntaxVersion
    = Elm
    | Guida


{-| Returns the syntax version based on a filepath.
Files ending in .elm use Elm syntax, all others use Guida syntax.
-}
fileSyntaxVersion : String -> SyntaxVersion
fileSyntaxVersion path =
    if String.endsWith ".elm" path then
        Elm

    else
        Guida



-- ====== ENCODERS and DECODERS ======


{-| Encodes a SyntaxVersion to bytes for serialization.
-}
encoder : SyntaxVersion -> Bytes.Encode.Encoder
encoder syntaxVersion =
    Bytes.Encode.unsignedInt8
        (case syntaxVersion of
            Elm ->
                0

            Guida ->
                1
        )


{-| Decodes a SyntaxVersion from bytes for deserialization.
-}
decoder : Bytes.Decode.Decoder SyntaxVersion
decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Elm

                    1 ->
                        Bytes.Decode.succeed Guida

                    _ ->
                        Bytes.Decode.fail
            )
