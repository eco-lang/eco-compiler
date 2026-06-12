module Compiler.Generate.MLIR.BytesFusion.Reify exposing
    ( EncoderNode(..), DecoderNode(..), BodyLookup
    , reifyEncoderWith, reifyDecoder
    , nodesToOps, decoderNodeToOps
    , CountSource, LengthDecoder
    )

{-| Reify MonoExpr representing Bytes.Encode.Encoder or Bytes.Decode.Decoder
into normalized operation structures.

This is a PURE AST RECOGNIZER that pattern-matches the monomorphized
expression tree to identify Bytes.Encode/Decode combinator calls.


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
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (Endianness(..), Op(..), WidthExpr(..))
import Compiler.Monomorphize.Registry as Registry
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| `SpecId -> Maybe (params, body)` lookup over the post-inline
MonoGraph, excluding recursive specs. Supplied by codegen at the
fusion entry; consumed by `reifyMapBody`'s `MonoVarGlobal` arm to
beta-reduce per-element encoder functions (closure-converted inline
lambdas, `Utils.Bytes.Encode.string`, etc.) against a synthetic
iteration variable.

Empty `Dict.empty` is safe — `reifyMapBody` will just fall through to
the `Nothing` arm and ELoop fusion is suppressed for that site.

-}
type alias BodyLookup =
    Dict Int ( List ( Name, Mono.MonoType ), Mono.MonoExpr )


