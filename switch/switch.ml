open Lwt
open Cohttp
open Xenstore_server

let debug fmt = Logging.debug "server_xen" fmt
let warn  fmt = Logging.warn  "server_xen" fmt
let error fmt = Logging.error "server_xen" fmt

let get_time () = Oclock.gettime Oclock.monotonic
let start_time = get_time ()

let message_logger = Logging.create 512
let message conn_id session (fmt: (_,_,_,_) format4) =
    Printf.ksprintf message_logger.Logging.push ("[%3d] [%s]" ^^ fmt) conn_id (match session with None -> "None" | Some x -> x)

let syslog = Lwt_log.syslog ~facility:`Local3 ()

let rec logging_thread logger =
    lwt lines = Logging.get logger in
	lwt () = Lwt_list.iter_s
            (fun x ->
                lwt () = Lwt_log.log ~logger:!Lwt_log.default ~level:Lwt_log.Notice x in
				return ()
			) lines in
	logging_thread logger

let make_path p = Store.Path.create p (Store.Path.getdomainpath 0)


let startswith prefix x = String.length x >= (String.length prefix) && (String.sub x 0 (String.length prefix) = prefix)


let port = ref 8080
let ip = ref "0.0.0.0"

open Cohttp_lwt_unix

let no_name () =
	Server.respond_string ~status:`Bad_request ~body:"no name has been bound" ()

let no_binding x =
	Server.respond_string ~status:`Not_found ~body:(Printf.sprintf "name %s is not bound" x) ()

let redirect x =
	let headers = Header.add (Header.init()) "Location" x in
	Server.respond_string ~headers ~status:`Found ~body:"" ()

let make_unique_id =
	let counter = ref 0L in
	fun () ->
		let result = !counter in
		counter := Int64.add 1L !counter;
		result

let make_fresh_name () = Printf.sprintf "client-%Ld" (make_unique_id ())

module Int64Map = Map.Make(struct type t = int64 let compare = Int64.compare end)
module IntMap = Map.Make(struct type t = int let compare = compare end)
module StringSet = Set.Make(struct type t = string let compare = String.compare end)
module IntSet = Set.Make(struct type t = int let compare = compare end)
module StringMap = Map.Make(struct type t = string let compare = compare end)

module Relation = functor(A: Map.OrderedType) -> functor(B: Map.OrderedType) -> struct
	(** Store a (a: A.t, b:B.t) relation R such that given
		an a, finding the largest set bs such that
          \forall b \in bs. (a, b)\in R
		and v.v. on b are efficient. *)

	module A_Set = Set.Make(A)
	module A_Map = Map.Make(A)
	module B_Set = Set.Make(B)
	module B_Map = Map.Make(B)

	type t = {
		a_to_b: B_Set.t A_Map.t;
		b_to_a: A_Set.t B_Map.t;
	}
	let empty = {
		a_to_b = A_Map.empty;
		b_to_a = B_Map.empty;
	}
	let get_bs a t =
		if A_Map.mem a t.a_to_b
		then A_Map.find a t.a_to_b
		else B_Set.empty
	let get_as b t =
		if B_Map.mem b t.b_to_a
		then B_Map.find b t.b_to_a
		else A_Set.empty
			
	let add a b t =
		{
			a_to_b = A_Map.add a (B_Set.add b (get_bs a t)) t.a_to_b;
			b_to_a = B_Map.add b (A_Set.add a (get_as b t)) t.b_to_a;
		}
	let of_list = List.fold_left (fun t (a, b) -> add a b t) empty
	let to_list t = A_Map.fold (fun a bs acc -> B_Set.fold (fun b acc -> (a, b) :: acc) bs acc) t.a_to_b []

	let remove_a a t =
		let bs = get_bs a t in
		{
			a_to_b = A_Map.remove a t.a_to_b;
			b_to_a =
				B_Set.fold
					(fun b acc ->
						let as' =
							if B_Map.mem b acc
							then B_Map.find b acc
							else A_Set.empty in
						let as' = A_Set.remove a as' in
						if as' = A_Set.empty
						then B_Map.remove b acc
						else B_Map.add b as' acc
					) bs t.b_to_a;
		}
	let remove_b b t =
		let as' = get_as b t in
		{
			a_to_b =
				A_Set.fold
					(fun a acc ->
						let bs =
							if A_Map.mem a acc
							then A_Map.find a acc
							else B_Set.empty in
						let bs = B_Set.remove b bs in
						if bs = B_Set.empty
						then A_Map.remove a acc
						else A_Map.add a bs acc
					) as' t.a_to_b;
			b_to_a = B_Map.remove b t.b_to_a;
		}

	let equal t1 t2 =
		true
		&& A_Map.equal B_Set.equal t1.a_to_b t2.a_to_b
		&& B_Map.equal A_Set.equal t1.b_to_a t2.b_to_a

