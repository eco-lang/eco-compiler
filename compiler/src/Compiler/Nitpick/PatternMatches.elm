module Compiler.Nitpick.PatternMatches exposing
    ( Pattern(..), Literal(..)
    , Error(..), Context(..)
    , check
    , errorEncoder, errorDecoder
    )

{-| Pattern match exhaustiveness and redundancy checker for Elm.

This module implements Luc Maranget's algorithm for detecting incomplete and redundant
patterns in case expressions, function arguments, and let destructuring. It simplifies
canonical patterns into a normalized form, then analyzes them to find missing cases
(non-exhaustive matches) and unreachable branches (redundant patterns).

The algorithm comes from "Warnings for Pattern Matching" by Luc Maranget:
<http://moscova.inria.fr/~maranget/papers/warn/warn.pdf>


# Pattern Representation

@docs Pattern, Literal


# Error Reporting

@docs Error, Context


# Checking

@docs check


# Serialization

@docs errorEncoder, errorDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import List.Extra as List
import Prelude
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- PATTERN


{-| Simplified pattern representation used by the exhaustiveness checker.

Canonical patterns are normalized into this simpler form for analysis:
- `Anything` matches any value (wildcards, variables, records)
- `Literal` matches exact primitive values (Int, Char, String)
- `Ctor` matches custom type constructors with their arguments
-}
type Pattern
    = Anything
    | Literal Literal
    | Ctor Can.Union Name.Name (List Pattern)


{-| Literal value that can appear in patterns.

Represents primitive values that can be matched exactly:
- `Chr` for character literals
- `Str` for string literals
- `Int` for integer literals
-}
type Literal
    = Chr String
    | Str String
    | Int Int



-- CREATE SIMPLIFIED PATTERNS


simplify : Can.Pattern -> Pattern
simplify (A.At _ pattern) =
    case pattern of
        Can.PAnything ->
            Anything

        Can.PVar _ ->
            Anything

        Can.PRecord _ ->
            Anything

        Can.PUnit ->
            Ctor unit unitName []

        Can.PTuple a b [] ->
            Ctor pair pairName [ simplify a, simplify b ]

        Can.PTuple a b [ c ] ->
            Ctor triple tripleName [ simplify a, simplify b, simplify c ]

        Can.PTuple a b cs ->
            Ctor nTuple nTupleName (List.map simplify (a :: b :: cs))

        Can.PCtor { union, name, args } ->
            List.map (\(Can.PatternCtorArg _ _ arg) -> simplify arg) args |> Ctor union name

        Can.PList entries ->
            List.foldr cons nil entries

        Can.PCons hd tl ->
            cons hd (simplify tl)

        Can.PAlias subPattern _ ->
            simplify subPattern

        Can.PInt int ->
            Literal (Int int)

        Can.PStr str _ ->
            Literal (Str str)

        Can.PChr chr ->
            Literal (Chr chr)

        Can.PBool union bool ->
            Ctor union
                (if bool then
                    Name.true

                 else
                    Name.false
                )
                []


cons : Can.Pattern -> Pattern -> Pattern
cons hd tl =
    Ctor list consName [ simplify hd, tl ]


nil : Pattern
nil =
    Ctor list nilName []



-- BUILT-IN UNIONS


unit : Can.Union
unit =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = unitName, index = Index.first, numArgs = 0, args = [] }
    in
    Can.Union { vars = [], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


pair : Can.Union
pair =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = pairName, index = Index.first, numArgs = 2, args = [ Can.TVar "a", Can.TVar "b" ] }
    in
    Can.Union { vars = [ "a", "b" ], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


triple : Can.Union
triple =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = tripleName, index = Index.first, numArgs = 3, args = [ Can.TVar "a", Can.TVar "b", Can.TVar "c" ] }
    in
    Can.Union { vars = [ "a", "b", "c" ], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


nTuple : Can.Union
nTuple =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = nTupleName, index = Index.first, numArgs = 3, args = [ Can.TVar "a", Can.TVar "b", Can.TVar "cs" ] }
    in
    Can.Union { vars = [ "a", "b", "cs" ], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


list : Can.Union
list =
    let
        nilCtor : Can.Ctor
        nilCtor =
            Can.Ctor { name = nilName, index = Index.first, numArgs = 0, args = [] }

        consCtor : Can.Ctor
        consCtor =
            Can.Ctor
                { name = consName
                , index = Index.second
                , numArgs = 2
                , args =
                    [ Can.TVar "a"
                    , Can.TType ModuleName.list Name.list [ Can.TVar "a" ]
                    ]
                }
    in
    Can.Union { vars = [ "a" ], alts = [ nilCtor, consCtor ], numAlts = 2, opts = Can.Normal }


unitName : Name.Name
unitName =
    "#0"


pairName : Name.Name
pairName =
    "#2"


tripleName : Name.Name
tripleName =
    "#3"


nTupleName : Name.Name
nTupleName =
    "#N"


consName : Name.Name
consName =
    "::"


nilName : Name.Name
nilName =
    "[]"



-- ERROR


{-| Pattern matching error detected during exhaustiveness checking.

- `Incomplete` indicates missing cases in pattern matching, with the region,
  context where the error occurred, and example patterns that are not covered
- `Redundant` indicates an unreachable pattern, with the overall match region,
  the redundant pattern's region, and its 1-based index in the pattern list
-}
type Error
    = Incomplete A.Region Context (List Pattern)
    | Redundant A.Region A.Region Int


{-| Context where a pattern matching error occurred.

- `BadArg` means the error is in a function argument pattern
- `BadDestruct` means the error is in a let-destructuring pattern
- `BadCase` means the error is in a case expression
-}
type Context
    = BadArg
    | BadDestruct
    | BadCase



-- CHECK


{-| Check a canonical module for pattern matching errors.

Traverses all declarations, expressions, and patterns in the module to find:
- Non-exhaustive pattern matches (missing cases)
- Redundant patterns (unreachable branches)

Returns `Ok ()` if all patterns are valid, or `Err` with a list of errors found.
-}
check : Can.Module -> Result (NE.Nonempty Error) ()
check (Can.Module canData) =
    case checkDecls canData.decls [] identity of
        [] ->
            Ok ()

        e :: es ->
            Err (NE.Nonempty e es)



-- CHECK DECLS


checkDecls : Can.Decls -> List Error -> (List Error -> List Error) -> List Error
checkDecls decls errors cont =
    case decls of
        Can.Declare def subDecls ->
            checkDecls subDecls errors (checkDef def >> cont)

        Can.DeclareRec def defs subDecls ->
            List.foldr checkDef (checkDecls subDecls errors (checkDef def >> cont)) defs

        Can.SaveTheEnvironment ->
            cont errors



-- CHECK DEFS


checkDef : Can.Def -> List Error -> List Error
checkDef def errors =
    case def of
        Can.Def _ args body ->
            List.foldr checkArg (checkExpr body errors) args

        Can.TypedDef _ _ args body _ ->
            List.foldr checkTypedArg (checkExpr body errors) args


checkArg : Can.Pattern -> List Error -> List Error
checkArg ((A.At region _) as pattern) errors =
    checkPatterns region BadArg [ pattern ] errors


checkTypedArg : ( Can.Pattern, tipe ) -> List Error -> List Error
checkTypedArg ( (A.At region _) as pattern, _ ) errors =
    checkPatterns region BadArg [ pattern ] errors



-- CHECK EXPRESSIONS


checkExpr : Can.Expr -> List Error -> List Error
checkExpr (A.At region expression) errors =
    case expression of
        Can.VarLocal _ ->
            errors

        Can.VarTopLevel _ _ ->
            errors

        Can.VarKernel _ _ ->
            errors

        Can.VarForeign _ _ _ ->
            errors

        Can.VarCtor _ _ _ _ _ ->
            errors

        Can.VarDebug _ _ _ ->
            errors

        Can.VarOperator _ _ _ _ ->
            errors

        Can.Chr _ ->
            errors

        Can.Str _ ->
            errors

        Can.Int _ ->
            errors

        Can.Float _ ->
            errors

        Can.List entries ->
            List.foldr checkExpr errors entries

        Can.Negate expr ->
            checkExpr expr errors

        Can.Binop _ _ _ _ left right ->
            checkExpr left
                (checkExpr right errors)

        Can.Lambda args body ->
            List.foldr checkArg (checkExpr body errors) args

        Can.Call func args ->
            checkExpr func (List.foldr checkExpr errors args)

        Can.If branches finally ->
            List.foldr checkIfBranch (checkExpr finally errors) branches

        Can.Let def body ->
            checkDef def (checkExpr body errors)

        Can.LetRec defs body ->
            List.foldr checkDef (checkExpr body errors) defs

        Can.LetDestruct ((A.At reg _) as pattern) expr body ->
            checkExpr expr (checkExpr body errors) |> checkPatterns reg BadDestruct [ pattern ]

        Can.Case expr branches ->
            checkExpr expr (checkCases region branches errors)

        Can.Accessor _ ->
            errors

        Can.Access record _ ->
            checkExpr record errors

        Can.Update record fields ->
            Dict.foldr A.compareLocated (\_ -> checkField) errors fields |> checkExpr record

        Can.Record fields ->
            Dict.foldr A.compareLocated (\_ -> checkExpr) errors fields

        Can.Unit ->
            errors

        Can.Tuple a b cs ->
            checkExpr a
                (checkExpr b
                    (List.foldr checkExpr errors cs)
                )

        Can.Shader _ _ ->
            errors



-- CHECK FIELD


checkField : Can.FieldUpdate -> List Error -> List Error
checkField (Can.FieldUpdate _ expr) errors =
    checkExpr expr errors



-- CHECK IF BRANCH


checkIfBranch : ( Can.Expr, Can.Expr ) -> List Error -> List Error
checkIfBranch ( condition, branch ) errs =
    checkExpr condition (checkExpr branch errs)



-- CHECK CASE EXPRESSION


checkCases : A.Region -> List Can.CaseBranch -> List Error -> List Error
checkCases region branches errors =
    let
        ( patterns, newErrors ) =
            List.foldr checkCaseBranch ( [], errors ) branches
    in
    checkPatterns region BadCase patterns newErrors


checkCaseBranch : Can.CaseBranch -> ( List Can.Pattern, List Error ) -> ( List Can.Pattern, List Error )
checkCaseBranch (Can.CaseBranch pattern expr) ( patterns, errors ) =
    ( pattern :: patterns
    , checkExpr expr errors
    )



-- CHECK PATTERNS


checkPatterns : A.Region -> Context -> List Can.Pattern -> List Error -> List Error
checkPatterns region context patterns errors =
    case toNonRedundantRows region patterns of
        Err err ->
            err :: errors

        Ok matrix ->
            case isExhaustive matrix 1 of
                [] ->
                    errors

                badPatterns ->
                    Incomplete region context (List.map Prelude.head badPatterns) :: errors



-- EXHAUSTIVE PATTERNS
-- INVARIANTS:
--
--   The initial rows "matrix" are all of length 1
--   The initial count of items per row "n" is also 1
--   The resulting rows are examples of missing patterns
--


isExhaustive : List (List Pattern) -> Int -> List (List Pattern)
isExhaustive matrix n =
    case matrix of
        [] ->
            [ List.repeat n Anything ]

        _ ->
            if n == 0 then
                []

            else
                let
                    ctors : Dict String Name.Name Can.Union
                    ctors =
                        collectCtors matrix

                    numSeen : Int
                    numSeen =
                        Dict.size ctors
                in
                if numSeen == 0 then
                    List.map ((::) Anything)
                        (isExhaustive (List.filterMap specializeRowByAnything matrix) (n - 1))

                else
                    let
                        ((Can.Union altsData) as alts) =
                            Tuple.second (Utils.mapFindMin ctors)
                    in
                    if numSeen < altsData.numAlts then
                        List.filterMap (isMissing alts ctors) altsData.alts
                            |> List.map (::)
                            |> List.andMap (isExhaustive (List.filterMap specializeRowByAnything matrix) (n - 1))

                    else
                        let
                            isAltExhaustive : Can.Ctor -> List (List Pattern)
                            isAltExhaustive (Can.Ctor c) =
                                List.map (recoverCtor alts c.name c.numArgs)
                                    (isExhaustive
                                        (List.filterMap (specializeRowByCtor c.name c.numArgs) matrix)
                                        (c.numArgs + n - 1)
                                    )
                        in
                        List.concatMap isAltExhaustive altsData.alts


isMissing : Can.Union -> Dict String Name.Name a -> Can.Ctor -> Maybe Pattern
isMissing union ctors (Can.Ctor c) =
    if Dict.member identity c.name ctors then
        Nothing

    else
        Just (Ctor union c.name (List.repeat c.numArgs Anything))


recoverCtor : Can.Union -> Name.Name -> Int -> List Pattern -> List Pattern
recoverCtor union name arity patterns =
    let
        ( args, rest ) =
            List.splitAt arity patterns
    in
    Ctor union name args :: rest



-- REDUNDANT PATTERNS


{-| INVARIANT: Produces a list of rows where (forall row. length row == 1)
-}
toNonRedundantRows : A.Region -> List Can.Pattern -> Result Error (List (List Pattern))
toNonRedundantRows region patterns =
    toSimplifiedUsefulRows region [] patterns


{-| INVARIANT: Produces a list of rows where (forall row. length row == 1)
-}
toSimplifiedUsefulRows : A.Region -> List (List Pattern) -> List Can.Pattern -> Result Error (List (List Pattern))
toSimplifiedUsefulRows overallRegion checkedRows uncheckedPatterns =
    case uncheckedPatterns of
        [] ->
            Ok checkedRows

        ((A.At region _) as pattern) :: rest ->
            let
                nextRow : List Pattern
                nextRow =
                    [ simplify pattern ]
            in
            if isUseful checkedRows nextRow then
                toSimplifiedUsefulRows overallRegion (nextRow :: checkedRows) rest

            else
                Err (Redundant overallRegion region (List.length checkedRows + 1))



-- Check if a new row "vector" is useful given previous rows "matrix"


isUseful : List (List Pattern) -> List Pattern -> Bool
isUseful matrix vector =
    case matrix of
        [] ->
            -- No rows are the same as the new vector! The vector is useful!
            True

        _ ->
            case vector of
                [] ->
                    -- There is nothing left in the new vector, but we still have
                    -- rows that match the same things. This is not a useful vector!
                    False

                firstPattern :: patterns ->
                    case firstPattern of
                        Ctor _ name args ->
                            -- keep checking rows that start with this Ctor or Anything
                            isUseful
                                (List.filterMap (specializeRowByCtor name (List.length args)) matrix)
                                (args ++ patterns)

                        Anything ->
                            -- check if all alts appear in matrix
                            case isComplete matrix of
                                No ->
                                    -- This Anything is useful because some Ctors are missing.
                                    -- But what if a previous row has an Anything?
                                    -- If so, this one is not useful.
                                    isUseful (List.filterMap specializeRowByAnything matrix) patterns

                                Yes alts ->
                                    -- All Ctors are covered, so this Anything is not needed for any
                                    -- of those. But what if some of those Ctors have subpatterns
                                    -- that make them less general? If so, this actually is useful!
                                    let
                                        isUsefulAlt : Can.Ctor -> Bool
                                        isUsefulAlt (Can.Ctor c) =
                                            isUseful
                                                (List.filterMap (specializeRowByCtor c.name c.numArgs) matrix)
                                                (List.repeat c.numArgs Anything ++ patterns)
                                    in
                                    List.any isUsefulAlt alts

                        Literal literal ->
                            -- keep checking rows that start with this Literal or Anything
                            isUseful
                                (List.filterMap (specializeRowByLiteral literal) matrix)
                                patterns



-- INVARIANT: (length row == N) ==> (length result == arity + N - 1)


specializeRowByCtor : Name.Name -> Int -> List Pattern -> Maybe (List Pattern)
specializeRowByCtor ctorName arity row =
    case row of
        (Ctor _ name args) :: patterns ->
            if name == ctorName then
                Just (args ++ patterns)

            else
                Nothing

        Anything :: patterns ->
            Just (List.repeat arity Anything ++ patterns)

        (Literal _) :: _ ->
            "Compiler bug! After type checking, constructors and literals should never align in pattern match exhaustiveness checks." |> crash

        [] ->
            crash "Compiler error! Empty matrices should not get specialized."



-- INVARIANT: (length row == N) ==> (length result == N-1)


specializeRowByLiteral : Literal -> List Pattern -> Maybe (List Pattern)
specializeRowByLiteral literal row =
    case row of
        (Literal lit) :: patterns ->
            if lit == literal then
                Just patterns

            else
                Nothing

        Anything :: patterns ->
            Just patterns

        (Ctor _ _ _) :: _ ->
            "Compiler bug! After type checking, constructors and literals should never align in pattern match exhaustiveness checks." |> crash

        [] ->
            crash "Compiler error! Empty matrices should not get specialized."



-- INVARIANT: (length row == N) ==> (length result == N-1)


specializeRowByAnything : List Pattern -> Maybe (List Pattern)
specializeRowByAnything row =
    case row of
        [] ->
            Nothing

        (Ctor _ _ _) :: _ ->
            Nothing

        Anything :: patterns ->
            Just patterns

        (Literal _) :: _ ->
            Nothing



-- ALL CONSTRUCTORS ARE PRESENT?


type Complete
    = Yes (List Can.Ctor)
    | No


isComplete : List (List Pattern) -> Complete
isComplete matrix =
    let
        ctors : Dict String Name.Name Can.Union
        ctors =
            collectCtors matrix

        numSeen : Int
        numSeen =
            Dict.size ctors
    in
    if numSeen == 0 then
        No

    else
        let
            (Can.Union unionData) =
                Tuple.second (Utils.mapFindMin ctors)
        in
        if numSeen == unionData.numAlts then
            Yes unionData.alts

        else
            No



-- COLLECT CTORS


collectCtors : List (List Pattern) -> Dict String Name.Name Can.Union
collectCtors matrix =
    List.foldl (\row acc -> collectCtorsHelp acc row) Dict.empty matrix


collectCtorsHelp : Dict String Name.Name Can.Union -> List Pattern -> Dict String Name.Name Can.Union
collectCtorsHelp ctors row =
    case row of
        (Ctor union name _) :: _ ->
            Dict.insert identity name union ctors

        _ ->
            ctors



-- ENCODERS and DECODERS


{-| Encode a pattern matching error to bytes for caching or serialization.
-}
errorEncoder : Error -> Bytes.Encode.Encoder
errorEncoder error =
    case error of
        Incomplete region context unhandled ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , contextEncoder context
                , BE.list patternEncoder unhandled
                ]

        Redundant caseRegion patternRegion index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.regionEncoder caseRegion
                , A.regionEncoder patternRegion
                , BE.int index
                ]


