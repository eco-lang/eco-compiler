module TestLogic.Generate.CodeGen.UnboxedBitmap exposing (expectUnboxedBitmap, checkUnboxedBitmap, checkClosureKindLimits, expectSlotKinds)

{-| Checks that the slot kinds in generated MLIR agree with the operand types
of the ops that carry them, so that a heap object or closure whose kinds
misdescribe the values stored in it is caught in the MLIR the code generator
produces. (The module keeps its historical name: only the tuple ops still
carry an integer bitmap.)

A _slot kind_ is 0 for a boxed value (`!eco.value`), 1 for an Int (`i64`), 2
for a Float (`f64`) and 3 for a Char (`i16`). The record and custom construct
ops record one kind per field in a `slot_kinds` array (a dense `i8` array;
wide-object Phase 3), and so do the closure ops `eco.papCreate` and
`eco.papExtend` (one entry per captured operand or new argument; wide-object
Phase 2). Only the tuple construct ops record their kinds in an integer
attribute, their _unboxed bitmap_, with slot N in bits 2N and 2N+1; a tuple has
at most three slots. The operand types
compared against them are the ones the op records in its `_operand_types`
attribute, read with `TestLogic.Generate.CodeGen.Invariants.extractOperandTypes`.

A Bool is `!eco.value` when it is stored in a heap object or captured by a
closure, so an `i1` in any operand position that is compared (for a list cons,
the head) is a violation whatever the bitmap, kind or flag says.

`expectUnboxedBitmap` compiles the given module to MLIR and checks, at any
nesting depth:

  - `eco.construct.tuple2` and `eco.construct.tuple3`: slot N of
    `unboxed_bitmap` holds the kind of operand N, for every recorded operand,
    trailing GC root hints included.
  - `eco.construct.record` and `eco.construct.custom`: `slot_kinds` is present
    and has one entry per field (`field_count` / `size`), and entry N is the
    kind of operand N. The trailing GC root hint operands are not compared. The
    op carries no `unboxed_bitmap` (the backend rejects it as stale since
    wide-object Phase 3D).
  - `eco.papCreate`: `slot_kinds` has one entry per captured operand, and entry
    N is the kind of operand N.
  - `eco.papExtend`: `slot_kinds` has one entry per new argument, and entry N
    is the kind of operand N+1. Operand 0 is the closure being extended, and
    the trailing operands that `eco.gc_roots_count` counts are GC root hints,
    so neither is compared.
  - `eco.construct.list`: the boolean `head_unboxed` is true exactly when the
    head operand is `i64`, `f64` or `i16`.

A closure op without `slot_kinds` passes only when it has no compared
operands. A missing tuple bitmap reads as 0 (every slot boxed) and a missing
`head_unboxed` as false. An op with no `_operand_types` attribute is not
checked.

`checkClosureKindLimits` checks a separate property of the closure ops: that
their kind attributes have the post-Phase-2 form the backend expects. No
`eco.papCreate`, `eco.papExtend` or `eco.papCreateGroup` carries a u64 kind
bitmap (`unboxed_bitmap`, `newargs_unboxed_bitmap`, `unboxed_bitmaps`); every
`slot_kinds` array (per sibling for a group) has at most 2047 entries
(`HeapLimits.maxStageArity`, HEAP\_078); and a papExtend has at most 2047 real
new arguments (operand 0, the closure, and the trailing GC root hints are not
counted).

Among what is not tested: the `head_kind` attribute of `eco.construct.list`,
the kinds of `eco.papCreateGroup` siblings, the types of function parameters
and results, and whether a recorded operand type matches the type of the SSA
value actually passed.

`expectSlotKinds` compiles a module and compares the `slot_kinds` of the one
op of a given name with an expected list.

@docs expectUnboxedBitmap, checkUnboxedBitmap, checkClosureKindLimits, expectSlotKinds

-}

import Compiler.AST.Source as Src
import Compiler.Data.HeapLimits as HeapLimits
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getArrayAttr
        , getBoolAttr
        , getIntAttr
        , isUnboxable
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that passes when `srcModule` compiles to MLIR and
every op the module docstring lists has an unboxed bitmap, or for a list cons a
`head_unboxed` flag, that agrees with its operand types under the rules set out
there.

