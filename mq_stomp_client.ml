(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)
open ExtString
open Mq
open Mq_stomp_client_gen

module Comm_of_thread (C : Mq_concurrency.THREAD) =
struct

  include C

  type conn =
    { c_in : C.in_channel;
      c_out : C.out_channel;
      c_eof_nl : bool
    }

  let close conn =
    close_in_noerr conn.c_in >>= fun () -> close_out_noerr conn.c_out

  let rec output_headers ch = function
      [] -> return ()
    | (name, value) :: tl ->
        output_string ch (name ^ ": ") >>= fun () ->
        output_string ch value >>= fun () ->
        output_char ch '\n' >>= fun () ->
        output_headers ch tl

  let send conn (command, headers, body) =
    let ch = conn.c_out in
    output_string ch (command ^ "\n") >>= fun () ->
    output_headers ch headers >>= fun () ->
    output_char ch '\n' >>= fun () ->
    output_string ch body >>= fun () ->
    output_string ch (if conn.c_eof_nl then "\000\n" else "\000") >>= fun () ->
    flush ch

  let read_headers ch =
    let rec loop acc = input_line ch >>= function
        "" -> return acc
      | s ->
          match try Some (String.split s ":") with _ -> None with
              Some (k, v) -> loop ((String.lowercase k, String.strip v) :: acc)
            | None -> loop acc
    in loop []

  let rec read_command ch = input_line ch >>= function
      "" -> read_command ch
    | l -> return l

  let recv conn =
    let ch = conn.c_in in
      read_command ch >>= fun command ->
      let command = String.uppercase (String.strip command) in
      read_headers ch >>= fun headers ->
      try
        let len = int_of_string (List.assoc "content-length" headers) in
        (* FIXME: is the exception captured in the monad if bad len? *)
        let body = String.make len '\000' in
          really_input ch body 0 len >>= fun () ->
            if conn.c_eof_nl then begin
              input_line ch >>= fun _ -> (* FIXME: check that it's a \0\n ? *)
              return (command, headers, body)
            end else begin
              input_char ch >>= fun _ -> (* FIXME: check that it's a \0 ? *)
              return (command, headers, body)
            end
      with Not_found -> (* read until \0 *)
        let rec nl_loop ch b =
          input_line ch >>= function
              "" -> Buffer.add_char b '\n'; nl_loop ch b
            | line when line.[String.length line - 1] = '\000' ->
                Buffer.add_substring b line 0 (String.length line - 1);
                return (Buffer.contents b)
            | line ->
                Buffer.add_string b line; Buffer.add_char b '\n'; nl_loop ch b in
        let rec no_nl_loop ch b =
          input_char ch >>= function
              '\000' -> return (Buffer.contents b)
            | c -> Buffer.add_char b c; no_nl_loop ch b in
        let read_f = if conn.c_eof_nl then nl_loop else no_nl_loop in
          read_f ch (Buffer.create 80) >>= fun body ->
          return (command, headers, body)

end

module Make_generic(C : Mq_concurrency.THREAD) =
struct

  module Comm = Comm_of_thread(C)

  module Impl = Make_comm'(Comm)

  include Impl

  open C

  let establish_conn ?timeout msg sockaddr =
    catch
      (fun () ->
         open_connection ?timeout sockaddr
      )
      (let abort () = error Abort (Connection_error Connection_refused) msg in
       function
           Unix.Unix_error (uerr, _, _) when uerr = Unix.ECONNREFUSED ->
             abort ()
         | Sys_error _ ->
             abort ()
         | e -> fail e)

  type connect_addr = Unix.sockaddr

  let connect ?login ?passcode ?(eof_nl = true) ?(headers = []) ?timeout sockaddr =
    establish_conn "Mq_stomp_client.connect" ?timeout sockaddr >>= fun (c_in, c_out) ->
    let c = { Comm.c_in = c_in; c_out = c_out; c_eof_nl = eof_nl } in
    connect ?login ?passcode ~eof_nl ~headers c

end

module Make_comm(M : Mq_concurrency.COMM) =
struct
  module Impl = Make_comm'(M)
  include Impl
  type connect_addr = M.conn
end

module Lock_generic
  (C : Mq_concurrency.THREAD)
  (G : Mq.GENERIC with type 'a thread = 'a C.t)
  (M : Mq_concurrency.MUTEX with type 'a thread = 'a C.t)
 : Mq.GENERIC with
     type 'a thread = 'a C.t
 and type connect_addr = G.connect_addr
 and type transaction = G.transaction
 and type receipt = G.receipt
 =
struct

  type 'a thread = 'a G.thread
  type connection =
    { c : G.connection;
      m : M.t;
    }
  type transaction = G.transaction

  open C

  let with_lock conn func =
    M.lock conn.m >>= fun () ->
    C.catch
      (fun () ->
         func conn.c >>= fun a ->
         return (`Ok a)
      )
      (fun e -> return (`Error e))
    >>= fun res ->
    M.unlock conn.m;
    match res with
    | `Ok a -> return a
    | `Error e -> fail e

  let transaction_begin c = with_lock c G.transaction_begin
  let transaction_commit c t = with_lock c (fun c -> G.transaction_commit c t)
  let transaction_commit_all c = with_lock c G.transaction_commit_all
  let transaction_abort_all c = with_lock c G.transaction_abort_all
  let transaction_abort c t = with_lock c (fun c -> G.transaction_abort c t)

  let receive_msg c = with_lock c G.receive_msg

  let ack_msg c ?transaction msg = with_lock c
    (fun c -> G.ack_msg c ?transaction msg)

  let ack c ?transaction msg_id = with_lock c
    (fun c -> G.ack c ?transaction msg_id)

  let disconnect c = with_lock c G.disconnect

  type connect_addr = G.connect_addr

  let connect ?login ?passcode ?eof_nl ?headers ?timeout addr =
    G.connect ?login ?passcode ?eof_nl ?headers ?timeout addr >>= fun c ->
    return { c = c; m = M.create () }

  let send c ?transaction ?persistent ~destination ?headers msg =
    with_lock c begin fun c ->
      G.send c ?transaction ?persistent ~destination ?headers msg
    end

  let send_no_ack c ?transaction ?persistent ~destination ?headers msg =
    with_lock c begin fun c ->
      G.send_no_ack c ?transaction ?persistent ~destination ?headers msg
    end

  let subscribe c ?headers dest = with_lock c begin fun c ->
    G.subscribe c ?headers dest
  end

  let unsubscribe c ?headers dest = with_lock c begin fun c ->
    G.unsubscribe c ?headers dest
  end

  let expect_receipt c rid = G.expect_receipt c.c rid

  type receipt = G.receipt = {
    r_headers : (string * string) list;
    r_body : string;
  }

  let receive_receipt c rid = with_lock c (fun c -> G.receive_receipt c rid)

  let receipt_id = G.receipt_id

  let transaction_id = G.transaction_id

end

module Trace
  (C : Mq_concurrency.THREAD)
  (G : Mq.GENERIC with type 'a thread = 'a C.t)
  (Config : sig val name : string end)
 : Mq.GENERIC with
     type 'a thread = 'a C.t
 and type connect_addr = G.connect_addr
 and type transaction = G.transaction
 and type receipt = G.receipt
 =
struct

  let next_cid =
    let cur = ref 0 in
    fun () ->
      incr cur;
      !cur

  type 'a thread = 'a G.thread
  type connection =
    { c : G.connection;
      cid : int;
    }
  type transaction = G.transaction

  open C

  let dbg cid funcname fmt =
    let open Printf in
    ksprintf begin fun s ->
        eprintf "Trace: %s %i: %s: %s\n%!" Config.name cid funcname s
      end
      fmt

  let trace conn funcname ?args ?res func =
    dbg conn.cid funcname "enter%s"
      (match args with None -> "" | Some a -> "; " ^ a);
    C.catch
      (fun () ->
         func conn.c >>= fun a ->
         return (`Ok a)
      )
      (fun e -> return (`Error e))
    >>= fun r ->
    match r with
    | `Ok a ->
        dbg conn.cid funcname "exit%s"
          (match res with None -> "" | Some dump -> "; " ^ dump a);
        return a
    | `Error e ->
        dbg conn.cid funcname "exit, error: %s" (Printexc.to_string e);
        fail e

  let transaction_begin c = trace c "transaction_begin" G.transaction_begin
  let transaction_commit c t = trace c "transaction_commit" begin fun c ->
    G.transaction_commit c t
  end
  let transaction_commit_all c = trace c "transaction_commit_all"
    G.transaction_commit_all
  let transaction_abort_all c = trace c "transaction_abort_all"
    G.transaction_abort_all
  let transaction_abort c t = trace c "transaction_abort" begin fun c ->
    G.transaction_abort c t
  end

  let dump_headers headers =
    "[" ^
    String.concat "; "
      (List.map (fun (n, v) -> Printf.sprintf "%s:%S" n v) headers) ^
    "]"

  let dump_msg msg =
    Printf.sprintf "id:%S headers:%s body:%S"
      msg.msg_id (dump_headers msg.msg_headers) msg.msg_body

  let receive_msg c = trace c "receive_msg" G.receive_msg
    ~res: dump_msg

  let ack_msg c ?transaction msg = trace c "ack_msg"
    (fun c -> G.ack_msg c ?transaction msg)
    ~args: (dump_msg msg)

  let ack c ?transaction msg_id = trace c "ack"
    (fun c -> G.ack c ?transaction msg_id)
    ~args: (Printf.sprintf "msg_id=%S" msg_id)

  let disconnect c = trace c "disconnect" G.disconnect

  type connect_addr = G.connect_addr

  let connect ?login ?passcode ?eof_nl ?headers ?timeout addr =
    dbg 0 "connect" "enter";
    G.connect ?login ?passcode ?eof_nl ?headers ?timeout addr >>= fun c ->
    let cid = next_cid () in
    dbg cid "connect" "exit";
    return { c = c; cid = cid }

  let dump_optheaders_body ho b =
    Printf.sprintf "headers:%s body=%S"
      (match ho with None -> "None" | Some h -> dump_headers h)
      b

  let send c ?transaction ?persistent ~destination ?headers msg =
    trace c "send" begin fun c ->
      G.send c ?transaction ?persistent ~destination ?headers msg
    end
    ~args: (dump_optheaders_body headers msg)

  let send_no_ack c ?transaction ?persistent ~destination ?headers msg =
    trace c "send_no_ack" begin fun c ->
      G.send_no_ack c ?transaction ?persistent ~destination ?headers msg
    end
    ~args: (dump_optheaders_body headers msg)

  let dump_dest d = Printf.sprintf "dest:%S" d

  let subscribe c ?headers dest = trace c "subscribe" begin fun c ->
      G.subscribe c ?headers dest
    end
    ~args: (dump_dest dest)

  let unsubscribe c ?headers dest = trace c "unsubscribe" begin fun c ->
      G.unsubscribe c ?headers dest
    end
    ~args: (dump_dest dest)

  let expect_receipt c rid = G.expect_receipt c.c rid

  type receipt = G.receipt = {
    r_headers : (string * string) list;
    r_body : string;
  }

  let receive_receipt c rid = trace c "receive_receipt" begin
    fun c -> G.receive_receipt c rid
  end

  let receipt_id = G.receipt_id

  let transaction_id = G.transaction_id

end
