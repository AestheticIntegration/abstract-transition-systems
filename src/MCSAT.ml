open Util

(** {2 Types} *)
module Ty : sig
  type t
  type view = Bool | Rat | Unin of ID.t | Arrow of t * t
  val view : t -> view
  val equal : t -> t -> bool
  val hash : t -> int
  val bool : t
  val rat : t
  val unin : ID.t -> t
  val arrow : t -> t -> t
  val arrow_l : t list -> t -> t
  val open_ : t -> t list * t
  val pp : t Fmt.printer

  val is_bool : t -> bool

  type env = t Str_map.t
  val parse : env -> t P.t

  module Tbl : CCHashtbl.S with type key = t
end = struct
  type t = {
    mutable id: int;
    view: view;
  }
  and view = Bool | Rat | Unin of ID.t | Arrow of t * t

  let view t = t.view
  let equal a b = a.id = b.id
  let hash a = CCInt.hash a.id

  module H = Hashcons.Make(struct
      type nonrec t = t
      let equal a b = match view a, view b with
        | Bool, Bool
        | Rat, Rat -> true
        | Unin a, Unin b -> ID.equal a b
        | Arrow (a1,a2), Arrow (b1,b2) -> equal a1 b1 && equal a2 b2
        | (Bool | Rat | Unin _ | Arrow _), _ -> false
      let hash t = match view t with
        | Bool -> 1
        | Rat -> 2
        | Unin id -> CCHash.combine2 10 (ID.hash id)
        | Arrow (a, b) -> CCHash.combine3 20 (hash a) (hash b)

      let set_id t id = assert (t.id < 0); t.id <- id
      end)

  let mk_ = 
    let h = H.create ~size:32 () in
    fun view -> H.hashcons h {view; id= -1}
  let bool : t = mk_ Bool
  let rat : t = mk_ Rat
  let unin id : t = mk_ @@ Unin id
  let arrow a b = mk_ @@ Arrow (a,b)
  let arrow_l a b = List.fold_right arrow a b

  let rec open_ ty = match view ty with
    | Arrow (a,b) ->
      let args, ret = open_ b in
      a :: args, ret
    | _ -> [], ty

  let is_bool ty = match view ty with Bool -> true | _ -> false

  let rec pp out t = match view t with
    | Bool -> Fmt.string out "bool"
    | Rat -> Fmt.string out "rat"
    | Unin id -> ID.pp out id
    | Arrow (a,b) -> Fmt.fprintf out "(@[->@ %a@ %a@])" pp a pp b

  type env = t Str_map.t
  let parse env =
    let open P in
    fix (fun self ->
      (try_ (skip_white *> string "bool") *> return bool) <|>
      (try_ (skip_white *> string "rat") *> return rat) <|>
      (try_ (skip_white *> U.word) >>= fun s ->
       (match Str_map.get s env with
        | Some ty -> return ty
        | None -> failf "not in scope: type %S" s)) <|>
      (try_ (skip_white *> char '(') *> skip_white *>
       string "->" *> skip_white *>
       (parsing "arrow argument" self <* skip_white
        >>= fun a -> many (self <* skip_white) >|= fun rest ->
        match List.rev (a::rest) with
        | [] -> assert false
        | [ret] -> ret
        | ret :: args -> arrow_l (List.rev args) ret)
       <* skip_white <* char ')')
      )

  module As_key = struct type nonrec t = t let compare=compare let equal=equal let hash=hash end
  module Tbl = CCHashtbl.Make(As_key)
end

(** {2 Typed Constants} *)
module Var : sig
  type t = {id: ID.t; ty: Ty.t}
  val make : ID.t -> Ty.t -> t
  val id : t -> ID.t
  val name : t -> string
  val ty : t -> Ty.t
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val hash : t -> int
  val pp : t Fmt.printer

  type env = t Str_map.t
  val parse : env -> t P.t
  val parse_string : env -> string -> t P.t
  module Map : CCMap.S with type key = t
end = struct
  type t = {id: ID.t; ty: Ty.t}
  let id v = v.id
  let ty v = v.ty
  let name v = ID.name @@ id v
  let make id ty : t = {id; ty}
  let equal a b = ID.equal a.id b.id
  let compare a b = ID.compare a.id b.id
  let hash a = ID.hash a.id
  let pp out a = ID.pp out a.id

  type env = t Str_map.t
  let parse_string env s =
    try P.return (Str_map.find s env)
    with Not_found -> P.failf "not in scope: variable %S" s
  let parse env : t P.t =
    let open P.Infix in
    P.try_ P.U.word >>= parse_string env

  module As_key = struct type nonrec t = t let compare=compare let equal=equal let hash=hash end
  module Map = CCMap.Make(As_key)
end

(** {2 Semantic Values} *)
module Value : sig
  type t = Bool of bool | Unin of Var.t

  val ty : t -> Ty.t
  val pp : t Fmt.printer

  val equal : t -> t -> bool
  val hash : t -> int
  val compare : t -> t -> int
  val ty : t -> Ty.t

  val is_bool : t -> bool
  val bool : bool -> t
  val not_ : t -> t
  val true_ : t
  val false_ : t
  val unin_var : Var.t -> t
  val unin : Ty.t -> int -> t (* from counter + type *)
