(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2022 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

include Runtime_error

type error = Runtime_error.runtime_error = {
  kind : string;
  msg : string;
  pos : Pos.List.t;
}

module ErrorDef = struct
  type content = error

  let name = "error"

  let descr { kind; msg; pos } =
    let pos =
      if pos <> [] then
        Lang_string.quote_string
          (Printf.sprintf ",positions=%s"
             (Pos.List.to_string ~newlines:false pos))
      else ""
    in
    Printf.sprintf "error(kind=%s,message=%s%s)"
      (Lang_string.quote_string kind)
      (Lang_string.quote_string msg)
      pos

  let to_json _ =
    raise
      Runtime_error.(
        Runtime_error
          {
            kind = "json";
            msg = "Error cannot be represented as json";
            pos = [];
          })

  let compare = Stdlib.compare
end

module Error = struct
  include Value.MkAbstract ((ErrorDef : Value.AbstractDef))

  let meths =
    [
      ( "kind",
        ([], Lang_core.string_t),
        "Error kind.",
        fun { kind } -> Lang_core.string kind );
      ( "message",
        ([], Lang_core.string_t),
        "Error message.",
        fun { msg } -> Lang_core.string msg );
      ( "positions",
        ([], Lang_core.(list_t string_t)),
        "Error positions.",
        fun { pos } ->
          Lang_core.list
            (List.map (fun pos -> Lang_core.string (Pos.to_string pos)) pos) );
    ]

  let t =
    Lang_core.method_t t
      (List.map (fun (lbl, t, descr, _) -> (lbl, t, descr)) meths)

  let to_value err =
    Lang_core.meth (to_value err)
      (List.map (fun (lbl, _, _, m) -> (lbl, m err)) meths)

  let of_value err = of_value (Lang_core.demeth err)
end

let () = Lang_core.add_module "error"

let () =
  Lang_core.add_builtin "error.register" ~category:`Liquidsoap
    ~descr:"Register an error of the given kind"
    [("", Lang_core.string_t, None, Some "Kind of the error")] Error.t (fun p ->
      let kind = Lang_core.to_string (List.assoc "" p) in
      Error.to_value { kind; msg = ""; pos = [] })

let () =
  Lang_core.add_builtin "error.raise" ~category:`Liquidsoap
    ~descr:"Raise an error."
    [
      ("", Error.t, None, Some "Error kind.");
      ( "",
        Lang_core.string_t,
        Some (Lang_core.string ""),
        Some "Description of the error." );
    ]
    (Lang_core.univ_t ())
    (fun p ->
      let { kind } = Error.of_value (Lang_core.assoc "" 1 p) in
      let msg = Lang_core.to_string (Lang_core.assoc "" 2 p) in
      raise (Term.Runtime_error { Term.kind; msg; pos = [] }))

let error_t = Error.t
let error = Error.to_value
let to_error = Error.of_value

let () =
  let a = Lang_core.univ_t () in
  Lang_core.add_builtin "error.catch" ~category:`Liquidsoap ~flags:[`Hidden]
    ~descr:"Execute a function, catching eventual exceptions."
    [
      ( "errors",
        Lang_core.nullable_t (Lang_core.list_t Error.t),
        None,
        Some "Kinds of errors to catch. Catches all errors if not set." );
      ("", Lang_core.fun_t [] a, None, Some "Function to execute.");
      ("", Lang_core.fun_t [(false, "", Error.t)] a, None, Some "Error handler.");
    ]
    a
    (fun p ->
      let errors =
        Option.map
          (fun v -> List.map Error.of_value (Lang_core.to_list v))
          (Lang_core.to_option (Lang_core.assoc "errors" 1 p))
      in
      let f = Lang_core.to_fun (Lang_core.assoc "" 1 p) in
      let h = Lang_core.to_fun (Lang_core.assoc "" 2 p) in
      try f []
      with
      | Term.Runtime_error { Term.kind; msg }
      when errors = None
           || List.exists (fun err -> err.kind = kind) (Option.get errors)
      ->
        h [("", Error.to_value { kind; msg; pos = [] })])
