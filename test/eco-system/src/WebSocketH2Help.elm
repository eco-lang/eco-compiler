module WebSocketH2Help exposing
    ( Config, Tools, program
    , h2Options, node, wssConnect, echoCase, largeCase, writeFile
    )

{-| Shared helpers for the WebSocket-over-HTTP/2 tests (RFC 8441; not a test: no `main`;
plans/eco-system-websockets.md §3.9, §4 WS9).

The program writes the test CA, the test server certificate and key, and a Node script (`ws.js`,
below) into a fresh temporary directory, creates the servers of the test with `createServerWith`
(https on 127.0.0.1, port 0, `http2 = True`, then the test's changes), subscribes to all of them,
and runs the test's client task.

Every server upgrades a request whose `upgrade` is `Just "websocket"` with
`Http.Server.upgradeRequest` and then, by path:

  - `/reject`: `WebSocket.reject 403` with a body;
  - `/quiet`: accepts with a 200 ms / 200 ms heartbeat and reads until the end;
  - `/many/<i>`: accepts and echoes (counted, not logged one by one);
  - anything else: accepts (with the protocol `chat` when the client offers it) and echoes until
    the end.

Other requests are answered `plain <path>`. When the client task is done and every server task has
ended (at most 10 s later), the server's lines (sorted: they come from concurrent streams) and
then the client's lines are printed, the directory is removed and the program exits.

-}

import Bytes
import Bytes.Encode
import Http.Server as Server exposing (HttpVersion(..), Request, Server, ServerOptions)
import Http.Server.Response as Response exposing (Response)
import Process
import Socket
import Socket.Address as Address exposing (Family(..))
import Socket.Tls
import Stream.Log
import System
import System.File as File
import System.File.Path as Path
import System.Process as P
import Task exposing (Task)
import TlsFixtures as Fx
import WebSocket
import WebSocketTestHelp as W


{-| The temporary directory with `ca.pem`, `cert.pem`, `key.pem` and `ws.js`.
-}
type alias Tools =
    { dir : String }


type alias Config =
    { servers : List (ServerOptions -> ServerOptions)
    , client : Tools -> List Server -> Task String (List String)
    }


type Msg
    = Ready (Result String ( Tools, List Server ))
    | GotRequest Request Response
    | ServerDone (List String)
    | ClientDone (Result String (List String))
    | GiveUp
    | Exit


type alias Model =
    { env : System.Environment
    , tools : Maybe Tools
    , servers : List Server
    , lines : List String
    , running : Int
    , manyDone : Int
    , manyClean : Int
    , client : Maybe (List String)
    , finished : Bool
    }


{-| `defaultServerOptions` on 127.0.0.1, port 0, with the test certificate and `http2 = True`.
-}
h2Options : ServerOptions
h2Options =
    let
        d =
            Server.defaultServerOptions (Address.loopback IPv4) 0
    in
    { d
        | tls = Just { certificateChain = Fx.serverCertPem, privateKey = Fx.serverKeyPem, alpn = [] }
        , http2 = True
    }


program : Config -> System.Program Model Msg
program config =
    System.defineProgram
        { init =
            \env ->
                ( { env = env
                  , tools = Nothing
                  , servers = []
                  , lines = []
                  , running = 0
                  , manyDone = 0
                  , manyClean = 0
                  , client = Nothing
                  , finished = False
                  }
                , setup config |> Task.attempt Ready
                )
        , update = update config
        , subscriptions =
            \model ->
                Sub.batch (List.map (\s -> Server.onRequest s GotRequest) model.servers)
        }


setup : Config -> Task String ( Tools, List Server )
setup config =
    File.makeTempDirectory "eco-ws-h2-test-"
        |> Task.mapError File.errorToString
        |> Task.andThen
            (\dirPath ->
                let
                    dir =
                        Path.toPosixString dirPath
                in
                writeFile (dir ++ "/ca.pem") Fx.caPem
                    |> Task.andThen (\_ -> writeFile (dir ++ "/cert.pem") Fx.serverCertPem)
                    |> Task.andThen (\_ -> writeFile (dir ++ "/key.pem") Fx.serverKeyPem)
                    |> Task.andThen (\_ -> writeFile (dir ++ "/ws.js") nodeScript)
                    |> Task.andThen
                        (\_ ->
                            config.servers
                                |> List.map
                                    (\change ->
                                        Server.createServerWith (change h2Options)
                                            |> Task.mapError (\(Server.ServerError e) -> "server error: " ++ e.code ++ " " ++ e.message)
                                    )
                                |> Task.sequence
                        )
                    |> Task.map (\servers -> ( { dir = dir }, servers ))
            )


writeFile : String -> String -> Task String ()
writeFile path text =
    File.writeFile (Bytes.Encode.encode (Bytes.Encode.string text)) (Path.fromPosixString path)
        |> Task.map (\_ -> ())
        |> Task.mapError File.errorToString


versionString : HttpVersion -> String
versionString v =
    case v of
        Http1_0 ->
            "Http1_0"

        Http1_1 ->
            "Http1_1"

        Http2 ->
            "Http2"


isMany : String -> Bool
isMany path =
    String.startsWith "/many/" path


serve : String -> WebSocket.Upgrade -> Task String (List String)
serve path up =
    if path == "/reject" then
        WebSocket.reject 403 [ ( "x-reason", "test" ) ] "forbidden" up
            |> Task.map (\_ -> [ "rejected /reject" ])

    else if path == "/quiet" then
        let
            d =
                WebSocket.defaultAcceptOptions
        in
        WebSocket.accept { d | heartbeat = Just { interval = 200, timeout = 200 } } up
            |> Task.mapError W.wsErr
            |> Task.andThen
                (\ws ->
                    W.readAll ws
                        |> Task.andThen (\_ -> WebSocket.closed ws)
                        |> Task.map (\info -> [ "ws /quiet: " ++ W.closeInfoString info ])
                )

    else
        let
            d =
                WebSocket.defaultAcceptOptions

            protocol =
                if List.member "chat" (WebSocket.upgradeProtocols up) then
                    Just "chat"

                else
                    Nothing
        in
        WebSocket.accept { d | protocol = protocol } up
            |> Task.mapError W.wsErr
            |> Task.andThen
                (\ws ->
                    W.echo ws
                        |> Task.andThen
                            (\end ->
                                WebSocket.closed ws
                                    |> Task.map
                                        (\info ->
                                            if isMany path then
                                                [ "many " ++ (if info.clean && info.code == WebSocket.Normal then "clean" else "unclean " ++ end) ]

                                            else
                                                [ "ws " ++ path ++ ": " ++ end ++ " | " ++ W.closeInfoString info ]
                                        )
                            )
                )


update : Config -> Msg -> Model -> ( Model, Cmd Msg )
update config msg model =
    case msg of
        Ready (Ok ( tools, servers )) ->
            ( { model | tools = Just tools, servers = servers }
            , config.client tools servers |> Task.attempt ClientDone
            )

        Ready (Err e) ->
            finish { model | lines = [ "setup failed: " ++ e ], client = Just [] }

        GotRequest request response ->
            let
                path =
                    request.url.path
            in
            if request.upgrade == Just "websocket" then
                ( { model
                    | running = model.running + 1
                    , lines =
                        if isMany path then
                            model.lines

                        else
                            model.lines ++ [ "upgrade " ++ path ++ " " ++ versionString request.version ]
                  }
                , Server.upgradeRequest request response
                    |> Task.mapError W.wsErr
                    |> Task.andThen (serve path)
                    |> Task.onError (\e -> Task.succeed [ "ws " ++ path ++ ": failed " ++ e ])
                    |> Task.perform ServerDone
                )

            else
                ( model, response |> Response.setBody ("plain " ++ path) |> Response.send )

        ServerDone lines ->
            let
                many =
                    List.filter (String.startsWith "many ") lines

                others =
                    List.filter (not << String.startsWith "many ") lines

                next =
                    { model
                        | running = model.running - 1
                        , lines = model.lines ++ others
                        , manyDone = model.manyDone + List.length many
                        , manyClean = model.manyClean + List.length (List.filter ((==) "many clean") many)
                    }
            in
            maybeFinish next

        ClientDone result ->
            let
                lines =
                    case result of
                        Ok ls ->
                            ls

                        Err e ->
                            [ "client failed: " ++ e ]
            in
            maybeFinish { model | client = Just lines }
                |> Tuple.mapSecond (\cmd -> Cmd.batch [ cmd, Process.sleep 10000 |> Task.perform (\_ -> GiveUp) ])

        GiveUp ->
            if model.finished then
                ( model, Cmd.none )

            else
                finish { model | lines = model.lines ++ [ "still running " ++ String.fromInt model.running ] }

        Exit ->
            ( model, System.exit )


maybeFinish : Model -> ( Model, Cmd Msg )
maybeFinish model =
    if model.client /= Nothing && model.running <= 0 && not model.finished then
        finish model

    else
        ( model, Cmd.none )


finish : Model -> ( Model, Cmd Msg )
finish model =
    let
        manyLine =
            if model.manyDone > 0 then
                [ "many: " ++ String.fromInt model.manyDone ++ " done, " ++ String.fromInt model.manyClean ++ " clean" ]

            else
                []

        serverLines =
            List.map (\l -> "server: " ++ l) (List.sort model.lines ++ manyLine)

        clientLines =
            List.map (\l -> "client: " ++ l) (Maybe.withDefault [] model.client)

        out =
            Stream.Log.line model.env.stdout (String.join "\n" (serverLines ++ clientLines))

        cleanup =
            case model.tools of
                Just tools ->
                    File.remove { recursive = True } (Path.fromPosixString tools.dir)
                        |> Task.map (\_ -> ())
                        |> Task.onError (\_ -> Task.succeed ())

                Nothing ->
                    Task.succeed ()
    in
    ( { model | finished = True }, out |> Task.andThen (\_ -> cleanup) |> Task.perform (\_ -> Exit) )



-- CLIENTS


{-| `WebSocket.connect` to `wss://localhost:<port><path>` with the test CA and `http2`.
-}
wssConnect : Bool -> Int -> String -> Task String (WebSocket.WebSocket WebSocket.Whole)
wssConnect http2 port_ path =
    let
        d =
            WebSocket.defaultConnectOptions ("wss://localhost:" ++ String.fromInt port_ ++ path)
    in
    WebSocket.connect
        { d
            | verification = Socket.Tls.TrustedCertificates Fx.caPem
            , http2 = http2
            , protocols = [ "chat" ]
            , timeout = Just 10000
        }
        |> Task.mapError (\e -> "connect " ++ Socket.errorToString e)


{-| Connect, send a text and a binary message, read their echoes, close (Normal), and wait for
the close: `label: Text "hello" | Binary [1,2,3] | protocol chat | Normal "" clean True`.
-}
echoCase : String -> Bool -> Int -> String -> Task x String
echoCase label http2 port_ path =
    wssConnect http2 port_ path
        |> Task.andThen
            (\ws ->
                W.sendAll [ W.text "hello", W.binary [ 1, 2, 3 ] ] ws
                    |> Task.andThen (\_ -> W.readMessages 2 ws)
                    |> Task.andThen
                        (\messages ->
                            WebSocket.close WebSocket.Normal "" ws
                                |> Task.mapError W.wsErr
                                |> Task.andThen (\_ -> WebSocket.closed ws)
                                |> Task.map
                                    (\info ->
                                        String.join " | "
                                            (List.map W.messageString messages
                                                ++ [ "protocol " ++ Maybe.withDefault "none" (WebSocket.protocol ws)
                                                   , W.closeInfoString info
                                                   ]
                                            )
                                    )
                        )
            )
        |> Task.onError (\e -> Task.succeed ("failed " ++ e))
        |> Task.map (\r -> label ++ ": " ++ r)



{-| `n` doublings of the bytes 1, 2, 3, 4 (`4 * 2 ^ n` bytes).
-}
bigBytes : Int -> Bytes.Bytes
bigBytes n =
    List.foldl
        (\_ b -> Bytes.Encode.encode (Bytes.Encode.sequence [ Bytes.Encode.bytes b, Bytes.Encode.bytes b ]))
        (Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 [ 1, 2, 3, 4 ])))
        (List.range 1 n)