{-| Normalized encoder node (after flattening sequences).

`ELoop` is the length-prefixed dynamic-list encoder shape:

    BE.sequence (BE.unsignedInt32 endian (List.length xs) :: List.map mapFn xs)

The reifier produces an `ELoop` when it matches that shape with `mapFn`
being a `MonoClosure` whose body reifies to a constant-width sequence of
EncoderNodes. `itemVar` is the lambda's parameter name (bound to each
cons head during the loop), `itemNodes` is the reified body, `iterExpr`
is the source list (`xs`), `countExpr` is the `List.length xs` MonoExpr
extracted from the header (reused for the buffer pre-allocation so we
don't evaluate `List.length` twice).

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
        , itemNodes : List EncoderNode
        , iterExpr : Mono.MonoExpr
        , countExpr : Mono.MonoExpr
        }
      -- Escape hatch: an encoder subtree the reifier doesn't recognise.
      -- Lowers to bf.write.encoder (runtime call to the existing
      -- writeEncoder walker against the current cursor). Width comes
      -- from bf.encoder.width (runtime call to encoderSize). Allows
      -- partial fusion of expressions that contain unfusable subtrees
      -- (e.g. HO mapFn passes a function-typed parameter that Phase 5
      -- can't statically resolve).
    | EOpaque Mono.MonoExpr


{-| Normalized decoder node.

Phase 2 supports: primitive reads, map/map2-5, succeed, fail.
Phase 3 adds: andThen
Phase 4 adds: loop

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
    | DBytes Mono.MonoExpr -- length expression
    | DString Mono.MonoExpr -- length expression
    | DSucceed Mono.MonoExpr -- value expression
    | DFail
    | DMap Mono.MonoExpr DecoderNode -- fn, inner decoder
    | DMap2 Mono.MonoExpr DecoderNode DecoderNode
    | DMap3 Mono.MonoExpr DecoderNode DecoderNode DecoderNode
    | DMap4 Mono.MonoExpr DecoderNode DecoderNode DecoderNode DecoderNode
    | DMap5 Mono.MonoExpr DecoderNode DecoderNode DecoderNode DecoderNode DecoderNode
      -- Phase 3: andThen support
    | DLengthPrefixedString LengthDecoder -- Read length, then string
    | DLengthPrefixedBytes LengthDecoder -- Read length, then bytes
    | DAndThen DecoderNode String DecoderNode -- firstDecoder, paramName, bodyDecoder
      -- Phase 4: loop support
    | DCountLoop CountSource DecoderNode -- count source, item decoder
    | DSentinelLoop Int DecoderNode -- sentinel value (e.g. 0), item decoder


{-| How to decode the length value for length-prefixed patterns.
-}
type LengthDecoder
    = LenU8
    | LenU16 Endianness
    | LenU32 Endianness
    | LenI8
    | LenI16 Endianness
    | LenI32 Endianness


{-| Source of count for count-based loops.
-}
type CountSource
    = CountFromVar String -- Count from previously decoded variable
    | CountConst Int -- Fixed count (rare)


{-| Like `reifyEncoder` but with the inliner's body-lookup table.

Required for `reifyMapBody`'s `MonoVarGlobal` arm: closure conversion
turns inline lambdas into top-level functions, and the typical Eco
pattern (`Utils.Bytes.Encode.list Utils.Bytes.Encode.string xs`)
already uses named helpers. Without this, ELoop fusion fires only on
the pure-`MonoClosure` mapFn case, which is rare post-monomorphization.

The table is the same one consumed by the inliner — non-recursive,
`getInlinableBody`-eligible specs only. Other shapes fall through and
the reifier falls back to the kernel call.

-}
reifyEncoderWith : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderWith bodyLookup registry exprCache expr =
    case reifyEncoderHelp bodyLookup registry exprCache expr of
        -- All-opaque short-circuit: the only reified node is the whole
        -- encoder treated as one EOpaque. Wrapping a single kernel-call
        -- in bf.alloc + bf.write.encoder + ReturnBuffer is strictly
        -- more expensive than calling the kernel directly. Return
        -- Nothing so the caller's existing kernel-call fallback fires.
        Just [ EOpaque _ ] ->
            Nothing

        result ->
            -- Per-call (fused, opaque) diagnostics: see
            -- plans/bytes-fusion-escape-hatch.md step 6. To enable, drop
            -- a `Debug.log "BFReify (fused, opaque)" (countNodes result)`
            -- in here for a one-off bootstrap run, then strip before
            -- merging (the `--optimize` bootstrap step rejects any
            -- `Debug.*` reference in compiler-side Elm).
            result


{-| Internal helper that returns nested structure. Always returns Just
(never Nothing) — unrecognised shapes are wrapped as `EOpaque expr` by
the wrapper around `reifyEncoderHelpStrict`. The wrapper is what makes
partial fusion possible: a subtree that fails reification becomes a
single `EOpaque` leaf instead of poisoning the whole expression.
-}
reifyEncoderHelp : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderHelp bodyLookup registry exprCache expr =
    case reifyEncoderHelpStrict bodyLookup registry exprCache expr of
        Just result ->
            Just result

        Nothing ->
            -- Escape hatch: subtree the reifier doesn't statically
            -- recognise. The runtime walker (writeEncoder) handles it
            -- via the bf.write.encoder lowering. The current cursor
            -- threads through; the outer fused encoder still gets a
            -- single bf.alloc + cursor.init + writes + ReturnBuffer
            -- sequence.
            Just [ EOpaque expr ]


{-| Strict reification helper. Returns `Nothing` on unrecognised shapes
so the wrapper `reifyEncoderHelp` can convert them to `EOpaque`.
-}
reifyEncoderHelpStrict : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderHelpStrict bodyLookup registry exprCache expr =
    case expr of
        -- Call to a Bytes.Encode function
        Mono.MonoCall _ func args _ _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Encode" then
                                reifyBytesEncodeCall bodyLookup registry exprCache name args

                            else
                                -- Not a Bytes.Encode function
                                Nothing

                        _ ->
                            Nothing

                Mono.MonoVarKernel _ _ "Bytes" name _ ->
                    -- Kernel function from Bytes module
                    reifyBytesKernelCall bodyLookup registry exprCache name args

                -- Curried call: func is itself a call (e.g. from pipe operator expansion).
                -- Flatten inner args with outer args and try again.
                Mono.MonoCall _ innerFunc innerArgs _ _ ->
                    case innerFunc of
                        Mono.MonoVarGlobal _ innerSpecId _ ->
                            case Registry.lookupSpecKey innerSpecId registry of
                                Just ( Mono.Global (IO.Canonical pkg2 moduleName2) name2, _, _ ) ->
                                    if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Encode" then
                                        reifyBytesEncodeCall bodyLookup registry exprCache name2 (innerArgs ++ args)

                                    else
                                        Nothing

                                _ ->
                                    Nothing

                        Mono.MonoVarKernel _ _ "Bytes" name2 _ ->
                            reifyBytesKernelCall bodyLookup registry exprCache name2 (innerArgs ++ args)

                        _ ->
                            Nothing

                -- Local variable in function position: resolve from exprCache.
                Mono.MonoVarLocal funcName _ ->
                    case Dict.get funcName exprCache of
                        Just (Mono.MonoCall _ innerFunc innerArgs _ _) ->
                            case innerFunc of
                                Mono.MonoVarGlobal _ innerSpecId _ ->
                                    case Registry.lookupSpecKey innerSpecId registry of
                                        Just ( Mono.Global (IO.Canonical pkg2 moduleName2) name2, _, _ ) ->
                                            if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Encode" then
                                                reifyBytesEncodeCall bodyLookup registry exprCache name2 (innerArgs ++ args)

                                            else
                                                Nothing

                                        _ ->
                                            Nothing

                                Mono.MonoVarKernel _ _ "Bytes" name2 _ ->
                                    reifyBytesKernelCall bodyLookup registry exprCache name2 (innerArgs ++ args)

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                _ ->
                    -- Unknown function - can't reify
                    Nothing

        -- Let binding: add the binding to exprCache and recurse on the body
        Mono.MonoLet def body _ ->
            case def of
                Mono.MonoDef name defExpr ->
                    reifyEncoderHelp bodyLookup registry (Dict.insert name defExpr exprCache) body

                _ ->
                    Nothing

        -- Local variable reference - look up in exprCache
        Mono.MonoVarLocal name _ ->
            case Dict.get name exprCache of
                Just cachedExpr ->
                    reifyEncoderHelp bodyLookup registry exprCache cachedExpr

                Nothing ->
                    Nothing

        -- Variable reference - can't statically analyze
        _ ->
            Nothing


{-| Reify a call to a Bytes.Encode.\* function.
-}
reifyBytesEncodeCall : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> List Mono.MonoExpr -> Maybe (List EncoderNode)
reifyBytesEncodeCall bodyLookup registry exprCache name args =
    case ( name, args ) of
        ( "sequence", [ listExpr ] ) ->
            -- sequence : List Encoder -> Encoder
            reifyEncoderList bodyLookup registry exprCache listExpr

        ( "unsignedInt8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "signedInt8", [ valueExpr ] ) ->
            -- Signed and unsigned have same encoding for 8 bits
            Just [ EU8 valueExpr ]

        -- Constructor name after inlining: U8(value)
        ( "U8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        -- Constructor name after inlining: I8(value)
        ( "I8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "unsignedInt16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "signedInt16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        -- Constructor name after inlining: U16(endianness, value)
        ( "U16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        -- Constructor name after inlining: I16(endianness, value)
        ( "I16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "unsignedInt32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "signedInt32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        -- Constructor name after inlining: U32(endianness, value)
        ( "U32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        -- Constructor name after inlining: I32(endianness, value)
        ( "I32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "float32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF32 e valueExpr ])

        ( "float64", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF64 e valueExpr ])

        -- Constructor name after inlining: F32(endianness, value)
        ( "F32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF32 e valueExpr ])

        -- Constructor name after inlining: F64(endianness, value)
        ( "F64", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF64 e valueExpr ])

        ( "bytes", [ bytesExpr ] ) ->
            Just [ EBytes bytesExpr ]

        -- Constructor name after inlining: Bytes(bytes)
        ( "Bytes", [ bytesExpr ] ) ->
            Just [ EBytes bytesExpr ]

        ( "string", [ stringExpr ] ) ->
            Just [ EUtf8 stringExpr ]

        -- Constructor name after inlining: Utf8(width, string)
        ( "Utf8", [ _, stringExpr ] ) ->
            Just [ EUtf8 stringExpr ]

        -- Constructor name after inlining: Seq(width, list)
        ( "Seq", [ _, listExpr ] ) ->
            reifyEncoderList bodyLookup registry exprCache listExpr

        _ ->
            -- Unknown Bytes.Encode function
            Nothing


{-| Reify a kernel call (e.g., from Elm.Kernel.Bytes).
-}
reifyBytesKernelCall : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> List Mono.MonoExpr -> Maybe (List EncoderNode)
reifyBytesKernelCall _ _ _ name args =
    -- Kernel functions like write_i8, write_u16, etc.
    case ( name, args ) of
        ( "write_u8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "write_i8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        -- Add more kernel function patterns as needed
        _ ->
            Nothing


{-| Reify a list of encoders (from sequence argument).

`MonoLet` and `MonoVarLocal` cases let the reifier walk past the
synthetic `mono_inline_N` temp bindings that `MonoInlineSimplify`
introduces when it inlines a helper that returns a literal encoder
list. Without this, `BE.sequence (let mono_inline_42 = [a, b, c] in
mono_inline_42)` (and the equivalent `BE.sequence mono_inline_42` with
the let one frame up) silently bails to the kernel path and loses
fusion. The `exprCache` is the same `Dict String MonoExpr` used by
`reifyEncoderHelp`, so a `MonoVarLocal` that was bound by an outer
`MonoLet` resolves transparently.

-}
reifyEncoderList : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderList bodyLookup registry exprCache listExpr =
    case listExpr of
        Mono.MonoList _ items _ ->
            -- Literal list of encoders
            items
                |> List.map (reifyEncoderHelp bodyLookup registry exprCache)
                |> combineResults
                |> Maybe.map List.concat

        Mono.MonoCall _ funcExpr args _ _ ->
            -- Try to recognise either elm/core's List.cons or a
            -- length-prefixed `header :: List.map mapFn xs` shape.
            case ( reifyListConsCall registry funcExpr args, args ) of
                ( Just ( headerExpr, tailExpr ), _ ) ->
                    reifyLengthPrefixedLoop bodyLookup registry exprCache headerExpr tailExpr

                _ ->
                    Nothing

        -- Walk through let-hoisted scaffolding the monomorphizer inserts
        -- around `BE.sequence`'s list argument. The binding is added to
        -- exprCache so a later `MonoVarLocal` reference inside the body
        -- resolves to the cons/list expression. Mirrors `reifyEncoderHelp`.
        Mono.MonoLet (Mono.MonoDef name boundExpr) body _ ->
            reifyEncoderList bodyLookup registry (Dict.insert name boundExpr exprCache) body

        Mono.MonoVarLocal name _ ->
            case Dict.get name exprCache of
                Just cachedExpr ->
                    reifyEncoderList bodyLookup registry exprCache cachedExpr

                Nothing ->
                    Nothing

        _ ->
            -- Dynamic list - can't statically analyze
            Nothing


{-| If `funcExpr args` is a call to elm/core's `(::)` / `Elm.Kernel.List.cons`,
return `Just (headerExpr, tailExpr)`. The cons kernel surface is two-arg:
head + tail. Polymorphic kernels arrive at MonoCall in two possible forms:
either as a `MonoVarKernel _ _ "List" "cons" _` direct reference or as a
specialised `MonoVarGlobal _ specId _` that resolves through the registry
to the elm/core `List.cons` global. We accept both.
-}
reifyListConsCall : Mono.SpecializationRegistry -> Mono.MonoExpr -> List Mono.MonoExpr -> Maybe ( Mono.MonoExpr, Mono.MonoExpr )
reifyListConsCall registry funcExpr args =
    case ( funcExpr, args ) of
        ( Mono.MonoVarKernel _ _ "List" "cons" _, [ headerExpr, tailExpr ] ) ->
            Just ( headerExpr, tailExpr )

        ( Mono.MonoVarGlobal _ specId _, [ headerExpr, tailExpr ] ) ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (IO.Canonical pkg "List") "cons", _, _ ) ->
                    if pkg == Pkg.core then
                        Just ( headerExpr, tailExpr )

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| If `expr` is a call to elm/core's `List.map mapFn xs`, return
`Just (mapFn, iterExpr)`.
-}
reifyListMapCall : Mono.SpecializationRegistry -> Mono.MonoExpr -> Maybe ( Mono.MonoExpr, Mono.MonoExpr )
reifyListMapCall registry expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) [ mapFn, iterExpr ] _ _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (IO.Canonical pkg "List") "map", _, _ ) ->
                    if pkg == Pkg.core then
                        Just ( mapFn, iterExpr )

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| If `expr` is a call to elm/core's `List.length xs`, return `Just xs`.
-}
reifyListLengthCall : Mono.SpecializationRegistry -> Mono.MonoExpr -> Maybe Mono.MonoExpr
reifyListLengthCall registry expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) [ iterExpr ] _ _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (IO.Canonical pkg "List") "length", _, _ ) ->
                    if pkg == Pkg.core then
                        Just iterExpr

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Conservative syntactic equality on two iter-expr references — both
must be the same `MonoVarLocal` name. This is enough for the typical
`Utils.Bytes.Encode.list`-style helper body where the same `xs` is
referenced from both the length and the map.
-}
sameIterExpr : Mono.MonoExpr -> Mono.MonoExpr -> Bool
sameIterExpr a b =
    case ( a, b ) of
        ( Mono.MonoVarLocal n1 _, Mono.MonoVarLocal n2 _ ) ->
            n1 == n2

        _ ->
            False