A compilation failure fails with its message. Otherwise the expectation fails
with the first violation found, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

-}
expectUnboxedBitmap : Src.Module -> Expectation
expectUnboxedBitmap srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkUnboxedBitmap mlirModule)


{-| Returns every violation in `mlirModule`: those of the tuple, record and
custom construct ops, then of the list cons ops, then of `eco.papCreate`, then
of `eco.papExtend`.
-}
checkUnboxedBitmap : MlirModule -> List Violation
checkUnboxedBitmap mlirModule =
    let
        tuple2Ops =
            findOpsNamed "eco.construct.tuple2" mlirModule

        tuple3Ops =
            findOpsNamed "eco.construct.tuple3" mlirModule

        recordOps =
            findOpsNamed "eco.construct.record" mlirModule

        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        containerViolations =
            List.concatMap checkContainerBitmap (tuple2Ops ++ tuple3Ops)
                ++ List.concatMap checkContainerSlotKinds (recordOps ++ customOps)

        listOps =
            findOpsNamed "eco.construct.list" mlirModule

        listViolations =
            List.filterMap checkListHeadUnboxed listOps

        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule

        papCreateViolations =
            List.concatMap checkPapCreateBitmap papCreateOps

        papExtendOps =
            findOpsNamed "eco.papExtend" mlirModule

        papExtendViolations =
            List.concatMap checkPapExtendBitmap papExtendOps
    in
    containerViolations ++ listViolations ++ papCreateViolations ++ papExtendViolations


{-| Returns the violations in the `unboxed_bitmap` of a tuple construct op,
comparing slot N with operand N. A missing bitmap reads as 0, and
an op with no recorded operand types gives none.
-}
checkContainerBitmap : MlirOp -> List Violation
checkContainerBitmap op =
    let
        unboxedBitmap =
            getIntAttr "unboxed_bitmap" op |> Maybe.withDefault 0

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            []

        Just operandTypes ->
            List.indexedMap (checkBitmapBit op unboxedBitmap) operandTypes
                |> List.filterMap identity


{-| Returns the violations in the `slot_kinds` of a record or custom construct
op: the op must not carry a stale `unboxed_bitmap`, and `slot_kinds` must be
present and hold one entry per field (`field_count` for a record, `size` for a
custom), and entry N must be the kind operand N's type requires (an `i1`
operand is reported whatever the entry holds). The trailing GC root hint
operands, beyond the slot count, are not compared. Apart from the stale
bitmap, an op with no recorded operand types gives none.
-}
checkContainerSlotKinds : MlirOp -> List Violation
checkContainerSlotKinds op =
    List.filterMap identity [ checkNoLegacyBitmap op "unboxed_bitmap" ]
        ++ checkContainerSlotKindsOnly op


{-| `checkContainerSlotKinds` without the stale-bitmap check.
-}
checkContainerSlotKindsOnly : MlirOp -> List Violation
checkContainerSlotKindsOnly op =
    let
        slotCount =
            if op.name == "eco.construct.record" then
                getIntAttr "field_count" op

            else
                getIntAttr "size" op
    in
    case ( getArrayAttr "slot_kinds" op |> Maybe.map (List.map (extractKind >> Maybe.withDefault -1)), extractOperandTypes op ) of
        ( _, Nothing ) ->
            []

        ( Nothing, Just _ ) ->
            [ { opId = op.id, opName = op.name, message = op.name ++ " has no slot_kinds attribute" } ]

        ( Just kinds, Just operandTypes ) ->
            if Just (List.length kinds) /= slotCount then
                [ { opId = op.id
                  , opName = op.name
                  , message =
                        "slot_kinds has "
                            ++ String.fromInt (List.length kinds)
                            ++ " entries but the op has "
                            ++ (slotCount |> Maybe.map String.fromInt |> Maybe.withDefault "no")
                            ++ " slots"
                  }
                ]

            else if List.length operandTypes < List.length kinds then
                [ { opId = op.id
                  , opName = op.name
                  , message =
                        "slot_kinds has "
                            ++ String.fromInt (List.length kinds)
                            ++ " entries but the op records only "
                            ++ String.fromInt (List.length operandTypes)
                            ++ " operand types"
                  }
                ]

            else
                List.map2 Tuple.pair kinds operandTypes
                    |> List.indexedMap (\i ( k, t ) -> checkSlotKind op i k t "operand")
                    |> List.filterMap identity


