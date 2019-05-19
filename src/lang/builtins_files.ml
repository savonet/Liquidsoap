(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

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

open Lang_builtins
open Extralib

let log = Dtools.Log.make ["lang.file"]

let () =
  add_builtin "file.extension" ~cat:Sys ~descr:"Returns a file's extension."
    ["dir_sep",Lang.string_t,Some (Lang.string Filename.dir_sep),
     Some "Directory separator.";
     "",Lang.string_t,None,None]
    Lang.string_t
    (fun p ->
      let dir_sep = Lang.to_string (List.assoc "dir_sep" p) in
      Lang.string (Utils.file_extension ~dir_sep
        (Lang.to_string (List.assoc "" p))))

let () =
  add_builtin "file.unlink" ~cat:Sys ~descr:"Remove a file."
  ["",Lang.string_t,None,None]
  Lang.unit_t
  (fun p ->
    try
      Unix.unlink (Lang.to_string (List.assoc "" p));
      Lang.unit
    with _ -> Lang.unit)

let () =
  add_builtin "file.rmdir" ~cat:Sys ~descr:"Remove a directory and its content."
  ["",Lang.string_t,None,None]
  Lang.unit_t
  (fun p ->
    try
      Extralib.Unix.rm_dir (Lang.to_string (List.assoc "" p));
      Lang.unit
    with _ -> Lang.unit)

let () =
  add_builtin "file.temp" ~cat:Sys ~descr:"Return a fresh temporary filename. \
    The temporary file is created empty, with permissions 0o600 (readable and writable only by the file owner)."
    ["",Lang.string_t,None,Some "File prefix";
     "",Lang.string_t,None, Some "File suffix"]
    Lang.string_t
    (fun p ->
      Lang.string (Filename.temp_file
        (Lang.to_string (Lang.assoc "" 1 p))
        (Lang.to_string (Lang.assoc "" 2 p))))

let () =
  add_builtin "file.temp_dir" ~cat:Sys ~descr:"Return a fresh temporary directory name. \
    The temporary directory is created empty, with permissions 0o700 (readable, writable and listable only by the file owner)."
    ["",Lang.string_t,None,Some "Directory prefix";
     "",Lang.string_t,None, Some "Directory suffix"]
    Lang.string_t
    (fun p ->
      Lang.string (Extralib.Filename.mk_temp_dir
        (Lang.to_string (Lang.assoc "" 1 p))
        (Lang.to_string (Lang.assoc "" 2 p)))) 

let () =
  add_builtin "file.exists" ~cat:Sys
    ["",Lang.string_t,None,None] Lang.bool_t
    ~descr:"Returns true if the file or directory exists."
    (fun p ->
       let f = Lang.to_string (List.assoc "" p) in
       Lang.bool (Sys.file_exists f))

let () =
  add_builtin "file.is_directory" ~cat:Sys
    ["",Lang.string_t,None,None] Lang.bool_t
    ~descr:"Returns true if the file exists and is a directory."
    (fun p ->
       let f = Lang.to_string (List.assoc "" p) in
       Lang.bool (try Sys.is_directory f with Sys_error _ -> false))

let () =
  (* This is not named "file.read" because we might want to use that for a
     proper file API, with descriptors, etc. *)
  add_builtin "file.contents" ~cat:Sys
    ["",Lang.string_t,None,None] Lang.string_t
    ~descr:"Read the whole contents of a file."
    (fun p ->
      let f = Lang.to_string (List.assoc "" p) in
      try
        let ic = open_in_bin f in
        let s = ref Bytes.empty in
        let buflen = 1024 in
        let buf = Bytes.create buflen in
        begin
          try
            while true do
              let n = input ic buf 0 buflen in
              if n = 0 then raise Exit;
              s := Bytes.cat !s (if n = buflen then buf else Bytes.sub buf 0 n)
            done;
            assert false
          with
            | Exit -> close_in ic; Lang.string (Bytes.unsafe_to_string !s)
        end;
      with e ->
        log#f 3 "Error while reading file %S: %s" f (Printexc.to_string e);
        Lang.string "")

let () =
  add_builtin "file.write" ~cat:Sys
    ["data",Lang.string_t,None,Some "Data to write";
     "append",Lang.bool_t,Some (Lang.bool false),Some "Append data if file exists.";
     "perms",Lang.int_t,Some (Lang.int 0o644),Some "Default file rights if created";
     "",Lang.string_t,None,Some "Path to write to"] Lang.bool_t
    ~descr:"Write data to a file. Returns `true` if successful."
    (fun p ->
      let data = Lang.to_string (List.assoc "data" p) in
      let append = Lang.to_bool (List.assoc "append" p) in
      let perms = Lang.to_int (List.assoc "perms" p) in
      let f = Lang.to_string (List.assoc "" p) in
      let flag = if append then Open_append else Open_trunc in
      let flags =
        flag::[Open_wronly;Open_creat;Open_binary]
      in
      try
        let oc =
          open_out_gen flags perms f
         in
         output_string oc data;
         close_out oc;
         Lang.bool true
      with e ->
        log#f 3 "Error while writing file %S: %s" f (Printexc.to_string e);
        Lang.bool false)
 
let () =
  add_builtin "file.watch" ~cat:Sys
    [
      "",Lang.string_t,None,Some "File to watch.";
      "",Lang.fun_t [] Lang.unit_t,None,Some "Handler function.";
    ]
    (Lang.fun_t [] Lang.unit_t)
    ~descr:"Call a function when a file is modified. Returns unwatch function."
    (fun p ->
       let fname = Lang.to_string (List.assoc_nth "" 0 p) in
       let fname = Utils.home_unrelate fname in
       let f = List.assoc_nth "" 1 p in
       let f () = ignore (Lang.apply ~t:Lang.unit_t f []) in
       let watch = !Configure.file_watcher in
       let unwatch = watch [`Modify] fname f in
       Lang.val_fun [] ~ret_t:Lang.unit_t
         (fun _ _ -> unwatch (); Lang.unit))

let () =
  add_builtin "path.basename" ~cat:Sys
    ["",Lang.string_t,None,None] Lang.string_t
    ~descr:"Get the base name of a path."
    (fun p ->
       let f = Lang.to_string (List.assoc "" p) in
         Lang.string (Filename.basename f))

let () =
  add_builtin "path.dirname" ~cat:Sys
    ["",Lang.string_t,None,None] Lang.string_t
    ~descr:"Get the directory name of a path."
    (fun p ->
       let f = Lang.to_string (List.assoc "" p) in
         Lang.string (Filename.dirname f))
 
let () =
  add_builtin "path.concat" ~cat:Sys
    ["",Lang.string_t,None,None; "",Lang.string_t,None,None;] Lang.string_t
    ~descr:"Concatenate two paths, using the appropriate directory separator."
    (fun p ->
       let f = Lang.to_string (Lang.assoc "" 1 p) in
       let s = Lang.to_string (Lang.assoc "" 2 p) in
         Lang.string (Filename.concat f s))