end = struct
  type t =  Bool of bool | Unin of Var.t

  let ty = function Bool _ -> Ty.bool | Unin v -> Var.ty v
  let pp out = function
    | Bool b -> Fmt.bool out b
    | Unin v -> Var.pp out v

  let bool b = Bool b
  let true_ = bool true
  let false_ = bool false
  let unin_var v : t = Unin v
  let is_bool = function Bool _ -> true | _ -> false
  let equal a b = match a, b with
    | Bool a, Bool b -> a=b
    | Unin a, Unin b -> Var.equal a b
    | (Bool _ | Unin _), _ -> false
  let compare a b =
    let to_int_ = function Bool _ -> 1 | Unin _ -> 2 in
    match a, b with
    | Bool a, Bool b -> CCBool.compare a b
    | Unin a, Unin b -> Var.compare a b
    | (Bool _ | Unin _), _ -> CCInt.compare (to_int_ a) (to_int_ b)
  let hash = function
    | Bool b -> CCHash.(combine2 10 (bool b))
    | Unin v -> CCHash.(combine2 20 (Var.hash v))

  let not_ = function
    | Bool b -> bool (not b)
    | v -> Util.errorf "cannot negate value %a" pp v

  let unin =
    let tbl : t list Ty.Tbl.t = Ty.Tbl.create 32 in
    fun ty i ->
      let l = Ty.Tbl.get_or ~default:[] tbl ty in
      let len_l = List.length l in
      let n_missing = i - len_l in
      if n_missing < 0 then (
        List.nth l i
      ) else (
        (* extend list *)
        let extend =
          CCList.init (n_missing+1)
            (fun i -> unin_var @@ Var.make (ID.makef "$%a_%d" Ty.pp ty (i+len_l)) ty)
        in
        let l = l @ extend in
        Ty.Tbl.replace tbl ty l;
        List.nth l i
      )
end

module Env = struct
  type t = {
    ty: Ty.env;
    vars: Var.env;
  }

  let empty : t = {ty=Str_map.empty; vars=Str_map.empty; }

  let add_ty (id:ID.t) (env:t) : t =
    if Str_map.mem (ID.name id) env.ty then (
      Util.errorf "cannot shadow type %a" ID.pp_name id;
    );
    {env with ty=Str_map.add (ID.name id) (Ty.unin id) env.ty}

  let add_var (v:Var.t) (env:t) : t =
    if Str_map.mem (Var.name v) env.vars then (
      Util.errorf "cannot shadow fun %a" ID.pp_name (Var.id v);
    );
    {env with vars=Str_map.add (Var.name v) v env.vars}

  type item = Ty of Ty.t | Fun of Var.t

  let to_iter (self:t) : item Iter.t =
    Iter.append
      (Str_map.values self.ty |> Iter.map (fun ty -> Ty ty))
      (Str_map.values self.vars |> Iter.map (fun f -> Fun f))

  let pp out (self:t) =
    let pp_item out = function
      | Ty id -> Fmt.fprintf out "(@[<2>ty@ %a@])" Ty.pp id
      | Fun v -> Fmt.fprintf out "(@[<2>fun@ %a@ %a@])" Var.pp v Ty.pp (Var.ty v)
    in
    Fmt.fprintf out "(@[%a@])" (Util.pp_iter pp_item) (to_iter self)
end

(** {2 Terms} *)
module Term : sig
  type t
  type view =
    | Bool of bool
    | Not of t
    | Eq of t * t
    | App of Var.t * t list

  val view : t -> view
  val equal : t -> t -> bool
  val hash : t -> int
  val compare : t -> t -> int
  val ty : t -> Ty.t

  val bool : bool -> t
  val true_ : t
  val false_ : t
  val const : Var.t -> t
  val app : Var.t -> t list -> t
  val eq : t -> t -> t
  val neq : t -> t -> t
  val not_ : t -> t
  val abs : t -> t
  val sign : t -> bool

  val sub : t -> t Iter.t
  val is_bool : t -> bool (** Has boolean type? *)

  val pp : t Fmt.printer

  val parse : Env.t -> t P.t

  module Set : CCSet.S with type elt = t
  module Map : CCMap.S with type key = t
  module Tbl : CCHashtbl.S with type key = t
