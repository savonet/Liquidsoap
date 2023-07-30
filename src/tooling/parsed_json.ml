(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2023 Savonet team

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

open Liquidsoap_lang
open Parsed_term

let json_of_position { Lexing.pos_fname; pos_lnum; pos_bol; pos_cnum } : Json.t
    =
  `Assoc
    [
      ("fname", `String pos_fname);
      ("lnum", `Int pos_lnum);
      ("bol", `Int pos_bol);
      ("cnum", `Int pos_cnum);
    ]

let json_of_positions = function
  | None -> `Null
  | Some (p, p') -> `Tuple [json_of_position p; json_of_position p']

let json_of_if ~to_json { if_condition; if_then; if_else } : Json.t =
  `Assoc
    [
      ("condition", to_json if_condition);
      ("then", to_json if_then);
      ("else", to_json if_else);
    ]

let json_of_while ~to_json { while_condition; while_loop } : Json.t =
  `Assoc [("condition", to_json while_condition); ("loop", to_json while_loop)]

let json_of_for ~to_json { for_variable; for_from; for_to; for_loop } : Json.t =
  `Assoc
    [
      ("variable", `String for_variable);
      ("from", to_json for_from);
      ("to", to_json for_to);
      ("loop", to_json for_loop);
    ]

let json_of_iterable_for ~to_json
    { iterable_for_variable; iterable_for_iterator; iterable_for_loop } : Json.t
    =
  `Assoc
    [
      ("variable", `String iterable_for_variable);
      ("iterator", to_json iterable_for_iterator);
      ("loop", to_json iterable_for_loop);
    ]

let json_of_try ~to_json
    { try_body; try_variable; try_errors_list; try_handler } : Json.t =
  `Assoc
    [
      ("body", to_json try_body);
      ("variable", `String try_variable);
      ("errors_list", to_json try_errors_list);
      ("handler", to_json try_handler);
    ]

let type_node ~typ value =
  `Assoc
    [
      ("type", `String "type_annotation");
      ("subtype", `String typ);
      ("value", value);
    ]

let rec json_of_type_annotation = function
  | `Named n -> type_node ~typ:"named" (`String n)
  | `Nullable t -> type_node ~typ:"nullable" (json_of_type_annotation t)
  | `List t -> type_node ~typ:"list" (json_of_type_annotation t)
  | `Json_object t -> type_node ~typ:"json_object" (json_of_type_annotation t)
  | `Tuple l ->
      type_node ~typ:"tuple" (`Tuple (List.map json_of_type_annotation l))
  | `Arrow (args, t) ->
      type_node ~typ:"arrow"
        (`Tuple
          [
            `Tuple
              (List.map
                 (fun (b, s, t) ->
                   `Tuple [`Bool b; `String s; json_of_type_annotation t])
                 args);
            json_of_type_annotation t;
          ])
  | `Record l ->
      type_node ~typ:"record" (`Tuple (List.map json_of_meth_annotation l))
  | `Method (t, l) ->
      type_node ~typ:"method"
        (`Tuple
          [
            json_of_type_annotation t;
            `Tuple (List.map json_of_meth_annotation l);
          ])
  | `Invoke (t, s) ->
      type_node ~typ:"invoke" (`Tuple [json_of_type_annotation t; `String s])
  | `Source (n, t) ->
      type_node ~typ:"source" (`Tuple [`String n; json_of_source_annotation t])

and json_of_meth_annotation { optional; name; typ; json_name } =
  `Assoc
    [
      ("optional", `Bool optional);
      ("name", `String name);
      ("type", json_of_type_annotation typ);
      ("json_name", match json_name with None -> `Null | Some n -> `String n);
    ]

and json_of_source_annotation { extensible; tracks } =
  `Assoc
    [
      ("extensible", `Bool extensible);
      ("tracks", `Tuple (List.map json_of_source_track_annotation tracks));
    ]

and json_of_source_track_annotation { track_name; track_type; track_params } =
  `Assoc
    [
      ("name", `String track_name);
      ("type", `String track_type);
      ( "params",
        `Tuple
          (List.map (fun (l, v) -> `Tuple [`String l; `String v]) track_params)
      );
    ]

let ast_node ~typ value = `Assoc [("type", `String typ); ("value", value)]

