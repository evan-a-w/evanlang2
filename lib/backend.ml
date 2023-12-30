open! Core
open! Ast
open! Types
open! Type_check

let reach_end = Typed_ast.reach_end

exception Invalid_type of mono
exception Invalid_user_type of user_type

module Inst_map = Map.Make (struct
    type t = mono String.Map.t [@@deriving sexp, compare]
  end)

type var =
  { name : string
  ; gen_expr : Typed_ast.gen_expr
  ; mutable cache : string Inst_map.t
  }

module Mono_list_map = Map.Make (struct
    type t = mono list [@@deriving sexp, compare]
  end)

type type_cache = string Mono_list_map.t ref

(* TODO: make the mem expr thingos work for sure *)

type state =
  { input : Type_check.output
  ; extern_vars : string String.Table.t
  ; vars : var String.Table.t
  ; inst_user_types : type_cache String.Table.t
  ; mutable inst_monos : string Mono_map.t
  ; type_decl_buf : Bigbuffer.t
  ; type_buf : Bigbuffer.t
  ; decl_buf : Bigbuffer.t
  ; def_buf : Bigbuffer.t
  ; var_counter : Counter.t
  }

let rec c_type_of_user_type ~state ({ monos; inst_user_mono; _ } as inst) =
  let ({ repr_name; info; _ } as user_type) = get_user_type inst in
  let map_ref =
    Hashtbl.find_or_add state.inst_user_types repr_name ~default:(fun () ->
      ref Mono_list_map.empty)
  in
  let monos = List.map monos ~f:reach_end in
  match Map.find !map_ref monos with
  | Some x -> x
  | None ->
    let name = string_of_mono (`User inst) in
    let data = "struct " ^ name in
    Bigbuffer.add_string state.type_decl_buf [%string {|%{data};|}];
    map_ref := Map.set !map_ref ~key:monos ~data;
    (match inst_user_mono with
     | Some m -> c_type_of_mono ~state m
     | None ->
       (match !info with
        | None -> raise (Invalid_user_type user_type)
        | Some x ->
          (match x with
           | `Alias _ -> failwith "impossible"
           | `Struct l ->
             define_struct ~state ~name ~l;
             data
           | `Enum l ->
             define_enum ~state ~name ~l;
             data)))

