(** Fipoint iterator *)

(** external signature of the module *)
module type T =
  sig
    type domain
    module Cfa:
    sig
      type t
      module State:
      sig
	(** data type for the decoding context *)
	  type ctx_t = {
	      addr_sz: int; (** size in bits of the addresses *)
	      op_sz  : int; (** size in bits of operands *)
	    }

	  (** abstract data type of a state *)
	  type t = {
	      id: int; 	     		    (** unique identificator of the state *)
	      mutable ip: Data.Address.t;   (** instruction pointer *)
	      mutable v: domain; 	    (** abstract value *)
	      mutable ctx: ctx_t ; 	    (** context of decoding *)
	      mutable stmts: Asm.stmt list; (** list of statements of the succesor state *)
	      mutable final: bool;          (** true whenever a widening operator has been applied to the v field *)
	      mutable back_loop: bool; (** true whenever the state belongs to a loop that is backward analysed *)
	      mutable branch: bool option; (** None is for unconditional predecessor. Some true if the predecessor is a If-statement for which the true branch has been taken. Some false if the false branch has been taken *)
	      mutable bytes: char list      (** corresponding list of bytes *)
	    }
      end
      val init: Data.Address.t -> State.t
      val create: unit -> t
      val add_vertex: t -> State.t -> unit
      val print: string -> string -> t -> unit
      val unmarshal: string -> t
      val marshal: string -> t -> unit
      val init_abstract_value: unit -> domain
      val last_addr: t -> Data.Address.t -> State.t
    end
    val forward_bin: Code.t -> Cfa.t -> Cfa.State.t -> (Cfa.t -> unit) -> Cfa.t
    val forward_cfa: Cfa.t -> Cfa.State.t -> (Cfa.t -> unit) -> Cfa.t 
    val backward: Cfa.t -> Cfa.State.t -> (Cfa.t -> unit) -> Cfa.t
  end
    
