(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)
open Arg
open Printf
open ExtString
open ExtList

module S = Mq_stomp_client.Make_generic(Mq_concurrency.Posix_thread)

let () = Random.self_init ()

let port = ref 61613
let address = ref "127.0.0.1"
let num_msgs = ref max_int
let login = ref None
let passcode = ref None
let dests = ref []
let use_nl_eof = ref false
let ack = ref false
let verbose = ref false
let readsubs = ref false
let durable = ref false
let headers = ref []
let prefetch = ref 0
let nthreads = ref 0

let msg = "Usage: test_receive [options]"

let set_some r x = r := Some x
let set_some_f f r x = r := Some (f x)

let args =
  Arg.align
    [
      "-n", Set_int num_msgs, "N Receive N messages (default: unlimited)";
      "-a", Set_string address, sprintf "ADDRESS Address (default: %s)" !address;
      "-p", Set_int port, sprintf "PORT Port (default: %d)" !port;
      "-s", String (fun s -> dests := s :: !dests), "NAME Subscribe to destination NAME.";
      "--concurrency", Set_int nthreads, " Concurrency factor.";
      "--prefetch", Set_int prefetch, " Prefetch (default: disabled)";
      "--stdin", Set readsubs, " Read list of destinations to from stdin.";
      "--ack", Set ack, " Send ACKs for received messages.";
      "--durable", Set durable, " Create durable destinations in RabbitMQ.";
      "--header", String (fun s -> headers := s :: !headers), " Use custom header in SUBSCRIBE.";
      "--login", String (set_some login), "LOGIN Use the given login (default: none).";
      "--passcode", String (set_some passcode), "PASSCODE Use the given passcode (default: none).";
      "--newline", Set use_nl_eof, " Use \\0\\n to signal end of frame (default: no).";
      "--verbose", Set verbose, " Verbose mode.";
    ]

let read_subs () =
  let rec loop ls =
    match try Some (read_line ()) with _ -> None with
        None -> ls
      | Some line -> loop (line :: ls)
  in loop []

let () =
  Arg.parse args ignore msg;
  if !num_msgs <= 0 then begin
    Arg.usage args msg;
    exit 1;
  end;
  let cnt = ref 0 in
  let t0 = ref (Unix.gettimeofday ()) in
  let payload = ref 0 in
  let print_rate () =
    let dt = Unix.gettimeofday () -. !t0 in
      printf "\n\nReceived %d messages in %.1fs (%8.1f/s)\n"
        !cnt dt (float !cnt /. dt);
      printf "Total payload %d KB (%d KB/s).\n" (!payload / 1024)
        (truncate (float !payload /. 1024. /. dt));
      exit 1 in
  let subs = if !readsubs then !dests @ read_subs () else !dests in
  let hs =
    List.filter_map
      (fun s -> try Some (String.split s ":") with _ -> None) !headers in
  let hs =
    if !durable then ["auto-delete", "false"; "durable", "true"] @ hs
    else hs in
  let hs = if !ack then ("ack", "client") :: hs else hs in
  let hs = match !prefetch with
      n when n > 0 -> ("prefetch", string_of_int n) :: hs
    | _ -> hs in

  let finish = ref false in

  let run num_msgs =
    let c = S.connect ?login:!login ?passcode:!passcode ~eof_nl:!use_nl_eof
              (Unix.ADDR_INET (Unix.inet_addr_of_string !address, !port))
    in
      if !nthreads <= 1 then begin
        printf "Subscribing to %d destination(s)... %!" (List.length subs);
        if !verbose then printf "\n";
      end;
      List.iteri
        (fun i dst ->
           if !nthreads <= 1 && !verbose && i mod 10 = 0 then printf "%d         \r%!" i;
           S.subscribe ~headers:hs c dst)
        subs;
      if !nthreads <= 1 then printf "DONE             \n%!";
      (try
        for _i = 1 to num_msgs do
          if !finish then raise Exit;
          let msg = S.receive_msg c in
            incr cnt;
            payload := !payload + String.length msg.Mq.msg_body;
            if !cnt = 1 then t0 := Unix.gettimeofday ();
            if !ack then S.ack_msg c msg;
            if !verbose && !cnt mod 11 = 0 then printf "%d       \r%!" !cnt;
        done;
        S.disconnect c;
       with Exit -> ())
  in
    Sys.set_signal Sys.sigint
      (Sys.Signal_handle (fun _ -> print_endline "SIGINT"; finish := true; print_rate ()));
    begin match !nthreads with
        n when n <= 1 -> run !num_msgs
      | n ->
          let ts = List.init n (fun _ -> Thread.create run (!num_msgs / n)) in
            List.iter Thread.join ts
    end;
    print_rate ()
