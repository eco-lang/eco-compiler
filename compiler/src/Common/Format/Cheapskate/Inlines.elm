module Common.Format.Cheapskate.Inlines exposing
    ( pHtmlTag
    , pLinkLabel
    , pReference
    , parseInlines
    )

import Common.Format.Cheapskate.ParserCombinators
    exposing
        ( Parser
        , andThen
        , anyChar
        , char
        , endOfInput
        , fail
        , guard
        , lazy
        , leftSequence
        , many
        , manyTill
        , map
        , mzero
        , notAfter
        , notInClass
        , oneOf
        , option
        , parse
        , peekChar
        , return
        , satisfy
        , scan
        , showParseError
        , skip
        , string
        , takeTill
        , takeWhile
        , takeWhile1
        )
import Common.Format.Cheapskate.Types exposing (HtmlTagType(..), Inline(..), Inlines, LinkTarget(..), ReferenceMap)
import Common.Format.Cheapskate.Util exposing (isEscapable, isWhitespace, nfb, nfbChar, scanSpaces, scanSpnl)
import Set exposing (Set)
import Utils.Crash exposing (crash)


{-| Returns tag type and whole tag.
-}
pHtmlTag : Parser ( HtmlTagType, String )
pHtmlTag =
    char '<'
        |> andThen
            (\_ ->
                -- do not end the tag with a > character in a quoted attribute.
                oneOf (char '/' |> map (\_ -> True)) (return False)
                    |> andThen
                        (\closing ->
                            takeWhile1 (\c -> isAsciiAlphaNum c || c == '?' || c == '!')
                                |> andThen
                                    (\tagname ->
                                        let
                                            tagname_ : String
                                            tagname_ =
                                                String.toLower tagname

                                            attr : Parser String
                                            attr =
                                                takeWhile isSpace
                                                    |> andThen
                                                        (\ss ->
                                                            satisfy Char.isAlpha
                                                                |> andThen
                                                                    (\x ->
                                                                        takeWhile (\c -> isAsciiAlphaNum c || c == ':')
                                                                            |> andThen
                                                                                (\xs ->
                                                                                    skip ((==) '=')
                                                                                        |> andThen (\_ -> oneOf (pQuoted '"') (oneOf (pQuoted '\'') (oneOf (takeWhile1 Char.isAlphaNum) (return ""))))
                                                                                        |> map
                                                                                            (\v ->
                                                                                                ss ++ String.fromChar x ++ xs ++ "=" ++ v
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                        in
                                        many attr
                                            |> map String.concat
                                            |> andThen
                                                (\attrs ->
                                                    takeWhile (\c -> isSpace c || c == '/')
                                                        |> andThen
                                                            (\final ->
                                                                char '>'
                                                                    |> andThen
                                                                        (\_ ->
                                                                            let
                                                                                tagtype : HtmlTagType
                                                                                tagtype =
                                                                                    if closing then
                                                                                        Closing tagname_

                                                                                    else
                                                                                        case stringStripSuffix "/" final of
                                                                                            Just _ ->
                                                                                                SelfClosing tagname_

                                                                                            Nothing ->
                                                                                                Opening tagname_
                                                                            in
                                                                            return
                                                                                ( tagtype
                                                                                , String.fromList
                                                                                    ('<'
                                                                                        :: (if closing then
                                                                                                [ '/' ]

                                                                                            else
                                                                                                []
                                                                                           )
                                                                                    )
                                                                                    ++ tagname
                                                                                    ++ attrs
                                                                                    ++ final
                                                                                    ++ ">"
                                                                                )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


isSpace : Char -> Bool
isSpace c =
    c == '\t' || c == '\n' || c == '\u{000D}'


stringStripSuffix : String -> String -> Maybe String
stringStripSuffix p t =
    if String.endsWith p t then
        Just (String.dropRight (String.length p) t)

    else
        Nothing


{-| Parses a quoted attribute value.
-}
pQuoted : Char -> Parser String
pQuoted c =
    skip ((==) c)
        |> andThen (\_ -> takeTill ((==) c))
        |> andThen
            (\contents ->
                skip ((==) c)
                    |> map (\_ -> String.fromChar c ++ contents ++ String.fromChar c)
            )


{-| Parses an HTML comment. This isn't really correct to spec, but should
do for now.
-}
pHtmlComment : Parser String
pHtmlComment =
    string "<!--"
        |> andThen (\_ -> manyTill anyChar (string "-->"))
        |> andThen (\rest -> return ("<!--" ++ String.fromList rest ++ "-->"))


{-| A link label [like this]. Note the precedence: code backticks have
precedence over label bracket markers, which have precedence over
\*, \_, and other inline formatting markers.
So, 2 below contains a link while 1 does not:

1.  [a link `with a ](/url)` character
2.  [a link \*with emphasized ](/url) text\*

-}
pLinkLabel : Parser String
pLinkLabel =
    let
        regChunk : Parser String
        regChunk =
            takeWhile1 (\c -> c /= '`' && c /= '[' && c /= ']' && c /= '\\')

        codeChunk : Parser String
        codeChunk =
            map Tuple.second pCode_

        bracketed : Parser String
        bracketed =
            lazy (\() -> pLinkLabel)
                |> map inBrackets

        inBrackets : String -> String
        inBrackets t =
            "[" ++ t ++ "]"
    in
    char '['
        |> andThen
            (\_ ->
                map String.concat
                    (manyTill (oneOf regChunk (oneOf pEscaped (oneOf bracketed codeChunk))) (char ']'))
            )


{-| A URL in a link or reference. This may optionally be contained
in `<..>`; otherwise whitespace and unbalanced right parentheses
aren't allowed. Newlines aren't allowed in any case.
-}
pLinkUrl : Parser String
pLinkUrl =
    oneOf (char '<' |> andThen (\_ -> return True)) (return False)
        |> andThen
            (\inPointy ->
                if inPointy then
                    manyTill (pSatisfy (\c -> c /= '\u{000D}' && c /= '\n')) (char '>')
                        |> map String.fromList

                else
                    let
                        regChunk : Parser String
                        regChunk =
                            oneOf (takeWhile1 (notInClass " \n()\\")) pEscaped

                        parenChunk : () -> Parser String
                        parenChunk () =
                            char '('
                                |> andThen (\_ -> manyTill (oneOf regChunk (lazy parenChunk)) (char ')'))
                                |> map (parenthesize << String.concat)

                        parenthesize : String -> String
                        parenthesize x =
                            "(" ++ x ++ ")"
                    in
                    map String.concat (many (oneOf regChunk (parenChunk ())))
            )


{-| A link title, single or double quoted or in parentheses.
Note that Markdown.pl doesn't allow the parenthesized form in
inline links -- only in references -- but this restriction seems
arbitrary, so we remove it here.
-}
pLinkTitle : Parser String
pLinkTitle =
    satisfy (\c -> c == '"' || c == '\'' || c == '(')
        |> andThen
            (\c ->
                peekChar
                    |> andThen
                        (\next ->
                            case next of
                                Nothing ->
                                    mzero

                                Just x ->
                                    if isWhitespace x then
                                        mzero

                                    else if x == ')' then
                                        mzero

                                    else
                                        return ()
                        )
                    |> andThen
                        (\_ ->
                            let
                                ender : Char
                                ender =
                                    if c == '(' then
                                        ')'

                                    else
                                        c

                                pEnder : Parser Char
                                pEnder =
                                    skip Char.isAlphaNum |> nfb |> andThen (\_ -> char ender)

                                regChunk : Parser String
                                regChunk =
                                    oneOf (takeWhile1 (\x -> x /= ender && x /= '\\')) pEscaped

                                nestedChunk : Parser String
                                nestedChunk =
                                    lazy (\() -> pLinkTitle)
                                        |> map (\x -> String.fromChar c ++ x ++ String.fromChar ender)
                            in
                            map String.concat (manyTill (oneOf regChunk nestedChunk) pEnder)
                        )
            )


{-| A link reference is a square-bracketed link label, a colon,
optional space or newline, a URL, optional space or newline,
and an optional link title. (Note: we assume the input is
pre-stripped, with no leading/trailing spaces.)
-}
pReference : Parser ( String, String, String )
pReference =
    pLinkLabel
        |> andThen
            (\lab ->
                char ':'
                    |> andThen (\_ -> scanSpnl)
                    |> andThen (\_ -> pLinkUrl)
                    |> andThen
                        (\url ->
                            option "" (scanSpnl |> andThen (\_ -> pLinkTitle))
                                |> andThen
                                    (\tit ->
                                        endOfInput
                                            |> map (\_ -> ( lab, url, tit ))
                                    )
                        )
            )


{-| Parses an escaped character and returns a Text.
-}
pEscaped : Parser String
pEscaped =
    map String.fromChar (skip ((==) '\\') |> andThen (\_ -> satisfy isEscapable))


{-| Parses a (possibly escaped) character satisfying the predicate.
-}
pSatisfy : (Char -> Bool) -> Parser Char
pSatisfy p =
    oneOf (satisfy (\c -> c /= '\\' && p c))
        (char '\\' |> andThen (\_ -> satisfy (\c -> isEscapable c && p c)))


{-| Parse a text into inlines, resolving reference links
using the reference map.
-}
parseInlines : ReferenceMap -> String -> Inlines
parseInlines remap t =
    case parse (map List.concat (leftSequence (many (pInline remap)) endOfInput)) t of
        Err e ->
            -- should not happen
            crash ("parseInlines: " ++ showParseError e)

        Ok r ->
            r


pInline : ReferenceMap -> Parser Inlines
pInline remap =
    oneOf pAsciiStr
        (oneOf pSpace
            -- strong/emph
            (oneOf (pEnclosure '*' remap)
                (oneOf (notAfter Char.isAlphaNum |> andThen (\_ -> pEnclosure '_' remap))
                    (oneOf pCode
                        (oneOf (pLink remap)
                            (oneOf (pImage remap)
                                (oneOf pRawHtml
                                    (oneOf pAutolink
                                        (oneOf pEntity pSym)
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )


{-| Parse spaces or newlines, and determine whether
we have a regular space, a line break (two spaces before
a newline), or a soft break (newline without two spaces
before).
-}
pSpace : Parser Inlines
pSpace =
    takeWhile1 isWhitespace
        |> andThen
            (\ss ->
                return
                    (List.singleton
                        (if String.any ((==) '\n') ss then
                            if String.startsWith "  " ss then
                                LineBreak

                            else
                                SoftBreak

                         else
                            Space
                        )
                    )
            )


isAsciiAlphaNum : Char -> Bool
isAsciiAlphaNum c =
    (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')


pAsciiStr : Parser Inlines
pAsciiStr =
    takeWhile1 isAsciiAlphaNum
        |> andThen
            (\t ->
                peekChar
                    |> andThen
                        (\mbc ->
                            case mbc of
                                Just ':' ->
                                    if Set.member t schemeSet then
                                        pUri t

                                    else
                                        return (List.singleton (Str t))

                                _ ->
                                    return (List.singleton (Str t))
                        )
            )


{-| Catch all -- parse an escaped character, an escaped
newline, or any remaining symbol character.
-}
pSym : Parser Inlines
pSym =
    anyChar
        |> andThen
            (\c ->
                let
                    ch : Char -> List Inline
                    ch =
                        String.fromChar >> Str >> List.singleton
                in
                if c == '\\' then
                    oneOf (map ch (satisfy isEscapable))
                        (oneOf (map (\_ -> List.singleton LineBreak) (satisfy ((==) '\n')))
                            (return (ch '\\'))
                        )

                else
                    return (ch c)
            )


{-| <http://www.iana.org/assignments/uri-schemes.html> plus
the unofficial schemes coap, doi, javascript.
-}
schemes : List String
schemes =
    [ -- unofficial
      "coap"
    , "doi"
    , "javascript"

    -- official
    , "aaa"
    , "aaas"
    , "about"
    , "acap"
    , "cap"
    , "cid"
    , "crid"
    , "data"
    , "dav"
    , "dict"
    , "dns"
    , "file"
    , "ftp"
    , "geo"
    , "go"
    , "gopher"
    , "h323"
    , "http"
    , "https"
    , "iax"
    , "icap"
    , "im"
    , "imap"
    , "info"
    , "ipp"
    , "iris"
    , "iris.beep"
    , "iris.xpc"
    , "iris.xpcs"
    , "iris.lwz"
    , "ldap"
    , "mailto"
    , "mid"
    , "msrp"
    , "msrps"
    , "mtqp"
    , "mupdate"
    , "news"
    , "nfs"
    , "ni"
    , "nih"
    , "nntp"
    , "opaquelocktoken"
    , "pop"
    , "pres"
    , "rtsp"
    , "service"
    , "session"
    , "shttp"
    , "sieve"
    , "sip"
    , "sips"
    , "sms"
    , "snmp"
    , "soap.beep"
    , "soap.beeps"
    , "tag"
    , "tel"
    , "telnet"
    , "tftp"
    , "thismessage"
    , "tn3270"
    , "tip"
    , "tv"
    , "urn"
    , "vemmi"
    , "ws"
    , "wss"
    , "xcon"
    , "xcon-userid"
    , "xmlrpc.beep"
    , "xmlrpc.beeps"
    , "xmpp"
    , "z39.50r"
    , "z39.50s"

    -- provisional
    , "adiumxtra"
    , "afp"
    , "afs"
    , "aim"
    , "apt"
    , "attachment"
    , "aw"
    , "beshare"
    , "bitcoin"
    , "bolo"
    , "callto"
    , "chrome"
    , "chrome-extension"
    , "com-eventbrite-attendee"
    , "content"
    , "cvs"
    , "dlna-playsingle"
    , "dlna-playcontainer"
    , "dtn"
    , "dvb"
    , "ed2k"
    , "facetime"
    , "feed"
    , "finger"
    , "fish"
    , "gg"
    , "git"
    , "gizmoproject"
    , "gtalk"
    , "hcp"
    , "icon"
    , "ipn"
    , "irc"
    , "irc6"
    , "ircs"
    , "itms"
    , "jar"
    , "jms"
    , "keyparc"
    , "lastfm"
    , "ldaps"
    , "magnet"
    , "maps"
    , "market"
    , "message"
    , "mms"
    , "ms-help"
    , "msnim"
    , "mumble"
    , "mvn"
    , "notes"
    , "oid"
    , "palm"
    , "paparazzi"
    , "platform"
    , "proxy"
    , "psyc"
    , "query"
    , "res"
    , "resource"
    , "rmi"
    , "rsync"
    , "rtmp"
    , "secondlife"
    , "sftp"
    , "sgn"
    , "skype"
    , "smb"
    , "soldat"
    , "spotify"
    , "ssh"
    , "steam"
    , "svn"
    , "teamspeak"
    , "things"
    , "udp"
    , "unreal"
    , "ut2004"
    , "ventrilo"
    , "view-source"
    , "webcal"
    , "wtai"
    , "wyciwyg"
    , "xfire"
    , "xri"
    , "ymsgr"
    ]


{-| Make them a set for more efficient lookup.
-}
schemeSet : Set String
schemeSet =
    Set.fromList (schemes ++ List.map String.toUpper schemes)


{-| Parse a URI, using heuristics to avoid capturing final punctuation.
-}
pUri : String -> Parser Inlines
pUri scheme =
    char ':'
        |> andThen (\_ -> scan (OpenParens 0) uriScanner)
        |> andThen
            (\x ->
                guard (not (String.isEmpty x))
                    |> andThen
                        (\_ ->
                            let
                                ( rawuri, endingpunct ) =
                                    case String.uncons (String.reverse x) of
                                        Just ( c, _ ) ->
                                            if String.contains (String.fromChar c) ".;?!:," then
                                                ( scheme ++ ":" ++ x, [ Str (String.fromChar c) ] )

                                            else
                                                ( scheme ++ ":" ++ x, [] )

                                        _ ->
                                            ( scheme ++ ":" ++ x, [] )
                            in
                            return (autoLink rawuri ++ endingpunct)
                        )
            )


{-| Scan non-ascii characters and ascii characters allowed in a URI.
We allow punctuation except when followed by a space, since
we don't want the trailing '.' in '<http://google.com.'>
We want to allow
<http://en.wikipedia.org/wiki/State_of_emergency_(disambiguation)>
as a URL, while NOT picking up the closing paren in
(<http://wikipedia.org>)
So we include balanced parens in the URL.
-}
type OpenParens
    = OpenParens Int


uriScanner : OpenParens -> Char -> Maybe OpenParens
uriScanner st c =
    case ( st, c ) of
        ( _, ' ' ) ->
            Nothing

        ( _, '\n' ) ->
            Nothing

        ( OpenParens n, '(' ) ->
            Just (OpenParens (n + 1))

        ( OpenParens n, ')' ) ->
            if n > 0 then
                Just (OpenParens (n - 1))

            else
                Nothing

        ( _, '+' ) ->
            Just st

        ( _, '/' ) ->
            Just st

        _ ->
            if isSpace c then
                Nothing

            else
                Just st


{-| Parses material enclosed in \*s, \*\*s, \_s, or \_\_s.
Designed to avoid backtracking.
-}
pEnclosure : Char -> ReferenceMap -> Parser Inlines
pEnclosure c remap =
    takeWhile1 ((==) c)
        |> andThen
            (\cs ->
                oneOf
                    (pSpace |> map ((::) (Str cs)))
                    (case String.length cs of
                        3 ->
                            pThree c remap

                        2 ->
                            pTwo c remap []

                        1 ->
                            pOne c remap []

                        _ ->
                            return (List.singleton (Str cs))
                    )
            )


{-| singleton sequence or empty if contents are empty
-}
single : (Inlines -> Inline) -> Inlines -> Inlines
single constructor ils =
    if List.isEmpty ils then
        []

    else
        List.singleton (constructor ils)


{-| parse inlines til you hit a c, and emit Emph.
if you never hit a c, emit '\*' + inlines parsed.
-}
pOne : Char -> ReferenceMap -> Inlines -> Parser Inlines
pOne c remap prefix =
    map List.concat
        (many
            (oneOf (nfbChar c |> andThen (\_ -> pInline remap))
                (string (String.fromList [ c, c ])
                    |> andThen (\_ -> nfbChar c)
                    |> andThen (\_ -> pTwo c remap [])
                )
            )
        )
        |> andThen
            (\contents ->
                oneOf (char c |> andThen (\_ -> return (single Emph (prefix ++ contents))))
                    (return (Str (String.fromChar c) :: (prefix ++ contents)))
            )


{-| parse inlines til you hit two c's, and emit Strong.
if you never do hit two c's, emit '\*\*' plus + inlines parsed.
-}
pTwo : Char -> ReferenceMap -> Inlines -> Parser Inlines
pTwo c remap prefix =
    let
        ender : Parser String
        ender =
            string (String.fromList [ c, c ])
    in
    map List.concat (many (nfb ender |> andThen (\_ -> pInline remap)))
        |> andThen
            (\contents ->
                oneOf (ender |> map (\_ -> single Strong (prefix ++ contents)))
                    (return (Str (String.fromList [ c, c ]) :: (prefix ++ contents)))
            )


{-| parse inlines til you hit one c or a sequence of two c's.
If one c, emit Emph and then parse pTwo.
if two c's, emit Strong and then parse pOne.
-}
pThree : Char -> ReferenceMap -> Parser Inlines
pThree c remap =
    map List.concat (many (nfbChar c |> andThen (\_ -> pInline remap)))
        |> andThen
            (\contents ->
                oneOf (string (String.fromList [ c, c ]) |> andThen (\_ -> pOne c remap (single Strong contents)))
                    (oneOf (char c |> andThen (\_ -> pTwo c remap (single Emph contents)))
                        (return (Str (String.fromList [ c, c, c ]) :: contents))
                    )
            )


{-| Inline code span.
-}
pCode : Parser Inlines
pCode =
    map Tuple.first pCode_


{-| this is factored out because it needed in pLinkLabel.
-}
pCode_ : Parser ( Inlines, String )
pCode_ =
    takeWhile1 ((==) '`')
        |> andThen
            (\ticks ->
                let
                    end : Parser ()
                    end =
                        string ticks |> andThen (\_ -> nfb (char '`'))

                    nonBacktickSpan : Parser String
                    nonBacktickSpan =
                        takeWhile1 ((/=) '`')

                    backtickSpan : Parser String
                    backtickSpan =
                        takeWhile1 ((==) '`')
                in
                manyTill (oneOf nonBacktickSpan backtickSpan) end
                    |> map String.concat
                    |> map
                        (\contents ->
                            ( List.singleton (Code (String.trim contents)), ticks ++ contents ++ ticks )
                        )
            )


pLink : ReferenceMap -> Parser Inlines
pLink remap =
    pLinkLabel
        |> andThen
            (\lab ->
                let
                    lab_ : Inlines
                    lab_ =
                        parseInlines remap lab
                in
                oneOf (oneOf (pInlineLink lab_) (pReferenceLink remap lab lab_))
                    -- fallback without backtracking if it's not a link:
                    (return (Str "[" :: lab_ ++ [ Str "]" ]))
            )


{-| An inline link: [label](/url "optional title")
-}
pInlineLink : Inlines -> Parser Inlines
pInlineLink lab =
    char '('
        |> andThen
            (\_ ->
                scanSpaces
                    |> andThen (\_ -> pLinkUrl)
                    |> andThen
                        (\url ->
                            -- tit <- option "" $ scanSpnl *> pLinkTitle <* scanSpaces
                            option "" (scanSpnl |> andThen (\_ -> andThen (\_ -> pLinkTitle) scanSpaces))
                                |> andThen
                                    (\tit ->
                                        char ')'
                                            |> map (\_ -> [ Link lab (Url url) tit ])
                                    )
                        )
            )


{-| A reference link: [label], [foo][label], or [label].
-}
pReferenceLink : ReferenceMap -> String -> Inlines -> Parser Inlines
pReferenceLink _ rawlab lab =
    option rawlab (scanSpnl |> andThen (\_ -> pLinkLabel))
        |> map (\ref -> [ Link lab (Ref ref) "" ])


{-| An image: ! followed by a link.
-}
pImage : ReferenceMap -> Parser Inlines
pImage remap =
    char '!'
        |> andThen
            (\_ ->
                oneOf (map linkToImage (pLink remap)) (return [ Str "!" ])
            )


linkToImage : Inlines -> Inlines
linkToImage ils =
    case ils of
        (Link lab (Url url) tit) :: [] ->
            [ Image lab url tit ]

        _ ->
            Str "!" :: ils


{-| An entity. We store these in a special inline element.
This ensures that entities in the input come out as
entities in the output. Alternatively we could simply
convert them to characters and store them as Str inlines.
-}
pEntity : Parser Inlines
pEntity =
    char '&'
        |> andThen (\_ -> oneOf pCharEntity (oneOf pDecEntity pHexEntity))
        |> andThen
            (\res ->
                char ';'
                    |> andThen (\_ -> return (List.singleton (Entity ("&" ++ res ++ ";"))))
            )


pCharEntity : Parser String
pCharEntity =
    takeWhile1 (\c -> Char.isAlpha c)


pDecEntity : Parser String
pDecEntity =
    char '#'
        |> andThen (\_ -> takeWhile1 Char.isDigit)
        |> andThen (\res -> return ("#" ++ res))


pHexEntity : Parser String
pHexEntity =
    char '#'
        |> andThen (\_ -> oneOf (char 'X') (char 'x'))
        |> andThen
            (\x ->
                takeWhile1 Char.isHexDigit
                    |> andThen
                        (\res ->
                            return ("#" ++ String.fromChar x ++ res)
                        )
            )



-- Raw HTML tag or comment.


pRawHtml : Parser Inlines
pRawHtml =
    map (List.singleton << RawHtml) (oneOf (map Tuple.second pHtmlTag) pHtmlComment)


{-| A link like this: <http://whatever.com> or [me@mydomain.edu](mailto:me@mydomain.edu).
Markdown.pl does email obfuscation; we don't bother with that here.
-}
pAutolink : Parser Inlines
pAutolink =
    skip ((==) '<')
        |> andThen (\_ -> takeWhile1 (\c -> c /= ':' && c /= '@'))
        |> andThen
            (\s ->
                takeWhile1 (\c -> c /= '>' && c /= ' ')
                    |> andThen
                        (\rest ->
                            skip ((==) '>')
                                |> andThen
                                    (\_ ->
                                        if String.startsWith "@" rest then
                                            return (emailLink (s ++ rest))

                                        else if Set.member s schemeSet then
                                            return (autoLink (s ++ rest))

                                        else
                                            fail "Unknown contents of <>"
                                    )
                        )
            )


autoLink : String -> Inlines
autoLink t =
    let
        toInlines : String -> Inlines
        toInlines t_ =
            case parse pToInlines t_ of
                Ok r ->
                    r

                Err e ->
                    ("autolink: " ++ showParseError e) |> crash

        pToInlines : Parser Inlines
        pToInlines =
            map List.concat (many strOrEntity)

        strOrEntity : Parser Inlines
        strOrEntity =
            oneOf (map (List.singleton << Str) (takeWhile1 ((/=) '&')))
                (oneOf pEntity (map (List.singleton << Str) (string "&")))
    in
    Link (toInlines t) (Url t) "" |> List.singleton


emailLink : String -> Inlines
emailLink t =
    [ Link [ Str t ] (Url ("mailto:" ++ t)) "" ]
