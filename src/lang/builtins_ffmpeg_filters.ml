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

let () =
  Lang.add_module "ffmpeg.filter";
  Lang.add_module "ffmpeg.filter.audio";
  Lang.add_module "ffmpeg.filter.video"

let log = Log.make ["ffmpeg"; "filter"]

type 'a input = 'a Avfilter.input
type 'a output = 'a Avfilter.output
type 'a setter = 'a -> unit
type 'a entries = (string, 'a setter) Hashtbl.t
type inputs = ([ `Audio ] input entries, [ `Video ] input entries) Avfilter.av

type outputs =
  ([ `Audio ] output entries, [ `Video ] output entries) Avfilter.av

type graph = {
  mutable config : Avfilter.config option;
  input_inits : (unit -> bool) Queue.t;
  init : unit Lazy.t Queue.t;
  entries : (inputs, outputs) Avfilter.io;
  clocks : Source.clock_variable Queue.t;
}

let init_graph graph =
  if Queue.fold (fun b v -> b && v ()) true graph.input_inits then
    Queue.iter Lazy.force graph.init

let initiated graph =
  Queue.fold (fun cur q -> cur && Lazy.is_val q) true graph.init

module Graph = Lang.MkAbstract (struct
  type content = graph

  let name = "ffmpeg.filter.graph"
  let descr _ = name
  let to_json ~compact:_ ~json5:_ v = Printf.sprintf "%S" (descr v)
  let compare = Stdlib.compare
end)

module Audio = Lang.MkAbstract (struct
  type content =
    [ `Input of ([ `Attached ], [ `Audio ], [ `Input ]) Avfilter.pad
    | `Output of ([ `Attached ], [ `Audio ], [ `Output ]) Avfilter.pad Lazy.t
    ]

  let name = "ffmpeg.filter.audio"
  let descr _ = name
  let to_json ~compact:_ ~json5:_ v = Printf.sprintf "%S" (descr v)
  let compare = Stdlib.compare
end)

module Video = Lang.MkAbstract (struct
  type content =
    [ `Input of ([ `Attached ], [ `Video ], [ `Input ]) Avfilter.pad
    | `Output of ([ `Attached ], [ `Video ], [ `Output ]) Avfilter.pad Lazy.t
    ]

  let name = "ffmpeg.filter.video"
  let descr _ = name
  let to_json ~compact:_ ~json5:_ v = Printf.sprintf "%S" (descr v)
  let compare = Stdlib.compare
end)

let uniq_name =
  let names = Hashtbl.create 10 in
  let name_idx name =
    match Hashtbl.find_opt names name with
      | Some x ->
          Hashtbl.replace names name (x + 1);
          x
      | None ->
          Hashtbl.add names name 1;
          0
  in
  fun name -> Printf.sprintf "%s_%d" name (name_idx name)

exception No_value_for_option

