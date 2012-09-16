-module(chatsrv).
-compile(export_all).

-include("/usr/lib/erlang/lib/stdlib-1.18.1/include/qlc.hrl").

-record(channels,{cnumber,topic,members}).
-record(users,{uid,uname}).

%% Start server process and DB
start_server(New) ->
	start_mnesia(New),
	spawn(fun start_client_listen/0).

%% Start DB and create schema
start_mnesia(true) ->
	mnesia:create_schema([node()]),
	mnesia:start(),
	mnesia:create_table(channels,[{attributes,record_info(fields,channels)},{disc_copies,[node()]}]),
	mnesia:create_table(users,[{attributes,record_info(fields,users)},{disc_copies,[node()]}]);

%% Only start DB
start_mnesia(false) ->
	mnesia:start().

%% Listen
start_client_listen() -> 
	{ok,Socket} = gen_tcp:listen(32768,[binary,{packet,0}]),
	accept_loop(Socket).

%% Accept connections
accept_loop(Socket) ->
	{ok,ClSock} = gen_tcp:accept(Socket),
	spawn(?MODULE,accept_loop,[Socket]),
	handle_client(ClSock,"").

%% Handle clients in a loop
%% UserName is the state. It's the associated user.
handle_client(Socket,UserName) ->
	receive
		{tcp,Socket,Data} -> ReturnValue = handle_data(Data,UserName),
			case ReturnValue of
				error -> gen_tcp:send(Socket,"Error at action. Maybe the username exists already\n"), NewUser = UserName;
				String when is_list(String) -> NewUser = String
			end,
			handle_client(Socket,NewUser);
		{tcp,closed} -> void
	end.

%% Handle received Data
handle_data(Data,UserName) ->
	case split_binary(Data,1) of
		{<<1>>,ChanName} -> join_channel(ChanName,UserName), UserName;
		{<<2>>,ChanAndMesg} -> UserName;%send_message(parse_message(ChanAndMesg))
		{<<3>>,NewUserName} -> 
			try add_user(binary_to_list(NewUserName)) of
				{atomic,ok} -> binary_to_list(NewUserName)
			catch
				throw: userExistsAlready -> error
			end
	end.

%% Put a user in a channel
join_channel(Channel,User) ->
	%% Get UID of user
	{atomic,[UID]} = mnesia:transaction(fun() -> 
				qlc:e(qlc:q([U#users.uid || U <- mnesia:table(users), string:equal(U#users.uname,User)]))
		end),

	%% Get list which users are already in this channel
	{atomic,[ListOfJoinedUsersInThisChannel]} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([C#channels.members || C <- mnesia:table(channels), string:equal(C#channels.cnumber,Channel)]))
		end),
	
	case lists:member(UID,ListOfJoinedUsersInThisChannel) of
		%% User is not yet in this channel
		false -> {atomic,ok} = mnesia:transaction(fun() ->
					case mnesia:read(channels,Channel) of
						[{channels,Number,Topic,Members}] -> Record = #channels{cnumber=Number,topic=Topic,members=[UID|Members]};
						[] ->
							{atomic,ChanNums} = mnesia:transaction(fun() ->
										qlc:e(qlc:q([C#channels.cnumber || C <- mnesia:table(channels)]))
								end),
							Record = #channels{cnumber=chat_util:greatest(ChanNums)+1, topic="",members=[UID]}
					end,
					mnesia:write(Record)
			end);
		%% User is already in this channel
		true -> goodAsWell
	end.

%% Add a user
add_user(UserName) ->
	{atomic,PreviousUser} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([U#users.uname || U <- mnesia:table(users), string:equal(UserName,U#users.uname)]))
		end),

	case PreviousUser of
		[] -> fine;
		Other -> throw(userExistsAlready)
	end,

	{atomic,ok} = mnesia:transaction(fun() ->
				Record = #users{uid=make_ref(),uname=UserName},
				mnesia:write(Record)
		end).


parse_message(Message) ->
	Limit = chat_util:find_mesg_limit(Message).
