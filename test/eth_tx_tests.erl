-module(eth_tx_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, <<"0x4646464646464646464646464646464646464646464646464646464646464646">>).
-define(TO, <<"0x0102030405060708090A0b0C0d0e0F1011121314">>).

tx() ->
    #{
        chain_id                 => 1,
        nonce                    => 2,
        max_priority_fee_per_gas => 3,
        max_fee_per_gas          => 4,
        gas                      => 21000,
        to                       => ?TO,
        value                    => 5,
        data                     => <<>>
    }.

%% Hand-derived from the EIP-1559 field order, small enough to check by eye:
%%
%%   chain_id 1  -> 01           nonce 2 -> 02       priority 3 -> 03
%%   max_fee 4   -> 04           gas 21000 -> 82 5208
%%   to (20 b)   -> 94 <bytes>   value 5 -> 05       data <<>> -> 80
%%   access_list -> c0
%%
%% payload is 31 bytes, so the list prefix is 0xc0 + 31 = 0xdf, and the
%% whole thing is prefixed with the 0x02 transaction type.
unsigned_payload_test() ->
    ?assertEqual(
        <<16#02,
          16#df,
          16#01, 16#02, 16#03, 16#04,
          16#82, 16#52, 16#08,
          16#94, (eth_account:bytes(?TO))/binary,
          16#05,
          16#80,
          16#c0>>,
        eth_tx:unsigned(tx())
    ).

%% Optional fields must default, not crash: absent data is the empty string,
%% absent value is zero (which in RLP is also the empty string, 0x80).
defaults_test() ->
    ?assertEqual(eth_tx:unsigned(tx()), eth_tx:unsigned(maps:remove(data, tx()))),
    ?assertEqual(
        eth_tx:unsigned(maps:put(value, 0, tx())),
        eth_tx:unsigned(maps:remove(value, tx()))
    ),
    ?assertEqual(
        <<16#05, 16#80, 16#c0>>,
        binary:part(eth_tx:unsigned(tx()), byte_size(eth_tx:unsigned(tx())) - 3, 3)
    ),
    ?assertEqual(
        <<16#80, 16#80, 16#c0>>,
        binary:part(eth_tx:unsigned(maps:remove(value, tx())),
                    byte_size(eth_tx:unsigned(tx())) - 3, 3)
    ).

%% An absent recipient is contract creation: the field is the empty string,
%% never twenty zero bytes.
contract_creation_test() ->
    Tx = maps:remove(to, tx()),
    Unsigned = eth_tx:unsigned(Tx),
    ?assertEqual(nomatch, binary:match(Unsigned, <<0:160>>)),
    ?assertNotEqual(nomatch, binary:match(Unsigned, <<16#80, 16#05, 16#80, 16#c0>>)).

%% The signature must be over the *unsigned* payload hash, and the recovery
%% id embedded as yParity must recover the signer. This is the check that a
%% plain sign/verify round trip cannot make.
signature_test() ->
    Tx = tx(),
    #{raw := Raw, hash := Hash} = eth_tx:sign(Tx, ?KEY),
    SigHash = eth_tx:sig_hash(Tx),
    Signature = secp256k1:sign(SigHash, eth_account:private_key(?KEY)),

    ?assertEqual(eth_account:public_key(?KEY), secp256k1:recover(SigHash, Signature)),

    <<R:256, S:256, YParity:8>> = Signature,
    Expected = <<16#02, (eth_rlp:encode(fields(Tx) ++ [YParity, R, S]))/binary>>,
    ?assertEqual(eth_hex:encode_data(Expected), Raw),

    %% The transaction is known by the hash of the signed payload, not of the
    %% signing digest.
    ?assertEqual(eth_hex:encode_data(keccak:hash_256(Expected)), Hash),
    ?assertNotEqual(eth_hex:encode_data(SigHash), Hash).

%% RFC6979 signing is deterministic, so the whole transaction is.
deterministic_test() ->
    ?assertEqual(eth_tx:sign(tx(), ?KEY), eth_tx:sign(tx(), ?KEY)).

%% Changing any signed field must change the signature — cheap protection
%% against a field silently dropping out of the payload.
all_fields_signed_test() ->
    #{hash := Base} = eth_tx:sign(tx(), ?KEY),
    lists:foreach(
        fun({Key, Value}) ->
            #{hash := Hash} = eth_tx:sign(maps:put(Key, Value, tx()), ?KEY),
            ?assertNotEqual({Key, Base}, {Key, Hash})
        end,
        [
            {chain_id, 8453},
            {nonce, 99},
            {max_priority_fee_per_gas, 30},
            {max_fee_per_gas, 40},
            {gas, 100000},
            {to, <<"0x00112233445566778899aAbBcCdDeEff00112233">>},
            {value, 6},
            {data, <<"0xdeadbeef">>},
            {access_list, [{?TO, [<<1:256>>]}]}
        ]
    ).

%% Calldata may arrive as a hex string or as raw bytes.
calldata_formats_test() ->
    Hex = eth_tx:sign(maps:put(data, <<"0xdeadbeef">>, tx()), ?KEY),
    Raw = eth_tx:sign(maps:put(data, <<16#de, 16#ad, 16#be, 16#ef>>, tx()), ?KEY),
    ?assertEqual(Hex, Raw).

fields(Tx) ->
    [
        maps:get(chain_id, Tx),
        maps:get(nonce, Tx),
        maps:get(max_priority_fee_per_gas, Tx),
        maps:get(max_fee_per_gas, Tx),
        maps:get(gas, Tx),
        eth_account:bytes(maps:get(to, Tx)),
        maps:get(value, Tx),
        <<>>,
        []
    ].
