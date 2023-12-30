A simple language that aims to blend OCaml and C.

My original idea was for a C like language with a module system like OCaml,
allowing for code reuse. I also enjoy the type system of OCaml, so evanlang2
has a Hindley-Milner type system with full type inference, as well as sum types.

Currently, the module system is unimplemented - the language is basically (a less complete) C with type inference.
In fact, it even compiles to C (though I hope to use LLVM in the future).

Usage:
Install ocaml (opam, dune etc.)
`dune exec bin/main.exe -- --comp <filename>` will spit out C code for you to separately compile.

```
[*
  this is a comment
*]

[* sum type/enum taking a type variable 'a' *]
type option(a) :=
  | Some(a)
  | None

[* product type/struct, also with a variable *]
type list(a) :=
  { data : a;
    next : option(&(list(a)))
  }

[* type without any type args *]
type unused_data := { unused_data : unit }

[* declares a function that is linked already *]
implicit_extern print_endline : &char -> c_int = "puts"

let do_nothing(a) := ()

let option_iter(a, f) := {
  [* pattern matching *]
  match a with
  | Some(a) -> f(a)
  | None -> ()
}

let list_option_iter(
  a,
  [* can optionally declare the type of arguments *]
  f : &char -> c_int
) := {

  option_iter(a, do_nothing);

  match a with
  | None -> ()
  | Some(a) -> {
        [* deref, same as C *]
        f((*a).data);

        [* postfix deref, equivalent to the above *]
        f(a^.data);

	list_option_iter(a^.next, f)
    }
}

let main() : [* optional type declaration of return type *] i64 = {
  let first := #list {
    data : "first";
    next : None
  };

  [* type declarations can be used in the same way in functions *]
  let second : list(&char) = #list {
    data : "second";
    next : Some(&first)
  };

  let unused := second.next;

  list_option_iter(Some(&second), print_endline);
  0
}
```
