let () =
  Lang.add_builtin "ignore"
    ~descr:"Convert anything to unit, preventing warnings." ~category:`Control
    [("", Lang.univ_t (), None, None)]
    Lang.unit_t
    (fun _ -> Lang.unit)

let () =
  let t = Lang.univ_t () in
  Lang.add_builtin "if" ~category:`Control ~descr:"The basic conditional."
    ~flags:[`Hidden]
    [
      ("", Lang.bool_t, None, None);
      ("then", Lang.fun_t [] t, None, None);
      ("else", Lang.fun_t [] t, None, None);
    ]
    t
    (fun p ->
      let c = List.assoc "" p in
      let fy = List.assoc "then" p in
      let fn = List.assoc "else" p in
      let c = Lang.to_bool c in
      Lang.apply (if c then fy else fn) [])

(** Operations on products. *)

let () =
  let t1 = Lang.univ_t () in
  let t2 = Lang.univ_t () in
  Lang.add_builtin "fst" ~category:`Liquidsoap
    ~descr:"Get the first component of a pair."
    [("", Lang.product_t t1 t2, None, None)]
    t1
    (fun p -> fst (Lang.to_product (Lang.assoc "" 1 p)));
  Lang.add_builtin "snd" ~category:`Liquidsoap
    ~descr:"Get the second component of a pair."
    [("", Lang.product_t t1 t2, None, None)]
    t2
    (fun p -> snd (Lang.to_product (Lang.assoc "" 1 p)))

let () =
  Lang.add_builtin "print" ~category:`Interaction
    ~descr:"Print on standard output."
    [
      ( "newline",
        Lang.bool_t,
        Some (Lang.bool true),
        Some "If true, a newline is added after displaying the value." );
      ("", Lang.univ_t (), None, None);
    ]
    Lang.unit_t
    (fun p ->
      let nl = Lang.to_bool (List.assoc "newline" p) in
      let v = List.assoc "" p in
      let v =
        match v.Lang.value with
          | Lang.(Ground (Ground.String s)) -> s
          | _ -> Value.to_string v
      in
      let v = if nl then v ^ "\n" else v in
      print_string v;
      flush stdout;
      Lang.unit)

(** Loops. *)

let () =
  Lang.add_builtin "while" ~category:`Liquidsoap ~descr:"A while loop."
    [
      ("", Lang.getter_t Lang.bool_t, None, Some "Condition guarding the loop.");
      ("", Lang.fun_t [] Lang.unit_t, None, Some "Function to execute.");
    ]
    Lang.unit_t
    (fun p ->
      let c = Lang.to_bool_getter (Lang.assoc "" 1 p) in
      let f = Lang.to_fun (Lang.assoc "" 2 p) in
      while c () do
        ignore (f [])
      done;
      Lang.unit)

let () =
  let a = Lang.univ_t () in
  Lang.add_builtin "for" ~category:`Liquidsoap ~descr:"A for loop."
    ~flags:[`Hidden]
    [
      ("", Lang.fun_t [] (Lang.nullable_t a), None, Some "Values to iterate on.");
      ( "",
        Lang.fun_t [(false, "", a)] Lang.unit_t,
        None,
        Some "Function to execute." );
    ]
    Lang.unit_t
    (fun p ->
      let i = Lang.to_fun (Lang.assoc "" 1 p) in
      let f = Lang.to_fun (Lang.assoc "" 2 p) in
      let rec aux () =
        match Lang.to_option (i []) with
          | Some i ->
              ignore (f [("", i)]);
              aux ()
          | None -> Lang.unit
      in
      aux ())

let () =
  Lang.add_builtin "iterator.int" ~category:`Liquidsoap
    ~descr:"Iterator on integers." ~flags:[`Hidden]
    [
      ("", Lang.int_t, None, Some "First value.");
      ("", Lang.int_t, None, Some "Last value (included).");
    ]
    (Lang.fun_t [] (Lang.nullable_t Lang.int_t))
    (fun p ->
      let a = Lang.to_int (Lang.assoc "" 1 p) in
      let b = Lang.to_int (Lang.assoc "" 2 p) in
      let i = ref a in
      let f _ =
        let ans = !i in
        incr i;
        if ans > b then Lang.null else Lang.int ans
      in
      Lang.val_fun [] f)

let () =
  let ss = Lang.product_t Lang.string_t Lang.string_t in
  let ret_t = Lang.list_t ss in
  Lang.add_builtin "environment" ~category:`System
    ~descr:"Return the process environment." [] ret_t (fun _ ->
      let l = Lang.environment () in
      let l = List.map (fun (x, y) -> (Lang.string x, Lang.string y)) l in
      let l = List.map (fun (x, y) -> Lang.product x y) l in
      Lang.list l)

let () =
  Lang.add_builtin "setenv" ~category:`System
    ~descr:"Set the value associated to a variable in the process environment."
    [
      ("", Lang.string_t, None, Some "Variable to be set.");
      ("", Lang.string_t, None, Some "Value to set.");
    ] Lang.unit_t (fun p ->
      let label = Lang.to_string (Lang.assoc "" 1 p) in
      let value = Lang.to_string (Lang.assoc "" 2 p) in
      Unix.putenv label value;
      Lang.unit)
