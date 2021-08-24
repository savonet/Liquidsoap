(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

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

exception Found of (Lang.value * Lang.value option)

let settings = ref Lang.null

(* Return a lazy variable, to be executed when all dependent
   OCaml modules have been linked. *)
let settings_module =
  lazy
    (let get_conf_type conf =
       let is_type fn =
         try
           ignore (fn conf);
           true
         with _ -> false
       in
       let has_default_value fn =
         try
           ignore (fn conf)#get;
           true
         with _ -> false
       in
       if is_type Dtools.Conf.as_unit then (Lang.unit_t, false)
       else if is_type Dtools.Conf.as_int then
         (Lang.int_t, has_default_value Dtools.Conf.as_int)
       else if is_type Dtools.Conf.as_float then
         (Lang.float_t, has_default_value Dtools.Conf.as_float)
       else if is_type Dtools.Conf.as_bool then
         (Lang.bool_t, has_default_value Dtools.Conf.as_bool)
       else if is_type Dtools.Conf.as_string then
         (Lang.string_t, has_default_value Dtools.Conf.as_string)
       else if is_type Dtools.Conf.as_list then
         (Lang.list_t Lang.string_t, has_default_value Dtools.Conf.as_list)
       else (Lang.unit_t, false)
     in
     let set_t ty =
       [
         ("description", ([], Lang.string_t), "Description of the setting");
         ( "comments",
           ([], Lang.string_t),
           "Additional comments about the setting" );
       ]
       @
       if ty = Lang.unit_t then []
       else
         [
           ( "set",
             ([], Lang.fun_t [(false, "", ty)] Lang.unit_t),
             "Set configuration value" );
         ]
     in
     let get_t ~has_default_value ty =
       match (ty, has_default_value) with
         | ty, _ when ty = Lang.unit_t -> Lang.unit_t
         | ty, true -> Lang.fun_t [] ty
         | ty, false -> Lang.fun_t [] (Lang.nullable_t ty)
     in
     let rec get_type ?(sub = []) conf =
       let ty, has_default_value = get_conf_type conf in
       Lang.method_t
         (get_t ~has_default_value ty)
         (set_t ty @ leaf_types conf @ sub)
     and leaf_types conf =
       List.map
         (fun label ->
           let ty = get_type (conf#path [label]) in
           let label = Utils.normalize_parameter_string label in
           ( label,
             ([], ty),
             Printf.sprintf "Entry for configuration key %s" label ))
         conf#subs
     in
     let log_t = get_type Dtools.Log.conf in
     let init_t = get_type Dtools.Init.conf in
     let settings_t =
       get_type
         ~sub:
           [
             ("init", ([], init_t), "Daemon settings");
             ("log", ([], log_t), "Logging settings");
           ]
         Configure.conf
     in
     let get_v fn conv_to conv_from conf =
       let get =
         Lang.val_fun [] (fun _ ->
             try conv_to (fn conf)#get with _ -> Lang.null)
       in
       let set =
         Lang.val_fun [("", "", None)] (fun p ->
             (fn conf)#set (conv_from (List.assoc "" p));
             Lang.unit)
       in
       (get, Some set)
     in
     let rec get_value ?(sub = []) conf =
       let to_v fn conv_to conv_from =
         try
           ignore (fn conf);
           raise (Found (get_v fn conv_to conv_from conf))
         with
           | Found v -> raise (Found v)
           | _ -> ()
       in
       let get_v, set_v =
         try
           to_v Dtools.Conf.as_int Lang.int Lang.to_int;
           to_v Dtools.Conf.as_float Lang.float Lang.to_float;
           to_v Dtools.Conf.as_bool Lang.bool Lang.to_bool;
           to_v Dtools.Conf.as_string Lang.string Lang.to_string;
           to_v Dtools.Conf.as_list
             (fun l -> Lang.list (List.map Lang.string l))
             (fun v -> List.map Lang.to_string (Lang.to_list v));
           (Lang.unit, None)
         with Found v -> v
       in
       Lang.meth get_v
         ((if set_v <> None then [("set", Option.get set_v)] else [])
         @ [
             ("description", Lang.string (String.trim conf#descr));
             ( "comments",
               Lang.string (String.trim (String.concat "" conf#comments)) );
           ]
         @ leaf_values conf @ sub)
     and leaf_values conf =
       List.map
         (fun label ->
           let v = get_value (conf#path [label]) in
           (Utils.normalize_parameter_string label, v))
         conf#subs
     in
     let init = get_value Dtools.Init.conf in
     let log = get_value Dtools.Log.conf in
     settings := get_value ~sub:[("log", log); ("init", init)] Configure.conf;
     Lang.add_builtin_base ~category:"Liquidsoap" "settings"
       ~descr:"All settings." !settings.Lang.value settings_t)

(* Hack to keep track of latest settings at runtime. *)
open Lang_builtins

let () =
  add_builtin ~cat:Liq "set_settings_ref" ~descr:"Internal use only!"
    ~flags:[Lang.Hidden]
    [("", Lang.univ_t (), None, None)]
    Lang.unit_t
    (fun p ->
      settings := List.assoc "" p;
      Lang.unit)

type descr = {
  description : string;
  comments : string;
  children : (string * descr) list;
  value : Lang.in_value;
}

let filtered_settings = ["subordinate log level"]

let print_settings () =
  let rec grab_descr cur = function
    | Term.V.Meth ("description", d, v) ->
        grab_descr { cur with description = Lang.to_string d } v.Lang.value
    | Term.V.Meth ("comments", c, v) ->
        grab_descr { cur with comments = Lang.to_string c } v.Lang.value
    | Term.V.Meth ("set", _, v) -> grab_descr cur v.Lang.value
    | Term.V.Meth (key, _, v) when List.mem_assoc key cur.children ->
        grab_descr cur v.Lang.value
    | Term.V.Meth (key, c, v) ->
        let descr =
          {
            description = "";
            comments = "";
            children = [];
            value = Term.V.Tuple [];
          }
        in
        grab_descr
          {
            cur with
            children = (key, grab_descr descr c.Lang.value) :: cur.children;
          }
          v.Lang.value
    | value -> { cur with value }
  in
  let descr =
    { description = ""; comments = ""; children = []; value = Term.V.Tuple [] }
  in
  let descr = grab_descr descr !settings.Lang.value in
  let filter_children =
    List.filter (fun (_, { description }) ->
        not (List.mem description filtered_settings))
  in
  let print_set ~path = function
    | Term.V.Tuple [] -> []
    | value ->
        [
          (match Lang.apply { Term.V.pos = None; value } [] with
            | v when v.Term.V.value = Term.V.Null ->
                Printf.sprintf {|
```liquidsoap
%s.set(<value>)
```
|} path
            | v ->
                Printf.sprintf {|
```liquidsoap
%s.set(%s)
```
|} path
                  (Term.V.print_value v));
        ]
  in
  let rec print_descr ~level ~path descr =
    Printf.sprintf {|
%s %s
%s|} (String.make level '#')
      (String.capitalize_ascii descr.description)
      (String.concat ""
         ((match descr.comments with "" -> [] | v -> ["\n"; v; "\n"])
         @ print_set ~path descr.value
         @ List.map
             (fun (k, d) ->
               print_descr ~level:(level + 1) ~path:(path ^ "." ^ k) d)
             (filter_children descr.children)))
  in
  print_descr ~level:1 ~path:"settings" descr

(* Deprecated backward-compatible get/set. *)

let () =
  let grab path value =
    let path = String.split_on_char '.' path in
    let rec grab links v =
      match (links, v.Term.V.value) with
        | [], _ -> v
        | link :: links, Term.V.Meth (key, v, _) when key = link -> grab links v
        | _, Term.V.Meth (_, _, v) -> grab links v
        | _ -> raise Not_found
    in
    grab path value
  in
  add_builtin ~cat:Liq "set"
    ~descr:
      "Change some setting. Use `liquidsoap --list-settings` on the \
       command-line to get some information about available settings."
    ~flags:[Lang.Deprecated; Lang.Hidden]
    [
      ("", Lang.string_t, None, None);
      ("", Lang.univ_t ~constraints:[Type.Dtools] (), None, None);
    ]
    Lang.unit_t
    (fun p ->
      log#severe
        "WARNING: \"set\" is deprecated and will be removed in future version. \
         Please use `settings.path.to.key.set(value)`";
      let path = Lang.to_string (Lang.assoc "" 1 p) in
      let value = Lang.assoc "" 2 p in
      (try
         let set = grab (path ^ ".set") !settings in
         try ignore (Lang.apply (Lang.demeth set) [("", value)])
         with _ ->
           log#severe
             "WARNING: Error while setting value %s for setting %S. Is that \
              the right type for it?"
             (Lang.print_value value) path
       with Not_found -> log#severe "WARNING: setting %S does not exist!" path);
      Lang.unit);

  let univ = Lang.univ_t ~constraints:[Type.Dtools] () in
  add_builtin "get" ~cat:Liq ~descr:"Get a setting's value."
    ~flags:[Lang.Deprecated; Lang.Hidden]
    [("default", univ, None, None); ("", Lang.string_t, None, None)] univ
    (fun p ->
      log#severe
        "WARNING: \"get\" is deprecated and will be removed in future version. \
         Please use `settings.path.to.key()`";
      let path = Lang.to_string (List.assoc "" p) in
      let default = List.assoc "default" p in
      try
        let get = grab path !settings in
        let v = Lang.apply (Lang.demeth get) [] in
        match (default.Lang.value, v.Lang.value) with
          | Lang.(Ground (Ground.Bool _)), Lang.(Ground (Ground.Bool _))
          | Lang.(Ground (Ground.Int _)), Lang.(Ground (Ground.Int _))
          | Lang.(Ground (Ground.Float _)), Lang.(Ground (Ground.Float _))
          | Lang.(Ground (Ground.String _)), Lang.(Ground (Ground.String _))
          | Lang.(List []), Lang.(List [])
          | ( Lang.(List ({ pos = _; value = Ground (Ground.String _) } :: _)),
              Lang.(List []) )
          | ( Lang.(List []),
              Lang.(List ({ pos = _; value = Ground (Ground.String _) } :: _)) )
          | ( Lang.(List ({ pos = _; value = Ground (Ground.String _) } :: _)),
              Lang.(List ({ pos = _; value = Ground (Ground.String _) } :: _)) )
            ->
              v
          | _ ->
              log#severe
                "WARNING: Invalid value/default pair (%s vs. %s) for setting \
                 %S!"
                (Lang.print_value v) (Lang.print_value default) path;
              default
      with
        | Not_found ->
            log#severe "WARNING: setting %S does not exist!" path;
            default
        | _ ->
            log#severe "WARNING: could not get setting %s value!" path;
            default)
