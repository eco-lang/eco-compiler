module Compiler.Parse.Shader exposing (shader)

{-| An Elm expression can embed a WebGL shader as a GLSL literal, written
`[glsl| ... |]`, and this module parses one.

The type checker gives a shader an Elm type built from its inputs, so the
parser has to look inside the GLSL rather than carry it as opaque text. The
literal is read in two steps. First the text between `[glsl|` and the first
`|]` after it is cut out as it stands, so a `|]` anywhere in the GLSL, even in a
GLSL comment, ends the literal. Then that text is handed to the GLSL parser
of `Language.GLSL.Parser`, and the inputs are picked out of the declarations it
returns.

An input is recorded only when it is a top-level declaration of a single
name, qualified `attribute`, `uniform` or `varying`, with one of the types
`vec2`, `vec3`, `vec4`, `mat4`, `int`, `float`, `sampler2D` or `bool`. Every
other declaration is ignored, without error. What the three kinds of input
mean is stated in `Compiler.AST.Utils.Shader`.

A GLSL syntax error is reported as an Elm syntax error. The GLSL parser gives
only a character offset into the cut-out text, so this module turns that offset
back into a row and column in the Elm file.

@docs shader

-}

import Compiler.AST.Source as Src
import Compiler.AST.Utils.Shader as Shader
import Compiler.Parse.Primitives as P exposing (Col, Parser, Row)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E
import Data.Map as Dict
import Language.GLSL.Parser as GLP
import Language.GLSL.Syntax as GLS
import Utils.Crash as Crash



-- ====== SHADER ======


{-| Parses a GLSL literal that begins at the current position, given that
position as `start`, and returns a `Src.Shader` expression located from `start`
to just after the closing `|]`.

The expression holds the text between the delimiters, escaped by
`Shader.fromString`, and the inputs found in it. Input that does not begin with
`[glsl|` fails without consuming anything, with `E.Start`. A literal with no
closing `|]` fails with `E.EndlessShader` at the opening `[`, and one whose
GLSL does not parse fails with `E.ShaderProblem`. When the same name is
declared twice with the same qualifier, the first declaration's type is kept.

-}
shader : A.Position -> Parser E.Expr Src.Expr
shader ((A.Position row col) as start) =
    parseBlock
        |> P.andThen
            (\block ->
                parseGlsl row col block
                    |> P.andThen
                        (\shdr ->
                            P.getPosition
                                |> P.map
                                    (\end ->
                                        A.at start end (Src.Shader (Shader.fromString block) shdr)
                                    )
                        )
            )



-- ====== BLOCK ======


{-| A parser for the delimiters of a GLSL literal, producing the raw text
between `[glsl|` and the first `|]`, which is consumed too.
-}
parseBlock : Parser E.Expr String
parseBlock =
    P.Parser <|
        \(P.State st) ->
            let
                pos6 : Int
                pos6 =
                    st.pos + 6
            in
            if
                (pos6 <= st.end)
                    && (P.unsafeIndex st.src st.pos == '[')
                    && (P.unsafeIndex st.src (st.pos + 1) == 'g')
                    && (P.unsafeIndex st.src (st.pos + 2) == 'l')
                    && (P.unsafeIndex st.src (st.pos + 3) == 's')
                    && (P.unsafeIndex st.src (st.pos + 4) == 'l')
                    && (P.unsafeIndex st.src (st.pos + 5) == '|')
            then
                let
                    ( ( status, newPos ), ( newRow, newCol ) ) =
                        eatShader st.src pos6 st.end st.row (st.col + 6)
                in
                case status of
                    Good ->
                        let
                            off : Int
                            off =
                                pos6

                            len : Int
                            len =
                                newPos - pos6

                            block : String
                            block =
                                String.left len (String.dropLeft off st.src)

                            newState : P.State
                            newState =
                                P.State { st | pos = newPos + 2, row = newRow, col = newCol + 2 }
                        in
                        P.Cok block newState

                    Unending ->
                        P.Cerr st.row st.col E.EndlessShader

            else
                P.Eerr st.row st.col E.Start


{-| Whether `eatShader` found the end of a GLSL literal: `Good` when it reached
a `|]`, and `Unending` when the input ran out first.
-}
type Status
    = Good
    | Unending


{-| Scans the source from `pos` for the first `|]`, tracking the row and
column as it goes, and returns whether one was found, the position where
the scan stopped (the `|` of the `|]` when one was found), and the row and
column of that point.
-}
eatShader : String -> Int -> Int -> Row -> Col -> ( ( Status, Int ), ( Row, Col ) )
eatShader src pos end row col =
    if pos >= end then
        ( ( Unending, pos ), ( row, col ) )

    else
        let
            word : Char
            word =
                P.unsafeIndex src pos
        in
        if word == '|' && P.isWord src (pos + 1) end ']' then
            ( ( Good, pos ), ( row, col ) )

        else if word == '\n' then
            eatShader src (pos + 1) end (row + 1) 1

        else
            let
                newPos : Int
                newPos =
                    pos + P.getCharWidth word
            in
            eatShader src newPos end row (col + 1)