let mk_options { Avfilter.options } =
  Avutil.Options.(
    let mk_opt ~t ~to_string ~from_value name help { default; min; max; values }
        =
      let desc =
        let string_of_value (name, value) =
          Printf.sprintf "%s (%s)" (to_string value) name
        in
        let string_of_values values =
          String.concat ", " (List.map string_of_value values)
        in
        match (help, default, values) with
          | Some help, None, [] -> Some help
          | Some help, _, _ ->
              let values =
                if values = [] then None
                else
                  Some
                    (Printf.sprintf "possible values: %s"
                       (string_of_values values))
              in
              let default =
                Option.map
                  (fun default ->
                    Printf.sprintf "default: %s" (to_string default))
                  default
              in
              let l =
                List.fold_left
                  (fun l -> function Some v -> v :: l | None -> l)
                  [] [values; default]
              in
              Some (Printf.sprintf "%s. (%s)" help (String.concat ", " l))
          | None, None, _ :: _ ->
              Some
                (Printf.sprintf "Possible values: %s" (string_of_values values))
          | None, Some v, [] ->
              Some (Printf.sprintf "Default: %s" (to_string v))
          | None, Some v, _ :: _ ->
              Some
                (Printf.sprintf "Default: %s, possible values: %s" (to_string v)
                   (string_of_values values))
          | None, None, [] -> None
      in
      let opt = (name, Lang.nullable_t t, Some Lang.null, desc) in
      let getter p l =
        try
          let v = List.assoc name p in
          let v =
            match Lang.to_option v with
              | None -> raise No_value_for_option
              | Some v -> v
          in
          let x =
            try from_value v
            with _ -> raise (Error.Invalid_value (v, "Invalid value"))
          in
          (match min with
            | Some m when x < m ->
                raise
                  (Error.Invalid_value
                     ( v,
                       Printf.sprintf "%s must be more than %s" name
                         (to_string m) ))
            | _ -> ());
          (match max with
            | Some m when m < x ->
                raise
                  (Error.Invalid_value
                     ( v,
                       Printf.sprintf "%s must be less than %s" name
                         (to_string m) ))
            | _ -> ());
          (match values with
            | _ :: _ when List.find_opt (fun (_, v) -> v = x) values = None ->
                raise
                  (Error.Invalid_value
                     ( v,
                       Printf.sprintf "%s should be one of: %s" name
                         (String.concat ", "
                            (List.map (fun (_, v) -> to_string v) values)) ))
            | _ -> ());
          let x =
            match default with
              | Some v
                when to_string v = Int64.to_string Int64.max_int
                     && to_string x = string_of_int max_int ->
                  `Int64 Int64.max_int
              | Some v
                when to_string v = Int64.to_string Int64.min_int
                     && to_string x = string_of_int min_int ->
                  `Int64 Int64.min_int
              | _ -> `String (to_string x)
          in
          `Pair (name, x) :: l
        with No_value_for_option -> l
      in
      (opt, getter)
    in
    let mk_opt (p, getter) { name; help; spec } =
      let mk_opt ~t ~to_string ~from_value spec =
        let opt, get = mk_opt ~t ~to_string ~from_value name help spec in
        let getter p l = get p (getter p l) in
        (opt :: p, getter)
      in
      match spec with
        | `Int s ->
            mk_opt ~t:Lang.int_t ~to_string:string_of_int
              ~from_value:Lang.to_int s
        | `Flags s | `Int64 s | `UInt64 s | `Duration s ->
            mk_opt ~t:Lang.int_t ~to_string:Int64.to_string
              ~from_value:(fun v -> Int64.of_int (Lang.to_int v))
              s
        | `Float s | `Double s ->
            mk_opt ~t:Lang.float_t ~to_string:string_of_float
              ~from_value:Lang.to_float s
        | `Rational s ->
            let to_string { Avutil.num; den } =
              Printf.sprintf "%i/%i" num den
            in
            let from_value v =
              let x = Lang.to_string v in
              match String.split_on_char '/' x with
                | [num; den] ->
                    { Avutil.num = int_of_string num; den = int_of_string den }
                | _ -> assert false
            in
            mk_opt ~t:Lang.string_t ~to_string ~from_value s
        | `Bool s ->
            mk_opt ~t:Lang.bool_t ~to_string:string_of_bool
              ~from_value:Lang.to_bool s
        | `String s
        | `Binary s
        | `Dict s
        | `Image_size s
        | `Video_rate s
        | `Color s ->
            mk_opt ~t:Lang.string_t
              ~to_string:(fun x -> x)
              ~from_value:Lang.to_string s
        | `Pixel_fmt s ->
            mk_opt ~t:Lang.string_t
              ~to_string:(fun p ->
                match Avutil.Pixel_format.to_string p with
                  | None -> "none"
                  | Some p -> p)
              ~from_value:(fun v ->
                Avutil.Pixel_format.of_string (Lang.to_string v))
              s
        | `Sample_fmt s ->
            mk_opt ~t:Lang.string_t
              ~to_string:(fun p ->
                match Avutil.Sample_format.get_name p with
                  | None -> "none"
                  | Some p -> p)
              ~from_value:(fun v ->
                Avutil.Sample_format.find (Lang.to_string v))
              s
        | `Channel_layout s ->
            mk_opt ~t:Lang.string_t
              ~to_string:(Avutil.Channel_layout.get_description ?channels:None)
              ~from_value:(fun v ->
                Avutil.Channel_layout.find (Lang.to_string v))
              s
    in
    List.fold_left mk_opt ([], fun _ x -> x) (Avutil.Options.opts options))

