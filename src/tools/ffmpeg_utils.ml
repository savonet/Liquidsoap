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

open Mm

let log = Log.make ["ffmpeg"]

let () =
  Printexc.register_printer (function
    | Avutil.Error `Encoder_not_found ->
        Some
          "The requested ffmpeg encoder was not found, please make sure that \
           ffmpeg was compiled with support for it"
    | _ -> None)

let conf_ffmpeg =
  Dtools.Conf.void ~p:(Configure.conf#plug "ffmpeg") "FFMPEG configuration"

let conf_log = Dtools.Conf.void ~p:(conf_ffmpeg#plug "log") "Log configuration"

let conf_verbosity =
  Dtools.Conf.string
    ~p:(conf_log#plug "verbosity")
    "Verbosity" ~d:"warning"
    ~comments:
      [
        "Set FFMPEG log level, one of: \"quiet\", \"panic\", \"fatal\"";
        "\"error\", \"warning\", \"info\", \"verbose\" or \"debug\"";
      ]

let conf_level = Dtools.Conf.int ~p:(conf_log#plug "level") "Level" ~d:3

let conf_scaling_algorithm =
  Dtools.Conf.string
    ~p:(conf_ffmpeg#plug "scaling_algorithm")
    "Scaling algorithm" ~d:"bicubic"
    ~comments:
      [
        "Set FFMPEG scaling algorithm. One of: \"fast_bilinear\",";
        "\"bilinear\" or \"bicubic\".";
      ]

let conf_alpha =
  Dtools.Conf.bool ~p:(conf_ffmpeg#plug "alpha") ~d:false
    "Import and export alpha layers when converting to and from ffmpeg frames."

let log_start_atom =
  Dtools.Init.make (fun () ->
      let verbosity =
        match conf_verbosity#get with
          | "quiet" -> `Quiet
          | "panic" -> `Panic
          | "fatal" -> `Fatal
          | "error" -> `Error
          | "warning" -> `Warning
          | "info" -> `Info
          | "verbose" -> `Verbose
          | "debug" -> `Debug
          | _ ->
              log#severe "Invalid value for \"ffmpeg.log.verbosity\"!";
              `Quiet
      in
      let level = conf_level#get in
      Avutil.Log.set_level verbosity;
      Avutil.Log.set_callback (fun s -> log#f level "%s" (String.trim s)))

let () = Lifecycle.before_start (fun () -> Dtools.Init.exec log_start_atom)

let best_pts frame =
  match Avutil.frame_pts frame with
    | Some pts -> Some pts
    | None -> Avutil.frame_best_effort_timestamp frame

module Fps = struct
  type filter = {
    time_base : Avutil.rational;
    input : [ `Video ] Avfilter.input;
    output : [ `Video ] Avfilter.output;
  }

  type t = [ `Filter of filter | `Pass_through of Avutil.rational ]

  let time_base = function
    | `Filter { time_base } -> time_base
    | `Pass_through time_base -> time_base

  let init ~width ~height ~pixel_format ~time_base ?pixel_aspect ?source_fps
      ~target_fps () =
    let config = Avfilter.init () in
    let _buffer =
      let args =
        [
          `Pair ("video_size", `String (Printf.sprintf "%dx%d" width height));
          `Pair ("pix_fmt", `Int (Avutil.Pixel_format.get_id pixel_format));
          `Pair ("time_base", `Rational time_base);
        ]
        @
        match pixel_aspect with
          | None -> []
          | Some p -> [`Pair ("pixel_aspect", `Rational p)]
      in
      let args =
        match source_fps with
          | None -> args
          | Some fps ->
              `Pair ("frame_rate", `Rational { Avutil.num = fps; den = 1 })
              :: args
      in
      Avfilter.attach ~name:"buffer" ~args Avfilter.buffer config
    in
    let fps =
      match
        List.find_opt (fun { Avfilter.name } -> name = "fps") Avfilter.filters
      with
        | Some fps -> fps
        | None -> failwith "Could not find fps ffmpeg filter!"
    in
    let fps =
      let args =
        [`Pair ("fps", `Rational { Avutil.num = target_fps; den = 1 })]
      in
      Avfilter.attach ~name:"fps" ~args fps config
    in
    let _buffersink =
      Avfilter.attach ~name:"buffersink" Avfilter.buffersink config
    in
    Avfilter.link
      (List.hd Avfilter.(_buffer.io.outputs.video))
      (List.hd Avfilter.(fps.io.inputs.video));
    Avfilter.link
      (List.hd Avfilter.(fps.io.outputs.video))
      (List.hd Avfilter.(_buffersink.io.inputs.video));
    let graph = Avfilter.launch config in
    let _, input = List.hd Avfilter.(graph.inputs.video) in
    let _, output = List.hd Avfilter.(graph.outputs.video) in
    let time_base = Avfilter.(time_base output.context) in
    { input; output; time_base }

  (* Source fps is not always known so it is optional here. *)
  let init ~width ~height ~pixel_format ~time_base ?pixel_aspect ?source_fps
      ~target_fps () =
    match source_fps with
      | Some f when f = target_fps -> `Pass_through time_base
      | _ ->
          `Filter
            (init ~width ~height ~pixel_format ~time_base ?pixel_aspect
               ?source_fps ~target_fps ())

  let convert converter frame cb =
    match converter with
      | `Pass_through _ -> cb frame
      | `Filter { input; output } ->
          Avutil.frame_set_pts frame (best_pts frame);
          input frame;
          let rec flush () =
            try
              cb (output.Avfilter.handler ());
              flush ()
            with Avutil.Error `Eagain -> ()
          in
          flush ()
end

let liq_main_ticks_time_base () =
  { Avutil.num = 1; den = Lazy.force Frame.main_rate }

let liq_audio_sample_time_base () =
  { Avutil.num = 1; den = Lazy.force Frame.audio_rate }

let liq_video_sample_time_base () =
  { Avutil.num = 1; den = Lazy.force Frame.video_rate }

let liq_frame_time_base () =
  { Avutil.num = Lazy.force Frame.size; den = Lazy.force Frame.main_rate }

let liq_frame_pixel_format () = if conf_alpha#get then `Yuva420p else `Yuv420p

let pack_image f =
  let y, u, v = Image.YUV420.data f in
  let sy = Image.YUV420.y_stride f in
  let s = Image.YUV420.uv_stride f in
  if conf_alpha#get then (
    Image.YUV420.ensure_alpha f;
    let a = Option.get (Image.YUV420.alpha f) in
    [| (y, sy); (u, s); (v, s); (a, s) |] )
  else [| (y, sy); (u, s); (v, s) |]

let unpack_image ~width ~height f =
  match (conf_alpha#get, f) with
    | true, [| (y, sy); (u, s); (v, _); (a, _) |] ->
        let img = Image.YUV420.make width height y sy u v s in
        Image.YUV420.set_alpha img (Some a);
        img
    | false, [| (y, sy); (u, s); (v, _) |] ->
        Image.YUV420.make width height y sy u v s
    | _ -> assert false

let convert_time_base ~src ~dst pts =
  let num = src.Avutil.num * dst.Avutil.den in
  let den = src.Avutil.den * dst.Avutil.num in
  Int64.div (Int64.mul pts (Int64.of_int num)) (Int64.of_int den)

exception
  Found of (Avcodec.Video.hardware_context option * Avutil.Pixel_format.t)

let mk_hardware_context ~hwaccel ~hwaccel_device ~opts ~target_pixel_format
    ~target_width ~target_height codec =
  let codec_name = Avcodec.name codec in
  let no_hardware_context = (None, target_pixel_format) in
  try
    if hwaccel = `None then raise (Found no_hardware_context);
    let hw_configs = Avcodec.hw_configs codec in
    let find hw_method cb =
      ignore
        (Option.map cb
           (List.find_opt
              (fun { Avcodec.methods; _ } -> List.mem hw_method methods)
              hw_configs))
    in
    find `Internal (fun _ ->
        (* Setting a hwaccel_device explicitly disables this method. *)
        if hwaccel_device = None && hwaccel <> `None then (
          log#info
            "Codec %s has internal hardware capabilities that should work \
             without specific settings."
            codec_name;
          raise (Found (None, target_pixel_format)) ));
    find `Hw_device_ctx (fun { Avcodec.device_type; _ } ->
        log#info
          "Codec %s has device context-based hardware capabilities. Enabling \
           it.."
          codec_name;
        let device_context =
          Avutil.HwContext.create_device_context ?device:hwaccel_device ~opts
            device_type
        in
        raise
          (Found (Some (`Device_context device_context), target_pixel_format)));
    find `Hw_frames_ctx (fun { Avcodec.device_type; pixel_format; _ } ->
        log#info
          "Codec %s has frame context-based hardware cabilities. Enabling it.."
          codec_name;
        let device_context =
          Avutil.HwContext.create_device_context ?device:hwaccel_device ~opts
            device_type
        in
        let frame_context =
          Avutil.HwContext.create_frame_context ~width:target_width
            ~height:target_height ~src_pixel_format:target_pixel_format
            ~dst_pixel_format:pixel_format device_context
        in
        raise (Found (Some (`Frame_context frame_context), pixel_format)));
    no_hardware_context
  with Found v -> v