-- ====== GLSL ======


{-| Produces a parser that returns the inputs declared in `src`, the GLSL text
of a literal whose `[glsl|` opener starts at `startRow` and `startCol`.

When `src` does not parse, the parser fails with `E.ShaderProblem` carrying the
GLSL parser's messages. The GLSL parser reports the failure as a character
offset into `src`, which is turned here into a position in the Elm file: on the
literal's first line the column is counted from just after `[glsl|`, and on a
later line it is the `String.length` (UTF-16 units) of the text before the
offset on that line.

-}
parseGlsl : Row -> Col -> String -> Parser E.Expr Shader.Types
parseGlsl startRow startCol src =
    case GLP.parse src of
        Ok (GLS.TranslationUnit decls) ->
            P.pure (List.foldr addInput emptyTypes (List.concatMap extractInputs decls))

        Err { position, messages } ->
            let
                lines : List String
                lines =
                    String.left position src
                        |> String.lines

                row : Int
                row =
                    List.length lines

                col : Int
                col =
                    case List.reverse lines of
                        lastLine :: _ ->
                            String.length lastLine

                        _ ->
                            0

                msg : String
                msg =
                    showErrorMessages messages
            in
            if row == 1 then
                failure startRow (startCol + 6 + col) msg

            else
                failure (startRow + row - 1) col msg


{-| Joins the GLSL parser's messages into one, one per line, or returns
`"unknown parse error"` when there are none.
-}
showErrorMessages : List String -> String
showErrorMessages msgs =
    if List.isEmpty msgs then
        "unknown parse error"

    else
        String.join "\n" msgs


{-| Produces a parser that always fails with `E.ShaderProblem msg` at `row`
and `col`, as an error after consuming input.
-}
failure : Row -> Col -> String -> Parser E.Expr a
failure row col msg =
    P.Parser <|
        \_ ->
            P.Cerr row col (E.ShaderProblem msg)



-- ====== INPUTS ======


{-| The inputs of a shader that declares none.
-}
emptyTypes : Shader.Types
emptyTypes =
    Shader.Types Dict.empty Dict.empty Dict.empty


{-| Adds one input to the inputs of its kind, replacing an earlier entry of
the same name and kind.

It crashes for a qualifier other than `attribute`, `uniform` or `varying`,
which `extractInputs` never returns.

-}
addInput : ( GLS.StorageQualifier, Shader.Type, String ) -> Shader.Types -> Shader.Types
addInput ( qual, tipe, name ) (Shader.Types attribute uniform varying) =
    case qual of
        GLS.Attribute ->
            Shader.Types (Dict.insert identity name tipe attribute) uniform varying

        GLS.Uniform ->
            Shader.Types attribute (Dict.insert identity name tipe uniform) varying

        GLS.Varying ->
            Shader.Types attribute uniform (Dict.insert identity name tipe varying)

        _ ->
            Crash.crash "Should never happen due to `extractInputs` function"


{-| Returns the input that a top-level GLSL declaration declares, as its
qualifier, type and name, or an empty list when the declaration is not an
input this module records.
-}
extractInputs : GLS.ExternalDeclaration -> List ( GLS.StorageQualifier, Shader.Type, String )
extractInputs decl =
    case decl of
        GLS.Declaration (GLS.InitDeclaration (GLS.TypeDeclarator (GLS.FullType (Just (GLS.TypeQualSto qual)) (GLS.TypeSpec _ (GLS.TypeSpecNoPrecision tipe _)))) [ GLS.InitDecl name _ _ ]) ->
            if List.member qual [ GLS.Attribute, GLS.Varying, GLS.Uniform ] then
                case tipe of
                    GLS.Vec2 ->
                        [ ( qual, Shader.V2, name ) ]

                    GLS.Vec3 ->
                        [ ( qual, Shader.V3, name ) ]

                    GLS.Vec4 ->
                        [ ( qual, Shader.V4, name ) ]

                    GLS.Mat4 ->
                        [ ( qual, Shader.M4, name ) ]

                    GLS.Int ->
                        [ ( qual, Shader.Int, name ) ]

                    GLS.Float ->
                        [ ( qual, Shader.Float, name ) ]

                    GLS.Sampler2D ->
                        [ ( qual, Shader.Texture, name ) ]

                    GLS.Bool ->
                        [ ( qual, Shader.Bool, name ) ]

                    _ ->
                        []

            else
                []

        _ ->
            []
