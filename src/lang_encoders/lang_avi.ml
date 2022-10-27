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

open Value
open Ground

let make params =
  let defaults =
    {
      (* We use a hardcoded value in order not to force the evaluation of the
         number of channels too early, see #933. *)
      Avi_format.channels = 2;
      samplerate = Frame.audio_rate;
      width = Frame.video_width;
      height = Frame.video_height;
    }
  in
  let avi =
    List.fold_left
      (fun f -> function
        | "channels", `Value { value = Ground (Int c); _ } ->
            { f with Avi_format.channels = c }
        | "samplerate", `Value { value = Ground (Int i); _ } ->
            { f with Avi_format.samplerate = Lazy.from_val i }
        | "width", `Value { value = Ground (Int i); _ } ->
            { f with Avi_format.width = Lazy.from_val i }
        | "height", `Value { value = Ground (Int i); _ } ->
            { f with Avi_format.height = Lazy.from_val i }
        | t -> Lang_encoder.raise_generic_error t)
      defaults params
  in
  Encoder.AVI avi

let kind_of_encoder p =
  Encoder.audio_video_kind (Lang_encoder.channels_of_params p)

let () = Lang_encoder.register "avi" kind_of_encoder make
