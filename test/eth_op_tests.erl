-module(eth_op_tests).

-include_lib("eunit/include/eunit.hrl").

%% The predeploy address is fixed across OP Stack chains.
oracle_address_test() ->
    ?assertEqual(<<"0x420000000000000000000000000000000000000F">>, eth_op:gas_price_oracle()),
    ?assert(eth_account:is_address(eth_op:gas_price_oracle())).

%% getL1Fee takes dynamic bytes, so the head is an offset and the payload is
%% length-prefixed and right-padded to a whole word.
calldata_test() ->
    Raw = <<"0xdeadbeef">>,
    ?assertEqual(
        eth_hex:encode_data(<<
            16#49, 16#94, 16#8e, 16#0e,                    %% getL1Fee(bytes)
            32:256,                                        %% offset to the bytes
            4:256,                                         %% length
            16#de, 16#ad, 16#be, 16#ef, 0:224              %% padded to 32 bytes
        >>),
        eth_abi:encode_call(<<"getL1Fee(bytes)">>, [Raw])
    ).

%% Selectors of the oracle methods used here.
selectors_test() ->
    ?assertEqual(<<"0x49948e0e">>,
                 eth_hex:encode_data(eth_abi:selector(<<"getL1Fee(bytes)">>))),
    ?assertEqual(<<"0xde26c4a1">>,
                 eth_hex:encode_data(eth_abi:selector(<<"getL1GasUsed(bytes)">>))),
    ?assertEqual(<<"0x519b4bd3">>,
                 eth_hex:encode_data(eth_abi:selector(<<"l1BaseFee()">>))).

%% A receipt from an OP Stack chain carries the fee that was actually
%% charged; a receipt from L1 does not.
receipt_l1_fee_test() ->
    ?assertEqual({ok, 16#2a}, eth_op:receipt_l1_fee(#{<<"l1Fee">> => <<"0x2a">>})),
    ?assertEqual({ok, 0}, eth_op:receipt_l1_fee(#{<<"l1Fee">> => <<"0x0">>})),
    ?assertEqual({error, not_op_stack}, eth_op:receipt_l1_fee(#{<<"l1Fee">> => null})),
    ?assertEqual({error, not_op_stack}, eth_op:receipt_l1_fee(#{<<"status">> => <<"0x1">>})).
