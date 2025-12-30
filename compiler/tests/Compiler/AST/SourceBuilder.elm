module Compiler.AST.SourceBuilder exposing
    ( -- Comment wrappers
      accessExpr
    , accessorExpr
    , binopsExpr
    , boolExpr
    , callExpr
    , caseExpr
    , charFuzzer
    , chrExpr
    , define
    , defineTyped
    , destruct
      -- Pattern builders
    , floatExpr
    , ifExpr
    , intExpr
    , lambdaExpr
    , letExpr
    , listExpr
    , makeModule
    , makeModuleWithDefs
    , makeModuleWithTypedDefs
      -- Fuzzers
    , negateExpr
    , pAlias
    , pAnything
    , pCons
    , pCtor
    , pInt
    , pList
    , pRecord
    , pStr
    , pTuple
    , pTuple3
    , pUnit
    , pVar
      -- Module builders
    , parensExpr
    , recordExpr
    , strExpr
      -- Type builders
    , tLambda
    , tRecord
    , tTuple
    , tType
    , tUnit
    , tVar
      -- Type alias
    , TypedDef
    , tuple3Expr
    , tupleExpr
    , unitExpr
    , updateExpr
    , varExpr
      -- Definition builders
    )

{-| Source AST builders for constructing test expressions and modules.

This module provides:

1.  Comment wrappers for Source AST formatting
2.  Expression builders for Source AST construction
3.  Pattern builders for Source AST construction
4.  Definition builders for Source AST construction
5.  Module builders for creating complete Source modules
6.  Fuzzers for generating random test inputs

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Parse.SyntaxVersion as SV
import Compiler.Reporting.Annotation as A
import Fuzz exposing (Fuzzer)



-- ============================================================================
-- COMMENT WRAPPERS
-- ============================================================================


{-| Empty list of formatting comments.
-}
noComments : Src.FComments
noComments =
    []


{-| Wrap a value with comments before it.
-}
c1 : a -> Src.C1 a
c1 a =
    ( noComments, a )


{-| Wrap a value with comments before and after it.
-}
c2 : a -> Src.C2 a
c2 a =
    ( ( noComments, noComments ), a )


{-| Wrap a value with optional end-of-line comment.
-}
c0Eol : a -> Src.C0Eol a
c0Eol a =
    ( Nothing, a )


{-| Wrap a value with comments before/after and optional end-of-line comment.
-}
c2Eol : a -> Src.C2Eol a
c2Eol a =
    ( ( noComments, noComments, Nothing ), a )



-- ============================================================================
-- EXPRESSION BUILDERS
-- ============================================================================


{-| Create an Int literal expression.
-}
intExpr : Int -> Src.Expr
intExpr n =
    A.At A.zero (Src.Int n (String.fromInt n))


{-| Create a Float literal expression.
-}
floatExpr : Float -> Src.Expr
floatExpr f =
    A.At A.zero (Src.Float f (String.fromFloat f))


{-| Create a String literal expression.
-}
strExpr : String -> Src.Expr
strExpr s =
    A.At A.zero (Src.Str s False)


{-| Create a Char literal expression.
-}
chrExpr : String -> Src.Expr
chrExpr c =
    A.At A.zero (Src.Chr c)


{-| Create a Unit expression.
-}
unitExpr : Src.Expr
unitExpr =
    A.At A.zero Src.Unit


{-| Create a Bool literal expression (True/False as constructor).
-}
boolExpr : Bool -> Src.Expr
boolExpr b =
    let
        name =
            if b then
                "True"

            else
                "False"
    in
    A.At A.zero (Src.VarQual Src.CapVar "Basics" name)


{-| Create a local variable reference.
-}
varExpr : Name -> Src.Expr
varExpr name =
    A.At A.zero (Src.Var Src.LowVar name)


{-| Create a List expression.
-}
listExpr : List Src.Expr -> Src.Expr
listExpr elements =
    A.At A.zero (Src.List (List.map c2Eol elements) noComments)


{-| Create a 2-tuple expression.
-}
tupleExpr : Src.Expr -> Src.Expr -> Src.Expr
tupleExpr a b =
    A.At A.zero (Src.Tuple (c2 a) (c2 b) [])


{-| Create a 3-tuple expression.
-}
tuple3Expr : Src.Expr -> Src.Expr -> Src.Expr -> Src.Expr
tuple3Expr a b c =
    A.At A.zero (Src.Tuple (c2 a) (c2 b) [ c2 c ])


{-| Create a Record expression.
-}
recordExpr : List ( Name, Src.Expr ) -> Src.Expr
recordExpr fields =
    let
        fieldList =
            List.map (\( name, expr ) -> c2Eol ( c1 (A.At A.zero name), c1 expr )) fields
    in
    A.At A.zero (Src.Record (c1 fieldList))


{-| Create a Negate expression.
-}
negateExpr : Src.Expr -> Src.Expr
negateExpr inner =
    A.At A.zero (Src.Negate inner)


{-| Create a Binops expression (left-to-right chain of binary operators).
-}
binopsExpr : List ( Src.Expr, Name ) -> Src.Expr -> Src.Expr
binopsExpr ops final =
    A.At A.zero (Src.Binops (List.map (\( e, op ) -> ( e, c2 (A.At A.zero op) )) ops) final)


{-| Create a Lambda expression.
-}
lambdaExpr : List Src.Pattern -> Src.Expr -> Src.Expr
lambdaExpr args body =
    A.At A.zero (Src.Lambda (c1 (List.map c1 args)) (c1 body))


{-| Create a function Call expression.
-}
callExpr : Src.Expr -> List Src.Expr -> Src.Expr
callExpr func args =
    A.At A.zero (Src.Call func (List.map c1 args))


{-| Create an If expression.
-}
ifExpr : Src.Expr -> Src.Expr -> Src.Expr -> Src.Expr
ifExpr condition then_ else_ =
    A.At A.zero (Src.If (c1 ( c2 condition, c2 then_ )) [] (c1 else_))


{-| Create a Let expression.
-}
letExpr : List Src.Def -> Src.Expr -> Src.Expr
letExpr defs body =
    A.At A.zero (Src.Let (List.map (\d -> c2 (A.At A.zero d)) defs) noComments body)


{-| Create a Case expression.
-}
caseExpr : Src.Expr -> List ( Src.Pattern, Src.Expr ) -> Src.Expr
caseExpr subject branches =
    A.At A.zero (Src.Case (c2 subject) (List.map (\( p, e ) -> ( c2 p, c1 e )) branches))


{-| Create an Accessor function expression (.field).
-}
accessorExpr : Name -> Src.Expr
accessorExpr field =
    A.At A.zero (Src.Accessor field)


{-| Create a field Access expression.
-}
accessExpr : Src.Expr -> Name -> Src.Expr
accessExpr record field =
    A.At A.zero (Src.Access record (A.At A.zero field))


{-| Create a Record Update expression.
-}
updateExpr : Src.Expr -> List ( Name, Src.Expr ) -> Src.Expr
updateExpr record fields =
    let
        fieldList =
            List.map (\( name, expr ) -> c2Eol ( c1 (A.At A.zero name), c1 expr )) fields
    in
    A.At A.zero (Src.Update (c2 record) (c1 fieldList))


{-| Create a Parens expression.
-}
parensExpr : Src.Expr -> Src.Expr
parensExpr inner =
    A.At A.zero (Src.Parens (c2 inner))



-- ============================================================================
-- PATTERN BUILDERS
-- ============================================================================


{-| Wildcard pattern (\_).
-}
pAnything : Src.Pattern
pAnything =
    A.At A.zero (Src.PAnything "_")


{-| Variable pattern.
-}
pVar : Name -> Src.Pattern
pVar name =
    A.At A.zero (Src.PVar name)


{-| Int literal pattern.
-}
pInt : Int -> Src.Pattern
pInt n =
    A.At A.zero (Src.PInt n (String.fromInt n))


{-| String literal pattern.
-}
pStr : String -> Src.Pattern
pStr s =
    A.At A.zero (Src.PStr s False)


{-| Unit pattern.
-}
pUnit : Src.Pattern
pUnit =
    A.At A.zero (Src.PUnit noComments)


{-| Tuple pattern.
-}
pTuple : Src.Pattern -> Src.Pattern -> Src.Pattern
pTuple a b =
    A.At A.zero (Src.PTuple (c2 a) (c2 b) [])


{-| 3-tuple pattern.
-}
pTuple3 : Src.Pattern -> Src.Pattern -> Src.Pattern -> Src.Pattern
pTuple3 a b c =
    A.At A.zero (Src.PTuple (c2 a) (c2 b) [ c2 c ])


{-| List literal pattern.
-}
pList : List Src.Pattern -> Src.Pattern
pList elements =
    A.At A.zero (Src.PList (c1 (List.map c2 elements)))


{-| Cons pattern (head :: tail).
-}
pCons : Src.Pattern -> Src.Pattern -> Src.Pattern
pCons head tail =
    A.At A.zero (Src.PCons (c0Eol head) (c2Eol tail))


{-| Record pattern.
-}
pRecord : List Name -> Src.Pattern
pRecord fields =
    A.At A.zero (Src.PRecord (c1 (List.map (\name -> c2 (A.At A.zero name)) fields)))


{-| As-pattern (binding a pattern to a name).
-}
pAlias : Src.Pattern -> Name -> Src.Pattern
pAlias pattern name =
    A.At A.zero (Src.PAlias (c1 pattern) (c1 (A.At A.zero name)))


{-| Constructor pattern (e.g., Just x, Nothing).
-}
pCtor : Name -> List Src.Pattern -> Src.Pattern
pCtor name args =
    A.At A.zero (Src.PCtor A.zero name (List.map c1 args))



-- ============================================================================
-- DEFINITION BUILDERS
-- ============================================================================


{-| Create a function/value definition.
-}
define : Name -> List Src.Pattern -> Src.Expr -> Src.Def
define name args body =
    Src.Define (A.At A.zero name) (List.map c1 args) (c1 body) Nothing


{-| Create a destructuring definition.
-}
destruct : Src.Pattern -> Src.Expr -> Src.Def
destruct pattern expr =
    Src.Destruct pattern (c1 expr)


{-| Create a function/value definition with a type annotation.
-}
defineTyped : Name -> List Src.Pattern -> Src.Type -> Src.Expr -> Src.Def
defineTyped name args tipe body =
    Src.Define (A.At A.zero name) (List.map c1 args) (c1 body) (Just (c1 (c2 tipe)))



-- ============================================================================
-- MODULE BUILDERS
-- ============================================================================


{-| Import statement for Basics exposing everything.
-}
basicsImport : Src.Import
basicsImport =
    Src.Import
        (c1 (A.At A.zero "Basics"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| Import statement for Maybe exposing everything.
-}
maybeImport : Src.Import
maybeImport =
    Src.Import
        (c1 (A.At A.zero "Maybe"))
        Nothing
        (c2 (Src.Open noComments noComments))


{-| Standard imports for test modules.
-}
standardImports : List Src.Import
standardImports =
    [ basicsImport, maybeImport ]


{-| Create a simple module with a single top-level definition.
-}
makeModule : Name -> Src.Expr -> Src.Module
makeModule name expr =
    let
        value =
            Src.Value
                { comments = noComments
                , name = c1 (A.At A.zero name)
                , args = []
                , body = c1 expr
                , tipe = Nothing
                }
    in
    Src.Module
        { syntaxVersion = SV.Elm
        , name = Just (A.At A.zero "Test")
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = [ basicsImport ]
        , values = [ A.At A.zero value ]
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.NoEffects
        }


{-| Create a module with multiple definitions.
-}
makeModuleWithDefs : List ( Name, List Src.Pattern, Src.Expr ) -> Src.Module
makeModuleWithDefs defs =
    let
        values =
            List.map
                (\( name, args, body ) ->
                    A.At A.zero
                        (Src.Value
                            { comments = noComments
                            , name = c1 (A.At A.zero name)
                            , args = List.map c1 args
                            , body = c1 body
                            , tipe = Nothing
                            }
                        )
                )
                defs
    in
    Src.Module
        { syntaxVersion = SV.Elm
        , name = Just (A.At A.zero "Test")
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = [ basicsImport ]
        , values = values
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.NoEffects
        }


{-| A typed definition: name, args, type annotation, and body.
-}
type alias TypedDef =
    { name : Name
    , args : List Src.Pattern
    , tipe : Src.Type
    , body : Src.Expr
    }


{-| Create a module with multiple typed definitions.
-}
makeModuleWithTypedDefs : List TypedDef -> Src.Module
makeModuleWithTypedDefs defs =
    let
        values =
            List.map
                (\{ name, args, tipe, body } ->
                    A.At A.zero
                        (Src.Value
                            { comments = noComments
                            , name = c1 (A.At A.zero name)
                            , args = List.map c1 args
                            , body = c1 body
                            , tipe = Just (c1 (c2 tipe))
                            }
                        )
                )
                defs
    in
    Src.Module
        { syntaxVersion = SV.Elm
        , name = Just (A.At A.zero "Test")
        , exports = A.At A.zero (Src.Open noComments noComments)
        , docs = Src.NoDocs A.zero []
        , imports = standardImports
        , values = values
        , unions = []
        , aliases = []
        , infixes = []
        , effects = Src.NoEffects
        }



-- ============================================================================
-- TYPE BUILDERS
-- ============================================================================


{-| Create a type variable.
-}
tVar : Name -> Src.Type
tVar name =
    A.At A.zero (Src.TVar name)


{-| Create a function type (a -> b).
-}
tLambda : Src.Type -> Src.Type -> Src.Type
tLambda from to =
    A.At A.zero (Src.TLambda (c0Eol from) (c2Eol to))


{-| Create a type constructor with arguments (e.g., List a, Maybe b).
-}
tType : Name -> List Src.Type -> Src.Type
tType name args =
    A.At A.zero (Src.TType A.zero name (List.map c1 args))


{-| Create a unit type.
-}
tUnit : Src.Type
tUnit =
    A.At A.zero Src.TUnit


{-| Create a tuple type.
-}
tTuple : Src.Type -> Src.Type -> Src.Type
tTuple a b =
    A.At A.zero (Src.TTuple (c2Eol a) (c2Eol b) [])


{-| Create a record type.
-}
tRecord : List ( Name, Src.Type ) -> Src.Type
tRecord fields =
    let
        fieldList =
            List.map (\( name, t ) -> c2 ( c1 (A.At A.zero name), c1 t )) fields
    in
    A.At A.zero (Src.TRecord fieldList Nothing noComments)



-- ============================================================================
-- FUZZERS
-- ============================================================================


{-| Fuzzer for single characters (as strings).
-}
charFuzzer : Fuzzer String
charFuzzer =
    Fuzz.map String.fromChar (Fuzz.intRange 32 126 |> Fuzz.map Char.fromCode)
