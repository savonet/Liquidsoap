let log = Log.make ["ffmpeg"]

let conf_ffmpeg =
  Dtools.Conf.void ~p:(Configure.conf#plug "ffmpeg") "FFMPEG configuration"

let conf_log = Dtools.Conf.void ~p:(conf_ffmpeg#plug "log") "Log configuration"

let conf_verbosity =
  Dtools.Conf.string
    ~p:(conf_log#plug "verbosity")
    "Verbosity" ~d:"quiet"
    ~comments:
      [
        "Set FFMPEG log level, one of: \"quiet\", \"panic\", \"fatal\"";
        "\"error\", \"warning\", \"info\", \"verbose\" or \"debug\"";
      ]

let conf_level = Dtools.Conf.int ~p:(conf_log#plug "level") "Level" ~d:5

let () =
  ignore
    (Dtools.Init.at_start (fun () ->
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
         Avutil.Log.set_callback (fun s -> log#f level "%s" (String.trim s))))

let fps_converter ~width ~height ~pixel_format ~time_base ~pixel_aspect
    ~target_fps cb =
  let config = Avfilter.init () in
  let _buffer =
    let args =
      [
        `Pair ("video_size", `String (Printf.sprintf "%dx%d" width height));
        `Pair ("pix_fmt", `String (Avutil.Pixel_format.to_string pixel_format));
        `Pair ("time_base", `Rational time_base);
        `Pair ("pixel_aspect", `Rational pixel_aspect);
      ]
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
    let args = [`Pair ("fps", `Int target_fps)] in
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
  fun frame ->
    input frame;
    let rec flush () =
      try
        cb (output.Avfilter.handler ());
        flush ()
      with Avutil.Error `Eagain -> ()
    in
    flush ()

(* Source fps is not always known so it is optional here. *)
let fps_converter ~width ~height ~pixel_format ~time_base ~pixel_aspect ?fps
    ~target_fps cb =
  match fps with
    | Some f when f = target_fps -> fun frame -> cb frame
    | _ ->
        fps_converter ~width ~height ~pixel_format ~time_base ~pixel_aspect
          ~target_fps cb

let pts ~mode ~time_base frame =
  let pts = Avutil.frame_pts frame in
  let { Avutil.num; den } = time_base in
  let liq_time_base =
    match mode with `Audio -> AFrame.size () | `Video -> VFrame.size ()
  in
  Int64.div
    (Int64.mul pts (Int64.of_int den))
    (Int64.of_int (num * liq_time_base))
