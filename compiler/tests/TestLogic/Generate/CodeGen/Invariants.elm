module TestLogic.Generate.CodeGen.Invariants exposing
    ( Violation, violationsToExpectation
    , walkAllOps, walkOpAndChildren, walkOpsInRegion
    , findOpsNamed, findOpsWithPrefix, findFuncOps
    , getIntAttr, getStringAttr, getArrayAttr, getTypeAttr, getBoolAttr
    , extractOperandTypes, extractResultTypes
    , isEcoValueType
    , checkNone
    , allBlocks
    , TypeEnv, typeEnvOfOp, findSymbolOps, isEcoPrimitive, isUnboxable, isValidTerminator, typesMatch
    )

{-| The MLIR that the code generator produces must obey rules that no type in
`Mlir.Mlir` enforces, and separate test modules, the checkers, test those rules.
This module is the toolkit the checkers share: walking a generated `MlirModule`,
reading op attributes and types, and turning what a check finds into an
`Expectation`.

A _violation_ is one op that breaks a rule, recorded with the op's id and name
and a message saying what is wrong. A checker collects violations, and
`violationsToExpectation` passes when there are none.

The walks flatten the nested op tree into a list. A module's body holds
top-level ops, an op holds regions, a region holds an entry block followed by
its labelled blocks, and a block holds body ops followed by a terminator. Each
walk lists an op before the ops nested in its regions, and a block's terminator
after its body, so a checker that walks every op sees the terminators too.
`findFuncOps` and `findSymbolOps` are different: they look only at the module's
top-level ops.

The attribute readers return `Nothing` when the attribute is absent or of
another kind. Operand types are not part of an `MlirOp`. They are read from the
op's `_operand_types` attribute, an array of type attributes, and an op without
it has no operand types to check here.

The type predicates name three sets of MLIR types. `isEcoValueType` recognises
`!eco.value`, the type of a boxed value. `isUnboxable` recognises `i64`, `f64`
and `i16`, the types an Int, a Float and a Char have when stored unboxed.
`isEcoPrimitive` adds `i1`, the type a Bool has in SSA operand context, such as
the result of an `eco.unbox`; at function boundaries and in heap objects a Bool
is `!eco.value`. Which values are unboxed where is decided by
`Compiler.Generate.MLIR.Types`.


# Violation Tracking

@docs Violation, violationsToExpectation


# Op Walking

@docs walkAllOps, walkOpAndChildren, walkOpsInRegion


# Op Finding

@docs findOpsNamed, findOpsWithPrefix, findFuncOps


# Attribute Extraction

@docs getIntAttr, getStringAttr, getArrayAttr, getTypeAttr, getBoolAttr


# Type Extraction

@docs extractOperandTypes, extractResultTypes


# Type Predicates

@docs isEcoValueType


# Checking Utilities

@docs checkNone


# Block Utilities

@docs allBlocks


# Type Environment and Helpers

@docs TypeEnv, typeEnvOfOp, findSymbolOps, isEcoPrimitive, isUnboxable, isValidTerminator, typesMatch

-}

import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict



-- VIOLATION TRACKING


{-| A report that one op breaks a rule, identifying the op by its `id` and
`name`.
-}
type alias Violation =
    { opId : String
    , opName : String
    , message : String
    }


{-| Returns an expectation that passes when `violations` is empty and fails
otherwise.

When `violations` is not empty, the expectation fails with one line per
violation, in list order, each reading
`Violation in <opName> (<opId>): <message>`.

-}
violationsToExpectation : List Violation -> Expectation
violationsToExpectation violations =
    case violations of
        [] ->
            Expect.pass

        _ ->
            Expect.fail (String.join "\n" (List.map formatViolation violations))


{-| Returns the failure message for one violation, in the form
`Violation in <opName> (<opId>): <message>`.
-}
formatViolation : Violation -> String
formatViolation v =
    "Violation in " ++ v.opName ++ " (" ++ v.opId ++ "): " ++ v.message



-- OP WALKING


{-| Returns every op in the module, at any depth: each top-level op in turn,
followed by the ops nested in its regions.
-}
walkAllOps : MlirModule -> List MlirOp
walkAllOps mod =
    List.concatMap walkOpAndChildren mod.body


{-| Returns `op` followed by every op nested in its regions, at any depth,
region by region.
-}
walkOpAndChildren : MlirOp -> List MlirOp
walkOpAndChildren op =
    op :: List.concatMap walkOpsInRegion op.regions


