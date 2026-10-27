module Compiler.Generate.MLIR.BytesFusion.Reify exposing
    ( EncoderNode, DecoderNode, BodyLookup
    , reifyEncoderWith, reifyDecoder
    , nodesToOps, decoderNodeToOps
    , CountSource, LengthDecoder
    )

{-| An `elm/bytes` encoder or decoder can be compiled to straight-line writes or
reads on a buffer only when its shape is known at compile time; this module
recognises that shape in the monomorphized program and describes it in the
operations of `Compiler.Generate.MLIR.BytesFusion.LoopIR`.

To _reify_ an expression here is to recognise, purely from its syntax, which
`Bytes.Encode` or `Bytes.Decode` combinators it is built from. Nothing is
evaluated. A combinator is identified by looking its specialization up in the
`SpecializationRegistry` and finding an `elm/bytes` global (`Bytes.Encode.*`,
`Bytes.Decode.*`, the `Bytes` endianness constructors); a few `elm/core` list,
comparison and arithmetic functions are recognised the same way, or as the
kernels they alias.

The work comes in two halves, one for each direction, and each half has two
steps: reify an expression into a tree of nodes (`EncoderNode`,
`DecoderNode`), then flatten the nodes into Loop IR operations (`nodesToOps`,
`decoderNodeToOps`).

The program has been through the inliner by the time it is reified, so a
combinator may appear in more than one form: as a call of the `elm/bytes`
global, as a curried call `(f a) b`, as the encoder constructor it is defined
by (`U8`, `I16`, `Utf8`, `Seq`, ...), or behind `let` bindings the inliner
introduced. An _expression cache_ (`exprCache`, a `Dict` from a `let`-bound name
to the expression bound to it) lets the reifier see through such bindings: it
is supplied by the caller and extended with every `let` the reifier walks past.

The two halves differ in what happens to a piece they do not recognise. An
encoder is reified _partially_: an unrecognised subtree becomes an `EOpaque`
node, written at run time by the ordinary encoder, while the rest is still
fused. A decoder is all or nothing: one unrecognised piece makes the whole
reification fail.

Most of the decoder half is the recognition of two `Bytes.Decode.loop` idioms:
a count loop, which reads a given number of items, and a sentinel loop, which
reads integers until one equals a given literal. After inlining, `succeed`,
`map` and `andThen` may appear as their inlined bodies, so the matchers look
through those as well as through calls.


# Types

@docs EncoderNode, DecoderNode, BodyLookup


# Reification

@docs reifyEncoderWith, reifyDecoder


# Loop IR Conversion

@docs nodesToOps, decoderNodeToOps


# Auxiliary Types

@docs CountSource, LengthDecoder

-}

import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (Endianness(..), Op(..), WidthExpr(..))
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.Registry as Registry
import Dict exposing (Dict)


{-| The parameters and body of named functions, keyed by specialization id,
which the encoder reifier may look inside.

It is used for one thing: when the function mapped over a length-prefixed list
(see `EncoderNode`) is a named function rather than a lambda, its body is
looked up here and reified in place of a lambda's. A function missing from the
table is not looked inside, so an empty table is always safe; it only means
that such a list is not fused as a loop.

-}
type alias BodyLookup =
    Dict Int ( List ( Name, Mono.MonoType ), Mono.MonoExpr )


{-| One write in a recognised encoder. An encoder reifies to a flat list of
these: a `sequence` contributes its elements' nodes in order, not a nested
node.

`EU8` to `EF64` write one fixed-width number, of the width and kind their names
give. Signed and unsigned writes of the same width share a node, since they
write the same bytes. The `MonoExpr` is the value to write.

`EBytes` copies a bytes value, and `EUtf8` writes a string as UTF-8; their
widths are known only at run time.

`ELoop` writes a list whose length was written just before it, the shape

    sequence (unsignedInt32 endian (List.length xs) :: List.map f xs)

which reifies to an `EU32` followed by an `ELoop`. `itemNodes` are the writes
for one element, and every one of them has a constant width. `itemVar` is the
name by which `itemNodes` refer to the current element, and `itemType` is its
type. `iterExpr` is `xs`, and `countExpr` is the `List.length xs` call itself,
also used to size the buffer.

`EOpaque` is an encoder subtree that was not recognised. It is written at run
time by the ordinary encoder, and its width is measured at run time too.

-}
type EncoderNode
    = EU8 Mono.MonoExpr
    | EU16 Endianness Mono.MonoExpr
    | EU32 Endianness Mono.MonoExpr
    | EF32 Endianness Mono.MonoExpr
    | EF64 Endianness Mono.MonoExpr
    | EBytes Mono.MonoExpr
    | EUtf8 Mono.MonoExpr
    | ELoop
        { itemVar : String
        , itemType : Mono.MonoType
        , itemNodes : List EncoderNode
        , iterExpr : Mono.MonoExpr
        , countExpr : Mono.MonoExpr
        }
    | EOpaque Mono.MonoExpr


{-| A recognised decoder, as a tree that mirrors the `Bytes.Decode`
combinators it was built from.

`DU8` to `DF64` read one fixed-width number; `DS` is signed, `DU` unsigned and
`DF` a float.

`DBytes` and `DString` read a bytes value or a UTF-8 string whose length in
bytes is the value of their expression.

`DSucceed` produces the value of its expression without reading, and `DFail`
fails the decoder.

`DMap` to `DMap5` run their decoders in order and apply the function
expression to their results.

`DLengthPrefixedString` and `DLengthPrefixedBytes` are the `andThen` shape
that reads an integer and then a string or bytes value of that length.
`DAndThen` is any other recognised `andThen`: the first decoder, the name of the
callback's parameter, and the decoder the callback's body reifies to.

`DCountLoop` is a `loop` that reads a given number of items; `DSentinelLoop`
is a `loop` that reads integers until one equals an integer literal. Each carries the order of the list it produces and its item
decoder, one fixed-width read; `DSentinelLoop` also carries the integer that
ends the list.

-}
type DecoderNode
    = DU8
    | DS8
    | DU16 Endianness
    | DS16 Endianness
    | DU32 Endianness
    | DS32 Endianness
    | DF32 Endianness
    | DF64 Endianness
    | DBytes Mono.MonoExpr
    | DString Mono.MonoExpr
    | DSucceed Mono.MonoExpr
    | DFail
    | DMap Mono.MonoExpr DecoderNode
    | DMap2 Mono.MonoExpr DecoderNode DecoderNode
    | DMap3 Mono.MonoExpr DecoderNode DecoderNode DecoderNode
    | DMap4 Mono.MonoExpr DecoderNode DecoderNode DecoderNode DecoderNode
    | DMap5 Mono.MonoExpr DecoderNode DecoderNode DecoderNode DecoderNode DecoderNode
    | DLengthPrefixedString LengthDecoder
    | DLengthPrefixedBytes LengthDecoder
    | DAndThen DecoderNode String DecoderNode
    | DCountLoop CountSource IR.ListOrder DecoderNode
    | DSentinelLoop Int IR.ListOrder DecoderNode


{-| The integer read that supplies the length of a `DLengthPrefixedString` or
`DLengthPrefixedBytes`: its width, whether it is signed, and its byte order.
-}
type LengthDecoder
    = LenU8
    | LenU16 Endianness
    | LenU32 Endianness
    | LenI8
    | LenI16 Endianness
    | LenI32 Endianness


{-| Where the number of items of a `DCountLoop` comes from.

`CountConst` is an `Int` literal, written directly or bound by a `let`.
`CountFromVar` names a local variable: either an `andThen` callback's
parameter, whose value is an earlier read, or a variable in scope where the
decoder is compiled.

-}
type CountSource
    = CountFromVar String
    | CountConst Int


{-| Reifies an encoder expression into the list of writes it performs, or
returns `Nothing` when nothing of it was recognised.

Recognition is partial: a subtree that is not recognised becomes an `EOpaque`
node and the rest is still reified. When the result would be a single
`EOpaque` node, the result is `Nothing`, since a fused encoder that only hands its
value to the run-time encoder gains nothing over calling it directly.

`bodyLookup` supplies the bodies of named functions mapped over a
length-prefixed list (see `BodyLookup`), and `exprCache` the expressions bound
to `let` names in scope.

-}
reifyEncoderWith : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderWith bodyLookup registry exprCache expr =
    case reifyEncoderHelp bodyLookup registry exprCache expr of
        Just [ EOpaque _ ] ->
            Nothing

        result ->
            result


{-| Reifies an encoder expression as `reifyEncoderHelpStrict` does, except that
an expression it does not recognise becomes `[ EOpaque expr ]`; so the result
is never `Nothing`. This is what lets one unrecognised subtree leave the rest
of the encoder fused.
-}
reifyEncoderHelp : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderHelp bodyLookup registry exprCache expr =
    case reifyEncoderHelpStrict bodyLookup registry exprCache expr of
        Just result ->
            Just result

        Nothing ->
            Just [ EOpaque expr ]


