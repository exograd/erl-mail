%% Copyright (c) 2021 Bryan Frimin <bryan@frimin.fr>.
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
%% SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
%% IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(imf_mime).

-export([encode_part/1]).

-export_type([part/0, header/0, field/0, body/0]).

-type part() :: #{header := header(),
                  body := body()}.

-type body() :: {data, iodata()}
              | {part, part()}
              | [{data, iodata()} | {part, part()}].

-type header() :: [field()].

-type field() :: mime_version()
               | content_type()
               | content_transfer_encoding()
               | content_id()
               | content_description()
               | content_disposition().

-type mime_version() :: {mime_version, {non_neg_integer(), non_neg_integer()}}.

-type content_type() :: {content_type, media_type()}.

-type content_transfer_encoding() :: {content_transfer_encoding, mechanism()}.

-type content_id() :: {content_id, imf:msg_id()}.

-type content_description() :: {content_description, text()}.

-type mechanism() :: '7bit' | '8bit' | binary | quoted_printable | base64.

-type media_type() ::
        #{type := binary(), subtype := binary(),
          parameters => #{attribute() => value()}}.

-type attribute() :: binary().
-type value() :: binary().

-type content_disposition() :: {content_disposition, disposition()}.

-type disposition() :: #{type :=  disposition_type(),
                         parameters => disposition_params()}.

-type disposition_type() :: inline | attachment.

-type disposition_params() :: #{filename => binary(),
                                creation_date => calendar:datetime(),
                                modification_date => calendar:datetime(),
                                read_date => calendar:datetime(),
                                size => pos_integer()}.

-type text() :: binary().