let rec json_of_pat : pattern -> Json.t = function
  | `PVar l -> ast_node ~typ:"pvar" (`Tuple (List.map (fun v -> `String v) l))
  | `PTuple l -> ast_node ~typ:"ptuple" (`Tuple (List.map json_of_pat l))
  | `PList (l, v, l') ->
      ast_node ~typ:"plist"
        (`Tuple
          [
            `Tuple (List.map json_of_pat l);
            (match v with None -> `Null | Some s -> `String s);
            `Tuple (List.map json_of_pat l');
          ])
  | `PMeth (p, l) ->
      let json_of_opt_pat = function
        | None -> `Null
        | Some p -> json_of_pat p
      in
      ast_node ~typ:"pmeth"
        (`Tuple
          [
            json_of_opt_pat p;
            `Tuple
              (List.map
                 (fun (lbl, p) -> `Tuple [`String lbl; json_of_opt_pat p])
                 l);
          ])

let json_of_let ~to_json { Term_base.replace; pat; def; body } =
  `Assoc
    [
      ("replace", `Bool replace);
      ("pat", json_of_pat pat);
      ("definition", to_json def);
      ("body", to_json body);
    ]

let json_of_func_argument ~to_json
    { Term_base.label; as_variable; typ; default } =
  `Assoc
    [
      ("label", `String label);
      ( "as_variable",
        match as_variable with None -> `Null | Some v -> `String v );
      ("typ", json_of_type_annotation typ);
      ("default", match default with None -> `Null | Some d -> to_json d);
    ]

let json_of_func ~to_json { Term_base.arguments; body } =
  `Assoc
    [
      ("arguments", `Tuple (List.map (json_of_func_argument ~to_json) arguments));
      ("body", to_json body);
    ]

let rec to_ast_json : parsed_ast -> Json.t = function
  | `Get t -> ast_node ~typ:"get" (to_json t)
  | `Set (t, t') -> ast_node ~typ:"set" (`Tuple [to_json t; to_json t'])
  | `Inline_if p -> ast_node ~typ:"inline_if" (json_of_if ~to_json p)
  | `If p -> ast_node ~typ:"if" (json_of_if ~to_json p)
  | `While p -> ast_node ~typ:"while" (json_of_while ~to_json p)
  | `For p -> ast_node ~typ:"for" (json_of_for ~to_json p)
  | `Iterable_for p ->
      ast_node ~typ:"iterable_for" (json_of_iterable_for ~to_json p)
  | `Not t -> ast_node ~typ:"not" (to_json t)
  | `Negative t -> ast_node ~typ:"negative" (to_json t)
  | `Append (t, t') -> ast_node ~typ:"append" (`Tuple [to_json t; to_json t'])
  | `Assoc (t, t') -> ast_node ~typ:"assoc" (`Tuple [to_json t; to_json t'])
  | `Infix (t, op, t') ->
      ast_node ~typ:"infix" (`Tuple [to_json t; `String op; to_json t'])
  | `Bool (t, op, t') ->
      ast_node ~typ:"bool" (`Tuple [to_json t; `String op; to_json t'])
  | `Simple_fun t -> ast_node ~typ:"simple_fun" (to_json t)
  | `Regexp (name, flags) ->
      ast_node ~typ:"refexp"
        (`Assoc
          [
            ("name", `String name);
            ( "flags",
              `Tuple (List.map (fun c -> `String (Char.escaped c)) flags) );
          ])
  | `Try p -> ast_node ~typ:"try" (json_of_try ~to_json p)
  | `Ground g -> ast_node ~typ:"ground" (Term_base.Ground.to_json ~pos:[] g)
  | `Encoder e -> ast_node ~typ:"encoder" (to_encoder_json e)
  | `List l -> ast_node ~typ:"list" (`Tuple (List.map to_json l))
  | `Tuple l -> ast_node ~typ:"tuple" (`Tuple (List.map to_json l))
  | `Null -> ast_node ~typ:"null" `Null
  | `Parsed_cast (t, typ) ->
      ast_node ~typ:"cast" (`Tuple [to_json t; json_of_type_annotation typ])
  | `Invoke { Term_base.invoked; default; meth } ->
      ast_node ~typ:"invoke"
        (`Assoc
          [
            ("invoked", to_json invoked);
            ("default", match default with None -> `Null | Some d -> to_json d);
            ("meth", `String meth);
          ])
  | `Open (t, t') -> ast_node ~typ:"open" (`Tuple [to_json t; to_json t'])
  | `Let p -> ast_node ~typ:"let" (json_of_let ~to_json p)
  | `Var s -> ast_node ~typ:"var" (`String s)
  | `Seq (t, t') -> ast_node ~typ:"seq" (`Tuple [to_json t; to_json t'])
  | `App (t, l) ->
      ast_node ~typ:"app"
        (`Assoc
          [
            ("op", to_json t);
            ( "args",
              `Tuple (List.map (fun (v, t) -> `Tuple [`String v; to_json t]) l)
            );
          ])
  | `Parsed_fun p -> ast_node ~typ:"fun" (json_of_func ~to_json p)
  | `Parsed_rfun (lbl, p) ->
      ast_node ~typ:"rfun" (`Tuple [`String lbl; json_of_func ~to_json p])
  | `Cast _ | `Fun _ | `RFun _ -> assert false

and to_encoder_json (lbl, params) =
  `Tuple [`String lbl; `Tuple (List.map to_encoder_param_json params)]

and to_encoder_param_json = function
  | lbl, `Encoder e -> `Tuple [`String lbl; to_ast_json (`Encoder e)]
  | lbl, `Term t -> `Tuple [`String lbl; ast_node ~typ:"term" (to_json t)]

and to_json { t; methods; term } : Json.t =
  `Assoc
    [
      ("position", json_of_positions t.pos);
      ( "methods",
        `Assoc
          (List.map
             (fun (lbl, tm) -> (lbl, to_json tm))
             (Methods.bindings methods)) );
      ("ast", to_ast_json term);
    ]