{-| Reifies an encoder expression, or returns `Nothing` when its outermost form
is not recognised.

Recognised forms are a call of a `Bytes.Encode` function or of the `Bytes`
kernel, directly, curried, or through a local variable bound to a partial call;
a `let`, whose binding is added to `exprCache`; and a local variable bound in
`exprCache`. The encoders inside a recognised `sequence` are reified with
`reifyEncoderHelp`, so they may still be opaque.

-}
reifyEncoderHelpStrict : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderHelpStrict bodyLookup registry exprCache expr =
    case expr of
        Mono.MonoCall _ func args _ _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Encode" then
                                reifyBytesEncodeCall bodyLookup registry exprCache name args

                            else
                                Nothing

                        _ ->
                            Nothing

                Mono.MonoVarKernel _ _ "Bytes" name _ ->
                    reifyBytesKernelCall name args

                Mono.MonoCall _ innerFunc innerArgs _ _ ->
                    case innerFunc of
                        Mono.MonoVarGlobal _ innerSpecId _ ->
                            case Registry.lookupSpecKey innerSpecId registry of
                                Just ( Mono.Global (ModuleName.Canonical pkg2 moduleName2) name2, _ ) ->
                                    if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Encode" then
                                        reifyBytesEncodeCall bodyLookup registry exprCache name2 (innerArgs ++ args)

                                    else
                                        Nothing

                                _ ->
                                    Nothing

                        Mono.MonoVarKernel _ _ "Bytes" name2 _ ->
                            reifyBytesKernelCall name2 (innerArgs ++ args)

                        _ ->
                            Nothing

                Mono.MonoVarLocal funcName _ ->
                    case Dict.get funcName exprCache of
                        Just (Mono.MonoCall _ innerFunc innerArgs _ _) ->
                            case innerFunc of
                                Mono.MonoVarGlobal _ innerSpecId _ ->
                                    case Registry.lookupSpecKey innerSpecId registry of
                                        Just ( Mono.Global (ModuleName.Canonical pkg2 moduleName2) name2, _ ) ->
                                            if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Encode" then
                                                reifyBytesEncodeCall bodyLookup registry exprCache name2 (innerArgs ++ args)

                                            else
                                                Nothing

                                        _ ->
                                            Nothing

                                Mono.MonoVarKernel _ _ "Bytes" name2 _ ->
                                    reifyBytesKernelCall name2 (innerArgs ++ args)

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        Mono.MonoLet def body _ ->
            case def of
                Mono.MonoDef name defExpr ->
                    reifyEncoderHelp bodyLookup registry (Dict.insert name defExpr exprCache) body

                _ ->
                    Nothing

        Mono.MonoVarLocal name _ ->
            case Dict.get name exprCache of
                Just cachedExpr ->
                    reifyEncoderHelp bodyLookup registry exprCache cachedExpr

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Reifies a saturated call of the `Bytes.Encode` function or constructor
`name` to `args`, or returns `Nothing` for any other name or argument count,
or when an endianness or nested part is not recognised.

The constructors (`U8`, `I16`, `F64`, `Bytes`, `Utf8`, `Seq`, ...) are the forms
the encoder functions take once inlined; `Utf8` and `Seq` carry a precomputed
width, which is ignored. `sequence` and `Seq` reify each element of their list
(see `reifyEncoderList`).

-}
reifyBytesEncodeCall : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> List Mono.MonoExpr -> Maybe (List EncoderNode)
reifyBytesEncodeCall bodyLookup registry exprCache name args =
    case ( name, args ) of
        ( "sequence", [ listExpr ] ) ->
            reifyEncoderList bodyLookup registry exprCache listExpr

        ( "unsignedInt8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "signedInt8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "U8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "I8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "unsignedInt16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "signedInt16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "U16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "I16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "unsignedInt32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "signedInt32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "U32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "I32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "float32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF32 e valueExpr ])

        ( "float64", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF64 e valueExpr ])

        ( "F32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF32 e valueExpr ])

        ( "F64", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF64 e valueExpr ])

        ( "bytes", [ bytesExpr ] ) ->
            Just [ EBytes bytesExpr ]

        ( "Bytes", [ bytesExpr ] ) ->
            Just [ EBytes bytesExpr ]

        ( "string", [ stringExpr ] ) ->
            Just [ EUtf8 stringExpr ]

        ( "Utf8", [ _, stringExpr ] ) ->
            Just [ EUtf8 stringExpr ]

        ( "Seq", [ _, listExpr ] ) ->
            reifyEncoderList bodyLookup registry exprCache listExpr

        _ ->
            Nothing


{-| Reifies a call of the `Bytes` kernel function `name`. Only the one-byte
writes `write_u8` and `write_i8` are recognised; any other kernel call returns
`Nothing`.
-}
reifyBytesKernelCall : String -> List Mono.MonoExpr -> Maybe (List EncoderNode)
reifyBytesKernelCall name args =
    case ( name, args ) of
        ( "write_u8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "write_i8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        _ ->
            Nothing


{-| Reifies the list argument of a `sequence` into the writes of all its
encoders, in order, or returns `Nothing` when the list's shape is not known.

The list is recognised as a list literal, whose elements are each reified with
`reifyEncoderHelp`, or as the length-prefixed shape `header :: List.map f xs`
(see `reifyLengthPrefixedLoop`). A `let` around the list, or a local variable
standing for it, is seen through with `exprCache`, which is how a list bound by
an inlined helper's `let` is still recognised.

-}
reifyEncoderList : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderList bodyLookup registry exprCache listExpr =
    case listExpr of
        Mono.MonoList _ items _ ->
            items
                |> List.map (reifyEncoderHelp bodyLookup registry exprCache)
                |> combineResults
                |> Maybe.map List.concat

        Mono.MonoCall _ funcExpr args _ _ ->
            case ( reifyListConsCall registry funcExpr args, args ) of
                ( Just ( headerExpr, tailExpr ), _ ) ->
                    reifyLengthPrefixedLoop bodyLookup registry exprCache headerExpr tailExpr

                _ ->
                    Nothing

        Mono.MonoLet (Mono.MonoDef name boundExpr) body _ ->
            reifyEncoderList bodyLookup registry (Dict.insert name boundExpr exprCache) body

        Mono.MonoVarLocal name _ ->
            case Dict.get name exprCache of
                Just cachedExpr ->
                    reifyEncoderList bodyLookup registry exprCache cachedExpr

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Returns the head and the tail when `funcExpr` applied to `args` is `::`,
written either as the `List` kernel `cons` or as the `elm/core` global
`List.cons`, with both arguments.
-}
reifyListConsCall : Mono.SpecializationRegistry -> Mono.MonoExpr -> List Mono.MonoExpr -> Maybe ( Mono.MonoExpr, Mono.MonoExpr )
reifyListConsCall registry funcExpr args =
    case ( funcExpr, args ) of
        ( Mono.MonoVarKernel _ _ "List" "cons" _, [ headerExpr, tailExpr ] ) ->
            Just ( headerExpr, tailExpr )

        ( Mono.MonoVarGlobal _ specId _, [ headerExpr, tailExpr ] ) ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg "List") "cons", _ ) ->
                    if pkg == Pkg.core then
                        Just ( headerExpr, tailExpr )

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the function and the list when `expr` is a call of the `elm/core`
global `List.map` with both arguments.
-}
reifyListMapCall : Mono.SpecializationRegistry -> Mono.MonoExpr -> Maybe ( Mono.MonoExpr, Mono.MonoExpr )
reifyListMapCall registry expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) [ mapFn, iterExpr ] _ _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg "List") "map", _ ) ->
                    if pkg == Pkg.core then
                        Just ( mapFn, iterExpr )

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the list when `expr` is a call of the `elm/core` global
`List.length`.
-}
reifyListLengthCall : Mono.SpecializationRegistry -> Mono.MonoExpr -> Maybe Mono.MonoExpr
reifyListLengthCall registry expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) [ iterExpr ] _ _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg "List") "length", _ ) ->
                    if pkg == Pkg.core then
                        Just iterExpr

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns whether `a` and `b` are the same local variable. Any other pair of
expressions, even identical ones, gives `False`.
-}
sameIterExpr : Mono.MonoExpr -> Mono.MonoExpr -> Bool
sameIterExpr a b =
    case ( a, b ) of
        ( Mono.MonoVarLocal n1 _, Mono.MonoVarLocal n2 _ ) ->
            n1 == n2

        _ ->
            False


{-| Reifies the list `headerExpr :: tailExpr` as a length-prefixed list,
returning `[ EU32 ..., ELoop ... ]`, or `Nothing` when it is not one.

It is one when `tailExpr` is `List.map f xs`, `headerExpr` is
`unsignedInt32 endian (List.length xs)` with the same local variable `xs` (see
`matchLengthPrefixHeader`), and `f`'s body reifies to constant-width writes
(see `reifyMapBody`).

-}
reifyLengthPrefixedLoop : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyLengthPrefixedLoop bodyLookup registry exprCache headerExpr tailExpr =
    case reifyListMapCall registry tailExpr of
        Nothing ->
            Nothing

        Just ( mapFn, iterExpr ) ->
            case matchLengthPrefixHeader registry headerExpr iterExpr of
                Nothing ->
                    Nothing

                Just ( headerNode, countExpr ) ->
                    case reifyMapBody bodyLookup registry exprCache mapFn iterExpr countExpr of
                        Nothing ->
                            Nothing

                        Just loopNode ->
                            Just [ headerNode, loopNode ]


{-| Matches the header of a length-prefixed list: a call of the `Bytes.Encode`
global `unsignedInt32` or `U32` to an endianness and `List.length` of the local
variable `iterExpr`. Returns the `EU32` write and the `List.length` call.

Only a direct, saturated call of the global is matched, not a curried call or
one reached through a `let`.

-}
matchLengthPrefixHeader : Mono.SpecializationRegistry -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe ( EncoderNode, Mono.MonoExpr )
matchLengthPrefixHeader registry headerExpr iterExpr =
    case headerExpr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) [ endianExpr, lengthCall ] _ _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg "Bytes.Encode") name, _ ) ->
                    if pkg == Pkg.bytes && (name == "unsignedInt32" || name == "U32") then
                        case ( reifyEndianness registry endianExpr, reifyListLengthCall registry lengthCall ) of
                            ( Just endian, Just lengthIterExpr ) ->
                                if sameIterExpr lengthIterExpr iterExpr then
                                    Just ( EU32 endian lengthCall, lengthCall )

                                else
                                    Nothing

                            _ ->
                                Nothing

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Builds the `ELoop` for `List.map mapFn iterExpr`, with `countExpr` as its
count, or returns `Nothing` when `mapFn`'s body is not known or not
constant-width.

