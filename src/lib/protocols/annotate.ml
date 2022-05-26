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

(* The annotate protocol allows to set the initial metadata for a request:
 * annotate:key1=val1,key2=val2,...:uri
 * is resolved into uri, and adds the bindings to the request metadata.
 * The values can be "strings", or directly integers, floats or identifiers. *)

exception Error of string

let log = Log.make ["annotate"]

let parse s =
  let lexbuf = Sedlexing.Utf8.from_string s in
  try
    let processor =
      MenhirLib.Convert.Simplified.traditional2revised Parser.annotate
    in
    let tokenizer = Preprocessor.mk_tokenizer ~pwd:"" lexbuf in
    let metadata = processor tokenizer in
    let b = Buffer.create 10 in
    let rec f () =
      match Sedlexing.next lexbuf with
        | Some c ->
            Buffer.add_utf_8_uchar b c;
            f ()
        | None -> Buffer.contents b
    in
    (metadata, f ())
  with _ ->
    let startp, endp = Sedlexing.loc lexbuf in
    let err = Printf.sprintf "Char %d-%d: Syntax error" startp endp in
    log#info "Error while parsing annotate URI %s: %s" (Utils.quote_string s)
      err;
    raise (Error err)

let annotate s ~log _ =
  try
    let metadata, uri = parse s in
    [Request.indicator ~metadata:(Utils.hashtbl_of_list metadata) uri]
  with Error err ->
    log err;
    []

let () =
  Lang.add_protocol ~doc:"Add metadata to a request"
    ~syntax:"annotate:key=\"val\",key2=\"val2\",...:uri" ~static:false
    "annotate" annotate
