open! Core
open! Ast
open! Types
open Type_common

type unification_error =
  | Failed_to_match of
      { sub : unification_error
      ; failed : mono * mono
      }
  | End
[@@deriving sexp]

let rec show_unification_error = function
  | Failed_to_match { sub; failed = a, b } ->
    [%string
      {| Failed to match %{a |> show_mono} and %{b |> show_mono} because %{show_unification_error sub} |}]
  | End -> "End"
;;

let print_sccs = false

exception Unification_error of unification_error

exception
  Module_cycle of
    { from_module : string
    ; offending_module : string
    }

exception Early_exit

let unel2_file filename =
  try
    let name = Filename.basename filename in
    let rex = Re.Pcre.regexp {|[a-z]([a-z0-9_]*)\.el2$|} in
    let group = Re.Pcre.exec ~rex name in
    let rest = Re.Group.get group 1 in
    let fst_char = name.[0] |> Char.uppercase in
    [%string "%{fst_char#Char}%{rest}"]
  with
  | _ -> failwith [%string {|Invalid filename: `%{filename}`|}]
;;

let el2_file dir name =
  let fst_char = name.[0] |> Char.lowercase in
  let rest_chars = String.sub name ~pos:1 ~len:(String.length name - 1) in
  Filename.concat dir [%string "%{fst_char#Char}%{rest_chars}.el2"]
;;

let rec unify a b =
  let fl sub a b =
    raise (Unification_error (Failed_to_match { failed = a, b; sub }))
  in
  try
    let a, b = inner_mono a, inner_mono b in
    if phys_equal a b then raise Early_exit;
    match a, b with
    | `Unit, `Unit | `I64, `I64 | `F64, `F64 | `Bool, `Bool | `Char, `Char -> a
    | `Pointer a, `Pointer b -> `Pointer (unify a b)
    | `Tuple l1, `Tuple l2 ->
      `Tuple (List.zip_exn l1 l2 |> List.map ~f:(fun (a, b) -> unify a b))
    | `Function (a, b), `Function (c, d) -> `Function (unify a c, unify b d)
    | `Var (_, r), o | o, `Var (_, r) | `Indir (_, r), o | o, `Indir (_, r) ->
      let m =
        match !r with
        | None -> o
        | Some m -> unify m o
      in
      r := Some m;
      m
    | `User a, `User b
      when String.equal a.orig_user_type.repr_name b.orig_user_type.repr_name ->
      let monos =
        List.zip_exn a.monos b.monos |> List.map ~f:(fun (a, b) -> unify a b)
      in
      `User { a with monos }
    | `User u, o | o, `User u ->
      (match user_type_monify u with
       | None -> raise (Unification_error End)
       | Some a -> unify a o)
    (* Opaque should only unify earlier with user_types exactly matching *)
    | `Opaque _, _ | _, `Opaque _ | _ -> raise (Unification_error End)
  with
  | Early_exit -> a
  | Unification_error sub -> fl sub a b
  (* this is just to catch exns from List.zip_exn *)
  | Invalid_argument _ -> fl End a b
;;

let get_user_type_field user_type field =
  match !(user_type.info) with
  | Some (`Struct l) ->
    List.find l ~f:(fun (a, _) -> String.equal a field)
    |> Option.map ~f:Tuple2.get2
  | _ -> None
;;

let get_user_type_variant user_type variant =
  match !(user_type.info) with
  | Some (`Enum l) ->
    List.find l ~f:(fun (a, _) -> String.equal a variant)
    |> Option.map ~f:Tuple2.get2
  | _ -> None
;;

let internal_var counter = "internal_" ^ Counter.next_num counter

module Type_state = struct
  module T = struct
    type module_name = string [@@deriving sexp, compare]

    module Module_name_set = Set.Make (struct
        type t = module_name [@@deriving sexp, compare]
      end)

    type module_t =
      { name : module_name
      ; filename : string
      ; sub_modules : module_t String.Table.t
      ; glob_vars : module_t list Typed_ast.top_var String.Table.t
      ; types : user_type String.Table.t
      ; variant_to_type : user_type String.Table.t
      ; field_to_type : user_type String.Table.t
      ; mutable in_eval : bool
      ; parent : module_t option
      }
    [@@deriving sexp]

    type t =
      { current_module : module_t
      ; seen_modules : module_t String.Table.t
      ; opened_modules : module_t list
      ; module_stack : module_t list
      ; locals : mono String.Map.t
      ; ty_vars : mono String.Map.t
      ; ty_var_counter : Counter.t
      ; var_counter : Counter.t
      ; seen_vars : String.Hash_set.t
      ; seen_types : String.Hash_set.t
      }
    [@@deriving sexp]
  end

  include T

  let default_types () = String.Table.of_alist_exn []

  let rec unique_name t =
    let name = internal_var t.var_counter in
    if Hash_set.mem t.seen_vars name
    then unique_name t
    else (
      Hash_set.add t.seen_vars name;
      name)
  ;;

  let module_prefix module_t =
    let buf = Buffer.create 16 in
    let rec go module_t =
      (match module_t.parent with
       | None -> ()
       | Some p -> go p);
      Buffer.add_string buf module_t.name;
      Buffer.add_char buf '_'
    in
    go module_t;
    Buffer.contents buf
  ;;

  let register_name ~state name =
    match Hash_set.mem state.seen_vars name with
    | false -> Hash_set.add state.seen_vars name
    | true -> failwith [%string "Name linked multiple times: `%{name}`"]
  ;;

  let make_unique_helper ~state name =
    let prefix = module_prefix state.current_module in
    let name = prefix ^ name in
    let rec loop i =
      let name = name ^ Int.to_string i in
      match Hash_set.mem state.seen_vars name with
      | false ->
        Hash_set.add state.seen_vars name;
        name
      | true -> loop (i + 1)
    in
    match Hash_set.mem state.seen_vars name with
    | false ->
      Hash_set.add state.seen_vars name;
      name
    | true -> loop 0
  ;;

  let make_unique ~state name =
    match name with
    | "main" when Hash_set.mem state.seen_vars "main" ->
      failwith "Duplicate main functions"
    | "main" ->
      Hash_set.add state.seen_vars name;
      name
    | _ -> make_unique_helper ~state name
  ;;

  let make_unique_type ~state name =
    let prefix = module_prefix state.current_module in
    let name = prefix ^ name in
    let rec loop i =
      let name = name ^ Int.to_string i in
      match Hash_set.mem state.seen_types name with
      | false ->
        Hash_set.add state.seen_types name;
        name
      | true -> loop (i + 1)
    in
    match Hash_set.mem state.seen_types name with
    | false ->
      Hash_set.add state.seen_types name;
      name
    | true -> loop 0
  ;;

  let module_create filename =
    { name = unel2_file filename
    ; filename
    ; sub_modules = String.Table.create ()
    ; glob_vars = String.Table.create ()
    ; types = default_types ()
    ; variant_to_type = String.Table.create ()
    ; field_to_type = String.Table.create ()
    ; in_eval = false
    ; parent = None
    }
  ;;

  let create filename =
    let current_module = module_create filename in
    { current_module
    ; opened_modules = []
    ; seen_modules =
        String.Table.of_alist_exn [ current_module.filename, current_module ]
    ; module_stack = []
    ; locals = String.Map.empty
    ; ty_vars = String.Map.empty
    ; ty_var_counter = Counter.create ()
    ; var_counter = Counter.create ()
    ; seen_vars = String.Hash_set.create ()
    ; seen_types = String.Hash_set.create ()
    }
  ;;

  let push_module ~module_t t =
    Hashtbl.set t.seen_modules ~key:module_t.filename ~data:module_t;
    { t with
      module_stack = t.current_module :: t.module_stack
    ; current_module = module_t
    }
  ;;

  let lookup_module_in names ~in_:module_t =
    let rec loop m names' =
      match names' with
      | [] -> Ok m
      | name :: names' ->
        (match Hashtbl.find m.sub_modules name with
         | Some m -> loop m names'
         | None -> Error name)
    in
    loop module_t names
  ;;

  let lookup_module_in_exn names ~in_ =
    match lookup_module_in names ~in_ with
    | Ok a -> a
    | Error name ->
      failwith
        [%string
          "Unknown module `%{name}` in chain `%{String.concat ~sep:\" \" \
           names}`"]
  ;;

  let lookup_module_exn ~state ~if_missing names =
    match names with
    | [] -> state.current_module
    | fst :: _ ->
      (match Hashtbl.find state.current_module.sub_modules fst with
       | None -> if_missing fst
       | _ -> ());
      lookup_module_in_exn names ~in_:state.current_module
  ;;

  let try_on_all_modules state ~try_make_module ~module_path ~f =
    let rec loop opened_modules =
      match opened_modules with
      | [] -> None
      | module_t :: opened_modules ->
        (match f module_path module_t with
         | Some _ as res -> res
         | None -> loop opened_modules)
    in
    match f module_path state.current_module with
    | Some _ as res -> res
    | None ->
      let on_newly_created =
        match module_path with
        | [] -> None
        | fst :: rest -> Option.bind (try_make_module ~state fst) ~f:(f rest)
      in
      (match on_newly_created with
       | Some _ as res -> res
       | None -> loop state.opened_modules)
  ;;
