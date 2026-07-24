-module(eth_hex).

%% JSON-RPC speaks two hex flavours (see the Ethereum JSON-RPC spec):
%%
%%   QUANTITY — an integer, minimally encoded, no leading zeroes, "0x0" for 0
%%   DATA     — a byte string, always an even number of digits
%%
%% Mixing them up is a classic source of "invalid argument" replies from
%% nodes, so they get separate functions here.

-export([encode_quantity/1]).
-export([decode_quantity/1]).
-export([encode_data/1]).
-export([decode_data/1]).
-export([decode_data/2]).

-spec encode_quantity(non_neg_integer()) -> binary().
encode_quantity(0) -> <<"0x0">>;
encode_quantity(N) when is_integer(N), N > 0 ->
    <<"0x", (string:lowercase(integer_to_binary(N, 16)))/binary>>.

-spec decode_quantity(binary() | integer()) -> non_neg_integer().
decode_quantity(N) when is_integer(N) -> N;
decode_quantity(<<"0x", Hex/binary>>) -> binary_to_integer(Hex, 16);
decode_quantity(Hex) when is_binary(Hex) -> binary_to_integer(Hex, 16).

-spec encode_data(binary()) -> binary().
encode_data(Bin) when is_binary(Bin) ->
    <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

%% @doc Accepts "0x"-prefixed hex, bare hex, or an already decoded binary.
%%
%% The ambiguity between bare hex and raw bytes is only resolvable with an
%% expected size, so unprefixed input is always treated as hex here. Use
%% decode_data/2 when a size is known.
-spec decode_data(binary()) -> binary().
decode_data(<<"0x", Hex/binary>>) -> binary:decode_hex(pad(Hex));
decode_data(Hex) when is_binary(Hex) -> binary:decode_hex(pad(Hex)).

%% @doc Decode to exactly Size bytes. An unprefixed binary that is already
%% Size bytes long is passed through, which is what makes it safe to hand
%% either an address string or raw address bytes to the transaction builder.
-spec decode_data(binary(), pos_integer()) -> binary().
decode_data(<<"0x", _/binary>> = Hex, Size) -> sized(decode_data(Hex), Size);
decode_data(Bin, Size) when byte_size(Bin) =:= Size -> Bin;
decode_data(Hex, Size) -> sized(decode_data(Hex), Size).

sized(Bin, Size) when byte_size(Bin) =:= Size -> Bin;
sized(Bin, Size) -> error({bad_size, Size, byte_size(Bin)}).

pad(Hex) when byte_size(Hex) rem 2 =:= 1 -> <<$0, Hex/binary>>;
pad(Hex) -> Hex.
