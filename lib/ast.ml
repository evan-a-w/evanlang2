open! Core

type t =
  | Let of string * t
  | Lambda of string * t
  | App of t * t
  | Let_in of string * t * t
  | If of t * t * t
  | Var of string
  | Unit
  | Int of int
  | Bool of bool
  | Float of float
  | String of string
[@@deriving sexp]