{-| Returns an expectation that passes when `srcModule` compiles to MLIR, at
least one op is named `opName`, and every such op's `slot_kinds` entries are
`expected`.
-}
expectSlotKinds : String -> List Int -> Src.Module -> Expectation
expectSlotKinds opName expected srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            case findOpsNamed opName mlirModule of
                [] ->
                    Expect.fail ("expected an " ++ opName ++ " op, found none")

                ops ->
                    -- Every copy: constant-thunk folding (CGEN_082) emits a
                    -- constant's body again at each use, so one construction
                    -- in the source can be several ops.
                    ops
                        |> List.map (getArrayAttr "slot_kinds" >> Maybe.map (List.filterMap extractKind))
                        |> Expect.equal (List.repeat (List.length ops) (Just expected))


{-| Returns the violation, if any, for operand `index` of a construct op, as
`checkBitmapKind` decides it.
-}
checkBitmapBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkBitmapBit op bitmap index operandType =
    checkBitmapKind op bitmap index operandType "unboxed_bitmap" "operand"


{-| Returns the slot kind held in slot `index` of `bitmap`.

Only tuple bitmaps (at most 3 slots) are still carried as integers. The slot
is read with float arithmetic, which is exact for them.

-}
slotKind : Int -> Int -> Int
slotKind bitmap index =
    modBy 4 (floor (toFloat bitmap / toFloat (4 ^ index)))


{-| Returns the slot kind an operand of type `ty` requires: 1 for `i64`, 2 for
`f64`, 3 for `i16`, and 0 for every other type, `i1` included.
-}
typeToKind : MlirType -> Int
typeToKind ty =
    case ty of
        I64 ->
            1

        F64 ->
            2

        I16 ->
            3

        _ ->
            0


{-| Returns the violation, if any, for operand `index` of `op`, whose type is
`operandType`, against slot `index` of `bitmap`.

An `i1` operand is reported whatever the slot holds. Otherwise the operand is
reported when the slot's kind differs from the kind its type requires.
`bitmapName` and `operandLabel` only word the message.

-}
checkBitmapKind : MlirOp -> Int -> Int -> MlirType -> String -> String -> Maybe Violation
checkBitmapKind op bitmap index operandType bitmapName operandLabel =
    let
        kindFromBitmap =
            slotKind bitmap index

        kindFromType =
            typeToKind operandType
    in
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                operandLabel
                    ++ " "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at heap boundary"
            }

    else if kindFromBitmap /= kindFromType then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                bitmapName
                    ++ " slot "
                    ++ String.fromInt index
                    ++ " encodes kind "
                    ++ String.fromInt kindFromBitmap
                    ++ " but "
                    ++ operandLabel
                    ++ " type "
                    ++ typeToString operandType
                    ++ " requires kind "
                    ++ String.fromInt kindFromType
            }

    else
        Nothing


{-| Returns the violation, if any, in the `head_unboxed` flag of a list cons op.

The head is the first recorded operand. An `i1` head is reported, and so is a
flag that is true for a head that is not `i64`, `f64` or `i16`, or false for
one that is. A missing flag reads as false. An op with no recorded operand
types gives none.

-}
checkListHeadUnboxed : MlirOp -> Maybe Violation
checkListHeadUnboxed op =
    let
        headUnboxed =
            getBoolAttr "head_unboxed" op |> Maybe.withDefault False

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            Nothing

        Just [] ->
            Nothing

        Just (headType :: _) ->
            let
                headIsUnboxable =
                    isUnboxable headType
            in
            if headType == I1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "list head is i1 (Bool) but must be !eco.value at heap boundary"
                    }

            else if headUnboxed && not headIsUnboxable then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "head_unboxed=true but head type is "
                            ++ typeToString headType
                            ++ ", expected unboxable (i64, f64, i16)"
                    }

            else if not headUnboxed && headIsUnboxable then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "head_unboxed=false but head type is "
                            ++ typeToString headType
                            ++ ", expected !eco.value"
                    }

            else
                Nothing


