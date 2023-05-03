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

(** base class *)

let output = Modules.output

let encoder_factory ?format format_val =
  let format =
    match format with Some f -> f | None -> Lang.to_format format_val
  in
  try Encoder.get_factory format
  with Not_found ->
    raise (Error.Invalid_value (format_val, "Unsupported encoding format"))

class virtual base ~source ~name p =
  let e f v = f (List.assoc v p) in
  (* Output settings *)
  let autostart = e Lang.to_bool "start" in
  let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
  let on_start =
    let f = List.assoc "on_start" p in
    fun () -> ignore (Lang.apply f [])
  in
  let on_stop =
    let f = List.assoc "on_stop" p in
    fun () -> ignore (Lang.apply f [])
  in
  object (self)
    inherit
      Output.encoded
        ~infallible ~on_start ~on_stop ~autostart ~output_kind:"output.file"
          ~name source

    val mutable encoder = None
    val mutable current_metadata = None
    method virtual private encoder_factory : Encoder.factory

    method start =
      let enc = self#encoder_factory self#id in
      let meta =
        match current_metadata with
          | Some m -> m
          | None -> Meta_format.empty_metadata
      in
      encoder <- Some (enc meta)

    (* Make sure to call stop on the encoder to close any open
       connection. *)
    method stop =
      match encoder with
        | None -> ()
        | Some enc ->
            (try ignore (enc.Encoder.stop ()) with _ -> ());
            encoder <- None

    method! reset = ()

    method encode frame ofs len =
      let enc = Option.get encoder in
      enc.Encoder.encode frame ofs len

    method virtual write_pipe : string -> int -> int -> unit
    method send b = Strings.iter self#write_pipe b
    method insert_metadata m = (Option.get encoder).Encoder.insert_metadata m
  end

(** url output: discard encoded data, try to restart on encoding error (can be
    networking issues etc.) *)
let url_proto frame_t =
  Output.proto
  @ [
      ("url", Lang.string_t, None, Some "Url to output to.");
      ( "restart_delay",
        Lang.nullable_t Lang.float_t,
        Some (Lang.float 2.),
        Some "If not `null`, restart output on errors after the given delay." );
      ( "on_error",
        Lang.fun_t [(false, "", Lang.error_t)] Lang.unit_t,
        Some (Lang.val_fun [("", "", None)] (fun _ -> Lang.unit)),
        Some "Callback executed when an error occurs." );
      ( "self_sync",
        Lang.bool_t,
        Some (Lang.bool false),
        Some
          "Should the source control its own synchronization? Set to `true` \
           for output to e.g. `rtmp` output using `%ffmpeg` and etc." );
      ("", Lang.format_t frame_t, None, Some "Encoding format.");
      ("", Lang.source_t frame_t, None, None);
    ]

