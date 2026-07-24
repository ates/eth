-module(eth_account_tests).

-include_lib("eunit/include/eunit.hrl").

%% Checksum vectors from EIP-55.
checksum_test() ->
    lists:foreach(
        fun(Address) ->
            ?assertEqual(Address, eth_account:checksum(string:lowercase(Address))),
            ?assertEqual(Address, eth_account:checksum(Address))
        end,
        [
            <<"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed">>,
            <<"0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359">>,
            <<"0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB">>,
            <<"0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb">>
        ]
    ).

%% Known private key / address pairs. The private key in the second case is
%% the one used by the EIP-155 example transaction.
address_test() ->
    ?assertEqual(
        <<"0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf">>,
        eth_account:address(<<1:256>>)
    ),
    ?assertEqual(
        <<"0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F">>,
        eth_account:address(
            <<"0x4646464646464646464646464646464646464646464646464646464646464646">>
        )
    ).

%% A hex string and its raw bytes must be interchangeable everywhere.
key_formats_test() ->
    Hex = <<"0x4646464646464646464646464646464646464646464646464646464646464646">>,
    Raw = <<16#4646464646464646464646464646464646464646464646464646464646464646:256>>,
    ?assertEqual(eth_account:address(Hex), eth_account:address(Raw)),
    ?assertEqual(eth_account:address(Hex), eth_account:address(binary:part(Hex, 2, 64))).

from_public_key_test() ->
    Pub = eth_account:public_key(<<1:256>>),
    ?assertEqual(64, byte_size(Pub)),
    ?assertEqual(eth_account:from_public_key(Pub), eth_account:from_public_key(<<4, Pub/binary>>)),
    ?assertEqual(<<"0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf">>,
                 eth_account:from_public_key(Pub)).

%% EIP-55 only defines a checksum for mixed-case input; all-lower and
%% all-upper must stay acceptable.
is_address_test() ->
    ?assert(eth_account:is_address(<<"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed">>)),
    ?assert(eth_account:is_address(<<"0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed">>)),
    ?assert(eth_account:is_address(<<"0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED">>)),
    ?assertNot(eth_account:is_address(<<"0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed">>)),
    ?assertNot(eth_account:is_address(<<"0xdeadbeef">>)),
    ?assertNot(eth_account:is_address(not_a_binary)).

bytes_test() ->
    Address = <<"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed">>,
    ?assertEqual(20, byte_size(eth_account:bytes(Address))),
    ?assertEqual(eth_account:bytes(Address),
                 eth_account:bytes(string:lowercase(Address))).