{-| Returns the violations in the kinds of an `eco.papCreate`, comparing kind
N with operand N, as `checkClosureKinds` decides them. Every operand is a
captured value. An op with no recorded operand types gives none.
-}
checkPapCreateBitmap : MlirOp -> List Violation
checkPapCreateBitmap op =
    case extractOperandTypes op of
        Nothing ->
            []

        Just operandTypes ->
            checkClosureKinds op "captured operand" operandTypes


{-| Returns the violations in the kinds of an `eco.papExtend`, comparing kind
N with operand N+1, as `checkClosureKinds` decides them.

Operand 0 is the closure being extended and is not compared. The last
`eco.gc_roots_count` operands are GC root hints and are dropped first; a
missing count drops none. An op with no recorded operand types gives none.

-}
checkPapExtendBitmap : MlirOp -> List Violation
checkPapExtendBitmap op =
    let
        rootCount =
            Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)
    in
    case extractOperandTypes op of
        Nothing ->
            []

        Just allOperandTypes ->
            let
                operandTypes =
                    List.take (List.length allOperandTypes - rootCount) allOperandTypes
            in
            case List.tail operandTypes of
                Nothing ->
                    []

                Just newArgTypes ->
                    checkClosureKinds op "new arg operand" newArgTypes


{-| Returns the violations of a closure op whose compared operands have the
types `types`.

With a `slot_kinds` array, its length must equal the number of compared
operands, and entry N must be the kind of operand N (an `i1` operand is
reported whatever the entry holds). Without one, the op is a violation unless
`types` is empty. (A stale u64 bitmap is reported by `checkClosureKindLimits`.)
`operandLabel` only words the messages.

-}
checkClosureKinds : MlirOp -> String -> List MlirType -> List Violation
checkClosureKinds op operandLabel types =
    case getArrayAttr "slot_kinds" op of
        Just kindAttrs ->
            let
                kinds =
                    List.map (extractKind >> Maybe.withDefault -1) kindAttrs
            in
            if List.length kinds /= List.length types then
                [ { opId = op.id
                  , opName = op.name
                  , message =
                        "slot_kinds has "
                            ++ String.fromInt (List.length kinds)
                            ++ " entries but the op has "
                            ++ String.fromInt (List.length types)
                            ++ " "
                            ++ operandLabel
                            ++ "s"
                  }
                ]

            else
                List.map2 Tuple.pair kinds types
                    |> List.indexedMap (\i ( k, t ) -> checkSlotKind op i k t operandLabel)
                    |> List.filterMap identity

        Nothing ->
            if List.isEmpty types then
                []

            else
                [ { opId = op.id
                  , opName = op.name
                  , message =
                        "no slot_kinds for "
                            ++ String.fromInt (List.length types)
                            ++ " "
                            ++ operandLabel
                            ++ "s"
                  }
                ]


{-| The integer held by one `slot_kinds` entry, or `Nothing` for an entry that
is not an integer.
-}
extractKind : MlirAttr -> Maybe Int
extractKind attr =
    case attr of
        IntAttr _ k ->
            Just k

        _ ->
            Nothing


{-| Returns the violation, if any, for operand `index` of a closure op, whose
type is `operandType`, against its `slot_kinds` entry `kind`. An `i1` operand
is reported whatever the entry holds; otherwise the operand is reported when
the entry differs from the kind its type requires.
-}
checkSlotKind : MlirOp -> Int -> Int -> MlirType -> String -> Maybe Violation
checkSlotKind op index kind operandType operandLabel =
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                operandLabel
                    ++ " "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at heap boundary"
            }

    else if kind /= typeToKind operandType then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "slot_kinds entry "
                    ++ String.fromInt index
                    ++ " is "
                    ++ String.fromInt kind
                    ++ " but "
                    ++ operandLabel
                    ++ " type "
                    ++ typeToString operandType
                    ++ " requires kind "
                    ++ String.fromInt (typeToKind operandType)
            }

    else
        Nothing


