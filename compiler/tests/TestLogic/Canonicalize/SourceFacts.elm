module TestLogic.Canonicalize.SourceFacts exposing
    ( Clash
    , SizeViolation
    , nameClashes
    , sizeViolations
    )

{-| Reads two facts about a source program straight from its `Src.Module`,
without the compiler, so that a check can compare them with what
canonicalization reports: the sizes over the runtime's limits, and the names
bound twice. Each fact is what canonicalization must reject the program for,
so a check built on it predicts the rejection from the program itself (an
_oracle_).


# Size limits

`sizeViolations` lists every size over a limit of
`Compiler.IR.Runtime.HeapLimits`, as canonicalization counts it
(`Compiler.Canonicalize.Expression`, `Type`, `LocalEnvironment`; HEAP\_019,
HEAP\_044, HEAP\_078):

  - a top-level function, a `let` function or a lambda with more parameters
    than `maxStageArity`;
  - a lambda or a `let` function with at least one parameter whose parameters
    plus captured variables are more than `maxStageArity`. Its captured
    variables are the names its body uses, less its parameters and the names
    the body binds itself, that an enclosing scope binds locally: a parameter
    of an enclosing function or lambda, a name a `case` branch binds, or a
    name of an enclosing `let`, its own name included. Top-level values are
    not captured;
  - a constructor with more fields than `maxCtorFields`;
  - a constructor without fields at a declaration index (counting from zero)
    over `maxNullaryCtorIndex`;
  - a record type alias whose body (through parentheses) is a record of more
    fields than `maxRecordFields`, and any other record type, in an alias, a
    constructor or an annotation, or record literal, with more fields than
    that.

Each violation carries the title its report must have and the opening of its
message, such as "The function `big` has 2048 parameters".


# Name clashes

`nameClashes` lists every name canonicalization must reject as bound twice
(CANON\_003), with the title of the report:

  - `NAME CLASH`: two top-level values, two types (custom types and aliases
    together), or two constructors (of custom types, and of the aliases whose
    body is a closed record) of one name; one type variable twice in an alias
    or a custom type; one field twice in a record literal, a record update or
    a record type; and one name bound twice by the arguments of one function or
    lambda, by one `case` pattern, or by one `let` (its definitions'
    names and the names its destructurings bind together);
  - `SHADOWING`: a name bound by an argument, a `case` pattern or a `let` while
    a top-level value of the module or an enclosing local binding already binds
    it. An imported name may be bound again.

Among what is not read: operators and their declarations, ports and effect
managers, exports, and the type variables of annotations.

-}

import Compiler.Core.Annotation as A
import Compiler.IR.Runtime.HeapLimits as HeapLimits
import Compiler.IR.Source as Src
import Set exposing (Set)



-- ============================================================================
-- SIZE LIMITS
-- ============================================================================


{-| One size over a limit: the `title` its report must have, and `message`, the
opening of the report's message (what is too large and its size).
-}
type alias SizeViolation =
    { title : String
    , message : String
    }


{-| Every size of `srcModule` over a limit, as the module docstring lists.
-}
sizeViolations : Src.Module -> List SizeViolation
sizeViolations (Src.Module data) =
    List.concatMap valueSizes data.values
        ++ List.concatMap unionSizes data.unions
        ++ List.concatMap aliasSizes data.aliases


valueSizes : A.Located Src.Value -> List SizeViolation
valueSizes (A.At _ (Src.Value v)) =
    let
        ( _, A.At _ name ) =
            v.name

        args =
            List.map Src.c1Value v.args

        own =
            if List.length args > HeapLimits.maxStageArity then
                [ tooManyParams ("The function `" ++ name ++ "`") (List.length args) ]

            else
                []
    in
    own
        ++ maybeAnnotationSizes v.tipe
        ++ exprSizes (patternsNames args) (Src.c1Value v.body)