-spec multipart_mixed(body()) -> body().
multipart_mixed(Parts) ->
  {part,
   #{header =>
       [{content_type,
         #{type => <<"multipart">>, subtype => <<"mixed">>,
           parameters => #{<<"boundary">> => ksuid:generate()}}}],
     body => Parts}}.

-spec multipart_related(body()) -> body().
multipart_related(Parts) ->
  {part,
   #{header =>
       [{content_type,
         #{type => <<"multipart">>, subtype => <<"related">>,
           parameters => #{<<"boundary">> => ksuid:generate()}}}],
     body => Parts}}.

-spec multipart_alternative(body()) -> body().
multipart_alternative(Parts) ->
  {part,
   #{header =>
       [{content_type,
         #{type => <<"multipart">>, subtype => <<"alternative">>,
           parameters => #{<<"boundary">> => ksuid:generate()}}}],
     body => Parts}}.

-spec text_html(binary()) -> body().
text_html(Bin) ->
  {part,
   #{header =>
       [{content_type,
         #{type => <<"text">>, subtype => <<"html">>}},
        {content_transfer_encoding, quoted_printable},
        {content_disposition, #{type => inline}}],
     body =>
       {data, Bin}}}.

-spec encode_part(part()) -> iodata().
encode_part(#{header := Header, body := Body}) ->
  EncodedHeader = lists:reverse(lists:foldl(fun encode_field/2, [], Header)),
  case find_content_type_boundary(Header) of
    error ->
      if
        EncodedHeader =:= [] ->
          [encode_part(Body, []), "\r\n"];
        true ->
          [EncodedHeader, "\r\n", encode_part(Body, []), "\r\n"]
      end;
    {ok, Boundary} ->
      [EncodedHeader, "\r\n"
       "--", Boundary, "\r\n",
       lists:join(["\r\n--", Boundary, "\r\n"], encode_part(Body, [])), "\r\n",
       "--", Boundary, "--\r\n"]
  end.

-spec encode_part(body(), iodata()) -> iodata().
encode_part({data, Bin}, Acc) ->
  Acc ++ [Bin];
encode_part({part, #{header := Header, body := Body}}, Acc) ->
  EncodedHeader = lists:reverse(lists:foldl(fun encode_field/2, [], Header)),
  case find_content_type_boundary(Header) of
    error ->
      if EncodedHeader =:= [] ->
          Acc ++ [encode_part(Body, [])];
         true ->
          Acc ++ [EncodedHeader, "\r\n", encode_part(Body, [])]
      end;
    {ok, Boundary} ->
      ["--", Boundary, "\r\n",
       EncodedHeader,
       encode_part(Body, []), "\r\n"
       "--", Boundary, "--\r\n"]
  end;
encode_part([], Acc) ->
  Acc;
encode_part([H | T], Acc) ->
  Acc2 = Acc ++ [encode_part(H, [])],
  encode_part(T, Acc2).

-spec find_content_type_boundary(header()) -> {ok, iodata()} | error.
find_content_type_boundary(Header) ->
  ContentType = proplists:get_value(content_type, Header, #{}),
  Parameters = maps:get(parameters, ContentType, #{}),
  maps:find(<<"boundary">>, Parameters).

-spec encode_field(field(), iodata()) -> iodata().
encode_field({mime_version, {Major, Minor}}, Acc) ->
  [["Mime-Version: ", io_lib:format("~B.~B\r\n", [Major, Minor])] | Acc];
encode_field({content_type, MediaType}, Acc) ->
  [["Content-Type: ", encode_media_type(MediaType)] | Acc];
encode_field({content_transfer_encoding, Mechanism}, Acc) ->
  [["Content-Transfer-Encoding: ", encode_mechanism(Mechanism), "\r\n"] | Acc];
encode_field({content_id, Id}, Acc) ->
  [["Content-ID: ", imf_message_id_field:encode([Id])] | Acc];
encode_field({content_description, Bin}, Acc) ->
  [["Content-Description:", imf_unstructured_field:encode(Bin, 20)] | Acc];
encode_field({content_disposition, Disposition}, Acc) ->
  [["Content-Disposition: ", encode_content_disposition(Disposition)] | Acc];
encode_field({Key, Value}, Acc) ->
  Prepend = byte_size(Key) + 1,
  [[Key, ":", imf_unstructured_field:encode(Value, Prepend)] | Acc].


-spec encode_mechanism(mechanism()) -> iodata().
encode_mechanism('7bit') ->
  "7bit";
encode_mechanism('8bit') ->
  "8bit";
encode_mechanism(binary) ->
  "binary";
encode_mechanism(quoted_printable) ->
  "quoted-printable";
encode_mechanism(base64) ->
  "base64".

-spec encode_media_type(media_type()) -> iodata().
encode_media_type(MediaType) ->
  Type = maps:get(type, MediaType),
  SubType = maps:get(subtype, MediaType),
  F =
    fun (Key, Value, Acc) ->
        [[Key, "=\"", Value, "\""] | Acc]
    end,
  Bin = maps:fold(F, [], maps:get(parameters, MediaType, #{})),
  Bin2 = lists:join("\r\n ", lists:reverse(Bin)),
  case iolist_size(Bin2) =:= 0 of
    true -> [Type, "/", SubType, "\r\n"];
    false -> [Type, "/", SubType, ";\r\n ", Bin2, "\r\n"]
  end.

-spec encode_content_disposition(disposition()) -> iodata().
encode_content_disposition(Disposition) ->
  Type = atom_to_binary(maps:get(type, Disposition)),
  F =
    fun
      (filename, Filename, Acc) ->
        [["filename=", Filename] | Acc];
      (creation_date, Datetime, Acc) ->
        FormattedDT = imf_date_field:format(Datetime),
        [["creation-date=\"", FormattedDT, "\""] | Acc];
      (modification_date, Datetime, Acc) ->
        FormattedDT = imf_date_field:format(Datetime),
        [["modification-date=\"", FormattedDT, "\""] | Acc];
      (read_date, Datetime, Acc) ->
        FormattedDT = imf_date_field:format(Datetime),
        [["read-date=\"", FormattedDT, "\""] | Acc];
      (size, Size, Acc) ->
        [["size=", integer_to_binary(Size)] | Acc]
    end,
  Bin = maps:fold(F, [], maps:get(parameters, Disposition, #{})),
  Bin2 = lists:join(";\r\n ", lists:reverse(Bin)),

  case iolist_size(Bin2) =:= 0 of
    true -> [Type, "\r\n"];
    false -> [Type, ";\r\n ", Bin2, "\r\n"]
  end.
