-module(eth_sub_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SUB_ID, <<"0xcd0c3e8af590364c09d0fa6a1210faf5">>).

setup() ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, Server, Port} = ws_server:start(),
    {Server, url(Port)}.

cleanup({Server, _Url}) ->
    ws_server:stop(Server).

url(Port) ->
    iolist_to_binary(["ws://127.0.0.1:", integer_to_list(Port), "/"]).

eth_sub_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun subscribe_request/1,
        fun delivers_events/1,
        fun reconnects_and_resubscribes/1,
        fun ignores_unrelated_messages/1
    ]}.

%% The subscription request must be a well formed eth_subscribe carrying the
%% caller's params verbatim.
subscribe_request({Server, Url}) ->
    fun() ->
        Filter = #{address => <<"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913">>,
                   topics => [eth_abi:transfer_topic()]},
        {ok, Sub} = eth_sub:logs(Url, Filter),
        {ok, Frame} = ws_server:recv(Server),
        ?assertMatch(
            #{<<"jsonrpc">> := <<"2.0">>,
              <<"method">> := <<"eth_subscribe">>,
              <<"params">> := [<<"logs">>, #{<<"address">> := _, <<"topics">> := [_]}]},
            json:decode(Frame)
        ),
        eth_sub:stop(Sub)
    end.

%% Happy path: subscribe reply, then a notification.
delivers_events({Server, Url}) ->
    fun() ->
        {ok, Sub} = eth_sub:new_heads(Url),
        {ok, _Request} = ws_server:recv(Server),

        ws_server:send(Server, subscribe_reply()),
        ?assertEqual({subscribed, ?SUB_ID}, next(Sub)),
        ?assertEqual(?SUB_ID, eth_sub:subscription_id(Sub)),

        ws_server:send(Server, notification(#{<<"number">> => <<"0x2a">>})),
        ?assertEqual({event, #{<<"number">> => <<"0x2a">>}}, next(Sub)),

        eth_sub:stop(Sub)
    end.

%% A dropped connection must produce {down, _} and then a fresh subscription,
%% because that second {subscribed, _} is what tells the owner to backfill the
%% gap.
reconnects_and_resubscribes({Server, Url}) ->
    fun() ->
        {ok, Sub} = eth_sub:new_heads(Url, #{reconnect_delay => 50}),
        {ok, _} = ws_server:recv(Server),
        ws_server:send(Server, subscribe_reply()),
        ?assertEqual({subscribed, ?SUB_ID}, next(Sub)),

        ws_server:drop(Server),
        ?assertMatch({down, _}, next(Sub)),
        ?assertEqual(undefined, eth_sub:subscription_id(Sub)),

        {ok, _} = ws_server:recv(Server, 5000),
        ws_server:send(Server, subscribe_reply()),
        ?assertEqual({subscribed, ?SUB_ID}, next(Sub)),

        eth_sub:stop(Sub)
    end.

%% Anything that is neither a notification nor the subscribe reply must be
%% dropped rather than crash the subscription.
ignores_unrelated_messages({Server, Url}) ->
    fun() ->
        {ok, Sub} = eth_sub:new_heads(Url),
        {ok, _} = ws_server:recv(Server),
        ws_server:send(Server, subscribe_reply()),
        ?assertEqual({subscribed, ?SUB_ID}, next(Sub)),

        ws_server:send(Server, <<"not json at all">>),
        ws_server:send(Server, json:encode(#{jsonrpc => <<"2.0">>, id => 99, result => true})),
        ws_server:send(Server, notification(#{<<"number">> => <<"0x2b">>})),

        ?assertEqual({event, #{<<"number">> => <<"0x2b">>}}, next(Sub)),
        ?assert(is_process_alive(Sub)),

        eth_sub:stop(Sub)
    end.

subscribe_reply() ->
    json:encode(#{jsonrpc => <<"2.0">>, id => 1, result => ?SUB_ID}).

notification(Result) ->
    json:encode(#{
        jsonrpc => <<"2.0">>,
        method  => <<"eth_subscription">>,
        params  => #{subscription => ?SUB_ID, result => Result}
    }).

next(Sub) ->
    receive {eth_sub, Sub, Message} -> Message
    after 5000 -> error(timeout)
    end.