end

type expr = Type_state.module_t list Typed_ast.expr
type expr_inner = Type_state.module_t list Typed_ast.expr_inner
type gen_expr = Type_state.module_t list Typed_ast.gen_expr
type var = Type_state.module_t list Typed_ast.var
type top_var = Type_state.module_t list Typed_ast.top_var

let make_user_type ~repr_name ~name ~ty_vars =
  { repr_name; name; ty_vars; info = ref None }
;;

type ty_var_map = mono String.Map.t [@@deriving sexp]
type locals_map = mono String.Map.t

let empty_ty_vars : ty_var_map = String.Map.empty

let get_non_user_type ~make_ty_vars ~state name =
  match name with
  | "i64" -> `I64
  | "c_int" -> `C_int
  | "f64" -> `F64
  | "bool" -> `Bool
  | "char" -> `Char
  | "unit" -> `Unit
  | "_" when make_ty_vars -> make_indir ()
  | _ ->
    (match Map.find state.Type_state.ty_vars name with
     | None -> failwith [%string "Unknown type `%{name}`"]
     | Some a -> a)
;;

let find_module_in_submodules ~state ~try_make_module ~f module_path =
  Type_state.try_on_all_modules
    ~f:(fun module_path module_t ->
      match Type_state.lookup_module_in ~in_:module_t module_path with
      | Error _ -> None
      | Ok module_t -> f module_t)
    ~try_make_module
    ~module_path
    state
;;

let poly_inner (poly : poly) =
  let rec go = function
    | `Mono mono -> mono
    | `For_all (_, r) -> go r
  in
  go poly
;;

let gen_helper ~vars ~indirs ~counter ~used mono : mono =
  let add mono' =
    match mono' with
    | `Var (s, _) ->
      if not (Hash_set.mem used s)
      then (
        Hash_set.add used s;
        Hashtbl.set vars ~key:s ~data:mono');
      mono'
    | _ -> mono'
  in
  let default () =
    let next_var = Counter.next_alphabetical counter in
    make_var_mono next_var
  in
  mono_map_rec_keep_refs mono ~f:(fun mono ->
    let mono' = inner_mono mono in
    match mono' with
    | `Var (x, _) -> Hashtbl.find_or_add vars x ~default |> add
    | `Indir (i, _) -> Hashtbl.find_or_add indirs i ~default |> add
    | _ -> mono')
;;

let make_weak_helper ~vars ~indirs mono : mono =
  mono_map_rec_keep_refs mono ~f:(fun mono ->
    let mono' = inner_mono mono in
    match mono' with
    | `Var (x, _) -> Hashtbl.find_or_add vars x ~default:make_indir
    | `Indir (i, _) -> Hashtbl.find_or_add indirs i ~default:make_indir
    | _ -> mono)
;;

let make_vars_weak ~vars ~indirs mono : poly =
  let mono =
    mono_map_rec_keep_refs
      ~f:(fun mono -> inner_mono mono |> make_weak_helper ~vars ~indirs)
      mono
  in
  `Mono mono
;;

let gen_mono ~counter ~vars ~indirs mono =
  let used = String.Hash_set.create () in
  inner_mono mono
  |> mono_map_rec_keep_refs ~f:(fun mono ->
    inner_mono mono |> gen_helper ~vars ~indirs ~counter ~used)
;;

let gen ~counter ~vars ~indirs mono =
  let used = String.Hash_set.create () in
  let mono =
    inner_mono mono
    |> mono_map_rec_keep_refs ~f:(fun mono ->
      inner_mono mono |> gen_helper ~vars ~indirs ~counter ~used)
  in
  Hash_set.fold used ~init:(`Mono mono) ~f:(fun acc key -> `For_all (key, acc))
;;

let gen_expr ~counter ~vars ~indirs (expr : expr) : gen_expr =
  let used = String.Hash_set.create () in
  let expr_inner, mono =
    Typed_ast.expr_map_monos expr ~f:(fun mono ->
      inner_mono mono |> gen_helper ~vars ~indirs ~counter ~used)
  in
  let poly =
    Hash_set.fold used ~init:(`Mono mono) ~f:(fun acc key ->
      `For_all (key, acc))
  in
  expr_inner, poly
;;