`mapFn` may be a lambda of one parameter, or a named function found in
`bodyLookup` with one parameter. A named function with two parameters is also
accepted when its body applies something to the second parameter as the last
argument and mentions it nowhere else: that is a one-parameter encoder function
that was eta-expanded (`Encoder` being a function type alias), and the body is
reduced back with `etaReduceTrailingParam`. The function's parameter becomes the
loop's `itemVar`. Anything else, such as a function passed in as a parameter or a
kernel, gives `Nothing`.

The body must reify to fixed-width numeric writes only (see
`hasConstantWidth`), because the buffer is sized as the count times one item's
width.

-}
reifyMapBody : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe EncoderNode
reifyMapBody bodyLookup registry exprCache mapFn iterExpr countExpr =
    case mapFn of
        Mono.MonoClosure info body _ ->
            case info.params of
                [ ( paramName, paramType ) ] ->
                    buildLoopNode bodyLookup registry exprCache paramName paramType body iterExpr countExpr

                _ ->
                    Nothing

        Mono.MonoVarGlobal _ specId _ ->
            case Dict.get specId bodyLookup of
                Just ( [ ( paramName, paramType ) ], body ) ->
                    buildLoopNode bodyLookup registry exprCache paramName paramType body iterExpr countExpr

                Just ( [ ( paramName, paramType ), ( extraName, _ ) ], body ) ->
                    case etaReduceTrailingParam extraName body of
                        Just reduced ->
                            buildLoopNode bodyLookup registry exprCache paramName paramType reduced iterExpr countExpr

                        Nothing ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Undoes one eta-expansion of a function body: returns `f args` when `body`
is `f args extra`, with the local variable `extra` as the last argument and
nowhere else in the call, and `Nothing` otherwise.

`extra` may be the only argument of a call, in which case the result is `f`
itself, or the last of several, in which case the result is the call without
it, typed by `peelParams`.

-}
etaReduceTrailingParam : Name -> MonoExpr -> Maybe MonoExpr
etaReduceTrailingParam extra body =
    let
        mentionsExtra e =
            MonoTraverse.foldExpr
                (\x acc ->
                    acc
                        || (case x of
                                MonoVarLocal n _ ->
                                    n == extra

                                _ ->
                                    False
                           )
                )
                False
                e
    in
    case body of
        MonoCall _ func [ MonoVarLocal n _ ] _ _ ->
            if n == extra && not (mentionsExtra func) then
                Just func

            else
                Nothing

        MonoCall region func args _ callInfo ->
            case List.reverse args of
                (MonoVarLocal n _) :: revInit ->
                    let
                        initArgs =
                            List.reverse revInit
                    in
                    if n == extra && not (List.isEmpty initArgs) && not (mentionsExtra func) && not (List.any mentionsExtra initArgs) then
                        Maybe.map
                            (\reducedType -> MonoCall region func initArgs reducedType callInfo)
                            (peelParams (List.length initArgs) (Mono.typeOf func))

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the type of a function of type `funcType` applied to `k`
arguments, or `Nothing` when it takes fewer than `k`.

A function type may take several parameters at once. When `k` stops part way
through such a group, the remaining parameters keep the group's own
annotation.

-}
peelParams : Int -> Mono.MonoType -> Maybe Mono.MonoType
peelParams k funcType =
    if k <= 0 then
        Just funcType

    else
        case funcType of
            Mono.MFunction _ anno params ret ->
                let
                    np =
                        List.length params
                in
                if k >= np then
                    peelParams (k - np) ret

                else
                    Just (Mono.mFunction anno (List.drop k params) ret)

            _ ->
                Nothing


{-| Builds the `ELoop` whose item is the parameter `paramName` and whose writes
are `body` reified, or returns `Nothing` when any of those writes lacks a
constant width.

`paramType` is the type of the list's elements. It is kept because the writes
are numeric but the element they read from may be of any type, a record for
instance.

-}
buildLoopNode : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe EncoderNode
buildLoopNode bodyLookup registry exprCache paramName paramType body iterExpr countExpr =
    case reifyEncoderHelp bodyLookup registry exprCache body of
        Just bodyNodes ->
            if List.all hasConstantWidth bodyNodes then
                Just
                    (ELoop
                        { itemVar = paramName
                        , itemType = paramType
                        , itemNodes = bodyNodes
                        , iterExpr = iterExpr
                        , countExpr = countExpr
                        }
                    )

            else
                Nothing

        Nothing ->
            Nothing


{-| Returns whether `node` writes a number of bytes known at compile time,
which is true of the fixed-width numeric writes `EU8` to `EF64` and of nothing
else; a nested `ELoop` gives `False`.
-}
hasConstantWidth : EncoderNode -> Bool
hasConstantWidth node =
    case node of
        EU8 _ ->
            True

        EU16 _ _ ->
            True

        EU32 _ _ ->
            True

        EF32 _ _ ->
            True

        EF64 _ _ ->
            True

        EBytes _ ->
            False

        EUtf8 _ ->
            False

        ELoop _ ->
            False

        EOpaque _ ->
            False


{-| Returns the number of bytes `node` writes when `hasConstantWidth node`;
for any other node it returns 0, which is not its width.
-}
constantNodeWidth : EncoderNode -> Int
constantNodeWidth node =
    case node of
        EU8 _ ->
            1

        EU16 _ _ ->
            2

        EU32 _ _ ->
            4

        EF32 _ _ ->
            4

        EF64 _ _ ->
            8

        EBytes _ ->
            0

        EUtf8 _ ->
            0

        ELoop _ ->
            0

        EOpaque _ ->
            0


{-| Returns the byte order `expr` names when it is the `elm/bytes` constructor
`Bytes.LE` or `Bytes.BE`, possibly applied to no arguments. An endianness
computed at run time, such as a variable, gives `Nothing`.
-}
reifyEndianness : Mono.SpecializationRegistry -> Mono.MonoExpr -> Maybe Endianness
reifyEndianness registry expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
                    if pkg == Pkg.bytes && moduleName == "Bytes" then
                        case name of
                            "LE" ->
                                Just LE

                            "BE" ->
                                Just BE

                            _ ->
                                Nothing

                    else
                        Nothing

                _ ->
                    Nothing

        Mono.MonoCall _ fn [] _ _ ->
            reifyEndianness registry fn

        _ ->
            Nothing


{-| Returns the Loop IR encoder for `nodes`: an `InitCursor` that allocates a
buffer of their total width (see `computeWidth`), one write per node in order,
and `ReturnBuffer`. The cursor is named `"cur"`.
-}
nodesToOps : List EncoderNode -> List Op
nodesToOps nodes =
    let
        cursorName =
            "cur"

        width =
            computeWidth nodes

        writeOps =
            List.map (nodeToOp cursorName) nodes
    in
    InitCursor cursorName width :: writeOps ++ [ ReturnBuffer ]


{-| Returns the Loop IR write for one node, on the cursor `cursorName`. An
`ELoop` becomes a `WriteEachItem` whose per-item width is the sum of its
writes' widths.
-}
nodeToOp : String -> EncoderNode -> Op
nodeToOp cursorName node =
    case node of
        EU8 expr ->
            WriteU8 cursorName expr

        EU16 endian expr ->
            WriteU16 cursorName endian expr

        EU32 endian expr ->
            WriteU32 cursorName endian expr

        EF32 endian expr ->
            WriteF32 cursorName endian expr

        EF64 endian expr ->
            WriteF64 cursorName endian expr

        EBytes expr ->
            WriteBytesCopy cursorName expr

        EUtf8 expr ->
            WriteUtf8 cursorName expr

        ELoop r ->
            WriteEachItem
                { cursorName = cursorName
                , itemVar = r.itemVar
                , itemType = r.itemType
                , bodyOps = List.map (nodeToOp cursorName) r.itemNodes
                , iterExpr = r.iterExpr
                , itemByteWidth = sumConstWidths r.itemNodes
                }

        EOpaque expr ->
            WriteOpaque cursorName expr


{-| Returns the total width of `nodes`, which must all have constant width
(see `constantNodeWidth`).
-}
sumConstWidths : List EncoderNode -> Int
sumConstWidths nodes =
    List.foldl (\n acc -> acc + constantNodeWidth n) 0 nodes


{-| Returns the total number of bytes `nodes` write, as a simplified
`WidthExpr`.
-}
computeWidth : List EncoderNode -> WidthExpr
computeWidth nodes =
    List.foldl addNodeWidth (WConst 0) nodes
        |> IR.simplifyWidth


{-| Adds the width of `node` to `acc`: a constant for a numeric write, the run-time
size of a bytes value, a string's UTF-8 length, the count times the item width
for an `ELoop`, or the size the run-time encoder measures for an `EOpaque`.
-}
addNodeWidth : EncoderNode -> WidthExpr -> WidthExpr
addNodeWidth node acc =
    case node of
        EU8 _ ->
            WAdd acc (WConst 1)

        EU16 _ _ ->
            WAdd acc (WConst 2)

        EU32 _ _ ->
            WAdd acc (WConst 4)

        EF32 _ _ ->
            WAdd acc (WConst 4)

        EF64 _ _ ->
            WAdd acc (WConst 8)

        EBytes bytesExpr ->
            WAdd acc (WBytesWidth bytesExpr)

        EUtf8 stringExpr ->
            WAdd acc (WStringUtf8Width stringExpr)

        ELoop r ->
            WAdd acc (WListLengthMul r.countExpr (sumConstWidths r.itemNodes))

        EOpaque expr ->
            WAdd acc (WOpaqueWidth expr)


{-| Returns every value of `maybes` in order, or `Nothing` if any of them is
`Nothing`.
-}
combineResults : List (Maybe a) -> Maybe (List a)
combineResults maybes =
    List.foldr
        (\maybeVal acc ->
            case ( maybeVal, acc ) of
                ( Just val, Just list ) ->
                    Just (val :: list)

                _ ->
                    Nothing
        )
        (Just [])
        maybes



-- ============================================================================
-- Decoder Reification
-- ============================================================================


