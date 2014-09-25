(** Functor [Make] can be used to create STOMP client that uses lwt_comm
    library.  It is useful to make ocamlmq + ocaml-stomp work in single
    binary.

    Make is parametrized by [LWT_COMM], part of signature of Lwt_comm module
    from lwt_comm library.
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

module Make (C : LWT_COMM) =
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

  module Impl = Mq_stomp_client.Make_comm(Comm)

  include Impl

  let connect ?login ?passcode ?headers server =
    let conn = C.connect ~ack_req:false ~ack_resp:false server in
    connect ?login ?passcode ?headers conn

end
