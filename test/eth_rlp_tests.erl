-module(eth_rlp_tests).

-include_lib("eunit/include/eunit.hrl").

%% Vectors from the RLP specification.

strings_test() ->
    ?assertEqual(<<16#83, "dog">>, eth_rlp:encode(<<"dog">>)),
    ?assertEqual(<<16#80>>, eth_rlp:encode(<<>>)),
    ?assertEqual(<<"a">>, eth_rlp:encode(<<"a">>)),
    ?assertEqual(<<16#00>>, eth_rlp:encode(<<0>>)),
    ?assertEqual(<<16#81, 16#80>>, eth_rlp:encode(<<16#80>>)).

long_string_test() ->
    Long = <<"Lorem ipsum dolor sit amet, consectetur adipisicing elit">>,
    ?assertEqual(56, byte_size(Long)),
    ?assertEqual(<<16#b8, 56, Long/binary>>, eth_rlp:encode(Long)).

lists_test() ->
    ?assertEqual(<<16#c0>>, eth_rlp:encode([])),
    ?assertEqual(
        <<16#c8, 16#83, "cat", 16#83, "dog">>,
        eth_rlp:encode([<<"cat">>, <<"dog">>])
    ),
    %% the "set theory" vector
    ?assertEqual(
        <<16#c7, 16#c0, 16#c1, 16#c0, 16#c3, 16#c0, 16#c1, 16#c0>>,
        eth_rlp:encode([[], [[]], [[], [[]]]])
    ).

%% Integers encode as their minimal big-endian byte string. Note that 0 and
%% <<0>> are different values: 0 is the empty string, <<0>> is one zero byte.
integers_test() ->
    ?assertEqual(<<16#80>>, eth_rlp:encode(0)),
    ?assertEqual(<<16#0f>>, eth_rlp:encode(15)),
    ?assertEqual(<<16#82, 16#04, 16#00>>, eth_rlp:encode(1024)),
    ?assertNotEqual(eth_rlp:encode(0), eth_rlp:encode(<<0>>)).

long_list_test() ->
    Item = <<"aaaaaaaaaa">>,
    List = lists:duplicate(10, Item),
    %% 10 items, each 11 bytes encoded = 110 byte payload, needs the long form
    ?assertEqual(<<16#f8, 110, (iolist_to_binary([<<16#8a, Item/binary>> || _ <- List]))/binary>>,
                 eth_rlp:encode(List)).