{-| Flow control and write backpressure on both sides: a 4 MiB binary message and 64 KiB text
messages sent at once, echoed, then a clean close: `label: 4194304 bytes back, 8 texts back |
Normal "" clean True`.
-}
largeCase : String -> Bool -> Int -> String -> Task x String
largeCase label http2 port_ path =
    let
        big =
            bigBytes 20

        texts =
            List.repeat 8 (W.text (String.repeat 65536 "t"))
    in
    wssConnect http2 port_ path
        |> Task.andThen
            (\ws ->
                W.sendAll (WebSocket.Binary big :: texts) ws
                    |> Task.andThen (\_ -> W.readMessages 9 ws)
                    |> Task.andThen
                        (\messages ->
                            let
                                sizes =
                                    List.map
                                        (\m ->
                                            case m of
                                                WebSocket.Binary b ->
                                                    Bytes.width b

                                                WebSocket.Text t ->
                                                    String.length t
                                        )
                                        messages
                            in
                            WebSocket.close WebSocket.Normal "" ws
                                |> Task.mapError W.wsErr
                                |> Task.andThen (\_ -> WebSocket.closed ws)
                                |> Task.map
                                    (\info ->
                                        String.fromInt (List.sum (List.take 1 sizes))
                                            ++ " bytes back, "
                                            ++ String.fromInt (List.length (List.filter ((==) 65536) (List.drop 1 sizes)))
                                            ++ " texts back | "
                                            ++ W.closeInfoString info
                                    )
                        )
            )
        |> Task.onError (\e -> Task.succeed ("failed " ++ e))
        |> Task.map (\r -> label ++ ": " ++ r)