{-| Reifies a decoder expression into a `DecoderNode`, or returns `Nothing`
when any part of it is not recognised; there is no partial result.

Recognised forms are a call of a `Bytes.Decode` function, directly, curried, or
through a local variable bound to a partial call; a bare `Bytes.Decode` value
such as `unsignedInt8`; a `let`, whose binding is added to `exprCache`; and a
local variable bound in `exprCache`. The recognised functions are the
fixed-width reads, `bytes`, `string`, `succeed`, `fail`, `map` to `map5`,
`andThen`, and `loop` in two shapes only: a count loop, which reads a given
number of items, and a sentinel loop, which reads integers until one equals an
integer literal. A call of a `Bytes` kernel function is never recognised.

-}
reifyDecoder : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyDecoder registry exprCache expr =
    case expr of
        Mono.MonoCall _ func args _ _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                                reifyBytesDecodeCall registry exprCache name args

                            else
                                Nothing

                        _ ->
                            Nothing

                Mono.MonoVarKernel _ _ "Bytes" _ _ ->
                    reifyBytesKernelDecodeCall

                Mono.MonoCall _ innerFunc innerArgs _ _ ->
                    case innerFunc of
                        Mono.MonoVarGlobal _ innerSpecId _ ->
                            case Registry.lookupSpecKey innerSpecId registry of
                                Just ( Mono.Global (ModuleName.Canonical pkg2 moduleName2) name2, _ ) ->
                                    if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Decode" then
                                        reifyBytesDecodeCall registry exprCache name2 (innerArgs ++ args)

                                    else
                                        Nothing

                                _ ->
                                    Nothing

                        Mono.MonoVarKernel _ _ "Bytes" _ _ ->
                            reifyBytesKernelDecodeCall

                        _ ->
                            Nothing

                Mono.MonoVarLocal funcName _ ->
                    case Dict.get funcName exprCache of
                        Just (Mono.MonoCall _ innerFunc innerArgs _ _) ->
                            case innerFunc of
                                Mono.MonoVarGlobal _ innerSpecId _ ->
                                    case Registry.lookupSpecKey innerSpecId registry of
                                        Just ( Mono.Global (ModuleName.Canonical pkg2 moduleName2) name2, _ ) ->
                                            if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Decode" then
                                                reifyBytesDecodeCall registry exprCache name2 (innerArgs ++ args)

                                            else
                                                Nothing

                                        _ ->
                                            Nothing

                                Mono.MonoVarKernel _ _ "Bytes" _ _ ->
                                    reifyBytesKernelDecodeCall

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        Mono.MonoVarGlobal _ specId _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
                    if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                        reifyBytesDecodeCall registry exprCache name []

                    else
                        Nothing

                _ ->
                    Nothing

        Mono.MonoLet def body _ ->
            case def of
                Mono.MonoDef name defExpr ->
                    reifyDecoder registry (Dict.insert name defExpr exprCache) body

                _ ->
                    Nothing

        Mono.MonoVarLocal name _ ->
            case Dict.get name exprCache of
                Just cachedExpr ->
                    reifyDecoder registry exprCache cachedExpr

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Reifies the `Bytes.Decode` function `name` applied to `args`, or returns
`Nothing` for any other name or argument count, or when an endianness or nested
part is not recognised.

Recognised are the fixed-width reads, `bytes` and `string` with a length
expression, `succeed`, `fail`, `map` to `map5`, `andThen` (see `reifyAndThen`)
and `loop` (see `reifyLoop`). The decoders among the arguments are reified with
`reifyDecoder`.

