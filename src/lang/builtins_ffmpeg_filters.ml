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

open Lang_builtins

type 'a input = 'a Avutil.frame -> unit
type 'a output = unit -> 'a Avutil.frame
type 'a setter = 'a -> unit
type 'a entries = (string, 'a setter) Hashtbl.t
type inputs = ([ `Audio ] input entries, [ `Video ] input entries) Avfilter.av

type outputs =
  ([ `Audio ] output entries, [ `Video ] output entries) Avfilter.av

type graph = {
  mutable config : Avfilter.config option;
  entries : (inputs, outputs) Avfilter.io;
}

module Graph = Lang.MkAbstract (struct
  type content = graph

  let name = "ffmpeg.filter.graph"
end)

module Audio = Lang.MkAbstract (struct
  type content =
    [ `Input of ([ `Attached ], [ `Audio ], [ `Input ]) Avfilter.pad
    | `Output of ([ `Attached ], [ `Audio ], [ `Output ]) Avfilter.pad ]

  let name = "ffmpeg.filter.audio"
end)

module Video = Lang.MkAbstract (struct
  type content =
    [ `Input of ([ `Attached ], [ `Video ], [ `Input ]) Avfilter.pad
    | `Output of ([ `Attached ], [ `Video ], [ `Output ]) Avfilter.pad ]

  let name = "ffmpeg.filter.video"
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

let mk_args ~t name p =
  let name = name ^ "_args" in
  let args = List.assoc name p in
  let args = Lang.to_list args in
  let extract_pair extractor v =
    let label, value = Lang.to_product v in
    (Lang.to_string label, extractor value)
  in
  let extract =
    match t with
      | `Int -> fun v -> `Pair (extract_pair (fun v -> `Int (Lang.to_int v)) v)
      | `Float ->
          fun v -> `Pair (extract_pair (fun v -> `Float (Lang.to_float v)) v)
      | `String ->
          fun v -> `Pair (extract_pair (fun v -> `String (Lang.to_string v)) v)
      | `Rational ->
          fun v ->
            `Pair
              (extract_pair
                 (fun v ->
                   let num, den = Lang.to_product v in
                   `Rational
                     { Avutil.num = Lang.to_int num; den = Lang.to_int den })
                 v)
      | `Flag -> fun v -> `Flag (Lang.to_string v)
  in
  List.map extract args

let get_config graph =
  let { config; _ } = Graph.of_value graph in
  match config with
    | Some config -> config
    | None ->
        raise
          (Lang_errors.Invalid_value
             ( graph,
               "Graph variables cannot be used outside of ffmpeg.filter.create!"
             ))

