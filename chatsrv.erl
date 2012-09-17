-module(chatsrv).
-compile(export_all).

-include("/usr/lib/erlang/lib/stdlib-1.18.1/include/qlc.hrl").

-record(channels,{cnumber,pid,topic,members}).
-record(users,{uid,uname,pid}).

%% Start server process and DB
start_server(New) ->
	start_mnesia(New),
	spawn(fun start_client_listen/0).

%% Start DB and create schema
start_mnesia(true) ->
	mnesia:create_schema([node()]),
	mnesia:start(),
	mnesia:create_table(channels,[{attributes,record_info(fields,channels)}]),
	mnesia:create_table(users,[{attributes,record_info(fields,users)}]);

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
	handle_client(ClSock,""),
	gen_tcp:close(ClSock).

%% Handle clients in a loop
%% UserName is the state. It's the associated user.
handle_client(Socket,UserName) ->
	receive
		%% A new TCP message
		{tcp,Socket,Data} ->
			%% Handle the message with handle_data() - providing join, log in, sending messages etc
			try handle_data(Data,UserName) of
				%% Should always return a user name (in case of change)
				String when is_list(String) -> handle_client(Socket,String);
				deleted -> gen_tcp:close(Socket)
			catch
				throw: userExistsAlready -> gen_tcp:send(Socket,"EXCEPTION: User exists already.\n"); %% Abort communication; thrown by add_user()
				throw: noSuchUser -> gen_tcp:send(Socket,"EXCEPTION: No such user. Maybe you should authenticate yourself before sending messages\n"),
					handle_client(Socket,UserName) %% Thrown by join_channel()
			end;
		{tcp,closed} -> remove_user(UserName);
		{mesg,Message} -> gen_tcp:send(Socket,Message), handle_client(Socket,UserName)
	end.

%% Handle received Data -- basically a dispatcher. Called on every received message
handle_data(Data,UserName) ->
	%% Separate the first byte, it's the type of message byte
	io:format("~p~n",[Data]),
	case split_binary(Data,1) of
		{<<1>>,ChanName} ->
			<<ChanNumber:64/native>> = ChanName,
			join_channel(ChanNumber,UserName),
			UserName;
		{<<2>>,ChanAndMesg} -> {DstChannel, OrigMessage} = parse_message(ChanAndMesg),
			send_message({DstChannel,[UserName|[": "|OrigMessage]]}),
			UserName;
		{<<3>>,NewUserName} -> {atomic,ok} =
			add_user(binary_to_list(NewUserName)),
			binary_to_list(NewUserName);
		{<<4>>,<<>>} -> remove_user(UserName), deleted
	end.

%%%%%%%%%%%%%%%%%%%%% Functions called by the handle_data() dispatcher %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Send a message to a channel
send_message({Channel,Message}) ->
	case mnesia:transaction(fun() ->
					qlc:e(qlc:q([C#channels.pid || C <- mnesia:table(channels), C#channels.cnumber =:= Channel]))
			end) of
		{atomic,[Pid]} -> Pid ! {mesg,Message};
		_ -> throw(dbError)
	end.

%% Associate a user with a channel
join_channel(Channel,User) ->
	%% Get UID of user
	case mnesia:transaction(fun() ->
				qlc:e(qlc:q([U#users.uid || U <- mnesia:table(users), string:equal(U#users.uname,User)]))
		end) of

		{atomic,[UID]} -> UID;
		{atomic,[]}    -> UID = 42, throw(noSuchUser) %% Abort - no such user. Should break the connection
	end,

	%% Get list which users are already in this channel
	case mnesia:transaction(fun() ->
				qlc:e(qlc:q([C#channels.members || C <- mnesia:table(channels), string:equal(C#channels.cnumber,Channel)]))
		end) of

		{atomic,[ListOfJoinedUsersInThisChannel]} -> fine;
		{atomic,[]} -> ListOfJoinedUsersInThisChannel = []
	end,

	case lists:member(UID,ListOfJoinedUsersInThisChannel) of
		%% User is not yet in this channel
		false -> {atomic,ok} = mnesia:transaction(fun() ->
					case mnesia:read(channels,Channel) of
						%% Channel already exists
						[{channels,Number,Pid,Topic,Members}] -> Record = #channels{cnumber=Number,pid=Pid,topic=Topic,members=[UID|Members]};
						%% Channel gets created
						[] -> Record = #channels{cnumber=Channel, pid=spawn(?MODULE,chanproc,[Channel]), topic="",members=[UID]}
					end,
					mnesia:write(Record)
			end);
		%% User is already in this channel
		true -> goodAsWell
	end.

%% Add a user to the db
add_user(UserName) ->
	Pid = self(),

	{atomic,PreviousUser} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([U#users.uname || U <- mnesia:table(users), string:equal(UserName,U#users.uname)]))
		end),

	case PreviousUser of
		[] -> fine;
		_Other -> throw(userExistsAlready)
	end,

	{atomic,ok} = mnesia:transaction(fun() ->
				Record = #users{uid=make_ref(),uname=UserName, pid=Pid},
				mnesia:write(Record)
		end).

%% Remove a user from everywhere
remove_user(UserName) ->
	%% Obtain UID
	{atomic,[UID]} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([U#users.uid || U <- mnesia:table(users), string:equal(U#users.uname,UserName)]))
			end),
	%% Delete user name from table
	{atomic,ok} = mnesia:transaction(fun() ->
					mnesia:delete({users,UID})
				end),
	{atomic,ok} = mnesia:transaction(fun() ->
				Channels = qlc:e(qlc:q([C || C <- mnesia:table(channels)])),
				NewChannels = lists:map(fun(Channel) ->
							#channels{cnumber=Channel#channels.cnumber,
								pid=Channel#channels.pid,
								topic=Channel#channels.topic,
								members=lists:subtract(Channel#channels.members,[UID])}
					end, Channels),
				lists:foreach(fun(X) -> mnesia:write(X) end,NewChannels)
		end).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Channel server: This channel sends the messages appearing in a channel to all users in this channel.
chanproc(Number) ->
	receive
		{mesg,Message} ->
			{atomic,[Members]} = mnesia:transaction(fun() ->
						qlc:e(qlc:q([C#channels.members || C <- mnesia:table(channels), C#channels.cnumber =:= Number]))
				end),
			lists:foreach(fun(U) ->
						{atomic,[Pid]} = mnesia:transaction(fun() ->
									qlc:e(qlc:q([V#users.pid || V <- mnesia:table(users), V#users.uid =:= U]))
							end),
						Pid ! {mesg,Message} end,Members), chanproc(Number)
	end.

parse_message(Message) ->
	{Channel,ActualMessage} = split_binary(Message,8),
	<<ChanNum:64/unsigned-native>> = Channel,
	{ChanNum,binary_to_list(ActualMessage)}.
