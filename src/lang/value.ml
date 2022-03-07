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

(** Values are untyped normal forms of terms. *)

(** Ground values. *)
module Ground = Term.Ground

type t =
  | Ground of Ground.t
  | Source of Source.source
  | Encoder of Encoder.format
  | List of t list
  | Tuple of t list
  | Null
  (* TODO: It would be better to have a list of methods associated to each
     value than a constructor here. However, I am keeping as is for now because
     implementation is safer this way. *)
  | Meth of string * t * t
  | Ref of t ref
  (* Function with given list of argument name, argument variable and default
     value, the (relevant part of the) closure, and the body. *)
  | Fun of (string * string * t option) list * lazy_env * TermDB.t
  (* For a foreign function only the arguments are visible, the closure
     doesn't capture anything in the environment. *)
  | FFI of (string * string * t option) list * (env -> t)

and env = (string * t) list

(* Some values have to be lazy in the environment because of recursive functions. *)
and lazy_env = t Lazy.t list

type encoder_params = (string * [ `Value of t | `Encoder of encoder ]) list

(** The type of evaluated encoder terms. *)
and encoder = string * encoder_params

let unit : t = Tuple []

let string_of_float f =
  let s = string_of_float f in
  if s.[String.length s - 1] = '.' then s ^ "0" else s

let rec print_value = function
  | Ground g -> Ground.to_string g
  | Source _ -> "<source>"
  | Encoder e -> Encoder.string_of_format e
  | List l -> "[" ^ String.concat ", " (List.map print_value l) ^ "]"
  | Ref a -> Printf.sprintf "ref(%s)" (print_value !a)
  | Tuple l -> "(" ^ String.concat ", " (List.map print_value l) ^ ")"
  | Null -> "null"
  | Meth (l, v, e) when Lazy.force Term.debug ->
      print_value e ^ ".{" ^ l ^ "=" ^ print_value v ^ "}"
  | Meth _ as v ->
      let rec split = function
        | Meth (l, v, e) ->
            let m, e = split e in
            ((l, v) :: m, e)
        | e -> ([], e)
      in
      let m, e = split v in
      let m =
        List.rev m
        |> List.map (fun (l, v) -> l ^ " = " ^ print_value v)
        |> String.concat ", "
      in
      let e = match e with Tuple [] -> "" | _ -> print_value e ^ "." in
      e ^ "{" ^ m ^ "}"
  | Fun ([], _, x) when TermDB.is_ground x ->
      "{" ^ TermDB.string_of_ground x ^ "}"
  | Fun (l, _, x) when TermDB.is_ground x ->
      let f (label, _, value) =
        match (label, value) with
          | "", None -> "_"
          | "", Some v -> Printf.sprintf "_=%s" (print_value v)
          | label, Some v -> Printf.sprintf "~%s=%s" label (print_value v)
          | label, None -> Printf.sprintf "~%s=_" label
      in
      let args = List.map f l in
      Printf.sprintf "fun (%s) -> %s" (String.concat "," args)
        (TermDB.string_of_ground x)
  | Fun _ | FFI _ -> "<fun>"

(** Find a method in a value. *)
let rec invoke x l =
  match x with
    | Meth (l', y, _) when l' = l -> y
    | Meth (_, _, x) -> invoke x l
    | _ -> failwith ("Could not find method " ^ l ^ " of " ^ print_value x)

(** Perform a sequence of invokes: invokes x [l1;l2;l3;...] is x.l1.l2.l3... *)
let rec invokes x = function l :: ll -> invokes (invoke x l) ll | [] -> x

let split_meths e =
  let rec aux hide = function
    | Meth (l, v, e) ->
        if List.mem l hide then aux hide e
        else (
          let m, e = aux (l :: hide) e in
          ((l, v) :: m, e))
    | _ -> ([], e)
  in
  aux [] e

let rec demeth = function Meth (_, _, v) -> demeth v | v -> v

let rec remeth t u =
  match t with Meth (l, v, t) -> Meth (l, v, remeth t u) | _ -> u

let compare a b =
  let rec aux = function
    | Ground a, Ground b -> Ground.compare a b
    | Tuple l, Tuple m ->
        List.fold_left2
          (fun cmp a b -> if cmp <> 0 then cmp else compare a b)
          0 l m
    | List l1, List l2 ->
        let rec cmp = function
          | [], [] -> 0
          | [], _ -> -1
          | _, [] -> 1
          | h1 :: l1, h2 :: l2 ->
              let c = compare h1 h2 in
              if c = 0 then cmp (l1, l2) else c
        in
        cmp (l1, l2)
    | Null, Null -> 0
    | Null, _ -> -1
    | _, Null -> 1
    | _ -> assert false
  and compare a b =
    let a' = demeth a in
    let b' = demeth b in
    (* For records, we compare the list ["label", field; ..] of common fields. *)
    if a' = Tuple [] && b' = Tuple [] then (
      let r a =
        let m, _ = split_meths a in
        m
      in
      let a = r a in
      let b = r b in
      (* Keep only common fields: with subtyping it might happen that some fields are ignored. *)
      let a =
        List.filter (fun (l, _) -> List.exists (fun (l', _) -> l = l') b) a
      in
      let b =
        List.filter (fun (l, _) -> List.exists (fun (l', _) -> l = l') a) b
      in
      let a = List.sort (fun x x' -> Stdlib.compare (fst x) (fst x')) a in
      let b = List.sort (fun x x' -> Stdlib.compare (fst x) (fst x')) b in
      let a =
        Tuple
          (List.map (fun (lbl, v) -> Tuple [Ground (Ground.String lbl); v]) a)
      in
      let b =
        Tuple
          (List.map (fun (lbl, v) -> Tuple [Ground (Ground.String lbl); v]) b)
      in
      aux (a, b))
    else aux (a', b')
  in
  compare a b

(** Operations on evaluation environments. *)
module Env = struct
  type nonrec t = lazy_env

  let add (env : t) v : t = Lazy.from_val v :: env
  let add_lazy (env : t) v : t = v :: env
  let add_list env l = List.fold_right (fun v env -> add env v) l env

  let lookup (env : t) var =
    match List.nth_opt env var with
      | Some v -> Lazy.force v
      | None ->
          failwith
            (Printf.sprintf "Internal error: variable %d not in environment."
               var)
end

(* Abstract values. *)

module type Abstract = sig
  include Term.Abstract

  val to_value : content -> t
  val of_value : t -> content
  val is_value : t -> bool
end

module type AbstractDef = Term.AbstractDef

module MkAbstractFromTerm (Term : Term.Abstract) = struct
  include Term

  let to_value c = Ground (to_ground c)

  let of_value = function
    | Ground g when is_ground g -> of_ground g
    | _ -> assert false

  let is_value = function Ground g -> is_ground g | _ -> false
end

module MkAbstract (Def : AbstractDef) = struct
  module Term = Term.MkAbstract (Def)
  include MkAbstractFromTerm (Term)
end

module RuntimeType = MkAbstract (struct
  type content = Type.t

  let name = "type"
  let descr _ = "type"

  let to_json _ =
    raise
      Runtime_error.(
        Runtime_error
          {
            kind = "json";
            msg = "Types cannot be represented as json";
            pos = [];
          })

  let compare = Stdlib.compare
end)
