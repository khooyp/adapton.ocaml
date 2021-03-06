(** Self-Adjusting Machine.

    * Based on Yit's "SAC Library" implementation, from Adapton / PLDI 2014.

    * Adapted to perform destination-passing-style transformation,
      a la self-adjusting machines (OOPSLA 2011, Hammer's Diss 2012).

 **)

let debug = false

module type DataS = Data.S

exception Missing_nominal_features

(** Types and operations common to EagerTotalOrder thunks containing
    any type. *)
module T = struct
    (** Abstract type identifying this module. *)
    type atype

    (** EagerTotalOrder thunks containing ['a]. *)
    type 'a thunk = { (* 3 + 16 = 19 words *)
        id : int;
        mutable value : 'a;
        meta : meta;
    }
    (**/**) (* auxiliary types *)
   and meta = { (* 5 + 5 + 5 = 15 words (not including closures of evaluate and unmemo as well as WeakDyn.t) *)
        mid : int;
        mutable enqueued : bool;
        mutable onstack : bool;
        mutable evaluate : unit -> unit;
        mutable unmemo : unit -> unit;
        mutable start_timestamp : TotalOrder.t; (* for const thunks, {start,end}_timestamp == TotalOrder.null and evaluate == nop *)
        mutable end_timestamp : TotalOrder.t; (* while evaluating non-const thunk, end_timestamp == TotalOrder.null *)
        dependents : meta WeakDyn.t;
        (* dependents doesn't have to be a set since it is cleared and
           dependents are immediately re-evaluated and re-added if
           updated; also, start_timestamp invalidators should provide
           strong references to dependencies to prevent the GC from
           breaking the dependents graph *)
    }
    (**/**)


    (** This module implements incremental thunks. *)
    let is_incremental = true

    (** This module implements eager values. *)
    let is_lazy = false


    (**/**) (* internal state and helper functions *)

    (* use a priority set because, although the size is usually quite small, duplicate insertions occur frequently *)
    module PriorityQueue = PrioritySet.Make (struct
        type t = meta
        let compare meta meta' = TotalOrder.compare meta.start_timestamp meta'.start_timestamp
    end)

    let eager_id_counter = Types.Counter.make 0
    let eager_name_counter = Types.Counter.make 0
    let eager_stack = ref []
    let eager_queue = PriorityQueue.create ()
    let eager_start = TotalOrder.create ()
    let eager_now = ref eager_start
    let eager_finger = ref eager_start

    let add_timestamp () =
        let timestamp = TotalOrder.add_next !eager_now in
        (if debug then Printf.printf "... add_timestamp: %d\n%!" (TotalOrder.id timestamp));
        eager_now := timestamp;
        timestamp

    let unqueue meta =
        if PriorityQueue.remove eager_queue meta then
            incr Statistics.Counts.clean

    let dequeue () =
      let m = PriorityQueue.pop eager_queue in
      assert( m.enqueued );
      assert( not m.onstack );
      m.enqueued <- false;
      m

    let enqueue_dependents dependents =
      WeakDyn.fold (
          fun d () ->
          if TotalOrder.is_valid d.start_timestamp then (
            if d.enqueued then
              (if debug then Printf.printf "... already enqueued: dependent %d\n%!" (TotalOrder.id d.start_timestamp))
            else if d.onstack then
              (if debug then Printf.printf "... already on stack: dependent %d\n%!" (TotalOrder.id d.start_timestamp))
            else (
              (if debug then Printf.printf "... enqueuing dependent %d\n%!" (TotalOrder.id d.start_timestamp)) ;
              d.enqueued <- true ;
              assert (not d.onstack) ;
              if PriorityQueue.add eager_queue d then
                incr Statistics.Counts.dirty
            ))) dependents ()
      (* WeakDyn.clear dependents (* XXX *) (* ??? *) *)

    (**/**)


    (** Return the id of an EagerTotalOrder thunk. *)
    let id m = (Some m.id)

    (** Compute the hash value of an EagerTotalOrder thunk. *)
    let hash seed m = Hashtbl.seeded_hash seed m.id
    let compare t t' = compare (hash 42 t) (hash 42 t')

    (** Compute whether two EagerTotalOrder thunks are equal. *)
    let equal = (==)

    (** Debugging string *)
    let show m = "&"^(string_of_int m.id)
    let pp ff p = Format.pp_print_string ff (show p)

    let sanitize m = m

    (** Recompute EagerTotalOrder thunks if necessary. *)
    let refresh_until end_time =
        let rec refresh () =
          match PriorityQueue.top eager_queue with
          | None -> ()
          | Some next -> (
            if TotalOrder.is_valid next.start_timestamp then (
              if (match end_time with
                    None -> true |
                    Some end_time -> TotalOrder.compare next.end_timestamp end_time <= 0 )
              then (
                let meta = dequeue () in
                assert ( match end_time with | None -> true | Some end_time -> TotalOrder.compare meta.end_timestamp end_time <= 0 ) ;
                eager_now := meta.start_timestamp;
                eager_finger := meta.end_timestamp;
                meta.evaluate ();
                TotalOrder.splice ~db:"refresh_until" !eager_now meta.end_timestamp;
                refresh ()
              )
              else (
                (if debug then Printf.printf "... WARNING: refresh is stopping with non-empty queue. Top is: (%d, %d)\n%!"
                                             (TotalOrder.id next.start_timestamp) (TotalOrder.id next.end_timestamp))
              ))
            else (
              (if debug then Printf.printf "... WARNING: XXX refresh is skipping invalid timestamp.\n%!") ;
              let meta = dequeue () in
              assert( not (TotalOrder.is_valid meta.start_timestamp) );
            ))
        in
        let old_finger = !eager_finger in
        refresh () ;
        eager_finger := old_finger

    (** Recompute EagerTotalOrder thunks if necessary. *)
    let refresh () =
        let condition = debug && (PriorityQueue.top eager_queue <> None) in
        if condition then Printf.printf ">>> BEGIN: global refresh:\n%!" ;
        if condition then (TotalOrder.iter eager_start (fun ts -> Printf.printf "... iter-dump: %d\n%!" (TotalOrder.id ts)));
        let last_now = !eager_now in
        (
          try
            (refresh_until None)
          with PriorityQueue.Empty ->
            eager_now := last_now;
            eager_finger := eager_start
        );
        if condition then Printf.printf "<<< END: global refresh.\n%!"

    let flush () = () (* Flushing is a no-op here: Flushing happens internally during change propagation. *)

    let make_dependency_edge m =
      (* add dependency to caller *)
      match !eager_stack with
      | dependent::_ -> WeakDyn.add m.meta.dependents dependent
      | [] ->
         (* Force is occuring at the outer layer. *)
         (* Make sure that this value is up to date! *)
         (* refresh () *) (* XXX *)
         ()

    let viznode _ = failwith "viznode: not implemented"
end
include T

module Eviction = struct
  let flush () = ()
  let set_policy p = ()
  let set_limit n = ()
end

(** Functor to make constructors and updaters for EagerTotalOrder thunks of a specific type. *)
module MakeArt (Name : Name.S) (Data : Data.S)
  : Art.S with type name = Name.t
           and type data = Data.t =
struct

  include T

  type name = Name.t
  (** Value contained by EagerTotalOrder thunks for a specific type. *)
  type data = Data.t

  (** EagerTotalOrder thunks for a specific type. *)
  type t = Data.t thunk

  (**/**) (* helper functions *)

  let nop () = ()

  let invalidator meta ts =
    (* help GC mark phase by cutting the object graph *)
    (* no need to call unmemo since the memo entry will be replaced when
       it sees start_timestamp is invalid; also, no need to replace
       {start,end}_timestamp with null since they are already cut by
       TotalOrder during invalidation *)
    (if debug then Printf.printf "... marked invalid: %d\n%!" (TotalOrder.id ts));
    meta.unmemo <- nop;
    meta.evaluate <- nop;
    unqueue meta;
    WeakDyn.clear meta.dependents

  let update m x =
    if not (Data.equal m.value x) then
      begin
        (if debug then Printf.printf "... update: ** CHANGED: #%d (%d,%d) **\n%!"
             m.id (TotalOrder.id m.meta.start_timestamp) (TotalOrder.id m.meta.end_timestamp));
        m.value <- x;
        enqueue_dependents m.meta.dependents
      end
    else
      (if debug then Printf.printf "... update: ** SAME: #%d (%d,%d) **\n%!"
           m.id (TotalOrder.id m.meta.start_timestamp) (TotalOrder.id m.meta.end_timestamp))

  (** Create an EagerTotalOrder thunk from a constant value. *)
  let const x =
    incr Statistics.Counts.create;
    let id = Types.Counter.next eager_id_counter in
    let m = {
      id=id;
      value=x;
      meta={
        mid=id;
        enqueued=false;
        onstack=false;
        evaluate=nop;
        unmemo=nop;
        start_timestamp=TotalOrder.null;
        end_timestamp=TotalOrder.null;
        dependents=WeakDyn.create 0;
      };
    } in
    m

  (** Update an EagerTotalOrder thunk with a constant value. *)
  let update_cell m x =
    incr Statistics.Counts.update;
    assert (m.meta.start_timestamp == TotalOrder.null) ;
    update m x

  let evaluate_meta meta f =
    incr Statistics.Counts.evaluate;
    eager_stack := meta::!eager_stack;
    meta.onstack <- true ;
    let value = try
        (if debug then Printf.printf "... BEGIN -- evaluate_meta: &%d @ (%d,%d):\n%!"
             meta.mid (TotalOrder.id meta.start_timestamp) (TotalOrder.id meta.end_timestamp));
        let res = f () in
        (if debug then Printf.printf "... END -- evaluate_meta: &%d @ (%d,%d).\n%!"
             meta.mid (TotalOrder.id meta.start_timestamp) (TotalOrder.id meta.end_timestamp)) ;
        res
      with exn ->
        eager_stack := List.tl !eager_stack;
        meta.onstack <- false ;
        raise exn
    in
    eager_stack := List.tl !eager_stack;
    meta.onstack <- false ;
    value

  let make_evaluate m f =
    fun () -> update m (evaluate_meta m.meta f)

  let cell nm v = const v (* TODO: Use the name; workaround: use mfn_nart interface instead. *)
  let set m v =
    (if debug then Printf.printf "... SET\n") ;
    update_cell m v

  let make_and_eval_node f =
    incr Statistics.Counts.create;
    let id = Types.Counter.next eager_id_counter in
    let meta = {
      mid=id;
      enqueued=false;
      onstack=false;
      evaluate=nop;
      unmemo=nop;
      start_timestamp=add_timestamp ();
      end_timestamp=TotalOrder.null;
      dependents=WeakDyn.create 0;
    } in
    let v = evaluate_meta meta f in
    let m = { id=id; value=v; meta } in
    meta.end_timestamp <- add_timestamp ();
    TotalOrder.set_invalidator meta.start_timestamp (invalidator meta);
    meta.evaluate <- make_evaluate m f;
    m

  let thunk nm f =
    (* TODO: Use the name; workaround: use mfn_nart interface instead. *)  
    make_and_eval_node f 

  (** Return the value contained by an EagerTotalOrder thunk, computing it if necessary. *)
  let force m =
    make_dependency_edge m ;
    (if debug then
       Printf.printf "... FORCE: %d --> %s\n%!"
         m.id
         (Data.show m.value)) ;
    m.value

  type 'arg mfn = { mfn_data : 'arg -> Data.t ;      (* Pure recursion. *)
                    mfn_art  : 'arg -> t ;           (* Create a memoized articulation, classically. *)
                    mfn_nart : Name.t -> 'arg -> t ; (* Create a memoized articulation, nominally. *) }

  let mk_mfn (type a)
      _
      (module Arg : DataS with type t = a)
      (user_function: Arg.t mfn -> Arg.t -> data)
    : Arg.t mfn =
    let rec mfn =
      (* create memoizing constructors *)
      let module Memo = struct
        type data = Data.t
        type t = Data.t thunk

        (** Create memoizing constructor for an EagerTotalOrder thunk. *)
        module Binding = struct

          type key =
            | Arg of Arg.t
            | Name of Name.t

          type node = {
            arg : Arg.t ref ;
            thunk : Data.t thunk ;
          }

          type t = { key : key ;
                     mutable nodes : node list ;
                   }

          let seed = Random.bits ()

          let hash a =
            match a.key with
            | Arg arg -> Arg.hash seed arg
            | Name name -> Name.hash seed name

          let equal a b = match a.key, b.key with
            | Arg a, Arg b -> Arg.equal a b
            | Name n, Name m -> Name.equal n m
            | _ -> false
        end
        module Table = Weak.Make (Binding)
        let table = Table.create 0
      end
      in


      let is_available m =
        TotalOrder.is_valid m.meta.start_timestamp
        && TotalOrder.compare m.meta.start_timestamp !eager_now > 0
        && TotalOrder.compare m.meta.end_timestamp !eager_finger < 0
      in


      let do_fresh_binding binding arg =
        (* note that m.meta.unmemo indirectly holds a reference to binding (via unmemo's closure);
                            this prevents the GC from collecting binding from Memo.table until m itself is collected *)
        incr Statistics.Counts.create;
        incr Statistics.Counts.miss;
        (* let m = make_node (fun () -> user_function mfn (!(binding.Memo.Binding.arg)) ) in *)
        let ref_arg = ref arg in
        let m = 
          make_and_eval_node
            (fun () ->
               let res = user_function mfn ( ! ref_arg ) in
               (if debug then
                  Printf.printf "... Computed Result=`%s'.\n%!"
                    (Data.show res)) ;
               res)
        in
        let node = Memo.Binding.({ arg = ref_arg ; thunk = m; }) in
        m.meta.unmemo <- (fun () ->
            binding.Memo.Binding.nodes <-
              List.filter (fun x -> not (x.Memo.Binding.thunk == m))
                binding.Memo.Binding.nodes) ;
        binding.Memo.Binding.nodes <- (node :: binding.Memo.Binding.nodes) ;
        make_dependency_edge m;
        m
      in

      let refresh_same_arg m =
        incr Statistics.Counts.hit;
        TotalOrder.splice ~db:"memo" !eager_now m.meta.start_timestamp;
        (if debug then Printf.printf "... --  BEGIN -- refresh_until: match &%d (Same arg)\n%!" m.meta.mid);
        refresh_until (Some m.meta.end_timestamp);
        eager_now := m.meta.end_timestamp;
        (if debug then Printf.printf "... --  END   -- refresh_until: match &%d (Same arg)\n%!" m.meta.mid) ;
        make_dependency_edge m
      in

      (* memoizing constructor *)
      let rec memo cur_arg =        
        let binding = Memo.Table.merge Memo.table Memo.Binding.({ key=Arg cur_arg; nodes=[] }) in
        let rec loop nodes =
          match nodes with
          | [] -> (do_fresh_binding binding cur_arg)
          | node::nodes ->
            if is_available node.Memo.Binding.thunk then (
              refresh_same_arg node.Memo.Binding.thunk;
              node.Memo.Binding.thunk
            )
            else loop nodes
        in loop binding.Memo.Binding.nodes
      in

      (* memoizing constructor *)
      let rec memo_name name cur_arg =
        let binding = Memo.Binding.({ key=Name name; nodes=[] }) in
        let binding = Memo.Table.merge Memo.table binding in
        let rec loop nodes = match nodes with
          | [] -> do_fresh_binding binding cur_arg
          | node::nodes ->
            if not (is_available node.Memo.Binding.thunk) then
              loop nodes
            else (
              if Arg.equal cur_arg (!(node.Memo.Binding.arg)) then (
                refresh_same_arg node.Memo.Binding.thunk;
                node.Memo.Binding.thunk
              )
              else (
                let m = node.Memo.Binding.thunk in
                (if debug then Printf.printf "...   memo_name: match (Diff arg): (%d, %d) -- `%s' (old) != `%s' (new)\n%!"
                     (TotalOrder.id m.meta.start_timestamp) (TotalOrder.id m.meta.end_timestamp)
                     (Arg.show !(node.Memo.Binding.arg)) (Arg.show cur_arg)) ;
                (if debug then Printf.printf "... ** BEGIN -- memo_name: match (Diff arg)\n%!") ;
                TotalOrder.splice ~db:"memo_name: Diff arg: #1" !eager_now m.meta.start_timestamp;
                eager_now := m.meta.start_timestamp;
                let old_finger = !eager_finger in
                assert( TotalOrder.compare m.meta.end_timestamp old_finger < 0 );
                eager_finger := m.meta.end_timestamp;
                node.Memo.Binding.arg := cur_arg ;
                m.meta.evaluate ();
                assert( TotalOrder.compare m.meta.start_timestamp !eager_now <= 0 );
                assert( TotalOrder.compare !eager_now   m.meta.end_timestamp <  0 );
                (if debug then Printf.printf "... Start: splice (%d, %d)\n%!" (TotalOrder.id !eager_now) (TotalOrder.id m.meta.end_timestamp));
                TotalOrder.splice ~db:"memo_name: Diff arg: #2" !eager_now m.meta.end_timestamp;
                (if debug then Printf.printf "... End: splice (%d, %d)\n%!" (TotalOrder.id !eager_now) (TotalOrder.id m.meta.end_timestamp));
                eager_finger := old_finger;
                (if debug then Printf.printf "... ** END   -- memo_name: match (Diff arg)\n%!") ;
                assert ( TotalOrder.is_valid m.meta.start_timestamp ) ;
                assert ( TotalOrder.is_valid m.meta.end_timestamp ) ;
                eager_now := m.meta.end_timestamp;
                make_dependency_edge m;
                m
              )
            )
        in loop binding.Memo.Binding.nodes
      in
      (* incr Statistics.Counts.evaluate;  *)
      {
        mfn_data = (fun arg -> user_function mfn arg) ;
        mfn_art  = (fun arg -> memo arg) ;
        mfn_nart = (fun name arg -> memo_name name arg) ;
      }
    in mfn


end

(*
(** Tweak GC for this module. *)
let tweak_gc () =
  let open Gc in
  let control = get () in
  set { control with
        minor_heap_size = max control.minor_heap_size (2 * 1024 * 1024);
        major_heap_increment = max control.minor_heap_size (4 * 1024 * 1024);
      }

 *)
