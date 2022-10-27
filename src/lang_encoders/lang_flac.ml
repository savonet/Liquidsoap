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

let kind_of_encoder p = Encoder.audio_kind (Lang_encoder.channels_of_params p)
let accepted_bits_per_sample = [8; 16; 24; 32]

let flac_gen params =
  let defaults =
    {
      Flac_format.fill = None;
      (* We use a hardcoded value in order not to force the evaluation of the
           number of channels too early, see #933. *)
      channels = 2;
      samplerate = Frame.audio_rate;
      bits_per_sample = 16;
      compression = 5;
    }
  in
  List.fold_left
    (fun f -> function
      | "channels", `Value { value = Ground (Int i); _ } ->
          { f with Flac_format.channels = i }
      | "samplerate", `Value { value = Ground (Int i); _ } ->
          { f with Flac_format.samplerate = Lazy.from_val i }
      | "compression", `Value { value = Ground (Int i); pos } ->
          if i < 0 || i > 8 then
            Lang_encoder.raise_error ~pos "invalid compression value";
          { f with Flac_format.compression = i }
      | "bits_per_sample", `Value { value = Ground (Int i); pos } ->
          if not (List.mem i accepted_bits_per_sample) then
            Lang_encoder.raise_error ~pos "invalid bits_per_sample value";
          { f with Flac_format.bits_per_sample = i }
      | "bytes_per_page", `Value { value = Ground (Int i); _ } ->
          { f with Flac_format.fill = Some i }
      | "", `Value { value = Ground (String s); _ }
        when String.lowercase_ascii s = "mono" ->
          { f with Flac_format.channels = 1 }
      | "", `Value { value = Ground (String s); _ }
        when String.lowercase_ascii s = "stereo" ->
          { f with Flac_format.channels = 2 }
      | t -> Lang_encoder.raise_generic_error t)
    defaults params

let make_ogg params = Ogg_format.Flac (flac_gen params)
let make params = Encoder.Flac (flac_gen params)
let () = Lang_encoder.register "flac" kind_of_encoder make