end = struct
  type t = {
    view: view;
    mutable ty: Ty.t;
    mutable id: int;
  }
  and view =
    | Bool of bool
    | Not of t
    | Eq of t * t
    | App of Var.t * t list

  let view t = t.view
  let ty t = t.ty
  let equal a b = a.id=b.id
  let compare a b = CCInt.compare a.id b.id
  let hash a = CCHash.int a.id

  let is_bool t = Ty.is_bool (ty t)

  let sub t k =
    let rec aux t =
      k t;
      match view t with
      | Bool _ | App (_, []) -> ()
      | App (_, l) -> List.iter aux l
      | Eq (a,b) -> aux a; aux b
      | Not u -> aux u
    in aux t

  module H = Hashcons.Make(struct
      type nonrec t = t
      let equal a b = match view a, view b with
        | Bool a, Bool b -> a=b
        | Not a, Not b -> equal a b
        | Eq (a1,a2), Eq (b1,b2) -> equal a1 b1 && equal a2 b2
        | App (f1,l1), App (f2,l2) -> Var.equal f1 f2 && CCList.equal equal l1 l2
        | (Bool _ | Not _ | Eq _ | App _), _ -> false

      let hash t =
        let module H = CCHash in
        match view t with
        | Bool b -> H.combine2 10 (H.bool b)
        | Not a -> H.combine2 20 (hash a)
        | Eq (a,b) -> H.combine3 30 (hash a) (hash b)
        | App (f, l) -> H.combine3 40 (Var.hash f) (H.list hash l)

      let set_id t id = assert (t.id < 0); t.id <- id
    end)

  let rec pp out (t:t) : unit =
    match view t with
    | Bool b -> Fmt.bool out b
    | Eq (a,b) -> Fmt.fprintf out "(@[=@ %a@ %a@])" pp a pp b
    | Not a -> Fmt.fprintf out "(@[not@ %a@])" pp a
    | App (f, []) -> Var.pp out f
    | App (f, l) -> Fmt.fprintf out "(@[%a@ %a@])" Var.pp f (Util.pp_list pp) l

  let ty_of_view_ = function
    | Bool _ -> Ty.bool
    | Eq (a,b) ->
      if not (Ty.equal (ty a) (ty b)) then (
        Util.errorf "cannot equate %a@ and %a:@ incompatible types" pp a pp b;
      );
      Ty.bool
    | Not a ->
      if not (Ty.equal (ty a) Ty.bool) then (
        Util.errorf "@[cannot compute negation of non-boolean@ %a@]" pp a;
      );
      Ty.bool
    | App (f, l) ->
      let args, ret = Ty.open_ (Var.ty f) in
      if List.length args <> List.length l then (
        Util.errorf "@[incompatible arity:@ %a@ applied to %a@]" Var.pp f (Fmt.Dump.list pp) l;
      );
      begin 
        match CCList.find_opt (fun (t,ty_a) -> not @@ Ty.equal (ty t) ty_a) (List.combine l args)
        with
        | None -> ()
        | Some (t,ty_a) ->
          Util.errorf "@[argument %a@ should have type %a@]" pp t Ty.pp ty_a
      end;
      ret

  let mk_ : view -> t =
    let tbl = H.create ~size:256 () in
    fun view ->
      let t = {view; id= -1; ty=Ty.bool} in
      let u = H.hashcons tbl t in
      if t == u then u.ty <- ty_of_view_ view;
      u

  let bool b : t = mk_ (Bool b)
  let true_ = bool true
  let false_ = bool false
  let app f l : t = mk_ (App (f, l))
  let const f = app f []
  let eq a b : t =
    let view = if compare a b < 0 then Eq (a,b) else Eq(b,a) in
    mk_ view

  let not_ a = match view a with
    | Bool b -> bool (not b)
    | Not u -> u
    | _ -> mk_ (Not a)
  let neq a b = not_ @@ eq a b

  let abs t = match view t with
    | Bool false -> true_
    | Not u -> u
    | _ -> t

  let sign t = match view t with
    | Bool b -> b
    | Not _ -> false
    | _ -> true

  module As_key = struct type nonrec t = t let compare=compare let equal=equal let hash=hash end

  module Set = CCSet.Make(As_key)
  module Map = CCMap.Make(As_key)
  module Tbl = CCHashtbl.Make(As_key)

  let parse (env:Env.t) : t P.t =
    let open P.Infix in
    P.fix (fun self ->
        let self' = P.try_ (self <* P.skip_white) in
        P.(try_ (string "true") *> return true_) <|>
        P.(try_ (string "false") *> return false_) <|>
        (P.try_ P.U.word >>= Var.parse_string env.Env.vars >|= const) <|>
        (P.try_ (P.char '(') *> P.skip_space *>
         ( (P.try_ (P.char '=') *> P.skip_white *>
            (self' >>= fun a -> self' <* P.skip_white <* P.char ')'
             >|= fun b -> eq a b)) <|>
           (P.try_ (P.string "not") *> P.skip_white *> (self' >|= not_)
            <* P.skip_white <* P.char ')') <|>
           (* apply *)
           (P.try_ P.U.word <* P.skip_white >>= Var.parse_string env.Env.vars
            >>= fun f -> P.many self' <* P.skip_white <* P.char ')'
            >|= fun l -> app f l)
         ) ) <?> "expected term"
      )
end

module SigMap = CCMap.Make(struct
    type t = Var.t * Value.t list
    let compare (f1,l1) (f2,l2) =
      if Var.equal f1 f2 then CCList.compare Value.compare l1 l2
      else Var.compare f1 f2
  end)

type assignment = Value.t Term.Map.t

