-module(eth_rlp).

%% Recursive Length Prefix encoding.
%%
%% Only the encoder is implemented — decoding is not needed to build and sign
%% transactions, and nodes hand back JSON rather than RLP.
%%
%% Erlang lists are RLP lists, binaries are RLP byte strings. Non-negative
%% integers are a convenience: they encode as their minimal big-endian byte
%% string, so 0 becomes the empty string, exactly as the yellow paper requires.
%% This distinction matters — <<0>> and 0 are different values in RLP.

-export([encode/1]).

-type item() :: binary() | non_neg_integer() | [item()].
-export_type([item/0]).

-spec encode(item()) -> binary().
encode(N) when is_integer(N), N >= 0 ->
    encode_string(unsigned(N));
encode(Bin) when is_binary(Bin) ->
    encode_string(Bin);
encode(List) when is_list(List) ->
    Payload = iolist_to_binary([encode(Item) || Item <- List]),
    prefix(byte_size(Payload), 16#c0, Payload).

encode_string(<<Byte>>) when Byte < 16#80 -> <<Byte>>;
encode_string(Bin) -> prefix(byte_size(Bin), 16#80, Bin).

prefix(Len, Offset, Payload) when Len =< 55 ->
    <<(Offset + Len), Payload/binary>>;
prefix(Len, Offset, Payload) ->
    LenBin = binary:encode_unsigned(Len),
    <<(Offset + 55 + byte_size(LenBin)), LenBin/binary, Payload/binary>>.

unsigned(0) -> <<>>;
unsigned(N) -> binary:encode_unsigned(N).
