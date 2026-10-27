module Compiler.Nitpick.PatternMatches exposing
    ( Pattern(..), Literal(..)
    , Error(..), Context(..)
    , check
    , errorEncoder, errorDecoder
    )

{-| A pattern match that misses a value would fail at run time, and a branch
that can never be reached is almost always a mistake, so every pattern match in
a canonical module is checked for both before it is compiled.

`check` looks at three kinds of match: a function or lambda argument, the
pattern of a `let` destructuring, and the branches of a `case`. A match that
misses cases is reported as an `Incomplete` error, whose `Context` says which
kind of match it was; a `Redundant` error does not say.

The method is Luc Maranget's, from "Warnings for Pattern Matching". The patterns
of one match are rows of a matrix, and each canonical pattern is first
simplified to a `Pattern`, which keeps only what decides whether a value
matches. Unit, tuples and lists become constructors of built-in unions, and
`Bool` a constructor of its own union, so that every pattern is a wildcard, a
literal or a constructor.

Two questions are then asked of the matrix. A row is _useful_ when it matches
some value that no earlier row matches; a row that is not useful is redundant.
The match is _exhaustive_ when no value escapes every row; when it is not, the
check produces example patterns of the values that escape. Both questions are
answered by _specialising_ the matrix: keeping the rows that can match a given
constructor, literal or wildcard in the first column, and replacing that column
by what remains to be matched.

Redundancy is checked first. The first redundant branch of a match is the only
error reported for it, and that match is not then checked for missing cases.

A literal never covers its type, since `Int`, `Char` and `String` have no finite
list of values, so a match on literals is exhaustive only with a wildcard.

The functions that specialise rows crash on a row where a literal meets a
constructor in the same column. They rely on the module having been type
checked, which makes that impossible.

@docs Pattern, Literal
@docs Error, Context
@docs check
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
import Data.Map
import Dict exposing (Dict)
import List.Extra as List
import Prelude
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== PATTERN ======


{-| A pattern reduced to what decides whether a value matches it.

`Anything` matches every value. A wildcard, a variable and a record pattern all
become `Anything`, and an alias pattern (`p as x`) becomes whatever `p` does.

`Literal` matches exactly one `Int`, `Char` or `String`.

`Ctor` matches one constructor of the union it carries, with a pattern for each
argument. Besides custom types it stands for `Bool`, unit, tuples and lists,
using built-in unions whose constructors are named `#0` for unit, `#2` for a
pair, `#3` for a triple, and `[]` and `::` for lists. A list pattern
`[ a, b ]` becomes `a :: b :: []`.

-}
type Pattern
    = Anything
    | Literal Literal
    | Ctor Can.Union Name.Name (List Pattern)


{-| A literal value a pattern can match exactly.

`Chr` carries the character as the `String` the canonical pattern holds.

-}
type Literal
    = Chr String
    | Str String
    | Int Int



-- ====== CREATE SIMPLIFIED PATTERNS ======


{-| Returns the `Pattern` that matches the same values as a canonical pattern.
-}
simplify : Can.Pattern -> Pattern
simplify (A.At _ patternInfo) =
    case patternInfo.node of
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


{-| Builds the `::` pattern of a canonical head and an already simplified tail.
-}
cons : Can.Pattern -> Pattern -> Pattern
cons hd tl =
    Ctor list consName [ simplify hd, tl ]


{-| The pattern of the empty list.
-}
nil : Pattern
nil =
    Ctor list nilName []



-- ====== BUILT-IN UNIONS ======


{-| The built-in union of the unit value, with the one constructor `#0`.
-}
unit : Can.Union
unit =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = unitName, index = Index.first, numArgs = 0, args = [] }
    in
    Can.Union { vars = [], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


{-| The built-in union of pairs, with the one two-argument constructor `#2`.
-}
pair : Can.Union
pair =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = pairName, index = Index.first, numArgs = 2, args = [ Can.TVar "a", Can.TVar "b" ] }
    in
    Can.Union { vars = [ "a", "b" ], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


{-| The built-in union of triples, with the one three-argument constructor `#3`.
-}
triple : Can.Union
triple =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = tripleName, index = Index.first, numArgs = 3, args = [ Can.TVar "a", Can.TVar "b", Can.TVar "c" ] }
    in
    Can.Union { vars = [ "a", "b", "c" ], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


{-| The built-in union for a tuple of more than three elements, with the one
constructor `#N`.

It declares three arguments whatever the tuple's size. Such a tuple cannot reach
this module, because canonicalization rejects tuples larger than three.

-}
nTuple : Can.Union
nTuple =
    let
        ctor : Can.Ctor
        ctor =
            Can.Ctor { name = nTupleName, index = Index.first, numArgs = 3, args = [ Can.TVar "a", Can.TVar "b", Can.TVar "cs" ] }
    in
    Can.Union { vars = [ "a", "b", "cs" ], alts = [ ctor ], numAlts = 1, opts = Can.Normal }


{-| The built-in union of lists, with the constructors `[]` and `::`.
-}
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


{-| The constructor name that stands for the unit value.
-}
unitName : Name.Name
unitName =
    "#0"


{-| The constructor name that stands for a pair.
-}
pairName : Name.Name
pairName =
    "#2"


{-| The constructor name that stands for a triple.
-}
tripleName : Name.Name
tripleName =
    "#3"


{-| The constructor name that stands for a tuple of more than three elements.
-}
nTupleName : Name.Name
nTupleName =
    "#N"


{-| The constructor name that stands for a non-empty list.
-}
consName : Name.Name
consName =
    "::"


{-| The constructor name that stands for the empty list.
-}
nilName : Name.Name
nilName =
    "[]"



-- ====== ERROR ======


{-| A fault in one pattern match.

`Incomplete` carries the region of the match, the kind of match, and one example
pattern for each group of values that no pattern matches. The region is that of
the whole `case` expression, or of the argument or destructuring pattern.

`Redundant` carries the region of the whole match, the region of the first
pattern that can never match, and that pattern's position among the match's
patterns, counting from 1.

-}
type Error
    = Incomplete A.Region Context (List Pattern)
    | Redundant A.Region A.Region Int


{-| The kind of pattern match an `Error` is about.

`BadArg` is the pattern of one argument of a function or a lambda. `BadDestruct`
is the pattern of a `let` destructuring. `BadCase` is the branches of a `case`
expression.

-}
type Context
    = BadArg
    | BadDestruct
    | BadCase



-- ====== CHECK ======


{-| Checks every pattern match in a module's declarations, and returns every
`Error` found.

For each match, the first branch that can never be reached is reported as
`Redundant`, and the match is then not checked for missing cases. A match with
no redundant branch that misses some values is reported as `Incomplete`, with
example patterns of what it misses. Matches on literals are exhaustive only with
a wildcard or variable, since a literal never covers its type.

The module must already be type checked: a pattern that mixes literals and
constructors in one position crashes the check.

-}
check : Can.Module -> Result (NE.Nonempty Error) ()
check (Can.Module canData) =
    case checkDecls canData.decls [] identity of
        [] ->
            Ok ()

        e :: es ->
            Err (NE.Nonempty e es)



-- ====== CHECK DECLS ======


{-| Returns `errors` with the errors of every definition in `decls` added.
-}
checkDecls : Can.Decls -> List Error -> (List Error -> List Error) -> List Error
checkDecls decls errors cont =
    case decls of
        Can.Declare def subDecls ->
            checkDecls subDecls errors (checkDef def >> cont)

        Can.DeclareRec def defs subDecls ->
            List.foldr checkDef (checkDecls subDecls errors (checkDef def >> cont)) defs

        Can.SaveTheEnvironment ->
            cont errors



-- ====== CHECK DEFS ======


{-| Adds the errors of a definition's argument patterns and body to `errors`.
-}
checkDef : Can.Def -> List Error -> List Error
checkDef def errors =
    case def of
        Can.Def _ args body ->
            List.foldr checkArg (checkExpr body errors) args

        Can.TypedDef _ _ args body _ ->
            List.foldr checkTypedArg (checkExpr body errors) args


{-| Adds the errors of one argument pattern, checked as a match of its own.
-}
checkArg : Can.Pattern -> List Error -> List Error
checkArg ((A.At region _) as pattern) errors =
    checkPatterns region BadArg [ pattern ] errors


{-| Adds the errors of one annotated argument pattern, checked as a match of its own.
-}
checkTypedArg : ( Can.Pattern, tipe ) -> List Error -> List Error
checkTypedArg ( (A.At region _) as pattern, _ ) errors =
    checkPatterns region BadArg [ pattern ] errors



-- ====== CHECK EXPRESSIONS ======


{-| Adds the errors of every pattern match inside an expression to `errors`.
-}
checkExpr : Can.Expr -> List Error -> List Error
checkExpr (A.At region exprInfo) errors =
    case exprInfo.node of
        Can.VarLocal _ ->
            errors

        Can.VarTopLevel _ _ ->
            errors

        Can.VarKernel _ _ _ ->
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
            Data.Map.foldr (\_ -> checkField) errors fields |> checkExpr record

        Can.Record fields ->
            Data.Map.foldr (\_ -> checkExpr) errors fields

        Can.Unit ->
            errors

        Can.Tuple a b cs ->
            checkExpr a
                (checkExpr b
                    (List.foldr checkExpr errors cs)
                )

        Can.Shader _ _ ->
            errors



-- ====== CHECK FIELD ======


{-| Adds the errors inside the new value of one updated record field.
-}
checkField : Can.FieldUpdate -> List Error -> List Error
checkField (Can.FieldUpdate _ expr) errors =
    checkExpr expr errors



-- ====== CHECK IF BRANCH ======


{-| Adds the errors inside one condition of an `if` and the branch it guards.
-}
checkIfBranch : ( Can.Expr, Can.Expr ) -> List Error -> List Error
checkIfBranch ( condition, branch ) errs =
    checkExpr condition (checkExpr branch errs)



-- ====== CHECK CASE EXPRESSION ======


{-| Adds the errors of a `case` expression covering `region`: those inside its
branch bodies, and those of its branch patterns taken as one match.
-}
checkCases : A.Region -> List Can.CaseBranch -> List Error -> List Error
checkCases region branches errors =
    let
        ( patterns, newErrors ) =
            List.foldr checkCaseBranch ( [], errors ) branches
    in
    checkPatterns region BadCase patterns newErrors


{-| Adds a branch's pattern to the patterns and the errors inside its body to the errors.
-}
checkCaseBranch : Can.CaseBranch -> ( List Can.Pattern, List Error ) -> ( List Can.Pattern, List Error )
checkCaseBranch (Can.CaseBranch pattern expr) ( patterns, errors ) =
    ( pattern :: patterns
    , checkExpr expr errors
    )



-- ====== CHECK PATTERNS ======


{-| Adds the error, if any, of `patterns` taken as one match covering `region`.

A redundant pattern gives a `Redundant` error and stops the check; otherwise a
non-exhaustive match gives one `Incomplete` error.

-}
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



-- ====== EXHAUSTIVE PATTERNS ======


{-| Returns example rows of `n` patterns that together cover the values no row of
`matrix` matches, or `[]` when the matrix is exhaustive. Every row of `matrix`
has `n` patterns.

When no row starts with a constructor, or not every constructor of the union
appears in the first column, only the rows starting with `Anything` can cover
what is left. Otherwise the matrix is specialised by each constructor in turn,
and the missing rows found are rebuilt into that constructor.

-}
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
                    ctors : Dict Name.Name Can.Union
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


{-| Returns a pattern for a constructor of `union` that is not a key of `ctors`, with `Anything` for each argument.
-}
isMissing : Can.Union -> Dict Name.Name a -> Can.Ctor -> Maybe Pattern
isMissing union ctors (Can.Ctor c) =
    if Dict.member c.name ctors then
        Nothing

    else
        Just (Ctor union c.name (List.repeat c.numArgs Anything))


{-| Rebuilds a row by putting its first `arity` patterns back under the constructor `name`.
-}
recoverCtor : Can.Union -> Name.Name -> Int -> List Pattern -> List Pattern
recoverCtor union name arity patterns =
    let
        ( args, rest ) =
            List.splitAt arity patterns
    in
    Ctor union name args :: rest



-- ====== REDUNDANT PATTERNS ======


{-| Returns the patterns of one match as rows of one simplified pattern each, or
the `Redundant` error of the first pattern that is not useful. `region` is the
region of the whole match.
-}
toNonRedundantRows : A.Region -> List Can.Pattern -> Result Error (List (List Pattern))
toNonRedundantRows region patterns =
    toSimplifiedUsefulRows region [] patterns


{-| Adds each of `uncheckedPatterns` in turn to `checkedRows`, which hold one
pattern each, last checked first, and stops with a `Redundant` error at the
first one that is not useful.
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


{-| Returns whether `vector` matches some value that no row of `matrix` matches.
-}
isUseful : List (List Pattern) -> List Pattern -> Bool
isUseful matrix vector =
    case matrix of
        [] ->
            -- No row matches anything, so the vector is useful.
            True

        _ ->
            case vector of
                [] ->
                    -- Some row matches everything the vector matches.
                    False

                firstPattern :: patterns ->
                    case firstPattern of
                        Ctor _ name args ->
                            isUseful
                                (List.filterMap (specializeRowByCtor name (List.length args)) matrix)
                                (args ++ patterns)

                        Anything ->
                            case isComplete matrix of
                                No ->
                                    -- Some constructor is missing, so only rows starting with
                                    -- Anything can cover what this Anything adds; the vector is
                                    -- useful unless those rows cover the rest of it.
                                    isUseful (List.filterMap specializeRowByAnything matrix) patterns

                                Yes alts ->
                                    -- All constructors appear, but the vector is still useful if,
                                    -- for some constructor, the rows starting with it leave values
                                    -- of its arguments uncovered.
                                    let
                                        isUsefulAlt : Can.Ctor -> Bool
                                        isUsefulAlt (Can.Ctor c) =
                                            isUseful
                                                (List.filterMap (specializeRowByCtor c.name c.numArgs) matrix)
                                                (List.repeat c.numArgs Anything ++ patterns)
                                    in
                                    List.any isUsefulAlt alts

                        Literal literal ->
                            isUseful
                                (List.filterMap (specializeRowByLiteral literal) matrix)
                                patterns


{-| Returns what is left of `row` to match once its first value is the
constructor `ctorName` of `arity` arguments, or `Nothing` when the row starts
with a different constructor. The first pattern is replaced by `arity`
argument patterns. It crashes on a row starting with a literal, or an empty row.
-}
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


{-| Returns what is left of `row` to match once its first value is `literal`,
or `Nothing` when the row starts with a different literal. It crashes on a row
starting with a constructor, or an empty row.
-}
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


{-| Returns the rest of `row` when it starts with `Anything`, and `Nothing`
otherwise.
-}
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



-- ====== ALL CONSTRUCTORS PRESENT ======


{-| Whether the first column of a matrix names every constructor of its union.

`Yes` carries all the union's constructors. `No` also holds when the column
names no constructor at all.

-}
type Complete
    = Yes (List Can.Ctor)
    | No


{-| Returns whether the first column of `matrix` names every constructor of its union.
-}
isComplete : List (List Pattern) -> Complete
isComplete matrix =
    let
        ctors : Dict Name.Name Can.Union
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



-- ====== COLLECT CTORS ======


{-| Returns the constructors that start a row of `matrix`, each with its union.
-}
collectCtors : List (List Pattern) -> Dict Name.Name Can.Union
collectCtors matrix =
    List.foldl (\row acc -> collectCtorsHelp acc row) Dict.empty matrix


{-| Adds the constructor that starts `row`, if any, to `ctors`.
-}
collectCtorsHelp : Dict Name.Name Can.Union -> List Pattern -> Dict Name.Name Can.Union
collectCtorsHelp ctors row =
    case row of
        (Ctor union name _) :: _ ->
            Dict.insert name union ctors

        _ ->
            ctors



-- ====== ENCODERS and DECODERS ======


{-| Encodes an `Error` in the binary form `errorDecoder` reads. A constructor
pattern is written with its whole union.
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


{-| A decoder for an `Error` in the form `errorEncoder` writes.
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


{-| Encodes a `Context` as one byte.
-}
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


{-| A decoder for a `Context` in the form `contextEncoder` writes.
-}
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


{-| Encodes a `Pattern`, a constructor together with its whole union.
-}
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


{-| A decoder for a `Pattern` in the form `patternEncoder` writes.
-}
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


{-| Encodes a `Literal` as a tag byte followed by its value.
-}
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


{-| A decoder for a `Literal` in the form `literalEncoder` writes.
-}
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
