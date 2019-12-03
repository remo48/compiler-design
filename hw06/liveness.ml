open Ll
open Datastructures                                     

(* liveness analysis -------------------------------------------------------- *)

(* Instantiates the generic dataflow analysis framework with the
   lattice for liveness analysis.
     - the lattice elements are sets of LL uids
     - the flow functions propagate uses toward their definitions
*)

(* the operands of an instruction ------------------------------------------- *)
let insn_ops : insn -> operand list = function 
  | Alloca _         -> []
  | Load (_,o)
  | Bitcast (_,o,_)  -> [o]
  | Binop (_,_,o1,o2) 
  | Store (_,o1,o2)
  | Icmp (_,_,o1,o2) -> [o1; o2]
  | Call (_,o,args)  -> o::List.map snd args
  | Gep (_,o,os)     -> o::os

(* the operands of a terminator --------------------------------------------- *)
let terminator_ops : terminator -> operand list = function 
  | Ret (_,None)
  | Br _        -> []
  | Ret (_,Some o) 
  | Cbr (o,_,_) -> [o]

(* compute 'use' information for instructions and terminators --------------- *)
let uids_of_ops : operand list -> UidS.t =
  List.fold_left (fun s o -> match o with Id u -> UidS.add u s | _ -> s)
    UidS.empty

let insn_uses (i:insn) : UidS.t = uids_of_ops (insn_ops i)
let terminator_uses (t:terminator) : UidS.t = uids_of_ops (terminator_ops t)

(* The following two flow functions implement the liveness analysis:

   the dataflow equation for liveness analysis is:
         in[n] = use[n] U (out[n] \ defs[n])
   
   Because liveness is a backward analysis, the flow function expresses
   in[n] as a _function_ of n and out[n]:
      in[n] = flow n out[n]

   (In our representation, there is one flow function for instructions
   and another for terminators.                                               *)
let insn_flow (u,i:uid * insn) (out:UidS.t) : UidS.t =
  out |> UidS.remove u
      |> UidS.union (insn_uses i)

let terminator_flow (t:terminator) (out:UidS.t) : UidS.t =
  out |> UidS.union (terminator_uses t)

module Fact =
  struct
    let forwards = false
    let insn_flow = insn_flow
    let terminator_flow = terminator_flow
    
    (* the lattice ---------------------------------------------------------- *)
    type t = UidS.t
    let combine ds = List.fold_left UidS.union UidS.empty ds
    let equal = UidS.equal

    let compare = UidS.compare
    let to_string = UidS.to_string
  end

(* instantiate the general framework ---------------------------------------- *)
module Graph = Cfg.AsGraph (Fact)
module Solver = Solver.Make (Fact) (Graph)

(* expose a top-level analysis operation ------------------------------------ *)
let analyze (cfg:Cfg.cfg) : Graph.t =
  let init l = UidS.empty in
  let live_out = UidS.empty in
  let g = Graph.of_cfg init live_out cfg in
  Solver.solve g

(* Get liveness information as taken in by the backend. For each block
   label or instruction uid in the graph, the resulting map is the set of 
   ids that are live on entry to that block or instruction.
*)
let get_liveness (f : Ll.fdecl) : uid -> UidS.t =
  let cfg = Cfg.of_ast f in
  let graph = analyze cfg in
  LblS.fold (fun l f ->
    let l_in = Graph.block_in graph l in
    let lb = Graph.uid_in graph l in
    fun u -> try if l = u then l_in else lb u with Not_found -> f u
  ) (Cfg.nodes cfg) (fun u -> (print_endline u; raise Not_found))
