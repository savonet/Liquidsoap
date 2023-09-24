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

let finalise_child_clock child_clock source =
  Clock.forget source#clock child_clock

(** [rms_width] and [minimum_length] are all in samples.
  * [cross_length] is in ticks (like #remaining estimations).
  * We are assuming a fixed audio kind -- at least for now. *)
class cross val_source ~duration_getter ~override_duration ~persist_override
  ~rms_width ~minimum_length ~conservative transition =
  let s = Lang.to_source val_source in
  let original_duration_getter = duration_getter in
  object (self)
    inherit source ~name:"cross" () as super
    inherit! Child_support.base ~check_self_sync:true [val_source]
    initializer Typing.(s#frame_type <: self#frame_type)
    method stype = `Fallible

    (* This is complicated. crossfade should never be used with [self_sync]
     * sources but we do not have a static way of knowing it at the moment.
     * Going with the same choice as above for now. *)
    method self_sync = s#self_sync
    val mutable cross_length = 0
    val mutable duration_getter = original_duration_getter
    method cross_duration = duration_getter ()

    method set_cross_length =
      let new_cross_length = self#cross_duration in
      let main_new_cross_length = Frame.main_of_seconds new_cross_length in

      if main_new_cross_length <> cross_length then
        if new_cross_length < 0. then
          self#log#important
            "Cannot set crossfade duration to negative value %f!"
            new_cross_length
        else (
          self#log#info "Setting crossfade duration to %.2fs" new_cross_length;
          cross_length <- main_new_cross_length)

    initializer self#set_cross_length

    (* We need to store the end of a track, and compute the power of the signal
     * before the end of track. For doing so we need to remember a sliding window
     * of samples, maintain the sum of squares, and the number of samples in that
     * sum. The sliding window is necessary because of possibly inaccurate
     * remaining time estimaton. *)
    val mutable gen_before = Generator.create Frame.Fields.empty
    val mutable rms_before = 0.
    val mutable rmsi_before = 0
    val mutable mem_before = Array.make rms_width 0.
    val mutable mem_i = 0
    val mutable before_metadata = None

    (* Same for the new track. No need for a sliding window here. *)
    val mutable gen_after = Generator.create Frame.Fields.empty
    val mutable rms_after = 0.
    val mutable rmsi_after = 0
    val mutable after_metadata = None

    (* An audio frame for intermediate computations. It is used to buffer the
       end and beginnings of tracks. Its past metadata should mimic that of the
       main stream in order to avoid metadata duplication. *)
    val mutable buf_frame = None

    method private buf_frame =
      match buf_frame with
        | Some frame -> frame
        | None ->
            let f = Frame.create self#content_type in
            buf_frame <- Some f;
            f

    method private reset_analysis =
      gen_before <- Generator.create self#content_type;
      gen_after <- Generator.create self#content_type;
      rms_before <- 0.;
      rmsi_before <- 0;
      mem_i <- 0;
      Array.iteri (fun i _ -> mem_before.(i) <- 0.) mem_before;
      rms_after <- 0.;
      rmsi_after <- 0;
      before_metadata <- after_metadata;
      after_metadata <- None

    (* The played source. We _need_ exclusive control on that source,
     * since we are going to pull data from it at a higher rate around
     * track limits. *)
    val source = s

    (* Give a default value for the transition source. *)
    val mutable transition_source = None
    val mutable pending_after = Generator.create Frame.Fields.empty

    method private prepare_transition_source s =
      let s = (s :> source) in
      s#get_ready ~dynamic:true [(self :> source)];
      Clock.unify ~pos:self#pos source#clock s#clock;
      transition_source <- Some s

    method cleanup_transition_source =
      match transition_source with
        | None -> ()
        | Some s ->
            s#leave ~dynamic:true (self :> source);
            transition_source <- None

    method! private wake_up a =
      self#reset_analysis;
      super#wake_up a;
      source#get_ready ~dynamic:true [(self :> source)];
      source#get_ready [(self :> source)];
      Lang.iter_sources
        (fun s -> s#get_ready ~dynamic:true [(self :> source)])
        transition

    method! private sleep =
      source#leave (self :> source);
      s#leave ~dynamic:true (self :> source);
      Lang.iter_sources
        (fun s -> s#leave ~dynamic:true (self :> source))
        transition;
      self#cleanup_transition_source

    (* in main time *)
    val mutable status = `Idle

    method private child_get source frame =
      self#child_on_output (fun () -> source#get frame)

    method private save_last_metadata mode buf_frame =
      let compare x y = -compare (fst x) (fst y) in
      let l = List.sort compare (AFrame.get_all_metadata buf_frame) in
      match (l, mode) with
        | (_, m) :: _, `Before -> before_metadata <- Some m
        | (_, m) :: _, `After -> after_metadata <- Some m
        | _ -> ()

    method private update_cross_length frame pos =
      if Frame.is_partial frame && not persist_override then
        duration_getter <- original_duration_getter;
      List.iter
        (fun (p, m) ->
          if p >= pos then (
            match Frame.Metadata.find_opt override_duration m with
              | None -> ()
              | Some v -> (
                  try
                    self#log#info
                      "Overriding crossfade duration from metadata %s"
                      override_duration;
                    let l = float_of_string v in
                    duration_getter <- (fun () -> l)
                  with _ -> ())))
        (Frame.get_all_metadata frame);
      self#set_cross_length

    method private get_frame frame =
      match status with
        | `Idle ->
            let rem = source#remaining in
            if conservative || (0 <= rem && rem <= cross_length) then (
              self#log#info "Buffering end of track...";
              status <- `Before;
              let buf_frame = self#buf_frame in
              Frame.set_breaks buf_frame [Frame.position frame];
              Frame.set_all_metadata buf_frame [];
              self#buffering cross_length;
              if status <> `Limit then
                self#log#info "More buffering will be needed.";
              self#get_frame frame)
            else (
              let p = Frame.position frame in
              self#child_get source frame;
              self#save_last_metadata `Before frame;
              self#update_cross_length frame p)
        | `Before ->
            (* We started buffering but the track didn't end.
             * Play the beginning of the buffer while filling it more. *)
            let len = Generator.length gen_before in
            if len <= cross_length then self#buffering (cross_length - len);
            Generator.fill gen_before frame
        | `Limit ->
            (* The track finished.
             * We compute rms_after and launch the transition. *)
            if source#is_ready ~frame () then self#analyze_after;
            self#create_transition;

            (* Check if the new source is ready *)
            if (Option.get transition_source)#is_ready ~frame () then
              self#get_frame frame
            else
              (* If not, finish this track, which requires our callers
               * to wait that we become ready again. *)
              Frame.add_break frame (Frame.position frame)
        | `After when (Option.get transition_source)#is_ready ~frame () ->
            self#child_get (Option.get transition_source) frame;

            if Generator.length pending_after = 0 && Frame.is_partial frame then (
              status <- `Idle;
              self#cleanup_transition_source;

              (* If underlying source if ready, try to continue filling up the frame
               * using it. Each call to [get_frame] must add exactly one break so
               * call it again and then remove the intermediate break that was just
               * added. *)
              if source#is_ready ~frame () then (
                self#get_frame frame;
                Frame.set_breaks frame
                  (match List.rev (Frame.breaks frame) with
                    | b :: _ :: l -> List.rev (b :: l)
                    | _ -> assert false)))
        | `After ->
            (* Here, transition source went down so we switch back to main source.
               Our [is_ready] check ensures that we only get here when the main source
               is ready. *)
            status <- `Idle;
            self#cleanup_transition_source;
            self#get_frame frame

    (* [bufferize n] stores at most [n+d] samples from [s] in [gen_before],
     * where [d=AFrame.size-1]. *)
    method private buffering n =
      let buf_frame = self#buf_frame in
      if not (Frame.is_partial buf_frame) then Frame.clear buf_frame;
      let start = AFrame.position buf_frame in
      let stop =
        self#child_get source buf_frame;
        AFrame.position buf_frame
      in
      self#save_last_metadata `Before buf_frame;
      self#update_cross_length buf_frame start;
      Generator.feed
        ~offset:(Frame.main_of_audio start)
        ~length:(Frame.main_of_audio (stop - start))
        gen_before buf_frame;

      (* Analyze them *)
      let pcm = AFrame.pcm buf_frame in
      let len = stop - start in
      let squares = Audio.squares pcm start len in
      rms_before <- rms_before -. mem_before.(mem_i) +. squares;
      mem_before.(mem_i) <- squares;
      mem_i <- (mem_i + len) mod rms_width;
      rmsi_before <- min rms_width (rmsi_before + len);

      (* Should we buffer more or are we done ? *)
      if AFrame.is_partial buf_frame then (
        Generator.add_track_mark gen_before;
        status <- `Limit)
      else if n > 0 then self#buffering (n - stop + start)

    (* Analyze the beginning of a new track. *)
    method private analyze_after =
      let buf_frame = self#buf_frame in
      let before_len = Generator.length gen_before in
      let rec f () =
        let start = AFrame.position buf_frame in
        let stop =
          self#child_get source buf_frame;
          AFrame.position buf_frame
        in
        Generator.feed
          ~offset:(Frame.main_of_audio start)
          ~length:(Frame.main_of_audio (stop - start))
          gen_after buf_frame;
        let after_len = Generator.length gen_after in
        if after_len <= rms_width then (
          let pcm = AFrame.pcm buf_frame in
          let len = stop - start in
          let squares = Audio.squares pcm start len in
          rms_after <- rms_after +. squares;
          rmsi_after <- rmsi_after + len);
        self#save_last_metadata `After buf_frame;
        self#update_cross_length buf_frame start;
        if
          AFrame.is_partial buf_frame
          && not (source#is_ready ~frame:buf_frame ())
        then Generator.add_track_mark gen_after
        else (
          if not (Frame.is_partial buf_frame) then Frame.clear buf_frame;
          if after_len < before_len then f ())
      in
      f ()

    (* Sum up analysis and build the transition *)
    method private create_transition =
      let db_after =
        Audio.dB_of_lin
          (sqrt (rms_after /. float rmsi_after /. float self#audio_channels))
      in
      let db_before =
        Audio.dB_of_lin
          (sqrt (rms_before /. float rmsi_before /. float self#audio_channels))
      in
      let compound =
        Clock.collect_after (fun () ->
            let metadata = function
              | None -> Frame.Metadata.empty
              | Some m -> m
            in
            let before_metadata = metadata before_metadata in
            let after_metadata = metadata after_metadata in
            let before =
              new Insert_metadata.replay
                before_metadata
                (new Generated.consumer gen_before)
            in
            Typing.(before#frame_type <: self#frame_type);
            let after =
              new Insert_metadata.replay
                after_metadata
                (new Generated.consumer gen_after)
            in
            Typing.(after#frame_type <: self#frame_type);
            let () =
              before#set_id (self#id ^ "_before");
              after#set_id (self#id ^ "_after")
            in
            let f a b =
              let params =
                [
                  ( "",
                    Lang.meth Lang.unit
                      [
                        ("source", Lang.source a);
                        ("db_level", Lang.float db_before);
                        ("metadata", Lang.metadata before_metadata);
                      ] );
                  ( "",
                    Lang.meth Lang.unit
                      [
                        ("source", Lang.source b);
                        ("db_level", Lang.float db_after);
                        ("metadata", Lang.metadata after_metadata);
                      ] );
                ]
              in
              Lang.to_source (Lang.apply transition params)
            in
            let compound =
              self#log#important "Analysis: %fdB / %fdB (%.2fs / %.2fs)"
                db_before db_after
                (Frame.seconds_of_main (Generator.length gen_before))
                (Frame.seconds_of_main (Generator.length gen_after));
              if Frame.main_of_audio minimum_length < Generator.length gen_after
              then f before after
              else (
                self#log#important "Not enough data for crossing.";
                (new Sequence.sequence [before; after] :> source))
            in
            Clock.unify ~pos:self#pos compound#clock s#clock;
            Typing.(compound#frame_type <: self#frame_type);
            compound)
      in
      self#cleanup_transition_source;
      self#prepare_transition_source compound;
      pending_after <- gen_after;
      status <- `After;
      self#reset_analysis

    method remaining =
      match status with
        | `Before | `Idle -> source#remaining
        | `Limit -> -1
        | `After -> (Option.get transition_source)#remaining

    method seek len =
      match status with
        | `Before | `Idle -> source#seek len
        | `Limit -> -1
        | `After -> (Option.get transition_source)#seek len

    method seek_source =
      match status with
        | `Before | `Idle -> source
        | `After -> Option.get transition_source
        | _ -> (self :> Source.source)

    method private _is_ready ?frame () =
      match status with
        | `Idle | `Before -> source#is_ready ?frame ()
        | `Limit -> true
        | `After ->
            (Option.get transition_source)#is_ready ?frame ()
            || source#is_ready ?frame ()

    method abort_track =
      if status = `After && (Option.get transition_source)#is_ready () then
        (Option.get transition_source)#abort_track
      else source#abort_track
  end

let _ =
  let frame_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make ~audio:(Format_type.audio ()) ())
  in
  let transition_arg =
    Lang.method_t Lang.unit_t
      [
        ("source", ([], Lang.source_t frame_t), "Source");
        ("db_level", ([], Lang.float_t), "dB level of the source.");
        ("metadata", ([], Lang.metadata_t), "Metadata of the source.");
      ]
  in
  Lang.add_operator "cross"
    [
      ( "duration",
        Lang.getter_t Lang.float_t,
        Some (Lang.float 5.),
        Some
          "Duration (in seconds) of buffered data from each track that is used \
           to compute the transition between tracks." );
      ( "override_duration",
        Lang.string_t,
        Some (Lang.string "liq_cross_duration"),
        Some
          "Metadata field which, if present and containing a float, overrides \
           the 'duration' parameter for current track." );
      ( "persist_override",
        Lang.bool_t,
        Some (Lang.bool false),
        Some "Keep duration override on track change." );
      ( "minimum",
        Lang.float_t,
        Some (Lang.float (-1.)),
        Some
          "Minimum duration (in sec.) for a cross: If the track ends without \
           any warning (e.g. in case of skip) there may not be enough data for \
           a decent composition. Set to 0. to avoid having transitions after \
           skips, or more to avoid transitions on short tracks. With a \
           negative default, transitions always occur." );
      ( "width",
        Lang.float_t,
        Some (Lang.float 2.),
        Some "Width of the power computation window." );
      ( "conservative",
        Lang.bool_t,
        Some (Lang.bool true),
        Some
          "Do not trust remaining time estimations, always buffering data in \
           advance. This avoids being tricked by skips, either manual or \
           caused by blank.skip()." );
      ( "",
        Lang.fun_t
          [(false, "", transition_arg); (false, "", transition_arg)]
          (Lang.source_t frame_t),
        None,
        Some
          "Transition function, composing from the end of a track and the next \
           track. The sources corresponding to the two tracks are decorated \
           with fields indicating the power of the signal before and after the \
           transition (`power`), and the metadata (`metadata`)." );
      ("", Lang.source_t frame_t, None, None);
    ]
    ~return_t:frame_t ~category:`Fade
    ~meth:
      [
        ( "cross_duration",
          Lang.([], fun_t [] float_t),
          "Get the current crossfade duration.",
          fun s -> Lang.val_fun [] (fun _ -> Lang.float s#cross_duration) );
      ]
    ~descr:
      "Cross operator, allowing the composition of the _n_ last seconds of a \
       track with the beginning of the next track, using a transition function \
       depending on the relative power of the signal before and after the end \
       of track."
    (fun p ->
      let duration_getter = Lang.to_float_getter (List.assoc "duration" p) in
      let override_duration =
        Lang.to_string (List.assoc "override_duration" p)
      in
      let persist_override = Lang.to_bool (List.assoc "persist_override" p) in
      let minimum = Lang.to_float (List.assoc "minimum" p) in
      let minimum_length = Frame.audio_of_seconds minimum in
      let rms_width = Lang.to_float (List.assoc "width" p) in
      let rms_width = Frame.audio_of_seconds rms_width in
      let transition = Lang.assoc "" 1 p in
      let conservative = Lang.to_bool (List.assoc "conservative" p) in
      let source = Lang.assoc "" 2 p in
      new cross
        source transition ~conservative ~duration_getter ~rms_width
        ~minimum_length ~override_duration ~persist_override)
