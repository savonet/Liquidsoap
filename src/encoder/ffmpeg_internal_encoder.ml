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

(** FFMPEG internal encoder *)

module InternalResampler =
  Swresample.Make (Swresample.PlanarFloatArray) (Swresample.Frame)

module RawResampler = Swresample.Make (Swresample.Frame) (Swresample.Frame)
module InternalScaler = Swscale.Make (Swscale.BigArray) (Swscale.Frame)
module RawScaler = Swscale.Make (Swscale.Frame) (Swscale.Frame)

let log = Log.make ["ffmpeg"; "encoder"; "internal"]

(* mk_stream is used for the copy encoder, where stream creation has to be
   delayed until the first packet is passed. This is not needed here. *)
let mk_stream _ = ()

let get_channel_layout channels =
  try Avutil.Channel_layout.get_default channels
  with Not_found ->
    failwith
      (Printf.sprintf
         "%%ffmpeg encoder: could not find a default channel configuration for \
          %d channels.."
         channels)

let can_split stream =
  let params = Av.get_codec_params stream in
  match Avcodec.descriptor params with
    | None -> fun () -> true
    | Some { Avcodec.properties } when List.mem `Intra_only properties ->
        fun () -> true
    | _ -> fun () -> Av.was_keyframe stream

(* This function optionally splits frames into [frame_size]
   and also adds PTS based on targeted [time_base], [sample_rate]
   and number of channel. *)
let write_audio_frame ~time_base ~sample_rate ~channel_layout ~sample_format
    ~frame_size write_frame =
  let src_time_base = { Avutil.num = 1; den = sample_rate } in
  let convert_pts =
    Ffmpeg_utils.convert_time_base ~src:src_time_base ~dst:time_base
  in

  let add_frame_pts () =
    let nb_samples = ref 0L in
    fun frame ->
      let frame_pts = convert_pts !nb_samples in
      nb_samples :=
        Int64.add !nb_samples
          (Int64.of_int (Avutil.Audio.frame_nb_samples frame));
      Avutil.Frame.set_pts frame (Some frame_pts)
  in

  let add_final_frame_pts = add_frame_pts () in
  let write_frame frame =
    add_final_frame_pts frame;
    write_frame frame
  in

  match frame_size with
    | None -> write_frame
    | Some out_frame_size ->
        let in_params =
          { Avfilter.Utils.sample_rate; channel_layout; sample_format }
        in
        let converter =
          Avfilter.Utils.init_audio_converter ~in_params ~in_time_base:time_base
            ~out_frame_size ()
        in
        let add_filter_frame_pts = add_frame_pts () in
        fun frame ->
          add_filter_frame_pts frame;
          Avfilter.Utils.convert_audio converter write_frame frame

let mk_audio ~ffmpeg ~options output =
  let codec =
    match ffmpeg.Ffmpeg_format.audio_codec with
      | Some (`Raw (Some codec)) | Some (`Internal (Some codec)) -> (
          try Avcodec.Audio.find_encoder_by_name codec
          with e ->
            log#severe "Cannot find encoder %s: %s." codec
              (Printexc.to_string e);
            raise e)
      | _ -> assert false
  in

  let target_samplerate = Lazy.force ffmpeg.Ffmpeg_format.samplerate in
  let target_liq_audio_sample_time_base =
    { Avutil.num = 1; den = target_samplerate }
  in
  let target_channels = ffmpeg.Ffmpeg_format.channels in
  let target_channel_layout = get_channel_layout target_channels in
  let target_sample_format =
    match ffmpeg.Ffmpeg_format.sample_format with
      | Some format -> Avutil.Sample_format.find format
      | None -> `Dbl
  in
  let target_sample_format =
    Avcodec.Audio.find_best_sample_format codec target_sample_format
  in

  let opts = Hashtbl.create 10 in
  Hashtbl.iter (Hashtbl.add opts) ffmpeg.Ffmpeg_format.audio_opts;
  Hashtbl.iter (Hashtbl.add opts) options;

  let internal_converter () =
    let src_samplerate = Lazy.force Frame.audio_rate in
    (* The typing system ensures that this is the number of channels in the frame. *)
    let src_channels = ffmpeg.Ffmpeg_format.channels in
    let src_channel_layout = get_channel_layout src_channels in

    let resampler =
      InternalResampler.create ~out_sample_format:target_sample_format
        src_channel_layout src_samplerate target_channel_layout
        target_samplerate
    in
    fun frame start len ->
      let astart = Frame.audio_of_main start in
      let alen = Frame.audio_of_main len in
      [
        InternalResampler.convert ~length:alen ~offset:astart resampler
          (AFrame.pcm frame);
      ]
  in

  let raw_converter =
    let resampler = ref None in
    let resample frame =
      let src_samplerate = Avutil.Audio.frame_get_sample_rate frame in
      let resampler =
        match !resampler with
          | Some f -> f
          | None ->
              let src_channel_layout =
                Avutil.Audio.frame_get_channel_layout frame
              in
              let src_sample_format =
                Avutil.Audio.frame_get_sample_format frame
              in
              let f =
                if
                  src_samplerate <> target_samplerate
                  || src_channel_layout <> target_channel_layout
                  || src_sample_format <> target_sample_format
                then (
                  let fn =
                    RawResampler.create ~in_sample_format:src_sample_format
                      ~out_sample_format:target_sample_format src_channel_layout
                      src_samplerate target_channel_layout target_samplerate
                  in
                  RawResampler.convert fn)
                else fun f -> f
              in
              resampler := Some f;
              f
      in
      resampler frame
    in
    fun frame start len ->
      let frames =
        Ffmpeg_raw_content.Audio.(get_data Frame.(frame.content.audio))
          .Ffmpeg_content_base.data
      in
      let frames =
        List.filter (fun (pos, _) -> start <= pos && pos < start + len) frames
      in
      List.map (fun (_, { Ffmpeg_raw_content.frame }) -> resample frame) frames
  in

  let converter =
    match ffmpeg.Ffmpeg_format.audio_codec with
      | Some (`Internal _) -> internal_converter ()
      | Some (`Raw _) -> raw_converter
      | _ -> assert false
  in

  let stream =
    try
      Av.new_audio_stream ~sample_rate:target_samplerate
        ~time_base:target_liq_audio_sample_time_base
        ~channel_layout:target_channel_layout
        ~sample_format:target_sample_format ~opts ~codec output
    with e ->
      log#severe
        "Cannot create audio stream (samplerate: %d, time_base: %s, channel \
         layout: %s, sample format: %s, options: %s): %s."
        target_samplerate
        (Avutil.string_of_rational target_liq_audio_sample_time_base)
        (Avutil.Channel_layout.get_description target_channel_layout)
        (Option.value ~default:""
           (Avutil.Sample_format.get_name target_sample_format))
        (Avutil.string_of_opts opts)
        (Printexc.to_string e);
      raise e
  in

  let codec_attr () = Av.codec_attr stream in

  let bitrate () = Av.bitrate stream in

  let video_size () = None in

  let audio_opts = Hashtbl.copy ffmpeg.Ffmpeg_format.audio_opts in

  Hashtbl.filter_map_inplace
    (fun l v -> if Hashtbl.mem opts l then Some v else None)
    audio_opts;

  if Hashtbl.length audio_opts > 0 then
    failwith
      (Printf.sprintf "Unrecognized options: %s"
         (Ffmpeg_format.string_of_options audio_opts));

  Hashtbl.filter_map_inplace
    (fun l v -> if Hashtbl.mem opts l then Some v else None)
    options;

  let frame_size =
    if List.mem `Variable_frame_size (Avcodec.capabilities codec) then None
    else Some (Av.get_frame_size stream)
  in

  let write_frame =
    try
      write_audio_frame ~time_base:(Av.get_time_base stream)
        ~sample_rate:target_samplerate ~channel_layout:target_channel_layout
        ~sample_format:target_sample_format ~frame_size (Av.write_frame stream)
    with e ->
      log#severe "Error writing audio frame: %s." (Printexc.to_string e);
      raise e
  in

  let encode frame start len =
    List.iter write_frame (converter frame start len)
  in

  {
    Ffmpeg_encoder_common.mk_stream;
    can_split = can_split stream;
    encode;
    codec_attr;
    bitrate;
    video_size;
  }

let mk_video ~ffmpeg ~options output =
  let codec =
    match ffmpeg.Ffmpeg_format.video_codec with
      | Some (`Raw (Some codec)) | Some (`Internal (Some codec)) -> (
          try Avcodec.Video.find_encoder_by_name codec
          with e ->
            log#severe "Cannot find encoder %s: %s." codec
              (Printexc.to_string e);
            raise e)
      | _ -> assert false
  in
  let pixel_aspect = { Avutil.num = 1; den = 1 } in

  let target_fps = Lazy.force ffmpeg.Ffmpeg_format.framerate in
  let target_video_frame_time_base = { Avutil.num = 1; den = target_fps } in
  let target_width = Lazy.force ffmpeg.Ffmpeg_format.width in
  let target_height = Lazy.force ffmpeg.Ffmpeg_format.height in
  let target_pixel_format =
    Ffmpeg_utils.pixel_format codec ffmpeg.Ffmpeg_format.pixel_format
  in

  let flag =
    match Ffmpeg_utils.conf_scaling_algorithm#get with
      | "fast_bilinear" -> Swscale.Fast_bilinear
      | "bilinear" -> Swscale.Bilinear
      | "bicubic" -> Swscale.Bicubic
      | _ -> failwith "Invalid value set for ffmpeg scaling algorithm!"
  in

  let opts = Hashtbl.create 10 in
  Hashtbl.iter (Hashtbl.add opts) ffmpeg.Ffmpeg_format.video_opts;
  Hashtbl.iter (Hashtbl.add opts) options;

  let hwaccel = ffmpeg.Ffmpeg_format.hwaccel in
  let hwaccel_device = ffmpeg.Ffmpeg_format.hwaccel_device in

  let hardware_context, target_pixel_format =
    Ffmpeg_utils.mk_hardware_context ~hwaccel ~hwaccel_device ~opts
      ~target_pixel_format ~target_width ~target_height codec
  in

  let stream =
    Av.new_video_stream ~time_base:target_video_frame_time_base
      ~pixel_format:target_pixel_format ?hardware_context
      ~frame_rate:{ Avutil.num = target_fps; den = 1 }
      ~width:target_width ~height:target_height ~opts ~codec output
  in

  let codec_attr () = Av.codec_attr stream in

  let bitrate () = Av.bitrate stream in

  let video_size () =
    let p = Av.get_codec_params stream in
    Some (Avcodec.Video.get_width p, Avcodec.Video.get_height p)
  in

  let video_opts = Hashtbl.copy ffmpeg.Ffmpeg_format.video_opts in
  Hashtbl.filter_map_inplace
    (fun l v -> if Hashtbl.mem opts l then Some v else None)
    video_opts;

  if Hashtbl.length video_opts > 0 then
    failwith
      (Printf.sprintf "Unrecognized options: %s"
         (Ffmpeg_format.string_of_options video_opts));

  Hashtbl.filter_map_inplace
    (fun l v -> if Hashtbl.mem opts l then Some v else None)
    options;

  let converter = ref None in

  let mk_converter ~pixel_format ~time_base ~stream_idx () =
    let c =
      Ffmpeg_avfilter_utils.Fps.init ~width:target_width ~height:target_height
        ~pixel_format ~time_base ~pixel_aspect ~target_fps ()
    in
    converter := Some (pixel_format, time_base, stream_idx, c);
    c
  in

  let get_converter ~pixel_format ~time_base ~stream_idx () =
    match !converter with
      | None -> mk_converter ~stream_idx ~pixel_format ~time_base ()
      | Some (p, t, i, _) when (p, t, i) <> (pixel_format, time_base, stream_idx)
        ->
          log#important "Frame format change detected!";
          mk_converter ~stream_idx ~pixel_format ~time_base ()
      | Some (_, _, _, c) -> c
  in

  let stream_time_base = Av.get_time_base stream in

  let fps_converter ~stream_idx ~time_base frame =
    let converter =
      get_converter ~time_base ~stream_idx
        ~pixel_format:(Avutil.Video.frame_get_pixel_format frame)
        ()
    in
    let time_base = Ffmpeg_avfilter_utils.Fps.time_base converter in
    Ffmpeg_avfilter_utils.Fps.convert converter frame (fun frame ->
        let frame_pts =
          Option.map
            (fun pts ->
              Ffmpeg_utils.convert_time_base ~src:time_base
                ~dst:stream_time_base pts)
            (Ffmpeg_utils.best_pts frame)
        in
        Avutil.Frame.set_pts frame frame_pts;
        Av.write_frame stream frame)
  in

  let internal_converter cb =
    let src_width = Lazy.force Frame.video_width in
    let src_height = Lazy.force Frame.video_height in
    let scaler =
      InternalScaler.create [flag] src_width src_height
        (Ffmpeg_utils.liq_frame_pixel_format ())
        target_width target_height target_pixel_format
    in
    let nb_frames = ref 0L in
    let time_base = Ffmpeg_utils.liq_video_sample_time_base () in
    let stream_idx = 1L in
    fun frame start len ->
      let vstart = Frame.video_of_main start in
      let vstop = Frame.video_of_main (start + len) in
      let vbuf = VFrame.yuva420p frame in
      for i = vstart to vstop - 1 do
        let f = Video.get vbuf i in
        let vdata = Ffmpeg_utils.pack_image f in
        let frame = InternalScaler.convert scaler vdata in
        Avutil.Frame.set_pts frame (Some !nb_frames);
        nb_frames := Int64.succ !nb_frames;
        cb ~stream_idx ~time_base frame
      done
  in

  let raw_converter cb =
    let scaler = ref None in
    let scale frame =
      let scaler =
        match !scaler with
          | Some f -> f
          | None ->
              let src_width = Avutil.Video.frame_get_width frame in
              let src_height = Avutil.Video.frame_get_height frame in
              let src_pixel_format =
                Avutil.Video.frame_get_pixel_format frame
              in
              let f =
                if src_width <> target_width || src_height <> target_height then (
                  let scaler =
                    RawScaler.create [flag] src_width src_height
                      src_pixel_format target_width target_height
                      src_pixel_format
                  in
                  fun frame ->
                    let scaled = RawScaler.convert scaler frame in
                    Avutil.Frame.set_pts scaled (Ffmpeg_utils.best_pts frame);
                    scaled)
                else fun f -> f
              in
              scaler := Some f;
              f
      in
      scaler frame
    in
    fun frame start len ->
      let stop = start + len in
      let { Ffmpeg_raw_content.VideoSpecs.data } =
        Ffmpeg_raw_content.Video.get_data Frame.(frame.content.video)
      in
      List.iter
        (fun (pos, { Ffmpeg_raw_content.time_base; frame; stream_idx }) ->
          if start <= pos && pos < stop then
            cb ~stream_idx ~time_base (scale frame))
        data
  in

  let converter =
    match ffmpeg.Ffmpeg_format.video_codec with
      | Some (`Internal _) -> internal_converter
      | Some (`Raw _) -> raw_converter
      | _ -> assert false
  in

  let encode = converter fps_converter in

  {
    Ffmpeg_encoder_common.mk_stream;
    can_split = can_split stream;
    encode;
    codec_attr;
    bitrate;
    video_size;
  }