{-| Returns every op in the region, at any depth: those of the entry block
first, then those of each labelled block in the order the region holds them. A
block's terminator comes after its body.
-}
walkOpsInRegion : MlirRegion -> List MlirOp
walkOpsInRegion (MlirRegion { entry, blocks }) =
    walkOpsInBlock entry ++ List.concatMap walkOpsInBlock (OrderedDict.values blocks)


{-| Returns every op in the block, at any depth: the body ops and then the
terminator, each followed by the ops nested in it. A body op is included even
when it is flagged `isTerminator`, although `Mlir.Pretty` skips such an op.
-}
walkOpsInBlock : MlirBlock -> List MlirOp
walkOpsInBlock block =
    List.concatMap walkOpAndChildren block.body
        ++ walkOpAndChildren block.terminator



-- OP FINDING


{-| Returns every op in the module, at any depth, whose name is exactly `name`.
-}
findOpsNamed : String -> MlirModule -> List MlirOp
findOpsNamed name mod =
    List.filter (\op -> op.name == name) (walkAllOps mod)


{-| Returns every op in the module, at any depth, whose name starts with
`prefix`.
-}
findOpsWithPrefix : String -> MlirModule -> List MlirOp
findOpsWithPrefix prefix mod =
    List.filter (\op -> String.startsWith prefix op.name) (walkAllOps mod)


{-| Returns the module's top-level `func.func` ops. A `func.func` nested in
another op's region is not included.
-}
findFuncOps : MlirModule -> List MlirOp
findFuncOps mod =
    List.filter (\op -> op.name == "func.func") mod.body



-- ATTRIBUTE EXTRACTION


{-| Reads the integer attribute `key` of `op`, ignoring the attribute's type.
Returns `Nothing` if the attribute is absent or is not an integer.
-}
getIntAttr : String -> MlirOp -> Maybe Int
getIntAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractInt


{-| Returns the value of an integer attribute, or `Nothing` for any other kind
of attribute.
-}
extractInt : MlirAttr -> Maybe Int
extractInt attr =
    case attr of
        IntAttr _ n ->
            Just n

        _ ->
            Nothing


{-| Reads the string attribute `key` of `op`, as stored, with no unescaping. A
symbol reference is accepted too and gives the symbol's name. Returns `Nothing`
if the attribute is absent or of another kind.
-}
getStringAttr : String -> MlirOp -> Maybe String
getStringAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractString


{-| Returns the string of a string attribute or the name in a symbol reference,
or `Nothing` for any other kind of attribute.
-}
extractString : MlirAttr -> Maybe String
extractString attr =
    case attr of
        StringAttr s ->
            Just s

        SymbolRefAttr s ->
            Just s

        _ ->
            Nothing


{-| Reads the items of the array attribute `key` of `op`, whether or not the
array has an element type. Returns `Nothing` if the attribute is absent or is
not an array.
-}
getArrayAttr : String -> MlirOp -> Maybe (List MlirAttr)
getArrayAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractArray


{-| Returns the items of an array attribute, or `Nothing` for any other kind of
attribute.
-}
extractArray : MlirAttr -> Maybe (List MlirAttr)
extractArray attr =
    case attr of
        ArrayAttr _ items ->
            Just items

        _ ->
            Nothing


{-| Reads the type held by the type attribute `key` of `op`. Returns `Nothing`
if the attribute is absent or is not a type attribute.
-}
getTypeAttr : String -> MlirOp -> Maybe MlirType
getTypeAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractType


{-| Returns the type held by a type attribute, or `Nothing` for any other kind
of attribute.
-}
extractType : MlirAttr -> Maybe MlirType
extractType attr =
    case attr of
        TypeAttr t ->
            Just t

        _ ->
            Nothing


{-| Reads the boolean attribute `key` of `op`. An integer attribute is accepted
too and reads as `True` when it is non-zero. Returns `Nothing` if the attribute
is absent or of another kind.
-}
getBoolAttr : String -> MlirOp -> Maybe Bool
getBoolAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractBool


{-| Returns the value of a boolean attribute, or `True` for a non-zero integer
attribute and `False` for zero, or `Nothing` for any other kind of attribute.
-}
extractBool : MlirAttr -> Maybe Bool
extractBool attr =
    case attr of
        BoolAttr b ->
            Just b

        IntAttr _ n ->
            Just (n /= 0)

        _ ->
            Nothing



-- TYPE EXTRACTION


{-| Returns the operand types recorded in the `_operand_types` array attribute
of `op`, in order, or `Nothing` if the op has no such array. Items that are not
type attributes are left out.
-}
extractOperandTypes : MlirOp -> Maybe (List MlirType)
extractOperandTypes op =
    getArrayAttr "_operand_types" op
        |> Maybe.map (List.filterMap extractTypeFromAttr)


