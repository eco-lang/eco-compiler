module Compiler.Type.PostSolve exposing (postSolve, NodeTypes)

{-| Rewrites the solver's node types for two kinds of node once solving is
done. A kernel function has no Elm declaration, so nothing gives a reference to
it a type, and this module works one out. A string, character or float literal
or unit is given its fixed type, whatever the solver recorded.

Each expression node's type is recorded in one of two ways, and
`Compiler.Type.Constrain.Typed.Expression` decides which. A _Group A_
node records the solver variable for its own result. A _Group B_ node, which is
a `Str`, `Chr`, `Float`, `Unit` or `Shader` node or a variable reference,
records a placeholder variable constrained to the type its context expects.
Group A entries are kept as they are. Of the Group B entries, string,
character and float literals and unit are overwritten with `String`, `Char`,
`Float` and `()`, kernel references are treated as below, and the rest are
kept.

A _kernel reference_ is a `Can.VarKernel`, a use of a function of a kernel
module such as `Elm.Kernel.List.map`. Its type is worked out from how the
module uses it. The types are kept in a `KernelTypes.KernelTypeEnv`,
one per kernel function, under the first-usage-wins rule and the keying that
`Compiler.Type.KernelTypes` describes. Entries are added in this order.

1.  A _kernel alias_ is a top-level definition with no arguments whose body is
    a bare kernel reference, such as `map = Elm.Kernel.List.map`. Before
    anything else, every kernel alias contributes its type: an annotated one
    its annotated type, and an unannotated one its type in the solver's
    `annotations`, if that has one.
2.  Then the declarations are walked in order. A call whose function is a
    kernel reference contributes the function type from its arguments' node
    types to its own node type. A bare kernel reference passed as an argument
    to a kernel call contributes the parameter type at its position in the
    called kernel's entry, or `Can.TVar "a"` where the entry has no parameter
    there. One passed to a constructor call contributes the type of the
    parameter it is passed for, taken from the constructor's annotation, with
    the annotation's type variables found by matching its result type against
    the call's node type. A bare kernel reference that is an operand of a
    binary operator contributes the parameter type in the operator's
    annotation, and one that is the body of a `case` branch contributes the
    `case` expression's node type.

A kernel reference walked after its kernel has an entry, or whose own position
creates the entry, gets that entry as its node type, so those occurrences of
one kernel all get the same type, whatever the context of each. Any other
kernel reference keeps the solver's type: one walked before its kernel had an
entry, in a position that did not create it, and one whose kernel never gets
an entry.

The exception is an annotated definition with no arguments whose body is a
bare kernel reference, top-level or in a `let`: that reference gets the
definition's own annotated type, whatever its kernel's entry, so that two such
definitions sharing one kernel at different types each keep their own.

@docs postSolve, NodeTypes

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Data.Map
import Dict exposing (Dict)


{-| The type of each expression and pattern node of a module, indexed by node
id. `Nothing` marks an id with no recorded type.

This is a name for an `Array`, not a new type, so nothing checks that it
covers every id of the module.

-}
type alias NodeTypes =
    Array (Maybe (Can.Type Name))


{-| Returns the solver's node types for a module with the literal and kernel
reference entries rewritten as the module documentation describes, together
with the kernel type environment built along the way.

`annotations` are the solver's types for the module's top-level definitions.
They are read only for an unannotated kernel alias.

An entry is written with `Array.set`, so a node id outside the array is
skipped and the array never grows.

-}
postSolve :
    Dict Name (Can.Annotation Name)
    -> Can.Module
    -> NodeTypes
    ->
        { nodeTypes : NodeTypes
        , kernelEnv : KernelTypes.KernelTypeEnv
        }
postSolve annotations (Can.Module canData) nodeTypes0 =
    let
        kernel0 : KernelTypes.KernelTypeEnv
        kernel0 =
            seedKernelAliases annotations canData.decls

        ( nodeTypes1, kernel1 ) =
            postSolveDecls annotations canData.decls nodeTypes0 kernel0
    in
    { nodeTypes = nodeTypes1
    , kernelEnv = kernel1
    }



-- ====== KERNEL ALIAS SEEDING ======


{-| Builds the kernel type environment that the module's kernel aliases alone
give, before any expression is walked. Aliases are taken in declaration order,
so where two aliases name one kernel the first one's type is kept.
-}
seedKernelAliases :
    Dict Name (Can.Annotation Name)
    -> Can.Decls
    -> KernelTypes.KernelTypeEnv
seedKernelAliases annotations decls =
    seedKernelAliasesHelp annotations decls Dict.empty


{-| Returns `env` with an entry added for each kernel alias among `decls`, in
declaration order.
-}
seedKernelAliasesHelp :
    Dict Name (Can.Annotation Name)
    -> Can.Decls
    -> KernelTypes.KernelTypeEnv
    -> KernelTypes.KernelTypeEnv
seedKernelAliasesHelp annotations decls env =
    case decls of
        Can.Declare def rest ->
            seedKernelAliasesHelp annotations rest (checkDefForAlias annotations def env)

        Can.DeclareRec def defs rest ->
            let
                env1 =
                    checkDefForAlias annotations def env

                env2 =
                    List.foldl (\d e -> checkDefForAlias annotations d e) env1 defs
            in
            seedKernelAliasesHelp annotations rest env2

        Can.SaveTheEnvironment ->
            env


{-| Returns `env` with the definition's type added for its kernel, when `def`
is a kernel alias, and `env` unchanged otherwise. An annotated definition
contributes its annotated type; an unannotated one is looked up in
`annotations` by name.
-}
checkDefForAlias :
    Dict Name (Can.Annotation Name)
    -> Can.Def
    -> KernelTypes.KernelTypeEnv
    -> KernelTypes.KernelTypeEnv
checkDefForAlias annotations def env =
    case def of
        Can.Def (A.At _ name) args body ->
            case args of
                [] ->
                    checkKernelAliasBody annotations name body env

                _ ->
                    env

        Can.TypedDef (A.At _ _) _ typedArgs body resultType ->
            case typedArgs of
                [] ->
                    let
                        { node } =
                            A.toValue body
                    in
                    case node of
                        Can.VarKernel _ home kernelName ->
                            KernelTypes.insertFirstUsage home kernelName resultType env

                        _ ->
                            env

                _ ->
                    env


{-| Returns `env` with the type `annotations` gives `defName` added for the
kernel, when `body` is a bare kernel reference, and `env` unchanged otherwise,
including when `annotations` has no entry for `defName`.
-}
checkKernelAliasBody :
    Dict Name (Can.Annotation Name)
    -> Name
    -> Can.Expr
    -> KernelTypes.KernelTypeEnv
    -> KernelTypes.KernelTypeEnv
checkKernelAliasBody annotations defName (A.At _ exprInfo) env =
    case exprInfo.node of
        Can.VarKernel _ home kernelName ->
            case Dict.get defName annotations of
                Just (Can.Forall _ tipe) ->
                    KernelTypes.insertFirstUsage home kernelName tipe env

                Nothing ->
                    env

        _ ->
            env



-- ====== EXPRESSION TRAVERSAL ======


{-| Returns the node types and kernel type environment after walking every
definition of `decls`, in declaration order.
-}
postSolveDecls :
    Dict Name (Can.Annotation Name)
    -> Can.Decls
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveDecls annotations decls nodeTypes0 kernel0 =
    case decls of
        Can.Declare def rest ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0
            in
            postSolveDecls annotations rest nodeTypes1 kernel1

        Can.DeclareRec def defs rest ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0

                ( nodeTypes2, kernel2 ) =
                    List.foldl
                        (\d ( nt, ke ) -> postSolveDef annotations d nt ke)
                        ( nodeTypes1, kernel1 )
                        defs
            in
            postSolveDecls annotations rest nodeTypes2 kernel2

        Can.SaveTheEnvironment ->
            ( nodeTypes0, kernel0 )


{-| Returns the node types and kernel type environment after walking one
definition, top-level or in a `let`.

An annotated definition with no arguments whose body is a bare kernel
reference is handled on its own: the body's node is given the definition's
annotated type rather than its kernel's entry, and the environment is left
unchanged.

-}
postSolveDef :
    Dict Name (Can.Annotation Name)
    -> Can.Def
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveDef annotations def nodeTypes0 kernel0 =
    case def of
        Can.Def _ args body ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolvePatterns args nodeTypes0 kernel0
            in
            postSolveExpr annotations body nodeTypes1 kernel1

        Can.TypedDef _ _ typedArgs body resultType ->
            case typedArgs of
                [] ->
                    let
                        bodyInfo =
                            A.toValue body
                    in
                    case bodyInfo.node of
                        Can.VarKernel _ _ _ ->
                            ( arraySetJust bodyInfo.id resultType nodeTypes0
                            , kernel0
                            )

                        _ ->
                            postSolveExpr annotations body nodeTypes0 kernel0

                _ ->
                    let
                        patterns =
                            List.map Tuple.first typedArgs

                        ( nodeTypes1, kernel1 ) =
                            postSolvePatterns patterns nodeTypes0 kernel0
                    in
                    postSolveExpr annotations body nodeTypes1 kernel1


{-| Returns the node types and kernel type environment after walking each of
`patterns`, which leaves both unchanged, as `postSolvePattern` does.
-}
postSolvePatterns :
    List Can.Pattern
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolvePatterns patterns nodeTypes0 kernel0 =
    List.foldl
        (\pat ( nt, ke ) -> postSolvePattern pat nt ke)
        ( nodeTypes0, kernel0 )
        patterns


{-| Returns `nodeTypes` and the kernel type environment unchanged. A pattern
contains no expression, so nothing in it is rewritten; the walk only descends
into the sub-patterns.
-}
postSolvePattern :
    Can.Pattern
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolvePattern (A.At _ patInfo) nodeTypes0 kernel0 =
    case patInfo.node of
        Can.PAnything ->
            ( nodeTypes0, kernel0 )

        Can.PVar _ ->
            ( nodeTypes0, kernel0 )

        Can.PRecord _ ->
            ( nodeTypes0, kernel0 )

        Can.PAlias pat _ ->
            postSolvePattern pat nodeTypes0 kernel0

        Can.PUnit ->
            ( nodeTypes0, kernel0 )

        Can.PTuple a b cs ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern a nodeTypes0 kernel0

                ( nt2, ke2 ) =
                    postSolvePattern b nt1 ke1
            in
            List.foldl
                (\p ( nt, ke ) -> postSolvePattern p nt ke)
                ( nt2, ke2 )
                cs

        Can.PList pats ->
            List.foldl
                (\p ( nt, ke ) -> postSolvePattern p nt ke)
                ( nodeTypes0, kernel0 )
                pats

        Can.PCons hd tl ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern hd nodeTypes0 kernel0
            in
            postSolvePattern tl nt1 ke1

        Can.PBool _ _ ->
            ( nodeTypes0, kernel0 )

        Can.PChr _ ->
            ( nodeTypes0, kernel0 )

        Can.PStr _ _ ->
            ( nodeTypes0, kernel0 )

        Can.PInt _ ->
            ( nodeTypes0, kernel0 )

        Can.PCtor ctorData ->
            List.foldl
                (\(Can.PatternCtorArg _ _ pat) ( nt, ke ) ->
                    postSolvePattern pat nt ke
                )
                ( nodeTypes0, kernel0 )
                ctorData.args


{-| Returns the node types and kernel type environment after walking one
expression and everything inside it.

A string, character or float literal, or unit, gets its fixed type. A kernel
reference gets its kernel's entry, if it has one by now, and otherwise keeps
the solver's type. Every other node keeps the solver's type; the calls,
binary operators and `case` expressions inside it are where kernel types are
inferred.

-}
postSolveExpr :
    Dict Name (Can.Annotation Name)
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveExpr annotations (A.At _ exprInfo) nodeTypes0 kernel0 =
    let
        exprId =
            exprInfo.id
    in
    case exprInfo.node of
        Can.Int _ ->
            ( nodeTypes0, kernel0 )

        Can.Negate subExpr ->
            postSolveExpr annotations subExpr nodeTypes0 kernel0

        Can.Binop _ _ _ opAnnotation left right ->
            postSolveBinop annotations opAnnotation left right nodeTypes0 kernel0

        Can.Call func args ->
            postSolveCall annotations exprId func args nodeTypes0 kernel0

        Can.If branches final ->
            postSolveIf annotations branches final nodeTypes0 kernel0

        Can.Case scrutinee branches ->
            postSolveCase annotations exprId scrutinee branches nodeTypes0 kernel0

        Can.Access record _ ->
            postSolveExpr annotations record nodeTypes0 kernel0

        Can.Update record fields ->
            postSolveUpdate annotations record fields nodeTypes0 kernel0

        Can.VarKernel _ home name ->
            case KernelTypes.lookup home name kernel0 of
                Just kernelType ->
                    let
                        nodeTypes1 =
                            arraySetJust exprId kernelType nodeTypes0
                    in
                    ( nodeTypes1, kernel0 )

                Nothing ->
                    -- The enclosing call, operator or case may still give this
                    -- node a type once it has inferred one for the kernel.
                    ( nodeTypes0, kernel0 )

        Can.Str _ ->
            let
                strType =
                    Can.TType ModuleName.string Name.string []

                nodeTypes1 =
                    arraySetJust exprId strType nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.Chr _ ->
            let
                chrType =
                    Can.TType ModuleName.char Name.char []

                nodeTypes1 =
                    arraySetJust exprId chrType nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.Float _ ->
            let
                floatType =
                    Can.TType ModuleName.basics Name.float []

                nodeTypes1 =
                    arraySetJust exprId floatType nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.Unit ->
            let
                nodeTypes1 =
                    arraySetJust exprId Can.TUnit nodeTypes0
            in
            ( nodeTypes1, kernel0 )

        Can.List elems ->
            List.foldl
                (\e ( nt, ke ) -> postSolveExpr annotations e nt ke)
                ( nodeTypes0, kernel0 )
                elems

        Can.Tuple a b cs ->
            let
                ( nt1, ke1 ) =
                    postSolveExpr annotations a nodeTypes0 kernel0

                ( nt2, ke2 ) =
                    postSolveExpr annotations b nt1 ke1
            in
            List.foldl
                (\c ( nt, ke ) -> postSolveExpr annotations c nt ke)
                ( nt2, ke2 )
                cs

        Can.Record fields ->
            let
                fieldList =
                    Data.Map.toList fields
            in
            List.foldl
                (\( _, fieldExpr ) ( nt, ke ) ->
                    postSolveExpr annotations fieldExpr nt ke
                )
                ( nodeTypes0, kernel0 )
                fieldList

        Can.Lambda args body ->
            let
                ( nt1, ke1 ) =
                    postSolvePatterns args nodeTypes0 kernel0
            in
            postSolveExpr annotations body nt1 ke1

        Can.Accessor _ ->
            ( nodeTypes0, kernel0 )

        Can.Let def body ->
            let
                ( nt1, ke1 ) =
                    postSolveDef annotations def nodeTypes0 kernel0
            in
            postSolveExpr annotations body nt1 ke1

        Can.LetRec defs body ->
            let
                ( nt1, ke1 ) =
                    List.foldl
                        (\d ( nt, ke ) -> postSolveDef annotations d nt ke)
                        ( nodeTypes0, kernel0 )
                        defs
            in
            postSolveExpr annotations body nt1 ke1

        Can.LetDestruct pat bound body ->
            let
                ( nt1, ke1 ) =
                    postSolvePattern pat nodeTypes0 kernel0

                ( nt2, ke2 ) =
                    postSolveExpr annotations bound nt1 ke1
            in
            postSolveExpr annotations body nt2 ke2

        Can.Shader _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarLocal _ ->
            ( nodeTypes0, kernel0 )

        Can.VarTopLevel _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarForeign _ _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarCtor _ _ _ _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarDebug _ _ _ ->
            ( nodeTypes0, kernel0 )

        Can.VarOperator _ _ _ _ ->
            ( nodeTypes0, kernel0 )


{-| Returns the node types and kernel type environment after walking a call,
where `exprId` is the call's own node id.

When `func` is a kernel reference, the arguments are walked first and the
function itself is not walked as an expression. The kernel's candidate type is
the function type from the arguments' node types to the call's node type,
with `Can.TVar "a"` for an argument and `Can.TVar "result"` for the call when
the node has no type. The candidate is recorded if the kernel has no entry
yet, `func`'s node gets the kernel's entry, and each bare kernel reference
among the arguments whose kernel has no entry is given the parameter type at
its position in that entry, or `Can.TVar "a"` where the entry has no parameter
at that position, as `propagateKernelArgTypes` does.

When `func` is a constructor and some argument is a bare kernel reference, the
call is handled by `postSolveCallWithCtorKernelArgs`. Any other call is walked
as an ordinary expression.

-}
postSolveCall :
    Dict Name (Can.Annotation Name)
    -> Int
    -> Can.Expr
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCall annotations exprId func args nodeTypes0 kernel0 =
    case func of
        A.At _ funcInfo ->
            case funcInfo.node of
                Can.VarKernel _ home name ->
                    let
                        ( nodeTypes1, kernel1 ) =
                            List.foldl
                                (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                                ( nodeTypes0, kernel0 )
                                args

                        argTypes =
                            List.map
                                (\arg ->
                                    case arg of
                                        A.At _ info ->
                                            arrayGetFlat info.id nodeTypes1
                                                |> Maybe.withDefault (Can.TVar "a")
                                )
                                args

                        callResultType =
                            arrayGetFlat exprId nodeTypes1
                                |> Maybe.withDefault (Can.TVar "result")

                        candidateType =
                            KernelTypes.buildFunctionType argTypes callResultType

                        kernel2 =
                            KernelTypes.insertFirstUsage home name candidateType kernel1

                        -- An earlier entry, if there was one, wins over this call's
                        -- candidate.
                        kernelNodeType =
                            case KernelTypes.lookup home name kernel2 of
                                Just t ->
                                    t

                                Nothing ->
                                    candidateType

                        nodeTypes2 =
                            arraySetJust funcInfo.id kernelNodeType nodeTypes1

                        ( inferredArgTypes, _ ) =
                            peelFunctionType kernelNodeType
                    in
                    propagateKernelArgTypes args inferredArgTypes nodeTypes2 kernel2

                Can.VarCtor _ _ _ _ ctorAnnotation ->
                    if hasKernelArg args then
                        postSolveCallWithCtorKernelArgs annotations exprId ctorAnnotation func args nodeTypes0 kernel0

                    else
                        let
                            ( nodeTypes1, kernel1 ) =
                                postSolveExpr annotations func nodeTypes0 kernel0
                        in
                        List.foldl
                            (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                            ( nodeTypes1, kernel1 )
                            args

                _ ->
                    let
                        ( nodeTypes1, kernel1 ) =
                            postSolveExpr annotations func nodeTypes0 kernel0
                    in
                    List.foldl
                        (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                        ( nodeTypes1, kernel1 )
                        args


{-| Returns the node types and kernel type environment after walking each
condition and branch of an `if`, in order, and then the final `else` branch.
-}
postSolveIf :
    Dict Name (Can.Annotation Name)
    -> List ( Can.Expr, Can.Expr )
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveIf annotations branches final nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            List.foldl
                (\( cond, thenExpr ) ( nt, ke ) ->
                    let
                        ( nt2, ke2 ) =
                            postSolveExpr annotations cond nt ke
                    in
                    postSolveExpr annotations thenExpr nt2 ke2
                )
                ( nodeTypes0, kernel0 )
                branches
    in
    postSolveExpr annotations final nt1 ke1


{-| Returns the node types and kernel type environment after walking both
operands of a binary operator.

An operand that is a bare kernel reference, and whose kernel still has no
entry after the walk, is given the parameter type at its position in
`opAnnotation`: the first parameter for `left`, the second for `right`. That
type is taken from the annotation as it stands, in the operator's own type
variables, not from the operand's node type.

-}
postSolveBinop :
    Dict Name (Can.Annotation Name)
    -> Can.Annotation Name
    -> Can.Expr
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveBinop annotations opAnnotation left right nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            postSolveExpr annotations left nodeTypes0 kernel0

        ( nt2, ke2 ) =
            postSolveExpr annotations right nt1 ke1

        leftIsKernel =
            isKernelExpr left

        rightIsKernel =
            isKernelExpr right
    in
    if leftIsKernel || rightIsKernel then
        let
            (Can.Forall _ opType) =
                opAnnotation

            ( argTypes, _ ) =
                peelFunctionType opType

            maybeLeftType =
                List.head argTypes

            maybeRightType =
                argTypes |> List.drop 1 |> List.head

            ( nt3, ke3 ) =
                case ( leftIsKernel, maybeLeftType ) of
                    ( True, Just expectedType ) ->
                        inferBinopKernelType left expectedType nt2 ke2

                    _ ->
                        ( nt2, ke2 )
        in
        case ( rightIsKernel, maybeRightType ) of
            ( True, Just expectedType ) ->
                inferBinopKernelType right expectedType nt3 ke3

            _ ->
                ( nt3, ke3 )

    else
        ( nt2, ke2 )


{-| Returns the node types and kernel type environment with `expectedType`
recorded for the kernel and written to `operand`'s node, when `operand` is a
bare kernel reference whose kernel has no entry yet. Otherwise both are
returned unchanged.
-}
inferBinopKernelType :
    Can.Expr
    -> Can.Type Name
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
inferBinopKernelType operand expectedType nodeTypes kernel =
    case operand of
        A.At _ exprInfo ->
            case exprInfo.node of
                Can.VarKernel _ home name ->
                    if KernelTypes.hasEntry home name kernel then
                        ( nodeTypes, kernel )

                    else
                        let
                            ke2 =
                                KernelTypes.insertFirstUsage home name expectedType kernel

                            nt2 =
                                arraySetJust exprInfo.id expectedType nodeTypes
                        in
                        ( nt2, ke2 )

                _ ->
                    ( nodeTypes, kernel )


{-| Returns the node types and kernel type environment after walking the
scrutinee and then each branch of a `case`, where `caseExprId` is the `case`
expression's own node id.

Every branch has the type of the whole `case`, so a branch body that is a bare
kernel reference, and whose kernel still has no entry after the branch is
walked, is given the `case` node's type, or `Can.TVar "a"` when that node has
none.

-}
postSolveCase :
    Dict Name (Can.Annotation Name)
    -> Int
    -> Can.Expr
    -> List Can.CaseBranch
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCase annotations caseExprId scrutinee branches nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            postSolveExpr annotations scrutinee nodeTypes0 kernel0

        caseResultType =
            arrayGetFlat caseExprId nt1
                |> Maybe.withDefault (Can.TVar "a")

        stepBranch (Can.CaseBranch pat branchExpr) ( nt, ke ) =
            let
                ( nt2, ke2 ) =
                    postSolvePattern pat nt ke

                ( nt3, ke3 ) =
                    postSolveExpr annotations branchExpr nt2 ke2
            in
            inferBranchKernelType branchExpr caseResultType nt3 ke3
    in
    List.foldl stepBranch ( nt1, ke1 ) branches


{-| Returns the node types and kernel type environment with `expectedType`
recorded for the kernel and written to `branchExpr`'s node, when `branchExpr`
is a bare kernel reference whose kernel has no entry yet. Otherwise both are
returned unchanged.
-}
inferBranchKernelType :
    Can.Expr
    -> Can.Type Name
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
inferBranchKernelType branchExpr expectedType nodeTypes kernel =
    case branchExpr of
        A.At _ exprInfo ->
            case exprInfo.node of
                Can.VarKernel _ home name ->
                    if KernelTypes.hasEntry home name kernel then
                        ( nodeTypes, kernel )

                    else
                        let
                            ke2 =
                                KernelTypes.insertFirstUsage home name expectedType kernel

                            nt2 =
                                arraySetJust exprInfo.id expectedType nodeTypes
                        in
                        ( nt2, ke2 )

                _ ->
                    ( nodeTypes, kernel )


{-| Returns the node types and kernel type environment after walking the
record being updated and then each new field value, in field-name order.
-}
postSolveUpdate :
    Dict Name (Can.Annotation Name)
    -> Can.Expr
    -> Data.Map.Dict String (A.Located Name) Can.FieldUpdate
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveUpdate annotations record fields nodeTypes0 kernel0 =
    let
        ( nt1, ke1 ) =
            postSolveExpr annotations record nodeTypes0 kernel0

        fieldList =
            Data.Map.toList fields
    in
    List.foldl
        (\( _, Can.FieldUpdate _ fieldExpr ) ( nt, ke ) ->
            postSolveExpr annotations fieldExpr nt ke
        )
        ( nt1, ke1 )
        fieldList



-- ====== KERNEL ARGUMENT TYPE INFERENCE ======


{-| Tells whether any of `args` is a bare kernel reference. A call of a kernel
function among the arguments does not count.
-}
hasKernelArg : List Can.Expr -> Bool
hasKernelArg args =
    List.any isKernelExpr args


{-| Tells whether an expression is a bare kernel reference, a `Can.VarKernel`
node.
-}
isKernelExpr : Can.Expr -> Bool
isKernelExpr (A.At _ info) =
    case info.node of
        Can.VarKernel _ _ _ ->
            True

        _ ->
            False


{-| Returns the node types and kernel type environment with each bare kernel
reference among `args` given the type in the same position of
`expectedTypes`, when its kernel has no entry yet: the type is recorded for
the kernel and written to the argument's node. An argument beyond the end of
`expectedTypes` is given `Can.TVar "a"`. Other arguments, and kernel
references whose kernel already has an entry, are left as they are; they are
expected to have been walked already.
-}
propagateKernelArgTypes :
    List Can.Expr
    -> List (Can.Type Name)
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
propagateKernelArgTypes args expectedTypes nodeTypes0 kernel0 =
    let
        argsWithTypes =
            List.map2 Tuple.pair args expectedTypes
                ++ List.map (\arg -> ( arg, Can.TVar "a" )) (List.drop (List.length expectedTypes) args)

        processArg ( arg, expectedType ) ( nt, ke ) =
            case arg of
                A.At _ argInfo ->
                    case argInfo.node of
                        Can.VarKernel _ argHome argName ->
                            if KernelTypes.hasEntry argHome argName ke then
                                ( nt, ke )

                            else
                                let
                                    ke2 =
                                        KernelTypes.insertFirstUsage argHome argName expectedType ke

                                    nt2 =
                                        arraySetJust argInfo.id expectedType nt
                                in
                                ( nt2, ke2 )

                        _ ->
                            ( nt, ke )
    in
    List.foldl processArg ( nodeTypes0, kernel0 ) argsWithTypes


{-| A binding of type variable names to types, found by matching a
constructor's annotation against a call's type with `unifySchemeToType`.
-}
type alias Subst =
    Dict Name (Can.Type Name)


{-| Returns the binding of `scheme`'s type variables that makes it match
`concrete`, or `Nothing` when the two do not match.

The match is one way: only a type variable of `scheme` is bound, and a type
variable of `concrete` is matched like any other type. A variable met twice
must be bound to `==` types both times. The arrow slots of two function types
being matched are not compared, and a `Filled` alias on either side is
replaced by its body, except that a type variable of `scheme` is bound to an
alias as it stands. Two record types match only with the same extension
variable, or none, and the same field names. A `Holey` alias is not looked
into: it matches only a type `==` to it.

-}
unifySchemeToType : Can.Type Name -> Can.Type Name -> Maybe Subst
unifySchemeToType scheme concrete =
    unifyHelp Dict.empty scheme concrete


{-| Returns `subst` extended so that `schemeType` matches `concreteType`, or
`Nothing` when it cannot be, as `unifySchemeToType` describes.
-}
unifyHelp : Subst -> Can.Type Name -> Can.Type Name -> Maybe Subst
unifyHelp subst schemeType concreteType =
    case ( schemeType, concreteType ) of
        ( Can.TVar v, t ) ->
            case Dict.get v subst of
                Nothing ->
                    Just (Dict.insert v t subst)

                Just existing ->
                    if existing == t then
                        Just subst

                    else
                        Nothing

        ( Can.TType home1 name1 args1, Can.TType home2 name2 args2 ) ->
            if home1 == home2 && name1 == name2 && List.length args1 == List.length args2 then
                unifyList subst args1 args2

            else
                Nothing

        -- The arrow slots are left uncompared on purpose: a slot names one
        -- occurrence of a function type, so two occurrences of the same type
        -- may carry different slots and still match.
        ( Can.TLambda _ arg1 res1, Can.TLambda _ arg2 res2 ) ->
            case unifyHelp subst arg1 arg2 of
                Nothing ->
                    Nothing

                Just subst1 ->
                    unifyHelp subst1 res1 res2

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            if List.length cs1 == List.length cs2 then
                case unifyHelp subst a1 a2 of
                    Nothing ->
                        Nothing

                    Just subst1 ->
                        case unifyHelp subst1 b1 b2 of
                            Nothing ->
                                Nothing

                            Just subst2 ->
                                unifyList subst2 cs1 cs2

            else
                Nothing

        ( Can.TUnit, Can.TUnit ) ->
            Just subst

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            if ext1 == ext2 then
                let
                    fieldList1 =
                        Dict.toList fields1

                    fieldList2 =
                        Dict.toList fields2
                in
                if List.length fieldList1 == List.length fieldList2 then
                    unifyFieldList subst fieldList1 fieldList2

                else
                    Nothing

            else
                Nothing

        ( Can.TAlias _ _ _ (Can.Filled realType1), t2 ) ->
            unifyHelp subst realType1 t2

        ( t1, Can.TAlias _ _ _ (Can.Filled realType2) ) ->
            unifyHelp subst t1 realType2

        _ ->
            if schemeType == concreteType then
                Just subst

            else
                Nothing


{-| Returns `subst` extended so that each type of `list1` matches the type in
the same position of `list2`, or `Nothing` when one does not or the lists
differ in length.
-}
unifyList : Subst -> List (Can.Type Name) -> List (Can.Type Name) -> Maybe Subst
unifyList subst list1 list2 =
    case ( list1, list2 ) of
        ( [], [] ) ->
            Just subst

        ( h1 :: t1, h2 :: t2 ) ->
            case unifyHelp subst h1 h2 of
                Nothing ->
                    Nothing

                Just subst1 ->
                    unifyList subst1 t1 t2

        _ ->
            Nothing


{-| Returns `subst` extended so that each field type of `list1` matches the
field in the same position of `list2`, or `Nothing` when one does not, two
fields in the same position have different names, or the lists differ in
length. The field index stored in each `FieldType` is ignored.
-}
unifyFieldList : Subst -> List ( Name, Can.FieldType Name ) -> List ( Name, Can.FieldType Name ) -> Maybe Subst
unifyFieldList subst list1 list2 =
    case ( list1, list2 ) of
        ( [], [] ) ->
            Just subst

        ( ( name1, Can.FieldType _ type1 ) :: t1, ( name2, Can.FieldType _ type2 ) :: t2 ) ->
            if name1 == name2 then
                case unifyHelp subst type1 type2 of
                    Nothing ->
                        Nothing

                    Just subst1 ->
                        unifyFieldList subst1 t1 t2

            else
                Nothing

        _ ->
            Nothing


{-| Returns `tipe` with every type variable that `subst` binds replaced by its
binding, including inside the body of a `Holey` alias. A record's extension
variable is left as it is.
-}
applySubst : Subst -> Can.Type Name -> Can.Type Name
applySubst subst tipe =
    case tipe of
        Can.TVar v ->
            Dict.get v subst
                |> Maybe.withDefault tipe

        Can.TType home name args ->
            Can.TType home name (List.map (applySubst subst) args)

        Can.TLambda aid arg res ->
            -- The arrow slot is kept as it is. Where the bound types carry
            -- stamped slots, the `TVar` arm copies one bound type, slots and
            -- all, into every position its variable occupies.
            Can.TLambda aid (applySubst subst arg) (applySubst subst res)

        Can.TTuple a b cs ->
            Can.TTuple
                (applySubst subst a)
                (applySubst subst b)
                (List.map (applySubst subst) cs)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (applySubst subst t)) fields)
                ext

        Can.TAlias home name args aliasType ->
            Can.TAlias home
                name
                (List.map (\( n, t ) -> ( n, applySubst subst t )) args)
                (case aliasType of
                    Can.Holey t ->
                        Can.Holey (applySubst subst t)

                    Can.Filled t ->
                        Can.Filled (applySubst subst t)
                )

        Can.TUnit ->
            tipe


{-| Returns the parameter types of a function type, in order, and the type
that remains once they are all taken off.

    peelFunctionType (A -> B -> C) == ( [A, B], C )

Only `TLambda` nodes are taken off. An alias of a function type is not looked
into, so for one the result is no parameters and the alias itself.

-}
peelFunctionType : Can.Type Name -> ( List (Can.Type Name), Can.Type Name )
peelFunctionType tipe =
    case tipe of
        Can.TLambda _ arg res ->
            let
                ( restArgs, finalResult ) =
                    peelFunctionType res
            in
            ( arg :: restArgs, finalResult )

        _ ->
            ( [], tipe )


{-| Returns the node types and kernel type environment after walking a call
of a constructor, where `exprId` is the call's own node id.

The result type in `ctorAnnotation` is matched against the call's node type
with `unifySchemeToType`. When they match, the call is handled by
`processCtorArgs` with the binding found. When they do not, or the call has no
node type, the function and the arguments are walked as ordinary expressions
and no kernel type is inferred here.

-}
postSolveCallWithCtorKernelArgs :
    Dict Name (Can.Annotation Name)
    -> Int
    -> Can.Annotation Name
    -> Can.Expr
    -> List Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
postSolveCallWithCtorKernelArgs annotations exprId ctorAnnotation funcExpr args nodeTypes0 kernel0 =
    let
        (Can.Forall _ ctorType) =
            ctorAnnotation

        ( ctorArgTypes, ctorResType ) =
            peelFunctionType ctorType

        maybeCallType =
            arrayGetFlat exprId nodeTypes0

        maybeSubst =
            case maybeCallType of
                Just callType ->
                    unifySchemeToType ctorResType callType

                Nothing ->
                    Nothing
    in
    case maybeSubst of
        Just subst ->
            processCtorArgs annotations subst ctorArgTypes args funcExpr nodeTypes0 kernel0

        Nothing ->
            let
                ( nodeTypes1, kernel1 ) =
                    postSolveExpr annotations funcExpr nodeTypes0 kernel0
            in
            List.foldl
                (\arg ( nt, ke ) -> postSolveExpr annotations arg nt ke)
                ( nodeTypes1, kernel1 )
                args


{-| Returns the node types and kernel type environment after walking
`funcExpr` and then each of `args`, giving kernel types to the bare kernel
references among them.

A bare kernel reference whose kernel has no entry yet is given the matching
parameter type of `ctorArgTypes` with `subst` applied: the type is recorded
for the kernel and written to the argument's node. Every other argument,
including a kernel reference beyond the end of `ctorArgTypes`, is walked as an
ordinary expression.

-}
processCtorArgs :
    Dict Name (Can.Annotation Name)
    -> Subst
    -> List (Can.Type Name)
    -> List Can.Expr
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
processCtorArgs annotations subst ctorArgTypes args funcExpr nodeTypes0 kernel0 =
    let
        ( nodeTypes1, kernel1 ) =
            postSolveExpr annotations funcExpr nodeTypes0 kernel0

        processArg : ( Can.Expr, Maybe (Can.Type Name) ) -> ( NodeTypes, KernelTypes.KernelTypeEnv ) -> ( NodeTypes, KernelTypes.KernelTypeEnv )
        processArg ( arg, maybeExpectedType ) ( nt, ke ) =
            case arg of
                A.At _ argInfo ->
                    case argInfo.node of
                        Can.VarKernel _ home name ->
                            if KernelTypes.hasEntry home name ke then
                                postSolveExpr annotations arg nt ke

                            else
                                case maybeExpectedType of
                                    Just expectedType ->
                                        let
                                            kernelType =
                                                applySubst subst expectedType

                                            ke2 =
                                                KernelTypes.insertFirstUsage home name kernelType ke

                                            nt2 =
                                                arraySetJust argInfo.id kernelType nt
                                        in
                                        ( nt2, ke2 )

                                    Nothing ->
                                        postSolveExpr annotations arg nt ke

                        _ ->
                            postSolveExpr annotations arg nt ke

        argsWithTypes =
            List.map2 (\arg t -> ( arg, Just t )) args ctorArgTypes
                ++ List.map (\arg -> ( arg, Nothing )) (List.drop (List.length ctorArgTypes) args)
    in
    List.foldl processArg ( nodeTypes1, kernel1 ) argsWithTypes



-- ====== Array Helpers ======


{-| Returns `nodeTypes` with `tipe` recorded for node `id`. An `id` outside the
array, such as a negative one, leaves it unchanged.
-}
arraySetJust : Int -> Can.Type Name -> NodeTypes -> NodeTypes
arraySetJust id tipe nodeTypes =
    Array.set id (Just tipe) nodeTypes


{-| Returns the type recorded for node `id`, or `Nothing` when there is none or
`id` is outside the array.
-}
arrayGetFlat : Int -> NodeTypes -> Maybe (Can.Type Name)
arrayGetFlat id nodeTypes =
    Array.get id nodeTypes |> Maybe.andThen identity
