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

(* See http://en.wikipedia.org/wiki/Comb_filter *)

class comb ~field (source : source) delay feedback =
  let past_len = Frame.audio_of_seconds delay in
  object (self)
    inherit operator ~name:"comb" [source] as super
    method stype = source#stype
    method remaining = source#remaining
    method seek = source#seek
    method seek_source = source
    method self_sync = source#self_sync
    method private _is_ready = source#is_ready
    method abort_track = source#abort_track
    val mutable past = Audio.make 0 0 0.

    method! private wake_up s =
      super#wake_up s;
      past <- Audio.make self#audio_channels past_len 0.

    val mutable past_pos = 0

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let b = Content.Audio.get_data (Frame.get buf field) in
      let position = AFrame.position buf in
      let feedback = feedback () in
      for i = offset to position - 1 do
        for c = 0 to Array.length b - 1 do
          let oldin = b.(c).(i) in
          b.(c).(i) <- b.(c).(i) +. (past.(c).(past_pos) *. feedback);
          past.(c).(past_pos) <- oldin
        done;
        past_pos <- (past_pos + 1) mod past_len
      done
  end

let _ =
  let frame_t = Format_type.audio () in
  Lang.add_track_operator ~base:Modules.track_audio "comb"
    [
      ("delay", Lang.float_t, Some (Lang.float 0.001), Some "Delay in seconds.");
      ( "feedback",
        Lang.getter_t Lang.float_t,
        Some (Lang.float (-6.)),
        Some "Feedback coefficient in dB." );
      ("", frame_t, None, None);
    ]
    ~return_t:frame_t ~category:`Audio ~descr:"Comb filter."
    (fun p ->
      let f v = List.assoc v p in
      let duration, feedback, (field, src) =
        ( Lang.to_float (f "delay"),
          Lang.to_float_getter (f "feedback"),
          Lang.to_track (f "") )
      in
      ( field,
        new comb ~field src duration (fun () -> Audio.lin_of_dB (feedback ()))
      ))