{-| Returns the type held by a type attribute, or `Nothing` for any other kind
of attribute.
-}
extractTypeFromAttr : MlirAttr -> Maybe MlirType
extractTypeFromAttr attr =
    case attr of
        TypeAttr t ->
            Just t

        _ ->
            Nothing


{-| Returns the types of the results of `op`, in order.
-}
extractResultTypes : MlirOp -> List MlirType
extractResultTypes op =
    List.map Tuple.second op.results



-- TYPE PREDICATES


{-| Returns whether `t` is `!eco.value`, the named struct type `eco.value`.
-}
isEcoValueType : MlirType -> Bool
isEcoValueType t =
    case t of
        NamedStruct name ->
            name == "eco.value"

        _ ->
            False


{-| Returns whether `t` is `i64`, `f64` or `i16`, the types an Int, a Float and
a Char have when stored unboxed. `i1` is not accepted, because a Bool in a heap
object is `!eco.value`.
-}
isUnboxable : MlirType -> Bool
isUnboxable t =
    case t of
        I16 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False


{-| Returns whether `t` is `i1`, `i16`, `i64` or `f64`: the types `isUnboxable`
accepts, plus `i1`, which a Bool has in SSA operand context, such as the result
of an `eco.unbox`, but not at function boundaries or in a heap object.
-}
isEcoPrimitive : MlirType -> Bool
isEcoPrimitive t =
    case t of
        I1 ->
            True

        I16 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False



-- CHECKING UTILITIES


{-| Returns one violation carrying `message` for each op in `ops`. A checker
that expects to find no such ops gets an empty list exactly when there are none.
-}
checkNone : String -> List MlirOp -> List Violation
checkNone message ops =
    List.map (\op -> { opId = op.id, opName = op.name, message = message }) ops



-- BLOCK UTILITIES


{-| Returns the region's blocks: the entry block first, then the labelled blocks
in the order the region holds them. Blocks of nested regions are not included.
-}
allBlocks : MlirRegion -> List MlirBlock
allBlocks (MlirRegion { entry, blocks }) =
    entry :: OrderedDict.values blocks



-- TYPE COMPARISON


{-| Returns whether the two types are equal. This is plain structural equality,
with no normalisation.
-}
typesMatch : MlirType -> MlirType -> Bool
typesMatch t1 t2 =
    t1 == t2



-- TERMINATOR VALIDATION


{-| The names of the ops `isValidTerminator` accepts at the end of a block.

`eco.case` is not among them: `Compiler.Generate.MLIR.Ops` describes it as a
value-producing expression, not a terminator.

-}
validTerminators : List String
validTerminators =
    [ "eco.return"
    , "eco.jump"
    , "eco.crash"
    , "eco.yield"
    , "scf.yield"
    , "scf.condition"
    , "cf.br"
    , "cf.cond_br"
    , "func.return"
    ]


{-| Returns whether the name of `op` is one accepted at the end of a block:
`eco.return`, `eco.jump`, `eco.crash`, `eco.yield`, `scf.yield`,
`scf.condition`, `cf.br`, `cf.cond_br` or `func.return`.

Only the name is checked, not where the op is, so `eco.yield` is accepted at the
end of any block. `eco.case` is not accepted.

-}
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name validTerminators



-- SYMBOL FINDING


{-| Returns each top-level op of the module whose `sym_name` attribute is a
string or a symbol reference, paired with that name. Ops nested in regions are
not searched.
-}
findSymbolOps : MlirModule -> List ( String, MlirOp )
findSymbolOps mod =
    List.filterMap
        (\op ->
            getStringAttr "sym_name" op
                |> Maybe.map (\name -> ( name, op ))
        )
        mod.body



-- TYPE ENVIRONMENT


{-| The types of SSA values, keyed by the names ops use for them in their
operands and results.

This is a name for a `Dict`, not a new type. `typeEnvOfOp` builds one.

-}
type alias TypeEnv =
    Dict String MlirType


{-| Returns the defined type of every SSA name introduced by `op` or anywhere
inside it: the results of `op` and of every nested op, and the arguments of
every block of every nested region. Where a name is defined twice, the later
definition in walk order wins.
-}
typeEnvOfOp : MlirOp -> TypeEnv
typeEnvOfOp op =
    walkOpAndChildren op
        |> List.concatMap
            (\o -> o.results ++ List.concatMap (\r -> List.concatMap .args (allBlocks r)) o.regions)
        |> Dict.fromList