{-| Detect the length-prefixed list-loop encoder shape:

    BE.sequence (header :: List.map mapFn iterExpr)

where `header` is `BE.unsignedInt32 endian (List.length iterExpr)` (or
the post-inline constructor form `U32 endian (List.length iterExpr)`)
and `mapFn` is a `MonoClosure` whose body reifies to a fixed-width run
of EncoderNodes.

Returns `Just [headerNode, ELoop ...]` on full match. Returns `Nothing`
on any mismatch — the caller falls back to the kernel call.

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


{-| The header of a length-prefixed encoder list must be
`BE.unsignedInt32 endian (List.length iterExpr)` — equivalently the
post-inline `U32 endian (List.length iterExpr)` constructor form.
Returns `Just (headerNode, lengthCallExpr)` where `headerNode` is the
EncoderNode for the U32 write and `lengthCallExpr` is the original
`List.length iterExpr` MonoExpr (reused as the loop count for the
pre-allocation, sparing a second list walk).
-}
matchLengthPrefixHeader : Mono.SpecializationRegistry -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe ( EncoderNode, Mono.MonoExpr )
matchLengthPrefixHeader registry headerExpr iterExpr =
    case headerExpr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) [ endianExpr, lengthCall ] _ _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (IO.Canonical pkg "Bytes.Encode") name, _, _ ) ->
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


