-module(eth_abi_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOKEN, <<"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913">>).

selector_test() ->
    %% Well known ERC-20 selectors.
    ?assertEqual(<<16#a9, 16#05, 16#9c, 16#bb>>,
                 eth_abi:selector(<<"transfer(address,uint256)">>)),
    ?assertEqual(<<16#70, 16#a0, 16#82, 16#31>>,
                 eth_abi:selector(<<"balanceOf(address)">>)).

transfer_topic_test() ->
    ?assertEqual(eth_abi:transfer_topic(),
                 eth_abi:topic(<<"Transfer(address,address,uint256)">>)).

%% Static arguments: head only, one word each.
encode_static_test() ->
    To = <<"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed">>,
    ?assertEqual(
        eth_hex:encode_data(<<
            (eth_abi:selector(<<"transfer(address,uint256)">>))/binary,
            0:96, (eth_account:bytes(To))/binary,
            1000:256
        >>),
        eth_abi:encode_call(<<"transfer(address,uint256)">>, [To, 1000])
    ).

%% Dynamic argument: the head holds an offset, the array lands in the tail.
%% This is the layout dpt_sweep builds by hand today.
encode_dynamic_array_test() ->
    Salts = [<<1:256>>, <<2:256>>],
    Expected = <<
        (eth_abi:selector(<<"sweepMany(bytes32[],address)">>))/binary,
        64:256,                                     %% offset to the array
        0:96, (eth_account:bytes(?TOKEN))/binary,   %% token, padded
        2:256,                                      %% array length
        1:256, 2:256                                %% elements
    >>,
    ?assertEqual(
        eth_hex:encode_data(Expected),
        eth_abi:encode_call(<<"sweepMany(bytes32[],address)">>, [Salts, ?TOKEN])
    ).

encode_empty_args_test() ->
    ?assertEqual(
        eth_hex:encode_data(eth_abi:selector(<<"decimals()">>)),
        eth_abi:encode_call(<<"decimals()">>, [])
    ).

decode_test() ->
    ?assertEqual([1000], eth_abi:decode([<<"uint256">>], eth_hex:encode_data(<<1000:256>>))),
    ?assertEqual(
        [eth_account:checksum(?TOKEN), true],
        eth_abi:decode(
            [<<"address">>, <<"bool">>],
            eth_hex:encode_data(<<0:96, (eth_account:bytes(?TOKEN))/binary, 1:256>>)
        )
    ).

decode_transfer_event_test() ->
    From = <<"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed">>,
    To = <<"0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359">>,
    Log = #{
        <<"topics">> => [
            eth_abi:transfer_topic(),
            eth_hex:encode_data(<<0:96, (eth_account:bytes(From))/binary>>),
            eth_hex:encode_data(<<0:96, (eth_account:bytes(To))/binary>>)
        ],
        <<"data">> => eth_hex:encode_data(<<1_500_000:256>>)
    },
    ?assertEqual(
        {ok, #{from => From, to => To, amount => 1_500_000}},
        eth_abi:decode_transfer_event(Log)
    ),
    %% atom keys must work too, for logs built inside the VM
    ?assertEqual(
        eth_abi:decode_transfer_event(Log),
        eth_abi:decode_transfer_event(#{
            topics => maps:get(<<"topics">>, Log),
            data   => maps:get(<<"data">>, Log)
        })
    ).

%% Some tokens emit Transfer with fewer indexed parameters, or the filter can
%% pick up an unrelated event. Neither may crash the caller.
decode_transfer_event_rejects_test() ->
    Topic = eth_abi:transfer_topic(),
    Word = eth_hex:encode_data(<<0:256>>),
    ?assertEqual({error, missing_indexed_arguments},
                 eth_abi:decode_transfer_event(#{topics => [Topic, Word], data => Word})),
    ?assertEqual({error, not_a_transfer},
                 eth_abi:decode_transfer_event(#{topics => [Word, Word, Word], data => Word})),
    ?assertMatch({error, {malformed_log, _}},
                 eth_abi:decode_transfer_event(#{topics => [Topic, Word, Word], data => <<"0x">>})).

unsupported_type_test() ->
    ?assertError({unsupported_type, <<"(uint256,address)">>},
                 eth_abi:encode([<<"(uint256,address)">>], [{1, ?TOKEN}])),
    ?assertError({unsupported_type, <<"bytes[]">>},
                 eth_abi:encode([<<"bytes[]">>], [[<<"0x00">>]])).
