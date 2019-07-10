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

open Lang_values
open Lang_encoders

let make params =
  let defaults =
    { Fdkaac_format.
        afterburner    = false;
        aot            = `Mpeg_4 `HE_AAC_v2;
        bandwidth      = `Auto;
        bitrate        = 64;
        bitrate_mode   = `Constant;
        channels       = Lazy.force Frame.audio_channels;
        samplerate     = Lazy.force Frame.audio_rate;
        sbr_mode       = false;
        transmux       = `Adts }
  in
  let valid_samplerates = [
    8000;  11025; 12000; 16000; 22050; 24000; 32000;
    44100; 48000; 64000; 88200; 96000 ]
  in
  let valid_vbr = [1;2;3;4;5] in
  let fdkaac =
    List.fold_left
      (fun f ->
        function
          | ("afterburner",{ term = Bool b; _}) ->
              { f with Fdkaac_format.afterburner = b }
          | ("aot",({ term = String s; _} as t)) ->
              let aot = try Fdkaac_format.aot_of_string s with
                | Not_found -> raise (Error (t,"invalid aot value"))
              in
              { f with Fdkaac_format.aot = aot }
          | ("vbr",({ term = Int i; _} as t)) ->
              if not (List.mem i valid_vbr) then
               begin
                let err =
                  Printf.sprintf "invalid vbr mode. Possible values: %s"
                  (String.concat ", "
                    (List.map string_of_int valid_vbr))
                in
                raise (Error (t,err));
               end;
              { f with Fdkaac_format.bitrate_mode = `Variable i }
          | ("bandwidth", { term = Int i; _ }) ->
              { f with Fdkaac_format.bandwidth = `Fixed i }
          | ("bandwidth", { term = String s; _ }) when String.lowercase_ascii s = "auto" ->
              { f with Fdkaac_format.bandwidth = `Auto }
          | ("bitrate",{ term = Int i; _}) ->
              { f with Fdkaac_format.bitrate = i }
          | ("channels",{ term = Int i; _}) ->
              { f with Fdkaac_format.channels = i }
          | ("samplerate",({ term = Int i; _} as t)) ->
              if not (List.mem i valid_samplerates) then
               begin
                let err =
                  Printf.sprintf "invalid samplerate value. Possible values: %s"
                  (String.concat ", "
                    (List.map string_of_int valid_samplerates))
                in
                raise (Error (t,err));
               end;
              { f with Fdkaac_format.samplerate = i }
          | ("sbr_mode",{ term = Bool b; _}) ->
              { f with Fdkaac_format.sbr_mode = b }
          | ("transmux",({ term = String s; _} as t)) ->
              let transmux = try Fdkaac_format.transmux_of_string s with
                | Not_found -> raise (Error (t,"invalid transmux value"))
              in
              { f with Fdkaac_format.transmux = transmux }
          | ("",{ term = Var s; _}) when String.lowercase_ascii s = "mono" ->
              { f with Fdkaac_format.channels = 1 }
          | ("",{ term = Var s; _}) when String.lowercase_ascii s = "stereo" ->
              { f with Fdkaac_format.channels = 2 }
          | (_,t) -> raise (generic_error t))
      defaults params
  in
  let aot = fdkaac.Fdkaac_format.aot in
    if aot = `Mpeg_4 `HE_AAC_v2 || aot = `Mpeg_2 `HE_AAC_v2 then
      if fdkaac.Fdkaac_format.channels <> 2 then
        failwith "HE-AAC v2 is only available with 2 channels.";
    Encoder.FdkAacEnc fdkaac
