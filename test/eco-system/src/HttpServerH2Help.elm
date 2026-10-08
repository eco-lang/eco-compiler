module HttpServerH2Help exposing
    ( Answer(..), Config, Tools, program
    , h2Options, curl, curlLines, node, sortedHeaders
    )

{-| Shared helpers for the `Http.Server` HTTP/2 tests (not a test: no `main`; plans/eco-system-
websockets.md §4 WS8).

The program writes the test CA (`TlsFixtures.caPem`) and a Node script (`h2.js`, below) into a
fresh temporary directory, creates the servers of the test with `createServerWith` (https on
127.0.0.1, port 0, `http2 = True`, then the test's changes), subscribes to all of them, and runs the
test's client task, which talks to the servers through peers it spawns with `System.Process.run`:
`curl --http2` (system curl, HTTP/2 through its nghttp2) and `node h2.js <mode> …` (Node's
`http2` client, or raw HTTP/2 frames over `tls` for cases no client library produces). Both are
available on every backend (WF12). When the client task ends, the server's lines (in arrival
order) and then the client's lines are printed, the directory is removed and the program exits.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Http.Server as Server exposing (Request, Server, ServerOptions)
import Http.Server.Response as Response exposing (Response)
import Process
import Socket.Address as Address exposing (Family(..))
import Stream.Log
import System
import System.File as File
import System.File.Path as Path
import System.Process as P
import Task exposing (Task)
import TlsFixtures as Fx


{-| How the server answers a request:

  - `Now`: at once;
  - `After ms`: after a delay;
  - `HoldReverse n`: kept until `n` requests are held, then all are answered, the latest first
    (3 ms apart);
  - `CloseThen ms`: `closeServer` (5 s deadline) at once, the answer after `ms` milliseconds;
  - `NoAnswer`: never.

-}
type Answer
    = Now Response
    | After Int Response
    | HoldReverse Int Response
    | CloseThen Int Response
    | NoAnswer


{-| The temporary directory with `ca.pem` and `h2.js`.
-}
type alias Tools =
    { dir : String }


type alias Config =
    { servers : List (ServerOptions -> ServerOptions)
    , handler : Request -> Response -> ( List String, Answer )
    , client : Tools -> List Server -> Task String (List String)
    }


type Msg
    = Ready (Result String ( Tools, List Server ))
    | GotRequest Request Response
    | SendLater Response
    | ServerClosed
    | ClientDone (Result String (List String))
    | Exit


type alias Model =
    { env : System.Environment
    , tools : Maybe Tools
    , servers : List Server
    , lines : List String
    , held : List Response
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
                ( { env = env, tools = Nothing, servers = [], lines = [], held = [] }
                , setup config |> Task.attempt Ready
                )
        , update = update config
        , subscriptions =
            \model ->
                Sub.batch (List.map (\s -> Server.onRequest s GotRequest) model.servers)
        }


setup : Config -> Task String ( Tools, List Server )
setup config =
    File.makeTempDirectory "eco-h2-test-"
        |> Task.mapError File.errorToString
        |> Task.andThen
            (\dirPath ->
                let
                    dir =
                        Path.toPosixString dirPath
                in
                writeText (dir ++ "/ca.pem") Fx.caPem
                    |> Task.andThen (\_ -> writeText (dir ++ "/h2.js") nodeScript)
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


writeText : String -> String -> Task String ()
writeText path text =
    File.writeFile (Bytes.Encode.encode (Bytes.Encode.string text)) (Path.fromPosixString path)
        |> Task.map (\_ -> ())
        |> Task.mapError File.errorToString


update : Config -> Msg -> Model -> ( Model, Cmd Msg )
update config msg model =
    case msg of
        Ready (Ok ( tools, servers )) ->
            ( { model | tools = Just tools, servers = servers }
            , config.client tools servers |> Task.attempt ClientDone
            )

        Ready (Err e) ->
            finish { model | lines = [ "setup failed: " ++ e ] } []

        GotRequest request response ->
            let
                ( lines, answer ) =
                    config.handler request response

                logged =
                    { model | lines = model.lines ++ List.map (\l -> "server: " ++ l) lines }
            in
            case answer of
                Now reply ->
                    ( logged, Response.send reply )

                After ms reply ->
                    ( logged, Process.sleep (toFloat ms) |> Task.perform (\_ -> SendLater reply) )

                HoldReverse n reply ->
                    let
                        held =
                            reply :: logged.held
                    in
                    if List.length held >= n then
                        -- `held` is newest first: the latest request is answered first, the
                        -- others 3 ms apart (so the order does not depend on how either backend
                        -- schedules the frames of answers given at the same time).
                        ( { logged | held = [], lines = logged.lines ++ [ "server: " ++ String.fromInt n ++ " held, answering the latest first" ] }
                        , Cmd.batch
                            (List.indexedMap
                                (\i r -> Process.sleep (toFloat (3 * i)) |> Task.perform (\_ -> SendLater r))
                                held
                            )
                        )

                    else
                        ( { logged | held = held }, Cmd.none )

                CloseThen ms reply ->
                    ( logged
                    , Cmd.batch
                        ((Process.sleep (toFloat ms) |> Task.perform (\_ -> SendLater reply))
                            :: List.map (\s -> Server.closeServer s |> Task.perform (\_ -> ServerClosed)) logged.servers
                        )
                    )

                NoAnswer ->
                    ( logged, Cmd.none )

        SendLater reply ->
            ( model, Response.send reply )

        ServerClosed ->
            ( { model | lines = model.lines ++ [ "server: closed" ] }, Cmd.none )

        ClientDone (Ok lines) ->
            finish model lines

        ClientDone (Err e) ->
            finish model [ "client failed: " ++ e ]

        Exit ->
            ( model, System.exit )


finish : Model -> List String -> ( Model, Cmd Msg )
finish model clientLines =
    let
        out =
            Stream.Log.line model.env.stdout
                (String.join "\n" (model.lines ++ List.map (\l -> "client: " ++ l) clientLines))

        cleanup =
            case model.tools of
                Just tools ->
                    File.remove { recursive = True } (Path.fromPosixString tools.dir)
                        |> Task.map (\_ -> ())
                        |> Task.onError (\_ -> Task.succeed ())

                Nothing ->
                    Task.succeed ()
    in
    ( model, out |> Task.andThen (\_ -> cleanup) |> Task.perform (\_ -> Exit) )



-- PEERS


noShell : P.RunOptions
noShell =
    let
        d =
            P.defaultRunOptions
    in
    { d | shell = P.NoShell, runDuration = P.Milliseconds 60000 }


bytesToString : Bytes -> String
bytesToString bytes =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes
        |> Maybe.withDefault "<invalid utf-8>"


run : String -> List String -> Task String String
run program_ args =
    P.run program_ args noShell
        |> Task.map (\r -> bytesToString r.stdout)
        |> Task.mapError
            (\err ->
                case err of
                    P.InitError e ->
                        program_ ++ ": " ++ e.errorCode

                    P.ProgramError e ->
                        program_
                            ++ " exited "
                            ++ String.fromInt e.exitCode
                            ++ ": "
                            ++ String.replace "\n" "|" (bytesToString e.stderr)
                            ++ " stdout: "
                            ++ String.replace "\n" "|" (bytesToString e.stdout)
            )


{-| `curl -sS --http2 --cacert <ca> --resolve localhost:<port>:127.0.0.1 <args> https://localhost:<port><path>`:
its stdout (with `-D -`, the response head then the body).
-}
curl : Tools -> Server -> List String -> String -> Task String String
curl tools server args path =
    let
        port_ =
            String.fromInt (Server.serverPort server)
    in
    P.run "curl"
        ([ "-sS", "--max-time", "30", "--cacert", tools.dir ++ "/ca.pem", "--resolve", "localhost:" ++ port_ ++ ":127.0.0.1" ]
            ++ args
            ++ [ "https://localhost:" ++ port_ ++ path ]
        )
        noShell
        |> Task.map (\r -> bytesToString r.stdout)
        |> Task.onError
            (\err ->
                case err of
                    -- curl 7.88 reports a RST_STREAM(NO_ERROR) that follows a complete response
                    -- (the server's answer before the end of an upload, RFC 9113 §8.1) as error
                    -- 92; whether it comes depends on timing. The response itself was written.
                    P.ProgramError e ->
                        if e.exitCode == 92 && Bytes.width e.stdout > 0 then
                            Task.succeed (bytesToString e.stdout)

                        else
                            Task.fail ("curl exited " ++ String.fromInt e.exitCode ++ ": " ++ String.replace "\n" "|" (bytesToString e.stderr))

                    P.InitError e ->
                        Task.fail ("curl: " ++ e.errorCode)
            )


{-| `curl` with `-D -`: the status line, the header lines except `date` (sorted, `name: value`,
joined with ", ") and the body, as one line: `HTTP/2 200 | content-length: 2, x-a: 1 | ok`.
-}
curlLines : Tools -> Server -> List String -> String -> Task String String
curlLines tools server args path =
    curl tools server
        (if List.member "-I" args then
            args

         else
            "-D" :: "-" :: args
        )
        path
        |> Task.map describeResponse


describeResponse : String -> String
describeResponse text =
    let
        normalized =
            String.replace "\u{000D}" "" text

        ( head, body ) =
            case String.indexes "\n\n" normalized of
                i :: _ ->
                    ( String.left i normalized, String.dropLeft (i + 2) normalized )

                [] ->
                    ( normalized, "" )
    in
    case String.lines head of
        status :: headers ->
            String.trim status ++ " | " ++ sortedHeaders headers ++ " | " ++ body

        [] ->
            "no response"


{-| Header lines without `date`, names lower-cased, sorted, joined with ", ".
-}
sortedHeaders : List String -> String
sortedHeaders headers =
    headers
        |> List.map String.trim
        |> List.map
            (\h ->
                case String.indexes ":" h of
                    i :: _ ->
                        String.toLower (String.left i h) ++ String.dropLeft i h

                    [] ->
                        h
            )
        |> List.filter (\h -> h /= "" && not (String.startsWith "date:" h))
        |> List.sort
        |> String.join ", "


{-| `node h2.js <mode> <port> <ca> <args>`: its stdout lines.
-}
node : Tools -> Server -> String -> List String -> Task String (List String)
node tools server mode args =
    run "node" ([ tools.dir ++ "/h2.js", mode, String.fromInt (Server.serverPort server), tools.dir ++ "/ca.pem" ] ++ args)
        |> Task.map (String.lines >> List.filter (\l -> l /= ""))


{-| The Node peer. Modes:

  - `concurrency <n>`: one `http2` session, `n` GETs of `/c/<i>` at once; prints how many ended
    with body `c<i>`, and whether the first to end was among the last tenth of the requests and
    the last among the first tenth.
  - `close`: GET `/slow` (the server closes itself and answers later); prints the GOAWAY code, the
    outcome of a request attempted after it, the answer, and the end of the session.
  - `rapid-reset <n>`: raw frames: `n` times HEADERS (END_STREAM) + RST_STREAM(CANCEL), in one
    write; prints the server's GOAWAY code and the end of the connection.
  - `limit <n>`: raw frames: prints the server's MAX_CONCURRENT_STREAMS, sends `n` GETs `/c<i>`
    at once and reports whether the last one was served concurrently with the first `n - 1`
    (answered before any of them was) or not (refused, or answered only after one of them).
  - `big-header <n>`: raw frames: one GET with an `x-big` field of `n` bytes, sent without
    waiting for the server's SETTINGS; prints the response status (or the reset code).
  - `connect <protocol>`: an extended CONNECT (`:protocol`) to `/ws` after the server's SETTINGS;
    prints ENABLE_CONNECT_PROTOCOL, the response status, and how the stream ended.

No backslash appears in the script (Elm string escapes).

-}
nodeScript : String
nodeScript =
    """'use strict';
const tls = require('tls'), http2 = require('http2'), fs = require('fs');
const [mode, portS, caPath, argS] = process.argv.slice(2);
const port = Number(portS), ca = fs.readFileSync(caPath);
const out = (s) => console.log(s);
const names = { 0: 'NO_ERROR', 1: 'PROTOCOL_ERROR', 2: 'INTERNAL_ERROR', 7: 'REFUSED_STREAM', 8: 'CANCEL', 11: 'ENHANCE_YOUR_CALM' };
const codeName = (c) => names[c] || String(c);
setTimeout(() => { out('timeout'); process.exit(0); }, 40000).unref();

function int7(n) {
  if (n < 127) return Buffer.from([n]);
  const a = [127]; n -= 127;
  while (n >= 128) { a.push((n % 128) + 128); n = Math.floor(n / 128); }
  a.push(n); return Buffer.from(a);
}
function str(s) { const b = Buffer.from(s, 'latin1'); return Buffer.concat([int7(b.length), b]); }
function hpack(h) { return Buffer.concat(h.map(([n, v]) => Buffer.concat([Buffer.from([0]), str(n), str(v)]))); }
function frame(type, flags, sid, payload) {
  const h = Buffer.alloc(9); h.writeUIntBE(payload.length, 0, 3); h[3] = type; h[4] = flags; h.writeUInt32BE(sid, 5);
  return Buffer.concat([h, payload]);
}
const PREFACE = Buffer.from('505249202a20485454502f322e300d0a0d0a534d0d0a0d0a', 'hex');
function get(sid, path) {
  return frame(1, 5, sid, hpack([[':method', 'GET'], [':scheme', 'https'], [':authority', 'localhost'], [':path', path]]));
}
function rst(sid, code) { const e = Buffer.alloc(4); e.writeUInt32BE(code); return frame(3, 0, sid, e); }
// The :status of the first response HEADERS of a connection (both servers send it first: a
// static-table index, or a literal with the :status name and a plain or Huffman-coded value;
// Huffman codes of the digits only, RFC 7541 Appendix B).
function firstStatus(p) {
  const table = { 8: '200', 9: '204', 10: '206', 11: '304', 12: '400', 13: '404', 14: '500' };
  const b = p[0];
  if (b >= 128) return table[b - 128] || 'indexed ' + (b - 128);
  const name = b >= 64 ? b - 64 : b % 16;
  if (name < 8 || name > 14) return 'unexpected ' + b;
  const huff = p[1] >= 128, len = p[1] % 128, v = p.subarray(2, 2 + len);
  if (!huff) return v.toString('latin1');
  const codes = { '00000': '0', '00001': '1', '00010': '2', '011001': '3', '011010': '4', '011011': '5', '011100': '6', '011101': '7', '011110': '8', '011111': '9' };
  let bits = '', outS = '';
  for (const x of v) bits += x.toString(2).padStart(8, '0');
  let cur = '';
  for (const c of bits) { cur += c; if (codes[cur] !== undefined) { outS += codes[cur]; cur = ''; } }
  return outS;
}
function raw(onOpen, onFrame) {
  const sock = tls.connect({ host: '127.0.0.1', port, servername: 'localhost', ca, ALPNProtocols: ['h2'] }, () => {
    sock.write(Buffer.concat([PREFACE, frame(4, 0, 0, Buffer.alloc(0))]));
    onOpen(sock);
  });
  let buf = Buffer.alloc(0);
  sock.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 9) {
      const len = buf.readUIntBE(0, 3);
      if (buf.length < 9 + len) break;
      const f = { type: buf[3], flags: buf[4], sid: buf.readUInt32BE(5) % 2147483648, p: buf.subarray(9, 9 + len) };
      buf = buf.subarray(9 + len);
      if (f.type === 4 && (f.flags % 2) === 0) sock.write(frame(4, 1, 0, Buffer.alloc(0)));
      onFrame(sock, f);
    }
  });
  sock.on('error', () => {});
  return sock;
}
function connect() {
  return http2.connect('https://localhost:' + port, {
    createConnection: () => tls.connect({ host: '127.0.0.1', port, servername: 'localhost', ca, ALPNProtocols: ['h2'] })
  });
}

if (mode === 'concurrency') {
  const n = Number(argS || 100);
  const session = connect();
  session.on('error', (e) => out('session error ' + e.code));
  const order = []; let ok = 0;
  for (let i = 0; i < n; i++) {
    const r = session.request({ ':path': '/c/' + i });
    let body = '';
    r.setEncoding('utf8');
    r.on('data', (d) => { body += d; });
    r.on('error', (e) => out('stream error ' + e.code));
    r.on('end', () => {
      order.push(i);
      if (body === 'c' + i) ok++;
      if (order.length === n) {
        out('responses ' + order.length + ', bodies ok ' + ok);
        // Answers go out latest first, a few ms apart; a busy machine may batch neighbours, so
        // only the ends of the order are checked.
        const tenth = Math.max(1, Math.floor(n / 10));
        out('first to end is one of the last requests ' + (order[0] >= n - tenth));
        out('last to end is one of the first requests ' + (order[n - 1] < tenth));
        out('order detail ' + order.slice(0, 5).join(',') + ' ... ' + order.slice(n - 5).join(','));
        session.close(() => process.exit(0));
      }
    });
    r.end();
  }
} else if (mode === 'close') {
  const session = connect();
  session.on('error', (e) => out('session error ' + e.code));
  session.on('goaway', (code) => {
    out('goaway ' + codeName(code));
    try {
      const late = session.request({ ':path': '/late' });
      late.on('error', (e) => out('after goaway: not served (' + e.code + ')'));
      late.on('response', () => out('after goaway: answered'));
      late.end();
    } catch (e) { out('after goaway: not served (' + e.code + ')'); }
  });
  session.on('close', () => { out('session closed'); process.exit(0); });
  const r = session.request({ ':path': '/slow' });
  let status = 0, body = '';
  r.setEncoding('utf8');
  r.on('response', (h) => { status = h[':status']; });
  r.on('data', (d) => { body += d; });
  r.on('error', (e) => out('slow error ' + e.code));
  r.on('end', () => out('slow: ' + status + ' ' + body));
  r.end();
} else if (mode === 'rapid-reset') {
  const n = Number(argS || 1100);
  let goaway = false;
  const sock = raw((s) => {
    const parts = [];
    for (let i = 0; i < n; i++) { const sid = 1 + 2 * i; parts.push(get(sid, '/rr'), rst(sid, 8)); }
    s.write(Buffer.concat(parts));
  }, (s, f) => {
    if (f.type === 7 && !goaway) { goaway = true; out('goaway ' + codeName(f.p.readUInt32BE(4))); }
  });
  sock.on('close', () => { out('closed'); process.exit(0); });
} else if (mode === 'limit') {
  const n = Number(argS || 11);
  const t0 = Date.now(); const res = {};
  let reported = false;
  const sock = raw((s) => {
    const parts = [];
    for (let i = 1; i <= n; i++) parts.push(get(2 * i - 1, '/c' + i));
    s.write(Buffer.concat(parts));
  }, (s, f) => {
    if (f.type === 4 && (f.flags % 2) === 0) {
      for (let i = 0; i + 6 <= f.p.length; i += 6) {
        if (f.p.readUInt16BE(i) === 3) out('max_concurrent_streams ' + f.p.readUInt32BE(i + 2));
      }
    }
    const k = (f.sid + 1) / 2;
    if (f.type === 1 && f.sid > 0 && !res[k]) res[k] = { t: Date.now() - t0, how: 'answered' };
    if (f.type === 3 && !res[k]) res[k] = { t: Date.now() - t0, how: codeName(f.p.readUInt32BE(0)) };
    if (!reported && Object.keys(res).length === n) {
      reported = true;
      let firstAnswer = Infinity, allAnswered = true;
      for (let i = 1; i < n; i++) {
        if (res[i].how !== 'answered') allAnswered = false;
        firstAnswer = Math.min(firstAnswer, res[i].t);
      }
      const last = res[n];
      out('first ' + (n - 1) + ' answered ' + allAnswered);
      const concurrent = last.how === 'answered' && last.t < firstAnswer;
      out('last served concurrently ' + concurrent);
      out('detail last ' + last.how + ' at ' + last.t + ' ms, first answer at ' + firstAnswer + ' ms');
      s.end();
      process.exit(0);
    }
  });
} else if (mode === 'big-header') {
  // A header list larger than the server's MAX_HEADER_LIST_SIZE, sent at once without waiting for
  // its SETTINGS (curl and Node's client may refuse to send it, depending on timing).
  const n = Number(argS || 3000);
  raw((s) => {
    s.write(frame(1, 5, 1, hpack([[':method', 'GET'], [':scheme', 'https'], [':authority', 'localhost'], [':path', '/big'], ['x-big', 'a'.repeat(n)]])));
  }, (s, f) => {
    if (f.type === 1 && f.sid === 1) { out('status ' + firstStatus(f.p)); s.end(); process.exit(0); }
    if (f.type === 3 && f.sid === 1) { out('reset ' + codeName(f.p.readUInt32BE(0))); s.end(); process.exit(0); }
  });
} else if (mode === 'connect') {
  const session = connect();
  session.on('error', (e) => out('session error ' + e.code));
  session.on('remoteSettings', (settings) => {
    out('enableConnectProtocol ' + settings.enableConnectProtocol);
    const r = session.request({ ':method': 'CONNECT', ':protocol': argS || 'websocket', ':scheme': 'https', ':path': '/ws', ':authority': 'localhost:' + port, 'sec-websocket-version': '13' });
    let status = 0;
    r.on('response', (h) => { status = h[':status']; out('status ' + status); });
    r.on('data', () => {});
    r.on('error', (e) => out('stream error ' + e.code));
    r.on('close', () => { out('stream closed ' + codeName(r.rstCode)); session.close(() => process.exit(0)); });
  });
} else {
  out('unknown mode ' + mode);
}
"""
