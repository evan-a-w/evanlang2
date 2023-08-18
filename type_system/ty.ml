open! Core
open! Shared
open! Frontend

type variance_map = Variance.t Lowercase.Map.t
[@@deriving sexp, equal, hash, compare]

type type_constructor_arg =
  | Tuple_arg of (Variance.t * Lowercase.t) list
  | Single_arg of Variance.t * Lowercase.t
[@@deriving sexp, equal, hash, compare]

let show_type_constructor_arg = function
  | Tuple_arg [ (_, s) ] | Single_arg (_, s) -> s
  | Tuple_arg l -> "(" ^ String.concat ~sep:", " (List.map l ~f:snd) ^ ")"
;;

module Binding_id = Id.Make ()

type type_constructor =
  type_constructor_arg option * user_type * type_proof
  (* replace bound variables in type_constructor_arg with new TyVars when using this mono *)
[@@deriving sexp, equal, hash, compare]

(* can't generalize the type of values (ie. things that arent just straight up a function,
   incl. lambdas)*)
(* BUT always safe to generalize variables that are only used covariantly *)
(* a use of a type variable is instantiating a value of type equal to the variable or a
   type parameterised by that variable.
   Can check if type is parameterised by the variable simply by mapping over the type
   and finding tyvars.
   This should probably be cached. *)
(* Variances of record fields is covariant if not mutable, invariant if mutable *)
(* Variances of Enum is the combination of all underlying types *)
and type_proof =
  { type_name : Lowercase.t
  ; absolute_type_name : Lowercase.t Qualified.t
  ; ordering : Lowercase.t list option
  ; tyvar_map : mono Lowercase.Map.t
  ; type_id : type_id
  ; mem_rep : Mem_rep.abstract
  }
[@@deriving sexp, equal, hash, compare]

and type_id = int [@@deriving sexp, equal, hash, compare]
and binding_id = Binding_id.t [@@deriving sexp, equal, hash, compare]

and mono =
  (* name and type args *)
  | Weak of Lowercase.t * Mem_rep.abstract
  (* keep track of the path and arg for equality *)
  | TyVar of Lowercase.t * Mem_rep.abstract
  | Function of mono * mono
  (* closures unify with all closures that have an equivalent mem rep and input/return type *)
  | Closure of mono * mono * (Lowercase.t * Mem_rep.abstract) Binding_id.Map.t
  | Tuple of mono list
  | Reference of mono
  | Named of type_proof
[@@deriving sexp, equal, hash, compare]

and record_type = (Lowercase.t * (mono * [ `Mutable | `Immutable ])) list
[@@deriving sexp, equal, hash, compare]

and enum_type = (Uppercase.t * mono option) list
[@@deriving sexp, equal, hash, compare]

and user_type =
  | Abstract of Mem_rep.abstract
  | Record of record_type
  | Enum of enum_type
  | User_mono of mono
[@@deriving sexp, equal, hash, compare]

let rec mem_rep_of_mono = function
  | Weak (_, rep) -> rep
  | TyVar (_, rep) -> rep
  | Function _ -> Closed `Reg
  | Closure (_, _, rep) ->
    let list =
      Binding_id.Map.to_alist rep
      |> List.map ~f:(fun (a, (f, m)) -> f ^ Int.to_string a, m)
    in
    Closed (`Native_struct list)
  | Tuple l ->
    let list =
      List.mapi l ~f:(fun i x -> [%string "_%{i#Int}"], mem_rep_of_mono x)
    in
    Closed (`Native_struct list)
  | Reference m -> Closed (`Pointer (mem_rep_of_mono m))
  | Named t -> t.mem_rep

and mem_rep_of_user_type = function
  | Abstract x -> x
  | Record l ->
    let list = List.map l ~f:(fun (a, (m, _)) -> a, mem_rep_of_mono m) in
    Closed (`Native_struct list)
  | Enum l ->
    let list =
      List.map l ~f:(fun (_, m) ->
        Option.value_map m ~default:(Mem_rep.Closed `Bits0) ~f:mem_rep_of_mono)
    in
    Closed (`Union list)
  | User_mono m -> mem_rep_of_mono m
;;

type poly =
  | Mono of mono
  | Forall of Lowercase.t * poly
[@@deriving sexp, equal, hash, compare, variants]

let rec get_mono_from_poly_without_gen = function
  | Mono m -> m
  | Forall (_, p) -> get_mono_from_poly_without_gen p
;;

module Module_path = Qualified.Make (Uppercase)

type 'data module_bindings =
  { toplevel_vars : (poly * binding_id) list Lowercase.Map.t
  ; toplevel_records : (poly Lowercase.Map.t * type_proof) Lowercase.Set.Map.t
  ; toplevel_fields :
      (type_proof * [ `Mutable | `Immutable ] * poly) Lowercase.Map.t
  ; toplevel_constructors : (poly option * type_proof) Uppercase.Map.t
  ; toplevel_type_constructors : type_id Lowercase.Map.t
  ; toplevel_modules : 'data module_bindings Uppercase.Map.t
  ; opened_modules : 'data module_bindings List.t
  ; data : 'data
  }
[@@deriving sexp, equal, hash, compare, fields]

module Absolute_name = Qualified.Make (Lowercase)

let type_id_of_absolute_name = Absolute_name.hash

let make_type_proof (s : Lowercase.t) mem_rep =
  let absolute_type_name = Qualified.Unqualified s in
  { type_name = s
  ; absolute_type_name
  ; ordering = None
  ; tyvar_map = Lowercase.Map.empty
  ; type_id = type_id_of_absolute_name absolute_type_name
  ; mem_rep = Mem_rep.Closed mem_rep
  }
;;

let int_type = make_type_proof "int" `Bits32
let float_type = make_type_proof "float" `Bits64
let bool_type = make_type_proof "bool" `Bits8
let unit_type = make_type_proof "unit" `Bits0
let string_type = make_type_proof "string" `Reg
let char_type = make_type_proof "char" `Bits8

let base_type_map =
  List.map
    [ int_type; float_type; bool_type; unit_type; string_type; char_type ]
    ~f:(fun t -> t.type_id, (None, Abstract t.mem_rep, t))
  |> Int.Map.of_alist_exn
;;

let base_module_bindings empty_data =
  { toplevel_vars = Lowercase.Map.empty
  ; toplevel_fields = Lowercase.Map.empty
  ; toplevel_records = Lowercase.Set.Map.empty
  ; toplevel_constructors = Uppercase.Map.empty
  ; toplevel_type_constructors =
      List.map
        [ int_type; float_type; bool_type; unit_type; string_type; char_type ]
        ~f:(fun t -> t.type_name, t.type_id)
      |> Lowercase.Map.of_alist_exn
  ; toplevel_modules = Uppercase.Map.empty
  ; opened_modules = []
  ; data = empty_data
  }
;;

let empty_module_bindings empty_data =
  { toplevel_vars = Lowercase.Map.empty
  ; toplevel_fields = Lowercase.Map.empty
  ; toplevel_records = Lowercase.Set.Map.empty
  ; toplevel_constructors = Uppercase.Map.empty
  ; toplevel_type_constructors = Lowercase.Map.empty
  ; toplevel_modules = Uppercase.Map.empty
  ; opened_modules = [ base_module_bindings empty_data ]
  ; data = empty_data
  }
;;
