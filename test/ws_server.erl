-module(ws_server).

%% A minimal RFC6455 server, just enough to exercise eth_sub end to end:
%% handshake, one masked frame in, unmasked frames out. Not a general
%% purpose implementation — no fragmentation, no payloads over 64 KiB.

-export([start/0]).
-export([start/1]).
-export([stop/1]).
-export([port/1]).
-export([recv/1]).
-export([recv/2]).
-export([send/2]).
-export([drop/1]).

-define(GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).

start() -> start(#{}).

start(Opts) ->
    Owner = self(),
    Pid = spawn(fun() -> listen(Owner, Opts) end),
    receive {ws_server, Pid, {port, Port}} -> {ok, Pid, Port}
    after 5000 -> error(listen_timeout)
    end.

stop(Pid) ->
    Pid ! {self(), stop},
    ok.

port(Pid) ->
    call(Pid, port).

%% @doc Next frame the client sent.
recv(Pid) -> recv(Pid, 5000).

recv(Pid, Timeout) ->
    Pid ! {self(), {recv, Timeout}},
    receive {ws_server, Pid, {frame, Frame}} -> {ok, Frame}
    after Timeout + 1000 -> {error, timeout}
    end.

%% @doc Push a text frame to the client.
send(Pid, Text) ->
    Pid ! {self(), {send, Text}},
    ok.

%% @doc Drop the connection without a close frame, the way a load balancer
%% would.
drop(Pid) ->
    Pid ! {self(), drop},
    ok.

call(Pid, Request) ->
    Pid ! {self(), Request},
    receive {ws_server, Pid, Reply} -> Reply
    after 5000 -> error(timeout)
    end.

%%%===================================================================

listen(Owner, Opts) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {ip, {127, 0, 0, 1}}, {packet, raw}]),
    {ok, Port} = inet:port(Listen),
    Owner ! {ws_server, self(), {port, Port}},
    accept(Owner, Listen, Port, Opts).

accept(Owner, Listen, Port, Opts) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    ok = handshake(Socket),
    case loop(Owner, Socket, <<>>) of
        reconnect ->
            gen_tcp:close(Socket),
            accept(Owner, Listen, Port, Opts);
        stop ->
            gen_tcp:close(Socket),
            gen_tcp:close(Listen)
    end.

handshake(Socket) ->
    Request = read_request(Socket, <<>>),
    Key = header(<<"sec-websocket-key">>, Request),
    Accept = base64:encode(crypto:hash(sha, <<Key/binary, ?GUID/binary>>)),
    gen_tcp:send(Socket, [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Accept: ">>, Accept, <<"\r\n\r\n">>
    ]).

%% Header names are case insensitive, values are not: Sec-WebSocket-Key is
%% base64 and the accept hash is computed over it verbatim.
header(Name, Request) ->
    [Value | _] =
        [string:trim(V)
         || Line <- binary:split(Request, <<"\r\n">>, [global]),
            [N, V] <- [binary:split(Line, <<":">>)],
            string:lowercase(string:trim(N)) =:= Name],
    Value.

read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
            read_request(Socket, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

loop(Owner, Socket, Buffer) ->
    receive
        {From, port} ->
            From ! {ws_server, self(), ok},
            loop(Owner, Socket, Buffer);
        {From, {recv, Timeout}} ->
            {Frame, Rest} = read_frame(Socket, Buffer, Timeout),
            From ! {ws_server, self(), {frame, Frame}},
            loop(Owner, Socket, Rest);
        {_From, {send, Text}} ->
            _ = gen_tcp:send(Socket, frame(Text)),
            loop(Owner, Socket, Buffer);
        {_From, drop} ->
            reconnect;
        {_From, stop} ->
            stop
    end.

%% Server to client frames are never masked.
frame(Payload) when not is_binary(Payload) ->
    frame(iolist_to_binary(Payload));
frame(Payload) when byte_size(Payload) < 126 ->
    <<1:1, 0:3, 1:4, 0:1, (byte_size(Payload)):7, Payload/binary>>;
frame(Payload) ->
    <<1:1, 0:3, 1:4, 0:1, 126:7, (byte_size(Payload)):16, Payload/binary>>.

%% The client going away mid-read is normal here — tests close subscriptions
%% and drop connections on purpose — so it is reported, not raised.
read_frame(Socket, Buffer, Timeout) ->
    case parse_frame(Buffer) of
        {ok, Payload, Rest} ->
            {Payload, Rest};
        more ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, Data}      -> read_frame(Socket, <<Buffer/binary, Data/binary>>, Timeout);
                {error, Reason} -> {{error, Reason}, Buffer}
            end
    end.

parse_frame(<<_Fin:1, _Rsv:3, _Op:4, 1:1, 127:7, Len:64, Mask:4/binary,
              Payload:Len/binary, Rest/binary>>) ->
    {ok, unmask(Payload, Mask), Rest};
parse_frame(<<_Fin:1, _Rsv:3, _Op:4, 1:1, 126:7, Len:16, Mask:4/binary,
              Payload:Len/binary, Rest/binary>>) ->
    {ok, unmask(Payload, Mask), Rest};
parse_frame(<<_Fin:1, _Rsv:3, _Op:4, 1:1, Len:7, Mask:4/binary,
              Payload:Len/binary, Rest/binary>>) when Len < 126 ->
    {ok, unmask(Payload, Mask), Rest};
parse_frame(_Buffer) ->
    more.

unmask(Payload, Mask) ->
    Key = binary:copy(Mask, byte_size(Payload) div 4 + 1),
    <<KeyPart:(byte_size(Payload))/binary, _/binary>> = Key,
    crypto:exor(Payload, KeyPart).
