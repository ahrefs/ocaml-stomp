(** Functor [Make] can be used to create STOMP client that uses lwt_comm
    library.  It is useful to make ocamlmq + ocaml-stomp work in single
    binary.

    Make is parametrized by [LWT_COMM], part of signature of Lwt_comm module
    from lwt_comm library.

    Note: [Make(Lwt_comm).connect] has argument [?eof_nl], it is present for
    signature compatibility, and ignored by [connect].  [?eof_nl] determines
    framing rules on sockets.  Interprocess communications don't [de]serialize
    stomp frames and touch sockets at all, so argument is not used actually.
 *)

module type LWT_COMM =
sig
  type ('snd, 'rcv, 'kind) conn
  val send : ('snd, 'rcv, 'kind) conn -> 'snd -> unit Lwt.t
  val recv : ('snd, 'rcv, 'kind) conn -> 'rcv Lwt.t
  val close : ?exn:exn -> ('snd, 'rcv, 'kind) conn -> unit

  type ('snd, 'rcv, 'kind) server
  val connect :
    ?ack_req:bool -> ?ack_resp:bool ->
    ('req, 'resp, [> `Connect] as 'k) server ->
    ('req, 'resp, 'k) conn
end

module Make (C : LWT_COMM) : Mq.GENERIC
  with type 'a thread = 'a Lwt.t
   and type connect_addr =
    (Mq.stomp_frame, Mq.stomp_frame, [ `Bidi | `Connect ]) C.server
 =
struct

  module Comm = struct
    type 'a t = 'a Lwt.t
    let return = Lwt.return
    let ( >>= ) = Lwt.( >>= )
    let fail = Lwt.fail
    let catch = Lwt.catch
    open Mq
    type conn = (stomp_frame, stomp_frame, [ `Bidi | `Connect ]) C.conn
    let close c = C.close c; Lwt.return_unit
    let recv = C.recv
    let send = C.send
  end

  module Impl = Mq_stomp_client_gen.Make_comm'(Comm)

  include Impl

  type connect_addr =
    (Mq.stomp_frame, Mq.stomp_frame, [ `Bidi | `Connect ]) C.server

  let connect ?login ?passcode ?eof_nl ?headers server =
    ignore (eof_nl : bool option);
    let conn = C.connect ~ack_req:false ~ack_resp:false server in
    connect ?login ?passcode ?headers conn

end