let make_vars_weak_expr ~vars ~indirs (expr : expr) : gen_expr =
  let expr_inner, mono =
    Typed_ast.expr_map_rec expr ~on_expr_inner:Fn.id ~on_mono:(fun mono ->
      inner_mono mono |> make_weak_helper ~vars ~indirs)
  in
  expr_inner, `Mono mono
;;

let state_add_local state ~name ~mono =
  { state with
    Type_state.locals = Map.set state.Type_state.locals ~key:name ~data:mono
  }
;;

let rec try_make_module ~state name =
  let filename =
    el2_file (Filename.dirname state.Type_state.current_module.filename) name
  in
  match Stdlib.Sys.file_exists filename with
  | false -> None
  | true -> Some (process_module ~state filename)

and inst_user_type_exn inst_user_type =
  get_insted_user_type inst_user_type
  |> Option.value_or_thunk ~default:(fun () -> failwith "Undefined type")

and get_user_type_variant_exn ~variant inst_user_type =
  let insted = inst_user_type_exn inst_user_type in
  match get_user_type_variant insted variant with
  | Some x -> x
  | None -> failwith [%string "Unknown variant %{variant}"]

and get_user_type_variant_with_data_exn ~variant inst_user_type =
  get_user_type_variant_exn inst_user_type ~variant
  |> Option.value_or_thunk ~default:(fun () ->
    failwith
      [%string
        {| Variant does not have any data: `%{variant}`
               in %{show_mono (`User inst_user_type)}|}])

and get_user_type_variant_without_data_exn ~variant inst_user_type =
  match get_user_type_variant_exn inst_user_type ~variant with
  | None -> ()
  | Some _ ->
    failwith
      [%string
        {| Variant has data: `%{variant}`
               in %{show_mono (`User inst_user_type)}|}]

and lookup_and_inst_user_type ~state (path : string path) =
  let user_type = lookup_user_type ~state path in
  inst_user_type_gen user_type

and get_user_type_from_field_exn ~state field =
  let user_type' = lookup_field ~state field in
  let inst_user_type = inst_user_type_gen user_type' in
  let res_type = get_user_type_field_exn inst_user_type ~field:field.inner in
  inst_user_type, res_type

and get_user_type_from_variant_exn ~state variant =
  let user_type' = lookup_variant ~state variant in
  let inst_user_type = inst_user_type_gen user_type' in
  let res_type =
    get_user_type_variant_with_data_exn inst_user_type ~variant:variant.inner
  in
  inst_user_type, res_type

and get_user_type_from_variant_no_data_exn ~state variant =
  let user_type' = lookup_variant ~state variant in
  let inst_user_type = inst_user_type_gen user_type' in
  get_user_type_variant_without_data_exn inst_user_type ~variant:variant.inner;
  inst_user_type

and get_struct_list_exn ~state s =
  let user_type = lookup_and_inst_user_type ~state s in
  ( user_type
  , (match get_insted_user_type user_type with
     | Some { info = { contents = Some (`Struct l) }; _ } -> l
     | _ -> failwith [%string "Not a struct: %{show_path Fn.id s}"])
    |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b) )

and get_user_type_field_exn ~field inst_user_type =
  let insted = inst_user_type_exn inst_user_type in
  match get_user_type_field insted field with
  | Some x -> x
  | None -> failwith [%string "Unknown field %{field}"]

and lookup_var ~state ({ inner = name; module_path } as p) =
  let f module_t = Hashtbl.find module_t.Type_state.glob_vars name in
  match find_module_in_submodules ~try_make_module ~state ~f module_path with
  | None -> failwith [%string "Unknown variable %{show_path Fn.id p}"]
  | Some x -> x

and lookup_user_type_opt ~state ({ module_path; inner = name } : string path) =
  let f module_t = Hashtbl.find module_t.Type_state.types name in
  find_module_in_submodules ~try_make_module ~state module_path ~f

and lookup_user_type ~state (p : string path) =
  match lookup_user_type_opt ~state p with
  | None -> failwith [%string "Unknown type %{show_path Fn.id p}"]
  | Some x -> x

and lookup_variant ~state { module_path; inner = name } =
  let f module_t = Hashtbl.find module_t.Type_state.variant_to_type name in
  match find_module_in_submodules ~try_make_module ~state module_path ~f with
  | None -> failwith [%string "Unknown variant %{name}"]
  | Some x -> x

and lookup_field ~state { module_path; inner = name } =
  let f module_t = Hashtbl.find module_t.Type_state.field_to_type name in
  match find_module_in_submodules ~try_make_module ~state module_path ~f with
  | None -> failwith [%string "Unknown field %{name}"]
  | Some x -> x

and lookup_mono ~make_ty_vars ~state name =
  match lookup_user_type_opt ~state (empty_path name) with
  | None -> get_non_user_type ~make_ty_vars ~state name
  | Some r ->
    (match r.ty_vars with
     | [] -> `User (inst_user_type_gen r)
     | _ -> failwith [%string "Type %{name} requires type arguments"])

and mono_of_type_expr ?(make_ty_vars = true) ~state (type_expr : type_expr)
  : mono
  =
  let f = mono_of_type_expr ~make_ty_vars ~state in
  match type_expr with
  | `Unit -> `Unit
  | `Named { inner; module_path = [] } -> lookup_mono ~make_ty_vars ~state inner
  | `Named path ->
    let r = lookup_user_type ~state path in
    (match r.ty_vars with
     | [] -> `User (inst_user_type_gen r)
     | _ ->
       failwith [%string "Type %{show_path Fn.id path} requires type arguments"])
  | `Pointer m -> `Pointer (f m)
  | `Tuple l -> `Tuple (List.map l ~f)
  | `Named_args (s, l) ->
    let monos = List.map l ~f in
    let user_type = lookup_user_type ~state s in
    let inst = inst_user_type ~monos user_type in
    `User inst
  | `Function (a, b) -> `Function (f a, f b)

and all_user_of_enum ~state l =
  let variants = String.Hash_set.create () in
  ( `Enum
      (List.map l ~f:(fun (s, t) ->
         if Hash_set.mem variants s
         then failwith [%string "Duplicate variant %{s}"];
         let mono_opt =
           Option.map t ~f:(mono_of_type_expr ~make_ty_vars:false ~state)
         in
         Hash_set.add variants s;
         s, mono_opt))
  , variants )

and all_user_of_struct ~state l =
  let set = Hash_set.create (module String) in
  ( `Struct
      (List.map l ~f:(fun (s, t) ->
         if Hash_set.mem set s then failwith [%string "Duplicate field %{s}"];
         Hash_set.add set s;
         s, mono_of_type_expr ~make_ty_vars:false ~state t))
  , set )

and process_types ~(state : Type_state.t) types =
  Hashtbl.iteri state.current_module.types ~f:(fun ~key ~data:user_type ->
    let ty_vars, decl, opened_modules = Hashtbl.find_exn types key in
    let ty_vars =
      List.fold ty_vars ~init:empty_ty_vars ~f:(fun acc s ->
        let mono = make_var_mono s in
        Map.add_exn acc ~key:s ~data:mono)
    in
    let state = { state with ty_vars; opened_modules } in
    let all_user =
      match decl with
      | `Alias type_expr ->
        `Alias (mono_of_type_expr ~state ~make_ty_vars:false type_expr)
      | `Enum l ->
        let all_user, variants = all_user_of_enum ~state l in
        Hash_set.iter variants ~f:(fun s ->
          match
            Hashtbl.add
              state.current_module.variant_to_type
              ~key:s
              ~data:user_type
          with
          | `Ok -> ()
          | `Duplicate -> failwith [%string "Duplicate variant %{s}"]);
        all_user
      | `Struct l ->
        let all_user, fields = all_user_of_struct ~state l in
        Hash_set.iter fields ~f:(fun s ->
          match
            Hashtbl.add
              state.current_module.field_to_type
              ~key:s
              ~data:user_type
          with
          | `Ok -> ()
          | `Duplicate -> failwith [%string "Duplicate field %{s}"]);
        all_user
    in
    user_type.info := Some all_user)

