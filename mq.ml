(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)
(** Message queue (MQ): message and error type definitions, module types. *)

(** Type of received messages. *)
type received_msg = {
  msg_id : string;
  msg_destination : string;
  msg_headers : (string * string) list;
  msg_body : string
}

(** Type of STOMP frame. *)
type stomp_frame = (string * (string * string) list * string)

let string_of_headers hs =
  "[" ^
  String.concat "; " (List.map (fun (k, v) -> Printf.sprintf "%S:%S" k v) hs) ^
  "]"

let string_of_stomp_frame (cmd, headers, body) =
  Printf.sprintf "frame(%S %s %S)"
    cmd (string_of_headers headers) body

(** {3 Errors } *)

(** Suggested error recovery strategy. *)
type restartable = Retry | Reconnect | Abort

let string_of_restartable = function
  | Retry -> "Retry"
  | Reconnect -> "Reconnect"
  | Abort -> "Abort"

(* Type of connection error. *)
type connection_error = Access_refused | Connection_refused | Closed

let string_of_connection_error = function
  | Access_refused -> "Access_refused"
  | Connection_refused -> "Connection_refused"
  | Closed -> "Closed"

type message_queue_error =
    Connection_error of connection_error
  | Protocol_error of stomp_frame

let string_of_message_queue_error = function
  | Connection_error e -> "Connection_error " ^ string_of_connection_error e
  | Protocol_error f -> "Protocol_error " ^ string_of_stomp_frame f

(* Exception raised by MQ client operations. *)
exception Message_queue_error of restartable * string * message_queue_error

let () = Printexc.register_printer begin function
  | Message_queue_error (r, p, e) -> Some begin
      Printf.sprintf "Mq.Message_queue_error(%s, %S, %s)"
        (string_of_restartable r) p (string_of_message_queue_error e)
    end
  | _ -> None
end

(** {3 Module types} *)

(** Base MQ module. *)
module type BASE =
sig
  type 'a thread
  type connection
  type transaction

  val transaction_begin : connection -> transaction thread
  val transaction_commit : connection -> transaction -> unit thread
  val transaction_commit_all : connection -> unit thread
  val transaction_abort_all : connection -> unit thread
  val transaction_abort : connection -> transaction -> unit thread

  val receive_msg : connection -> received_msg thread

  (** Acknowledge the reception of a message. *)
  val ack_msg : connection -> ?transaction:transaction -> received_msg -> unit thread

  (** Acknowledge the reception of a message using its message-id. *)
  val ack : connection -> ?transaction:transaction -> string -> unit thread

  val disconnect : connection -> unit thread
end

(** Generic, low-level MQ module, accepting custom headers for the operations
  * not included in {!BASE}. *)
module type GENERIC =
sig
  include BASE

  type connect_addr

  val connect : ?login:string -> ?passcode:string -> ?eof_nl:bool ->
    ?headers:(string * string) list -> connect_addr -> connection thread
  val send : connection -> ?transaction:transaction -> ?persistent:bool ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread
  val send_no_ack : connection -> ?transaction:transaction -> ?persistent:bool ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread

  val subscribe : connection -> ?headers:(string * string) list -> string -> unit thread
  val unsubscribe : connection -> ?headers:(string * string) list -> string -> unit thread

  (** [expect_receipt conn rid] notifies that receipts whose receipt-id is
    * [rid] are to be stored and will be consumed with [receive_receipt]. *)
  val expect_receipt : connection -> string -> unit

  type receipt = {
    r_headers : (string * string) list;
    r_body : string;
  }

  (** [receive_receipt conn rid] blocks until a RECEIPT with the given
    * receipt-id is received. You must use [expect_receipt] before, or the
    * RECEIPT might be discarded (resulting in receive_receipt blocking
    * forever). If an error occurs, the RECEIPT will be discarded if received
    * at any later point in time. (This is meant to prevent memleaks.) *)
  val receive_receipt : connection -> string -> receipt thread

  (** Return a unique receipt id. *)
  val receipt_id : unit -> string
  (** Return a unique transaction id. *)
  val transaction_id : unit -> string
end

(** Higher-level message queue, with queue and topic abstractions. *)
module type HIGH_LEVEL =
sig
  include BASE

  val connect :
    ?prefetch:int -> login:string -> passcode:string -> Unix.sockaddr ->
    connection thread

  (** Send and wait for ACK. *)
  val send : connection -> ?transaction:transaction ->
    ?ack_timeout:float -> destination:string -> string -> unit thread

  (** Send without waiting for confirmation. *)
  val send_no_ack : connection -> ?transaction:transaction ->
    ?ack_timeout:float -> destination:string -> string -> unit thread

  (** Send to a topic and wait for ACK *)
  val topic_send : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  (** Send to a topic without waiting for confirmation. *)
  val topic_send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  (** [create queue conn name] creates a persistent queue named [name].
    * Messages sent to will persist. *)
  val create_queue : connection -> string -> unit thread
  val subscribe_queue : connection -> ?auto_delete:bool -> string -> unit thread
  val unsubscribe_queue : connection -> string -> unit thread
  val subscribe_topic : connection -> string -> unit thread
  val unsubscribe_topic : connection -> string -> unit thread

  val queue_size : connection -> string -> Int64.t option thread
  val queue_subscribers : connection -> string -> int option thread
  val topic_subscribers : connection -> string -> int option thread
end