-}
reifyBytesDecodeCall : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> List Mono.MonoExpr -> Maybe DecoderNode
reifyBytesDecodeCall registry exprCache name args =
    case ( name, args ) of
        ( "unsignedInt8", [] ) ->
            Just DU8

        ( "signedInt8", [] ) ->
            Just DS8

        ( "unsignedInt16", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DU16

        ( "signedInt16", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DS16

        ( "unsignedInt32", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DU32

        ( "signedInt32", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DS32

        ( "float32", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DF32

        ( "float64", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DF64

        ( "bytes", [ lenExpr ] ) ->
            Just (DBytes lenExpr)

        ( "string", [ lenExpr ] ) ->
            Just (DString lenExpr)

        ( "succeed", [ valueExpr ] ) ->
            Just (DSucceed valueExpr)

        ( "fail", [] ) ->
            Just DFail

        ( "map", [ fnExpr, decoderExpr ] ) ->
            reifyDecoder registry exprCache decoderExpr
                |> Maybe.map (DMap fnExpr)

        ( "map2", [ fnExpr, d1Expr, d2Expr ] ) ->
            Maybe.map2 (DMap2 fnExpr)
                (reifyDecoder registry exprCache d1Expr)
                (reifyDecoder registry exprCache d2Expr)

        ( "map3", [ fnExpr, d1Expr, d2Expr, d3Expr ] ) ->
            Maybe.map3 (DMap3 fnExpr)
                (reifyDecoder registry exprCache d1Expr)
                (reifyDecoder registry exprCache d2Expr)
                (reifyDecoder registry exprCache d3Expr)

        ( "map4", [ fnExpr, d1Expr, d2Expr, d3Expr, d4Expr ] ) ->
            map4 (DMap4 fnExpr)
                (reifyDecoder registry exprCache d1Expr)
                (reifyDecoder registry exprCache d2Expr)
                (reifyDecoder registry exprCache d3Expr)
                (reifyDecoder registry exprCache d4Expr)

        ( "map5", [ fnExpr, d1Expr, d2Expr, d3Expr, d4Expr, d5Expr ] ) ->
            map5 (DMap5 fnExpr)
                (reifyDecoder registry exprCache d1Expr)
                (reifyDecoder registry exprCache d2Expr)
                (reifyDecoder registry exprCache d3Expr)
                (reifyDecoder registry exprCache d4Expr)
                (reifyDecoder registry exprCache d5Expr)

        ( "andThen", [ lambdaExpr, firstDecoderExpr ] ) ->
            reifyAndThen registry exprCache lambdaExpr firstDecoderExpr

        ( "loop", [ initialStateExpr, stepFnExpr ] ) ->
            reifyLoop registry exprCache initialStateExpr stepFnExpr

        _ ->
            Nothing


{-| The reification of any call of a `Bytes` kernel function as a decoder,
which is always `Nothing`: no kernel decoder is recognised.
-}
reifyBytesKernelDecodeCall : Maybe DecoderNode
reifyBytesKernelDecodeCall =
    Nothing



-- ============================================================================
-- andThen Pattern Recognition
-- ============================================================================


{-| Reifies `andThen lambdaExpr firstDecoderExpr`, or returns `Nothing` when the
first decoder is not recognised or the callback is not a one-parameter lambda
whose body `reifyAndThenBody` recognises.
-}
reifyAndThen : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyAndThen registry exprCache lambdaExpr firstDecoderExpr =
    case reifyDecoder registry exprCache firstDecoderExpr of
        Nothing ->
            Nothing

        Just firstDecoder ->
            case lambdaExpr of
                Mono.MonoClosure closureInfo bodyExpr _ ->
                    reifyAndThenBody registry exprCache firstDecoder closureInfo bodyExpr

                _ ->
                    Nothing


{-| Reifies an `andThen` whose first decoder reifies to `firstDecoder` and whose
callback is a lambda of one parameter with body `bodyExpr`.

When the body is `string n` or `bytes n` on the parameter `n` itself, the result
is a `DLengthPrefixedString` or `DLengthPrefixedBytes`, provided the first
decoder is a single integer read; if it is not, the result is `Nothing`, and the
general form is not tried. Otherwise the body is reified as a decoder and the
result is a `DAndThen`.

-}
reifyAndThenBody :
    Mono.SpecializationRegistry
    -> Dict String Mono.MonoExpr
    -> DecoderNode
    -> Mono.ClosureInfo
    -> Mono.MonoExpr
    -> Maybe DecoderNode
reifyAndThenBody registry exprCache firstDecoder closureInfo bodyExpr =
    let
        maybeParamName =
            case closureInfo.params of
                [ ( name, _ ) ] ->
                    Just name

                _ ->
                    Nothing
    in
    case maybeParamName of
        Nothing ->
            Nothing

        Just paramName ->
            case matchLengthPrefixedPattern registry paramName bodyExpr of
                Just patternConstructor ->
                    case decoderToLengthDecoder firstDecoder of
                        Just lenDecoder ->
                            Just (patternConstructor lenDecoder)

                        Nothing ->
                            Nothing

                Nothing ->
                    case reifyDecoder registry exprCache bodyExpr of
                        Just bodyDecoder ->
                            Just (DAndThen firstDecoder paramName bodyDecoder)

                        Nothing ->
                            Nothing


{-| Returns `DLengthPrefixedString` or `DLengthPrefixedBytes` when `bodyExpr` is
a direct call of the `Bytes.Decode` global `string` or `bytes` whose one
argument is the local variable `paramName`.
-}
matchLengthPrefixedPattern :
    Mono.SpecializationRegistry
    -> String
    -> Mono.MonoExpr
    -> Maybe (LengthDecoder -> DecoderNode)
matchLengthPrefixedPattern registry paramName bodyExpr =
    case bodyExpr of
        Mono.MonoCall _ func [ argExpr ] _ _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                                if isParamRef paramName argExpr then
                                    case name of
                                        "string" ->
                                            Just DLengthPrefixedString

                                        "bytes" ->
                                            Just DLengthPrefixedBytes

                                        _ ->
                                            Nothing

                                else
                                    Nothing

                            else
                                Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns whether `expr` is the local variable `paramName`.
-}
isParamRef : String -> Mono.MonoExpr -> Bool
isParamRef paramName expr =
    case expr of
        Mono.MonoVarLocal name _ ->
            name == paramName

        _ ->
            False


{-| Returns the `LengthDecoder` for `node` when it is a single integer read, and
`Nothing` for anything else, a float read included.
-}
decoderToLengthDecoder : DecoderNode -> Maybe LengthDecoder
decoderToLengthDecoder node =
    case node of
        DU8 ->
            Just LenU8

        DS8 ->
            Just LenI8

        DU16 endian ->
            Just (LenU16 endian)

        DS16 endian ->
            Just (LenI16 endian)

        DU32 endian ->
            Just (LenU32 endian)

        DS32 endian ->
            Just (LenI32 endian)

        _ ->
            Nothing



-- ============================================================================
-- loop Pattern Recognition
-- ============================================================================


{-| Reifies a `Bytes.Decode.loop` call, given its two arguments in `elm/bytes`
order:

    loop : state -> (state -> Decoder (Step state a)) -> Decoder a

Only two loop shapes are recognised, and only when the whole idiom matches,
because the reified loop is not the step function run repeatedly but a fixed
list-building loop that is correct only for these idioms; anything else gives
`Nothing`. In both, the accumulator starts as `[]`, each item is prepended
with `::`, the item decoder is one fixed-width primitive read, and the `Done`
result is either the accumulator itself (the items in reverse read order) or
`List.reverse` of it (in read order); any other `Done` result, condition or
state update is not fused.

  - Count loop:

        loop ( count, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    succeed (Done acc)
                    -- or (List.reverse acc)

                else
                    map (\x -> Loop ( n - 1, x :: acc )) item
            )

  - Sentinel loop (`item` an integer read, `s` an integer literal, `b == s`
    or `s == b`):

        loop []
            (\acc ->
                andThen
                    (\b ->
                        if b == s then
                            succeed (Done acc)
                            -- or (List.reverse acc)

                        else
                            succeed (Loop (b :: acc))
                    )
                    item
            )

`succeed`, `map` and `andThen` are recognised both as calls and in the form the
inliner leaves them in when it inlines them: the `Decoder` constructor applied
to the closure of their `elm/bytes` body. `<=`, `==`, `-`, `::` and
`List.reverse` are recognised as the elm/core globals or as the kernels they
are aliases of.

-}
reifyLoop : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyLoop registry exprCache initialStateExpr stepFnExpr =
    let
        env =
            { lets = exprCache, paths = Dict.empty }
    in
    case resolveLocal env initialStateExpr of
        Mono.MonoTupleCreate _ [ countExpr, accInit ] _ ->
            if isEmptyList (resolveLocal env accInit) then
                Maybe.map2 (\count ( order, item ) -> DCountLoop count order item)
                    (countSourceOf env countExpr)
                    (matchCountStep registry env stepFnExpr)

            else
                Nothing

        initial ->
            if isEmptyList initial then
                matchSentinelStep registry env stepFnExpr
                    |> Maybe.map (\( sentinel, order, item ) -> DSentinelLoop sentinel order item)

            else
                Nothing


{-| What is known about the names in scope where a loop is recognised: the
expression each `let` binds, and the path each destructuring binds.
-}
type alias LoopEnv =
    { lets : Dict String Mono.MonoExpr
    , paths : Dict String Mono.MonoPath
    }


{-| Strips the `let`s and destructurings at the top of `expr`, recording what
they bind in `env`, and returns the expression under them.
-}
peelBindings : LoopEnv -> Mono.MonoExpr -> ( LoopEnv, Mono.MonoExpr )
peelBindings env expr =
    case expr of
        Mono.MonoLet (Mono.MonoDef name bound) body _ ->
            peelBindings { env | lets = Dict.insert name bound env.lets } body

        Mono.MonoDestruct (Mono.MonoDestructor name path _) body _ ->
            peelBindings { env | paths = Dict.insert name path env.paths } body

        _ ->
            ( env, expr )


{-| Follows a local variable to the expression a `let` bound it to, as many
times as needed (up to 32), and returns the first expression reached that is
not a `let`-bound local.
-}
resolveLocal : LoopEnv -> Mono.MonoExpr -> Mono.MonoExpr
resolveLocal env expr =
    resolveLocalHelp 32 env expr


{-| Follows `let`-bound local variables as `resolveLocal` does, at most `fuel`
times; when the fuel runs out the expression reached so far is returned.
-}
resolveLocalHelp : Int -> LoopEnv -> Mono.MonoExpr -> Mono.MonoExpr
resolveLocalHelp fuel env expr =
    if fuel <= 0 then
        expr

    else
        case expr of
            Mono.MonoVarLocal name _ ->
                case Dict.get name env.lets of
                    Just bound ->
                        resolveLocalHelp (fuel - 1) env bound

                    Nothing ->
                        expr

            _ ->
                expr


{-| Returns whether `expr` is the empty list literal.
-}
isEmptyList : Mono.MonoExpr -> Bool
isEmptyList expr =
    case expr of
        Mono.MonoList _ [] _ ->
            True

        _ ->
            False


{-| Returns the count of a count loop when `countExpr` is an `Int` literal, or a
local variable (`CountConst` when a `let` binds it to a literal, `CountFromVar`
otherwise), and `Nothing` for any other expression.
-}
countSourceOf : LoopEnv -> Mono.MonoExpr -> Maybe CountSource
countSourceOf env countExpr =
    case countExpr of
        Mono.MonoLiteral (Mono.LInt n) _ ->
            Just (CountConst n)

        Mono.MonoVarLocal name _ ->
            case resolveLocal env countExpr of
                Mono.MonoLiteral (Mono.LInt n) _ ->
                    Just (CountConst n)

                _ ->
                    Just (CountFromVar name)

        _ ->
            Nothing


{-| Matches the step function of a count loop (see `reifyLoop`), returning the
order of the list it builds and its item decoder.
-}
matchCountStep : Mono.SpecializationRegistry -> LoopEnv -> Mono.MonoExpr -> Maybe ( IR.ListOrder, DecoderNode )
matchCountStep registry env0 stepFnExpr =
    case resolveLocal env0 stepFnExpr of
        Mono.MonoClosure info body _ ->
            case info.params of
                [ ( stateName, _ ) ] ->
                    let
                        ( env, inner ) =
                            peelBindings env0 body

                        componentName index =
                            Dict.foldl
                                (\name path found ->
                                    case path of
                                        Mono.MonoIndex i Mono.Tuple2Container _ (Mono.MonoRoot root _) ->
                                            if i == index && root == stateName then
                                                Just name

                                            else
                                                found

                                        _ ->
                                            found
                                )
                                Nothing
                                env.paths
                    in
                    case ( componentName 0, componentName 1, inner ) of
                        ( Just n, Just acc, Mono.MonoIf [ ( cond, thenExpr ) ] elseExpr _ ) ->
                            if isCountExhausted registry env n cond then
                                Maybe.map2 Tuple.pair
                                    (matchDoneSucceed registry env acc thenExpr)
                                    (matchCountContinue registry env n acc elseExpr)

                            else
                                Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns whether `cond` is `n <= 0`.
-}
isCountExhausted : Mono.SpecializationRegistry -> LoopEnv -> String -> Mono.MonoExpr -> Bool
isCountExhausted registry env n cond =
    case flatCall (resolveLocal env cond) of
        Just ( fn, [ lhs, rhs ] ) ->
            isCoreFunction registry [ ( "Utils", "le" ), ( "Basics", "le" ) ] ( "Basics", "le" ) fn
                && isLocalNamed env n lhs
                && isIntLiteral env 0 rhs

        _ ->
            False


{-| Matches the `else` branch of a count loop,
`map (\x -> Loop ( n - 1, x :: acc )) item`, returning the item decoder.
-}
matchCountContinue : Mono.SpecializationRegistry -> LoopEnv -> String -> String -> Mono.MonoExpr -> Maybe DecoderNode
matchCountContinue registry env0 n acc expr =
    viewMap registry env0 expr
        |> Maybe.andThen
            (\( env, fnExpr, itemExpr ) ->
                case resolveLocal env fnExpr of
                    Mono.MonoClosure info fnBody _ ->
                        case info.params of
                            [ ( x, _ ) ] ->
                                let
                                    ( fnEnv, loopExpr ) =
                                        peelBindings env fnBody
                                in
                                case viewCtorArg registry fnEnv "Loop" loopExpr |> Maybe.map (resolveLocal fnEnv) of
                                    Just (Mono.MonoTupleCreate _ [ nextCount, nextAcc ] _) ->
                                        if isDecrement registry fnEnv n nextCount && isConsOnto registry fnEnv x acc nextAcc then
                                            fixedWidthItem registry env itemExpr

                                        else
                                            Nothing

                                    _ ->
                                        Nothing

                            _ ->
                                Nothing

                    _ ->
                        Nothing
            )


{-| Returns whether `expr` is `n - 1`.
-}
isDecrement : Mono.SpecializationRegistry -> LoopEnv -> String -> Mono.MonoExpr -> Bool
isDecrement registry env n expr =
    case flatCall (resolveLocal env expr) of
        Just ( fn, [ lhs, rhs ] ) ->
            isCoreFunction registry [ ( "Basics", "sub" ) ] ( "Basics", "sub" ) fn
                && isLocalNamed env n lhs
                && isIntLiteral env 1 rhs

        _ ->
            False


{-| Returns whether `expr` is `x :: acc`.
-}
isConsOnto : Mono.SpecializationRegistry -> LoopEnv -> String -> String -> Mono.MonoExpr -> Bool
isConsOnto registry env x acc expr =
    case flatCall (resolveLocal env expr) of
        Just ( fn, [ hd, tl ] ) ->
            isCoreListFunction registry "cons" fn
                && isLocalNamed env x hd
                && isLocalNamed env acc tl

        _ ->
            False


{-| Matches `succeed (Done result)` where `result` is `acc` or
`List.reverse acc`, returning the order of the list it returns.
-}
matchDoneSucceed : Mono.SpecializationRegistry -> LoopEnv -> String -> Mono.MonoExpr -> Maybe IR.ListOrder
matchDoneSucceed registry env0 acc expr =
    viewSucceed registry env0 expr
        |> Maybe.andThen
            (\( env, value ) ->
                viewCtorArg registry env "Done" value
                    |> Maybe.andThen
                        (\result ->
                            if isLocalNamed env acc result then
                                Just IR.ReverseReadOrder

                            else
                                case flatCall (resolveLocal env result) of
                                    Just ( fn, [ arg ] ) ->
                                        if isCoreListFunction registry "reverse" fn && isLocalNamed env acc arg then
                                            Just IR.InReadOrder

                                        else
                                            Nothing

                                    _ ->
                                        Nothing
                        )
            )


{-| Matches the step function of a sentinel loop (see `reifyLoop`), returning
the sentinel, the order of the list it builds and its item decoder.
-}
matchSentinelStep : Mono.SpecializationRegistry -> LoopEnv -> Mono.MonoExpr -> Maybe ( Int, IR.ListOrder, DecoderNode )
matchSentinelStep registry env0 stepFnExpr =
    case resolveLocal env0 stepFnExpr of
        Mono.MonoClosure info body _ ->
            case info.params of
                [ ( acc, _ ) ] ->
                    viewAndThen registry env0 body
                        |> Maybe.andThen (matchSentinelCallback registry acc)

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Matches the callback and item decoder of a sentinel loop's `andThen`.
-}
matchSentinelCallback : Mono.SpecializationRegistry -> String -> ( LoopEnv, Mono.MonoExpr, Mono.MonoExpr ) -> Maybe ( Int, IR.ListOrder, DecoderNode )
matchSentinelCallback registry acc ( env, callbackExpr, itemExpr ) =
    case resolveLocal env callbackExpr of
        Mono.MonoClosure info cbBody _ ->
            case info.params of
                [ ( b, _ ) ] ->
                    let
                        ( cbEnv, inner ) =
                            peelBindings env cbBody
                    in
                    case inner of
                        Mono.MonoIf [ ( cond, thenExpr ) ] elseExpr _ ->
                            Maybe.map3 (\sentinel order item -> ( sentinel, order, item ))
                                (sentinelOf registry cbEnv b cond)
                                (matchDoneSucceed registry cbEnv acc thenExpr)
                                (if matchSentinelContinue registry cbEnv b acc elseExpr then
                                    integerItem registry env itemExpr

                                 else
                                    Nothing
                                )

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the sentinel `s` when `cond` is `b == s` or `s == b` with `s` an
`Int` literal.
-}
sentinelOf : Mono.SpecializationRegistry -> LoopEnv -> String -> Mono.MonoExpr -> Maybe Int
sentinelOf registry env b cond =
    case flatCall (resolveLocal env cond) of
        Just ( fn, [ lhs, rhs ] ) ->
            if isCoreFunction registry [ ( "Utils", "equal" ), ( "Utils", "eq" ), ( "Basics", "eq" ) ] ( "Basics", "eq" ) fn then
                if isLocalNamed env b lhs then
                    intLiteral env rhs

                else if isLocalNamed env b rhs then
                    intLiteral env lhs

                else
                    Nothing

            else
                Nothing

        _ ->
            Nothing


{-| Returns whether `expr` is `succeed (Loop (b :: acc))`.
-}
matchSentinelContinue : Mono.SpecializationRegistry -> LoopEnv -> String -> String -> Mono.MonoExpr -> Bool
matchSentinelContinue registry env0 b acc expr =
    case viewSucceed registry env0 expr of
        Just ( env, value ) ->
            case viewCtorArg registry env "Loop" value of
                Just next ->
                    isConsOnto registry env b acc next

                Nothing ->
                    False

        Nothing ->
            False


{-| Returns the item decoder of a loop when `itemExpr` reifies to one
fixed-width read, and `Nothing` otherwise.
-}
fixedWidthItem : Mono.SpecializationRegistry -> LoopEnv -> Mono.MonoExpr -> Maybe DecoderNode
fixedWidthItem registry env itemExpr =
    case reifyDecoder registry env.lets (resolveLocal env itemExpr) of
        Just node ->
            if isFixedWidthRead node then
                Just node

            else
                Nothing

        Nothing ->
            Nothing


{-| Returns the item decoder of a sentinel loop when `itemExpr` reifies to one
fixed-width integer read, and `Nothing` otherwise.
-}
integerItem : Mono.SpecializationRegistry -> LoopEnv -> Mono.MonoExpr -> Maybe DecoderNode
integerItem registry env itemExpr =
    fixedWidthItem registry env itemExpr
        |> Maybe.andThen
            (\node ->
                case node of
                    DF32 _ ->
                        Nothing

                    DF64 _ ->
                        Nothing

                    _ ->
                        Just node
            )


{-| Returns whether `node` is a single fixed-width primitive read.
-}
isFixedWidthRead : DecoderNode -> Bool
isFixedWidthRead node =
    case node of
        DU8 ->
            True

        DS8 ->
            True

        DU16 _ ->
            True

        DS16 _ ->
            True

        DU32 _ ->
            True

        DS32 _ ->
            True

        DF32 _ ->
            True

        DF64 _ ->
            True

        _ ->
            False



-- DECODER COMBINATOR VIEWS
--
-- `viewSucceed`, `viewMap` and `viewAndThen` each recognise one elm/bytes
-- combinator both as a call of the `Bytes.Decode` global and in its inlined
-- form, a `Decoder` constructor applied to the closure of the combinator's
-- body. They return the environment extended with the bindings they looked
-- through.


{-| Returns the value when `expr` is `succeed value`, as a call or inlined as
`Decoder (\_ offset -> ( offset, value ))`.
-}
viewSucceed : Mono.SpecializationRegistry -> LoopEnv -> Mono.MonoExpr -> Maybe ( LoopEnv, Mono.MonoExpr )
viewSucceed registry env0 expr =
    let
        ( env, inner ) =
            peelBindings env0 (resolveLocal env0 expr)
    in
    case flatCall inner of
        Just ( fn, [ arg ] ) ->
            if isBytesDecodeGlobal registry "succeed" fn then
                Just ( env, arg )

            else if isBytesDecodeGlobal registry "Decoder" fn then
                case resolveLocal env arg of
                    Mono.MonoClosure info body _ ->
                        case info.params of
                            [ _, ( offset, _ ) ] ->
                                let
                                    ( bodyEnv, result ) =
                                        peelBindings env body
                                in
                                case result of
                                    Mono.MonoTupleCreate _ [ off, value ] _ ->
                                        if isLocalNamed bodyEnv offset off then
                                            Just ( bodyEnv, value )

                                        else
                                            Nothing

                                    _ ->
                                        Nothing

                            _ ->
                                Nothing

                    _ ->
                        Nothing

            else
                Nothing

        _ ->
            Nothing


{-| Returns the function and the decoder when `expr` is `map fn decoder`, as a
call or inlined as

    let
        (Decoder decodeA) =
            decoder
    in
    Decoder
        (\bites offset ->
            let
                ( aOffset, a ) =
                    decodeA bites offset
            in
            ( aOffset, fn a )
        )

-}
viewMap : Mono.SpecializationRegistry -> LoopEnv -> Mono.MonoExpr -> Maybe ( LoopEnv, Mono.MonoExpr, Mono.MonoExpr )
viewMap registry env0 expr =
    let
        ( env, inner ) =
            peelBindings env0 (resolveLocal env0 expr)
    in
    case flatCall inner of
        Just ( fn, [ fnExpr, decoderExpr ] ) ->
            if isBytesDecodeGlobal registry "map" fn then
                Just ( env, fnExpr, decoderExpr )

            else
                Nothing

        Just ( fn, [ arg ] ) ->
            if isBytesDecodeGlobal registry "Decoder" fn then
                viewInlinedRun env arg
                    |> Maybe.andThen
                        (\run ->
                            case run.result of
                                Mono.MonoTupleCreate _ [ off, applied ] _ ->
                                    if isLocalNamed run.env run.offsetName off then
                                        case flatCall (resolveLocal run.env applied) of
                                            Just ( mapFn, [ a ] ) ->
                                                if isLocalNamed run.env run.valueName a then
                                                    Just ( run.env, mapFn, run.decoder )

                                                else
                                                    Nothing

                                            _ ->
                                                Nothing

                                    else
                                        Nothing

                                _ ->
                                    Nothing
                        )

            else
                Nothing

        _ ->
            Nothing


{-| Returns the callback and the decoder when `expr` is
`andThen callback decoder`, as a call or inlined as

    let
        (Decoder decodeA) =
            decoder
    in
    Decoder
        (\bites offset ->
            let
                ( aOffset, a ) =
                    decodeA bites offset

                (Decoder decodeB) =
                    callback a
            in
            decodeB bites aOffset
        )

-}
viewAndThen : Mono.SpecializationRegistry -> LoopEnv -> Mono.MonoExpr -> Maybe ( LoopEnv, Mono.MonoExpr, Mono.MonoExpr )
viewAndThen registry env0 expr =
    let
        ( env, inner ) =
            peelBindings env0 (resolveLocal env0 expr)
    in
    case flatCall inner of
        Just ( fn, [ callbackExpr, decoderExpr ] ) ->
            if isBytesDecodeGlobal registry "andThen" fn then
                Just ( env, callbackExpr, decoderExpr )

            else
                Nothing

        Just ( fn, [ arg ] ) ->
            if isBytesDecodeGlobal registry "Decoder" fn then
                viewInlinedRun env arg
                    |> Maybe.andThen
                        (\run ->
                            case flatCall run.result of
                                Just ( Mono.MonoVarLocal decodeB _, [ bites, off ] ) ->
                                    case ( unboxedRoot run.env decodeB, isLocalNamed run.env run.bitesName bites, isLocalNamed run.env run.offsetName off ) of
                                        ( Just nextDecoder, True, True ) ->
                                            case flatCall (resolveLocal run.env (Mono.MonoVarLocal nextDecoder Mono.MUnit)) of
                                                Just ( callback, [ a ] ) ->
                                                    if isLocalNamed run.env run.valueName a then
                                                        Just ( run.env, callback, run.decoder )

                                                    else
                                                        Nothing

                                                _ ->
                                                    Nothing

                                        _ ->
                                            Nothing

                                _ ->
                                    Nothing
                        )

            else
                Nothing

        _ ->
            Nothing


{-| Matches the common head of an inlined `map` or `andThen`: a closure
`\bites offset -> let ( aOffset, a ) = decodeA bites offset in ...` whose
`decodeA` was taken out of a decoder variable with `let (Decoder decodeA) = ...`.
Returns that decoder variable, the names of `bites`, `aOffset` and `a`, the
expression under the bindings and the environment.
-}
viewInlinedRun :
    LoopEnv
    -> Mono.MonoExpr
    ->
        Maybe
            { env : LoopEnv
            , decoder : Mono.MonoExpr
            , bitesName : String
            , offsetName : String
            , valueName : String
            , result : Mono.MonoExpr
            }
viewInlinedRun env arg =
    case resolveLocal env arg of
        Mono.MonoClosure info body _ ->
            case info.params of
                [ ( bites, _ ), ( offset, _ ) ] ->
                    let
                        -- The destructurings made inside the closure, kept
                        -- apart so that a tuple destructured outside it (a
                        -- loop's state) cannot be mistaken for this one.
                        ( localEnv, result ) =
                            peelBindings { env | paths = Dict.empty } body

                        bodyEnv =
                            { localEnv | paths = Dict.union localEnv.paths env.paths }

                        tupleComponent index =
                            Dict.foldl
                                (\name path found ->
                                    case path of
                                        Mono.MonoIndex i Mono.Tuple2Container _ (Mono.MonoRoot root _) ->
                                            if i == index then
                                                Just ( name, root )

                                            else
                                                found

                                        _ ->
                                            found
                                )
                                Nothing
                                localEnv.paths
                    in
                    case ( tupleComponent 0, tupleComponent 1 ) of
                        ( Just ( aOffset, root0 ), Just ( a, root1 ) ) ->
                            if root0 == root1 then
                                case flatCall (resolveLocal bodyEnv (Mono.MonoVarLocal root0 Mono.MUnit)) of
                                    Just ( Mono.MonoVarLocal decodeA _, [ bitesArg, offsetArg ] ) ->
                                        case unboxedRoot bodyEnv decodeA of
                                            Just decoderName ->
                                                if isLocalNamed bodyEnv bites bitesArg && isLocalNamed bodyEnv offset offsetArg then
                                                    Just
                                                        { env = bodyEnv
                                                        , decoder = Mono.MonoVarLocal decoderName Mono.MUnit
                                                        , bitesName = bites
                                                        , offsetName = aOffset
                                                        , valueName = a
                                                        , result = result
                                                        }

                                                else
                                                    Nothing

                                            Nothing ->
                                                Nothing

                                    _ ->
                                        Nothing

                            else
                                Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Returns the name of the variable `var` when `name` was bound by
unwrapping a single-constructor value held in `var`, as in
`let (Decoder name) = var`.
-}
unboxedRoot : LoopEnv -> String -> Maybe String
unboxedRoot env name =
    case Dict.get name env.paths of
        Just (Mono.MonoUnbox _ (Mono.MonoRoot root _)) ->
            Just root

        _ ->
            Nothing


{-| Returns the argument when `expr` is a call of the `Bytes.Decode`
constructor `ctorName` (`Done` or `Loop`) to one argument.
-}
viewCtorArg : Mono.SpecializationRegistry -> LoopEnv -> String -> Mono.MonoExpr -> Maybe Mono.MonoExpr
viewCtorArg registry env ctorName expr =
    case flatCall (resolveLocal env expr) of
        Just ( fn, [ arg ] ) ->
            if isBytesDecodeGlobal registry ctorName fn then
                Just arg

            else
                Nothing

        _ ->
            Nothing



-- SMALL MATCHERS


{-| Returns a call's function and all its arguments, with a curried call
`(f a) b` flattened to `f a b`, or `Nothing` when `expr` is not a call.
-}
flatCall : Mono.MonoExpr -> Maybe ( Mono.MonoExpr, List Mono.MonoExpr )
flatCall expr =
    case expr of
        Mono.MonoCall _ fn args _ _ ->
            case flatCall fn of
                Just ( innerFn, innerArgs ) ->
                    Just ( innerFn, innerArgs ++ args )

                Nothing ->
                    Just ( fn, args )

        _ ->
            Nothing


{-| Returns whether `expr` is the local variable `name`, directly or through
one `let` that binds it to `name`.
-}
isLocalNamed : LoopEnv -> String -> Mono.MonoExpr -> Bool
isLocalNamed env name expr =
    case expr of
        Mono.MonoVarLocal n _ ->
            n == name || isLocalNamedVia env name n

        _ ->
            False


{-| Returns whether a `let` in `env` binds `n` directly to the local
variable `name`. Only one step is followed.
-}
isLocalNamedVia : LoopEnv -> String -> String -> Bool
isLocalNamedVia env name n =
    case Dict.get n env.lets of
        Just (Mono.MonoVarLocal m _) ->
            m == name

        _ ->
            False


{-| Returns the value of `expr` when it is an `Int` literal, directly or
through `let`s.
-}
intLiteral : LoopEnv -> Mono.MonoExpr -> Maybe Int
intLiteral env expr =
    case resolveLocal env expr of
        Mono.MonoLiteral (Mono.LInt n) _ ->
            Just n

        _ ->
            Nothing


{-| Returns whether `expr` is the `Int` literal `value`, directly or
through `let`s.
-}
isIntLiteral : LoopEnv -> Int -> Mono.MonoExpr -> Bool
isIntLiteral env value expr =
    intLiteral env expr == Just value


{-| Returns whether `fn` is the `Bytes.Decode` global `name`.
-}
isBytesDecodeGlobal : Mono.SpecializationRegistry -> String -> Mono.MonoExpr -> Bool
isBytesDecodeGlobal registry name fn =
    case fn of
        Mono.MonoVarGlobal _ specId _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg moduleName) globalName, _ ) ->
                    pkg == Pkg.bytes && moduleName == "Bytes.Decode" && globalName == name

                _ ->
                    False

        _ ->
            False