{-| Decode a pattern matching error from bytes after deserialization.
-}
errorDecoder : Bytes.Decode.Decoder Error
errorDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Incomplete
                            A.regionDecoder
                            contextDecoder
                            (BD.list patternDecoder)

                    1 ->
                        Bytes.Decode.map3 Redundant
                            A.regionDecoder
                            A.regionDecoder
                            BD.int

                    _ ->
                        Bytes.Decode.fail
            )


contextEncoder : Context -> Bytes.Encode.Encoder
contextEncoder context =
    Bytes.Encode.unsignedInt8
        (case context of
            BadArg ->
                0

            BadDestruct ->
                1

            BadCase ->
                2
        )


contextDecoder : Bytes.Decode.Decoder Context
contextDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\str ->
                case str of
                    0 ->
                        Bytes.Decode.succeed BadArg

                    1 ->
                        Bytes.Decode.succeed BadDestruct

                    2 ->
                        Bytes.Decode.succeed BadCase

                    _ ->
                        Bytes.Decode.fail
            )


patternEncoder : Pattern -> Bytes.Encode.Encoder
patternEncoder pattern =
    case pattern of
        Anything ->
            Bytes.Encode.unsignedInt8 0

        Literal index ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , literalEncoder index
                ]

        Ctor union name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , Can.unionEncoder union
                , BE.string name
                , BE.list patternEncoder args
                ]


patternDecoder : Bytes.Decode.Decoder Pattern
patternDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed Anything

                    1 ->
                        Bytes.Decode.map Literal literalDecoder

                    2 ->
                        Bytes.Decode.map3 Ctor
                            Can.unionDecoder
                            BD.string
                            (BD.list patternDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


literalEncoder : Literal -> Bytes.Encode.Encoder
literalEncoder literal =
    case literal of
        Chr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string value
                ]

        Str value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string value
                ]

        Int value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.int value
                ]


literalDecoder : Bytes.Decode.Decoder Literal
literalDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Chr BD.string

                    1 ->
                        Bytes.Decode.map Str BD.string

                    2 ->
                        Bytes.Decode.map Int BD.int

                    _ ->
                        Bytes.Decode.fail
            )