{-| Apply `mapFn` to a fresh per-iteration item and reify the body.

Two shapes are accepted:

  - `MonoClosure` — the inline-lambda case. The lambda's parameter
    name becomes the `itemVar`, and the body is reified directly (it
    already references that name as `MonoVarLocal`, which the emit
    module binds to the per-iteration SSA head).

  - `MonoVarGlobal` — the named-helper case. Closure conversion turns
    inline lambdas into top-level functions, and the typical Eco
    pattern (`Utils.Bytes.Encode.list Utils.Bytes.Encode.string xs`)
    references helpers by name from the start. We look the spec up in
    the inliner's `bodyLookup` (which only contains non-recursive,
    `getInlinableBody`-eligible specs) and reify the body using its
    own parameter name as the `itemVar`. The emit module binds that
    name to the per-iteration SSA head the same way it would for a
    lambda parameter.

Other shapes (function parameters at the map call site, MonoVarKernel,
recursive globals not in `bodyLookup`, etc.) return `Nothing` to fall
back to the kernel call.

The reified body must have a constant total byte width: every node's
output is a fixed-size primitive. Variable-width bodies (ELoop within
ELoop, EUtf8 of a per-iteration string, EBytes of per-iteration bytes)
are rejected because the pre-allocation would need a per-iteration
size walk.

-}
reifyMapBody : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe EncoderNode
reifyMapBody bodyLookup registry exprCache mapFn iterExpr countExpr =
    case mapFn of
        Mono.MonoClosure info body _ ->
            case info.params of
                [ ( paramName, _ ) ] ->
                    buildLoopNode bodyLookup registry exprCache paramName body iterExpr countExpr

                _ ->
                    Nothing

        Mono.MonoVarGlobal _ specId _ ->
            case Dict.get specId bodyLookup of
                Just ( [ ( paramName, _ ) ], body ) ->
                    buildLoopNode bodyLookup registry exprCache paramName body iterExpr countExpr

                _ ->
                    -- Not an arity-1 inlinable spec (recursive, kernel,
                    -- multi-arg, MonoCase body, etc.). Bail.
                    Nothing

        _ ->
            Nothing


{-| Shared body-reification step for both `reifyMapBody` arms.
-}
buildLoopNode : BodyLookup -> Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe EncoderNode
buildLoopNode bodyLookup registry exprCache paramName body iterExpr countExpr =
    case reifyEncoderHelp bodyLookup registry exprCache body of
        Just bodyNodes ->
            if List.all hasConstantWidth bodyNodes then
                Just
                    (ELoop
                        { itemVar = paramName
                        , itemNodes = bodyNodes
                        , iterExpr = iterExpr
                        , countExpr = countExpr
                        }
                    )

            else
                Nothing

        Nothing ->
            Nothing


