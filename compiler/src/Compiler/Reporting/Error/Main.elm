module Compiler.Reporting.Error.Main exposing
    ( Error(..)
    , toReport
    , errorEncoder, errorDecoder
    )

{-| A module's `main` value is where a program starts, and not every value can
be one. This module names the ways a `main` can be unusable and turns each into
a report for the user.

A `main` must be a plain value, not part of a cycle of definitions, and its type
must be a virtual DOM node or a `Platform.Program`. A program's flags are the
value it is given by JavaScript when it starts, so the flags type must be one
that can cross from JavaScript into Elm. Which types can cross is decided by the
checks that raise these errors; the reasons a type cannot are the
`InvalidPayload` of `Compiler.Reporting.Error.Canonicalize`, shared with ports.

Errors can also be written to and read from bytes.


# Errors

@docs Error


# Reporting

@docs toReport


# Serialization

@docs errorEncoder, errorDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error.Canonicalize as E
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Render.Type as RT
import Compiler.Reporting.Render.Type.Localizer as L
import Compiler.Reporting.Report as Report
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== ERROR ======


{-| A reason a module's `main` cannot be the entry point of a program. Each
carries the region of the name `main` where it is defined.

`BadType` carries the type of `main`, which is neither a virtual DOM node nor a
`Platform.Program`.

`BadCycle` is a `main` defined in terms of itself. It carries the name of one
definition in the cycle and the names of the others, in the order the report
draws them.

`BadFlags` is a `Program` whose flags type cannot come from JavaScript. It
carries the part of the flags type that was rejected and why it was rejected.
The report shows only the reason, not the type.

-}
type Error
    = BadType A.Region (Can.Type Name)
    | BadCycle A.Region Name (List Name)
    | BadFlags A.Region (Can.Type Name) E.InvalidPayload



-- ====== TO REPORT ======


{-| Builds the report for an error about `main`, showing the source lines of
its region from `source`. `localizer` decides how type names are qualified when
a `BadType` report prints the type.

A `BadFlags` report gives its own wording for each `InvalidPayload`, phrased
for flags rather than ports.

-}
toReport : L.Localizer -> Code.Source -> Error -> Report.Report
toReport localizer source err =
    case err of
        BadType region tipe ->
            ( D.fromChars "I cannot handle this type of `main` value:"
            , D.stack
                [ D.fromChars "The type of `main` value I am seeing is:"
                , RT.canToDoc localizer RT.None tipe |> D.dullyellow |> D.indent 4
                , D.reflow "I only know how to handle Html, Svg, and Programs though. Modify `main` to be one of those types of values!"
                ]
            )
                |> Code.toSnippet source region Nothing
                |> Report.report "BAD MAIN TYPE" region []

        BadCycle region name names ->
            ( D.fromChars "A `main` definition cannot be defined in terms of itself."
            , D.stack
                [ D.reflow "It should be a boring value with no recursion. But instead it is involved in this cycle of definitions:"
                , D.cycle 4 name names
                ]
            )
                |> Code.toSnippet source region Nothing
                |> Report.report "BAD MAIN" region []

        BadFlags region _ invalidPayload ->
            let
                formatDetails : ( String, D.Doc ) -> Report.Report
                formatDetails ( aBadKindOfThing, butThatIsNoGood ) =
                    ( D.reflow ("Your `main` program wants " ++ aBadKindOfThing ++ " from JavaScript.")
                    , butThatIsNoGood
                    )
                        |> Code.toSnippet source region Nothing
                        |> Report.report "BAD FLAGS" region []
            in
            formatDetails <|
                case invalidPayload of
                    E.ExtendedRecord ->
                        ( "an extended record"
                        , D.reflow "But the exact shape of the record must be known at compile time. No type variables!"
                        )

                    E.Function ->
                        ( "a function"
                        , D.reflow "But if I allowed functions from JS, it would be possible to sneak side-effects and runtime exceptions into Elm!"
                        )

                    E.TypeVariable name ->
                        ( "an unspecified type"
                        , D.reflow <|
                            "But type variables like `"
                                ++ name
                                ++ "` cannot be given as flags. I need to know exactly what type of data I am getting, "
                                ++ "so I can guarantee that unexpected data cannot sneak in and crash the Elm program."
                        )

                    E.UnsupportedType name ->
                        ( "a `" ++ name ++ "` value"
                        , D.stack
                            [ D.reflow "I cannot handle that. The types that CAN be in flags include:"
                            , D.reflow "Ints, Floats, Bools, Strings, Maybes, Lists, Arrays, tuples, records, and JSON values." |> D.indent 4
                            , D.reflow <|
                                "Since JSON values can flow through, you can use JSON encoders and decoders to allow other types through as well. "
                                    ++ "More advanced users often just do everything with encoders and decoders for more control and better errors."
                            ]
                        )



-- ====== ENCODERS and DECODERS ======


{-| Builds an encoder that writes `error` as a one-byte tag, 0 to 2 in
constructor order, followed by its fields. `errorDecoder` reads it back.
-}
errorEncoder : Error -> Bytes.Encode.Encoder
errorEncoder error =
    case error of
        BadType region tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , Can.typeEncoder tipe
                ]

        BadCycle region name names ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder region
                , BE.string name
                , BE.list BE.string names
                ]

        BadFlags region subType invalidPayload ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , Can.typeEncoder subType
                , E.invalidPayloadEncoder invalidPayload
                ]


{-| A decoder for an `Error` as `errorEncoder` writes it. An unknown tag fails.
-}
errorDecoder : Bytes.Decode.Decoder Error
errorDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 BadType
                            A.regionDecoder
                            Can.typeDecoder

                    1 ->
                        Bytes.Decode.map3 BadCycle
                            A.regionDecoder
                            BD.string
                            (BD.list BD.string)

                    2 ->
                        Bytes.Decode.map3 BadFlags
                            A.regionDecoder
                            Can.typeDecoder
                            E.invalidPayloadDecoder

                    _ ->
                        Bytes.Decode.fail
            )