unionSizes : A.Located Src.Union -> List SizeViolation
unionSizes (A.At _ (Src.Union _ _ ctor0 ctors)) =
    List.concat <|
        List.indexedMap
            (\index ( _, ( A.At _ ctorName, args ) ) ->
                (if List.isEmpty args && index > HeapLimits.maxNullaryCtorIndex then
                    [ { title = "TOO MANY CONSTRUCTORS"
                      , message = "The constructor `" ++ ctorName ++ "` has no fields and is constructor " ++ String.fromInt (index + 1) ++ " of its type"
                      }
                    ]

                 else
                    []
                )
                    ++ (if List.length args > HeapLimits.maxCtorFields then
                            [ { title = "TOO MANY FIELDS"
                              , message = "The constructor `" ++ ctorName ++ "` has " ++ String.fromInt (List.length args) ++ " fields"
                              }
                            ]

                        else
                            []
                       )
                    ++ List.concatMap (Src.c1Value >> typeSizes) args
            )
            (ctor0 :: ctors)


aliasSizes : A.Located Src.Alias -> List SizeViolation
aliasSizes (A.At _ (Src.Alias a)) =
    let
        ( _, A.At _ name ) =
            a.name

        tipe =
            Src.c1Value a.tipe
    in
    case recordBody tipe of
        Just ( fields, fieldTypes ) ->
            (if fields > HeapLimits.maxRecordFields then
                [ { title = "TOO MANY FIELDS"
                  , message = "The record type `" ++ name ++ "` has " ++ String.fromInt fields ++ " fields"
                  }
                ]

             else
                []
            )
                ++ List.concatMap typeSizes fieldTypes

        Nothing ->
            typeSizes tipe


{-| The field count and field types of a record type, looking through
parentheses, or `Nothing` when the type is not a record.
-}
recordBody : Src.Type -> Maybe ( Int, List Src.Type )
recordBody (A.At _ tipe) =
    case tipe of
        Src.TRecord fields _ ->
            Just ( List.length fields, List.map (\( _, ( _, ( _, t ) ) ) -> t) fields )

        Src.TRecordExt _ firstField fields _ ->
            Just ( 1 + List.length fields, List.map (\( _, ( _, ( _, t ) ) ) -> t) (firstField :: fields) )

        Src.TParens ( _, inner ) ->
            recordBody inner

        _ ->
            Nothing


maybeAnnotationSizes : Maybe (Src.C1 (Src.C2 Src.Type)) -> List SizeViolation
maybeAnnotationSizes maybeType =
    case maybeType of
        Just ( _, ( _, tipe ) ) ->
            typeSizes tipe

        Nothing ->
            []


{-| The records of more than `maxRecordFields` fields in `tipe`.
-}
typeSizes : Src.Type -> List SizeViolation
typeSizes tipe =
    List.filterMap
        (\n ->
            if n > HeapLimits.maxRecordFields then
                Just (tooManyFields n)

            else
                Nothing
        )
        (recordSizes tipe)


{-| The field count of every record type in `tipe`, outermost first.
-}
recordSizes : Src.Type -> List Int
recordSizes (A.At _ tipe) =
    case tipe of
        Src.TLambda ( _, a ) ( _, b ) ->
            recordSizes a ++ recordSizes b

        Src.TVar _ ->
            []

        Src.TType _ _ args ->
            List.concatMap (Src.c1Value >> recordSizes) args

        Src.TTypeQual _ _ _ args ->
            List.concatMap (Src.c1Value >> recordSizes) args

        Src.TRecord fields _ ->
            List.length fields :: List.concatMap (\( _, ( _, ( _, t ) ) ) -> recordSizes t) fields

        Src.TRecordExt _ firstField fields _ ->
            (1 + List.length fields) :: List.concatMap (\( _, ( _, ( _, t ) ) ) -> recordSizes t) (firstField :: fields)

        Src.TUnit ->
            []

        Src.TTuple ( _, a ) ( _, b ) rest ->
            recordSizes a ++ recordSizes b ++ List.concatMap (\( _, t ) -> recordSizes t) rest

        Src.TParens ( _, t ) ->
            recordSizes t


tooManyParams : String -> Int -> SizeViolation
tooManyParams subject n =
    { title = "TOO MANY PARAMETERS", message = subject ++ " has " ++ String.fromInt n ++ " parameters" }


tooManySlots : String -> Int -> SizeViolation
tooManySlots subject n =
    { title = "TOO MANY CAPTURED VARIABLES", message = subject ++ " has " ++ String.fromInt n ++ " parameters and captured variables" }


tooManyFields : Int -> SizeViolation
tooManyFields n =
    { title = "TOO MANY FIELDS", message = "This record has " ++ String.fromInt n ++ " fields" }