end

module StringStringRelation = Relation(String)(String)

module Subscription = struct
	(* Session token -> queue bindings *)
	let t = ref (StringStringRelation.empty)

	let session_to_wakeup : (string, unit Lwt.u) Hashtbl.t = Hashtbl.create 128

	let add session subscription =
		t := StringStringRelation.add session subscription !t;
		if Hashtbl.mem session_to_wakeup session then begin
			Lwt.wakeup_later (Hashtbl.find session_to_wakeup session) ()
		end

	let get session = StringStringRelation.get_bs session !t

	let remove subscription =
		t := StringStringRelation.remove_b subscription !t

end

module IntStringRelation = Relation(struct type t = int let compare = compare end)(String)

module Connections = struct
	let t = ref (IntStringRelation.empty)

	let get_session conn_id =
		(* Nothing currently stops you registering multiple sessions per connection *)
		let sessions = IntStringRelation.get_bs conn_id !t in
		if sessions = IntStringRelation.B_Set.empty
		then None
		else Some(IntStringRelation.B_Set.choose sessions)

	let get_origin conn_id = match get_session conn_id with
		| None -> Protocol.Anonymous conn_id
		| Some x -> Protocol.Name x

	let add conn_id session =
		debug "+ connection %d" conn_id;
		t := IntStringRelation.add conn_id session !t

	let remove conn_id =
		debug "- connection %d" conn_id;
		t := IntStringRelation.remove_a conn_id !t

	let is_session_active session =
		IntStringRelation.get_as session !t <> IntStringRelation.A_Set.empty

end

