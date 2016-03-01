(** {!Mq.GENERIC} STOMP protocol client.
  *
  * Note: don't execute multiple operations on a single connection
  * concurrently: neither the implementation nor the STOMP protocol support
  * concurrent operations (e.g., ERROR frames are not associated to a given
  * request, so we must assume they refer to the latest request).
  * Concurrent operations on different connections are fine.
  * *)
module Make_generic : functor (C : Mq_concurrency.THREAD) ->
sig
  include Mq.GENERIC with type 'a thread = 'a C.t
    and type connect_addr = Unix.sockaddr
end

module Make_comm : functor (C : Mq_concurrency.COMM) ->
sig
  include Mq.GENERIC with type 'a thread = 'a C.t
    and type connect_addr = C.conn
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

module Trace
  (C : Mq_concurrency.THREAD)
  (G : Mq.GENERIC with type 'a thread = 'a C.t)
  (Config : sig val enabled : bool ref val name : string end)
 : Mq.GENERIC with
     type 'a thread = 'a C.t
 and type connect_addr = G.connect_addr
 and type transaction = G.transaction
 and type receipt = G.receipt
