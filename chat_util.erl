-module(chat_util).
-export([find_mesg_limit/1,greatest/1]).

%% Find the begin of the message in a Channel+0+Message binary
find_mesg_limit(Message) -> find_mesg_limit(Message,1).

find_mesg_limit(<<>>,N) -> N;
find_mesg_limit(Message,N) ->
	case split_binary(Message,1) of
		{<<0>>,Rest} -> N;
		{_OtherChar,Rest} -> find_mesg_limit(Rest,N+1)
	end.

greatest(List) -> greatest(List,0).

greatest([],Yet) -> Yet;
greatest([H|T],Yet) ->
	if
		H > Yet -> greatest(T,H);
		true -> greatest(T,Yet)
	end.
