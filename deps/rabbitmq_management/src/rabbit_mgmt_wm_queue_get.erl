%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is VMware, Inc.
%%   Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.
-module(rabbit_mgmt_wm_queue_get).

-export([init/1, resource_exists/2, post_is_create/2, is_authorized/2,
         allowed_methods/2, process_post/2]).

-include("rabbit_mgmt.hrl").
-include_lib("webmachine/include/webmachine.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%%--------------------------------------------------------------------

init(_Config) -> {ok, #context{}}.

allowed_methods(ReqData, Context) ->
    {['POST'], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {case rabbit_mgmt_wm_queue:queue(ReqData) of
         not_found -> false;
         _         -> true
     end, ReqData, Context}.

post_is_create(ReqData, Context) ->
    {false, ReqData, Context}.

process_post(ReqData, Context) ->
    rabbit_mgmt_util:post_respond(do_it(ReqData, Context)).

do_it(ReqData, Context) ->
    VHost = rabbit_mgmt_util:vhost(ReqData),
    Q = rabbit_mgmt_util:id(queue, ReqData),
    rabbit_mgmt_util:with_decode(
      [requeue, count, encoding], ReqData, Context,
      fun([RequeueBin, CountBin, EncBin]) ->
              rabbit_mgmt_util:with_channel(
                VHost, ReqData, Context,
                fun (Ch) ->
                        NoAck = not rabbit_mgmt_util:parse_bool(RequeueBin),
                        Count = rabbit_mgmt_util:parse_int(CountBin),
                        Enc = case EncBin of
                                  <<"auto">>   -> auto;
                                  <<"base64">> -> base64;
                                  _            -> throw({error,
                                                         {bad_encoding,
                                                          EncBin}})
                              end,
                        rabbit_mgmt_util:reply(
                          basic_gets(Count, Ch, Q, NoAck, Enc),
                          ReqData, Context)
                end)
      end).

basic_gets(0, _, _, _, _) ->
    [];

basic_gets(Count, Ch, Q, NoAck, Enc) ->
    case basic_get(Ch, Q, NoAck, Enc) of
        none -> [];
        M    -> [M | basic_gets(Count - 1, Ch, Q, NoAck, Enc)]
    end.

basic_get(Ch, Q, NoAck, Enc) ->
    case amqp_channel:call(Ch, #'basic.get'{queue = Q,
                                            no_ack = NoAck}) of
        {#'basic.get_ok'{redelivered   = Redelivered,
                         exchange      = Exchange,
                         routing_key   = RoutingKey,
                         message_count = MessageCount},
         #amqp_msg{props = Props, payload = Payload}} ->
            [{payload_bytes, size(Payload)},
             {redelivered,   Redelivered},
             {exchange,      Exchange},
             {routing_key,   RoutingKey},
             {message_count, MessageCount},
             {properties,    rabbit_mgmt_format:basic_properties(Props)}] ++
                payload_part(Payload, Enc);
        #'basic.get_empty'{} ->
            none
    end.

is_authorized(ReqData, Context) ->
    rabbit_mgmt_util:is_authorized_vhost(ReqData, Context).

%%--------------------------------------------------------------------

payload_part(Payload, Enc) ->
    {PL, E} = case Enc of
                  auto -> try
                              %% TODO mochijson does this but is it safe?
                              xmerl_ucs:from_utf8(Payload),
                              {Payload, string}
                          catch exit:{ucs, _} ->
                                  {base64:encode(Payload), base64}
                          end;
                  _    -> {base64:encode(Payload), base64}
              end,
    [{payload, PL}, {payload_encoding, E}].