and breakup_patterns ~state ~vars (pattern : pattern) (expr : Ast.expr) =
  let rep = breakup_patterns ~state ~vars in
  let enqueue_new expanded_expr =
    let var = Type_state.unique_name state in
    Stack.push vars (var, expanded_expr);
    empty_path var
  in
  match pattern with
  | `Bool _ | `Float _ | `Char _ | `String _ | `Int _ | `Null ->
    failwith
      [%string
        "Refutable pattern `%{Sexp.to_string_hum [%sexp (pattern : pattern)]}`"]
  | `Var name -> Stack.push vars (name, expand_expr ~state expr)
  | `Unit ->
    (ignore : string path -> unit)
      (enqueue_new (`Typed (expand_expr ~state expr, `Unit)))
  | `Tuple l ->
    let var = enqueue_new (expand_expr ~state expr) in
    List.iteri l ~f:(fun i p ->
      let expr = `Tuple_access (`Var var, i) in
      rep p expr)
  | `Ref p ->
    let var = enqueue_new (expand_expr ~state expr) in
    rep p (`Deref (`Var var))
  | `Struct (type_name, l) ->
    let var =
      enqueue_new (`Assert_struct (type_name, expand_expr ~state expr))
    in
    List.iter l ~f:(fun (field, opt_p) ->
      let expr = `Field_access (`Var var, { type_name with inner = field }) in
      let p = Option.value opt_p ~default:(`Var field) in
      rep p expr)
  | `Typed (p, type_expr) ->
    let var = enqueue_new (`Typed (expand_expr ~state expr, type_expr)) in
    rep p (`Var var)
  | `Enum (name, opt_p) ->
    (match opt_p with
     | Some p ->
       let var =
         enqueue_new (`Access_enum_field (name, expand_expr ~state expr))
       in
       rep p (`Var var)
     | None ->
       (ignore : string path -> unit)
         (enqueue_new
            (`Assert_empty_enum_field (name, expand_expr ~state expr))))

and expand_let ~state ~init (p, a) =
  let vars = Stack.create () in
  breakup_patterns ~state ~vars p a;
  Stack.fold vars ~init ~f:(fun acc (var, expr) -> `Let (var, expr, acc))

and expand_expr ~state (expr : Ast.expr) : expanded_expr =
  let f = expand_expr ~state in
  match (expr : Ast.expr) with
  | `Null -> `Null
  | `Unit -> `Unit
  | `Bool b -> `Bool b
  | `Var s -> `Var s
  | `Int i -> `Int i
  | `Float f -> `Float f
  | `Char c -> `Char c
  | `String s -> `String s
  | `Enum s -> `Enum s
  | `Assert a -> `Assert (f a)
  | `Array_lit l -> `Array_lit (List.map l ~f)
  | `Tuple l -> `Tuple (List.map l ~f)
  | `Loop a -> `Loop (f a)
  | `Break a -> `Break (f a)
  | `Compound l ->
    let expr =
      List.fold_right l ~init:None ~f:(fun x acc ->
        match x, acc with
        | `Expr e, None -> Some (f e)
        | `Expr e, Some r -> `Let ("_", f e, r) |> Option.some
        | `Let (a, b), None ->
          expand_let ~state ~init:`Unit (a, b) |> Option.some
        | `Let (a, b), Some r -> expand_let ~state ~init:r (a, b) |> Option.some)
      |> Option.value ~default:`Unit
    in
    `Compound expr
  | `Index (a, b) -> `Index (f a, f b)
  | `Inf_op (op, a, b) -> `Inf_op (op, f a, f b)
  | `Assign (a, b) -> `Assign (f a, f b)
  | `Apply (a, b) -> `Apply (f a, f b)
  | `Tuple_access (a, i) -> `Tuple_access (f a, i)
  | `Field_access (a, field) -> `Field_access (f a, field)
  | `Size_of (`Type t) -> `Size_of (`Type t)
  | `Size_of (`Expr e) -> `Size_of (`Expr (f e))
  | `Return a -> `Return (f a)
  | `Ref a -> `Ref (f a)
  | `Deref a -> `Deref (f a)
  | `Pref_op (op, a) -> `Pref_op (op, f a)
  | `Typed (a, type_expr) -> `Typed (f a, type_expr)
  | `Match (a, l) -> `Match (f a, List.map l ~f:(Tuple2.map_snd ~f))
  | `Struct (name, l) ->
    `Struct (name, List.map l ~f:(Tuple2.map_snd ~f:(Option.map ~f)))
  | `If (a, b, c) -> `If (f a, f b, f c)
  | `Unsafe_cast x -> `Unsafe_cast (f x)
  | `Let (p, a, b) ->
    let init = expand_expr ~state b in
    expand_let ~state ~init (p, a)

and function_arg_set ~init l =
  List.fold l ~init ~f:(fun acc ->
      function
      | `Untyped s -> Set.add acc s
      | `Typed (s, _) -> Set.add acc s)

and pattern_vars p ~locals =
  match p with
  | `Bool _ | `Float _ | `Char _ | `String _ | `Int _ | `Null -> locals
  | `Var s -> Set.add locals s
  | `Unit -> locals
  | `Tuple l ->
    List.fold l ~init:locals ~f:(fun locals p -> pattern_vars p ~locals)
  | `Ref p -> pattern_vars p ~locals
  | `Struct (_, l) ->
    List.fold l ~init:locals ~f:(fun acc (f, p) ->
      match p with
      | Some p -> pattern_vars p ~locals:acc
      | None -> Set.add acc f)
  | `Typed (p, _) -> pattern_vars p ~locals
  | `Enum (_, p) ->
    (match p with
     | Some p -> pattern_vars p ~locals
     | None -> locals)

