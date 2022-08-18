open Type

let should_work t t' r =
  let t = make t in
  let t' = make t' in
  let r = make r in
  Printf.printf "Finding min for %s and %s\n%!" (to_string t) (to_string t');
  let m = Typing.sup ~pos:None t t' in
  Printf.printf "Got: %s, expect %s\n%!" (to_string m) (to_string r);
  Typing.(m <: r);
  Typing.(t <: m);
  Typing.(t' <: m)

let should_fail t t' =
  try
    ignore (Typing.sup ~pos:None (make t) (make t'));
    assert false
  with _ -> ()

let () =
  should_work (var ()).descr Ground.bool Ground.bool;
  should_work Ground.bool (var ()).descr Ground.bool;

  should_fail Ground.bool Ground.int;
  should_fail
    (List { t = make Ground.bool; json_repr = `Tuple })
    (List { t = make Ground.int; json_repr = `Tuple });

  let mk_meth meth ty t =
    Meth ({ meth; scheme = ([], make ty); doc = ""; json_name = None }, make t)
  in

  let m = mk_meth "aa" Ground.int Ground.bool in

  should_work m Ground.bool Ground.bool;

  let n = mk_meth "b" Ground.bool m in

  should_work m n m;

  let n = mk_meth "aa" Ground.int Ground.int in

  should_fail m n;

  let n = mk_meth "aa" Ground.bool Ground.bool in

  should_fail m n;

  ()