{-| The sizes over a limit in `expr`, whose enclosing scopes bind `locals`
locally.
-}
exprSizes : Set String -> Src.Expr -> List SizeViolation
exprSizes locals (A.At _ expr) =
    case expr of
        Src.Lambda ( _, args ) ( _, body ) ->
            let
                patterns =
                    List.map Src.c1Value args

                n =
                    List.length patterns

                bound =
                    patternsNames patterns

                own =
                    if n > HeapLimits.maxStageArity then
                        [ tooManyParams "This anonymous function" n ]

                    else
                        closureSlots "This anonymous function" locals n bound body
            in
            own ++ exprSizes (Set.union locals bound) body

        Src.Let defs _ body ->
            let
                scope =
                    Set.union locals (letNames (List.map (Src.c2Value >> A.toValue) defs))
            in
            List.concatMap (Src.c2Value >> A.toValue >> defSizes scope) defs
                ++ exprSizes scope body

        Src.Case ( _, subject ) branches ->
            exprSizes locals subject
                ++ List.concatMap
                    (\( ( _, pattern ), ( _, branch ) ) -> exprSizes (Set.union locals (patternNames pattern)) branch)
                    branches

        Src.Record ( _, fields ) ->
            (if List.length fields > HeapLimits.maxRecordFields then
                [ tooManyFields (List.length fields) ]

             else
                []
            )
                ++ List.concatMap (\( _, ( _, ( _, value ) ) ) -> exprSizes locals value) fields

        _ ->
            List.concatMap (exprSizes locals) (children expr)


{-| The sizes over a limit of one `let` definition, whose scope, the `let`'s
own names included, is `scope`.
-}
defSizes : Set String -> Src.Def -> List SizeViolation
defSizes scope def =
    case def of
        Src.Define (A.At _ name) args ( _, body ) maybeType ->
            let
                patterns =
                    List.map Src.c1Value args

                n =
                    List.length patterns

                bound =
                    patternsNames patterns

                own =
                    if n > HeapLimits.maxStageArity then
                        [ tooManyParams ("The function `" ++ name ++ "`") n ]

                    else
                        closureSlots ("The local function `" ++ name ++ "`") scope n bound body
            in
            own ++ maybeAnnotationSizes maybeType ++ exprSizes (Set.union scope bound) body

        Src.Destruct _ ( _, body ) ->
            exprSizes scope body


{-| The violation of a closure of `n` parameters binding `bound`, with body
`body`, inside scopes binding `locals`, when its parameters plus captured
variables are over the limit.
-}
closureSlots : String -> Set String -> Int -> Set String -> Src.Expr -> List SizeViolation
closureSlots subject locals n bound body =
    let
        captured =
            Set.size (Set.intersect locals (Set.diff (freeNames body) bound))
    in
    if n > 0 && n + captured > HeapLimits.maxStageArity then
        [ tooManySlots subject (n + captured) ]

    else
        []



-- ============================================================================
-- NAME CLASHES
-- ============================================================================


{-| One name bound twice: the `title` its report must have (`NAME CLASH` or
`SHADOWING`) and the `name`.
-}
type alias Clash =
    { title : String
    , name : String
    }


{-| Every name of `srcModule` bound twice, as the module docstring lists.
-}
nameClashes : Src.Module -> List Clash
nameClashes (Src.Module data) =
    let
        valueNames =
            List.map (\(A.At _ (Src.Value v)) -> A.toValue (Tuple.second v.name)) data.values

        typeNames =
            List.map (\(A.At _ (Src.Union ( _, A.At _ n ) _ _ _)) -> n) data.unions
                ++ List.map (\(A.At _ (Src.Alias a)) -> A.toValue (Tuple.second a.name)) data.aliases

        ctorNames =
            List.concatMap (\(A.At _ (Src.Union _ _ ctor0 ctors)) -> List.map (\( _, ( A.At _ n, _ ) ) -> n) (ctor0 :: ctors)) data.unions
                ++ List.filterMap aliasCtor data.aliases

        typeVarClashes =
            List.concatMap (\(A.At _ (Src.Union _ vars _ _)) -> repeats (List.map (Src.c1Value >> A.toValue) vars)) data.unions
                ++ List.concatMap (\(A.At _ (Src.Alias a)) -> repeats (List.map (Src.c1Value >> A.toValue) a.args)) data.aliases

        typeFieldClashes =
            List.concatMap (\(A.At _ (Src.Union _ _ ctor0 ctors)) -> List.concatMap (\( _, ( _, args ) ) -> List.concatMap (Src.c1Value >> typeFieldRepeats) args) (ctor0 :: ctors)) data.unions
                ++ List.concatMap (\(A.At _ (Src.Alias a)) -> typeFieldRepeats (Src.c1Value a.tipe)) data.aliases

        topLevel =
            Set.fromList valueNames
    in
    List.map nameClash
        (repeats valueNames ++ repeats typeNames ++ repeats ctorNames ++ typeVarClashes ++ typeFieldClashes)
        ++ List.concatMap (valueClashes topLevel) data.values


