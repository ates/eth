-module(eth_account).

%% Key handling and address derivation.
%%
%% Private keys are accepted either as 32 raw bytes or as a hex string, since
%% that is how they come out of a vault.

-export([address/1]).
-export([public_key/1]).
-export([private_key/1]).
-export([from_public_key/1]).
-export([checksum/1]).
-export([is_address/1]).
-export([bytes/1]).

-define(ADDRESS_SIZE, 20).

%% @doc EIP-55 checksummed address of the key's owner.
-spec address(binary()) -> binary().
address(PrivateKey) ->
    from_public_key(public_key(PrivateKey)).

-spec public_key(binary()) -> binary().
public_key(PrivateKey) ->
    secp256k1:public_key(private_key(PrivateKey)).

-spec private_key(binary()) -> <<_:256>>.
private_key(PrivateKey) ->
    eth_hex:decode_data(PrivateKey, 32).

%% @doc Address of an uncompressed public key: the low 20 bytes of its keccak
%% hash. Tolerates the 0x04 SEC1 prefix.
-spec from_public_key(binary()) -> binary().
from_public_key(<<4, Point:64/binary>>) ->
    from_public_key(Point);
from_public_key(<<Point:64/binary>>) ->
    checksum(binary:part(keccak:hash_256(Point), 12, ?ADDRESS_SIZE)).

%% @doc Apply the EIP-55 mixed-case checksum. Accepts raw address bytes or any
%% casing of a hex address; the result is always "0x"-prefixed.
-spec checksum(binary()) -> binary().
checksum(Address) ->
    Lower = string:lowercase(binary:encode_hex(bytes(Address))),
    <<Hash:(?ADDRESS_SIZE)/binary, _/binary>> = keccak:hash_256(Lower),
    Nibbles = [N || <<N:4>> <= Hash],
    <<"0x", << <<(cased(C, N))>> || {C, N} <- lists:zip(binary_to_list(Lower), Nibbles) >>/binary>>.

%% @doc Whether the value is a well formed address. Mixed-case input is also
%% verified against its EIP-55 checksum; all-lower and all-upper input is not,
%% as EIP-55 requires.
-spec is_address(term()) -> boolean().
is_address(Address) when is_binary(Address) ->
    try
        Bytes = bytes(Address),
        Hex = strip(Address),
        case Hex =:= string:lowercase(Hex) orelse Hex =:= string:uppercase(Hex) of
            true  -> true;
            false -> checksum(Bytes) =:= <<"0x", Hex/binary>>
        end
    catch
        _:_ -> false
    end;
is_address(_) ->
    false.

%% @doc Raw 20 bytes of an address.
-spec bytes(binary()) -> <<_:160>>.
bytes(Address) ->
    eth_hex:decode_data(Address, ?ADDRESS_SIZE).

strip(<<"0x", Hex/binary>>) -> Hex;
strip(Hex) -> Hex.

cased(C, N) when C >= $a, C =< $f, N >= 8 -> C - 32;
cased(C, _) -> C.
