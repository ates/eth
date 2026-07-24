-module(eth_abi).

%% Contract ABI encoding/decoding.
%%
%% Deliberately partial: static types (uintN, intN, address, bool, bytesN),
%% the dynamic types (bytes, string) and one-dimensional arrays of static
%% types. That covers ERC-20 calls and the sweep/forwarder patterns. Tuples,
%% nested arrays and fixed-size arrays are not supported and raise.

-export([selector/1]).
-export([topic/1]).
-export([encode_call/2]).
-export([encode/2]).
-export([decode/2]).
-export([decode_transfer_event/1]).
-export([transfer_topic/0]).

-define(WORD, 32).

%% keccak("Transfer(address,address,uint256)")
-define(TRANSFER_TOPIC,
    <<"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef">>).

-spec transfer_topic() -> binary().
transfer_topic() -> ?TRANSFER_TOPIC.

%% @doc First four bytes of the keccak hash of a function signature.
-spec selector(binary()) -> <<_:32>>.
selector(Signature) ->
    binary:part(keccak:hash_256(Signature), 0, 4).

%% @doc Full keccak hash of an event signature, as a log topic.
-spec topic(binary()) -> binary().
topic(Signature) ->
    eth_hex:encode_data(keccak:hash_256(Signature)).

%% @doc Calldata for a call, e.g.
%% `encode_call(<<"transfer(address,uint256)">>, [To, Amount])'.
%%
%% Returns a "0x" string, since calldata is a wire value: it goes straight
%% into a transaction or an eth_call. Use encode/2 for raw bytes.
-spec encode_call(binary(), [term()]) -> binary().
encode_call(Signature, Args) ->
    eth_hex:encode_data(
        <<(selector(Signature))/binary, (encode(types(Signature), Args))/binary>>
    ).

%% @doc Encode arguments without a selector, as raw bytes.
-spec encode([binary()], [term()]) -> binary().
encode(Types, Args) when length(Types) =:= length(Args) ->
    Pairs = lists:zip(Types, Args),
    {Heads, Tails, _} =
        lists:foldl(
            fun({Type, Arg}, {H, T, Offset}) ->
                case is_dynamic(Type) of
                    false ->
                        {[encode_static(Type, Arg) | H], T, Offset};
                    true ->
                        Encoded = encode_dynamic(Type, Arg),
                        {[word(Offset) | H], [Encoded | T], Offset + byte_size(Encoded)}
                end
            end,
            {[], [], ?WORD * length(Pairs)},
            Pairs
        ),
    iolist_to_binary([lists:reverse(Heads), lists:reverse(Tails)]).

%% @doc Decode a return value or log data blob. Static types only.
-spec decode([binary()], binary()) -> [term()].
decode(Types, Data) ->
    decode_words(Types, eth_hex:decode_data(Data), []).

%% @doc Decode an ERC-20 Transfer log into `#{from, to, amount}'.
%%
%% Accepts the log object as it comes off the wire (binary keys) or with atom
%% keys. Both indexed parameters are required, which rules out the malformed
%% Transfer events some tokens emit.
-spec decode_transfer_event(map()) ->
    {ok, #{from := binary(), to := binary(), amount := non_neg_integer()}} | {error, term()}.
decode_transfer_event(Log) ->
    try
        Topics = [string:lowercase(T) || T <- field(topics, Log)],
        Data = field(data, Log),
        case Topics of
            [?TRANSFER_TOPIC, From, To] ->
                <<Amount:(?WORD * 8), _/binary>> = eth_hex:decode_data(Data),
                {ok, #{
                    from   => decode_static(<<"address">>, eth_hex:decode_data(From, ?WORD)),
                    to     => decode_static(<<"address">>, eth_hex:decode_data(To, ?WORD)),
                    amount => Amount
                }};
            [Topic | _] when Topic =/= ?TRANSFER_TOPIC ->
                {error, not_a_transfer};
            _ ->
                {error, missing_indexed_arguments}
        end
    catch
        _:Reason -> {error, {malformed_log, Reason}}
    end.

field(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error       -> maps:get(atom_to_binary(Key), Map)
    end.

decode_words([], _Bin, Acc) ->
    lists:reverse(Acc);
decode_words([Type | Types], <<Word:(?WORD)/binary, Rest/binary>>, Acc) ->
    decode_words(Types, Rest, [decode_static(Type, Word) | Acc]).

types(Signature) ->
    [_Name, Rest] = binary:split(Signature, <<"(">>),
    case binary:part(Rest, 0, byte_size(Rest) - 1) of
        <<>> -> [];
        Args -> binary:split(Args, <<",">>, [global])
    end.

is_dynamic(<<"bytes">>) -> true;
is_dynamic(<<"string">>) -> true;
is_dynamic(Type) when byte_size(Type) > 2 ->
    binary:part(Type, byte_size(Type) - 2, 2) =:= <<"[]">>;
is_dynamic(_Type) -> false.

element_type(Type) -> binary:part(Type, 0, byte_size(Type) - 2).

encode_dynamic(<<"bytes">>, Value) ->
    Bin = eth_hex:decode_data(Value),
    <<(word(byte_size(Bin)))/binary, (pad_right(Bin))/binary>>;
encode_dynamic(<<"string">>, Value) ->
    <<(word(byte_size(Value)))/binary, (pad_right(Value))/binary>>;
encode_dynamic(Type, Values) when is_list(Values) ->
    Elem = element_type(Type),
    case is_dynamic(Elem) of
        true  -> error({unsupported_type, Type});
        false -> ok
    end,
    iolist_to_binary([word(length(Values)) | [encode_static(Elem, V) || V <- Values]]).

encode_static(<<"address">>, Value) ->
    <<0:96, (eth_account:bytes(Value))/binary>>;
encode_static(<<"bool">>, true) ->
    word(1);
encode_static(<<"bool">>, false) ->
    word(0);
encode_static(<<"uint", _/binary>>, Value) when is_integer(Value), Value >= 0 ->
    word(Value);
encode_static(<<"int", _/binary>>, Value) when is_integer(Value) ->
    <<Value:(?WORD * 8)/signed>>;
encode_static(<<"bytes", Size/binary>>, Value) when Size =/= <<>> ->
    pad_right(eth_hex:decode_data(Value, binary_to_integer(Size)));
encode_static(Type, _Value) ->
    error({unsupported_type, Type}).

decode_static(<<"address">>, <<0:96, Address:20/binary>>) ->
    eth_account:checksum(Address);
decode_static(<<"bool">>, <<Value:(?WORD * 8)>>) ->
    Value =/= 0;
decode_static(<<"uint", _/binary>>, <<Value:(?WORD * 8)>>) ->
    Value;
decode_static(<<"int", _/binary>>, <<Value:(?WORD * 8)/signed>>) ->
    Value;
decode_static(<<"bytes", Size/binary>>, Word) when Size =/= <<>> ->
    binary:part(Word, 0, binary_to_integer(Size));
decode_static(Type, _Word) ->
    error({unsupported_type, Type}).

word(N) -> <<N:(?WORD * 8)>>.

pad_right(Bin) when byte_size(Bin) rem ?WORD =:= 0 -> Bin;
pad_right(Bin) ->
    Padding = ?WORD - byte_size(Bin) rem ?WORD,
    <<Bin/binary, 0:(Padding * 8)>>.