module Make(D: Domain.T): (T with type domain = D.t) =
  struct

    type domain = D.t
		    
    (** Decoder *)
    module Decoder = Decoder.Make(D)
				 
    (** Control Flow Automaton *)
    module Cfa = Decoder.Cfa 
			      
    open Asm
	    				    
    (* Hash table to know when a widening has to be processed, that is when the associated value reaches the threshold Config.unroll *)
    let unroll_tbl: (Data.Address.t, int * D.t) Hashtbl.t = Hashtbl.create 10

    (*let default_ctx () = {
        Cfa.State.op_sz = !Config.operand_sz; 
        Cfa.State.addr_sz = !Config.address_sz;
      }*)
			   
    (** opposite the given comparison operator *)
    let inv_cmp cmp =
      match cmp with
      | EQ  -> NEQ
      | NEQ -> EQ
      | LT  -> GEQ
      | GEQ -> LT
      | LEQ -> GT
      | GT  -> LEQ
		 
    let restrict d e b =
      let rec process e b =
        match e with
        | BConst b' 		  -> if b = b' then d else D.bot
        | BUnOp (LogNot, e) 	  -> process e (not b)
					     
        | BBinOp (LogOr, e1, e2)  ->
           let v1 = process e1 b in
           let v2 = process e2 b in
           if b then D.join v1 v2
           else D.meet v1 v2
		       
        | BBinOp (LogAnd, e1, e2) ->
           let v1 = process e1 b in
           let v2 = process e2 b in
           if b then D.meet v1 v2
           else D.join v1 v2
		       
        | Asm.Cmp (cmp, e1, e2)   ->
           let cmp' = if b then cmp else inv_cmp cmp in
           D.compare d e1 cmp' e2
      in
      process e b

	      		   
    (** widen the given vertex with all previous vertices that have the same ip as v *)
    let widen v jd =
      let join_vd = D.join jd v.Cfa.State.v in
      v.Cfa.State.final <- true;
      v.Cfa.State.v <- D.widen jd join_vd
			       
			       
    (** update the abstract value field of the given vertices wrt to their list of statements and the abstract value of their predecessor *)
    (** the widening may be also launched if the threshold is reached *)
    let update_abstract_values g v ip process_stmts =
      try
        let l = process_stmts g v ip in
        List.iter (fun v ->
            let n, jd =
              try
		let n', jd' = Hashtbl.find unroll_tbl ip in
		let d' = D.join jd' v.Cfa.State.v in
		Hashtbl.replace unroll_tbl ip (n'+1, d'); n', d'
              with Not_found ->
		Hashtbl.add unroll_tbl v.Cfa.State.ip (1, v.Cfa.State.v);
		1, v.Cfa.State.v
            in
            if n <= !Config.unroll then
              ()
            else 
              widen v jd
          ) l;
        List.fold_left (fun l' v -> if D.is_bot v.Cfa.State.v then
                                      begin
					Log.from_analysis (Printf.sprintf "unreachable state at address %s" (Data.Address.to_string ip));
					Cfa.remove_state g v; l'
                                      end
				    else v::l') [] l (* TODO: optimize by avoiding creating a state then removing it if its abstract value is bot *)
      with Exceptions.Empty -> Log.from_analysis (Printf.sprintf "No more reachable states from %s\n" (Data.Address.to_string ip)); []
								
 
    (*************************** Forward from binary file ************************)
    (*****************************************************************************)
    let apply_tainting _rules d = d (* TODO apply rules of type Config.tainting_fun *)
    let check_tainting _f _a _d = () (* TODO check both in Config.assert_untainted_functions and Config.assert_tainted_functions *)
				    
    let process_ret fun_stack v =
      let d = v.Cfa.State.v in
      let d', ipstack =
        try
          let f, ipstack = List.hd !fun_stack in
          fun_stack := List.tl !fun_stack;	
          (* check and apply tainting rules *)
          match f with
          | Some (libname, fname) -> (* function library: try to apply tainting rules from config *)
             begin
               try
                 let rules =
                   let funs = Hashtbl.find Config.tainting_tbl libname in
                   fst (List.find (fun v -> String.compare (fst v) fname = 0) funs)
                 in
                 let d' = apply_tainting rules d in
                 check_tainting f ipstack d';
                 d', Some ipstack
               with
               | Not_found -> d, Some ipstack
             end
          | None -> (* internal functions: tainting rules from control flow and data flow are directly infered from analysis *) d, Some ipstack
        with
        | _ -> Log.from_analysis "RET without previous CALL"; d, None
      in   
      (* check whether instruction pointers supposed and effective agree *)
      try
        let sp = Register.stack_pointer () in
        let ip_on_stack = D.mem_to_addresses d' (Asm.Lval (Asm.M (Asm.Lval (Asm.V (Asm.T sp)), (Register.size sp)))) in
        match Data.Address.Set.elements (ip_on_stack) with
        | [a] ->
           v.Cfa.State.ip <- a;
           begin
             match ipstack with
             | Some ip' -> 
                if not (Data.Address.equal ip' a) then
                  Log.from_analysis (Printf.sprintf "computed instruction pointer %s differs from instruction pointer found on the stack %s at RET instruction"
						    (Data.Address.to_string ip') (Data.Address.to_string a))
             | None -> ()
           end;
           v
        | _ -> raise Exit
      with
        _ -> Log.error "computed instruction pointer at return instruction is either undefined or imprecise"
		       
		       
    exception Jmp_exn
    (** returns the result of the transfert function corresponding to the statement on the given abstract value *)
    let process_stmts fun_stack g (v: Cfa.State.t) ip =
      let copy v d branch is_pred =
        let v' = Cfa.copy_state g v in
        v'.Cfa.State.stmts <- [];
        v'.Cfa.State.v <- d;
	v'.Cfa.State.branch <- branch;
        if is_pred then
          Cfa.add_edge g v v'
        else
          Cfa.add_edge g (Cfa.pred g v) v';
        v'
      in
      let rec has_jmp stmts =
        match stmts with
        |	[] -> false
        | s::stmts' ->
           let b =
             match s with
             | Call _ | Return  | Jmp _ -> true
             | If (_, tstmts, estmts)   -> (has_jmp tstmts) || (has_jmp estmts)
             | _ 			      -> false
           in
           b || (has_jmp stmts')
      in
      let rec process_value d s =
        match s with
        | Nop 				    -> d
        | If (e, then_stmts, else_stmts) 	    ->
           if has_jmp then_stmts || has_jmp else_stmts then
             raise Jmp_exn
           else
             let dt = List.fold_left (fun d s -> process_value d s) (restrict d e true) then_stmts in
             let de = List.fold_left (fun d s -> process_value d s) (restrict d e false) else_stmts in
             D.join dt de
		    
        | Set (dst, src) 			    -> D.set dst src d 
        | Directive (Remove r) 		    -> let d' = D.remove_register r d in Register.remove r; d'
        | Directive (Forget r) 		    -> D.forget_register r d
        | _ 				    -> raise Jmp_exn
						     
      in
      let rec process_vertices vertices s =
        try
          List.map (fun v -> v.Cfa.State.v <- process_value v.Cfa.State.v s; v) vertices
        with Jmp_exn ->
             match s with 
             | If (e, then_stmts, else_stmts) ->
		let then' = process_list (List.fold_left (fun l v ->
					      try
						let d = restrict v.Cfa.State.v e true in
						if D.is_bot d then
						  l
						else
						  (copy v d (Some true) false)::l
					      with Exceptions.Empty -> l) [] vertices) then_stmts
		in
		let else' = process_list (List.fold_left (fun l v ->
					      try
						let d = restrict v.Cfa.State.v e false in
						if D.is_bot d then
						  l
						else (copy v d (Some false) false)::l
					      with Exceptions.Empty -> l) [] vertices) else_stmts
		in
		List.iter (fun v -> Cfa.remove_state g v) vertices;
		then' @ else'
			  
             | Jmp (A a) -> List.map (fun v -> v.Cfa.State.ip <- a; v) vertices 
				     
             | Jmp (R target) ->
		List.map (fun v ->
                    try
                      let addresses = Data.Address.Set.elements (D.mem_to_addresses v.Cfa.State.v target) in
                      match addresses with
                      | [a] -> v.Cfa.State.ip <- a; v
                      | [ ] -> Log.error (Printf.sprintf "Unreachable jump target from ip = %s\n" (Data.Address.to_string v.Cfa.State.ip))
                      | l -> Log.error (Printf.sprintf "Interpreter: please select between the addresses %s for jump target from %s\n"
						       (List.fold_left (fun s a -> s^(Data.Address.to_string a)) "" l) (Data.Address.to_string v.Cfa.State.ip))
                    with
                    | Exceptions.Enum_failure -> Log.error (Printf.sprintf "Interpreter: uncomputable set of address targets for jump at ip = %s\n" (Data.Address.to_string v.Cfa.State.ip))
		  ) vertices
			 
			 
             | Call (A a) ->
		let f =
                  try
                    Some (Hashtbl.find Config.imports (Data.Address.to_int a))
                  with Not_found -> None
		in
		fun_stack := (f, ip)::!fun_stack;
		List.map (fun v -> v.Cfa.State.ip <- a; v) vertices
			 
             | Return -> List.map (process_ret fun_stack) vertices
				  
             | _       -> vertices
			    
      and process_list vertices stmts =
        match stmts with
        | s::stmts ->
           let new_vertices =
             try process_vertices vertices s
             with Exceptions.Bot_deref -> [] (* in case of undefined dereference corresponding vertices are no more explored. They are not added to the waiting list neither *)
           in
           process_list new_vertices stmts 
        | []       -> vertices
      in
      let vstart = copy v v.Cfa.State.v None true
      in
      vstart.Cfa.State.ip <- ip;
      process_list [vstart] v.Cfa.State.stmts

    (** [filter_vertices g vertices] returns vertices in _vertices_ that are already in _g_ (same address and same decoding context and subsuming abstract value) *)
    let filter_vertices g vertices =
      (* predicate to check whether a new vertex has to be explored or not *)
      let same prev v' =
        Data.Address.equal prev.Cfa.State.ip v'.Cfa.State.ip &&
          prev.Cfa.State.ctx.Cfa.State.addr_sz = v'.Cfa.State.ctx.Cfa.State.addr_sz &&
            prev.Cfa.State.ctx.Cfa.State.op_sz = v'.Cfa.State.ctx.Cfa.State.op_sz &&
              (* fixpoint reached *)
              D.subset v'.Cfa.State.v prev.Cfa.State.v
      in
      List.fold_left (fun l v ->
          try
            (* filters on cutting instruction pointers *)
            if Config.SAddresses.mem (Data.Address.to_int v.Cfa.State.ip) !Config.blackAddresses then
              Log.from_analysis (Printf.sprintf "Address %s reached but not explored because it belongs to the cut off branches\n"
						(Data.Address.to_string v.Cfa.State.ip))
            else
              (** explore if a greater abstract state of v has already been explored *)
              Cfa.iter_vertex (fun prev ->
                  if v.Cfa.State.id = prev.Cfa.State.id then
                    ()
                  else
                    if same prev v then raise Exit
                ) g;
            v::l
          with
            Exit -> l
        ) [] vertices
		     
  (** oracle used by the decoder to know the current value of a register *)
    class decoder_oracle s =
    object
      method value_of_register r = D.value_of_register s r
    end
      
    (** fixpoint iterator to build the CFA corresponding to the provided code starting from the initial vertex s *)
    (** g is the initial CFA reduced to the singleton s *) 
    let forward_bin (code: Code.t) (g: Cfa.t) (s: Cfa.State.t) (dump: Cfa.t -> unit): Cfa.t =
      let module Vertices = Set.Make(Cfa.State) in
      (* check whether the instruction pointer is in the black list of addresses to decode *)
      if Config.SAddresses.mem (Data.Address.to_int s.Cfa.State.ip) !Config.blackAddresses then
        Log.error "Interpreter not started as the entry point belongs to the cut off branches\n";
      (* boolean variable used as condition for exploration of the CFA *)
      let continue = ref true		      in
      (* set of waiting nodes in the CFA waiting to be processed *)
      let waiting  = ref (Vertices.singleton s) in
      (* set d to the initial internal state of the decoder *)
      let d = ref (Decoder.init ())             in
      (* function stack *)
      let fun_stack = ref []                    in
      while !continue do
        (* a waiting node is randomly chosen to be explored *)
        let v = Vertices.choose !waiting in
        waiting := Vertices.remove v !waiting;
        begin
          try
            (* the subsequence of instruction bytes starting at the offset provided the field ip of v is extracted *)
            let text'        = Code.sub code v.Cfa.State.ip						         in
            (* the corresponding instruction is decoded and the successor vertex of v are computed and added to    *)
            (* the CFA                                                                                             *)
            (* except the abstract value field which is set to v.Cfa.State.value. The right value will be          *)
            (* computed next step                                                                                  *)
            (* the new instruction pointer (offset variable) is also returned                                      *)
            let r = Decoder.parse text' g !d v v.Cfa.State.ip (new decoder_oracle v.Cfa.State.v)                   in
            match r with
            | Some (v, ip', d') ->
               (* these vertices are updated by their right abstract values and the new ip                         *)
               let new_vertices = update_abstract_values g v ip' (process_stmts fun_stack)                         in
               (* among these computed vertices only new are added to the waiting set of vertices to compute       *)
               let vertices'  = filter_vertices g new_vertices				     		         in
               List.iter (fun v -> waiting := Vertices.add v !waiting) vertices';
               (* udpate the internal state of the decoder *)
               d := d'
            | None -> ()
          with
          | Exceptions.Error msg 	  -> dump g; Log.error msg
          | Exceptions.Enum_failure -> dump g; Log.error "analysis stopped (computed value too much imprecise)"
          | e			  -> dump g; raise e
        end;
        (* boolean condition of loop iteration is updated *)
        continue := not (Vertices.is_empty !waiting);
      done;
      g								      
																      
    (******************** BACKWARD *******************************)
    (*************************************************************)
		     
	
    (** backward transfert function on the given abstract value *) 
    let back_process (d: D.t) (stmt: Asm.stmt): D.t =
      match stmt with
      | Call _
      | Return
      | Jmp _
      | Nop -> d
      | Directive (Forget _) -> d 
      | Directive (Remove r) -> D.add_register r d
      | Set (dst, src) ->
	 begin
	   match dst, src with
	   | V (T r1), Lval (V (T r2)) when Register.size r1 = Register.size r2 -> D.set (V (T r2)) (Lval (V (T r1))) d
	   | _, _ -> D.forget d
	 end
      | If _ -> D.forget d

    let back_update_abstract_value (g:Cfa.t) (pred: Cfa.State.t) (v: Cfa.State.t) (ip: Data.Address.t): unit =
      let back _g v _ip =
	let d' = List.fold_left back_process v.Cfa.State.v pred.Cfa.State.stmts in
	pred.Cfa.State.v <- D.meet pred.Cfa.State.v d';
	[pred]
      in
      let _ = update_abstract_values g v ip back in
      ()
			      
    let back_unroll g v pred =
      if v.Cfa.State.final then
	begin
	  let new_pred = Cfa.copy_state g v in
	  new_pred.Cfa.State.back_loop <- true;
	  Cfa.remove_edge g pred v;
	  Cfa.add_vertex g new_pred;
	  Cfa.add_edge g pred new_pred;
	  Cfa.add_edge g new_pred v;
	  new_pred
	end
      else
	begin
	  pred.Cfa.State.v <- v.Cfa.State.v;
	  pred
	end
			      
    let backward (g: Cfa.t) (s: Cfa.State.t) (dump: Cfa.t -> unit): Cfa.t =
      if D.is_bot s.Cfa.State.v then
	begin
	  dump g;
	  Log.error "backward analysis not started: empty meet with previous forward computed value"
	end
      else
	let module Vertices = Set.Make(Cfa.State) in
	let continue = ref true in
	let waiting = ref (Vertices.singleton s) in
	try
	  while !continue do
	    let v = Vertices.choose !waiting in
	    waiting := Vertices.remove v !waiting;
	    let pred = Cfa.pred g v in
	    back_update_abstract_value g pred v pred.Cfa.State.ip;
	    let pred' = back_unroll g v pred in
	    let vertices = filter_vertices g [pred'] in
	    List.iter (fun v -> waiting := Vertices.add v !waiting) vertices;
	    continue := not (Vertices.is_empty !waiting)
	  done;
	  g
	with
	| Failure "hd" -> Log.from_analysis "entry node of the CFA reached"; g
	| _ -> dump g; Log.error "unexpected error"

    (********** FORWARD FROM CFA ***************)
    (*******************************************)
    let forward_cfa (_orig_cfa: Cfa.t) (_ep_state: Cfa.State.t) (_dump: Cfa.t -> unit): Cfa.t = failwith "Interpreter.forward_cfa: not implemented"
						   
  end
     
