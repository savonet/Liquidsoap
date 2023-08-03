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

open Mm
open Source
open Dssi

let log = Log.make ["DSSI synthesizer"]

let dssi_enable =
  try
    let venv = Unix.getenv "LIQ_DSSI" in
    venv = "1" || venv = "true"
  with Not_found -> true

let dssi_load =
  try
    let venv = Unix.getenv "LIQ_DSSI_LOAD" in
    Pcre.split ~pat:":" venv
  with Not_found -> []

let plugin_dirs =
  try
    let path = Unix.getenv "LIQ_DSSI_PATH" in
    Pcre.split ~pat:":" path
  with Not_found -> ["/usr/lib/dssi"; "/usr/local/lib/dssi"]

(* Number of channels to synthesize when in all mode *)
let all_chans = 16

(* chan = None means synth all channels *)
class dssi ?chan plugin descr outputs params source =
  object
    inherit operator ~name:"dssi" [source]
    method seek n = source#seek n
    method seek_source = source
    method stype = source#stype
    method remaining = source#remaining
    method is_ready = source#is_ready
    method self_sync = source#self_sync
    method abort_track = source#abort_track

    val di =
      let p = Plugin.load plugin in
      let d = Descriptor.descriptor p descr in
      ( d,
        Array.init
          (if chan <> None then 1 else all_chans)
          (fun _ ->
            Ladspa.Descriptor.instantiate (Descriptor.ladspa d)
              (Lazy.force Frame.audio_rate)) )

    initializer
      Array.iter (fun inst -> Ladspa.Descriptor.activate inst) (snd di)

    method private get_frame buf =
      let descr, inst = di in
      let offset = Frame.position buf in
      let position =
        source#get buf;
        Frame.position buf
      in
      let b = AFrame.pcm buf in
      let evs = MFrame.midi buf in
      (* Now convert everything to audio samples. *)
      let offset = Frame.audio_of_main offset in
      let position = Frame.audio_of_main position in
      let len = position - offset in
      let evs =
        let dssi_of_midi (t, e) =
          let t = Frame.audio_of_main (Frame.main_of_midi t) in
          match e with
            | MIDI.Note_on (n, v) ->
                Some (t, Dssi.Event_note_on (0, n, int_of_float (v *. 127.)))
            | MIDI.Note_off (n, v) ->
                Some (t, Dssi.Event_note_off (0, n, int_of_float (v *. 127.)))
            | _ -> None
        in
        match chan with
          | Some chan ->
              let evs = MIDI.data evs.(chan) in
              [| Array.of_list (List.filter_map dssi_of_midi evs) |]
          | None ->
              Array.init all_chans (fun chan ->
                  Array.of_list
                    (List.filter_map dssi_of_midi (MIDI.data evs.(chan))))
      in
      assert (Array.length outputs = Array.length b);
      let ba = Audio.to_ba b offset len in
      Array.iter
        (fun inst ->
          List.iter
            (fun (p, v) -> Ladspa.Descriptor.set_control_port inst p (v ()))
            params;
          for c = 0 to Array.length outputs - 1 do
            Ladspa.Descriptor.connect_port inst outputs.(c) ba.(c)
          done)
        inst;
      try Descriptor.run_multiple_synths descr ~adding:true inst len evs
      with Descriptor.Not_implemented ->
        for i = 0 to (if chan = None then all_chans else 1) - 1 do
          Descriptor.run_synth ~adding:true descr inst.(i) len evs.(i)
        done;
        Audio.copy_from_ba ba b offset len
  end

let dssi = Lang.add_module "dssi"
let synth_dssi = Lang.add_module ~base:Modules.synth "dssi"
let synth_all_dssi = Lang.add_module ~base:Modules.synth_all "dssi"

