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
