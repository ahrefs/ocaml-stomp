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

  let establish_conn msg sockaddr =
    catch
      (fun () ->
         open_connection sockaddr
      )
      (let abort () = error Abort (Connection_error Connection_refused) msg in
       function
           Unix.Unix_error (uerr, _, _) when uerr = Unix.ECONNREFUSED ->
             abort ()
         | Sys_error _ ->
             abort ()
         | e -> fail e)

  type connect_addr = Unix.sockaddr

  let connect ?login ?passcode ?(eof_nl = true) ?(headers = []) sockaddr =
    establish_conn "Mq_stomp_client.connect" sockaddr >>= fun (c_in, c_out) ->
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

  let connect ?login ?passcode ?eof_nl ?headers addr =
    G.connect ?login ?passcode ?eof_nl ?headers addr >>= fun c ->
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