and c_type_of_mono ~state (mono : mono) =
  let mono = reach_end mono in
  match mono with
  | `Bool -> "bool"
  | `I64 -> "int64_t"
  | `C_int -> "int"
  | `F64 -> "double"
  | `Unit -> "void"
  | `Char -> "char"
  | `User x -> c_type_of_user_type ~state x
  | `Opaque x -> c_type_of_mono ~state x
  | `Pointer x ->
    let x = c_type_of_mono ~state x in
    x ^ "*"
  | `Function (a, b) ->
    (match Map.find state.inst_monos mono with
     | Some x -> x
     | None ->
       let name = string_of_mono mono in
       state.inst_monos <- Map.set state.inst_monos ~key:mono ~data:name;
       let args =
         match a with
         | `Tuple l -> l
         | _ -> [ a ]
       in
       Bigbuffer.add_string
         state.type_buf
         (function_typedef_string ~state ~name ~args ~ret:b);
       name)
  | `Tuple l ->
    (match Map.find state.inst_monos mono with
     | Some x -> x
     | None ->
       let mono_name = string_of_mono mono in
       let name = "struct " ^ mono_name in
       state.inst_monos <- Map.set state.inst_monos ~key:mono ~data:name;
       let fields =
         List.mapi l ~f:(fun i x ->
           let a = [%string {| %{mono_name}_%{i#Int} |}] in
           let b = c_type_of_mono ~state x in
           [%string {|%{b} %{a};|}])
         |> String.concat ~sep:"\n"
       in
       Bigbuffer.add_string state.type_buf [%string {|%{name} {%{fields}};|}];
       name)
  | `Indir _ | `Var _ -> raise (Invalid_type mono)

and declare_function ~state ~name ~args ~ret =
  let args =
    List.filter_map args ~f:(fun (_, mono) ->
      match mono with
      | `Unit -> None
      | _ -> Some (c_type_of_mono ~state mono))
    |> String.concat ~sep:", "
  in
  let ret = c_type_of_mono ~state ret in
  Bigbuffer.add_string state.decl_buf [%string {|%{ret} %{name}(%{args});|}]

and function_typedef_string ~state ~name ~args ~ret =
  let args =
    List.filter_map args ~f:(fun mono ->
      match mono with
      | `Unit -> None
      | _ -> Some (c_type_of_mono ~state mono))
    |> String.concat ~sep:", "
  in
  let ret = c_type_of_mono ~state ret in
  [%string {|typedef %{ret} (*%{name})(%{args});|}]

and define_struct ~state ~name ~l =
  let l =
    List.map l ~f:(fun (a, b) ->
      match reach_end b with
      | `Unit -> ""
      | _ ->
        let b = c_type_of_mono ~state b in
        [%string {|%{b} %{a};|}])
    |> String.concat ~sep:"\n"
  in
  Bigbuffer.add_string state.type_buf [%string {|struct %{name} {%{l}};|}]

and enum_tag ~name ~variant =
  String.uppercase name ^ "_" ^ String.uppercase variant ^ "_TAG"

and define_enum ~state ~name ~l =
  let tags =
    List.map l ~f:(fun (a, _) -> enum_tag ~name ~variant:a)
    |> String.concat ~sep:", "
  in
  (* first define the enum *)
  let enum_name = [%string "enum %{name}_tag"] in
  Bigbuffer.add_string state.type_buf [%string {| %{enum_name} {%{tags}}; |}];
  let union_inside =
    List.filter_map l ~f:(fun (a, b) ->
      match b with
      | None -> None
      | Some b ->
        (match reach_end b with
         | `Unit -> None
         | _ ->
           let b = c_type_of_mono ~state b in
           Some [%string {|%{b} %{a};|}]))
    |> String.concat ~sep:"\n"
  in
  Bigbuffer.add_string
    state.type_buf
    [%string
      {| struct %{name} {
           %{enum_name} tag;
           union {
               %{union_inside}
           } data;
         };
      |}]
;;

let declare_extern ~state ~name ~mono =
  let mono = reach_end mono in
  match mono with
  | `Unit -> ()
  | _ ->
    let c_type = c_type_of_mono ~state mono in
    Bigbuffer.add_string state.decl_buf [%string {|extern %{c_type} %{name};|}]
;;

let rec var_to_string_inner ~state ~inst_map (var : Var.var) =
  let gen_expr =
    match var.Var.typed_expr with
    | None -> failwith "untyped var!"
    | Some x -> x
  in
  let comp_var =
    Hashtbl.find_or_add state.vars var.Var.name ~default:(fun () ->
      { name = var.Var.name; gen_expr; cache = Inst_map.empty })
  in
  let expr_inner, poly = gen_expr in
  let ((expr_inner, mono) as expr) =
    (expr_inner, poly_inner poly)
    |> Typed_ast.expr_map_rec
         ~on_expr_inner:Fn.id
         ~on_mono:(inst_mono ~inst_map)
  in
  match Map.find comp_var.cache inst_map with
  | Some x -> x
  | None ->
    let suffix =
      Map.data inst_map |> List.map ~f:string_of_mono |> String.concat ~sep:"_"
    in
    let name =
      match Map.length inst_map with
      | 0 -> comp_var.name
      | _ -> comp_var.name ^ "_inst_" ^ suffix
    in
    comp_var.cache <- Map.set comp_var.cache ~key:inst_map ~data:name;
    (match var.Var.args with
     | `Non_func ->
       (match mono with
        | `Unit -> ""
        | _ ->
          declare_val ~state ~name ~mono;
          define_val ~state ~name ~mono ~expr_inner;
          name)
     | `Func args ->
       let args = List.map args ~f:(fun (s, m) -> s, inst_mono ~inst_map m) in
       declare_function ~state ~name ~args ~ret:mono;
       define_func ~state ~name ~args ~ret:mono ~expr;
       name)

and var_to_string ~state ~inst_map var =
  match var with
  | Var.El var -> var_to_string_inner ~state ~inst_map var
  | Implicit_extern (_, extern_name, _) -> extern_name
  | Extern (internal_name, extern_name, mono) ->
    (match mono with
     | `Unit -> ""
     | _ ->
       Hashtbl.find_or_add state.extern_vars internal_name ~default:(fun () ->
         declare_extern ~state ~name:extern_name ~mono;
         extern_name))

and define_val ~state ~name ~mono ~expr_inner =
  match mono with
  | `Unit -> ()
  | _ ->
    ignore
      (define_inner_val_with_name
         ~state
         ~buf:state.def_buf
         ~name
         (expr_inner, mono))

and define_func ~state ~name ~args ~ret ~expr =
  let buf = Bigbuffer.create 100 in
  function_definition ~state ~buf ~name ~args ~ret;
  Bigbuffer.add_string buf "{ ";
  let s = expr_to_string ~state ~buf ~expr in
  (match snd expr |> reach_end with
   | `Unit -> ()
   | _ -> Bigbuffer.add_string buf [%string {| return %{s}; |}]);
  Bigbuffer.add_string buf " }";
  Bigbuffer.add_buffer state.def_buf buf

and function_definition ~state ~buf ~name ~args ~ret =
  let ret = c_type_of_mono ~state ret in
  let args =
    List.filter_map args ~f:(fun (a, b) ->
      match b with
      | `Unit -> None
      | _ -> Some [%string {|%{c_type_of_mono ~state b} %{a}|}])
    |> String.concat ~sep:", "
  in
  Bigbuffer.add_string buf [%string {|%{ret} %{name}(%{args})|}]

and declare_inner_val ~state ~buf ~name ~mono =
  let mono = reach_end mono in
  match mono with
  | `Unit -> ()
  | _ ->
    let c_type = c_type_of_mono ~state mono in
    Bigbuffer.add_string buf [%string {|%{c_type} %{name};|}]

and declare_val ~state ~name ~mono =
  declare_inner_val ~state ~buf:state.decl_buf ~name ~mono

and add_equal name =
  match name with
  | "" -> ""
  | _ -> name ^ " = "

and nameify name ~expr =
  match fst expr, snd expr |> reach_end with
  | _, `Unit | `Assert (`Bool false, _), _ -> ""
  | _ -> name

and define_inner_val_with_name ~state ~buf ~name expr =
  let name = nameify name ~expr in
  let expr = expr_to_string ~state ~buf ~expr in
  Bigbuffer.add_string buf [%string {| %{add_equal name}%{expr}; |}];
  name

and create_inner_val_with_name ~state ~buf ~name expr =
  declare_inner_val ~state ~buf ~name ~mono:(snd expr);
  define_inner_val_with_name ~state ~buf ~name expr

and create_inner_val ~state ~buf expr =
  let name = unique_name state.var_counter in
  create_inner_val_with_name ~state ~buf ~name expr

and expr_to_string ~state ~buf ~expr:(expr_inner, mono) =
  let get_typ_no_struct mono =
    let typ = c_type_of_mono ~state mono in
    typ, String.chop_prefix_if_exists ~prefix:"struct " typ
  in
  match expr_inner with
  | `Null -> "NULL"
  | `Bool true -> "true"
  | `Bool false -> "false"
  | `Tuple l ->
    let _, typ_no_struct = get_typ_no_struct mono in
    let inners =
      List.map l ~f:(create_inner_val ~state ~buf)
      |> List.mapi ~f:(fun i s ->
        [%string {| .%{typ_no_struct}_%{i#Int} = %{s} |}])
      |> String.concat ~sep:", "
    in
    [%string "(%{c_type_of_mono ~state mono}){ %{inners} }"]
  | `Index (a, b) ->
    let a = expr_to_string ~state ~buf ~expr:a in
    let b = expr_to_string ~state ~buf ~expr:b in
    [%string {| (%{a})[%{b}] |}]
  | `Tuple_access ((a, am), i) ->
    let _, typ_no_struct = get_typ_no_struct am in
    let num =
      match am with
      | `Tuple l -> List.length l
      | _ -> 0
    in
    let a = expr_to_string ~state ~expr:(a, am) ~buf in
    (match i < num with
     | true -> [%string {| (%{a}).%{typ_no_struct}_%{i#Int} |}]
     | false -> failwith "tuple access out of bounds")
  | `Assign (a, b) ->
    let a = expr_to_string ~state ~expr:a ~buf in
    let a = nameify a ~expr:b in
    let b = expr_to_string ~state ~expr:b ~buf in
    [%string {| %{add_equal a}%{b}; |}]
  | `Glob_var (name, inst_map) ->
    let var = Hashtbl.find_exn state.input.glob_vars name in
    var_to_string ~state ~inst_map var
  | `Local_var name ->
    (match reach_end mono with
     | `Unit -> ""
     | _ -> name)
  | `Access_enum_field (field, expr) ->
    let expr = expr_to_string ~state ~expr ~buf in
    [%string {| (%{expr}).data.%{field} |}]
  | `Compound l ->
    let len = List.length l in
    let last = ref None in
    List.iteri l ~f:(fun i expr ->
      let s = expr_to_string ~state ~expr ~buf in
      match i = len - 1 with
      | true -> last := Some s
      | false ->
        Bigbuffer.add_string buf s;
        Bigbuffer.add_string buf "; ");
    Option.value_exn !last
  | `Inf_op (op, a, b) ->
    let a = expr_to_string ~buf ~state ~expr:a in
    let b = expr_to_string ~buf ~state ~expr:b in
    let op =
      match op with
      | `Ge -> ">"
      | `Rem -> "%"
      | `Div -> "/"
      | `Add -> "+"
      | `Lt -> "<"
      | `And -> "&&"
      | `Sub -> "-"
      | `Eq -> "=="
      | `Le -> "<"
      | `Or -> "||"
      | `Gt -> ">"
      | `Mul -> "*"
      | `Ne -> "!="
    in
    [%string {| ((%{a}) %{op} (%{b})) |}]
  | `Field_access (expr, field) ->
    let expr = expr_to_string ~state ~buf ~expr in
    [%string {| %{expr}.%{field} |}]
  | `Float x -> Float.to_string x
  | `Unit -> ""
  | `Ref e -> [%string "&(%{expr_to_string ~state ~buf ~expr:e })"]
  | `Deref e -> [%string "(*(%{expr_to_string ~state ~buf ~expr:e }))"]
  | `Char x -> [%string "'%{x#Char}'"]
  | `String s -> [%string {| "%{s}" |}]
  | `Int i -> [%string {| %{i#Int} |}]
  | `Check_variant (variant, expr) ->
    let _, typ_no_struct = get_typ_no_struct (snd expr) in
    let variant = enum_tag ~name:typ_no_struct ~variant in
    [%string {| ((%{expr_to_string ~state ~expr  ~buf}).tag == %{variant}) |}]
  | `Pref_op (op, e) ->
    let e = expr_to_string ~state ~buf ~expr:e in
    let op =
      match op with
      | `Minus -> "-"
    in
    [%string {| %{op}(%{e}) |}]
  | `Enum (s, p) ->
    let typ, typ_no_struct = get_typ_no_struct mono in
    let variant = enum_tag ~name:typ_no_struct ~variant:s in
    let union =
      match p with
      | None -> ""
      | Some p ->
        let var = create_inner_val ~state ~buf p in
        [%string {| , .data = { .%{s} = %{var} } |}]
    in
    [%string {| (%{typ}){ .tag = %{variant}%{union} } |}]
  | `Struct (_, fields) ->
    let typ, _ = get_typ_no_struct mono in
    let fields =
      List.map fields ~f:(fun (s, p) ->
        let expr = create_inner_val ~state ~buf p in
        [%string {| .%{s} = %{expr} |}])
      |> String.concat ~sep:", "
    in
    [%string {| (%{typ}){ %{fields} } |}]
  | `Apply (a, ((be, _) as b)) ->
    let args =
      match be with
      | `Tuple l -> List.map l ~f:(create_inner_val ~state ~buf)
      | _ -> [ create_inner_val ~state ~buf b ]
    in
    let args = String.concat ~sep:", " args in
    let a = expr_to_string ~state ~buf ~expr:a in
    [%string {| (%{a})(%{args}) |}]
  | `Let (name, a, b) ->
    let (_ : string) = create_inner_val_with_name ~state ~buf ~name a in
    expr_to_string ~state ~buf ~expr:b
  | `If (a, b, c) ->
    let name =
      match snd b |> reach_end with
      | `Unit -> ""
      | _ ->
        let name = unique_name state.var_counter in
        declare_inner_val ~state ~buf ~name ~mono;
        name
    in
    let b_name = nameify name ~expr:b in
    let c_name = nameify name ~expr:c in
    let a = expr_to_string ~state ~buf ~expr:a in
    Bigbuffer.add_string buf [%string {| if (%{a}) { |}];
    let b = expr_to_string ~state ~buf ~expr:b in
    Bigbuffer.add_string buf [%string {| %{add_equal b_name}%{b};} else { |}];
    let c = expr_to_string ~state ~buf ~expr:c in
    Bigbuffer.add_string buf [%string {| %{add_equal c_name}%{c};} |}];
    name
  | `Assert e -> [%string {| assert(%{expr_to_string ~state ~buf ~expr:e}) |}]
;;

let state_of_input input =
  { input
  ; vars = String.Table.create ()
  ; extern_vars = String.Table.create ()
  ; inst_user_types = String.Table.create ()
  ; inst_monos = Mono_map.empty
  ; type_buf = Bigbuffer.create 100
  ; type_decl_buf = Bigbuffer.create 100
  ; decl_buf = Bigbuffer.create 100
  ; def_buf = Bigbuffer.create 100
  ; var_counter = input.var_counter
  }
;;

let headers =
  "#include <stdint.h>\n\
   #include <stdbool.h>\n\
   #include <stdlib.h>\n\
   #include <string.h>\n\
   #include <assert.h>\n\
   #include <stdio.h>\n"
;;

let compile ~input =
  let state = state_of_input input in
  Hashtbl.iteri input.types ~f:(fun ~key:_ ~data ->
    match data.ty_vars with
    | [] ->
      let inst_user_type =
        { monos = []; user_type = Insted data; inst_user_mono = None }
      in
      ignore (c_type_of_user_type ~state inst_user_type)
    | _ -> ());
  Hashtbl.iteri input.glob_vars ~f:(fun ~key:_ ~data ->
    (* inst all monomorphic thingos *)
    match data with
    | Var.El { poly = `Mono _; _ } | Extern _ ->
      ignore (var_to_string ~state ~inst_map:String.Map.empty data)
    | _ -> ());
  Out_channel.output_string Out_channel.stdout headers;
  Bigbuffer.contents state.type_decl_buf
  |> Out_channel.output_string Out_channel.stdout;
  Bigbuffer.contents state.type_buf
  |> Out_channel.output_string Out_channel.stdout;
  Bigbuffer.contents state.decl_buf
  |> Out_channel.output_string Out_channel.stdout;
  Bigbuffer.contents state.def_buf
  |> Out_channel.output_string Out_channel.stdout
;;

let print_typed_ast toplevels =
  let input = Type_check.type_check toplevels in
  Hashtbl.iter input.glob_vars ~f:(fun var ->
    match var with
    | Var.El { poly; name; typed_expr; _ } ->
      let expr_inner, poly' = Option.value_exn typed_expr in
      let mono = poly_inner poly' in
      Pretty_print.print ~name ~poly ~typed_ast:(expr_inner, mono)
    | _ -> ())
;;

let compile_fully toplevels =
  let input = Type_check.type_check toplevels in
  compile ~input
;;