{-| Returns whether `fn` is the elm/core global `( moduleName, name )` or one
of the kernels `( kernelHome, kernelName )` it is an alias of.
-}
isCoreFunction : Mono.SpecializationRegistry -> List ( String, String ) -> ( String, String ) -> Mono.MonoExpr -> Bool
isCoreFunction registry kernels ( moduleName, name ) fn =
    case fn of
        Mono.MonoVarKernel _ _ home kernelName _ ->
            List.member ( home, kernelName ) kernels

        Mono.MonoVarGlobal _ specId _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (ModuleName.Canonical pkg globalModule) globalName, _ ) ->
                    pkg == Pkg.core && globalModule == moduleName && globalName == name

                _ ->
                    False

        _ ->
            False


{-| Returns whether `fn` is `List.name` (`cons` or `reverse`), as the
elm/core global or the `List` kernel of that name.
-}
isCoreListFunction : Mono.SpecializationRegistry -> String -> Mono.MonoExpr -> Bool
isCoreListFunction registry name fn =
    isCoreFunction registry [ ( "List", name ) ] ( "List", name ) fn


{-| Applies `fn` to the four values when all are present, as `Maybe.map4`
would.
-}
map4 : (a -> b -> c -> d -> e) -> Maybe a -> Maybe b -> Maybe c -> Maybe d -> Maybe e
map4 fn ma mb mc md =
    case ma of
        Nothing ->
            Nothing

        Just a ->
            case mb of
                Nothing ->
                    Nothing

                Just b ->
                    case mc of
                        Nothing ->
                            Nothing

                        Just c ->
                            case md of
                                Nothing ->
                                    Nothing

                                Just d ->
                                    Just (fn a b c d)


