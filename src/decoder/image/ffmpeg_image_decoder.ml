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

module Scaler = Swscale.Make (Swscale.Frame) (Swscale.BigArray)

let log = Log.make ["decoder"; "ffmpeg"; "image"]

let image_file_extensions =
  Dtools.Conf.list
    ~p:(Ffmpeg_decoder.file_extensions#plug "images")
    "File extensions used for decoding images with ffmpeg"
    ~d:
      [
        "bmp";
        "cri";
        "dds";
        "dng";
        "dpx";
        "exr";
        "im1";
        "im24";
        "im32";
        "im8";
        "j2c";
        "j2k";
        "jls";
        "jp2";
        "jpc";
        "jpeg";
        "jpg";
        "jps";
        "ljpg";
        "mng";
        "mpg1-img";
        "mpg2-img";
        "mpg4-img";
        "mpo";
        "pam";
        "pbm";
        "pcd";
        "pct";
        "pcx";
        "pfm";
        "pgm";
        "pgmyuv";
        "pic";
        "pict";
        "pix";
        "png";
        "pnm";
        "pns";
        "ppm";
        "ptx";
        "ras";
        "raw";
        "rs";
        "sgi";
        "sun";
        "sunras";
        "svg";
        "svgz";
        "tga";
        "tif";
        "tiff";
        "webp";
        "xbm";
        "xface";
        "xpm";
        "xwd";
        "y";
        "yuv10";
      ]

let load_image fname =
  let container = Av.open_input fname in
  let _, stream, codec = Av.find_best_video_stream container in
  let pixel_format =
    match Avcodec.Video.get_pixel_format codec with
      | None -> failwith "Pixel format unknown!"
      | Some f -> f
  in
  let width = Avcodec.Video.get_width codec in
  let height = Avcodec.Video.get_height codec in
  let scaler =
    Scaler.create [] width height pixel_format width height
      (Ffmpeg_utils.liq_frame_pixel_format ())
  in
  match Av.read_input ~video_frame:[stream] container with
    | `Video_frame (_, frame) ->
        Some
          (Ffmpeg_utils.unpack_image ~width ~height
             (Scaler.convert scaler frame))
    | _ -> None

let () =
  Decoder.image_file_decoders#register "ffmpeg"
    ~sdoc:"Decode images using Ffmpeg." (fun filename ->
      let ext = Filename.extension filename in
      if List.exists (fun s -> ext = "." ^ s) image_file_extensions#get then
        load_image filename
      else None)