{-| An EncoderNode has a constant compile-time byte width iff it is a
primitive write (EU8/EU16/EU32/EF32/EF64) or a nested ELoop whose body
also has constant width — but for the first-pass implementation we only
allow primitives in loop bodies (so EBytes/EUtf8/ELoop inside ELoop
return False).
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
            -- Width is runtime-computed via elm_encoder_size; not a
            -- constant. Loop bodies that hold an opaque subtree can't
            -- be ELoop-fused (would need per-iteration width walks).
            False


{-| Compute the constant byte width of a node that has one. Only valid
to call on nodes for which `hasConstantWidth` returns True.
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


{-| Reify an endianness expression (BE or LE).

Based on MonoExpr structure:

  - `MonoVarGlobal Region SpecId MonoType` references global values including constructors
  - `Registry.lookupSpecKey` returns `Maybe (Global, MonoType, Maybe LambdaId)` (a tuple!)
  - `Global = Global IO.Canonical Name | Accessor Name`

Bytes.BE and Bytes.LE are nullary constructors of Bytes.Endianness.

-}
reifyEndianness : Mono.SpecializationRegistry -> Mono.MonoExpr -> Maybe Endianness
reifyEndianness registry expr =
    case expr of
        -- Nullary constructors are represented as MonoVarGlobal
        Mono.MonoVarGlobal _ specId _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
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

        -- Unwrap trivial zero-arg calls (sometimes nullary ctors get wrapped)
        Mono.MonoCall _ fn [] _ _ ->
            reifyEndianness registry fn

        _ ->
            Nothing


{-| Convert encoder nodes to Loop IR operations.
Uses "cur" as the cursor name.
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


{-| Convert a single encoder node to a Loop IR operation.
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
                , bodyOps = List.map (nodeToOp cursorName) r.itemNodes
                , iterExpr = r.iterExpr
                , itemByteWidth = sumConstWidths r.itemNodes
                }

        EOpaque expr ->
            WriteOpaque cursorName expr


sumConstWidths : List EncoderNode -> Int
sumConstWidths nodes =
    List.foldl (\n acc -> acc + constantNodeWidth n) 0 nodes


{-| Compute the total width from encoder nodes.
-}
computeWidth : List EncoderNode -> WidthExpr
computeWidth nodes =
    List.foldl addNodeWidth (WConst 0) nodes
        |> IR.simplifyWidth


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
            -- Pre-allocate count*constItemWidth bytes for the loop body.
            -- countExpr was extracted from the header's List.length call so
            -- it's evaluated once, not re-walked at emit time.
            WAdd acc (WListLengthMul r.countExpr (sumConstWidths r.itemNodes))

        EOpaque expr ->
            -- Runtime walk via elm_encoder_size. Same tree gets walked
            -- again by elm_encoder_write_into at write time — that's the
            -- same two-pass cost the kernel pays today.
            WAdd acc (WOpaqueWidth expr)


{-| Combine a list of Maybe values into Maybe of list.
Returns Nothing if any element is Nothing.
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
-- Decoder Reification (Phase 2)
-- ============================================================================


{-| Try to reify a MonoExpr into a decoder node.
Returns Nothing if the expression contains dynamic/opaque decoders
or unsupported combinators (andThen, loop).
-}
reifyDecoder : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyDecoder registry exprCache expr =
    case expr of
        Mono.MonoCall _ func args _ _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                                reifyBytesDecodeCall registry exprCache name args

                            else
                                Nothing

                        _ ->
                            Nothing

                Mono.MonoVarKernel _ _ "Bytes" name _ ->
                    reifyBytesKernelDecodeCall registry exprCache name args

                -- Curried call: func is itself a call (e.g. from pipe operator expansion).
                -- Flatten inner args with outer args and try again.
                Mono.MonoCall _ innerFunc innerArgs _ _ ->
                    case innerFunc of
                        Mono.MonoVarGlobal _ innerSpecId _ ->
                            case Registry.lookupSpecKey innerSpecId registry of
                                Just ( Mono.Global (IO.Canonical pkg2 moduleName2) name2, _, _ ) ->
                                    if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Decode" then
                                        reifyBytesDecodeCall registry exprCache name2 (innerArgs ++ args)

                                    else
                                        Nothing

                                _ ->
                                    Nothing

                        Mono.MonoVarKernel _ _ "Bytes" name2 _ ->
                            reifyBytesKernelDecodeCall registry exprCache name2 (innerArgs ++ args)

                        _ ->
                            Nothing

                -- Local variable in function position: resolve from exprCache.
                -- Handles the pattern where pipe inlining produces
                -- let _f = D.andThen callback in _f decoder
                Mono.MonoVarLocal funcName _ ->
                    case Dict.get funcName exprCache of
                        Just (Mono.MonoCall _ innerFunc innerArgs _ _) ->
                            case innerFunc of
                                Mono.MonoVarGlobal _ innerSpecId _ ->
                                    case Registry.lookupSpecKey innerSpecId registry of
                                        Just ( Mono.Global (IO.Canonical pkg2 moduleName2) name2, _, _ ) ->
                                            if pkg2 == Pkg.bytes && moduleName2 == "Bytes.Decode" then
                                                reifyBytesDecodeCall registry exprCache name2 (innerArgs ++ args)

                                            else
                                                Nothing

                                        _ ->
                                            Nothing

                                Mono.MonoVarKernel _ _ "Bytes" name2 _ ->
                                    reifyBytesKernelDecodeCall registry exprCache name2 (innerArgs ++ args)

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        -- Zero-argument decoder values (e.g. unsignedInt8, signedInt8) are bare MonoVarGlobal
        Mono.MonoVarGlobal _ specId _ ->
            case Registry.lookupSpecKey specId registry of
                Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                    if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                        reifyBytesDecodeCall registry exprCache name []

                    else
                        Nothing

                _ ->
                    Nothing

        -- Let binding: add the binding to exprCache and recurse on the body
        Mono.MonoLet def body _ ->
            case def of
                Mono.MonoDef name defExpr ->
                    reifyDecoder registry (Dict.insert name defExpr exprCache) body

                _ ->
                    Nothing

        -- Local variable reference - look up in exprCache
        Mono.MonoVarLocal name _ ->
            case Dict.get name exprCache of
                Just cachedExpr ->
                    reifyDecoder registry exprCache cachedExpr

                Nothing ->
                    Nothing

        -- Variable reference - can't statically analyze
        _ ->
            Nothing


{-| Reify a call to a Bytes.Decode.\* function.
-}
reifyBytesDecodeCall : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> List Mono.MonoExpr -> Maybe DecoderNode
reifyBytesDecodeCall registry exprCache name args =
    case ( name, args ) of
        -- Primitive decoders (zero-arg)
        ( "unsignedInt8", [] ) ->
            Just DU8

        ( "signedInt8", [] ) ->
            Just DS8

        -- Primitive decoders with endianness
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

        -- Variable-length reads
        ( "bytes", [ lenExpr ] ) ->
            Just (DBytes lenExpr)

        ( "string", [ lenExpr ] ) ->
            Just (DString lenExpr)

        -- Succeed/fail
        ( "succeed", [ valueExpr ] ) ->
            Just (DSucceed valueExpr)

        ( "fail", [] ) ->
            Just DFail

        -- Map combinators
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

        -- Phase 3: andThen support
        ( "andThen", [ lambdaExpr, firstDecoderExpr ] ) ->
            reifyAndThen registry exprCache lambdaExpr firstDecoderExpr

        -- Phase 4: loop support
        -- loop : (state -> Decoder (Step state a)) -> state -> Decoder a
        ( "loop", [ stepFnExpr, initialStateExpr ] ) ->
            reifyLoop registry exprCache stepFnExpr initialStateExpr

        _ ->
            Nothing


{-| Reify kernel decode calls.
-}
reifyBytesKernelDecodeCall : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> String -> List Mono.MonoExpr -> Maybe DecoderNode
reifyBytesKernelDecodeCall _ _ _ _ =
    -- Kernel decode functions are internal; typically not exposed
    Nothing



-- ============================================================================
-- Phase 3: andThen Pattern Recognition
-- ============================================================================


{-| Try to reify an andThen expression into a fuseable pattern.
-}
reifyAndThen : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyAndThen registry exprCache lambdaExpr firstDecoderExpr =
    -- First, reify the initial decoder
    case reifyDecoder registry exprCache firstDecoderExpr of
        Nothing ->
            Nothing

        Just firstDecoder ->
            -- Analyze the lambda
            case lambdaExpr of
                Mono.MonoClosure closureInfo bodyExpr _ ->
                    reifyAndThenBody registry exprCache firstDecoder closureInfo bodyExpr

                _ ->
                    Nothing


{-| Analyze the lambda body to identify fuseable patterns.
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
        -- Get the lambda parameter name
        maybeParamName =
            case closureInfo.params of
                [ ( name, _ ) ] ->
                    Just name

                _ ->
                    -- andThen lambda should have exactly 1 param
                    Nothing
    in
    case maybeParamName of
        Nothing ->
            Nothing

        Just paramName ->
            -- Try to match length-prefixed patterns first
            case matchLengthPrefixedPattern registry exprCache paramName bodyExpr of
                Just patternConstructor ->
                    -- Convert firstDecoder to LengthDecoder if it's an integer type
                    case decoderToLengthDecoder firstDecoder of
                        Just lenDecoder ->
                            Just (patternConstructor lenDecoder)

                        Nothing ->
                            -- First decoder isn't an integer - can't use as length
                            Nothing

                Nothing ->
                    -- Try general andThen pattern (recursive analysis)
                    case reifyDecoder registry exprCache bodyExpr of
                        Just bodyDecoder ->
                            Just (DAndThen firstDecoder paramName bodyDecoder)

                        Nothing ->
                            Nothing


{-| Check if the body is a length-prefixed pattern like Decode.string len or Decode.bytes len.
Returns a constructor that takes a LengthDecoder.
-}
matchLengthPrefixedPattern :
    Mono.SpecializationRegistry
    -> Dict String Mono.MonoExpr
    -> String
    -> Mono.MonoExpr
    -> Maybe (LengthDecoder -> DecoderNode)
matchLengthPrefixedPattern registry _ paramName bodyExpr =
    case bodyExpr of
        Mono.MonoCall _ func [ argExpr ] _ _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                                -- Check if the argument is just the parameter variable
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


{-| Check if an expression is a reference to the given parameter name.
-}
isParamRef : String -> Mono.MonoExpr -> Bool
isParamRef paramName expr =
    case expr of
        Mono.MonoVarLocal name _ ->
            name == paramName

        _ ->
            False


{-| Convert a primitive integer decoder to a LengthDecoder.
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
            -- Float decoders and complex decoders can't be used as length
            Nothing



-- ============================================================================
-- Phase 4: loop Pattern Recognition
-- ============================================================================


{-| Try to reify a loop expression.

Decode.loop : (state -> Decoder (Step state a)) -> state -> Decoder a

This is complex because we need to analyze the step function to understand:

1.  The loop termination condition
2.  The item decoder for each iteration
3.  The accumulator update pattern

For Phase 4, we support the most common pattern: count-based loops where
the initial state is a tuple (count, []) and the step function decrements
the count.

-}
reifyLoop : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyLoop registry exprCache stepFnExpr initialStateExpr =
    -- Try count-based pattern first:
    -- Decode.loop ( count, [] ) (\( n, acc ) -> if n <= 0 then ... else Decode.map ... itemDecoder)
    case extractCountFromInitialState initialStateExpr of
        Just countSource ->
            case extractItemDecoderFromStepFn registry exprCache stepFnExpr of
                Just itemDecoder ->
                    Just (DCountLoop countSource itemDecoder)

                Nothing ->
                    -- Count source found but item decoder extraction failed
                    trySentinelLoop registry exprCache stepFnExpr initialStateExpr

        Nothing ->
            -- Not a count-based loop, try sentinel pattern
            trySentinelLoop registry exprCache stepFnExpr initialStateExpr


{-| Try to recognize sentinel-terminated loop patterns:
Decode.loop [] (\\acc ->
Decode.unsignedInt8
|> Decode.andThen (\\byte ->
if byte == 0 then Decode.succeed (Done ...)
else Decode.succeed (Loop ...)
)
)

Key characteristics:

  - Initial state is empty list []
  - Step function reads a value, then uses andThen to check sentinel

-}
trySentinelLoop : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
trySentinelLoop registry exprCache stepFnExpr initialStateExpr =
    -- Check if initial state is empty list []
    case initialStateExpr of
        Mono.MonoList _ [] _ ->
            -- Try to extract sentinel and item decoder from step function
            extractSentinelFromStepFn registry exprCache stepFnExpr

        _ ->
            Nothing


{-| Extract sentinel value and item decoder from a sentinel-terminated step function.

Pattern:
\\acc -> itemDecoder |> Decode.andThen (\\val -> if val == SENTINEL then ... else ...)

-}
extractSentinelFromStepFn : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
extractSentinelFromStepFn registry exprCache stepFnExpr =
    case stepFnExpr of
        Mono.MonoClosure _ bodyExpr _ ->
            extractSentinelFromBody registry exprCache bodyExpr

        _ ->
            Nothing


{-| Extract sentinel from the body of a sentinel loop step function.
-}
extractSentinelFromBody : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
extractSentinelFromBody registry exprCache bodyExpr =
    case bodyExpr of
        Mono.MonoLet _ innerExpr _ ->
            extractSentinelFromBody registry exprCache innerExpr

        -- Look for: decoder |> andThen (\val -> if val == sentinel then ...)
        -- This is MonoCall to andThen with [decoderExpr, lambdaExpr]
        Mono.MonoCall _ func [ decoderExpr, lambdaExpr ] _ _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    -- Check if this is Decode.andThen
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" && name == "andThen" then
                                -- Found andThen, now extract sentinel and item decoder
                                extractSentinelFromAndThenBody registry exprCache decoderExpr lambdaExpr

                            else
                                Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Extract sentinel value from the andThen body.

The lambda has pattern: \\val -> if val == SENTINEL then Done else Loop
We need to find the sentinel value and confirm the decoder type.

-}
extractSentinelFromAndThenBody : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
extractSentinelFromAndThenBody registry exprCache decoderExpr lambdaExpr =
    -- First try to reify the decoder (typically DU8 for null-terminated)
    case reifyDecoder registry exprCache decoderExpr of
        Just itemDecoder ->
            -- Now extract sentinel value from the lambda body
            case extractSentinelValue lambdaExpr of
                Just sentinel ->
                    Just (DSentinelLoop sentinel itemDecoder)

                Nothing ->
                    Nothing

        Nothing ->
            Nothing


{-| Extract the sentinel value from a lambda body containing an if expression.

Pattern: \\val -> if val == SENTINEL then ...

-}
extractSentinelValue : Mono.MonoExpr -> Maybe Int
extractSentinelValue lambdaExpr =
    case lambdaExpr of
        Mono.MonoClosure _ bodyExpr _ ->
            extractSentinelFromIfExpr bodyExpr

        _ ->
            Nothing


{-| Extract sentinel from an if expression that compares against a literal.
-}
extractSentinelFromIfExpr : Mono.MonoExpr -> Maybe Int
extractSentinelFromIfExpr bodyExpr =
    case bodyExpr of
        Mono.MonoLet _ innerExpr _ ->
            extractSentinelFromIfExpr innerExpr

        Mono.MonoIf branches _ _ ->
            -- Look at the condition of the first branch
            case branches of
                [ ( condExpr, _ ) ] ->
                    extractSentinelFromCondition condExpr

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Extract sentinel value from a comparison condition.

Pattern: val == SENTINEL (typically 0 for null-terminated)

-}
extractSentinelFromCondition : Mono.MonoExpr -> Maybe Int
extractSentinelFromCondition condExpr =
    case condExpr of
        -- Look for equality comparison: var == literal or literal == var
        Mono.MonoCall _ func [ arg1, arg2 ] _ _ ->
            case func of
                Mono.MonoVarKernel _ _ _ "eq" _ ->
                    -- Check if one arg is a literal int
                    case ( arg1, arg2 ) of
                        ( Mono.MonoLiteral (Mono.LInt n) _, _ ) ->
                            Just n

                        ( _, Mono.MonoLiteral (Mono.LInt n) _ ) ->
                            Just n

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Extract count source from initial state tuple ( count, [] ).
-}
extractCountFromInitialState : Mono.MonoExpr -> Maybe CountSource
extractCountFromInitialState expr =
    case expr of
        Mono.MonoTupleCreate _ [ countExpr, listExpr ] _ ->
            -- Check that listExpr is an empty list
            case listExpr of
                Mono.MonoList _ [] _ ->
                    -- Extract count from countExpr
                    extractCountSource countExpr

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Extract count source from a count expression.
-}
extractCountSource : Mono.MonoExpr -> Maybe CountSource
extractCountSource expr =
    case expr of
        Mono.MonoVarLocal name _ ->
            -- Count from a bound variable (e.g., from andThen)
            Just (CountFromVar name)

        Mono.MonoLiteral (Mono.LInt n) _ ->
            -- Constant count
            Just (CountConst n)

        _ ->
            Nothing


{-| Try to extract the item decoder from a loop step function.

The step function has the pattern:
( n, acc ) -> if n <= 0 then ... else Decode.map (\\item -> ...) itemDecoder

We need to find the Decode.map call and extract its second argument (itemDecoder).

-}
extractItemDecoderFromStepFn : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
extractItemDecoderFromStepFn registry exprCache stepFnExpr =
    case stepFnExpr of
        Mono.MonoClosure _ bodyExpr _ ->
            -- Body may have destructs for tuple extraction, then an if
            extractItemDecoderFromBody registry exprCache bodyExpr

        _ ->
            Nothing


{-| Extract item decoder from the step function body.

This recursively looks through Let/Destruct nodes to find the MonoIf,
then extracts the item decoder from the else branch's Decode.map call.

-}
extractItemDecoderFromBody : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
extractItemDecoderFromBody registry exprCache bodyExpr =
    case bodyExpr of
        Mono.MonoLet _ innerExpr _ ->
            extractItemDecoderFromBody registry exprCache innerExpr

        Mono.MonoDestruct _ innerExpr _ ->
            extractItemDecoderFromBody registry exprCache innerExpr

        Mono.MonoIf branches elseExpr _ ->
            -- The else branch (or last branch if/else) contains Decode.map ... itemDecoder
            -- In Elm's MonoIf, branches is a list of (condition, thenExpr) pairs
            -- The elseExpr is the final else branch
            -- For count-based loops, the else branch is the "continue" path with item decoding
            case branches of
                [ _ ] ->
                    -- Single if-then-else: else branch has the item decoder
                    extractItemDecoderFromMapCall registry exprCache elseExpr

                _ ->
                    Nothing

        _ ->
            -- Also check if this is directly a Decode.map call (simpler patterns)
            extractItemDecoderFromMapCall registry exprCache bodyExpr


{-| Extract item decoder from a Decode.map call.

Pattern: Decode.map (\\item -> Loop ...) itemDecoder
The itemDecoder is the second argument.

-}
extractItemDecoderFromMapCall : Mono.SpecializationRegistry -> Dict String Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
extractItemDecoderFromMapCall registry exprCache expr =
    case expr of
        Mono.MonoCall _ func [ _, itemDecoderExpr ] _ _ ->
            -- Check if func is Decode.map
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" && name == "map" then
                                reifyDecoder registry exprCache itemDecoderExpr

                            else
                                Nothing

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Maybe.map4 helper.
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


{-| Maybe.map5 helper.
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


{-| State for decoder compilation.
-}
type alias DecoderCompileState =
    { cursorName : String
    , varCounter : Int
    , ops : List IR.DecoderOp
    , paramBindings : Dict String String -- paramName -> SSA var (for andThen)
    }


{-| Convert a DecoderNode to a list of DecoderOps.
Returns the ops and the final result variable name.
Note: InitReadCursor uses a dummy MonoExpr since the actual bytesVar
is passed directly to the emitter.
-}
decoderNodeToOps : DecoderNode -> ( List IR.DecoderOp, String )
decoderNodeToOps node =
    let
        cursorName =
            "dcur"

        -- Use MonoUnit as dummy since emitter ignores this and uses pre-compiled bytesVar
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


{-| Compile a decoder node, returning the result variable and updated state.
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
            -- Check if lenExpr is a bound parameter reference
            case getParamBinding lenExpr state.paramBindings of
                Just lenVarName ->
                    -- Use ReadBytesVar with the bound SSA variable
                    ( resultVar
                    , { state1 | ops = IR.ReadBytesVar state.cursorName lenVarName resultVar :: state1.ops }
                    )

                Nothing ->
                    -- Use ReadBytes with the expression (will be compiled by emitter)
                    ( resultVar
                    , { state1 | ops = IR.ReadBytes state.cursorName lenExpr resultVar :: state1.ops }
                    )

        DString lenExpr ->
            let
                ( resultVar, state1 ) =
                    freshVar "str" state
            in
            -- Check if lenExpr is a bound parameter reference
            case getParamBinding lenExpr state.paramBindings of
                Just lenVarName ->
                    -- Use ReadUtf8Var with the bound SSA variable
                    ( resultVar
                    , { state1 | ops = IR.ReadUtf8Var state.cursorName lenVarName resultVar :: state1.ops }
                    )

                Nothing ->
                    -- Use ReadUtf8 with the expression (will be compiled by emitter)
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
            -- DFail means the decoder always fails - emit ReturnNothing
            -- The result var is a placeholder since we won't use it
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

        -- Phase 3: Length-prefixed patterns
        DLengthPrefixedString lenDecoder ->
            let
                -- First read the length
                ( lenVar, state1 ) =
                    compileLengthDecoder lenDecoder state

                -- Then read the string using that length variable
                ( resultVar, state2 ) =
                    freshVar "lpstr" state1
            in
            ( resultVar
            , { state2 | ops = IR.ReadUtf8Var state.cursorName lenVar resultVar :: state2.ops }
            )

        DLengthPrefixedBytes lenDecoder ->
            let
                -- First read the length
                ( lenVar, state1 ) =
                    compileLengthDecoder lenDecoder state

                -- Then read the bytes using that length variable
                ( resultVar, state2 ) =
                    freshVar "lpbytes" state1
            in
            ( resultVar
            , { state2 | ops = IR.ReadBytesVar state.cursorName lenVar resultVar :: state2.ops }
            )

        DAndThen firstDecoder paramName bodyDecoder ->
            -- General andThen: compile first decoder, then body decoder
            -- The paramName references the first result in the body
            let
                -- Compile the first decoder
                ( firstVar, state1 ) =
                    compileDecoderNode firstDecoder state

                -- Add binding: paramName -> firstVar
                -- This allows DBytes/DString in the body to use ReadBytesVar/ReadUtf8Var
                stateWithBinding =
                    { state1 | paramBindings = Dict.insert paramName firstVar state1.paramBindings }
            in
            compileDecoderNode bodyDecoder stateWithBinding

        DCountLoop countSource itemDecoder ->
            -- Count-based loop: decode a fixed number of items into a list
            -- The count comes from either a bound variable or a constant
            let
                -- Get the count variable name
                -- Compile the item decoder in a fresh state to get its ops
                itemState =
                    { cursorName = state.cursorName
                    , varCounter = state.varCounter
                    , ops = []
                    , paramBindings = state.paramBindings
                    }

                ( _, itemStateAfter ) =
                    compileDecoderNode itemDecoder itemState

                -- The item ops are in reverse order, reverse them
                itemOps =
                    List.reverse itemStateAfter.ops

                -- Generate the result variable for the list
                ( resultVar, state1 ) =
                    freshVar "list" { state | varCounter = itemStateAfter.varCounter }

                -- Create the loop op
                -- For CountConst, we need to communicate the constant value somehow
                -- We'll use the countVarName field with a special prefix
                actualCountVar =
                    case countSource of
                        CountFromVar varName ->
                            Dict.get varName state.paramBindings
                                |> Maybe.withDefault varName

                        CountConst n ->
                            -- Encode constant as special name that emitter can recognize
                            "const:" ++ String.fromInt n
            in
            ( resultVar
            , { state1
                | ops =
                    IR.LoopDecodeList actualCountVar state.cursorName itemOps resultVar
                        :: state1.ops
              }
            )

        DSentinelLoop sentinel itemDecoder ->
            -- Sentinel-terminated loop: decode items until sentinel is read
            -- Each item is checked against sentinel before being added to list
            let
                -- Compile the item decoder in a fresh state to get its ops
                itemState =
                    { cursorName = state.cursorName
                    , varCounter = state.varCounter
                    , ops = []
                    , paramBindings = state.paramBindings
                    }

                ( _, itemStateAfter ) =
                    compileDecoderNode itemDecoder itemState

                -- The item ops are in reverse order, reverse them
                itemOps =
                    List.reverse itemStateAfter.ops

                -- Generate the result variable for the list
                ( resultVar, state1 ) =
                    freshVar "list" { state | varCounter = itemStateAfter.varCounter }
            in
            ( resultVar
            , { state1
                | ops =
                    IR.LoopSentinelDecodeList sentinel state.cursorName itemOps resultVar
                        :: state1.ops
              }
            )


{-| Compile a LengthDecoder to the appropriate read op and return the length variable.
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


{-| Generate a fresh variable name.
-}
freshVar : String -> DecoderCompileState -> ( String, DecoderCompileState )
freshVar prefix state =
    ( prefix ++ "_" ++ String.fromInt state.varCounter
    , { state | varCounter = state.varCounter + 1 }
    )


{-| Check if a MonoExpr is a local variable reference that's bound in paramBindings.
Returns the SSA variable name if found.
-}
getParamBinding : MonoExpr -> Dict String String -> Maybe String
getParamBinding expr bindings =
    case expr of
        MonoVarLocal varName _ ->
            Dict.get varName bindings

        _ ->
            Nothing