(** {2 Disjunction of boolean terms} *)
module Clause = struct
  type t = Term.Set.t
  let pp out c =
    if Term.Set.cardinal c = 1
    then Term.pp out (Term.Set.choose c)
    else Fmt.fprintf out "(@[or@ %a@])" (pp_list Term.pp) (Term.Set.to_list c)
  let is_empty = Term.Set.is_empty
  let choose = Term.Set.choose
  let contains l c = Term.Set.mem l c
  let length = Term.Set.cardinal
  let remove l c : t = Term.Set.remove l c
  let union = Term.Set.union
  let lits c = Term.Set.to_seq c
  let for_all = Term.Set.for_all
  let filter = Term.Set.filter
  let of_list = Term.Set.of_list

  let as_unit c = match Term.Set.choose_opt c with
    | None -> None
    | Some lit ->
      let c' = remove lit c in
      if is_empty c' then Some lit else None

  let parse (env:Env.t) : t P.t =
    let open P in
    skip_white *> parsing "clause" (
      (try_ (char '(' *> string "or") *> skip_white *>
       (many (try_ (Term.parse env) <* skip_white) <* char ')' >|= Term.Set.of_list)) <|>
      (Term.parse env >|= Term.Set.singleton)
    )

  (* semantic evaluation *)
  let rec eval_lit_semantic (ass:assignment) (t:Term.t) : bool option =
    match Term.view t with
    | Term.Eq (a,b) ->
      begin match Term.Map.get a ass, Term.Map.get b ass with
        | Some va, Some vb -> Some (Value.equal va vb)
        | _ -> None
      end
    | Term.Not u ->
      CCOpt.map not (eval_lit_semantic ass u)
    | _ -> None

  (* semantic + trail evaluation *)
  let eval_lit (ass:assignment) (t:Term.t) : bool option =
    match Term.Map.get t ass with
    | Some (Value.Bool b) -> Some b
    | Some _ -> assert false
    | None -> eval_lit_semantic ass t

  (* can [t] eval to false? *)
  let lit_eval_to_false (ass:assignment) (t:Term.t) : bool =
    match Term.Map.get t ass, eval_lit_semantic ass t with
    | Some (Value.Bool false), _ | _, Some false -> true
    | _ -> false

  (* remove all literals that somehow evaluate to false *)
  let filter_false (ass:assignment) (c:t) : t =
    filter
      (fun t -> not (lit_eval_to_false ass t))
      c

  let eval_to_false (ass:assignment) (c:t) : bool =
    for_all (fun t -> lit_eval_to_false ass t) c
end

module Trail = struct
  type kind = Decision | BCP of Clause.t | Eval
  type t =
    | Nil
    | Cons of {
        kind: kind;
        lit: Term.t;
        value: Value.t;
        next: t;
        _level: int lazy_t;
        _assign: assignment lazy_t; (* assignment, from trail *)
      }

  let[@inline] assign = function
    | Nil -> Term.Map.empty
    | Cons {_assign=lazy a;_} -> a

  let[@inline] level = function
    | Nil -> 0
    | Cons {_level=lazy l;_} -> l

  let cons kind (lit:Term.t) (value:Value.t) (next:t) : t =
    let lit, value =
      if Term.sign lit then lit, value else Term.not_ lit, Value.not_ value in
    (* Format.printf "trail.cons %a <- %a@." Term.pp lit Value.pp value; *)
    let _level = lazy (
      match kind with
      | Decision -> 1 + level next
      | BCP _ | Eval -> level next
    ) 
    and _assign = lazy (
      let a = assign next in
      if Value.is_bool value then (
        a |> Term.Map.add lit value
        |> Term.Map.add (Term.not_ lit) (Value.not_ value)
      ) else (
        a |> Term.Map.add lit value
      )
    ) in
    Cons { kind; lit; value; next; _assign; _level; }

  let unit_true = Clause.of_list [Term.true_] (* axiom: [true] *)
  let empty = cons (BCP unit_true) Term.true_ Value.true_ Nil

  let rec iter k = function
    | Nil -> ()
    | Cons {kind;lit;value;next;_} ->
      k (kind, lit, value);
      iter k next

  let to_iter (tr:t) : (kind * Term.t * Value.t) Iter.t = fun k -> iter k tr
  let iter_terms (tr:t) : Term.t Iter.t = to_iter tr |> Iter.map (fun (_,t,_) -> t)
  let iter_ass (tr:t) : (Term.t*Value.t) Iter.t = to_iter tr |> Iter.map (fun (_,t,v) -> t,v)

  let pp_trail_elt out (k,lit,v) =
    let cause = match k with Decision -> "*" | BCP _ -> "" | Eval -> "$" in
    Fmt.fprintf out "(@[%a%s@ <- %a@])" Term.pp lit cause Value.pp v

  let pp out (self:t) : unit =
    Fmt.fprintf out "(@[%a@])" (pp_iter pp_trail_elt) (to_iter self)
end

