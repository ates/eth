-module(eth_hex_tests).

-include_lib("eunit/include/eunit.hrl").

%% QUANTITY is minimally encoded; DATA keeps every byte. Encoding a block
%% number as DATA or an address as QUANTITY is the classic way to get an
%% "invalid argument" back from a node.
quantity_test() ->
    ?assertEqual(<<"0x0">>, eth_hex:encode_quantity(0)),
    ?assertEqual(<<"0x41">>, eth_hex:encode_quantity(65)),
    ?assertEqual(<<"0x400">>, eth_hex:encode_quantity(1024)),
    ?assertEqual(1024, eth_hex:decode_quantity(<<"0x400">>)),
    ?assertEqual(1024, eth_hex:decode_quantity(<<"0x0400">>)),
    ?assertEqual(1024, eth_hex:decode_quantity(1024)).

data_test() ->
    ?assertEqual(<<"0x0400">>, eth_hex:encode_data(<<4, 0>>)),
    ?assertEqual(<<"0x">>, eth_hex:encode_data(<<>>)),
    ?assertEqual(<<4, 0>>, eth_hex:decode_data(<<"0x0400">>)),
    ?assertEqual(<<4, 0>>, eth_hex:decode_data(<<"0400">>)),
    %% mixed case in, lower case out
    ?assertEqual(<<16#de, 16#ad>>, eth_hex:decode_data(<<"0xDeAd">>)),
    ?assertEqual(<<"0xdead">>, eth_hex:encode_data(<<16#de, 16#ad>>)).

%% Odd digit counts show up in hand written config and in some node replies.
odd_length_test() ->
    ?assertEqual(<<16#04>>, eth_hex:decode_data(<<"0x4">>)),
    ?assertEqual(<<16#04, 16#00>>, eth_hex:decode_data(<<"0x400">>)).

%% Sized decoding is what lets an address or a salt be passed either way.
sized_test() ->
    Raw = <<1:160>>,
    ?assertEqual(Raw, eth_hex:decode_data(Raw, 20)),
    ?assertEqual(Raw, eth_hex:decode_data(eth_hex:encode_data(Raw), 20)),
    ?assertError({bad_size, 20, 4}, eth_hex:decode_data(<<"0xdeadbeef">>, 20)).
