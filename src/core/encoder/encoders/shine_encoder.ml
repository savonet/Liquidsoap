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

(** Fixed-point MP3 encoder *)

open Shine_format

let create_encoder ~samplerate ~bitrate ~channels =
  Shine.create { Shine.channels; samplerate; bitrate }

let encoder ~pos:_ shine =
  let channels = shine.channels in
  let samplerate = Lazy.force shine.samplerate in
  let enc = create_encoder ~samplerate ~bitrate:shine.bitrate ~channels in
  let samplerate_converter = Audio_converter.Samplerate.create channels in
  let src_freq = float (Frame.audio_of_seconds 1.) in
  let dst_freq = float samplerate in
  (* Shine accepts data of a fixed length.. *)
  let samples = Frame.main_of_audio (Shine.samples_per_pass enc) in
  let buf =
    Generator.create
      (Frame.Fields.make ~audio:(Content.Audio.format_of_channels channels) ())
  in
  let encoded = Strings.Mutable.empty () in
  let encode frame start len =
    let b = AFrame.pcm frame in
    let start = Frame.audio_of_main start in
    let len = Frame.audio_of_main len in
    let b, start, len =
      Audio_converter.Samplerate.resample samplerate_converter
        (dst_freq /. src_freq) b start len
    in
    let start = Frame.main_of_audio start in
    let len = Frame.main_of_audio len in
    Generator.put buf Frame.Fields.audio
      (Content.sub (Content.Audio.lift_data b) start len);
    while Generator.length buf > samples do
      let pcm =
        Content.Audio.get_data
          (Frame.Fields.find Frame.Fields.audio
             (Generator.get ~length:samples buf))
      in
      Strings.Mutable.add encoded (Shine.encode_buffer enc pcm)
    done;
    Strings.Mutable.flush encoded
  in
  let stop () = Strings.of_string (Shine.flush enc) in
  {
    Encoder.insert_metadata = (fun _ -> ());
    header = (fun () -> Strings.empty);
    hls = Encoder.dummy_hls encode;
    encode;
    stop;
  }

let () =
  Plug.register Encoder.plug "shine" ~doc:"SHINE fixed-point mp3 encoder."
    (function
    | Encoder.Shine m -> Some (fun ~pos _ _ -> encoder ~pos m)
    | _ -> None)
