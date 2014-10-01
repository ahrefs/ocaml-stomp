(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)
open ExtString
open Mq

module Make_comm'(M : Mq_concurrency.COMM) =
struct
  module S = Set.Make(String)
  open M

  type 'a thread = 'a M.t
  type transaction = string

  type receipt = {
    r_headers : (string * string) list;
    r_body : string;
  }

  type connection = {
    conn : conn;
    mutable c_closed : bool;
    mutable c_transactions : S.t;
    c_eof_nl : bool;
    c_pending_msgs : received_msg Queue.t;
    mutable c_expected_receipts : S.t;
    c_pending_receipts : (string, receipt) Hashtbl.t;
  }

  let error restartable err fmt =
    Printf.kprintf (fun s -> fail (Message_queue_error (restartable, s, err))) fmt

  let receipt_id =
    let i = ref 1 in fun () -> incr i; Printf.sprintf "receipt-%d" !i

  let transaction_id =
    let i = ref 1 in fun () -> incr i; Printf.sprintf "transaction-%d" !i

  let send_frame' msg conn frame =
    catch
      (fun () ->
         send conn.conn frame
      )
      (* FIXME: handle errors besides Sys_error differenty? *)
      (fun _ -> error Reconnect (Connection_error Closed) "Mq_stomp_client.%s" msg)

  let send_frame msg conn command headers body =
    let rid = receipt_id () in
    let headers = ("receipt", rid) :: headers in
      send_frame' msg conn (command, headers, body) >>= fun () ->
      return rid

  let send_frame_clength msg conn command headers body =
    send_frame msg conn command
      (("content-length", string_of_int (String.length body)) :: headers) body

  let send_frame_clength' msg conn command headers body =
    send_frame' msg conn
      ( command,
        (("content-length", string_of_int (String.length body)) :: headers),
        body
      )

  let receive_frame conn =
    recv conn.conn

  (* add EOF handling *)
  let receive_frame msg conn =
    catch
      (fun () -> receive_frame conn)
      (function
           Sys_error _ | End_of_file ->
               error Reconnect (Connection_error Closed) "Mq_stomp_client.%s" msg
         | e -> fail e)

  let rec receive_non_message_frame msg conn =
    receive_frame msg conn >>= function
        ("MESSAGE", hs, body) ->
          begin
            try
              Queue.add
                { msg_id = List.assoc "message-id" hs;
                  msg_destination = List.assoc "destination" hs;
                  msg_headers = hs; msg_body = body }
                conn.c_pending_msgs
            with Not_found -> (* no message-id or destination, ignore *) ()
          end;
          receive_non_message_frame msg conn
      | frame -> return frame

  let header_is k v l =
    try
      List.assoc k l = v
    with Not_found -> false

  let connect ?login ?passcode ?(eof_nl = true) ?(headers = []) c =
    let conn =
      { conn = c; c_closed = false; c_transactions = S.empty;
        c_eof_nl = eof_nl; c_pending_msgs = Queue.create ();
        c_expected_receipts = S.empty; c_pending_receipts = Hashtbl.create 13;
      }
    in
    let headers = match login, passcode with
        None, None -> headers
      | _ -> ("login", Option.default "" login) ::
             ("passcode", Option.default "" passcode) :: headers in
    send_frame' "connect" conn ("CONNECT", headers, "") >>= fun () ->
    receive_non_message_frame "connect" conn >>= function
        ("CONNECTED", _, _) -> return conn
      | ("ERROR", hs, _) when header_is "message" "access_refused" hs ->
          error Abort (Connection_error Access_refused) "Mq_stomp_client.connect"
      | t  -> error Reconnect (Protocol_error t) "Mq_stomp_client.connect"

  let disconnect conn =
    if conn.c_closed then return ()
    else
      catch
        (fun () ->
           send_frame' "disconnect" conn ("DISCONNECT", [], "") >>= fun () ->
           close conn.conn >>= fun () ->
           conn.c_closed <- true;
           return ())
        (function
             (* if there's a connection error, such as the other end closing
              * before us, ignore it, as we wanted to close the conn anyway *)
             Message_queue_error (_, _, mqe) as e -> begin
               match mqe with
               | Connection_error _ -> return ()
               | Protocol_error _ -> fail e
             end
           | e -> fail e)

  let check_closed msg conn =
    if conn.c_closed then
      error Reconnect (Connection_error Closed)
        "Mq_stomp_client.%s: closed connection" msg
    else return ()

  let transaction_header = function
      None -> []
    | Some t -> ["transaction", t]

  let rec get_receipt msg conn rid =
    receive_non_message_frame msg conn >>= function
        ("RECEIPT", hs, body) when header_is "receipt-id" rid hs ->
          conn.c_expected_receipts <- S.remove rid conn.c_expected_receipts;
          return { r_headers = hs; r_body = body }
      | ("RECEIPT", hs, body) ->
          Option.may
            (fun id ->
               if S.mem id conn.c_expected_receipts then
                 Hashtbl.replace conn.c_pending_receipts id
                   { r_headers = hs; r_body = body })
            (try Some (List.assoc "receipt-id" hs) with Not_found -> None);
          get_receipt msg conn rid
      | t ->
         error Reconnect (Protocol_error t) "Mq_stomp_client.%s: no RECEIPT received." msg

  let check_receipt msg conn rid =
    get_receipt msg conn rid >>= fun _receipt ->
    return ()

  let send_frame_with_receipt msg conn command hs body =
    check_closed msg conn >>= fun () ->
    send_frame msg conn command hs body >>= check_receipt msg conn

  let send_frame_without_receipt msg conn command hs body =
    check_closed msg conn >>= fun () ->
    send_frame' msg conn (command, hs, body)

  let send_headers transaction persistent destination =
    ("destination", destination) :: ("persistent", string_of_bool persistent) ::
    transaction_header transaction

  let send_no_ack conn
        ?transaction ?(persistent = true) ~destination ?(headers = []) body =
    check_closed "send_no_ack" conn >>= fun () ->
    let headers = headers @ send_headers transaction persistent destination in
    send_frame_clength' "send_no_ack" conn "SEND" headers body

  let send conn ?transaction ?(persistent = true) ~destination ?(headers = []) body =
    check_closed "send" conn >>= fun () ->
    let headers = headers @ send_headers transaction persistent destination in
      (* if given a transaction ID, don't try to get RECEIPT --- the message
       * will only be saved on COMMIT anyway *)
      match transaction with
          None ->
            send_frame_clength "send" conn "SEND" headers body >>=
            check_receipt "send" conn
        | _ ->
            send_frame_clength' "send" conn "SEND" headers body

  let rec receive_msg conn =
    check_closed "receive_msg" conn >>= fun () ->
    try
      return (Queue.take conn.c_pending_msgs)
    with Queue.Empty ->
      receive_frame "receive_msg" conn >>= function
          ("MESSAGE", hs, body) as t -> begin
            try
              return { msg_id = List.assoc "message-id" hs;
                       msg_destination = List.assoc "destination" hs;
                       msg_headers = hs;
                       msg_body = body; }
            with Not_found ->
              error Retry (Protocol_error t)
                "Mq_stomp_client.receive_msg: no message-id or destination."
          end
        | _ -> receive_msg conn (* try to get another frame *)

  let ack_msg conn ?transaction msg =
    let headers = ("message-id", msg.msg_id) :: transaction_header transaction in
    send_frame_with_receipt "ack_msg" conn "ACK" headers ""

  let ack conn ?transaction msgid =
    let headers = ("message-id", msgid) :: transaction_header transaction in
    send_frame_with_receipt "ack" conn "ACK" headers ""

  let subscribe conn ?(headers = []) s =
    send_frame_without_receipt "subscribe" conn
      "SUBSCRIBE" (headers @ ["destination", s]) ""

  let unsubscribe conn ?(headers = []) s =
    send_frame_without_receipt "subscribe" conn "UNSUBSCRIBE" (headers @ ["destination", s]) ""

  let transaction_begin conn =
    let tid = transaction_id () in
    send_frame_with_receipt "transaction_begin" conn
      "BEGIN" ["transaction", tid] "" >>= fun () ->
        conn.c_transactions <- S.add tid (conn.c_transactions);
        return tid

  let transaction_commit conn tid =
    send_frame_with_receipt "transaction_commit" conn
      "COMMIT" ["transaction", tid] "" >>= fun () ->
    conn.c_transactions <- S.remove tid (conn.c_transactions);
    return ()

  let transaction_abort conn tid =
    send_frame_with_receipt "transaction_abort" conn
      "ABORT" ["transaction", tid] "" >>= fun () ->
    conn.c_transactions <- S.remove tid (conn.c_transactions);
    return ()

  let transaction_for_all f conn =
    let rec loop s =
      let next =
        try
          let tid = S.min_elt s in
            f conn tid >>= fun () ->
            return (Some conn.c_transactions)
        with Not_found -> (* empty *)
          return None
      in next >>= function None -> return () | Some s -> loop s
    in loop conn.c_transactions

  let transaction_commit_all = transaction_for_all transaction_commit
  let transaction_abort_all = transaction_for_all transaction_abort

  let expect_receipt conn rid =
    conn.c_expected_receipts <- S.add rid conn.c_expected_receipts

  let receive_receipt conn rid =
    try
      let r = Hashtbl.find conn.c_pending_receipts rid in
        Hashtbl.remove conn.c_pending_receipts rid;
        return r
    with Not_found ->
      catch
        (fun () -> get_receipt "receive_receipt" conn rid)
        (fun e -> Hashtbl.remove conn.c_pending_receipts rid; raise e)
end
