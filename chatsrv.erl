-module(chatsrv).
-compile(export_all).

-record(channels,{cnumber,topic}).
-record(users,{uname,uid}).
-record(users_channels,{cnumber,uid}).

start_server(New) ->
	start_mnesia(New),
	start_client_listen().

start_mnesia(true) ->
	mnesia:create_schema([node()]),
	mnesia:start(),
	mnesia:create_table(channels,[{attributes,record_info(fields,channels)},{disc_copies,[node()]}]),
	mnesia:create_table(users,[{attributes,record_info(fields,channels)},{disc_copies,[node()]}]),
	mnesia:create_table(users_channels,[{attributes,record_info(fields,users_channels)},{type,bag},{disc_copies,[node()]}]);

start_mnesia(false) ->
	mnesia:start().

start_client_listen() -> 
	{ok,Socket} = gen_tcp:listen(32768,[binary,{packet,0}]),
	accept_loop(Socket).

accept_loop(Socket) ->
	{ok,ClSock} = gen_tcp:accept(Socket),
	spawn(?MODULE,accept_loop,[Socket]),
	handle_client(ClSock).

handle_client(Socket) ->
	receive
		{tcp,Socket,Data} -> handle_data(Data), handle_client(Socket);
		{tcp,closed} -> void
	end.

handle_data(Data) ->
	case split_binary(Data,1) of
		{<<1>>,ChanName} -> void;%join(binary_to_list(ChanName);
		{<<2>>,ChanAndMesg} -> void%send_message(parse_message(ChanAndMesg))
	end.

parse_message(Message) ->
	Limit = find_mesg_limit(Message).

find_mesg_limit(Message) -> find_mesg_limit(Message,1).

find_mesg_limit(<<>>,N) -> N;
find_mesg_limit(Message,N) ->
	case split_binary(Message,N) of
		{<<0>>,Rest} -> N;
		{_OtherChar,Rest} -> find_mesg_limit(Rest,N+1)
	end.