let get_config graph =
  let { config; _ } = Graph.of_value graph in
  match config with
    | Some config -> config
    | None ->
        raise
          (Error.Invalid_value
             ( graph,
               "Graph variables cannot be used outside of ffmpeg.filter.create!"
             ))

let apply_filter ~args_parser ~filter ~sources_t p =
  Avfilter.(
    let graph_v = Lang.assoc "" 1 p in
    let config = get_config graph_v in
    let graph = Graph.of_value graph_v in
    let name = uniq_name filter.name in
    let flags = filter.flags in
    let filter = attach ~args:(args_parser p []) ~name filter config in
    let input_set = ref false in
    let meths =
      [
        ( "process_command",
          Lang.val_fun
            [
              ("fast", "fast", Some (Lang.bool false));
              ("", "", None);
              ("", "", None);
            ]
            (fun p ->
              let fast = Lang.to_bool (List.assoc "fast" p) in
              let flags = if fast then [`Fast] else [] in
              let cmd = Lang.to_string (Lang.assoc "" 1 p) in
              let arg = Lang.to_string (Lang.assoc "" 2 p) in
              if initiated graph then (
                try
                  Lang.string (Avfilter.process_command ~flags ~cmd ~arg filter)
                with exn ->
                  let bt = Printexc.get_raw_backtrace () in
                  Lang.raise_as_runtime ~bt ~kind:"ffmpeg.filter" exn)
              else Lang.string "graph not started!") );
        ( "output",
          let audio =
            List.map
              (fun p -> Audio.to_value (`Output (lazy p)))
              filter.io.outputs.audio
          in
          let video =
            List.map
              (fun p -> Video.to_value (`Output (lazy p)))
              filter.io.outputs.video
          in
          if List.mem `Dynamic_outputs flags then
            Lang.tuple [Lang.list audio; Lang.list video]
          else (match audio @ video with [x] -> x | l -> Lang.tuple l) );
        ( "set_input",
          Lang.val_fun
            (List.map (fun (_, lbl, _) -> (lbl, lbl, None)) sources_t)
            (fun p ->
              let v = List.assoc "" p in
              if !input_set then
                Runtime_error.error
                  ~pos:
                    (match v.Term.Value.pos with None -> [] | Some p -> [p])
                  ~message:"Filter input already set!" "ffmpeg.filter";
              let audio_inputs_c = List.length filter.io.inputs.audio in
              let get_input ~mode ~ofs idx =
                if List.mem `Dynamic_inputs flags then (
                  let v = Lang.assoc "" (if mode = `Audio then 1 else 2) p in
                  let inputs = Lang.to_list v in
                  if List.length inputs <= idx then
                    raise
                      (Error.Invalid_value
                         ( v,
                           Printf.sprintf
                             "Invalid number of input for filter %s" filter.name
                         ));
                  List.nth inputs idx)
                else Lang.assoc "" (idx + ofs + 1) p
              in
              Queue.push
                (lazy
                  (List.iteri
                     (fun idx input ->
                       let output =
                         match
                           Audio.of_value (get_input ~mode:`Audio ~ofs:0 idx)
                         with
                           | `Output output -> Lazy.force output
                           | _ -> assert false
                       in
                       link output input)
                     filter.io.inputs.audio;
                   List.iteri
                     (fun idx input ->
                       let output =
                         match
                           Video.of_value
                             (get_input ~mode:`Video ~ofs:audio_inputs_c idx)
                         with
                           | `Output output -> output
                           | _ -> assert false
                       in
                       link (Lazy.force output) input)
                     filter.io.inputs.video))
                graph.init;
              input_set := true;
              Lang.unit) );
      ]
    in
    Lang.meth Lang.unit meths)

let () =
  Avfilter.(
    let mk_av_t ~flags ~mode { audio; video } =
      match mode with
        | `Input when List.mem `Dynamic_inputs flags ->
            [Lang.list_t Audio.t; Lang.list_t Video.t]
        | `Output when List.mem `Dynamic_outputs flags ->
            [Lang.list_t Audio.t; Lang.list_t Video.t]
        | _ ->
            let audio = List.map (fun _ -> Audio.t) audio in
            let video = List.map (fun _ -> Video.t) video in
            audio @ video
    in
    List.iter
      (fun ({ name; description; io; flags } as filter) ->
        let args, args_parser = mk_options filter in
        let args_t = args @ [("", Graph.t, None, None)] in
        let sources_t =
          List.map
            (fun t -> (false, "", t))
            (mk_av_t ~flags ~mode:`Input io.inputs)
        in
        let output_t =
          match mk_av_t ~flags ~mode:`Output io.outputs with
            | [x] -> x
            | l -> Lang.tuple_t l
        in
        let return_t =
          Lang.method_t Lang.unit_t
            [
              ( "process_command",
                ( [],
                  Lang.fun_t
                    [
                      (true, "fast", Lang.bool_t);
                      (false, "", Lang.string_t);
                      (false, "", Lang.string_t);
                    ]
                    Lang.string_t ),
                "`process_command(?fast, \"command\", \"argument\")` sends the \
                 given command to this filter. Set `fast` to `true` to only \
                 execute the command when it is fast." );
              ("output", ([], output_t), "Filter output(s)");
              ( "set_input",
                ([], Lang.fun_t sources_t Lang.unit_t),
                "Set the filter's input(s)" );
            ]
        in
        let explanation =
          String.concat " "
            ((if List.mem `Dynamic_inputs flags then
              [
                "This filter has dynamic inputs: last two arguments are lists \
                 of audio and video inputs. Total number of inputs is \
                 determined at runtime.";
              ]
             else [])
            @
            if List.mem `Dynamic_outputs flags then
              [
                "This filter has dynamic outputs: returned value is a tuple of \
                 audio and video outputs. Total number of outputs is \
                 determined at runtime.";
              ]
            else [])
        in
        let descr =
          Printf.sprintf "Ffmpeg filter: %s%s" description
            (if explanation <> "" then " " ^ explanation else "")
        in
        Lang.add_builtin ~category:`Filter ("ffmpeg.filter." ^ name) ~descr
          ~flags:[`Extra]
          (args_t @ List.map (fun (_, lbl, t) -> (lbl, t, None, None)) sources_t)
          output_t
          (fun p ->
            let named_args = List.filter (fun (lbl, _) -> lbl <> "") p in
            let unnamed_args = List.filter (fun (lbl, _) -> lbl = "") p in
            (* Unnamed args are ordered. The last [n] ones are from [sources_t] *)
            let n_sources = List.length sources_t in
            let n_args = List.length unnamed_args in
            let unnamed_args, inputs =
              List.fold_left
                (fun (args, inputs) el ->
                  if List.length args < n_args - n_sources then
                    (args @ [el], inputs)
                  else (args, inputs @ [el]))
                ([], []) unnamed_args
            in
            let args = named_args @ unnamed_args in
            let filter = apply_filter ~args_parser ~filter ~sources_t args in
            ignore (Lang.apply (Term.Value.invoke filter "set_intput") inputs);
            Term.Value.invoke filter "output");
        Lang.add_builtin ~category:`Filter
          ("ffmpeg.filter." ^ name ^ ".create")
          ~descr:
            (Printf.sprintf
               "%s. Use this operator to initiate the filter independently of \
                its inputs, to be able to send commands to the filter \
                instance."
               descr)
          ~flags:[`Extra] args_t return_t
          (apply_filter ~args_parser ~filter ~sources_t))
      filters)

let abuffer_args frame =
  let sample_rate = Avutil.Audio.frame_get_sample_rate frame in
  let channel_layout = Avutil.Audio.frame_get_channel_layout frame in
  let sample_format = Avutil.Audio.frame_get_sample_format frame in
  [
    `Pair ("sample_rate", `Int sample_rate);
    `Pair ("time_base", `Rational (Ffmpeg_utils.liq_main_ticks_time_base ()));
    `Pair
      ("channel_layout", `Int64 (Avutil.Channel_layout.get_id channel_layout));
    `Pair ("sample_fmt", `Int (Avutil.Sample_format.get_id sample_format));
  ]