let apply_filter ~filter p =
  let int_args = mk_args ~t:`Int "int" p in
  let float_args = mk_args ~t:`Float "float" p in
  let string_args = mk_args ~t:`String "string" p in
  let rational_args = mk_args ~t:`Rational "rational" p in
  let flag_args = mk_args ~t:`Flag "flag" p in
  let args = int_args @ float_args @ string_args @ rational_args @ flag_args in
  Avfilter.(
    let config = get_config (Lang.assoc "" 1 p) in
    let name = uniq_name filter.name in
    let filter = attach ~args ~name filter config in
    let audio_inputs_c = List.length filter.io.inputs.audio in
    List.iteri
      (fun idx input ->
        let output =
          match Audio.of_value (Lang.assoc "" (idx + 2) p) with
            | `Output output -> output
            | _ -> assert false
        in
        link output input)
      filter.io.inputs.audio;
    List.iteri
      (fun idx input ->
        let output =
          match Video.of_value (Lang.assoc "" (audio_inputs_c + idx + 2) p) with
            | `Output output -> output
            | _ -> assert false
        in
        link output input)
      filter.io.inputs.video;
    let output =
      List.map (fun p -> Audio.to_value (`Output p)) filter.io.outputs.audio
      @ List.map (fun p -> Video.to_value (`Output p)) filter.io.outputs.video
    in
    match output with [x] -> x | l -> Lang.tuple l)

let () =
  Avfilter.(
    let mk_av_t { audio; video } =
      let audio = List.map (fun _ -> Audio.t) audio in
      let video = List.map (fun _ -> Video.t) video in
      audio @ video
    in
    let args ?t name =
      let t =
        match t with
          | Some t -> Lang.product_t Lang.string_t t
          | None -> Lang.string_t
      in
      (name ^ "_args", Lang.list_t t, Some (Lang.list ~t []), None)
    in
    List.iter
      (fun ({ name; description; io } as filter) ->
        let input_t =
          [
            args ~t:Lang.int_t "int";
            args ~t:Lang.float_t "float";
            args ~t:Lang.string_t "string";
            args ~t:(Lang.product_t Lang.int_t Lang.int_t) "rational";
            args "flag";
            ("", Graph.t, None, None);
          ]
          @ List.map (fun t -> ("", t, None, None)) (mk_av_t io.inputs)
        in
        let output_t =
          match mk_av_t io.outputs with [x] -> x | l -> Lang.tuple_t l
        in
        add_builtin ~cat:Liq ("ffmpeg.filter." ^ name)
          ~descr:("Ffmpeg filter: " ^ description)
          input_t output_t (apply_filter ~filter))
      filters)

let get_filter =
  let filters = Hashtbl.create 10 in
  fun ~source name ->
    match Hashtbl.find_opt filters name with
      | Some f -> f
      | None -> (
          match List.find_opt (fun f -> f.Avfilter.name = name) source with
            | Some f ->
                Hashtbl.add filters name f;
                f
            | None -> failwith ("Could not find ffmpeg filter: " ^ name) )

let abuffer_args channels =
  let sample_rate = Frame.audio_of_seconds 1. in
  let channel_layout =
    try Avutil.Channel_layout.get_default channels
    with Not_found ->
      failwith
        "ffmpeg filter: could not find a default channel configuration for \
         this number of channels.."
  in
  [
    `Pair ("sample_rate", `Int sample_rate);
    `Pair ("time_base", `Rational { Avutil.num = 1; den = sample_rate });
    `Pair ("channels", `Int channels);
    `Pair ("channel_layout", `Int (Avutil.Channel_layout.get_id channel_layout));
    `Pair ("sample_fmt", `Int (Avutil.Sample_format.get_id `Dbl));
  ]

let buffer_args () =
  let frame_rate = Frame.video_of_seconds 1. in
  let width = Lazy.force Frame.video_width in
  let height = Lazy.force Frame.video_height in
  [
    `Pair ("frame_rate", `Int frame_rate);
    `Pair ("time_base", `Rational { Avutil.num = 1; den = frame_rate });
    `Pair ("pixel_aspect", `Int 1);
    `Pair ("width", `Int width);
    `Pair ("height", `Int height);
    `Pair ("pix_fmt", `String "yuv420p");
  ]