{-| The constructor a type alias defines: one named like the alias when its
body is a closed record.
-}
aliasCtor : A.Located Src.Alias -> Maybe String
aliasCtor (A.At _ (Src.Alias a)) =
    case Src.c1Value a.tipe of
        A.At _ (Src.TRecord _ _) ->
            Just (A.toValue (Tuple.second a.name))

        _ ->
            Nothing


nameClash : String -> Clash
nameClash name =
    { title = "NAME CLASH", name = name }


shadowing : String -> Clash
shadowing name =
    { title = "SHADOWING", name = name }


{-| The clashes of one top-level value, given the module's top-level value
names `topLevel`.
-}
valueClashes : Set String -> A.Located Src.Value -> List Clash
valueClashes topLevel (A.At _ (Src.Value v)) =
    let
        args =
            List.map Src.c1Value v.args

        typeClashes =
            case v.tipe of
                Just ( _, ( _, tipe ) ) ->
                    typeFieldRepeats tipe

                Nothing ->
                    []
    in
    List.map nameClash typeClashes
        ++ bindingClashes { topLevel = topLevel, locals = Set.empty } (patternsNameList args)
        ++ exprClashes { topLevel = topLevel, locals = patternsNames args } (Src.c1Value v.body)


{-| The names bound in scope: the module's top-level values and the enclosing
local bindings.
-}
type alias Scope =
    { topLevel : Set String
    , locals : Set String
    }


{-| The clashes of binding `names` together in `scope`: a name among them twice
is a `NAME CLASH`, and one already in scope is `SHADOWING`.
-}
bindingClashes : Scope -> List String -> List Clash
bindingClashes scope names =
    List.map nameClash (repeats names)
        ++ List.map shadowing
            (List.filter (\n -> Set.member n scope.topLevel || Set.member n scope.locals) (unique names))


withLocals : Set String -> Scope -> Scope
withLocals names scope =
    { scope | locals = Set.union scope.locals names }


exprClashes : Scope -> Src.Expr -> List Clash
exprClashes scope (A.At _ expr) =
    case expr of
        Src.Lambda ( _, args ) ( _, body ) ->
            let
                patterns =
                    List.map Src.c1Value args
            in
            bindingClashes scope (patternsNameList patterns)
                ++ exprClashes (withLocals (patternsNames patterns) scope) body

        Src.Let defs _ body ->
            let
                plainDefs =
                    List.map (Src.c2Value >> A.toValue) defs

                groupNames =
                    letNameList plainDefs

                inner =
                    withLocals (Set.fromList groupNames) scope
            in
            bindingClashes scope groupNames
                ++ List.concatMap (defClashes inner) plainDefs
                ++ exprClashes inner body

        Src.Case ( _, subject ) branches ->
            exprClashes scope subject
                ++ List.concatMap
                    (\( ( _, pattern ), ( _, branch ) ) ->
                        bindingClashes scope (patternNameList pattern)
                            ++ exprClashes (withLocals (patternNames pattern) scope) branch
                    )
                    branches

        Src.Record ( _, fields ) ->
            List.map nameClash (repeats (List.map (\( _, ( ( _, A.At _ n ), _ ) ) -> n) fields))
                ++ List.concatMap (\( _, ( _, ( _, value ) ) ) -> exprClashes scope value) fields

        Src.Update ( _, record ) ( _, ( firstField, moreFields ) ) ->
            let
                fields =
                    firstField :: moreFields
            in
            List.map nameClash (repeats (List.map (\( _, ( ( _, A.At _ n ), _ ) ) -> n) fields))
                ++ exprClashes scope record
                ++ List.concatMap (\( _, ( _, ( _, value ) ) ) -> exprClashes scope value) fields

        _ ->
            List.concatMap (exprClashes scope) (children expr)


