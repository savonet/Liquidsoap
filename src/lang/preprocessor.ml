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

type tokenizer = unit -> Parser.token * (Lexing.position * Lexing.position)

let fst3 (x, _, _) = x
let snd3 (_, y, _) = y
let trd3 (_, _, z) = z

let mk_tokenizer ?(fname = "") lexbuf =
  Sedlexing.set_filename lexbuf fname;
  fun () ->
    let token = Lexer.token lexbuf in
    let pos = Sedlexing.lexing_positions lexbuf in
    (token, pos)

(* The Lang_lexer is not quite enough for our needs, so we first define
   convenient layers between it and the parser. First a pre-processor which
   evaluates %ifdefs. *)
let eval_ifdefs tokenizer =
  let state = ref 0 in
  let rec token () =
    let go_on () =
      incr state;
      token ()
    in
    let rec skip () =
      match tokenizer () with
        | Parser.PP_ENDIF, _ -> token ()
        | Parser.PP_ELSE, _ -> go_on ()
        | _ -> skip ()
    in
    match tokenizer () with
      | (Parser.PP_IFDEF v, _ | Parser.PP_IFNDEF v, _) as tok ->
          let test =
            match fst tok with
              | Parser.PP_IFDEF _ -> fun x -> x
              | Parser.PP_IFNDEF _ -> not
              | _ -> assert false
          in
          (* XXX Less natural meaning than the original one. *)
          if test (Environment.has_builtin v) then go_on () else skip ()
      | Parser.PP_IFVERSION (cmp, ver), _ ->
          let current = Utils.Version.of_string Configure.version in
          let ver = Utils.Version.of_string ver in
          let test =
            let compare = Utils.Version.compare current ver in
            match cmp with
              | `Eq -> compare = 0
              | `Geq -> compare >= 0
              | `Leq -> compare <= 0
              | `Gt -> compare > 0
              | `Lt -> compare < 0
          in
          if test then go_on () else skip ()
      | (Parser.PP_IFENCODER, _ | Parser.PP_IFNENCODER, _) as tok ->
          let has_enc =
            try
              let fmt =
                let token = fst (tokenizer ()) in
                match token with
                  | Parser.ENCODER e ->
                      Lang_encoder.make_encoder ~pos:None (Term.make Term.unit)
                        (e, [])
                  | _ -> failwith "expected an encoding format after %ifencoder"
              in
              let (_ : Encoder.factory) = Encoder.get_factory fmt in
              true
            with _ -> false
          in
          let test =
            if fst tok = Parser.PP_IFENCODER then fun x -> x else not
          in
          if test has_enc then go_on () else skip ()
      | Parser.PP_ELSE, _ ->
          if !state = 0 then failwith "no %ifdef to end here";
          decr state;
          skip ()
      | Parser.PP_ENDIF, _ ->
          if !state = 0 then failwith "no %ifdef to end here";
          decr state;
          token ()
      | x -> x
  in
  token

(** Expand %include statements by inserting the content of files. Filenames are
   understood relatively to the current directory, which can be a relative path
   such as "." or "..". *)
let includer dir tokenizer =
  let stack = Stack.create () in
  let peek () = try fst3 (Stack.top stack) with Stack.Empty -> tokenizer in
  let current_dir () = try snd3 (Stack.top stack) with Stack.Empty -> dir in
  let rec token () =
    match peek () () with
      | Parser.PP_INCLUDE fname, (_, curp) ->
          let fname = Utils.home_unrelate fname in
          let fname =
            if Filename.is_relative fname then
              Filename.concat (current_dir ()) fname
            else fname
          in
          let channel =
            try open_in fname
            with Sys_error _ ->
              flush_all ();
              Printf.printf "%sine %d, char %d: cannot %%include, "
                (if curp.Lexing.pos_fname = "" then "L"
                else
                  Printf.sprintf "File %s, l"
                    (Utils.quote_string curp.Lexing.pos_fname))
                curp.Lexing.pos_lnum
                (curp.Lexing.pos_cnum - curp.Lexing.pos_bol);
              Printf.printf "file %s doesn't exist.\n"
                (Utils.quote_string fname);
              exit 1
          in
          let lexbuf = Sedlexing.Utf8.from_channel channel in
          let tokenizer = mk_tokenizer ~fname lexbuf in
          Stack.push (tokenizer, Filename.dirname fname, channel) stack;
          token ()
      | (Parser.EOF, _) as tok ->
          if Stack.is_empty stack then tok
          else (
            close_in (trd3 (Stack.pop stack));
            token ())
      | x -> x
  in
  token

(* The expander turns "bla #{e} bli" into ("bla "^string_of(e)^" bli"). *)
type exp_item =
  | String of string
  | Expr of tokenizer
  | Concat
  | RPar
  | LPar
  | String_of

let expand_string tokenizer =
  let state = Queue.create () in
  let add pos x = Queue.add (x, pos) state in
  let pop () = ignore (Queue.take state) in
  let parse s pos =
    let l = Pcre.split ~pat:"#{(.*?)}" s in
    let l = if l = [] then [""] else l in
    let add = add pos in
    let rec parse = function
      | s :: x :: l ->
          let lexbuf = Sedlexing.Utf8.from_string x in
          let tokenizer = mk_tokenizer lexbuf in
          let tokenizer () = (fst (tokenizer ()), pos) in
          List.iter add
            [String s; Concat; LPar; String_of; Expr tokenizer; RPar; RPar];
          if l <> [] then (
            add Concat;
            parse l)
      | [x] -> add (String x)
      | [] -> assert false
    in
    parse l
  in
  let rec token () =
    if Queue.is_empty state then (
      match tokenizer () with
        | Parser.STRING s, pos ->
            parse s pos;
            if Queue.length state > 1 then (
              add pos RPar;
              (Parser.LPAR, pos))
            else token ()
        | x -> x)
    else (
      let el, pos = Queue.peek state in
      match el with
        | String s ->
            pop ();
            (Parser.STRING s, pos)
        | Concat ->
            pop ();
            (Parser.BIN2 "^", pos)
        | RPar ->
            pop ();
            (Parser.RPAR, pos)
        | LPar ->
            pop ();
            (Parser.LPAR, pos)
        | String_of ->
            pop ();
            (Parser.VARLPAR "string_of", pos)
        | Expr tokenizer -> (
            match tokenizer () with
              | Parser.EOF, _ ->
                  pop ();
                  token ()
              | x, _ -> (x, pos)))
  in
  token

type doc_type = [ `Full | `Argsof of string list ]

(* Glue the documenting comments to the corresponding PP_DEF (read pre-DEF) *
   and strip out other comments. *)
let parse_comments tokenizer =
  let documented_def decoration (doc, doc_startp) (startp, endp) =
    let startp =
      match doc_startp with Some startp -> startp | None -> startp
    in
    let doc =
      List.map
        (fun x -> Pcre.substitute ~pat:"^\\s*#\\s?" ~subst:(fun _ -> "") x)
        doc
    in
    let get_args doc =
      List.map
        (fun (n, d) ->
          let n = if n = "(unlabeled)" then "" else n in
          let d = d#get_doc in
          let d = if d <> "(no doc)" then d else "" in
          (n, d))
        (List.filter
           (fun (n, _) -> String.length n = 0 || n.[0] <> '_')
           doc#get_subsections)
    in
    let rec parse_doc (main, special, params, methods) = function
      | [] -> (main, special, params, methods)
      | line :: lines -> (
          try
            let sub =
              Pcre.exec
                ~pat:"^\\s*@(category|docof|flag|param|method|argsof)\\s*(.*)$"
                line
            in
            let s = Pcre.get_substring sub 2 in
            match Pcre.get_substring sub 1 with
              | "docof" ->
                  let doc = Environment.builtins#get_subsection s in
                  let main_doc = doc#get_doc in
                  let main =
                    if main_doc <> "(no doc)" then main_doc :: main else main
                  in
                  let params = get_args doc @ params in
                  let doc_specials =
                    List.fold_left
                      (fun cur n ->
                        try
                          match (doc#get_subsection n)#get_doc with
                            | "(no doc)" -> cur
                            | s when n = "_category" -> `Category s :: cur
                            | s when n = "_flag" -> `Flag s :: cur
                            | _ -> assert false
                        with Not_found -> cur)
                      [] ["_category"; "_flag"]
                  in
                  parse_doc
                    (main, doc_specials @ special, params, methods)
                    lines
              | "argsof" ->
                  let s, only, except =
                    try
                      let sub =
                        Pcre.exec ~pat:"^\\s*([^\\[]+)\\[([^\\]]+)\\]\\s*$" s
                      in
                      let s = Pcre.get_substring sub 1 in
                      let args =
                        List.filter
                          (fun s -> s <> "")
                          (List.map String.trim
                             (String.split_on_char ','
                                (Pcre.get_substring sub 2)))
                      in
                      let only, except =
                        List.fold_left
                          (fun (only, except) v ->
                            if String.length v > 0 && v.[0] = '!' then
                              ( only,
                                String.sub v 1 (String.length v - 1) :: except
                              )
                            else (v :: only, except))
                          ([], []) args
                      in
                      (s, only, except)
                    with Not_found -> (s, [], [])
                  in
                  let doc = Environment.builtins#get_subsection s in
                  let args =
                    List.filter
                      (fun (n, _) ->
                        n <> ""
                        &&
                        match (only, except) with
                          | [], except -> not (List.mem n except)
                          | only, except ->
                              List.mem n only && not (List.mem n except))
                      (get_args doc)
                  in
                  parse_doc (main, special, args @ params, methods) lines
              | "category" ->
                  parse_doc
                    (main, `Category s :: special, params, methods)
                    lines
              | "flag" ->
                  parse_doc (main, `Flag s :: special, params, methods) lines
              | "param" ->
                  let sub = Pcre.exec ~pat:"^(~?[a-zA-Z0-9_.]+)\\s*(.*)$" s in
                  let label = Pcre.get_substring sub 1 in
                  let descr = Pcre.get_substring sub 2 in
                  let label =
                    if label.[0] = '~' then
                      String.sub label 1 (String.length label - 1)
                    else ""
                  in
                  let rec parse_descr descr lines =
                    match lines with
                      | [] -> raise Not_found
                      | line :: lines ->
                          let line =
                            Pcre.substitute ~pat:"^ *" ~subst:(fun _ -> "") line
                          in
                          let n = String.length line - 1 in
                          if line.[n] = '\\' then (
                            let descr = String.sub line 0 n :: descr in
                            parse_descr descr lines)
                          else (
                            let descr = List.rev (line :: descr) in
                            (String.concat "" descr, lines))
                  in
                  let descr, lines = parse_descr [] (descr :: lines) in
                  parse_doc
                    (main, special, (label, descr) :: params, methods)
                    lines
              | "method" ->
                  let sub = Pcre.exec ~pat:"^(~?[a-zA-Z0-9_.]+)\\s*(.*)$" s in
                  let label = Pcre.get_substring sub 1 in
                  let descr = Pcre.get_substring sub 2 in
                  parse_doc
                    (main, special, params, (label, descr) :: methods)
                    lines
              | _ -> assert false
          with Not_found ->
            parse_doc (line :: main, special, params, methods) lines)
    in
    let main, special, params, methods = parse_doc ([], [], [], []) doc in
    let main = List.rev main and params = List.rev params in
    let main = String.concat "\n" main in
    let main = Utils.unbreak_md main in
    (* let main = String.concat "\n" main in *)
    let doc =
      let sort = false in
      if main = "" then Doc.none ~sort () else Doc.trivial ~sort main
    in
    List.iter
      (function
        | `Category c ->
            doc#add_subsection "_category" (Lazy.from_val (Doc.trivial c))
        | `Flag c -> doc#add_subsection "_flag" (Lazy.from_val (Doc.trivial c)))
      special;
    (Parser.DEF ((doc, params, methods), decoration), (startp, endp))
  in
  let comment = ref ([], None) in
  let rec token () =
    match tokenizer () with
      | Parser.PP_COMMENT c, (startp, _) ->
          comment := (c, Some startp);
          token ()
      | Parser.PP_DEF decoration, pos ->
          let decoration =
            Parser_helper.let_decoration_of_lexer_let_decoration decoration
          in
          let c = !comment in
          comment := ([], None);
          documented_def decoration c pos
      | x ->
          comment := ([], None);
          x
  in
  token

(** Special token in order to avoid 3.{s = "a"} to be parsed as a float followed
    by a record. *)
let int_meth tokenizer =
  let q = Queue.create () in
  let fill () =
    match tokenizer () with
      | Parser.PP_INT_DOT_LCUR n, (spos, epos) ->
          let a n pos =
            { pos with Lexing.pos_cnum = pos.Lexing.pos_cnum - n }
          in
          Queue.add_seq q
            (List.to_seq
               [
                 (Parser.INT n, (spos, a 2 epos));
                 (Parser.DOT, (a 2 spos, a 1 epos));
                 (Parser.LCUR, (a 1 spos, epos));
               ])
      | t -> Queue.add t q
  in
  let token () =
    if Queue.is_empty q then fill ();
    Queue.pop q
  in
  token

(* Replace DOTVAR v with DOT, VAR v *)
let dotvar tokenizer =
  let state = ref None in
  let token () =
    match !state with
      | Some t ->
          state := None;
          t
      | None -> (
          match tokenizer () with
            | Parser.DOTVAR v, pos ->
                state := Some (Parser.VAR v, pos);
                (Parser.DOT, pos)
            | t -> t)
  in
  token

(** Change MINUS to UMINUS if the minus is not preceded by a number (or an
   expression which could produce a number). *)
let uminus tokenizer =
  let was_number = ref false in
  let token () =
    match tokenizer () with
      | (Parser.INT _, _ | Parser.FLOAT _, _ | Parser.VAR _, _ | Parser.RPAR, _)
        as t ->
          was_number := true;
          t
      | Parser.MINUS, pos when not !was_number ->
          was_number := false;
          (Parser.UMINUS, pos)
      | t ->
          was_number := false;
          t
  in
  token

(* Last but not least: remove new lines and merge some tokens around them
   in order to remove some ambiguities, typically between:
   def foo \n (x,y) ... << Normal definition, starting with a couple
   def foo(x,y) ...     << Definition of the function foo *)
let strip_newlines tokenizer =
  let state = ref None in
  let rec token () =
    let inject_varlpar var v =
      match tokenizer () with
        | Parser.LPAR, (_, endp) ->
            state := None;
            let startp = fst (snd v) in
            (Parser.VARLPAR var, (startp, endp))
        | Parser.LBRA, (_, endp) when var <> "in" ->
            state := None;
            let startp = fst (snd v) in
            (Parser.VARLBRA var, (startp, endp))
        | Parser.PP_ENDL, _ ->
            state := None;
            v
        | x ->
            state := Some x;
            v
    in
    match !state with
      | None -> (
          match tokenizer () with
            | Parser.PP_ENDL, _ -> token ()
            | (Parser.VAR _, _) as v ->
                state := Some v;
                token ()
            | x -> x)
      | Some ((Parser.VAR var, _) as v) -> inject_varlpar var v
      | Some ((Parser.UNDERSCORE, _) as v) -> inject_varlpar "_" v
      | Some x ->
          state := None;
          x
  in
  token

(* Inline %define x value. *)
let expand_define tokenizer =
  let defs = ref [] in
  let rec token () =
    match tokenizer () with
      | Parser.PP_DEFINE, pos -> (
          match tokenizer () with
            | Parser.VAR def_name, _ -> (
                if def_name <> String.uppercase_ascii def_name then
                  raise Parsing.Parse_error;
                match tokenizer () with
                  | ( Parser.INT _, _
                    | Parser.FLOAT _, _
                    | Parser.STRING _, _
                    | Parser.BOOL _, _ ) as def_val ->
                      defs := (def_name, (fst def_val, pos)) :: !defs;
                      token ()
                  | _ -> raise Parsing.Parse_error)
            | _ -> raise Parsing.Parse_error)
      | (Parser.VAR def_name, _) as v -> (
          try List.assoc def_name !defs with Not_found -> v)
      | x -> x
  in
  token

(* Wrap the lexer with its extensions *)
let mk_tokenizer ?fname ~pwd lexbuf =
  mk_tokenizer ?fname lexbuf |> includer pwd |> eval_ifdefs |> parse_comments
  |> expand_string |> int_meth |> dotvar |> uminus |> strip_newlines
  |> expand_define