{-| Returns one violation for each closure-op kind attribute that breaks the
post-Phase-2 form the module docstring sets out: the `eco.papExtend` ops
first, then the `eco.papCreate` ops, then the `eco.papCreateGroup` ops.
-}
checkClosureKindLimits : MlirModule -> List Violation
checkClosureKindLimits mlirModule =
    List.concatMap checkPapExtendLimits (findOpsNamed "eco.papExtend" mlirModule)
        ++ List.concatMap checkPapCreateLimits (findOpsNamed "eco.papCreate" mlirModule)
        ++ List.concatMap checkPapCreateGroupLimits (findOpsNamed "eco.papCreateGroup" mlirModule)


{-| Returns the violation, if any, for a stale u64 kind bitmap `name` that
`op` still carries (a closure op, or a record or custom construct op).
-}
checkNoLegacyBitmap : MlirOp -> String -> Maybe Violation
checkNoLegacyBitmap op name =
    if Dict.member name op.attrs then
        Just
            { opId = op.id
            , opName = op.name
            , message = name ++ " is present; " ++ op.name ++ " carries slot_kinds instead (wide-object Phases 2/3)"
            }

    else
        Nothing


{-| Returns the violation, if any, for a count `count` named `label`, when it
exceeds `HeapLimits.maxStageArity`.
-}
checkSlotCount : MlirOp -> String -> Int -> Maybe Violation
checkSlotCount op label count =
    if count > HeapLimits.maxStageArity then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                label
                    ++ " "
                    ++ String.fromInt count
                    ++ " exceeds "
                    ++ String.fromInt HeapLimits.maxStageArity
                    ++ " (closure stage arity limit, HEAP_078)"
            }

    else
        Nothing


{-| The number of entries of the `slot_kinds` array of `op`; 0 when absent.
-}
slotKindsLength : MlirOp -> Int
slotKindsLength op =
    getArrayAttr "slot_kinds" op |> Maybe.map List.length |> Maybe.withDefault 0


{-| Returns the limit violations of one `eco.papExtend`: a legacy
`newargs_unboxed_bitmap`, then its `slot_kinds` length, then its number of
real new arguments, which leaves out operand 0 (the closure) and the trailing
`eco.gc_roots_count` operands.
-}
checkPapExtendLimits : MlirOp -> List Violation
checkPapExtendLimits op =
    let
        rootCount =
            Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

        newArgCount =
            List.length op.operands - 1 - rootCount
    in
    List.filterMap identity
        [ checkNoLegacyBitmap op "newargs_unboxed_bitmap"
        , checkSlotCount op "papExtend slot_kinds length" (slotKindsLength op)
        , checkSlotCount op "papExtend real newargs" newArgCount
        ]


{-| Returns the limit violations of one `eco.papCreate`: a legacy
`unboxed_bitmap`, then its `slot_kinds` length, then its `arity`.
-}
checkPapCreateLimits : MlirOp -> List Violation
checkPapCreateLimits op =
    List.filterMap identity
        [ checkNoLegacyBitmap op "unboxed_bitmap"
        , checkSlotCount op "papCreate slot_kinds length" (slotKindsLength op)
        , checkSlotCount op "papCreate arity" (getIntAttr "arity" op |> Maybe.withDefault 0)
        ]


{-| Returns the limit violations of one `eco.papCreateGroup`: a legacy
`unboxed_bitmaps`, then the length of each sibling's `slot_kinds` array.
-}
checkPapCreateGroupLimits : MlirOp -> List Violation
checkPapCreateGroupLimits op =
    checkNoLegacyBitmap op "unboxed_bitmaps"
        :: List.map
            (\sibling ->
                checkSlotCount op
                    "papCreateGroup sibling slot_kinds length"
                    (extractArrayLength sibling)
            )
            (getArrayAttr "slot_kinds" op |> Maybe.withDefault [])
        |> List.filterMap identity


{-| The number of items of an array attribute; 0 for any other attribute.
-}
extractArrayLength : MlirAttr -> Int
extractArrayLength attr =
    case attr of
        ArrayAttr _ items ->
            List.length items

        _ ->
            0


{-| Returns how `t` is written in a violation message. A named struct gives its
bare name, so `!eco.value` reads as `eco.value`, and any function type reads as
`function`.
-}
typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            name

        FunctionType _ ->
            "function"
