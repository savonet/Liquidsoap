(*****************************************************************************

  Liquidsoap, a programmable stream generator.
  Copyright 2003-2024 Savonet team

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
open Extralib
open Gstreamer
module GU = Gstreamer_utils

module SyncSource = Clock.MkSyncSource (struct
  type t = unit

  let to_string _ = "gstreamer"
end)

let sync_source = SyncSource.make ()
let log = Log.make ["gstreamer"]

let string_of_state_change = function
  | Element.State_change_success -> "success"
  | Element.State_change_async -> "asynchronous"
  | Element.State_change_no_preroll -> "no pre-roll"

exception Flushing_error of string

let () =
  Printexc.register_printer (function Flushing_error s -> Some s | _ -> None)

type ('a, 'b) element = {
  bin : Gstreamer.Element.t;
  audio : 'a option;
  video : 'b option;
}

class virtual ['a, 'b] element_factory ~on_error =
  let () =
    log#important
      "Gstreamer is DEPRECATED! Please consider moving to FFMPEG. See: \
       https://github.com/savonet/liquidsoap/issues/2592 for some discussion \
       and example."
  in
  object (self)
    val restart_m = Mutex.create ()
    val mutable restarting = false
    val mutable retry_in = -1.
    val task_m = Mutex.create ()
    val mutable task = None
    val mutable element_m = Mutex.create ()
    val mutable element = None
    method virtual log : Log.t
    method virtual make_element : ('a, 'b) element

    method private get_element =
      Mutex_utils.mutexify element_m
        (fun () ->
          match element with
            | Some el -> el
            | None ->
                let el = self#make_element in
                element <- Some el;
                el)
        ()

    method private restart_task =
      let should_run =
        Mutex_utils.mutexify restart_m
          (fun () ->
            if not restarting then (
              restarting <- true;
              true)
            else false)
          ()
      in
      if should_run then (
        try
          self#log#important "Restarting pipeline.";
          Mutex_utils.mutexify element_m
            (fun () ->
              begin
                match element with
                  | None -> ()
                  | Some el ->
                      ignore (Element.set_state el.bin Element.State_null);
                      ignore (Element.get_state el.bin)
              end;
              let el = self#make_element in
              element <- Some el;
              ignore (Element.set_state el.bin Element.State_playing);
              ignore (Element.get_state el.bin);
              retry_in <- -1.;
              GU.flush ~log:self#log
                ~on_error:(fun err -> retry_in <- on_error (Flushing_error err))
                el.bin)
            ();
          Mutex_utils.mutexify restart_m (fun () -> restarting <- false) ();
          if retry_in >= 0. then
            self#log#info
              "An error occurred while restarting pipeline, will retry in %.02f"
              retry_in
          else self#log#info "Done restarting pipeline";
          retry_in
        with exn ->
          let bt = Printexc.get_backtrace () in
          Utils.log_exception ~log:self#log ~bt
            (Printf.sprintf "Error while restarting pipeline: %s"
               (Printexc.to_string exn));
          retry_in <- on_error exn;
          self#log#important "Will retry again in %.02f" retry_in;
          Mutex_utils.mutexify restart_m (fun () -> restarting <- false) ();
          retry_in)
      else -1.

    method private register_task ~priority scheduler =
      Mutex_utils.mutexify task_m
        (fun () ->
          task <-
            Some
              (Duppy.Async.add ~priority scheduler (fun () -> self#restart_task)))
        ()

    method private stop_task =
      Mutex_utils.mutexify task_m
        (fun () ->
          match task with
            | None -> ()
            | Some t ->
                Duppy.Async.stop t;
                task <- None)
        ()

    method private restart =
      Mutex_utils.mutexify task_m
        (fun () ->
          match task with None -> () | Some t -> Duppy.Async.wake_up t)
        ()

    method private on_error exn =
      let delay = on_error exn in
      if delay >= 0. then
        Duppy.Task.add Tutils.scheduler
          {
            Duppy.Task.priority = `Non_blocking;
            events = [`Delay delay];
            handler =
              (fun _ ->
                self#restart;
                []);
          }
      else raise exn
  end

(***** Output *****)

(* Audio/video output *)

class output ~self_sync ~on_error ~infallible ~register_telnet ~on_start
  ~on_stop ?(blocking = true) source start
  (pipeline, audio_pipeline, video_pipeline) =
  let has_audio, audio_pipeline =
    match audio_pipeline with
      | Some audio_pipeline -> (true, audio_pipeline)
      | None -> (false, "")
  in
  let has_video, video_pipeline =
    match video_pipeline with
      | Some video_pipeline -> (true, video_pipeline)
      | None -> (false, "")
  in
  object (self)
    inherit
      Output.output
        ~infallible ~register_telnet ~on_start ~on_stop ~name:"output.gstreamer"
          ~output_kind:"gstreamer" source start as super

    inherit [App_src.t, App_src.t] element_factory ~on_error
    val mutable started = false

    method! self_sync =
      if self_sync then (`Dynamic, if started then Some sync_source else None)
      else (`Static, None)

    method start =
      let el = self#get_element in
      self#log#info "Playing.";
      started <- true;
      ignore (Element.set_state el.bin Element.State_playing);

      (* Don't uncomment the following line, it locks the program. I guess that
         GStreamer is waiting for some data before answering that we are
         playing. *)
      (* ignore (Element.get_state el.bin); *)
      self#register_task ~priority:`Blocking Tutils.scheduler

    method stop =
      self#stop_task;
      started <- false;
      let todo =
        Mutex_utils.mutexify element_m
          (fun () ->
            match element with
              | None -> fun () -> ()
              | Some el ->
                  element <- None;
                  fun () ->
                    if has_audio then
                      App_src.end_of_stream (Option.get el.audio);
                    if has_video then
                      App_src.end_of_stream (Option.get el.video);
                    ignore (Element.set_state el.bin Element.State_null);
                    ignore (Element.get_state el.bin);
                    GU.flush ~log:self#log el.bin)
          ()
      in
      todo ()

    method private make_element =
      let pipeline =
        if has_audio then
          Printf.sprintf "%s ! %s %s"
            (GU.Pipeline.audio_src ~channels:self#audio_channels ~block:blocking
               "audio_src")
            audio_pipeline pipeline
        else pipeline
      in
      let pipeline =
        if has_video then
          Printf.sprintf "%s ! %s %s"
            (GU.Pipeline.video_src ~block:blocking "video_src")
            video_pipeline pipeline
        else pipeline
      in
      self#log#info "GStreamer pipeline: %s" pipeline;
      let bin = Pipeline.parse_launch pipeline in
      let audio_src =
        if has_audio then (
          let audio_src =
            App_src.of_element (Bin.get_by_name bin "audio_src")
          in
          Some audio_src)
        else None
      in
      let video_src =
        if has_video then (
          let video_src =
            App_src.of_element (Bin.get_by_name bin "video_src")
          in
          Some video_src)
        else None
      in
      { bin; audio = audio_src; video = video_src }

    val mutable presentation_time = Int64.zero

    method send_frame frame =
      let el = self#get_element in
      try
        if not (Frame.is_partial frame) then (
          let len = Lazy.force Frame.size in
          let duration = Gstreamer_utils.time_of_main len in
          if has_audio then (
            let pcm = AFrame.pcm frame in
            assert (Array.length pcm = self#audio_channels);
            let len = Frame.audio_of_main len in
            let data = Bytes.create (2 * self#audio_channels * len) in
            Audio.S16LE.of_audio pcm 0 data 0 len;
            Gstreamer.App_src.push_buffer_bytes ~duration ~presentation_time
              (Option.get el.audio) data 0 (Bytes.length data));
          if has_video then (
            let buf = VFrame.data frame in
            List.iter
              (fun (_, img) ->
                let img = Video.Canvas.Image.render img in
                let y, u, v = Image.YUV420.data img in
                let buf =
                  Gstreamer.Buffer.of_data_list
                    (List.map (fun d -> (d, 0, Image.Data.length d)) [y; u; v])
                in
                Gstreamer.Buffer.set_duration buf duration;
                Gstreamer.Buffer.set_presentation_time buf presentation_time;
                Gstreamer.App_src.push_buffer (Option.get el.video) buf)
              buf.Content.Video.data);
          presentation_time <- Int64.add presentation_time duration;
          GU.flush ~log:self#log
            ~on_error:(fun err -> raise (Flushing_error err))
            el.bin)
      with e ->
        let bt = Printexc.get_backtrace () in
        Utils.log_exception ~log:self#log ~bt
          (Printf.sprintf "Error while processing output data: %s"
             (Printexc.to_string e));
        self#on_error e

    method! reset = ()
  end

let output_proto ~return_t ~pipeline =
  Output.proto
  @ [
      ( "self_sync",
        Lang.bool_t,
        Some (Lang.bool true),
        Some "Use the dedicated GStreamer clock." );
      ( "on_error",
        Lang.fun_t [(false, "", Lang.string_t)] Lang.float_t,
        Some (Lang.val_cst_fun [("", None)] (Lang.float 3.)),
        Some
          "Callback executed when an error happens. The callback receives a \
           string representation of the error that occurred and returns a \
           float. If returned value is positive, connection will be tried \
           again after this amount of time (in seconds)." );
      ( "pipeline",
        Lang.string_t,
        Some (Lang.string pipeline),
        Some "GStreamer pipeline for sink." );
      ("", Lang.source_t return_t, None, None);
    ]

let output_gstreamer = Lang.add_module ~base:Modules.output "gstreamer"
let input_gstreamer = Lang.add_module ~base:Modules.input "gstreamer"

let _ =
  let return_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make ~audio:(Format_type.audio ()) ())
  in
  Lang.add_operator ~base:output_gstreamer "audio"
    (output_proto ~return_t ~pipeline:"autoaudiosink")
    ~category:`Output ~meth:Output.meth
    ~descr:"Output stream to a GStreamer pipeline." ~return_t (fun p ->
      let self_sync = Lang.to_bool (List.assoc "self_sync" p) in
      let pipeline = Lang.to_string (List.assoc "pipeline" p) in
      let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
      let register_telnet = Lang.to_bool (List.assoc "register_telnet" p) in
      let on_error = List.assoc "on_error" p in
      let on_error error =
        let msg = Printexc.to_string error in
        Lang.to_float (Lang.apply on_error [("", Lang.string msg)])
      in
      let start = Lang.to_bool (List.assoc "start" p) in
      let on_start =
        let f = List.assoc "on_start" p in
        fun () -> ignore (Lang.apply f [])
      in
      let on_stop =
        let f = List.assoc "on_stop" p in
        fun () -> ignore (Lang.apply f [])
      in
      let source = List.assoc "" p in
      (new output
         ~self_sync ~on_error ~infallible ~register_telnet ~on_start ~on_stop
         source start ("", Some pipeline, None)
        :> Output.output))

let _ =
  let return_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make ~audio:(Format_type.audio ()) ())
  in
  Lang.add_operator ~base:output_gstreamer "video"
    (output_proto ~return_t ~pipeline:"videoconvert ! autovideosink")
    ~category:`Output ~meth:Output.meth
    ~descr:"Output stream to a GStreamer pipeline." ~return_t (fun p ->
      let self_sync = Lang.to_bool (List.assoc "self_sync" p) in
      let pipeline = Lang.to_string (List.assoc "pipeline" p) in
      let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
      let register_telnet = Lang.to_bool (List.assoc "register_telnet" p) in
      let on_error = List.assoc "on_error" p in
      let on_error error =
        let msg = Printexc.to_string error in
        Lang.to_float (Lang.apply on_error [("", Lang.string msg)])
      in
      let start = Lang.to_bool (List.assoc "start" p) in
      let on_start =
        let f = List.assoc "on_start" p in
        fun () -> ignore (Lang.apply f [])
      in
      let on_stop =
        let f = List.assoc "on_stop" p in
        fun () -> ignore (Lang.apply f [])
      in
      let source = List.assoc "" p in
      (new output
         ~self_sync ~infallible ~register_telnet ~on_error ~on_start ~on_stop
         source start ("", None, Some pipeline)
        :> Output.output))

let _ =
  let return_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make ~audio:(Format_type.audio ())
         ~video:(Format_type.video ()) ())
  in
  Lang.add_operator ~base:output_gstreamer "audio_video"
    (output_proto ~return_t ~pipeline:""
    @ [
        ( "audio_pipeline",
          Lang.string_t,
          Some (Lang.string "autoaudiosink"),
          Some "GStreamer pipeline for audio sink." );
        ( "video_pipeline",
          Lang.string_t,
          Some (Lang.string "videoconvert ! autovideosink"),
          Some "GStreamer pipeline for video sink." );
        ( "blocking",
          Lang.bool_t,
          Some (Lang.bool true),
          Some "Pushing buffers is blocking." );
      ])
    ~category:`Output ~meth:Output.meth
    ~descr:"Output stream to a GStreamer pipeline." ~return_t
    (fun p ->
      let self_sync = Lang.to_bool (List.assoc "self_sync" p) in
      let pipeline = Lang.to_string (List.assoc "pipeline" p) in
      let audio_pipeline = Lang.to_string (List.assoc "audio_pipeline" p) in
      let video_pipeline = Lang.to_string (List.assoc "video_pipeline" p) in
      let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
      let register_telnet = Lang.to_bool (List.assoc "register_telnet" p) in
      let on_error = List.assoc "on_error" p in
      let on_error error =
        let msg = Printexc.to_string error in
        Lang.to_float (Lang.apply on_error [("", Lang.string msg)])
      in
      let start = Lang.to_bool (List.assoc "start" p) in
      let blocking = Lang.to_bool (List.assoc "blocking" p) in
      let on_start =
        let f = List.assoc "on_start" p in
        fun () -> ignore (Lang.apply f [])
      in
      let on_stop =
        let f = List.assoc "on_stop" p in
        fun () -> ignore (Lang.apply f [])
      in
      let source = List.assoc "" p in
      (new output
         ~self_sync ~infallible ~register_telnet ~on_error ~on_start ~on_stop
         ~blocking source start
         (pipeline, Some audio_pipeline, Some video_pipeline)
        :> Output.output))

(***** Input *****)

(* Audio + video. *)

type 'a sink = { pending : unit -> int; pull : unit -> 'a }

class audio_video_input p (pipeline, audio_pipeline, video_pipeline) =
  let max = Lang.to_float (List.assoc "max" p) in
  let max_ticks = Frame.main_of_seconds max in
  let on_error = List.assoc "on_error" p in
  let on_error error =
    let msg = Printexc.to_string error in
    Lang.to_float (Lang.apply on_error [("", Lang.string msg)])
  in
  let restart = Lang.to_bool (List.assoc "restart" p) in
  let has_audio, has_video =
    match (audio_pipeline, video_pipeline) with
      | Some _, Some _ -> (true, true)
      | None, Some _ -> (false, true)
      | Some _, None -> (true, false)
      | None, None ->
          failwith "There should be at least one audio or video pipeline!"
  in
  let rlog = ref (fun _ -> ()) in
  object (self)
    inherit Source.source ~name:"input.gstreamer.audio_video" () as super
    inherit [string sink, Gstreamer.data sink] element_factory ~on_error
    initializer rlog := fun s -> self#log#important "%s" s
    method set_state s = ignore (Element.set_state self#get_element.bin s)
    method pause_cmd = self#set_state Element.State_paused
    method play_cmd = self#set_state Element.State_playing
    method restart_cmd = self#restart
    method fallible = true
    method remaining = -1
    method seek_source = (self :> Source.source)

    (* Source is ready when ready = true and gst has some audio or some video. *)
    val mutable ready = true

    method private can_generate_frame =
      let pending = function
        | Some sink -> sink.pending () > 0
        | None -> false
      in
      try
        ready
        && (Generator.length self#buffer > 0
           || pending self#get_element.audio
           || pending self#get_element.video)
      with e ->
        log#info "Error when trying to check if ready: %s"
          (Printexc.to_string e);
        false

    method self_sync =
      if self_sync then
        (`Dynamic, if self#is_ready then Some sync_source else None)
      else (`Static, None)

    method abort_track = ()

    method! wake_up activations =
      super#wake_up activations;
      try
        self#register_task ~priority:`Blocking Tutils.scheduler;
        ignore (Element.set_state self#get_element.bin Element.State_playing);
        ignore (Element.get_state self#get_element.bin)
      with exn ->
        self#log#info "Error setting state to playing: %s"
          (Printexc.to_string exn);
        self#on_error exn

    method! sleep =
      self#stop_task;
      let todo =
        Mutex_utils.mutexify element_m
          (fun () ->
            match element with
              | Some el ->
                  element <- None;
                  fun () ->
                    ignore (Element.set_state el.bin Element.State_null);
                    ignore (Element.get_state el.bin);
                    GU.flush ~log:self#log el.bin
              | None -> fun () -> ())
          ()
      in
      todo ();
      super#sleep

    method make_element =
      let pipeline =
        if has_audio then
          Printf.sprintf "%s %s ! %s ! %s" (pipeline ())
            (Option.get audio_pipeline ())
            (GU.Pipeline.decode_audio ())
            (GU.Pipeline.audio_sink ~channels:self#audio_channels "audio_sink")
        else pipeline ()
      in
      let pipeline =
        if has_video then
          Printf.sprintf "%s %s ! %s ! %s" pipeline
            (Option.get video_pipeline ())
            (GU.Pipeline.decode_video ())
            (GU.Pipeline.video_sink "video_sink")
        else pipeline
      in
      log#debug "GStreamer pipeline: %s" pipeline;
      let bin = Pipeline.parse_launch pipeline in
      let wrap_sink sink pull =
        let m = Mutex.create () in
        let counter = ref 0 in
        App_sink.emit_signals sink;
        App_sink.on_new_sample sink
          (Mutex_utils.mutexify m (fun () -> incr counter));
        let pending = Mutex_utils.mutexify m (fun () -> !counter) in
        let pull =
          Mutex_utils.mutexify m (fun () ->
              let b = pull sink in
              decr counter;
              b)
        in
        { pending; pull }
      in
      let audio_sink =
        if has_audio then (
          let sink = App_sink.of_element (Bin.get_by_name bin "audio_sink") in
          Some (wrap_sink sink Gstreamer.App_sink.pull_buffer_string))
        else None
      in
      let video_sink =
        if has_video then (
          let sink = App_sink.of_element (Bin.get_by_name bin "video_sink") in
          Some (wrap_sink sink Gstreamer.App_sink.pull_buffer_data))
        else None
      in
      { bin; audio = audio_sink; video = video_sink }

    method private is_generator_at_max =
      Generator.length self#buffer >= max_ticks

    method private fill_audio audio =
      while audio.pending () > 0 && not self#is_generator_at_max do
        let b = audio.pull () in
        let len = String.length b / (2 * self#audio_channels) in
        let buf = Audio.create self#audio_channels len in
        Audio.S16LE.to_audio b 0 buf 0 len;
        Generator.put self#buffer Frame.Fields.audio
          (Content.Audio.lift_data buf)
      done

    method private fill_video video =
      let width, height = self#video_dimensions in
      while video.pending () > 0 && not self#is_generator_at_max do
        let b = video.pull () in
        let img =
          Image.YUV420.make_data width height b (Image.Data.round 4 width)
            (Image.Data.round 4 (width / 2))
        in
        Generator.put self#buffer Frame.Fields.video
          (Content.Video.lift_image (Video.Canvas.Image.make img))
      done

    method generate_frame =
      let el = self#get_element in
      let conditional_fill fn = function
        | None -> ()
        | Some element -> fn element
      in
      try
        conditional_fill self#fill_audio el.audio;
        conditional_fill self#fill_video el.video;
        let frame = Generator.slice self#buffer (Lazy.force Frame.size) in
        GU.flush ~log:self#log
          ~on_error:(fun err -> raise (Flushing_error err))
          el.bin;
        frame
      with
        | Gstreamer.End_of_stream ->
            self#log#info "End of stream.";
            ready <- false;
            if restart then (
              self#log#info "Restarting.";
              self#restart);
            if self#can_generate_frame then self#generate_frame
            else self#end_of_track
        | exn ->
            let bt = Printexc.get_backtrace () in
            Utils.log_exception ~log:self#log ~bt
              (Printf.sprintf "Error while processing input data: %s"
                 (Printexc.to_string exn));
            self#on_error exn;
            self#end_of_track
  end

let input_proto =
  [
    ( "on_error",
      Lang.fun_t [(false, "", Lang.string_t)] Lang.float_t,
      Some (Lang.val_cst_fun [("", None)] (Lang.float 3.)),
      Some
        "Callback executed when an error happens. The callback receives a \
         string representation of the error that occurred and returns a float. \
         If returned value is positive, connection will be tried again after \
         this amount of time (in seconds)." );
    ( "restart",
      Lang.bool_t,
      Some (Lang.bool true),
      Some "Restart input on end of stream event." );
    ( "max",
      Lang.float_t,
      Some (Lang.float 10.),
      Some "Maximum duration of the buffered data." );
  ]

let _ =
  (* TODO: be more flexible on audio *)
  let return_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make
         ~audio:(Format_type.audio_stereo ())
         ~video:(Format_type.video ()) ())
  in
  let proto =
    input_proto
    @ [
        ( "pipeline",
          Lang.getter_t Lang.string_t,
          Some (Lang.string ""),
          Some "Main GStreamer pipeline." );
        ( "audio_pipeline",
          Lang.getter_t Lang.string_t,
          Some (Lang.string "audiotestsrc"),
          Some "Audio pipeline to input from." );
        ( "video_pipeline",
          Lang.getter_t Lang.string_t,
          Some (Lang.string "videotestsrc"),
          Some "Video pipeline to input from." );
      ]
  in
  Lang.add_operator ~base:input_gstreamer "audio_video" proto ~return_t
    ~category:`Input ~flags:[]
    ~meth:
      [
        ( "pause",
          ([], Lang.fun_t [] Lang.unit_t),
          "Pause input.",
          fun s ->
            Lang.val_fun [] (fun _ ->
                s#pause_cmd;
                Lang.unit) );
        ( "play",
          ([], Lang.fun_t [] Lang.unit_t),
          "Play input.",
          fun s ->
            Lang.val_fun [] (fun _ ->
                s#play_cmd;
                Lang.unit) );
        ( "restart",
          ([], Lang.fun_t [] Lang.unit_t),
          "Restart input.",
          fun s ->
            Lang.val_fun [] (fun _ ->
                s#restart_cmd;
                Lang.unit) );
      ]
    ~descr:"Stream audio+video from a GStreamer pipeline."
    (fun p ->
      let pipeline = Lang.to_string_getter (List.assoc "pipeline" p) in
      let audio_pipeline =
        Lang.to_string_getter (List.assoc "audio_pipeline" p)
      in
      let video_pipeline =
        Lang.to_string_getter (List.assoc "video_pipeline" p)
      in
      new audio_video_input
        p
        (pipeline, Some audio_pipeline, Some video_pipeline))

let _ =
  let return_t =
    Lang.frame_t Lang.unit_t
      (Frame.Fields.make ~audio:(Format_type.audio ()) ())
  in
  let proto =
    input_proto
    @ [
        ( "pipeline",
          Lang.getter_t Lang.string_t,
          Some (Lang.string "audiotestsrc"),
          Some "GStreamer pipeline to input from." );
      ]
  in
  Lang.add_operator ~base:input_gstreamer "audio" proto ~return_t
    ~category:`Input ~flags:[] ~descr:"Stream audio from a GStreamer pipeline."
    (fun p ->
      let pipeline = Lang.to_string_getter (List.assoc "pipeline" p) in
      (new audio_video_input p ((fun () -> ""), Some pipeline, None)
        :> Source.source))

let _ =
  let return_t =
    Lang.frame_t Lang.unit_t
      (Frame.Fields.make ~video:(Format_type.video ()) ())
  in
  let proto =
    input_proto
    @ [
        ( "pipeline",
          Lang.getter_t Lang.string_t,
          Some (Lang.string "videotestsrc"),
          Some "GStreamer pipeline to input from." );
      ]
  in
  Lang.add_operator ~base:input_gstreamer "video" proto ~return_t
    ~category:`Input ~flags:[] ~descr:"Stream video from a GStreamer pipeline."
    (fun p ->
      let pipeline = Lang.to_string_getter (List.assoc "pipeline" p) in
      (new audio_video_input p ((fun () -> ""), None, Some pipeline)
        :> Source.source))