{-| Applies `fn` to the five values when all are present, as `Maybe.map5`
would.
-}
map5 : (a -> b -> c -> d -> e -> f) -> Maybe a -> Maybe b -> Maybe c -> Maybe d -> Maybe e -> Maybe f
map5 fn ma mb mc md me =
    case ma of
        Nothing ->
            Nothing

        Just a ->
            case mb of
                Nothing ->
                    Nothing

                Just b ->
                    case mc of
                        Nothing ->
                            Nothing

                        Just c ->
                            case md of
                                Nothing ->
                                    Nothing

                                Just d ->
                                    case me of
                                        Nothing ->
                                            Nothing

                                        Just e ->
                                            Just (fn a b c d e)



-- ============================================================================
-- Decoder Node to Ops Compilation
-- ============================================================================


{-| The state threaded through the flattening of a `DecoderNode` into
operations.

`ops` holds the operations emitted so far, most recent first. `varCounter`
numbers the next placeholder. `paramBindings` maps the parameter name of every
`andThen` compiled so far to the placeholder of its first decoder's result.

-}
type alias DecoderCompileState =
    { cursorName : String
    , varCounter : Int
    , ops : List IR.DecoderOp
    , paramBindings : Dict String String
    }


{-| Returns the Loop IR decoder for `node`, with the placeholder of its result.

The operations start with an `InitReadCursor` on the cursor `"dcur"` and end
with `ReturnJust` of the result. The `InitReadCursor`'s input expression is a
placeholder `MonoUnit`, not the bytes to decode, which this module never sees.

Inside an `andThen`, a length or loop count that is the callback's parameter is
taken from the placeholder of the first decoder's result.

-}
decoderNodeToOps : DecoderNode -> ( List IR.DecoderOp, String )
decoderNodeToOps node =
    let
        cursorName =
            "dcur"

        dummyBytesExpr =
            Mono.MonoUnit

        initialState =
            { cursorName = cursorName
            , varCounter = 0
            , ops = [ IR.InitReadCursor cursorName dummyBytesExpr ]
            , paramBindings = Dict.empty
            }

        ( resultVar, finalState ) =
            compileDecoderNode node initialState
    in
    ( List.reverse finalState.ops ++ [ IR.ReturnJust resultVar ], resultVar )