module Q = struct

	let queues : (string, Protocol.Entry.t Int64Map.t) Hashtbl.t = Hashtbl.create 128
	let queue_lengths : (string, int) Hashtbl.t = Hashtbl.create 128
	let next_transfer_expected : (string, int64) Hashtbl.t = Hashtbl.create 128
	let message_id_to_queue : string Int64Map.t ref = ref Int64Map.empty

	let list prefix = Hashtbl.fold (fun name _ acc ->
		if startswith prefix name
		then name :: acc
		else acc) queues []

	module Lengths = struct
		open Measurable
		let d x =Description.({ description = "length of queue " ^ x; units = "" })
		let list_available () =
			Hashtbl.fold (fun name _ acc ->
				(name, d name) :: acc
			) queues []
		let measure name =
			if Hashtbl.mem queues name
			then Some (Measurement.Int (Hashtbl.find queue_lengths name))
			else None
	end

	type wait = {
		c: unit Lwt_condition.t;
		m: Lwt_mutex.t
	}

	let waiters = Hashtbl.create 128

	let exists name = Hashtbl.mem queues name

	let add name =
		if not(exists name) then begin
			Hashtbl.replace queues name Int64Map.empty;
			Hashtbl.replace queue_lengths name 0;
			Hashtbl.replace waiters name {
				c = Lwt_condition.create ();
				m = Lwt_mutex.create ()
			}
		end

	let get name =
		if exists name
		then Hashtbl.find queues name
		else Int64Map.empty


	let remove name =
		let entries = get name in
		Int64Map.iter (fun id _ ->
			message_id_to_queue := Int64Map.remove id !message_id_to_queue
		) entries;
		Hashtbl.remove queues name;
		Hashtbl.remove queue_lengths name;
		Hashtbl.remove next_transfer_expected name;
		Hashtbl.remove waiters name;
		Subscription.remove name

	let transfer name next_expected =
		let time = Int64.add (get_time ()) (Int64.of_float (next_expected *. 1e9)) in
		Hashtbl.replace next_transfer_expected name time

	let get_next_transfer_expected name =
		if Hashtbl.mem next_transfer_expected name
		then Some (Hashtbl.find next_transfer_expected name)
		else None

	let queue_of_id id = Int64Map.find id !message_id_to_queue

	let ack id =
		let name = queue_of_id id in
		if exists name then begin
			let q = get name in
			message_id_to_queue := Int64Map.remove id !message_id_to_queue;
			Printf.fprintf stderr "Removing id %Ld from queue %s\n%!" id name;
			if Int64Map.mem id q
			then Hashtbl.replace queue_lengths name (Hashtbl.find queue_lengths name - 1);
			Hashtbl.replace queues name (Int64Map.remove id q);
		end

	let wait from name =
		if Hashtbl.mem waiters name then begin
			let w = Hashtbl.find waiters name in
			Lwt_mutex.with_lock w.m
				(fun () ->
					let rec loop () =
						let _, _, not_seen = Int64Map.split from (get name) in
						if not_seen = Int64Map.empty then begin
							lwt () = Lwt_condition.wait ~mutex:w.m w.c in
							loop ()
						end else return () in
					loop ()
				)
		end else begin
			let t, _ = Lwt.task () in
			t (* block forever *)
		end

	let send conn_id name data =
		(* If a queue doesn't exist then drop the message *)
		if exists name then begin
			let w = Hashtbl.find waiters name in
			Lwt_mutex.with_lock w.m
				(fun () ->
					let q = get name in
					let origin = Connections.get_origin conn_id in
					let id = make_unique_id () in
					message_id_to_queue := Int64Map.add id name !message_id_to_queue;
					Hashtbl.replace queues name (Int64Map.add id (Protocol.Entry.make (get_time ()) origin data) q);
					Hashtbl.replace queue_lengths name (Hashtbl.find queue_lengths name + 1);
					Lwt_condition.broadcast w.c ();
					return (Some id)
				)
		end else return None

end

module Transient_queue = struct

	(* Session -> set of queues which will be GCed on session cleanup *)
	let queues : (string, StringSet.t) Hashtbl.t = Hashtbl.create 128

	let add session name =
		let existing =
			if Hashtbl.mem queues session
			then Hashtbl.find queues session
			else StringSet.empty in
		Hashtbl.replace queues session (StringSet.add name existing)

	let remove session =
		if Hashtbl.mem queues session then begin
			let qs = Hashtbl.find queues session in
			StringSet.iter
				(fun name ->
					debug "Deleting transient queue: %s" name;
					Q.remove name;
				) qs;
			Hashtbl.remove queues session
		end

	let all () = Hashtbl.fold (fun _ set acc -> StringSet.union set acc) queues StringSet.empty
end

let snapshot () =
	let get_queue_contents q = Int64Map.fold (fun i e acc -> (i, e) :: acc) q [] in
	let open Protocol.Diagnostics in
	let queues qs =
		Hashtbl.fold (fun n q acc ->
			let queue_contents = get_queue_contents q in
			let next_transfer_expected = Q.get_next_transfer_expected n in
			(n, { queue_contents; next_transfer_expected }) :: acc
		) qs [] in
	let is_transient =
		let all = Transient_queue.all () in
		fun (x, _) -> StringSet.mem x all in
	let all_queues = queues Q.queues in
	let transient_queues, permanent_queues = List.partition is_transient all_queues in
	let current_time = get_time () in
	{ start_time; current_time; permanent_queues; transient_queues }

module Trace_buffer = struct
	let size = 128

	let buffer : (int64 * Protocol.Event.t) option array = Array.create size None
	let c = Lwt_condition.create ()

	let next_id = ref 0L

	let add event =
		let next_slot = Int64.(to_int (rem !next_id (of_int size))) in
		buffer.(next_slot) <- Some (!next_id, event);
		next_id := Int64.succ !next_id;
		Lwt_condition.broadcast c ()

	(* fold [f] over buffered items in chronological order *)
	let fold f acc =
		let next_slot = Int64.(to_int (rem !next_id (of_int size))) in
		let rec range start finish acc =
			if start > finish
			then acc
			else range (start + 1) finish (f buffer.(start) acc) in
		range 0 (next_slot - 1) (range next_slot (size - 1) acc)

	let get from timeout : (int64 * Protocol.Event.t) list Lwt.t =
		let sleep = Lwt_unix.sleep timeout in
		let wait_for_data =
			while_lwt !next_id <= from do
	   			Lwt_condition.wait c
			done in
		(* Wait until some data is available ie. when next_id > from (or timeout) *)
		lwt () = Lwt.pick [ sleep; wait_for_data ] in
		(* start from next_slot, looking for non-None entries which
		   are > from *)
		let reversed_results = fold (fun x acc -> match x with
			| None -> acc
			| Some (id, _) when id < from -> acc
			| Some (id, x) -> (id, x) :: acc) [] in
		return (List.rev reversed_results)

end

open Protocol
let process_request conn_id session request = match session, request with
	(* Only allow Login, Get, Trace and Diagnostic messages if there is no session *)
	| _, In.Login session ->
		(* associate conn_id with 'session' *)
		Connections.add conn_id session;
		return Out.Login
	| _, In.Diagnostics ->
		return (Out.Diagnostics (snapshot ()))
	| _, In.Trace(from, timeout) ->
		lwt events = Trace_buffer.get from timeout in
		return (Out.Trace {Out.events = events})
	| _, In.Get path ->
		let path = if path = [] || path = [ "" ] then [ "index.html" ] else path in
		lwt ic = Lwt_io.open_file ~mode:Lwt_io.input (String.concat "/" ("www" :: path)) in
		lwt txt = Lwt_stream.to_string (Lwt_io.read_chars ic) in
		lwt () = Lwt_io.close ic in
		return (Out.Get txt)
	| None, _ ->
		return Out.Not_logged_in
	| Some session, In.List prefix ->
		return (Out.List (Q.list prefix))
	| Some session, In.CreatePersistent name ->
		Q.add name;
		return (Out.Create name)
	| Some session, In.CreateTransient name ->
		Transient_queue.add session name;
		Q.add name;
		return (Out.Create name)
	| Some session, In.Subscribe name ->
		Subscription.add session name;
		return Out.Subscribe
	| Some session, In.Ack id ->
		let name = Q.queue_of_id id in
		Trace_buffer.add (Event.({time = Unix.gettimeofday (); input = Some session; queue = name; output = None; message = Ack id }));
		Q.ack id;
		return Out.Ack
	| Some session, In.Transfer(from, timeout) ->
		let start = Unix.gettimeofday () in
		let rec wait () =
			let names = Subscription.get session in
			let not_seen = StringStringRelation.B_Set.fold (fun name map ->
				let q = Q.get name in
				Q.transfer name timeout;
				let _, _, not_seen = Int64Map.split from q in
				Int64Map.fold Int64Map.add map not_seen
			) names Int64Map.empty in
			if not_seen <> Int64Map.empty
			then return not_seen
			else
				let remaining_timeout = max 0. (start +. timeout -. (Unix.gettimeofday ())) in
				if remaining_timeout <= 0.
				then return Int64Map.empty
				else
					let timeout = Lwt.map (fun () -> `Timeout) (Lwt_unix.sleep remaining_timeout) in
					let more = StringStringRelation.B_Set.fold (fun name acc ->
						Lwt.map (fun () -> `Data) (Q.wait from name) :: acc
					) names [] in
					let t, u = Lwt.task () in
					Hashtbl.replace Subscription.session_to_wakeup session u;
					let sub = Lwt.map (fun () -> `Subscription) t in
					try_lwt
						match_lwt Lwt.pick (sub :: timeout :: more) with
						| `Timeout -> return Int64Map.empty
						| `Data ->
							wait ()
						| `Subscription ->
							wait ()
					finally
		   				Hashtbl.remove Subscription.session_to_wakeup session;
			   			return ()
				in
		lwt messages = wait () in
		let transfer = {
			Out.messages = Int64Map.fold (fun id e acc -> (id, e.Protocol.Entry.message) :: acc) messages [];
		} in
		List.iter
			(fun (id, m) ->
				let name = Q.queue_of_id id in
				Trace_buffer.add (Event.({time = Unix.gettimeofday (); input = None; queue = name; output = Some session; message = Message (id, m) }))
			) transfer.Out.messages;
		return (Out.Transfer transfer)
	| Some session, In.Send (name, data) ->
		begin match_lwt Q.send conn_id name data with
		| None -> return Out.Send
		| Some id ->
			Trace_buffer.add (Event.({time = Unix.gettimeofday (); input = Some session; queue = name; output = None; message = Message (id, data) }));
			return Out.Send
		end

let make_server () =
	debug "Started server on localhost:%d" !port;

	let (_: 'a) = logging_thread Logging.logger in
	let (_: 'a) = logging_thread message_logger in

  	(* (Response.t * Body.t) Lwt.t *)
	let callback conn_id ?body req =
		let open Protocol in
		lwt body = match body with
			| None -> return None
			| Some b ->
				lwt s = Body.string_of_body (Some b) in
				return (Some s) in
		match In.of_request body (Request.meth req) (Request.path req) with
		| None ->
			debug "<- [unparsable request; path = %s; body = %s]" (Request.path req) (match body with Some x -> "\"" ^ x ^ "\"" | None -> "None");
			debug "-> 404 [Not_found]";
			Cohttp_lwt_unix.Server.respond_not_found ~uri:(Request.uri req) ()
		| Some request ->
			debug "<- %s [%s]" (Request.path req) (match body with None -> "" | Some x -> x);
			let session = Connections.get_session conn_id in
			message conn_id session "%s" (Jsonrpc.to_string (In.rpc_of_t request));
			lwt response = process_request conn_id session request in
			let status, body = Out.to_response response in
			debug "-> %s [%s]" (Cohttp.Code.string_of_status status) body;
			Cohttp_lwt_unix.Server.respond_string ~status ~body ()
		in
	let conn_closed conn_id () =
		let session = Connections.get_session conn_id in
		Connections.remove conn_id;
		match session with
		| None -> ()
		| Some session ->
			if not(Connections.is_session_active session) then begin
				debug "Session %s cleaning up" session;
				Transient_queue.remove session
			end in

	debug "Message switch starting";
	let config = { Cohttp_lwt_unix.Server.callback; conn_closed } in
	server ~address:!ip ~port:!port config
    
let _ =
	Arg.parse [
		"-port", Arg.Set_int port, "port to listen on";
		"-ip", Arg.Set_string ip, "IP to bind to";
	] (fun x -> Printf.fprintf stderr "Ignoring: %s" x)
		"A simple message switch";

	Lwt_unix.run (make_server ()) 