{-| The clashes of one `let` definition, in `scope`, which holds the `let`'s
own names.
-}
defClashes : Scope -> Src.Def -> List Clash
defClashes scope def =
    case def of
        Src.Define _ args ( _, body ) maybeType ->
            let
                patterns =
                    List.map Src.c1Value args

                typeClashes =
                    case maybeType of
                        Just ( _, ( _, tipe ) ) ->
                            List.map nameClash (typeFieldRepeats tipe)

                        Nothing ->
                            []
            in
            typeClashes
                ++ bindingClashes scope (patternsNameList patterns)
                ++ exprClashes (withLocals (patternsNames patterns) scope) body

        Src.Destruct _ ( _, body ) ->
            exprClashes scope body


{-| The field names repeated within one record type anywhere in `tipe`.
-}
typeFieldRepeats : Src.Type -> List String
typeFieldRepeats (A.At _ tipe) =
    case tipe of
        Src.TLambda ( _, a ) ( _, b ) ->
            typeFieldRepeats a ++ typeFieldRepeats b

        Src.TVar _ ->
            []

        Src.TType _ _ args ->
            List.concatMap (Src.c1Value >> typeFieldRepeats) args

        Src.TTypeQual _ _ _ args ->
            List.concatMap (Src.c1Value >> typeFieldRepeats) args

        Src.TRecord fields _ ->
            repeats (List.map (\( _, ( ( _, A.At _ n ), _ ) ) -> n) fields)
                ++ List.concatMap (\( _, ( _, ( _, t ) ) ) -> typeFieldRepeats t) fields

        Src.TRecordExt _ firstField fields _ ->
            repeats (List.map (\( _, ( ( _, A.At _ n ), _ ) ) -> n) (firstField :: fields))
                ++ List.concatMap (\( _, ( _, ( _, t ) ) ) -> typeFieldRepeats t) (firstField :: fields)

        Src.TUnit ->
            []

        Src.TTuple ( _, a ) ( _, b ) rest ->
            typeFieldRepeats a ++ typeFieldRepeats b ++ List.concatMap (\( _, t ) -> typeFieldRepeats t) rest

        Src.TParens ( _, t ) ->
            typeFieldRepeats t



-- ============================================================================
-- NAMES
-- ============================================================================


{-| The names a `let` binds: each definition's name and the names each
destructuring's pattern binds, in order, repeats kept.
-}
letNameList : List Src.Def -> List String
letNameList defs =
    List.concatMap
        (\def ->
            case def of
                Src.Define (A.At _ name) _ _ _ ->
                    [ name ]

                Src.Destruct pattern _ ->
                    patternNameList pattern
        )
        defs


letNames : List Src.Def -> Set String
letNames =
    letNameList >> Set.fromList


patternsNameList : List Src.Pattern -> List String
patternsNameList =
    List.concatMap patternNameList


patternsNames : List Src.Pattern -> Set String
patternsNames =
    patternsNameList >> Set.fromList


patternNames : Src.Pattern -> Set String
patternNames =
    patternNameList >> Set.fromList


{-| The names `pattern` binds, in order, repeats kept.
-}
patternNameList : Src.Pattern -> List String
patternNameList (A.At _ pattern) =
    case pattern of
        Src.PAnything _ ->
            []

        Src.PVar name ->
            [ name ]

        Src.PRecord ( _, fields ) ->
            List.map (\( _, A.At _ n ) -> n) fields

        Src.PAlias ( _, inner ) ( _, A.At _ name ) ->
            patternNameList inner ++ [ name ]

        Src.PUnit _ ->
            []

        Src.PTuple ( _, a ) ( _, b ) rest ->
            patternNameList a ++ patternNameList b ++ List.concatMap (\( _, p ) -> patternNameList p) rest

        Src.PCtor _ _ args ->
            List.concatMap (Src.c1Value >> patternNameList) args

        Src.PCtorQual _ _ _ args ->
            List.concatMap (Src.c1Value >> patternNameList) args

        Src.PList ( _, items ) ->
            List.concatMap (\( _, p ) -> patternNameList p) items

        Src.PCons ( _, head ) ( _, tail ) ->
            patternNameList head ++ patternNameList tail

        Src.PChr _ ->
            []

        Src.PStr _ _ ->
            []

        Src.PInt _ _ ->
            []

        Src.PParens ( _, inner ) ->
            patternNameList inner