{-| Adds the operations for `node` to `state`, and returns the placeholder of
its result.

Child decoders are flattened in order before the operation that combines them.
A `DFail` adds a `ReturnNothing` and returns the placeholder `"fail"`, which
names no result. A loop's item decoder is flattened separately, and its
operations go inside the loop operation.

-}
compileDecoderNode : DecoderNode -> DecoderCompileState -> ( String, DecoderCompileState )
compileDecoderNode node state =
    case node of
        DU8 ->
            let
                ( resultVar, state1 ) =
                    freshVar "u8" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadU8 state.cursorName resultVar :: state1.ops }
            )

        DS8 ->
            let
                ( resultVar, state1 ) =
                    freshVar "i8" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadI8 state.cursorName resultVar :: state1.ops }
            )

        DU16 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "u16" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadU16 state.cursorName endian resultVar :: state1.ops }
            )

        DS16 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "i16" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadI16 state.cursorName endian resultVar :: state1.ops }
            )

        DU32 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "u32" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadU32 state.cursorName endian resultVar :: state1.ops }
            )

        DS32 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "i32" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadI32 state.cursorName endian resultVar :: state1.ops }
            )

        DF32 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "f32" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadF32 state.cursorName endian resultVar :: state1.ops }
            )

        DF64 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "f64" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadF64 state.cursorName endian resultVar :: state1.ops }
            )

        DBytes lenExpr ->
            let
                ( resultVar, state1 ) =
                    freshVar "bytes" state
            in
            case getParamBinding lenExpr state.paramBindings of
                Just lenVarName ->
                    ( resultVar
                    , { state1 | ops = IR.ReadBytesVar state.cursorName lenVarName resultVar :: state1.ops }
                    )

                Nothing ->
                    ( resultVar
                    , { state1 | ops = IR.ReadBytes state.cursorName lenExpr resultVar :: state1.ops }
                    )

        DString lenExpr ->
            let
                ( resultVar, state1 ) =
                    freshVar "str" state
            in
            case getParamBinding lenExpr state.paramBindings of
                Just lenVarName ->
                    ( resultVar
                    , { state1 | ops = IR.ReadUtf8Var state.cursorName lenVarName resultVar :: state1.ops }
                    )

                Nothing ->
                    ( resultVar
                    , { state1 | ops = IR.ReadUtf8 state.cursorName lenExpr resultVar :: state1.ops }
                    )

        DSucceed valueExpr ->
            let
                ( resultVar, state1 ) =
                    freshVar "val" state
            in
            ( resultVar
            , { state1 | ops = IR.PushValue valueExpr resultVar :: state1.ops }
            )

        DFail ->
            ( "fail", { state | ops = IR.ReturnNothing :: state.ops } )

        DMap fnExpr innerNode ->
            let
                ( innerVar, state1 ) =
                    compileDecoderNode innerNode state

                ( resultVar, state2 ) =
                    freshVar "map" state1
            in
            ( resultVar
            , { state2 | ops = IR.Apply1 fnExpr innerVar resultVar :: state2.ops }
            )

        DMap2 fnExpr d1 d2 ->
            let
                ( var1, state1 ) =
                    compileDecoderNode d1 state

                ( var2, state2 ) =
                    compileDecoderNode d2 state1

                ( resultVar, state3 ) =
                    freshVar "map2" state2
            in
            ( resultVar
            , { state3 | ops = IR.Apply2 fnExpr var1 var2 resultVar :: state3.ops }
            )

        DMap3 fnExpr d1 d2 d3 ->
            let
                ( var1, state1 ) =
                    compileDecoderNode d1 state

                ( var2, state2 ) =
                    compileDecoderNode d2 state1

                ( var3, state3 ) =
                    compileDecoderNode d3 state2

                ( resultVar, state4 ) =
                    freshVar "map3" state3
            in
            ( resultVar
            , { state4 | ops = IR.Apply3 fnExpr var1 var2 var3 resultVar :: state4.ops }
            )

        DMap4 fnExpr d1 d2 d3 d4 ->
            let
                ( var1, state1 ) =
                    compileDecoderNode d1 state

                ( var2, state2 ) =
                    compileDecoderNode d2 state1

                ( var3, state3 ) =
                    compileDecoderNode d3 state2

                ( var4, state4 ) =
                    compileDecoderNode d4 state3

                ( resultVar, state5 ) =
                    freshVar "map4" state4
            in
            ( resultVar
            , { state5 | ops = IR.Apply4 fnExpr var1 var2 var3 var4 resultVar :: state5.ops }
            )

        DMap5 fnExpr d1 d2 d3 d4 d5 ->
            let
                ( var1, state1 ) =
                    compileDecoderNode d1 state

                ( var2, state2 ) =
                    compileDecoderNode d2 state1

                ( var3, state3 ) =
                    compileDecoderNode d3 state2

                ( var4, state4 ) =
                    compileDecoderNode d4 state3

                ( var5, state5 ) =
                    compileDecoderNode d5 state4

                ( resultVar, state6 ) =
                    freshVar "map5" state5
            in
            ( resultVar
            , { state6 | ops = IR.Apply5 fnExpr var1 var2 var3 var4 var5 resultVar :: state6.ops }
            )

        DLengthPrefixedString lenDecoder ->
            let
                ( lenVar, state1 ) =
                    compileLengthDecoder lenDecoder state

                ( resultVar, state2 ) =
                    freshVar "lpstr" state1
            in
            ( resultVar
            , { state2 | ops = IR.ReadUtf8Var state.cursorName lenVar resultVar :: state2.ops }
            )

        DLengthPrefixedBytes lenDecoder ->
            let
                ( lenVar, state1 ) =
                    compileLengthDecoder lenDecoder state

                ( resultVar, state2 ) =
                    freshVar "lpbytes" state1
            in
            ( resultVar
            , { state2 | ops = IR.ReadBytesVar state.cursorName lenVar resultVar :: state2.ops }
            )

        DAndThen firstDecoder paramName bodyDecoder ->
            let
                ( firstVar, state1 ) =
                    compileDecoderNode firstDecoder state

                -- Only a length or a loop count consults this binding; a
                -- residual expression that mentions the parameter does not.
                stateWithBinding =
                    { state1 | paramBindings = Dict.insert paramName firstVar state1.paramBindings }
            in
            compileDecoderNode bodyDecoder stateWithBinding

        DCountLoop countSource order itemDecoder ->
            let
                itemState =
                    { cursorName = state.cursorName
                    , varCounter = state.varCounter
                    , ops = []
                    , paramBindings = state.paramBindings
                    }

                ( _, itemStateAfter ) =
                    compileDecoderNode itemDecoder itemState

                itemOps =
                    List.reverse itemStateAfter.ops

                ( resultVar, state1 ) =
                    freshVar "list" { state | varCounter = itemStateAfter.varCounter }

                -- A variable bound by an enclosing andThen is the result of an
                -- earlier read; any other variable is compiled where the loop
                -- is emitted.
                count =
                    case countSource of
                        CountFromVar varName ->
                            case Dict.get varName state.paramBindings of
                                Just placeholder ->
                                    IR.CountPlaceholder placeholder

                                Nothing ->
                                    IR.CountExpression (Mono.MonoVarLocal varName Mono.MInt)

                        CountConst n ->
                            IR.CountLiteral n
            in
            ( resultVar
            , { state1
                | ops =
                    IR.LoopDecodeList count state.cursorName itemOps order resultVar
                        :: state1.ops
              }
            )

        DSentinelLoop sentinel order itemDecoder ->
            let
                itemState =
                    { cursorName = state.cursorName
                    , varCounter = state.varCounter
                    , ops = []
                    , paramBindings = state.paramBindings
                    }

                ( _, itemStateAfter ) =
                    compileDecoderNode itemDecoder itemState

                itemOps =
                    List.reverse itemStateAfter.ops

                ( resultVar, state1 ) =
                    freshVar "list" { state | varCounter = itemStateAfter.varCounter }
            in
            ( resultVar
            , { state1
                | ops =
                    IR.LoopSentinelDecodeList sentinel state.cursorName itemOps order resultVar
                        :: state1.ops
              }
            )


{-| Adds the integer read for `lenDecoder` to `state`, and returns the
placeholder of the length it reads.
-}
compileLengthDecoder : LengthDecoder -> DecoderCompileState -> ( String, DecoderCompileState )
compileLengthDecoder lenDecoder state =
    case lenDecoder of
        LenU8 ->
            let
                ( resultVar, state1 ) =
                    freshVar "len8" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadU8 state.cursorName resultVar :: state1.ops }
            )

        LenI8 ->
            let
                ( resultVar, state1 ) =
                    freshVar "len8" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadI8 state.cursorName resultVar :: state1.ops }
            )

        LenU16 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "len16" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadU16 state.cursorName endian resultVar :: state1.ops }
            )

        LenI16 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "len16" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadI16 state.cursorName endian resultVar :: state1.ops }
            )

        LenU32 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "len32" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadU32 state.cursorName endian resultVar :: state1.ops }
            )

        LenI32 endian ->
            let
                ( resultVar, state1 ) =
                    freshVar "len32" state
            in
            ( resultVar
            , { state1 | ops = IR.ReadI32 state.cursorName endian resultVar :: state1.ops }
            )


{-| Returns a new placeholder, `prefix` followed by `_` and the next number,
and the state with that number used.
-}
freshVar : String -> DecoderCompileState -> ( String, DecoderCompileState )
freshVar prefix state =
    ( prefix ++ "_" ++ String.fromInt state.varCounter
    , { state | varCounter = state.varCounter + 1 }
    )


{-| Returns the placeholder bound to `expr` in `bindings` when `expr` is a local
variable with a binding there.
-}
getParamBinding : MonoExpr -> Dict String String -> Maybe String
getParamBinding expr bindings =
    case expr of
        MonoVarLocal varName _ ->
            Dict.get varName bindings

        _ ->
            Nothing
