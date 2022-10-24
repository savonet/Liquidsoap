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

(** Decode ffmpeg packets. *)

open Avcodec

let log = Log.make ["ffmpeg"; "decoder"; "copy"]

exception Corrupt
exception Empty

let mk_decoder ~stream_idx ~stream_time_base ~lift_data ~put_data params =
  let duration_converter =
    Ffmpeg_utils.Duration.init ~src:stream_time_base ~get_ts:Packet.get_dts
  in
  fun ~buffer packet ->
    try
      let flags = Packet.get_flags packet in
      if List.mem `Corrupt flags then (
        log#important "Corrupted packet in stream!";
        raise Corrupt);
      let packets = Ffmpeg_utils.Duration.push duration_converter packet in
      if packets = None then raise Empty;
      let length, packets = Option.get packets in
      let data =
        List.map
          (fun (pos, packet) ->
            ( pos,
              {
                Ffmpeg_copy_content.packet;
                time_base = stream_time_base;
                stream_idx;
              } ))
          packets
      in
      let data = { Ffmpeg_content_base.params = Some params; data; length } in
      let data = lift_data data in
      put_data buffer.Decoder.generator data
    with Empty | Corrupt (* Might want to change that later. *) -> ()

let mk_audio_decoder ~stream_idx ~format container =
  let idx, stream, params = Av.find_best_audio_stream container in
  Ffmpeg_decoder_common.set_audio_stream_decoder stream;
  ignore
    (Content.merge format Ffmpeg_copy_content.(Audio.lift_params (Some params)));
  let stream_time_base = Av.get_time_base stream in
  let lift_data data = Ffmpeg_copy_content.Audio.lift_data data in
  ( idx,
    stream,
    mk_decoder ~stream_idx ~lift_data ~stream_time_base
      ~put_data:(fun g c -> Generator.put g Frame.Fields.audio c)
      params )

let mk_video_decoder ~stream_idx ~format container =
  let idx, stream, params = Av.find_best_video_stream container in
  Ffmpeg_decoder_common.set_video_stream_decoder stream;
  ignore
    (Content.merge format Ffmpeg_copy_content.(Video.lift_params (Some params)));
  let stream_time_base = Av.get_time_base stream in
  let lift_data data = Ffmpeg_copy_content.Video.lift_data data in
  ( idx,
    stream,
    mk_decoder ~stream_idx ~lift_data ~stream_time_base
      ~put_data:(fun g c -> Generator.put g Frame.Fields.video c)
      params )
