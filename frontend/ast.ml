open! Core
open! Shared
module Tag = String_replacement.Make ()

module Tuple = struct
  type 'a t = 'a list [@@deriving sexp, compare, equal, hash]
end

module Type_expr = struct
  type t =
    | Pointer of t
    | Single of Lowercase.t Qualified.t
    | Arrow of t * t
    | Tuple of t Tuple.t
    | Multi of t * Lowercase.t Qualified.t
  [@@deriving sexp, variants, compare, hash, equal]
end

module Type_binding = struct
  type arg =
    | Single of (Variance.t * Lowercase.t)
    | Tuple of (Variance.t * Lowercase.t) list
  [@@deriving sexp, variants, equal, hash, compare]

  (* need to enforce that every arg appears in the definition *)
  type t = Mono of Lowercase.t | Poly of (arg * Lowercase.t)
  [@@deriving sexp, variants, equal, hash, compare]
end

module Type_def_lit = struct
  type t =
    | Record of (Lowercase.t * (Type_expr.t * [ `Mutable | `Immutable ])) List.t
    | Enum of (Uppercase.t * Type_expr.t option) List.t
    | Type_expr of Type_expr.t
  [@@deriving sexp, variants, equal, hash, compare]
end

module Mode = struct
  type t = Allocation of [ `Local | `Global ]
  [@@deriving sexp, compare, equal, hash, variants]
end

module Ast_tags = struct
  type t = Token.t list Tag.Map.t [@@deriving sexp, compare, equal, hash]

  let empty = Tag.Map.empty
end

module Value_tag = struct
  type t = {
    type_expr : Type_expr.t option; [@sexp.option]
    mode : Mode.t option; [@sexp.option]
    ast_tags : Ast_tags.t;
  }
  [@@deriving sexp, compare, equal, hash, fields]

  let empty = { type_expr = None; mode = None; ast_tags = Ast_tags.empty }
end

module Literal = struct
  type t =
    | Unit
    | Int of int
    | Bool of bool
    | Float of float
    | String of string
    | Char of char
  [@@deriving sexp, equal, hash, compare]
end

module Binding = struct
  module T = struct
    type t =
      | Name of Lowercase.t
      | Constructor of Uppercase.t Qualified.t * t option
      | Literal of Literal.t
      | Record of t Lowercase.Map.t Qualified.t
      | Tuple of t Tuple.t Qualified.t
      | Typed of t * Value_tag.t
      | Renamed of t * Lowercase.t
      | Pointer of t
    [@@deriving sexp, equal, hash, compare, variants]
  end

  module Table = Map.Make (T)
  include T
end

type 'type_def type_description = {
  type_name : Type_binding.t;
  type_def : 'type_def;
  ast_tags : Ast_tags.t;
}
[@@deriving sexp, equal, hash, compare]

type toplevel_type =
  | Sig_binding of Binding.t * Value_tag.t
  | Sig_module of module_sig module_description
  | Sig_type_def of Type_def_lit.t option type_description
[@@deriving sexp, equal, hash, compare]

and module_sig = toplevel_type list [@@deriving sexp, equal, hash, compare]

and 'module_sig module_description = {
  module_name : Uppercase.t;
  functor_args : (Uppercase.t * module_sig) list;
  module_sig : 'module_sig;
}
[@@deriving sexp, equal, hash, compare]

type rec_flag = bool [@@deriving sexp, equal, hash, compare]

(* node has no spaces, t does *)
type node =
  | Var of Lowercase.t Qualified.t
  | Literal of Literal.t
  | Tuple of expr Tuple.t Qualified.t
  | Constructor of Uppercase.t Qualified.t
  | Record of expr Lowercase.Map.t Qualified.t
  | Wrapped of expr Qualified.t
[@@deriving sexp, equal, hash, compare]

and let_each = Binding.t * expr [@@deriving sexp, equal, hash, compare]

and let_def = Rec of let_each list | Nonrec of let_each
[@@deriving sexp, equal, hash, compare]

and module_def =
  | Struct of toplevel list
  | Named of Uppercase.t Qualified.t
  | Functor_app of module_def * module_def list
  | Module_typed of module_def * module_sig
[@@deriving sexp, equal, hash, compare]

and expr =
  | Node of node
  | If of expr * expr * expr
  | Lambda of Binding.t * expr
  | App of
      expr
      * expr (* these should just be node | App but that makes it more clunky *)
  | Let_in of let_def * expr
  | Match of expr * (Binding.t * expr) list
  | Typed of expr * Value_tag.t
[@@deriving sexp, equal, hash, compare]

and toplevel =
  (* | Type_def of Type_def_lit.t type_description list [@sexp.list] *)
  | Type_def of Type_def_lit.t type_description
  | Let of let_def
  (* TODO: | Module_type of Uppercase.t * module_sig *)
  | Module_def of {
      module_description : module_sig option module_description;
      module_def : module_def;
    }
[@@deriving sexp, equal, hash, compare]

and t = toplevel list [@@deriving sexp, equal, hash, compare]
