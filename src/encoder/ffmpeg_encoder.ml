(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

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

(** FFMPEG encoder *)

open Ffmpeg_encoder_common

let () =
  Encoder.plug#register "FFMPEG" (function
    | Encoder.Ffmpeg m ->
        Some
          (fun _ ->
            let get_stream = mk_stream_store () in
            let mk_audio =
              match m.Ffmpeg_format.audio_codec with
                | Some `Copy ->
                    fun ~ffmpeg:_ ~options:_ ->
                      Ffmpeg_copy_encoder.mk_stream_copy
                        ~video_size:(fun _ -> None)
                        ~get_stream
                        ~get_data:(fun frame ->
                          Ffmpeg_copy_content.Audio.get_data
                            Frame.(frame.content.audio))
                | None | Some (`Internal (Some _)) | Some (`Raw (Some _)) ->
                    Ffmpeg_internal_encoder.mk_audio
                | Some (`Internal None) ->
                    failwith "%audio encoder expects a codec variable!"
                | Some (`Raw None) ->
                    failwith "%audio.raw encoder expects a codec variable!"
            in
            let mk_video =
              match m.Ffmpeg_format.video_codec with
                | Some `Copy ->
                    fun ~ffmpeg:_ ~options:_ ->
                      let get_data frame =
                        Ffmpeg_copy_content.Video.get_data
                          Frame.(frame.content.video)
                      in
                      let video_size frame =
                        let { Ffmpeg_content_base.params } = get_data frame in
                        Option.map
                          (fun params ->
                            ( Avcodec.Video.get_width params,
                              Avcodec.Video.get_height params ))
                          params
                      in
                      Ffmpeg_copy_encoder.mk_stream_copy ~video_size ~get_stream
                        ~get_data
                | None | Some (`Internal (Some _)) | Some (`Raw (Some _)) ->
                    Ffmpeg_internal_encoder.mk_video
                | Some (`Internal None) ->
                    failwith "%video encoder expects a codec variable!"
                | Some (`Raw None) ->
                    failwith "%video.raw encoder expects a codec variable!"
            in
            encoder ~mk_audio ~mk_video m)
    | _ -> None)