module State = struct
  type conflict_uf =
    | CUF_forbid of {
        t: Term.t;
        v: Value.t;
        lit_force: Term.t;
        lit_forbid: Term.t;
      }
    | CUF_forced2 of {
        t: Term.t;
        v1: Value.t;
        v2: Value.t;
        lit_v1: Term.t;
        lit_v2: Term.t;
      }
    | CUF_congruence of {
        f: Var.t;
        t1: Term.t;
        t2: Term.t;
      }

  type status =
    | Sat
    | Unsat
    | Conflict_bool of Clause.t
    | Conflict_uf of conflict_uf
    | Backjump of Clause.t
    | Searching

  type uf_domain =
    | UFD_forced of Value.t * Term.t
    | UFD_forbid of (Value.t * Term.t) list
    | UFD_conflict_forbid of Value.t * Term.t * Term.t
    | UFD_conflict_forced2 of Value.t * Term.t  * Value.t * Term.t 

  type t = {
    env: Env.t;
    cs: Clause.t list;
    trail: Trail.t;
    status: status;
    _all_vars: Term.Set.t lazy_t;
    _to_decide: Term.Set.t lazy_t;
    _uf_domain: uf_domain Term.Map.t lazy_t; (* incompatibility table for UF *)
    _uf_sigs: (Value.t * Term.t) SigMap.t lazy_t; (* signature table for UF *)
  }

  let[@inline] all_vars self = Lazy.force self._all_vars
  let[@inline] to_decide self = Lazy.force self._to_decide
  let[@inline] uf_domain self = Lazy.force self._uf_domain
  let[@inline] uf_sigs self = Lazy.force self._uf_sigs

  (* compute domains, by looking for [a=b <- false]
     where [a] has a value already but [b] doesn't,
     or for [a=b <- true] where [a] has a value but [b] doesn't.
     We might detect conflicts when doing that. *)
  let compute_uf_domain trail : uf_domain Term.Map.t =
    let ass = Trail.assign trail in
    let is_ass x = Term.Map.mem x ass in
    (* pairs of impossible assignments *)
    let pairs : (Term.t * Term.t * _) list =
      Trail.iter_ass trail
      |> Iter.filter_map
        (fun (t,v) -> match Term.view t, v with
           | Term.Eq (a,b), Value.Bool bool when is_ass a && not (is_ass b) ->
             let value = Term.Map.find a ass in
             Some (t, b, if bool then `Forced value else `Forbid value)
           | Term.Eq (a,b), Value.Bool bool when is_ass b && not (is_ass a) ->
             let value = Term.Map.find b ass in
             Some (t, a, if bool then `Forced value else `Forbid value)
           | _ -> None)
      |> Iter.to_rev_list
    in
    List.fold_left
      (fun m (t1,t,op) ->
         match op, Term.Map.get t m with
         | _, Some (UFD_conflict_forbid _ | UFD_conflict_forced2 _) -> m
         | `Forced v1, Some (UFD_forced (v2,t2)) ->
           if Value.equal v1 v2 then m
           else Term.Map.add t (UFD_conflict_forced2 (v1,t1,v2,t2)) m
         | `Forced v1, Some (UFD_forbid l) ->
           begin match CCList.find_opt (fun (v2,_) -> Value.equal v1 v2) l with
             | Some (_,t2) ->
               Term.Map.add t (UFD_conflict_forbid (v1,t1,t2)) m
             | None ->
               Term.Map.add t (UFD_forced (v1,t1)) m
           end
         | `Forbid v1, Some (UFD_forced (v2,t2)) ->
           if Value.equal v1 v2
           then Term.Map.add t (UFD_conflict_forbid (v1,t2,t1)) m
           else m
         | `Forbid v1, Some (UFD_forbid l) ->
           Term.Map.add t (UFD_forbid ((v1,t1)::l)) m
         | `Forced v1, None ->
           Term.Map.add t (UFD_forced (v1,t1)) m
         | `Forbid v1, None ->
           Term.Map.add t (UFD_forbid [v1,t1]) m)
      Term.Map.empty pairs

  (* compute signatures, by looking at terms [f t1…tn <- v] where each [t_i]
     also has a value *)
  let compute_uf_sigs trail =
    let ass = Trail.assign trail in
    let is_ass x = Term.Map.mem x ass in
    Trail.iter_ass trail
    |> Iter.filter_map
      (fun (t,v) -> match Term.view t with
         | Term.App (f, l) when List.for_all is_ass l ->
           Some ((f, List.map (fun x->Term.Map.find x ass) l), (v,t))
         | _ -> None)
    |> SigMap.of_seq

  (* main constructor *)
  let make (env:Env.t) (cs:Clause.t list) (trail:Trail.t) status : t =
    let _all_vars = lazy (
      Iter.(
        of_list cs
        |> flat_map Clause.lits |> flat_map Term.sub |> map Term.abs)
      |> Term.Set.of_seq;
    ) in
    let _to_decide = lazy (
      let lazy all = _all_vars in
      let in_trail =
        Iter.(Trail.iter_terms trail |> map Term.abs) |> Term.Set.of_seq in
      Term.Set.diff all in_trail
    ) in
    let _uf_sigs = lazy (compute_uf_sigs trail) in
    let _uf_domain = lazy (compute_uf_domain trail) in
    { env; cs; trail; status; _all_vars; _to_decide; _uf_sigs; _uf_domain; }

  let empty : t = make Env.empty [] Trail.empty Searching

  let pp_conflict_uf out = function
    | CUF_forbid {t;v;lit_force;lit_forbid} ->
      Fmt.fprintf out "(@[conflict-uf-forbid@ @[%a <-@ %a@]@ :force %a@ :forbid %a@])"
        Term.pp t Value.pp v Term.pp lit_force Term.pp lit_forbid
    | CUF_forced2 {t;v1;v2;lit_v1;lit_v2} ->
      Fmt.fprintf out
        "(@[conflict-uf-forced2@ %a @[<- %a@ :by %a@]@ :or @[<- %a@ :by %assert@]@])"
        Term.pp t Value.pp v1 Term.pp lit_v1 Value.pp v2 Term.pp lit_v2
    | CUF_congruence {f;t1;t2} ->
      Fmt.fprintf out
        "(@[conflict-uf-congruence[%a]@ %a@ :and %a@])"
        Var.pp f Term.pp t1 Term.pp t2

  let pp_status out = function
    | Sat -> Fmt.string out "sat"
    | Unsat -> Fmt.string out "unsat"
    | Searching -> Fmt.string out "searching"
    | Conflict_bool c -> Fmt.fprintf out "(@[conflict %a@])" Clause.pp c
    | Conflict_uf cuf -> pp_conflict_uf out cuf
    | Backjump c -> Fmt.fprintf out "(@[backjump %a@])" Clause.pp c

  let pp out (self:t) : unit =
    Fmt.fprintf out
      "(@[<hv>st @[<2>:status@ %a@]@ @[<2>:cs@ (@[<v>%a@])@]@ \
       @[<2>:trail@ %a@]@ @[<2>:env@ %a@]@])"
      pp_status self.status (pp_list Clause.pp) self.cs Trail.pp self.trail
      Env.pp self.env

  let parse_one (env:Env.t) (cs:Clause.t list) : (Env.t * Clause.t list) P.t =
    let open P in
    (* assert *)
    (try_ (char '(' *> skip_white *> string "assert") *> skip_white *>
     (parsing "assert" (Clause.parse env)
      >|= fun c -> (env,c::cs)) <* skip_white <* char ')') <|>
    (* new type *)
    (try_ (char '(' *> skip_white *> string "ty") *> skip_white *>
     parsing "ty"
       (U.word >|= fun ty -> Env.add_ty (ID.make ty) env, cs) <* skip_white <* char ')') <|>
    (* new function *)
    (try_ (char '(' *> skip_white *> string "fun") *> skip_white *>
     parsing "fun" (U.word >>= fun f ->
      (skip_white *> parsing "ty" (Ty.parse env.Env.ty) <* skip_white <* char ')') >|= fun ty ->
      let v = Var.make (ID.make f) ty in
      Env.add_var v env, cs))

  let rec parse_rec (env:Env.t) (cs:Clause.t list) : (Env.t * Clause.t list) P.t =
    let open P in
    skip_white *> (
      (* done *)
      (try_ (char ')') *> return (env, List.rev cs)) <|>
      (* one statement, then recurse *)
      (try_ (parsing "statement" @@ parse_one env cs)
       >>= fun (env,cs) -> parse_rec env cs)
    )

  let parse : t P.t =
    let open P in
    (skip_white *> char '(' *> parse_rec Env.empty [])
    >|= fun (env,cs) -> make env cs Trail.empty Searching

  (* ######### *)

  let resolve_bool_conflict_ (self:t) : _ ATS.step option =
    let open ATS in
    match self.status with
    | Conflict_bool c when Clause.is_empty c ->
      Some (One (make self.env self.cs self.trail Unsat, "learnt false"))
    | Conflict_bool c ->
      begin match self.trail with
        | Trail.Nil ->
          Some (One (make self.env self.cs self.trail Unsat, "empty trail")) (* unsat! *)
        | Trail.Cons {kind=BCP d;lit;next;_} when Clause.contains (Term.not_ lit) c ->
          (* resolution *)
          assert (Clause.contains lit d);
          let res = Clause.union (Clause.remove lit d) (Clause.remove (Term.not_ lit) c) in
          let expl = Fmt.sprintf "resolve on %a with %a" Term.pp lit Clause.pp d in
          Some (One (make self.env self.cs next (Conflict_bool res), expl))
        | Trail.Cons {kind=BCP _; next; _} ->
          Some (One (make self.env self.cs next self.status, "consume"))
        | Trail.Cons {kind=Eval; lit; next; _} ->
          Some (One (make self.env self.cs next self.status, Fmt.sprintf "consume-eval %a" Term.pp lit))
        | Trail.Cons {kind=Decision; _} ->
          (* start backjumping *)
          Some (One (make self.env self.cs self.trail (Backjump c), "backjump below conflict level"))
      end
    | _ -> None

  let backjump_ (self:t) : _ ATS.step option =
    let open ATS in
    let rec unwind_till_next_decision = function
      | Trail.Nil -> Trail.empty
      | Trail.Cons {kind=Decision; next; _} -> next
      | Trail.Cons {kind=BCP _ | Eval;next; _} -> unwind_till_next_decision next
    in
    let trail = self.trail in
    match self.status, trail with
    | Backjump c, _ when Clause.is_empty c ->
      Some (One (make self.env self.cs self.trail Unsat, "learnt false"))
    | Backjump _, Trail.Nil ->
      Some (One (make self.env self.cs self.trail Unsat, "empty trail")) (* unsat! *)
    | Backjump _, _ when Trail.level trail = 0 ->
      Some (One (make self.env self.cs self.trail Unsat, "level 0 trail")) (* unsat! *)
    | Backjump c, Trail.Cons {lit; kind; next; _ } when not (Term.is_bool lit) ->
      assert (kind=Decision);
      let c_reduced = Clause.filter_false (Trail.assign next) c in
      if Clause.is_empty c_reduced then (
        let expl = "T-consume" in
        Some (One (make self.env self.cs next (Backjump c), expl))
      ) else if Clause.length c_reduced=1 then (
        (* normal backjump *)
        let expl = Fmt.sprintf "backjump with %a" Clause.pp c in
        Some (One (make self.env (c::self.cs) next Searching, expl))
      ) else if Clause.length c_reduced=2 then (
        (* semantic case split? *)
        let decision = Clause.choose c_reduced in
        let expl =
          Fmt.sprintf "backjump+semantic split with %a@ @[<2>decide %a@ in %a@]"
            Clause.pp c Term.pp decision Clause.pp c_reduced
        in
        let trail = Trail.cons Trail.Decision decision Value.true_ next in
        Some (One (make self.env (c :: self.cs) trail Searching, expl))
      ) else (
        Util.errorf
          "backjump with clause %a@ but filter-false %a@ \
           should have at most 2 lits"
          Clause.pp c Clause.pp c_reduced
      )
    | Backjump c, Trail.Cons {lit; _}
      when Clause.contains (Term.not_ lit) c
        && Clause.eval_to_false
             (Trail.assign trail) (Clause.remove (Term.not_ lit) c) ->
      (* reached UIP *)
      let tr = unwind_till_next_decision trail in
      let expl = Fmt.sprintf "backjump with %a" Clause.pp c in
      let trail = Trail.cons (BCP c) lit Value.false_ tr in
      Some (One (make self.env (c :: self.cs) trail Searching, expl))
    | Backjump c, Trail.Cons {next;_} ->
      Some (One (make self.env (c :: self.cs) next (Backjump c), "consume"))
    | _ -> None

  let find_unit_c (self:t) : (Clause.t * Term.t) option =
    let assign = Trail.assign self.trail in
    Iter.of_list self.cs
    |> Iter.find_map
      (fun c ->
         (* non-false lits *)
         let c' = Clause.filter_false assign c in
         match Clause.as_unit c' with
         | Some l when not (Term.Map.mem l assign) -> Some (c,l)
         | _ -> None)

  let propagate self : _ ATS.step option =
    match find_unit_c self with
    | Some (c,lit) ->
      let expl = Fmt.sprintf "propagate %a from %a" Term.pp lit Clause.pp c in
      let trail = Trail.cons (BCP c) lit Value.true_ self.trail in
      Some (ATS.One (make self.env self.cs trail Searching, expl))
    | None -> None

  (* find [a=b] where [a] and [b] are assigned *)
  let propagate_uf_eq self : (_*_) ATS.step option =
    let ass = Trail.assign self.trail in
    let has_ass t = Term.Map.mem t ass in
    all_vars self
    |> Term.Set.to_seq
    |> Iter.filter (fun t -> not @@ has_ass t)
    |> Iter.find_map
      (fun t ->
        match Term.view t with
          | Term.Eq (a,b) when has_ass a && has_ass b ->
            let value =
              Value.bool (Value.equal (Term.Map.find a ass) (Term.Map.find b ass))
            in
            let trail = Trail.cons Trail.Eval t value self.trail in
            let expl = Fmt.asprintf "eval %a" Term.pp t in
            Some (ATS.One (make self.env self.cs trail Searching, expl))
          | _ -> None)

  let is_searching self = match self.status with
    | Searching -> true
    | _ -> false

  let decide self : _ ATS.step option =
    (* try to decide *)
    let vars = to_decide self in
    if Term.Set.is_empty vars then (
      (* full model, we're done! *)
      Some (ATS.Done (make self.env self.cs self.trail Sat, "all vars decided"))
    ) else (
      (* multiple possible decisions *)
      let decs =
        Term.Set.to_seq vars
        |> Iter.flat_map_l
          (fun x ->
             let mk_ v value =
               make self.env self.cs
                 (Trail.cons Decision v value self.trail) Searching,
               Fmt.sprintf "decide %a <- %a" Term.pp v Value.pp value
             in
             if Term.is_bool x then (
               [mk_ x Value.true_; mk_ x Value.false_]
             ) else (
               let domain = uf_domain self in
               match Term.Map.get x domain with
               | None -> [mk_ x @@ Value.unin (Term.ty x) 0]
               | Some (UFD_conflict_forbid _ | UFD_conflict_forced2 _) ->
                 assert false
               | Some (UFD_forced (v,_)) -> [mk_ x v]
               | Some (UFD_forbid l) ->
                 let value =
                   Iter.(0--max_int)
                   |> Iter.find_map (fun i ->
                       let value = Value.unin (Term.ty x) i in
                       if List.for_all (fun (v',_) -> not (Value.equal value v')) l
                       then Some value else None)
                   |> CCOpt.get_exn
                 in
                 [mk_ x value]

             ))
        |> Iter.to_rev_list
      in
      Some (ATS.Choice decs)
    )

  let find_false_clause (self:t) : _ option =
    let ass = Trail.assign self.trail in
    match CCList.find_opt (Clause.eval_to_false ass) self.cs with
    | None -> None
    | Some c ->
      (* conflict! *)
      Some (ATS.One (make self.env self.cs self.trail (Conflict_bool c), "false clause"))

  let find_uf_domain_conflict (self:t) : _ option =
    let domain = uf_domain self in
    let l =
      Term.Map.to_seq domain
      |> Iter.filter_map
          (fun (t,dom) ->
            match dom with
            | UFD_conflict_forbid (v,t1,t2) ->
              Some (t, Conflict_uf (CUF_forbid {t;v;lit_force=t1; lit_forbid=t2}))
            | UFD_conflict_forced2 (v1,t1,v2,t2) ->
              Some (t, Conflict_uf (CUF_forced2 {t;v1;lit_v1=t1;v2;lit_v2=t2}))
            | _ -> None)
      |> Iter.to_rev_list
    in
    let mk_expl t = Fmt.asprintf "UF domain conflict on %a" Term.pp t in
    begin match l with
      | [] -> None
      | [t, c] ->
        Some (ATS.One (make self.env self.cs self.trail c, mk_expl t))
      | cs ->
        let choices =
          List.map
            (fun (t,c) -> make self.env self.cs self.trail c, mk_expl t) cs
        in
        Some (ATS.Choice choices)
    end

  let find_congruence_conflict (self:t) : _ option =
    let ass = Trail.assign self.trail in
    let sigs = uf_sigs self in
    let has_ass x = Term.Map.mem x ass in
    let get_ass x = Term.Map.find x ass in
    let l =
      Trail.iter_ass self.trail
      |> Iter.filter_map
          (fun (t,v) ->
            match Term.view t with
            | Term.App (f, l) when List.for_all has_ass l ->
              (* see if the signature is compatible with [v] *)
              begin match SigMap.get (f, List.map get_ass l) sigs with
                | None -> assert false
                | Some (v2,_) when Value.equal v v2 -> None (* compatible *)
                | Some (_v2,t2) ->
                  let cuf = CUF_congruence {f; t1=t;t2} in
                  Some (t, Conflict_uf cuf)
              end
            | _ -> None)
      |> Iter.to_rev_list
    in
    let mk_expl t = Fmt.asprintf "UF congruence conflict on %a" Term.pp t in
    begin match l with
      | [] -> None
      | [t, c] ->
        Some (ATS.One (make self.env self.cs self.trail c, mk_expl t))
      | cs ->
        let choices =
          List.map
            (fun (t,c) -> make self.env self.cs self.trail c, mk_expl t) cs
        in
        Some (ATS.Choice choices)
    end

  (* assuming [eq] is an equation [t=u] or [u=t], return [u] *)
  let get_eq_other_side (t:Term.t) ~(eq:Term.t) : Term.t =
    match Term.view eq with
    | Term.Eq (a,b) when Term.equal a t -> b
    | Term.Eq (a,b) when Term.equal b t -> a
    | _ -> Util.errorf "get_eq_other_side of %a in %a" Term.pp t Term.pp eq

  let mk_uf_lemma (self:t) (cuf:conflict_uf) : Clause.t =
    let ass = Trail.assign self.trail in
    match cuf with
    | CUF_forbid { t; v=_; lit_force; lit_forbid } ->
      (* learn transitivity lemma *)
      let t1 = get_eq_other_side t ~eq:lit_forbid in
      let t2 = get_eq_other_side t ~eq:lit_force in
      Clause.of_list [Term.eq t1 t; Term.neq t2 t; Term.neq t1 t2]
    | CUF_forced2 { t; v1=_; v2=_; lit_v1; lit_v2 } ->
      (* transitivity lemma *)
      let t1 = get_eq_other_side t ~eq:lit_v1 in
      let t2 = get_eq_other_side t ~eq:lit_v2 in
      Clause.of_list [Term.neq t1 t; Term.neq t2 t; Term.eq t1 t2]
    | CUF_congruence { f; t1; t2; } ->
      (* congruence lemma *)
        begin match Term.view t1, Term.view t2 with
        | Term.App (f1,l1), Term.App (f2, l2) ->
          assert (Var.equal f f1 && Var.equal f f2 && List.length l1 = List.length l2);
          let hyps = CCList.map2 Term.neq l1 l2 in
          let concl =
            (* one of the two terms is false in current trail *)
            if Term.is_bool t1 then (
              match Clause.eval_lit ass t1, Clause.eval_lit ass t2 with
              | Some true, Some false ->
                [Term.not_ t1; t2]
              | Some false, Some true ->
                [Term.not_ t2; t1]
              | v1, v2 ->
                Util.errorf "cannot find boolean congruence lemma@ for %a[%a] and %a[%a]"
                  Term.pp t1 (Fmt.opt Fmt.bool) v1 Term.pp t2 (Fmt.opt Fmt.bool) v2
            ) else (
              [Term.eq t1 t2]
            )
          in
          Clause.of_list (concl @ hyps)
        | _ -> assert false
        end

  (* learn some UF lemma and then do resolution on it *)
  let solve_uf_domain_conflict (self:t) : _ option =
    match self.status with
    | Searching | Sat | Unsat | Backjump _ | Conflict_bool _ -> None
    | Conflict_uf cuf ->
      (* learn a UF lemma *)
      let lemma = mk_uf_lemma self cuf in
      let expl = Fmt.asprintf "add UF lemma %a" Clause.pp lemma in
      (* lemma must be false *)
      let reduced = Clause.filter_false (Trail.assign self.trail) lemma in
      if not @@ Clause.is_empty reduced then (
        Util.errorf "bad lemma: %a@ reduced: %a" Clause.pp lemma Clause.pp reduced;
      );
      Some (ATS.One (make self.env self.cs self.trail (Conflict_bool lemma), expl))

  let if_searching f self = match self.status with
    | Searching -> f self
    | _ -> None

  let is_done (self:t) =
    match self.status with
    | Sat | Unsat -> Some (ATS.Done (self, "done"))
    | _ -> None

  let rules : _ ATS.rule list list = [
    [is_done];
    [resolve_bool_conflict_; solve_uf_domain_conflict; backjump_];
    [if_searching find_false_clause;
     if_searching find_uf_domain_conflict;
     if_searching find_congruence_conflict;
    ];
    [if_searching propagate];
    [if_searching propagate_uf_eq];
    [if_searching decide];
  ]
end

module A = struct
  let name = "mcsat"
  module State = State
  let rules = State.rules
end

let ats : ATS.t = (module ATS.Make(A))