{-| The unqualified lower-case names `expr` uses that it does not bind itself.
-}
freeNames : Src.Expr -> Set String
freeNames ((A.At _ expr) as located) =
    case expr of
        Src.Var Src.LowVar name ->
            Set.singleton name

        Src.Lambda ( _, args ) ( _, body ) ->
            Set.diff (freeNames body) (patternsNames (List.map Src.c1Value args))

        Src.Let defs _ body ->
            let
                plainDefs =
                    List.map (Src.c2Value >> A.toValue) defs

                defFree def =
                    case def of
                        Src.Define _ args ( _, defBody ) _ ->
                            Set.diff (freeNames defBody) (patternsNames (List.map Src.c1Value args))

                        Src.Destruct _ ( _, defBody ) ->
                            freeNames defBody
            in
            Set.diff
                (List.foldl (defFree >> Set.union) (freeNames body) plainDefs)
                (letNames plainDefs)

        Src.Case ( _, subject ) branches ->
            List.foldl
                (\( ( _, pattern ), ( _, branch ) ) acc -> Set.union acc (Set.diff (freeNames branch) (patternNames pattern)))
                (freeNames subject)
                branches

        _ ->
            List.foldl (freeNames >> Set.union) Set.empty (childrenOf located)


{-| The direct sub-expressions of an expression that binds nothing.
-}
childrenOf : Src.Expr -> List Src.Expr
childrenOf (A.At _ expr) =
    children expr


{-| The direct sub-expressions of `expr`. For a lambda, a `let` and a `case`,
which bind names, this is every sub-expression regardless of scope; the
callers handle those three themselves.
-}
children : Src.Expr_ -> List Src.Expr
children expr =
    case expr of
        Src.List items _ ->
            List.map (\( _, e ) -> e) items

        Src.Negate e ->
            [ e ]

        Src.Binops firstOp ops final ->
            List.map Tuple.first (firstOp :: ops) ++ [ final ]

        Src.Lambda _ ( _, body ) ->
            [ body ]

        Src.Call func firstArg args ->
            func :: List.map Src.c1Value (firstArg :: args)

        Src.If ( _, ( ( _, c ), ( _, t ) ) ) elseIfs ( _, final ) ->
            c :: t :: List.concatMap (\( _, ( ( _, c2 ), ( _, t2 ) ) ) -> [ c2, t2 ]) elseIfs ++ [ final ]

        Src.Let defs _ body ->
            List.map
                (\( _, A.At _ def ) ->
                    case def of
                        Src.Define _ _ ( _, b ) _ ->
                            b

                        Src.Destruct _ ( _, b ) ->
                            b
                )
                defs
                ++ [ body ]

        Src.Case ( _, subject ) branches ->
            subject :: List.map (\( _, ( _, b ) ) -> b) branches

        Src.Access e _ ->
            [ e ]

        Src.Update ( _, record ) ( _, ( firstField, moreFields ) ) ->
            record :: List.map (\( _, ( _, ( _, value ) ) ) -> value) (firstField :: moreFields)

        Src.Record ( _, fields ) ->
            List.map (\( _, ( _, ( _, value ) ) ) -> value) fields

        Src.Tuple ( _, a ) ( _, b ) rest ->
            a :: b :: List.map Src.c2Value rest

        Src.Parens ( _, e ) ->
            [ e ]

        _ ->
            []



-- ============================================================================
-- LISTS
-- ============================================================================


{-| Each name that occurs more than once in `names`, once, in order of its
second occurrence.
-}
repeats : List String -> List String
repeats names =
    List.foldl
        (\n ( seen, found ) ->
            if Set.member n seen && not (List.member n found) then
                ( seen, n :: found )

            else
                ( Set.insert n seen, found )
        )
        ( Set.empty, [] )
        names
        |> Tuple.second
        |> List.reverse


{-| `names` without repeats, in order of first occurrence.
-}
unique : List String -> List String
unique names =
    List.foldl
        (\n ( seen, acc ) ->
            if Set.member n seen then
                ( seen, acc )

            else
                ( Set.insert n seen, n :: acc )
        )
        ( Set.empty, [] )
        names
        |> Tuple.second
        |> List.reverse
