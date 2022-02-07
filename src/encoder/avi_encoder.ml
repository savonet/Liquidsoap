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

open Mm

(** AVI encoder *)

open Avi_format

let encode_frame ~channels ~samplerate ~converter frame start len =
  let ratio = float samplerate /. float (Lazy.force Frame.audio_rate) in
  let audio =
    let astart = Frame.audio_of_main start in
    let alen = Frame.audio_of_main len in
    let pcm = AFrame.pcm frame in
    (* Resample if needed. *)
    let pcm, astart, alen =
      if ratio = 1. then (pcm, astart, alen)
      else (
        let pcm =
          Audio_converter.Samplerate.resample converter ratio
            (Audio.sub pcm astart alen)
        in
        (pcm, 0, Audio.length pcm))
    in
    let data = Bytes.create (2 * channels * alen) in
    Audio.S16LE.of_audio (Audio.sub pcm astart alen) data 0;
    Avi.audio_chunk (Bytes.unsafe_to_string data)
  in
  let video =
    let vbuf = VFrame.data frame in
    let vstart = Frame.video_of_main start in
    let vlen = Frame.video_of_main len in
    let data = Strings.Mutable.empty () in
    for i = vstart to vstart + vlen - 1 do
      let img = Video.Canvas.render vbuf i in
      let width = Image.YUV420.width img in
      let height = Image.YUV420.height img in
      let y, u, v = Image.YUV420.data img in
      let y = Image.Data.to_string y in
      let u = Image.Data.to_string u in
      let v = Image.Data.to_string v in
      let y_stride = Image.YUV420.y_stride img in
      let uv_stride = Image.YUV420.uv_stride img in
      if y_stride = width then Strings.Mutable.add data y
      else
        for j = 0 to height - 1 do
          Strings.Mutable.add_substring data y (j * y_stride) width
        done;
      if uv_stride = width / 2 then (
        Strings.Mutable.add data u;
        Strings.Mutable.add data v)
      else (
        for j = 0 to (height / 2) - 1 do
          Strings.Mutable.add_substring data u (j * uv_stride) (width / 2)
        done;
        for j = 0 to (height / 2) - 1 do
          Strings.Mutable.add_substring data v (j * uv_stride) (width / 2)
        done)
    done;
    Avi.video_chunk_strings data
  in
  Strings.add video audio

let encoder avi =
  let channels = avi.channels in
  let samplerate = Lazy.force avi.samplerate in
  let converter = Audio_converter.Samplerate.create channels in
  (* TODO: use duration *)
  let header = Avi.header ~channels ~samplerate () in
  let need_header = ref true in
  let encode frame start len =
    let ans = encode_frame ~channels ~samplerate ~converter frame start len in
    if !need_header then (
      need_header := false;
      Strings.dda header ans)
    else ans
  in
  let hls =
    {
      Encoder.init_encode = (fun f o l -> (None, encode f o l));
      split_encode = (fun f o l -> `Ok (Strings.empty, encode f o l));
      codec_attrs = (fun () -> None);
      bitrate = (fun () -> None);
      video_size = (fun () -> None);
    }
  in
  {
    Encoder.insert_metadata = (fun _ -> ());
    hls;
    encode;
    header = Strings.of_string header;
    stop = (fun () -> Strings.empty);
  }

let () =
  Encoder.plug#register "AVI" (function
    | Encoder.AVI avi -> Some (fun _ _ -> encoder avi)
    | _ -> None)