class url_output p =
  let url = Lang.to_string (List.assoc "url" p) in
  let format_val = Lang.assoc "" 1 p in
  let format = Lang.to_format format_val in
  let () =
    if not (Encoder.url_output format) then
      raise
        (Error.Invalid_value
           (format_val, "Encoding format does not support output url!"))
  in
  let format = Encoder.with_url_output format url in
  let source = Lang.assoc "" 2 p in
  let restart_delay =
    Lang.to_valued_option Lang.to_float (List.assoc "restart_delay" p)
  in
  let on_error = List.assoc "on_error" p in
  let on_error ~bt exn =
    let error = Lang.runtime_error_of_exception ~bt ~kind:"output" exn in
    ignore (Lang.apply on_error [("", Lang.error error)])
  in
  let on_start =
    let f = List.assoc "on_start" p in
    fun () -> ignore (Lang.apply f [])
  in
  let p =
    List.map
      (fun ((lbl, _) as v) ->
        match lbl with
          | "on_start" -> ("on_start", Lang.val_fun [] (fun _ -> Lang.unit))
          | _ -> v)
      p
  in
  let self_sync = Lang.to_bool (List.assoc "self_sync" p) in
  let name = "output.url" in
  object (self)
    inherit base p ~source ~name as super
    method private encoder_factory = encoder_factory ~format format_val
    val mutable restart_time = 0.

    method! start =
      match encoder with
        | None when restart_time <= Unix.gettimeofday () -> (
            try
              super#start;
              on_start ()
            with exn -> (
              let bt = Printexc.get_raw_backtrace () in
              Utils.log_exception ~log:self#log
                ~bt:(Printexc.raw_backtrace_to_string bt)
                (Printf.sprintf "Error while connecting: %s"
                   (Printexc.to_string exn));
              on_error ~bt exn;
              match restart_delay with
                | None -> Printexc.raise_with_backtrace exn bt
                | Some delay ->
                    restart_time <- Unix.gettimeofday () +. delay;
                    self#log#important "Will try again in %.02f seconds." delay)
            )
        | _ -> ()

    method! encode frame ofs len =
      try
        match encoder with
          | None when restart_time <= Unix.gettimeofday () ->
              super#start;
              on_start ();
              super#encode frame ofs len
          | None -> Strings.empty
          | Some _ -> super#encode frame ofs len
      with exn -> (
        let bt = Printexc.get_raw_backtrace () in
        Utils.log_exception ~log:self#log
          ~bt:(Printexc.raw_backtrace_to_string bt)
          (Printf.sprintf "Error while encoding data: %s"
             (Printexc.to_string exn));
        on_error ~bt exn;
        match restart_delay with
          | None -> Printexc.raise_with_backtrace exn bt
          | Some delay ->
              self#stop;
              restart_time <- Unix.gettimeofday () +. delay;
              self#log#important "Will try again in %.02f seconds." delay;
              Strings.empty)

    method write_pipe _ _ _ = ()
    method! self_sync = (`Static, self_sync)
  end

let _ =
  let return_t = Lang.univ_t () in
  Lang.add_operator ~base:output "url" (url_proto return_t) ~return_t
    ~category:`Output ~meth:Output.meth
    ~descr:
      "Encode and let encoder handle data output. Useful with encoder with no \
       expected output or to encode to files that need full control from the \
       encoder, e.g. `%ffmpeg` with `rtmp` output." (fun p ->
      (new url_output p :> Output.output))

(** Piped virtual class: open/close pipe,
  * implements metadata interpolation and
  * takes care of the various reload mechanisms. *)

let pipe_proto frame_t arg_doc =
  let reopen_t =
    Lang.fun_t
      [
        (false, "error", Lang.nullable_t Lang.error_t);
        (false, "metadata", Lang.nullable_t Lang.metadata_t);
      ]
      (Lang.nullable_t Lang.float_t)
  in
  Output.proto
  @ [
      ( "should_reopen",
        reopen_t,
        Some (Lang.val_cst_fun [("error", None); ("metadata", None)] Lang.null),
        Some
          "Callback called on error and metadata. If returned value is not \
           `null` (and positive), the output is reopened after this delay has \
           expired, if negative the output is not reopened and an error is \
           raised if the `error` argument was present." );
      ( "on_reopen",
        Lang.fun_t [] Lang.unit_t,
        Some (Lang.val_cst_fun [] Lang.unit),
        Some "Callback executed when the output is reopened." );
      ("", Lang.format_t frame_t, None, Some "Encoding format.");
      ("", Lang.getter_t Lang.string_t, None, Some arg_doc);
      ("", Lang.source_t frame_t, None, None);
    ]

class virtual piped_output ~name p =
  let source = Lang.assoc "" 3 p in
  let should_reopen = List.assoc "should_reopen" p in
  let should_reopen ?error ?metadata () =
    let map fn = function None -> Lang.null | Some v -> fn v in
    let error = map Lang.error error in
    let metadata = map Lang.metadata metadata in
    match
      Lang.to_valued_option Lang.to_float
        (Lang.apply should_reopen [("error", error); ("metadata", metadata)])
    with
      | Some v when 0. <= v -> v
      | _ -> -1.
  in
  let on_reopen = List.assoc "on_reopen" p in
  let on_reopen () = ignore (Lang.apply on_reopen []) in
  object (self)
    inherit base ~source ~name p as super
    method reopen_cmd = self#reopen
    val mutable open_date = 0.
    val mutable need_reopen = false
    method virtual open_pipe : unit
    method virtual close_pipe : unit
    method virtual is_open : bool

    method interpolate ?(subst = fun x -> x) s =
      let current_metadata =
        match current_metadata with
          | Some m ->
              fun x -> subst (Hashtbl.find (Meta_format.to_metadata m) x)
          | None -> fun _ -> raise Not_found
      in
      Utils.interpolate current_metadata s

    method prepare_pipe =
      self#open_pipe;
      open_date <- Unix.gettimeofday ();
      need_reopen <- false

    method private close_encoder =
      match encoder with
        | None -> ()
        | Some encoder ->
            let flush = encoder.Encoder.stop () in
            super#send flush

    method! stop =
      if self#is_open then (
        self#close_encoder;
        self#close_pipe);
      super#stop

    method reopen =
      self#log#important "Re-opening output pipe.";
      self#close_encoder;
      self#close_pipe;
      self#prepare_pipe;
      on_reopen ()

    method! output =
      try super#output
      with exn ->
        let bt = Printexc.get_raw_backtrace () in
        self#close_encoder;
        self#close_pipe;
        let error = Lang.runtime_error_of_exception ~bt ~kind:"output" exn in
        let open_delay = should_reopen ~error () in
        if open_delay < 0. then Printexc.raise_with_backtrace exn bt;
        open_date <- Unix.gettimeofday () +. open_delay;
        self#log#important "Error while streaming: %s, will re-open in %.02fs"
          (Printexc.to_string exn) open_delay

    method! send b =
      (match self#is_open with
        | false when open_date <= Unix.gettimeofday () -> self#prepare_pipe
        | true when need_reopen ->
            if open_date <= Unix.gettimeofday () then self#reopen
        | true -> (
            match should_reopen () with
              | 0. -> self#reopen
              | v when 0. < v ->
                  need_reopen <- true;
                  open_date <- Unix.gettimeofday () +. v
              | _ -> ())
        | _ -> ());
      if self#is_open then super#send b

    method! insert_metadata metadata =
      match should_reopen ~metadata:(Meta_format.to_metadata metadata) () with
        | 0. ->
            self#reopen;
            super#insert_metadata metadata
        | open_delay ->
            super#insert_metadata metadata;
            if open_delay > 0. then (
              self#log#info "New metadata received, will re-open in %.02fs"
                open_delay;
              need_reopen <- true;
              open_date <- Unix.gettimeofday () +. open_delay)
  end

(** Out channel virtual class: takes care of current out channel and writing to
    it. *)
let chan_proto frame_t arg_doc =
  [
    ( "flush",
      Lang.bool_t,
      Some (Lang.bool false),
      Some "Perform a flush after each write." );
  ]
  @ pipe_proto frame_t arg_doc

class virtual ['a] chan_output p =
  let flush = Lang.to_bool (List.assoc "flush" p) in
  object (self)
    val mutable chan : 'a option = None
    method virtual open_chan : 'a
    method virtual close_chan : 'a -> unit
    method virtual output_substring : 'a -> string -> int -> int -> unit
    method virtual flush : 'a -> unit
    method open_pipe = chan <- Some self#open_chan

    method write_pipe b ofs len =
      let chan = Option.get chan in
      try
        self#output_substring chan b ofs len;
        if flush then self#flush chan
      with Sys_error _ as exn ->
        let bt = Printexc.get_raw_backtrace () in
        Lang.raise_as_runtime ~bt ~kind:"system" exn

    method close_pipe =
      self#close_chan (Option.get chan);
      chan <- None

    method is_open = chan <> None
  end

(** File output *)

class virtual ['a] file_output_base p =
  let filename = Lang.to_string_getter (Lang.assoc "" 2 p) in
  let on_close = List.assoc "on_close" p in
  let on_close s = Lang.to_unit (Lang.apply on_close [("", Lang.string s)]) in
  let perm = Lang.to_int (List.assoc "perm" p) in
  let dir_perm = Lang.to_int (List.assoc "dir_perm" p) in
  let append = Lang.to_bool (List.assoc "append" p) in
  object (self)
    val current_filename = Atomic.make None
    method virtual interpolate : ?subst:(string -> string) -> string -> string

    method private filename =
      let filename = filename () in
      let filename = Lang_string.home_unrelate filename in
      (* Avoid / in metas for filename.. *)
      let subst m = Pcre.substitute ~pat:"/" ~subst:(fun _ -> "-") m in
      self#interpolate ~subst filename

    method virtual open_out_gen : open_flag list -> int -> string -> 'a

    method private prepare_filename =
      let mode =
        Open_wronly :: Open_creat
        :: (if append then [Open_append] else [Open_trunc])
      in
      match Atomic.get current_filename with
        | Some filename -> (filename, mode, perm)
        | None -> (
            let filename = self#filename in
            try
              Utils.mkdir ~perm:dir_perm (Filename.dirname filename);
              Atomic.set current_filename (Some filename);
              (filename, mode, perm)
            with Sys_error _ as exn ->
              let bt = Printexc.get_raw_backtrace () in
              Lang.raise_as_runtime ~bt ~kind:"system" exn)

    method open_chan =
      try
        let filename, mode, perm = self#prepare_filename in
        self#open_out_gen mode perm filename
      with Sys_error _ as exn ->
        let bt = Printexc.get_raw_backtrace () in
        Lang.raise_as_runtime ~bt ~kind:"system" exn

    method virtual close_out : 'a -> unit

    method close_chan fd =
      try
        self#close_out fd;
        self#on_close (Option.get (Atomic.get current_filename));
        Atomic.set current_filename None
      with Sys_error _ as exn ->
        let bt = Printexc.get_raw_backtrace () in
        Lang.raise_as_runtime ~bt ~kind:"system" exn

    method private on_close = on_close
  end

class file_output ~format_val p =
  object
    inherit piped_output ~name:"output.file" p
    inherit [out_channel] chan_output p
    inherit [out_channel] file_output_base p
    method encoder_factory = encoder_factory format_val

    method open_out_gen mode perm filename =
      let fd = open_out_gen mode perm filename in
      set_binary_mode_out fd true;
      fd

    method output_substring = output_substring
    method flush = flush
    method close_out = close_out
  end

class file_output_using_encoder ~format_val p =
  let format = Lang.to_format format_val in
  let append = Lang.to_bool (List.assoc "append" p) in
  let p = ("append", Lang.bool true) :: List.remove_assoc "append" p in
  object (self)
    inherit piped_output ~name:"output.file" p
    inherit [unit] chan_output p
    inherit [unit] file_output_base p

    method open_out_gen mode perm filename =
      let fd = open_out_gen mode perm filename in
      close_out fd;
      ()

    method encoder_factory name meta =
      (* Make sure the file is created with the right perms. *)
      let filename, mode, perm = self#prepare_filename in
      self#open_out_gen mode perm filename;
      let format = Encoder.with_file_output ~append format filename in
      encoder_factory ~format format_val name meta

    method output_substring () _ _ _ = ()
    method flush () = ()
    method close_out () = ()
  end

let file_proto frame_t =
  [
    ( "append",
      Lang.bool_t,
      Some (Lang.bool false),
      Some "Do not truncate but append in the file if it exists." );
    ( "perm",
      Lang.int_t,
      Some (Lang.int 0o666),
      Some
        "Permission of the file if it has to be created, up to umask. You can \
         and should write this number in octal notation: 0oXXX. The default \
         value is however displayed in decimal (0o666 = 6×8^2 + 6×8 + 6 = \
         438)." );
    ( "dir_perm",
      Lang.int_t,
      Some (Lang.int 0o777),
      Some
        "Permission of the directories if some have to be created, up to \
         umask. Although you can enter values in octal notation (0oXXX) they \
         will be displayed in decimal (for instance, 0o777 = 7×8^2 + 7×8 + 7 = \
         511)." );
    ( "on_close",
      Lang.fun_t [(false, "", Lang.string_t)] Lang.unit_t,
      Some (Lang.val_cst_fun [("", None)] Lang.unit),
      Some
        "This function will be called for each file, after that it is finished \
         and closed. The filename will be passed as argument." );
  ]
  @ chan_proto frame_t "Filename where to output the stream."

let new_file_output p =
  let format_val = Lang.assoc "" 1 p in
  let format = Lang.to_format format_val in
  if Encoder.file_output format then
    (new file_output_using_encoder ~format_val p :> piped_output)
  else (new file_output ~format_val p :> piped_output)

let output_file =
  let return_t = Lang.univ_t () in
  Lang.add_operator ~base:output "file" (file_proto return_t) ~return_t
    ~category:`Output ~meth:Output.meth
    ~descr:"Output the source stream to a file." (fun p ->
      (new_file_output p :> Output.output))

(** External output *)

class external_output p =
  let format_val = Lang.assoc "" 1 p in
  let process = Lang.to_string_getter (Lang.assoc "" 2 p) in
  let self_sync = Lang.to_bool (List.assoc "self_sync" p) in
  object (self)
    inherit piped_output ~name:"output.external" p
    inherit [out_channel] chan_output p
    method encoder_factory = encoder_factory format_val
    method! self_sync = (`Static, self_sync)

    method open_chan =
      let process = process () in
      let process = self#interpolate process in
      Unix.open_process_out process

    method close_chan chan =
      try ignore (Unix.close_process_out chan)
      with Sys_error msg when msg = "Broken pipe" -> ()

    method output_substring = output_substring
    method flush = flush
    method close_out = close_out
  end

let pipe_proto frame_t descr =
  ( "self_sync",
    Lang.bool_t,
    Some (Lang.bool false),
    Some
      "Set to `true` if the process is expected to control the output's \
       latency. Typical example: `ffmpeg` with the `-re` command-line option."
  )
  :: chan_proto frame_t descr

let _ =
  let return_t = Lang.univ_t () in
  let meth =
    List.map
      (fun (a, b, c, fn) -> (a, b, c, fun s -> fn (s :> Output.output)))
      Output.meth
  in
  Lang.add_operator ~base:output "external"
    (pipe_proto return_t "Process to pipe data to.")
    ~return_t ~category:`Output
    ~meth:
      (meth
      @ [
          ( "reopen",
            ([], Lang.fun_t [] Lang.unit_t),
            "Reopen the pipe.",
            fun s ->
              Lang.val_fun [] (fun _ ->
                  s#reopen_cmd;
                  Lang.unit) );
        ])
    ~descr:"Send the stream to a process' standard input."
    (fun p -> new external_output p)