let () =
  let audio_t = Lang.(source_t (kind_type_of_kind_format audio_any)) in
  let video_t = Lang.(source_t (kind_type_of_kind_format video_only)) in

  add_builtin ~cat:Liq "ffmpeg.filter.audio.input"
    ~descr:"Attach an audio source to a filter's input"
    [("", Graph.t, None, None); ("", audio_t, None, None)] Audio.t (fun p ->
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in
      let source_val = Lang.assoc "" 2 p in
      let kind = (Lang.to_source source_val)#kind in
      let channels = Frame.((type_of_kind kind).audio) in
      let name = uniq_name "abuffer" in
      let abuffer = get_filter ~source:Avfilter.buffers "abuffer" in
      let args = abuffer_args channels in
      let abuffer = Avfilter.attach ~args ~name abuffer config in
      let s = Ffmpeg_filter_io.(new audio_output ~name ~kind source_val) in
      Avfilter.(Hashtbl.add graph.entries.inputs.audio name s#set_input);
      Audio.to_value (`Output (List.hd Avfilter.(abuffer.io.outputs.audio))));

  let kind = Lang.kind_type_of_kind_format Lang.audio_any in
  Lang.add_operator "ffmpeg.filter.audio.output" ~category:Lang.Output
    ~descr:"Return an audio source from a filter's output"
    ~kind:(Lang.Unconstrained kind)
    [("", Graph.t, None, None); ("", Audio.t, None, None)] (fun p kind ->
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in
      let pad =
        match Audio.of_value (Lang.assoc "" 2 p) with
          | `Output p -> p
          | _ -> assert false
      in
      let name = uniq_name "abuffersink" in
      let abuffersink = get_filter ~source:Avfilter.sinks "abuffersink" in
      let abuffersink = Avfilter.attach ~name abuffersink config in
      Avfilter.(link pad (List.hd abuffersink.io.inputs.audio));
      let s = new Ffmpeg_filter_io.audio_input kind in
      Avfilter.(Hashtbl.add graph.entries.outputs.audio name s#set_output);
      (s :> Source.source));

  add_builtin ~cat:Liq "ffmpeg.filter.video.input"
    ~descr:"Attach a video source to a filter's input"
    [("", Graph.t, None, None); ("", video_t, None, None)] Video.t (fun p ->
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in
      let source_val = Lang.assoc "" 2 p in
      let name = uniq_name "buffer" in
      let buffer = get_filter ~source:Avfilter.buffers "buffer" in
      let args = buffer_args () in
      let buffer = Avfilter.attach ~args ~name buffer config in
      let s = Ffmpeg_filter_io.(new video_output ~name source_val) in
      Avfilter.(Hashtbl.add graph.entries.inputs.video name s#set_input);
      Video.to_value (`Output (List.hd Avfilter.(buffer.io.outputs.video))));

  let kind = Lang.kind_type_of_kind_format Lang.video_only in
  Lang.add_operator "ffmpeg.filter.video.output" ~category:Lang.Output
    ~descr:"Return a video source from a filter's output"
    ~kind:(Lang.Unconstrained kind)
    [("", Graph.t, None, None); ("", Video.t, None, None)] (fun p kind ->
      let graph_v = Lang.assoc "" 1 p in
      let config = get_config graph_v in
      let graph = Graph.of_value graph_v in
      let pad =
        match Video.of_value (Lang.assoc "" 2 p) with
          | `Output p -> p
          | _ -> assert false
      in
      let name = uniq_name "buffersink" in
      let target_frame_rate = Lazy.force Frame.video_rate in
      let fps = get_filter ~source:Avfilter.filters "fps" in
      let fps =
        let args =
          [`Pair ("fps", `Int target_frame_rate); `Pair ("start_time", `Int 0)]
        in
        Avfilter.attach ~name:(uniq_name "fps") ~args fps config
      in
      let buffersink = get_filter ~source:Avfilter.sinks "buffersink" in
      let buffersink = Avfilter.attach ~name buffersink config in
      Avfilter.(link pad (List.hd fps.io.inputs.video));
      Avfilter.(
        link (List.hd fps.io.outputs.video) (List.hd buffersink.io.inputs.video));
      let s = new Ffmpeg_filter_io.video_input kind in
      Avfilter.(Hashtbl.add graph.entries.outputs.video name s#set_output);
      (s :> Source.source))

let () =
  let univ_t = Lang.univ_t () in
  add_builtin "ffmpeg.filter.create" ~cat:Liq
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
            entries =
              {
                inputs =
                  { audio = Hashtbl.create 10; video = Hashtbl.create 10 };
                outputs =
                  { audio = Hashtbl.create 10; video = Hashtbl.create 10 };
              };
          }
      in
      let ret = Lang.apply ~t:Lang.unit_t fn [("", Graph.to_value graph)] in
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
            let set_output = Hashtbl.find graph.entries.outputs.audio name in
            set_output output)
          filter.outputs.audio);
      Avfilter.(
        List.iter
          (fun (name, output) ->
            let set_output = Hashtbl.find graph.entries.outputs.video name in
            set_output output)
          filter.outputs.video);
      graph.config <- None;
      ret)
