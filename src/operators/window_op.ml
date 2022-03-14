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

open Source

type mode = RMS | Peak

class window ~kind mode duration source =
  object (self)
    inherit
      operator
        kind [source]
        ~name:(match mode with RMS -> "rms" | Peak -> "peak") as super

    method stype = source#stype
    method is_ready = source#is_ready
    method remaining = source#remaining
    method seek = source#seek
    method abort_track = source#abort_track
    method self_sync = source#self_sync

    (** Accumulator (e.g. sum of squares). *)
    val mutable acc = [||]

    (** Duration of the accumulated data (in samples). *)
    val mutable acc_dur = 0

    (** Last computed value (rms or peak). *)
    val mutable value = [||]

    method wake_up a =
      super#wake_up a;
      let channels = self#audio_channels in
      acc <- Array.make channels 0.;
      value <- Array.make channels 0.

    val m = Mutex.create ()
    method value = Tutils.mutexify m (fun () -> value) ()

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let duration = duration () in
      if duration > 0. then (
        let duration = Frame.audio_of_seconds duration in
        let position = AFrame.position buf in
        let buf = AFrame.pcm buf in
        for i = offset to position - 1 do
          for c = 0 to self#audio_channels - 1 do
            let x = buf.(c).(i) in
            match mode with
              | RMS -> acc.(c) <- acc.(c) +. (x *. x)
              | Peak -> acc.(c) <- max acc.(c) (abs_float x)
          done;
          acc_dur <- acc_dur + 1;
          if acc_dur >= duration then (
            let dur = float acc_dur in
            let value' =
              Array.init self#audio_channels (fun i ->
                  match mode with
                    | RMS ->
                        let v = sqrt (acc.(i) /. dur) in
                        acc.(i) <- 0.;
                        v
                    | Peak ->
                        let v = acc.(i) in
                        acc.(i) <- 0.;
                        v)
            in
            acc_dur <- 0;
            Tutils.mutexify m (fun () -> value <- value') ())
        done)
  end

let declare mode suffix kind fun_ret_t f_ans =
  let name = match mode with RMS -> "rms" | Peak -> "peak" in
  let doc = match mode with RMS -> "RMS volume" | Peak -> "peak volume" in
  let return_t = Lang.kind_type_of_kind_format kind in
  Lang.add_operator (name ^ suffix) ~category:`Audio
    ~meth:
      [
        ( name,
          ([], Lang.fun_t [] fun_ret_t),
          "Current value for the " ^ doc ^ ".",
          fun s -> Lang.val_fun [] (fun _ -> f_ans s#value) );
      ]
    ~return_t
    ~descr:
      ("Get current " ^ doc
     ^ " of the source. Returns the source with a method `" ^ name
     ^ "` to compute the current " ^ doc ^ " of the source, with `0.0 <= " ^ doc
     ^ " <= 1.0`.")
    [
      ( "duration",
        Lang.getter_t Lang.float_t,
        Some (Lang.float 0.5),
        Some
          "Duration of the window (in seconds). A value <= 0, means that \
           computation should not be performed." );
      ("", Lang.source_t return_t, None, None);
    ]
    (fun p ->
      let f v = List.assoc v p in
      let src = Lang.to_source (f "") in
      let duration = Lang.to_float_getter (f "duration") in
      let kind = Source.Kind.of_kind kind in
      new window ~kind mode duration src)

let () =
  let mean value =
    let x = Array.fold_left ( +. ) 0. value in
    let x = x /. float (Array.length value) in
    Lang.float x
  in
  let stereo value =
    Lang.product (Lang.float value.(0)) (Lang.float value.(1))
  in
  let kind = { Frame.audio = Frame.audio_stereo; video = `Any; midi = `Any } in
  declare RMS "" Lang.audio_pcm Lang.float_t mean;
  declare RMS ".stereo" kind (Lang.product_t Lang.float_t Lang.float_t) stereo;
  declare Peak "" Lang.audio_pcm Lang.float_t mean;
  declare Peak ".stereo" kind (Lang.product_t Lang.float_t Lang.float_t) stereo