module Duration = struct
  type 'a t = {
    get_ts : 'a -> Int64.t option;
    src : Avutil.rational;
    dst : Avutil.rational;
    mutable last_packet : 'a option;
    mutable packets : (int * 'a) list;
  }

  let init ~src ~get_ts =
    {
      get_ts;
      src;
      dst = liq_main_ticks_time_base ();
      last_packet = None;
      packets = [];
    }

  let push t packet =
    let { get_ts; last_packet; packets; src; dst } = t in
    t.last_packet <- Some packet;
    let last_ts =
      Option.join (Option.map (fun packet -> get_ts packet) last_packet)
    in
    let duration =
      match (last_ts, get_ts packet) with
        | None, Some _ -> 0
        | Some old_pts, Some pts ->
            let d = Int64.sub pts old_pts in
            Int64.to_int (convert_time_base ~src ~dst d)
        | _, None -> 0
    in
    let packets = packets in
    if duration > 0 then (
      t.packets <- [(0, packet)];
      Some (duration, packets) )
    else (
      t.packets <- packets @ [(0, packet)];
      None )

  let flush { packets } = packets
end

let find_pixel_format codec pixel_format =
  let formats = Avcodec.Video.get_supported_pixel_formats codec in
  if List.mem pixel_format formats then pixel_format
  else (
    match
      List.filter
        (fun f ->
          not (List.mem `Hwaccel Avutil.Pixel_format.((descriptor f).flags)))
        formats
    with
      | p :: _ -> p
      | [] ->
          failwith
            (Printf.sprintf "No suitable pixel format for codec %s!"
               (Avcodec.name codec)) )

let pixel_format codec = function
  | Some p -> Avutil.Pixel_format.of_string p
  | None -> find_pixel_format codec (liq_frame_pixel_format ())