and traverse_expr ~state ~not_found_vars ~edge ~locals (expr : expanded_expr) =
  let rep = traverse_expr ~state ~not_found_vars ~edge in
  match expr with
  | `Bool _ | `Int _ | `Float _ | `Char _ | `String _ | `Enum _ | `Unit | `Null
  | `Size_of (`Type _) -> ()
  | `Var { inner = name'; module_path = [] } when Set.mem locals name' -> ()
  | `Var { inner = name'; module_path } ->
    let f module_t =
      Hashtbl.find module_t.Type_state.glob_vars name'
      |> Option.map ~f:(Fn.const module_t)
    in
    (match find_module_in_submodules ~try_make_module ~state ~f module_path with
     | None ->
       Typed_ast.(edge.used_globals <- Set.add edge.used_globals name');
       Hash_set.add not_found_vars name'
     | Some module_t
       when String.equal
              state.Type_state.current_module.filename
              module_t.filename ->
       Typed_ast.(edge.used_globals <- Set.add edge.used_globals name')
     | Some _ -> ())
  | `Match (a, l) ->
    rep ~locals a;
    List.iter l ~f:(fun (p, e) -> rep ~locals:(pattern_vars p ~locals) e)
  | `Tuple l | `Array_lit l -> List.iter l ~f:(rep ~locals)
  | `Index (a, b) | `Inf_op (_, a, b) | `Assign (a, b) | `Apply (a, b) ->
    rep ~locals a;
    rep ~locals b
  | `Let (s, a, b) ->
    let locals = Set.add locals s in
    let rep = rep ~locals in
    rep a;
    rep b
  | `Break a
  | `Loop a
  | `Assert a
  | `Compound a
  | `Return a
  | `Size_of (`Expr a)
  | `Unsafe_cast a
  | `Assert_struct (_, a)
  | `Access_enum_field (_, a)
  | `Assert_empty_enum_field (_, a)
  | `Tuple_access (a, _)
  | `Field_access (a, _)
  | `Ref a
  | `Deref a
  | `Pref_op (_, a)
  | `Typed (a, _) -> rep ~locals a
  | `Struct (_, l) ->
    List.iter l ~f:(fun (field_name, o) ->
      match o with
      | Some p -> rep ~locals p
      | None -> rep ~locals (`Var { inner = field_name; module_path = [] }))
  | `If (a, b, c) ->
    rep ~locals a;
    rep ~locals b;
    rep ~locals c

and process_module ~state filename =
  match Hashtbl.find state.Type_state.seen_modules filename with
  | Some (Type_state.{ in_eval = false; _ } as m) -> m
  | Some { in_eval = true; _ } ->
    raise
      (Module_cycle
         { offending_module = filename
         ; from_module = state.current_module.name
         })
  | None ->
    In_channel.with_file filename ~f:(fun chan ->
      let lexbuf = Lexing.from_channel chan in
      Frontend.parse_and_do ~filename lexbuf ~f:(fun toplevels ->
        let module_t = Type_state.module_create filename in
        module_t.in_eval <- true;
        let state = Type_state.push_module ~module_t state in
        type_check
          ~state:{ state with opened_modules = []; locals = String.Map.empty }
          toplevels;
        module_t.in_eval <- false;
        module_t))

and process_module_path ~state path =
  match path with
  | fst :: rest ->
    let filename =
      el2_file (Filename.dirname state.Type_state.current_module.filename) fst
    in
    let in_ = process_module ~state filename in
    Type_state.lookup_module_in_exn ~in_ rest
  | _ -> failwith "impossible"

and type_check ~state toplevels =
  try
    let state = process_toplevel_graph ~state toplevels in
    let _ = get_sccs state.Type_state.current_module.glob_vars in
    Hashtbl.iter state.current_module.glob_vars ~f:(fun var ->
      let state =
        match var with
        | Typed_ast.El { data = opened_modules; _ } ->
          { state with opened_modules }
        | _ -> state
      in
      ignore (infer_var ~state var))
  with
  | Failure s ->
    print_endline
      [%string
        "Fatal error while evaluating %{state.current_module.filename}:\n%{s}"];
    exit 1

and process_toplevel_graph ~state (toplevels : toplevel list) =
  let type_defs = String.Table.create () in
  let let_toplevels = Queue.create () in
  let curdir = state.Type_state.current_module.filename |> Filename.dirname in
  let _ =
    List.fold toplevels ~init:[] ~f:(fun acc ->
        function
        | `Open_file filename ->
          let nek = process_module ~state (Filename.concat curdir filename) in
          Queue.enqueue let_toplevels (`Open nek);
          nek :: acc
        | `Open path ->
          let nek = process_module_path ~state path in
          Queue.enqueue let_toplevels (`Open nek);
          nek :: acc
        | `Let_type ((name, ty_vars), type_decl) ->
          let repr_name = Type_state.make_unique_type ~state name in
          (match
             Hashtbl.add
               state.Type_state.current_module.types
               ~key:name
               ~data:(make_user_type ~repr_name ~ty_vars ~name)
           with
           | `Ok ->
             Hashtbl.add_exn type_defs ~key:name ~data:(ty_vars, type_decl, acc)
           | `Duplicate -> failwith [%string "Duplicate type %{name}"]);
          acc
        | `Let_fn x ->
          Queue.enqueue let_toplevels (`Let_fn x);
          acc
        | `Let x ->
          Queue.enqueue let_toplevels (`Let x);
          acc
        | `Extern x ->
          Queue.enqueue let_toplevels (`Extern x);
          acc
        | `Implicit_extern x ->
          Queue.enqueue let_toplevels (`Implicit_extern x);
          acc)
  in
  let not_found_vars = String.Hash_set.create () in
  process_types ~state type_defs;
  let find_references ~edge ~state ~locals expr =
    let open Typed_ast in
    match Hashtbl.find state.Type_state.current_module.glob_vars edge.name with
    | Some _ -> failwith [%string "Duplicate variable %{edge.name}"]
    | None ->
      Hashtbl.add_exn
        state.current_module.glob_vars
        ~key:edge.name
        ~data:(El edge);
      Hash_set.remove not_found_vars edge.name;
      traverse_expr ~state ~not_found_vars ~edge ~locals expr
  in
  let _ =
    Queue.fold let_toplevels ~init:[] ~f:(fun opened_modules ->
        function
        | `Open m -> m :: opened_modules
        | `Let_fn (name, vars, expr) ->
          let expr = expand_expr ~state expr in
          let var_decls =
            List.map vars ~f:(function
              | `Typed (s, e) -> s, mono_of_type_expr ~state e
              | `Untyped s -> s, make_indir ())
          in
          let edge =
            Typed_ast.create_func
              ~ty_var_counter:state.ty_var_counter
              ~name
              ~expr
              ~var_decls
              ~data:opened_modules
              ~unique_name:(Type_state.make_unique ~state name)
          in
          find_references
            ~state:{ state with opened_modules }
            ~edge
            ~locals:(function_arg_set ~init:String.Set.empty vars)
            expr;
          opened_modules
        | `Let (pattern, expr) ->
          let vars = Stack.create () in
          breakup_patterns ~state ~vars pattern expr;
          Stack.iter vars ~f:(fun (name, expr) ->
            let edge =
              Typed_ast.create_non_func
                ~ty_var_counter:state.ty_var_counter
                ~name
                ~expr
                ~data:opened_modules
                ~unique_name:(Type_state.make_unique ~state name)
            in
            find_references ~state ~edge ~locals:String.Set.empty expr);
          opened_modules
        | `Extern (name, t, extern_name) ->
          let mono = mono_of_type_expr ~state t in
          Type_state.register_name ~state extern_name;
          let edge = Typed_ast.Extern (name, extern_name, mono) in
          (match
             Hashtbl.add state.current_module.glob_vars ~key:name ~data:edge
           with
           | `Ok -> opened_modules
           | _ -> failwith [%string "Duplicate variable %{name}"])
        | `Implicit_extern (name, t, extern_name) ->
          let mono = mono_of_type_expr ~state t in
          Type_state.register_name ~state extern_name;
          let edge = Typed_ast.Implicit_extern (name, extern_name, mono) in
          (match
             Hashtbl.add state.current_module.glob_vars ~key:name ~data:edge
           with
           | `Ok -> opened_modules
           | _ -> failwith [%string "Duplicate variable %{name}"]))
  in
  match Hash_set.is_empty not_found_vars with
  | false ->
    failwith
      [%string
        "Unknown variables: `%{Hash_set.to_list not_found_vars |> \
         String.concat ~sep:\", \"}`"]
  | true -> state

and get_sccs glob_vars =
  let open Typed_ast in
  let res = Stack.create () in
  let stack = Stack.create () in
  let index = ref 0 in
  let rec connect v =
    v.scc_st.index <- Some !index;
    v.scc_st.lowlink <- !index;
    incr index;
    Stack.push stack v;
    v.scc_st.on_stack <- true;
    Set.iter v.used_globals ~f:(fun s ->
      let w = Hashtbl.find_exn glob_vars s in
      match w with
      | Extern _ | Implicit_extern _ -> ()
      | El w ->
        if Option.is_none w.scc_st.index
        then (
          connect w;
          v.scc_st.lowlink <- Int.min v.scc_st.lowlink w.scc_st.lowlink)
        else if w.scc_st.on_stack
        then
          v.scc_st.lowlink
          <- Int.min v.scc_st.lowlink (Option.value_exn w.scc_st.index));
    if v.scc_st.lowlink = Option.value_exn v.scc_st.index
    then (
      let scc = Stack.create () in
      let rec loop () =
        let w = Stack.pop_exn stack in
        w.scc_st.on_stack <- false;
        Stack.push scc w;
        match phys_equal v w with
        | true -> ()
        | false -> loop ()
      in
      loop ();
      Stack.push res scc)
  in
  Hashtbl.iter glob_vars ~f:(function
    | Extern _ | Implicit_extern _ -> ()
    | El v ->
      (match v.scc_st.index with
       | None -> connect v
       | Some _ -> ()));
  let num = ref 0 in
  Stack.iter res ~f:(fun vars ->
    if print_sccs then print_endline [%string "SCC %{!num#Int}:"];
    incr num;
    let scc = { vars; type_check_state = `Untouched } in
    Stack.iter vars ~f:(fun v ->
      if print_sccs then print_endline [%string "  %{v.name}"];
      v.scc <- scc));
  res

and mono_of_var ~state name =
  match Map.find state.Type_state.locals name with
  | Some x -> `Local x
  | None ->
    let var = lookup_var ~state (empty_path name) in
    `Global (var, infer_var ~state var)

and infer_var ~state (var : Type_state.module_t list Typed_ast.top_var) =
  match var with
  | El v ->
    (match v.scc.type_check_state with
     | `Untouched -> infer_scc ~state v.scc
     | `In_checking | `Done -> ());
    let mono, inst_map = inst v.poly in
    (match v.scc.type_check_state with
     | `Untouched | `In_checking -> mono, None
     | `Done -> mono, Some inst_map)
  | Extern (_, _, mono) | Implicit_extern (_, _, mono) ->
    mono, Some String.Map.empty

and infer_scc ~state scc =
  let open Typed_ast in
  scc.type_check_state <- `In_checking;
  let monos =
    Stack.to_list scc.vars
    |> List.map ~f:(fun v ->
      try
        let mono, _ = inst v.poly in
        let state, to_unify, mono =
          match v.args, mono with
          | `Func l, `Function (a, b) ->
            let tup =
              match l with
              | [ (_, m) ] -> m
              | _ -> `Tuple (List.map l ~f:snd)
            in
            let state =
              List.fold l ~init:state ~f:(fun state (key, data) ->
                { state with locals = Map.set state.locals ~key ~data })
            in
            let a = unify tup a in
            state, b, `Function (a, b)
          | _, _ -> state, mono, mono
        in
        let expr_inner, mono' =
          type_expr ~res_type:to_unify ~break_type:None ~state v.expr
        in
        v, (expr_inner, unify to_unify mono'), mono
      with
      | Unification_error e ->
        show_unification_error e |> print_endline;
        print_s [%message "While evaluating" v.name (v.expr : expanded_expr)];
        exit 1)
  in
  let counter = Counter.create () in
  let vars = String.Table.create () in
  let indirs = Int.Table.create () in
  List.iter monos ~f:(fun (v, expr, mono) ->
    let mono = mono_map_rec_keep_refs mono ~f:inner_mono in
    let expr, poly =
      match v.args with
      | `Func l ->
        let expr = gen_expr ~counter ~vars ~indirs expr in
        let poly = gen ~counter ~vars ~indirs mono in
        let l =
          List.map l ~f:(fun (s, m) -> s, gen_mono ~counter ~vars ~indirs m)
        in
        v.args <- `Func l;
        expr, poly
      | `Non_func ->
        let vars = String.Table.create () in
        let indirs = Int.Table.create () in
        ( make_vars_weak_expr ~vars ~indirs expr
        , make_vars_weak ~vars ~indirs mono )
    in
    v.poly <- poly;
    v.typed_expr <- Some expr);
  scc.type_check_state <- `Done

and make_pointer ~state:_ =
  let ty_var = make_indir () in
  `Pointer ty_var, ty_var

and type_expr ~res_type ~break_type ~state expr =
  try type_expr_ ~res_type ~break_type ~state expr with
  | Unification_error _ as exn ->
    print_endline "While evaluating:";
    print_s [%message (expr : expanded_expr)];
    raise exn

and type_expr_ ~res_type ~break_type ~state expr : expr =
  let rep ~state = type_expr ~res_type ~break_type ~state in
  match expr with
  | `Bool b -> `Bool b, `Bool
  | `Int i -> `Int i, `I64
  | `Null ->
    let pointer_type, _ = make_pointer ~state in
    `Null, pointer_type
  | `Return a ->
    let a, am = rep ~state a in
    let am = unify res_type am in
    `Return (a, am), `Unit
  | `Break a ->
    (match break_type with
     | Some break_type ->
       let a, am = rep ~state a in
       let am = unify break_type am in
       `Break (a, am), `Unit
     | None -> failwith "break outside of loop")
  | `Loop a ->
    let indir = make_indir () in
    let break_type = Some indir in
    let a, am = type_expr ~state ~res_type ~break_type a in
    let am = unify am `Unit in
    `Loop (a, am), indir
  | `Float f -> `Float f, `F64
  | `Char c -> `Char c, `Char
  | `String s -> `String s, `Pointer `Char
  | `Unit -> `Unit, `Unit
  | `Var { inner = name; module_path = [] } ->
    (match mono_of_var ~state name with
     | `Global (var, (mono, inst_map)) -> `Glob_var (var, inst_map), mono
     | `Local mono -> `Local_var name, mono)
  | `Var p ->
    let var = lookup_var ~state p in
    let mono, inst_map = infer_var ~state var in
    `Glob_var (var, inst_map), mono
  | `Array_lit l ->
    let init = make_indir () in
    let res_type, l' =
      List.fold_map ~init l ~f:(fun acc expr ->
        let expr' = rep ~state expr in
        unify acc (snd expr'), expr')
    in
    `Array_lit l', `Pointer res_type
  | `Tuple l ->
    let l' = List.map l ~f:(rep ~state) in
    let monos = List.map l' ~f:snd in
    `Tuple l', `Tuple monos
  | `Index (a, b) ->
    let a, am = rep ~state a in
    let b, bm = rep ~state b in
    let pointer_type, ty_var = make_pointer ~state in
    let am = unify am pointer_type in
    let bm = unify bm `I64 in
    `Index ((a, am), (b, bm)), ty_var
  | `Assert a ->
    let a, am = rep ~state a in
    let am = unify am `Bool in
    `Assert (a, am), `Unit
  | `Tuple_access (a, i) ->
    let a, am = rep ~state a in
    let res_type =
      match am with
      | `Tuple l ->
        (match List.nth l i with
         | Some x -> x
         | None -> failwith "Tuple access out of bounds")
      | _ -> failwith "must specify tuple type exactly if indexing"
    in
    `Tuple_access ((a, am), i), res_type
  | `Assign (a, b) ->
    let a, am = rep ~state a in
    let b, bm = rep ~state b in
    let bm = unify bm am in
    `Assign ((a, bm), (b, bm)), bm
  | `Assert_struct (str, a) ->
    let a, am = rep ~state a in
    let user_type = lookup_and_inst_user_type ~state str in
    let am = unify am (`User user_type) in
    a, am
  | `Access_enum_field (field, a) ->
    let a, am = rep ~state a in
    let inst_user_type, res_type =
      get_user_type_from_variant_exn ~state field
    in
    let am = unify am (`User inst_user_type) in
    `Access_enum_field (field.inner, (a, am)), res_type
  | `Assert_empty_enum_field (field, a) ->
    let a, am = rep ~state a in
    let inst_user_type = get_user_type_from_variant_no_data_exn ~state field in
    let am = unify am (`User inst_user_type) in
    a, am
  | `Compound e ->
    let expr = rep ~state e in
    `Compound expr, snd expr
  | `Inf_op (op, a, b) ->
    let a, am = rep ~state a in
    let b, bm = rep ~state b in
    let m = unify am bm in
    let res_type =
      match op with
      | `Add | `Sub | `Mul | `Div | `Rem -> unify m `I64
      | `Eq | `Ne | `Lt | `Gt | `Le | `Ge -> `Bool
      | `And | `Or -> unify m `Bool
    in
    `Inf_op (op, (a, am), (b, bm)), res_type
  | `Field_access (a, field) ->
    let a, am = rep ~state a in
    let user_type, res_type = get_user_type_from_field_exn ~state field in
    let am = unify am (`User user_type) in
    `Field_access ((a, am), field.inner), res_type
  | `Ref a ->
    let a, am = rep ~state a in
    let pointer_type, ty_var = make_pointer ~state in
    let am = unify am ty_var in
    `Ref (a, am), pointer_type
  | `Deref a ->
    let a, am = rep ~state a in
    let pointer_type, ty_var = make_pointer ~state in
    let am = unify am pointer_type in
    `Deref (a, am), ty_var
  | `Pref_op (op, a) ->
    let a, am = rep ~state a in
    let res_type =
      match op with
      | `Minus -> unify am `I64
    in
    `Pref_op (op, (a, am)), res_type
  | `Struct (s, l) ->
    let l = List.sort l ~compare:(fun (a, _) (b, _) -> String.compare a b) in
    let user_type, struct_l = get_struct_list_exn ~state s in
    let l' =
      match List.zip struct_l l with
      | Ok l -> l
      | _ ->
        failwith [%string {| Wrong number of fields in struct `%{s.inner}`|}]
    in
    let l' =
      List.map l' ~f:(fun ((orig_field, orig_mono), (field, opt_expr)) ->
        if not (String.equal orig_field field)
        then raise (Unification_error End);
        let expr =
          match opt_expr with
          | Some expr -> expr
          | None -> `Var (empty_path field)
        in
        let a, am = rep ~state expr in
        let am = unify am orig_mono in
        field, (a, am))
    in
    `Struct l', `User user_type
  | `Apply (`Enum s, e) ->
    let inst_user_type, arg_type = get_user_type_from_variant_exn ~state s in
    let e, em = rep ~state e in
    let em = unify em arg_type in
    `Enum (s.inner, Some (e, em)), `User inst_user_type
  | `Enum s ->
    let inst_user_type = get_user_type_from_variant_no_data_exn ~state s in
    `Enum (s.inner, None), `User inst_user_type
  | `Apply (a, b) ->
    let a, am = rep ~state a in
    let b, bm = rep ~state b in
    let arg_type = make_indir () in
    let res_type = make_indir () in
    let func_type = `Function (arg_type, res_type) in
    let am = unify am func_type in
    let bm = unify bm arg_type in
    `Apply ((a, am), (b, bm)), res_type
  | `Typed (a, b) ->
    let a, am = rep ~state a in
    let b = mono_of_type_expr ~state b in
    let am = unify am b in
    a, am
  | `Let (s, b, c) ->
    let b, bm = rep ~state b in
    let state = state_add_local state ~name:s ~mono:bm in
    let c, cm = rep ~state c in
    `Let (s, (b, bm), (c, cm)), cm
  | `If (a, b, c) ->
    let a, am = rep ~state a in
    let b, bm = rep ~state b in
    let c, cm = rep ~state c in
    let am = unify am `Bool in
    let bm = unify bm cm in
    `If ((a, am), (b, bm), (c, cm)), bm
  | `Size_of (`Type t) ->
    let mono = mono_of_type_expr ~state t in
    `Size_of mono, `I64
  | `Size_of (`Expr e) ->
    let _, mono = rep ~state e in
    `Size_of mono, `I64
  | `Unsafe_cast e ->
    let expr = rep ~state e in
    let res_type = make_indir () in
    `Unsafe_cast expr, res_type
  | `Match (e, l) ->
    let initial_expr, em = rep ~state e in
    let res_type = make_indir () in
    let var = Type_state.unique_name state in
    let bound_expr = `Local_var var, em in
    let l =
      List.map l ~f:(fun (p, e) ->
        let conds, bindings_f, state =
          breakup_and_type_pattern ~state ~expr:bound_expr p
        in
        let e, em = rep ~state e in
        let em = unify em res_type in
        conds, bindings_f (e, em))
    in
    let _, (_, res_mono) = List.hd_exn l in
    let init = `Assert (`Bool false, `Bool), res_mono in
    let rest =
      List.fold_right
        ~init
        ~f:(fun (conds, (e, em)) acc -> `If (conds, (e, em), acc), em)
        l
    in
    `Let (var, (initial_expr, em), rest), res_mono

and breakup_and_type_pattern ~state ~expr:(e, em) pattern =
  let true_cond = `Bool true, `Bool in
  match pattern with
  | `Tuple l ->
    let l = List.map l ~f:(fun a -> a, make_indir ()) in
    let tuple_type = `Tuple (List.map l ~f:snd) in
    let em = unify em tuple_type in
    let expr = e, em in
    let conds = true_cond in
    let bindings_f expr = expr in
    List.foldi
      l
      ~init:(conds, bindings_f, state)
      ~f:(fun i (conds, bindings_f, state) (p, mono) ->
        let expr = `Tuple_access (expr, i), mono in
        let conds', bindings_f', state =
          breakup_and_type_pattern ~state ~expr p
        in
        let conds = Typed_ast.(conds && conds') in
        let bindings_f expr = bindings_f (bindings_f' expr) in
        conds, bindings_f, state)
  | `Var s ->
    let locals = Map.set state.locals ~key:s ~data:em in
    ( true_cond
    , (fun (e', em') -> `Let (s, (e, em), (e', em')), em')
    , { state with locals } )
  | `Bool b ->
    let _ = unify em `Bool in
    let conds = `Inf_op (`Eq, (e, em), (`Bool b, `Bool)), `Bool in
    conds, (fun expr -> expr), state
  | `Float f ->
    let _ = unify em `F64 in
    let conds = `Inf_op (`Eq, (e, em), (`Float f, `F64)), `Bool in
    conds, (fun expr -> expr), state
  | `Unit ->
    let _ = unify em `Unit in
    true_cond, (fun expr -> expr), state
  | `Ref p ->
    let pointer_type, ty_var = make_pointer ~state in
    let em = unify em pointer_type in
    let expr = `Deref (e, em), ty_var in
    breakup_and_type_pattern ~state ~expr p
  | `Char c ->
    let _ = unify em `Char in
    let conds = `Inf_op (`Eq, (e, em), (`Char c, `Char)), `Bool in
    conds, (fun expr -> expr), state
  | `String s ->
    let _ = unify em (`Pointer `Char) in
    let conds = `Inf_op (`Eq, (e, em), (`String s, `Pointer `Char)), `Bool in
    conds, (fun expr -> expr), state
  | `Int i ->
    let _ = unify em `I64 in
    let conds = `Inf_op (`Eq, (e, em), (`Int i, `I64)), `Bool in
    conds, (fun expr -> expr), state
  | `Null ->
    let pointer_type, _ = make_pointer ~state in
    let _ = unify em pointer_type in
    let conds = `Inf_op (`Eq, (e, em), (`Null, pointer_type)), `Bool in
    conds, (fun expr -> expr), state
  | `Typed (a, b) ->
    let b = mono_of_type_expr ~state b in
    let em = unify em b in
    breakup_and_type_pattern ~state ~expr:(e, em) a
  | `Struct (name, l) ->
    let l = List.sort l ~compare:(fun (a, _) (b, _) -> String.compare a b) in
    let user_type, struct_l = get_struct_list_exn ~state name in
    let l' =
      match List.zip struct_l l with
      | Ok l -> l
      | _ ->
        failwith [%string {| Wrong number of fields in struct `%{name.inner}`|}]
    in
    let em = unify em (`User user_type) in
    let expr = e, em in
    let conds = true_cond in
    let bindings_f expr = expr in
    List.fold
      l'
      ~init:(conds, bindings_f, state)
      ~f:
        (fun
          (conds, bindings_f, state)
          ((orig_field, orig_mono), (field, opt_pattern))
        ->
        if not (String.equal orig_field field)
        then
          failwith
            [%string
              {| Wrong field name in struct `%{name.inner}` (%{field} vs %{orig_field})|}];
        let pattern =
          match opt_pattern with
          | Some p -> p
          | None -> `Var field
        in
        let expr = `Field_access (expr, field), orig_mono in
        let conds', bindings_f', state =
          breakup_and_type_pattern ~state ~expr pattern
        in
        let conds = Typed_ast.(conds && conds') in
        let bindings_f expr = bindings_f (bindings_f' expr) in
        conds, bindings_f, state)
  | `Enum (name, opt_p) ->
    let user_type = lookup_variant ~state name in
    let user_type = inst_user_type_gen user_type in
    let arg_type = get_user_type_variant_exn user_type ~variant:name.inner in
    let em = unify em (`User user_type) in
    let conds = `Check_variant (name.inner, (e, em)), `Bool in
    (match opt_p with
     | Some p ->
       let arg_type =
         Option.value_or_thunk arg_type ~default:(fun () ->
           failwith [%string "variant does not have data `%{name.inner}`"])
       in
       let expr = `Access_enum_field (name.inner, (e, em)), arg_type in
       let conds', binding_f, state = breakup_and_type_pattern ~state ~expr p in
       let conds = Typed_ast.(conds && conds') in
       conds, binding_f, state
     | None ->
       if Option.is_some arg_type
       then failwith [%string "variant has data `%{name.inner}`"];
       conds, (fun expr -> expr), state)
;;

let type_check_starting_with ~filename =
  let state = Type_state.create filename in
  In_channel.with_file filename ~f:(fun chan ->
    let lexbuf = Lexing.from_channel chan in
    Frontend.parse_and_do ~filename lexbuf ~f:(fun toplevels ->
      state.current_module.in_eval <- true;
      type_check ~state toplevels;
      state.current_module.in_eval <- false;
      state))
;;

let type_check_and_output filename =
  try type_check_starting_with ~filename with
  | Unification_error e ->
    show_unification_error e |> print_endline;
    exit 1
  | Failure s ->
    print_endline "Fatal error:";
    print_endline s;
    exit 1
;;

let process_and_dump filename =
  let state = type_check_and_output filename in
  Hashtbl.iter state.Type_state.seen_modules ~f:(fun module_t ->
    print_endline [%string "Module %{module_t.name}:"];
    Hashtbl.iter module_t.types ~f:(fun user_type ->
      print_endline [%string "    Inferred %{user_type.repr_name} to be:"];
      Pretty_print.user_type_p user_type
      |> Pretty_print.output_endline ~prefix:"    ");
    Hashtbl.iter module_t.glob_vars ~f:(fun var ->
      match var with
      | Typed_ast.El { name; poly; _ } ->
        print_endline
          [%string "    Inferred %{name} to have type %{show_poly poly}"]
      | Extern (name, _, mono) ->
        print_endline [%string "    Extern %{name} has type %{show_mono mono}"]
      | Implicit_extern (name, _, mono) ->
        print_endline
          [%string "    Implicit_extern %{name} has type %{show_mono mono}"]))
;;
