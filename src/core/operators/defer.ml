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

external alloc_managed_int16_ba :
  int -> (int, Bigarray.int16_signed_elt, Bigarray.c_layout) Bigarray.Array1.t
  = "liquidsoap_alloc_managed_int16_ba"

external cleanup_managed_int16_ba :
  (int, Bigarray.int16_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> unit
  = "liquidsoap_cleanup_managed_int16_ba"

(* For this to work, we need to make sure that we are never holding onto
   any view on the array.. *)
let alloc_managed_int16_ba len =
  let ba = alloc_managed_int16_ba len in
  Gc.finalise cleanup_managed_int16_ba ba;
  ba

type state = { offset : int; position : int }

class defer ~delay ~overhead ~field source =
  let overhead =
    match overhead with
      | None -> Lazy.force Frame.size
      | Some v -> Frame.main_of_seconds v
  in
  let delay = Frame.main_of_seconds delay in
  object (self)
    inherit Source.operator ~name:"defer" [source]
    method stype = `Fallible
    method remaining = source#remaining
    method abort_track = source#abort_track
    method seek = source#seek
    method seek_source = source
    method self_sync = source#self_sync
    val mutable state = { offset = 0; position = 0 }
    val mutable deferred = true
    val mutable generator = None
    val mutable data = None
    val mutable tmp_frame = None

    method private data =
      match data with
        | Some d -> d
        | None ->
            let make_chunk len =
              Array.init self#audio_channels (fun _ ->
                  alloc_managed_int16_ba (Frame.audio_of_main len))
            in
            let d = [| make_chunk delay; make_chunk overhead |] in
            data <- Some d;
            d

    method private generator =
      match generator with
        | Some g -> g
        | None ->
            let gen =
              Generator.create ~max_length:(delay + overhead) self#content_type
            in
            generator <- Some gen;
            gen

    method private tmp_frame =
      match tmp_frame with
        | Some tmp_frame -> tmp_frame
        | None ->
            let frame = Frame.create source#content_type in
            tmp_frame <- Some frame;
            frame

    method private buffer_data =
      let { offset; position } = state in
      let data = self#data.(position) in
      let chunk_len = Content_pcm_base.length data in
      let data_rem = chunk_len - offset in

      let tmp_frame = self#tmp_frame in
      Frame.clear tmp_frame;

      while Frame.is_partial tmp_frame && source#is_ready ~frame:tmp_frame () do
        source#get tmp_frame
      done;
      let gen_len = Frame.position tmp_frame in

      let gen = self#generator in
      let buffered = Generator.length gen + offset in

      List.iter
        (fun (pos, m) ->
          if pos < gen_len then
            Generator.add_metadata ~pos:(pos + buffered) gen m)
        (Frame.get_all_metadata tmp_frame);
      List.iter
        (fun pos ->
          if pos < gen_len then
            Generator.add_track_mark ~pos:(pos + buffered) gen)
        (Frame.breaks tmp_frame);

      let frame_content = Frame.get tmp_frame field in
      let frame_pcm = Content_pcm_s16.get_data frame_content in
      let blit_len = min data_rem gen_len in
      Content_pcm_base.blit frame_pcm 0 data offset blit_len;

      if offset + blit_len < chunk_len then (
        assert (gen_len = blit_len);
        state <- { offset = offset + blit_len; position })
      else (
        assert (offset + data_rem = chunk_len);
        deferred <- false;
        let position = (position + 1) mod 2 in
        let offset = gen_len - blit_len in
        Generator.put gen field (Content_pcm_s16.lift_data data);
        Content_pcm_base.blit frame_pcm blit_len self#data.(position) 0 offset;
        state <- { offset; position })

    val mutable should_queue = false

    method private queue_output =
      let clock = Source.Clock_variables.get self#clock in
      clock#on_output (fun () ->
          if source#is_ready () then self#buffer_data;
          if should_queue then
            clock#on_before_output (fun () -> self#queue_output))

    initializer
      self#on_wake_up (fun () ->
          should_queue <- true;
          self#queue_output);
      self#on_sleep (fun () -> should_queue <- false)

    method private _is_ready ?frame:_ _ =
      (not deferred) && Generator.length self#generator > 0

    method private get_frame buf = Generator.fill self#generator buf
  end

let _ =
  let frame_t = Format_type.audio ~pcm_kind:Content_pcm_s16.kind () in
  Lang.add_track_operator ~base:Modules.track_audio "defer"
    [
      ("delay", Lang.float_t, None, Some "Duration of the delay, in seconds.");
      ( "overhead",
        Lang.(nullable_t float_t),
        Some Lang.null,
        Some
          "Duration of the delay overhead, in seconds. Defaults to frame size."
      );
      ("", frame_t, None, Some "Track to delay.");
    ]
    ~category:`Track
    ~descr:
      "Defer an audio track by a given amount of time. Track will be available \
       when the given `delay` has been fully buffered. Use this operator \
       instead of `buffer` when buffering large amount of data as initial \
       delay."
    ~return_t:frame_t
    (fun p ->
      let delay = Lang.to_float (List.assoc "delay" p) in
      let overhead =
        Lang.to_valued_option Lang.to_float (List.assoc "overhead" p)
      in
      let field, s = Lang.to_track (List.assoc "" p) in
      (field, new defer ~delay ~overhead ~field s))