-- PEERS


noShell : P.RunOptions
noShell =
    let
        d =
            P.defaultRunOptions
    in
    { d | shell = P.NoShell, runDuration = P.Milliseconds 60000 }


{-| `node ws.js <mode> <port> <dir> <args>`: its stdout lines.
-}
node : Tools -> Int -> String -> List String -> Task String (List String)
node tools port_ mode args =
    P.run "node" ([ tools.dir ++ "/ws.js", mode, String.fromInt port_, tools.dir ] ++ args) noShell
        |> Task.map (\r -> W.latin1 r.stdout |> String.lines |> List.filter (\l -> l /= ""))
        |> Task.mapError
            (\err ->
                case err of
                    P.InitError e ->
                        "node: " ++ e.errorCode

                    P.ProgramError e ->
                        "node exited "
                            ++ String.fromInt e.exitCode
                            ++ ": "
                            ++ String.replace "\n" "|" (W.latin1 e.stderr)
                            ++ " stdout: "
                            ++ String.replace "\n" "|" (W.latin1 e.stdout)
            )


{-| The Node peer (`node ws.js <mode> <port> <dir> [args]`; `<dir>` holds `ca.pem`, `cert.pem`,
`key.pem`). Client modes use one `http2` session to 127.0.0.1 (SNI localhost) and wait for the
server's SETTINGS; WebSocket frames are written masked and read unmasked by hand:

  - `echo`: extended CONNECT `/echo` offering `chat`; prints the status and the chosen protocol;
    sends a text and a binary message, prints their echoes, then Close 1000 "bye"; prints the
    server's Close, its END_STREAM (then ends its own side), and how the stream closed.
  - `quiet`: extended CONNECT `/quiet`; answers nothing (no pong): prints the server's ping,
    Close, END_STREAM and how the stream closed (the client never ends its side).
  - `reset`: extended CONNECT `/reset`; after the echo of one message resets the stream (CANCEL).
  - `reject`: extended CONNECT `/reject`; prints the status, a header and the body.
  - `unknown`: extended CONNECT with `:protocol chat`; prints the status.
  - `many <n> <m>`: `n` WebSockets (`/many/<i>`) and `m` GETs (`/plain/<j>`) at once on the one
    session: every WebSocket sends `m<i>`, expects its echo and closes; prints the totals.
  - `noecp-server`: an HTTP/2 server (`allowHTTP1`) on 127.0.0.1:<port> WITHOUT
    `enableConnectProtocol`: logs h2 sessions and the client's GOAWAY; answers an HTTP/1.1
    WebSocket upgrade by hand (101, then a text frame `via http/1.1`), echoes the client's Close
    and exits when the connection closes.

No backslash appears in the script (Elm string escapes).

-}
nodeScript : String
nodeScript =
    """'use strict';
const tls = require('tls'), http2 = require('http2'), fs = require('fs'), crypto = require('crypto');
const [mode, portS, dir, argA, argB] = process.argv.slice(2);
const port = Number(portS), ca = fs.readFileSync(dir + '/ca.pem');
const out = (s) => console.log(s);
const names = { 0: 'NO_ERROR', 1: 'PROTOCOL_ERROR', 2: 'INTERNAL_ERROR', 7: 'REFUSED_STREAM', 8: 'CANCEL' };
const codeName = (c) => names[c] || String(c);
const CRLF = String.fromCharCode(13, 10);
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
setTimeout(() => { out('timeout'); process.exit(0); }, 40000).unref();

function frame(op, payload, masked) {
  const len = payload.length;
  let head;
  if (len < 126) head = Buffer.from([128 + op, (masked ? 128 : 0) + len]);
  else if (len < 65536) { head = Buffer.alloc(4); head[0] = 128 + op; head[1] = (masked ? 128 : 0) + 126; head.writeUInt16BE(len, 2); }
  else { head = Buffer.alloc(10); head[0] = 128 + op; head[1] = (masked ? 128 : 0) + 127; head.writeBigUInt64BE(BigInt(len), 2); }
  if (!masked) return Buffer.concat([head, payload]);
  const key = crypto.randomBytes(4), body = Buffer.alloc(len);
  for (let i = 0; i < len; i++) body[i] = payload[i] ^ key[i % 4];
  return Buffer.concat([head, key, body]);
}
const masked = (op, p) => frame(op, p, true);
function closePayload(code, reason) { const b = Buffer.alloc(2); b.writeUInt16BE(code); return Buffer.concat([b, Buffer.from(reason)]); }
function parser(onFrame) {
  let buf = Buffer.alloc(0);
  return (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      if (buf.length < 2) return;
      const op = buf[0] % 16, isMasked = buf[1] >= 128;
      let len = buf[1] % 128, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      let key = null;
      if (isMasked) { if (buf.length < off + 4) return; key = buf.subarray(off, off + 4); off += 4; }
      if (buf.length < off + len) return;
      const p = Buffer.from(buf.subarray(off, off + len));
      if (key) for (let i = 0; i < p.length; i++) p[i] = p[i] ^ key[i % 4];
      buf = buf.subarray(off + len);
      onFrame(op, p, isMasked);
    }
  };
}
function connect() {
  return http2.connect('https://localhost:' + port, {
    createConnection: () => tls.connect({ host: '127.0.0.1', port, servername: 'localhost', ca, ALPNProtocols: ['h2'] })
  });
}
function wsRequest(session, path, extra) {
  const h = Object.assign({ ':method': 'CONNECT', ':protocol': 'websocket', ':scheme': 'https', ':path': path,
    ':authority': 'localhost:' + port, 'sec-websocket-version': '13' }, extra || {});
  return session.request(h, { endStream: false });
}
function withSettings(f) {
  const session = connect();
  session.on('error', (e) => out('session error ' + e.code));
  let started = false;
  session.on('remoteSettings', (st) => {
    if (started) return;
    started = true;
    out('enableConnectProtocol ' + st.enableConnectProtocol);
    f(session);
  });
  return session;
}
const finish = (session) => session.close(() => process.exit(0));

if (mode === 'echo') {
  withSettings((session) => {
    const r = wsRequest(session, '/echo', { 'sec-websocket-protocol': 'chat, other' });
    r.on('response', (h) => {
      out('status ' + h[':status'] + ' protocol ' + h['sec-websocket-protocol']);
      r.write(masked(1, Buffer.from('hello')));
      r.write(masked(2, Buffer.from([1, 2, 3])));
    });
    r.on('data', parser((op, p, m) => {
      if (m) out('a server frame is masked');
      if (op === 1) out('text ' + p.toString());
      else if (op === 2) { out('binary ' + p.toString('hex')); r.write(masked(8, closePayload(1000, 'bye'))); }
      else if (op === 8) out('close ' + (p.length >= 2 ? p.readUInt16BE(0) : 'empty'));
    }));
    r.on('end', () => { out('server END_STREAM'); r.end(); });
    r.on('error', (e) => out('stream error ' + e.code));
    r.on('close', () => { out('stream closed ' + codeName(r.rstCode)); finish(session); });
  });
} else if (mode === 'quiet') {
  withSettings((session) => {
    const r = wsRequest(session, '/quiet');
    let pinged = false;
    r.on('response', (h) => out('status ' + h[':status']));
    r.on('data', parser((op, p) => {
      if (op === 9 && !pinged) { pinged = true; out('ping (not answered)'); }
      else if (op === 8) out('close ' + (p.length >= 2 ? p.readUInt16BE(0) : 'empty'));
    }));
    r.on('end', () => out('server END_STREAM'));
    r.on('error', (e) => out('stream error ' + e.code));
    r.on('close', () => { out('stream closed ' + codeName(r.rstCode)); finish(session); });
  });
} else if (mode === 'reset') {
  withSettings((session) => {
    const r = wsRequest(session, '/reset');
    r.on('response', (h) => { out('status ' + h[':status']); r.write(masked(1, Buffer.from('one'))); });
    r.on('data', parser((op, p) => {
      if (op === 1) { out('text ' + p.toString()); r.close(http2.constants.NGHTTP2_CANCEL); }
    }));
    r.on('error', (e) => {});
    r.on('close', () => { out('stream closed ' + codeName(r.rstCode)); finish(session); });
  });
} else if (mode === 'reject') {
  withSettings((session) => {
    const r = wsRequest(session, '/reject');
    let body = '';
    r.setEncoding('utf8');
    r.on('response', (h) => out('status ' + h[':status'] + ' x-reason ' + h['x-reason']));
    r.on('data', (d) => { body += d; });
    r.on('end', () => out('body ' + body));
    r.on('error', (e) => {});
    r.on('close', () => { out('stream closed'); finish(session); });
  });
} else if (mode === 'unknown') {
  withSettings((session) => {
    const r = session.request({ ':method': 'CONNECT', ':protocol': 'chat', ':scheme': 'https', ':path': '/chat',
      ':authority': 'localhost:' + port, 'sec-websocket-version': '13' }, { endStream: false });
    r.on('response', (h) => out('status ' + h[':status']));
    r.on('data', () => {});
    r.on('error', (e) => {});
    r.on('close', () => { out('stream closed'); finish(session); });
  });
} else if (mode === 'many') {
  const n = Number(argA || 50), m = Number(argB || 10);
  let wsLeft = n, getLeft = m, echoed = 0, clean = 0, gets = 0;
  let sessionRef = null;
  const done = () => {
    if (wsLeft > 0 || getLeft > 0) return;
    out('websockets ' + n + ', echoed ' + echoed + ', closed cleanly ' + clean);
    out('requests ' + m + ', answered ' + gets);
    finish(sessionRef);
  };
  sessionRef = withSettings((session) => {
    for (let i = 0; i < n; i++) {
      const r = wsRequest(session, '/many/' + i);
      const want = 'm' + i;
      let gotClose = false;
      r.on('response', () => r.write(masked(1, Buffer.from(want))));
      r.on('data', parser((op, p) => {
        if (op === 1 && p.toString() === want) { echoed++; r.write(masked(8, closePayload(1000, ''))); }
        else if (op === 8) gotClose = true;
      }));
      r.on('end', () => r.end());
      r.on('error', () => {});
      r.on('close', () => { if (gotClose && r.rstCode === 0) clean++; wsLeft--; done(); });
    }
    for (let j = 0; j < m; j++) {
      const g = session.request({ ':path': '/plain/' + j });
      let body = '';
      g.setEncoding('utf8');
      g.on('data', (d) => { body += d; });
      g.on('error', () => {});
      g.on('close', () => { if (body === 'plain /plain/' + j) gets++; getLeft--; done(); });
      g.end();
    }
  });
} else if (mode === 'noecp-server') {
  const srv = http2.createSecureServer({ key: fs.readFileSync(dir + '/key.pem'), cert: fs.readFileSync(dir + '/cert.pem'),
    allowHTTP1: true, settings: { enableConnectProtocol: false } });
  srv.on('session', (s) => {
    out('h2 session');
    s.on('goaway', (code) => out('h2 goaway from the client ' + codeName(code)));
    s.on('error', () => {});
  });
  srv.on('stream', (st, h) => { out('unexpected h2 stream ' + h[':method']); st.close(); });
  srv.on('upgrade', (req, sock, head) => {
    out('upgrade HTTP/' + req.httpVersion + ' ' + req.url + ' alpn ' + sock.alpnProtocol);
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + GUID).digest('base64');
    sock.write('HTTP/1.1 101 Switching Protocols' + CRLF + 'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF
      + 'Sec-WebSocket-Accept: ' + accept + CRLF + CRLF);
    sock.write(frame(1, Buffer.from('via http/1.1'), false));
    sock.on('data', parser((op, p, m) => {
      if (op === 8) {
        out('client close ' + (p.length >= 2 ? p.readUInt16BE(0) : 'empty') + ' masked ' + m);
        sock.write(frame(8, p.subarray(0, 2), false));
        sock.end();
      }
    }));
    sock.on('error', () => {});
    sock.on('close', () => { out('upgraded connection closed'); srv.close(); setTimeout(() => process.exit(0), 50); });
  });
  srv.listen(port, '127.0.0.1', () => out('listening'));
} else {
  out('unknown mode ' + mode);
}
"""