let buffer_args frame =
  let width = Avutil.Video.frame_get_width frame in
  let height = Avutil.Video.frame_get_height frame in
  let pixel_format = Avutil.Video.frame_get_pixel_format frame in
  [
    `Pair ("time_base", `Rational (Ffmpeg_utils.liq_main_ticks_time_base ()));
    `Pair ("width", `Int width);
    `Pair ("height", `Int height);
    `Pair ("pix_fmt", `Int Avutil.Pixel_format.(get_id pixel_format));
  ]

let () =
  let raw_audio_format = `Kind Ffmpeg_raw_content.Audio.kind in
  let raw_video_format = `Kind Ffmpeg_raw_content.Video.kind in
  let audio_frame =
    { Frame.audio = raw_audio_format; video = Frame.none; midi = Frame.none }
  in
  let video_frame =
    { Frame.audio = Frame.none; video = raw_video_format; midi = Frame.none }
  in
  let audio_t =
    Lang.(source_t ~methods:true (kind_type_of_kind_format audio_frame))
  in
  let video_t =
    Lang.(source_t ~methods:true (kind_type_of_kind_format video_frame))
  in

  let output_base_proto =
    [
      ( "buffer",
        Lang.float_t,
        Some (Lang.float 0.1),
        Some "Duration of the pre-buffered data." );
    ]
  in

  Lang.add_builtin ~category:`Filter "ffmpeg.filter.audio.input"
    ~descr:"Attach an audio source to a filter's input"
    [
      ( "pass_metadata",
        Lang.bool_t,
        Some (Lang.bool true),
        Some "Pass liquidsoap's metadata to this stream" );
      ("", Graph.t, None, None);
      ("", audio_t, None, None);
    ]
    Audio.t
    (fun p ->
      let pass_metadata = Lang.to_bool (List.assoc "pass_metadata" p) in
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in
      let source_val = Lang.assoc "" 2 p in

      let kind =
        Source.Kind.of_kind
          Frame.
            {
              (* We need to make sure that we are using a format here to
                 ensure that its params are properly unified with the underlying source. *)
              audio =
                `Format
                  Ffmpeg_raw_content.Audio.(lift_params (default_params `Raw));
              video = Frame.none;
              midi = Frame.none;
            }
      in
      let name = uniq_name "abuffer" in
      let pos = source_val.Lang.pos in
      let s =
        try
          Ffmpeg_filter_io.(
            new audio_output ~pass_metadata ~name ~kind source_val)
        with
          | Source.Clock_conflict (a, b) ->
              raise (Error.Clock_conflict (pos, a, b))
          | Source.Clock_loop (a, b) -> raise (Error.Clock_loop (pos, a, b))
          | Source.Kind.Conflict (a, b) ->
              raise (Error.Kind_conflict (pos, a, b))
      in
      Queue.add s#clock graph.clocks;

      let args = ref None in

      let audio =
        lazy
          (let _abuffer =
             Avfilter.attach ~args:(Option.get !args) ~name Avfilter.abuffer
               config
           in
           Avfilter.(Hashtbl.add graph.entries.inputs.audio name s#set_input);
           init_graph graph;
           List.hd Avfilter.(_abuffer.io.outputs.audio))
      in

      Queue.add (fun () -> Lazy.is_val audio) graph.input_inits;

      s#set_init (fun frame ->
          if !args = None then (
            args := Some (abuffer_args frame);
            ignore (Lazy.force audio);
            init_graph graph));

      Audio.to_value (`Output audio));

  let return_kind = Frame.{ audio_frame with video = none; midi = none } in
  let return_t = Lang.kind_type_of_kind_format return_kind in
  Lang.add_operator "ffmpeg.filter.audio.output" ~category:`Audio
    ~descr:"Return an audio source from a filter's output" ~return_t
    (output_base_proto
    @ [
        ( "pass_metadata",
          Lang.bool_t,
          Some (Lang.bool true),
          Some "Pass ffmpeg stream metadata to liquidsoap" );
        ("", Graph.t, None, None);
        ("", Audio.t, None, None);
      ])
    (fun p ->
      let pass_metadata = Lang.to_bool (List.assoc "pass_metadata" p) in
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in

      let kind =
        Source.Kind.of_kind
          Frame.
            {
              audio = `Kind Ffmpeg_raw_content.Audio.kind;
              video = none;
              midi = none;
            }
      in
      let bufferize = Lang.to_float (List.assoc "buffer" p) in
      let s = new Ffmpeg_filter_io.audio_input ~pass_metadata ~bufferize kind in
      Queue.add s#clock graph.clocks;

      let pad = Audio.of_value (Lang.assoc "" 2 p) in
      Queue.add
        (lazy
          (let pad =
             match pad with `Output pad -> Lazy.force pad | _ -> assert false
           in
           let name = uniq_name "abuffersink" in
           let _abuffersink =
             Avfilter.attach ~name Avfilter.abuffersink config
           in
           Avfilter.(link pad (List.hd _abuffersink.io.inputs.audio));
           Avfilter.(Hashtbl.add graph.entries.outputs.audio name s#set_output)))
        graph.init;

      (s :> Source.source));

  Lang.add_builtin ~category:`Filter "ffmpeg.filter.video.input"
    ~descr:"Attach a video source to a filter's input"
    [
      ( "pass_metadata",
        Lang.bool_t,
        Some (Lang.bool false),
        Some "Pass liquidsoap's metadata to this stream" );
      ("", Graph.t, None, None);
      ("", video_t, None, None);
    ]
    Video.t
    (fun p ->
      let pass_metadata = Lang.to_bool (List.assoc "pass_metadata" p) in
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in
      let source_val = Lang.assoc "" 2 p in

      let kind =
        Source.Kind.of_kind
          Frame.
            {
              (* We need to make sure that we are using a format here to
                 ensure that its params are properly unified with the underlying source. *)
              audio = Frame.none;
              video =
                `Format
                  Ffmpeg_raw_content.Video.(lift_params (default_params `Raw));
              midi = Frame.none;
            }
      in
      let name = uniq_name "buffer" in
      let pos = source_val.Lang.pos in
      let s =
        try
          Ffmpeg_filter_io.(
            new video_output ~pass_metadata ~name ~kind source_val)
        with
          | Source.Clock_conflict (a, b) ->
              raise (Error.Clock_conflict (pos, a, b))
          | Source.Clock_loop (a, b) -> raise (Error.Clock_loop (pos, a, b))
          | Source.Kind.Conflict (a, b) ->
              raise (Error.Kind_conflict (pos, a, b))
      in
      Queue.add s#clock graph.clocks;

      let args = ref None in

      let video =
        lazy
          (let _buffer =
             Avfilter.attach ~args:(Option.get !args) ~name Avfilter.buffer
               config
           in
           Avfilter.(Hashtbl.add graph.entries.inputs.video name s#set_input);
           List.hd Avfilter.(_buffer.io.outputs.video))
      in

      Queue.add (fun () -> Lazy.is_val video) graph.input_inits;

      s#set_init (fun frame ->
          if !args = None then (
            args := Some (buffer_args frame);
            ignore (Lazy.force video);
            init_graph graph));

      Video.to_value (`Output video));

  let return_kind = Frame.{ video_frame with audio = none; midi = none } in
  let return_t = Lang.kind_type_of_kind_format return_kind in
  Lang.add_operator "ffmpeg.filter.video.output" ~category:`Video
    ~descr:"Return a video source from a filter's output" ~return_t
    (output_base_proto
    @ [
        ( "pass_metadata",
          Lang.bool_t,
          Some (Lang.bool false),
          Some "Pass ffmpeg stream metadata to liquidsoap" );
        ( "fps",
          Lang.nullable_t Lang.int_t,
          Some Lang.null,
          Some "Output frame per seconds. Defaults to global value" );
        ("", Graph.t, None, None);
        ("", Video.t, None, None);
      ])
    (fun p ->
      let pass_metadata = Lang.to_bool (List.assoc "pass_metadata" p) in
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in

      let fps = Lang.to_option (Lang.assoc "fps" 1 p) in
      let fps = Option.map (fun v -> lazy (Lang.to_int v)) fps in
      let fps = Option.value fps ~default:Frame.video_rate in

      let kind =
        Source.Kind.of_kind
          Frame.
            {
              audio = none;
              video = `Kind Ffmpeg_raw_content.Video.kind;
              midi = none;
            }
      in
      let bufferize = Lang.to_float (List.assoc "buffer" p) in
      let s =
        new Ffmpeg_filter_io.video_input ~pass_metadata ~bufferize ~fps kind
      in
      Queue.add s#clock graph.clocks;

      Queue.add
        (lazy
          (let pad =
             match Video.of_value (Lang.assoc "" 2 p) with
               | `Output p -> Lazy.force p
               | _ -> assert false
           in
           let name = uniq_name "buffersink" in
           let target_frame_rate = Lazy.force fps in
           let fps =
             match Avfilter.find_opt "fps" with
               | Some f -> f
               | None -> failwith "Could not find ffmpeg fps filter"
           in
           let fps =
             let args = [`Pair ("fps", `Int target_frame_rate)] in
             Avfilter.attach ~name:(uniq_name "fps") ~args fps config
           in
           let _buffersink = Avfilter.attach ~name Avfilter.buffersink config in
           Avfilter.(link pad (List.hd fps.io.inputs.video));
           Avfilter.(
             link
               (List.hd fps.io.outputs.video)
               (List.hd _buffersink.io.inputs.video));
           Avfilter.(Hashtbl.add graph.entries.outputs.video name s#set_output)))
        graph.init;

      (s :> Source.source))

let () =
  let univ_t = Lang.univ_t () in
  Lang.add_builtin "ffmpeg.filter.create" ~category:`Filter
    ~descr:"Configure and launch a filter graph"
    [("", Lang.fun_t [(false, "", Graph.t)] univ_t, None, None)]
    univ_t
    (fun p ->
      let fn = List.assoc "" p in
      let config = Avfilter.init () in
      let graph =
        Avfilter.
          {
            config = Some config;
            input_inits = Queue.create ();
            init = Queue.create ();
            clocks = Queue.create ();
            entries =
              {
                inputs =
                  { audio = Hashtbl.create 10; video = Hashtbl.create 10 };
                outputs =
                  { audio = Hashtbl.create 10; video = Hashtbl.create 10 };
              };
          }
      in
      let ret = Lang.apply fn [("", Graph.to_value graph)] in
      let first = Queue.take graph.clocks in
      Queue.iter (Clock.unify first) graph.clocks;
      Queue.add
        (lazy
          (log#info "Initializing graph";
           let filter = Avfilter.launch config in
           Avfilter.(
             List.iter
               (fun (name, input) ->
                 let set_input = Hashtbl.find graph.entries.inputs.audio name in
                 set_input input)
               filter.inputs.audio);
           Avfilter.(
             List.iter
               (fun (name, input) ->
                 let set_input = Hashtbl.find graph.entries.inputs.video name in
                 set_input input)
               filter.inputs.video);
           Avfilter.(
             List.iter
               (fun (name, output) ->
                 let set_output =
                   Hashtbl.find graph.entries.outputs.audio name
                 in
                 set_output output)
               filter.outputs.audio);
           Avfilter.(
             List.iter
               (fun (name, output) ->
                 let set_output =
                   Hashtbl.find graph.entries.outputs.video name
                 in
                 set_output output)
               filter.outputs.video)))
        graph.init;
      init_graph graph;
      graph.config <- None;
      ret)