let register_descr plugin_name descr_n descr outputs =
  let ladspa_descr = Descriptor.ladspa descr in
  let liq_params, params = Ladspa_op.params_of_descr ladspa_descr in
  let chans = Array.length outputs in
  let frame_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make
         ~audio:(Format_type.audio_n chans)
         ~midi:(Format_type.midi_n 1) ())
  in
  let liq_params = liq_params in
  ignore
    (Lang.add_operator ~base:synth_dssi
       (Utils.normalize_parameter_string (Ladspa.Descriptor.label ladspa_descr))
       ([
          ( "channel",
            Lang.int_t,
            Some (Lang.int 0),
            Some "MIDI channel to handle." );
        ]
       @ liq_params
       @ [("", Lang.source_t frame_t, None, None)])
       ~return_t:frame_t ~category:`Synthesis ~flags:[`Extra]
       ~descr:(Ladspa.Descriptor.name ladspa_descr ^ ".")
       (fun p ->
         let f v = List.assoc v p in
         let chan = Lang.to_int (f "channel") in
         let source = Lang.to_source (f "") in
         let params = params p in
         new dssi plugin_name descr_n outputs params ~chan source));

  let frame_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make
         ~audio:(Format_type.audio_n chans)
         ~midi:(Format_type.midi_n all_chans)
         ())
  in
  ignore
    (Lang.add_operator ~base:synth_all_dssi
       (Utils.normalize_parameter_string (Ladspa.Descriptor.label ladspa_descr))
       (liq_params @ [("", Lang.source_t frame_t, None, None)])
       ~return_t:frame_t ~category:`Synthesis ~flags:[`Extra]
       ~descr:(Ladspa.Descriptor.name ladspa_descr ^ ".")
       (fun p ->
         let f v = List.assoc v p in
         let source = Lang.to_source (f "") in
         let params = params p in
         new dssi plugin_name descr_n outputs params source))

let register_plugin ?(log_errors = false) pname =
  try
    let p = Plugin.load pname in
    let descr = Descriptor.descriptors p in
    Array.iteri
      (fun n d ->
        let ladspa_descr = Descriptor.ladspa d in
        let i, o = Ladspa_op.get_audio_ports ladspa_descr in
        (* TODO: we should handle inputs too someday *)
        if Array.length i = 0 then (
          register_descr pname n d o;
          if log_errors then
            log#important "Registered DSSI plugin: %s."
              (Ladspa.Descriptor.label ladspa_descr))
        else if log_errors then
          log#important
            "Plugin %s has inputs, don't know how to handle them for now."
            (Ladspa.Descriptor.label ladspa_descr))
      descr
    (* TODO: Unloading plugins makes liq segv. Don't do it for now. *)
    (* Plugin.unload p *)
  with Plugin.Not_a_plugin ->
    if log_errors then log#important "File \"%s\" is not a plugin!" pname

let register_plugins () =
  let plugins =
    let ans = ref [] in
    let add plugins_dir =
      try
        let dir = Unix.opendir plugins_dir in
        try
          while true do
            let f = Unix.readdir dir in
            if f <> "." && f <> ".." then ans := (plugins_dir ^ "/" ^ f) :: !ans
          done
        with End_of_file -> Unix.closedir dir
      with Unix.Unix_error (e, _, _) ->
        log#info "Error while loading directory %s: %s" plugins_dir
          (Unix.error_message e)
    in
    List.iter add plugin_dirs;
    List.rev !ans
  in
  List.iter (register_plugin ~log_errors:false) plugins

let dssi_init =
  let inited = ref false in
  fun () ->
    if !inited then ()
    else (
      Dssi.init ();
      inited := true)

let () =
  Startup.time "DSSI plugins registration" (fun () ->
      if dssi_enable then (
        dssi_init ();
        register_plugins ());
      List.iter (register_plugin ~log_errors:true) dssi_load)

let _ =
  Lang.add_builtin ~base:dssi "register" ~category:(`Source `Synthesis)
    ~descr:"Register a DSSI plugin."
    [("", Lang.string_t, None, Some "Path of the DSSI plugin file.")]
    Lang.unit_t
    (fun p ->
      dssi_init ();
      let fname = Lang.to_string (List.assoc "" p) in
      register_plugin ~log_errors:true fname;
      Lang.unit)
