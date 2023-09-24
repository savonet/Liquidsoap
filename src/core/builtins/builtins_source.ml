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

let source = Muxer.source
let should_stop = Atomic.make false
let () = Lifecycle.before_core_shutdown (fun () -> Atomic.set should_stop true)

let _ =
  Lang.add_builtin ~base:source "set_name" ~category:(`Source `Liquidsoap)
    ~descr:"Set the name of an operator."
    [
      ("", Lang.source_t (Lang.univ_t ()), None, None);
      ("", Lang.string_t, None, None);
    ]
    Lang.unit_t
    (fun p ->
      let s = Lang.assoc "" 1 p |> Lang.to_source in
      let n = Lang.assoc "" 2 p |> Lang.to_string in
      s#set_name n;
      Lang.unit)

let _ =
  Lang.add_builtin ~base:source "skip" ~category:(`Source `Liquidsoap)
    ~descr:"Skip to the next track."
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.unit_t
    (fun p ->
      (Lang.to_source (List.assoc "" p))#abort_track;
      Lang.unit)

let _ =
  Lang.add_builtin ~base:source "seek" ~category:(`Source `Liquidsoap)
    ~descr:
      "Seek forward, in seconds. Returns the amount of time effectively seeked."
    [
      ("", Lang.source_t (Lang.univ_t ()), None, None);
      ("", Lang.float_t, None, None);
    ]
    Lang.float_t
    (fun p ->
      let s = Lang.to_source (Lang.assoc "" 1 p) in
      let time = Lang.to_float (Lang.assoc "" 2 p) in
      let len = Frame.main_of_seconds time in
      let ret = s#seek len in
      Lang.float (Frame.seconds_of_main ret))

let _ =
  Lang.add_builtin ~base:source "id" ~category:(`Source `Liquidsoap)
    ~descr:"Get the identifier of a source."
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.string_t
    (fun p -> Lang.string (Lang.to_source (List.assoc "" p))#id)

let _ =
  Lang.add_builtin ~base:source "fallible" ~category:(`Source `Liquidsoap)
    ~descr:"Indicate if a source may fail, i.e. may not be ready to stream."
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.bool_t
    (fun p -> Lang.bool ((Lang.to_source (List.assoc "" p))#stype == `Fallible))

let _ =
  Lang.add_builtin ~base:source "is_ready" ~category:(`Source `Liquidsoap)
    ~descr:
      "Indicate if a source is ready to stream (we also say that it is \
       available), or currently streaming."
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.bool_t
    (fun p -> Lang.bool ((Lang.to_source (List.assoc "" p))#is_ready ()))

let _ =
  Lang.add_builtin ~base:source "is_up" ~category:`System
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.bool_t ~descr:"Check whether a source is up."
    (fun p -> Lang.bool (Lang.to_source (Lang.assoc "" 1 p))#is_up)

let _ =
  Lang.add_builtin ~base:source "remaining" ~category:(`Source `Liquidsoap)
    ~descr:"Estimation of remaining time in the current track."
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.float_t
    (fun p ->
      let r = (Lang.to_source (List.assoc "" p))#remaining in
      let f = if r < 0 then infinity else Frame.seconds_of_main r in
      Lang.float f)

let _ =
  Lang.add_builtin ~base:source "elapsed" ~category:(`Source `Liquidsoap)
    ~descr:"Elapsed time in the current track."
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.float_t
    (fun p ->
      let d = (Lang.to_source (List.assoc "" p))#elapsed in
      let f = if d < 0 then infinity else Frame.seconds_of_main d in
      Lang.float f)

let _ =
  Lang.add_builtin ~base:source "duration" ~category:(`Source `Liquidsoap)
    ~descr:"Estimation of the duration in the current track."
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.float_t
    (fun p ->
      let d = (Lang.to_source (List.assoc "" p))#duration in
      let f = if d < 0 then infinity else Frame.seconds_of_main d in
      Lang.float f)

let _ =
  Lang.add_builtin ~category:(`Source `Liquidsoap) ~base:source "time"
    ~descr:"Get a source's time, based on its assigned clock"
    [("", Lang.source_t (Lang.univ_t ()), None, None)]
    Lang.float_t
    (fun p ->
      let s = Lang.to_source (List.assoc "" p) in
      let ticks =
        if Source.Clock_variables.is_known s#clock then
          (Source.Clock_variables.get s#clock)#get_tick
        else 0
      in
      let frame_position = Lazy.force Frame.duration *. float ticks in
      let in_frame_position = Frame.seconds_of_main (Frame.position s#memo) in
      Lang.float (frame_position +. in_frame_position))

let _ =
  Lang.add_builtin ~base:source "on_shutdown" ~category:(`Source `Liquidsoap)
    [
      ("", Lang.source_t (Lang.univ_t ()), None, None);
      ("", Lang.fun_t [] Lang.unit_t, None, None);
    ]
    Lang.unit_t
    ~descr:
      "Register a function to be called when source is not used anymore by \
       another source."
    (fun p ->
      let s = Lang.to_source (Lang.assoc "" 1 p) in
      let f = Lang.assoc "" 2 p in
      let wrap_f () = ignore (Lang.apply f []) in
      s#on_sleep wrap_f;
      Lang.unit)

let _ =
  let s_t = Lang.source_t (Lang.frame_t (Lang.univ_t ()) Frame.Fields.empty) in
  Lang.add_builtin ~base:source "init" ~category:(`Source `Liquidsoap)
    ~descr:
      "Simultaneously initialize sources, return the sublist of sources that \
       failed to initialize."
    ~flags:[`Experimental]
    [("", Lang.list_t s_t, None, None)]
    (Lang.list_t s_t)
    (fun p ->
      let l = Lang.to_list (List.assoc "" p) in
      let l = List.map Lang.to_source l in
      let l =
        (* TODO this whole function should be about active sources,
         *   just like source.shutdown() but the language has no runtime
         *   difference between sources and active sources, so we use
         *   this trick to compare active sources and passive ones... *)
        Clock.force_init (fun x -> List.exists (fun y -> Oo.id x = Oo.id y) l)
      in
      Lang.list (List.map (fun x -> Lang.source (x :> Source.source)) l))

let _ =
  let log = Log.make ["source"; "dump"] in
  let kind = Lang.univ_t () in
  Lang.add_builtin ~base:source "dump" ~category:(`Source `Liquidsoap)
    ~descr:"Immediately encode the whole contents of a source into a file."
    ~flags:[`Experimental]
    [
      ("", Lang.format_t kind, None, Some "Encoding format.");
      ("", Lang.string_t, None, Some "Name of the file.");
      ("", Lang.source_t kind, None, Some "Source to encode.");
      ( "ratio",
        Lang.float_t,
        Some (Lang.float 50.),
        Some
          "Time ratio. A value of `50` means process data at `50x` real rate, \
           when possible." );
    ]
    Lang.unit_t
    (fun p ->
      let module Time = (val Clock.time_implementation () : Liq_time.T) in
      let open Time in
      let proto =
        let p = Pipe_output.file_proto (Lang.univ_t ()) in
        List.filter_map (fun (l, _, v, _) -> Option.map (fun v -> (l, v)) v) p
      in
      let proto = ("fallible", Lang.bool true) :: proto in
      let s = Lang.to_source (Lang.assoc "" 3 p) in
      let p = (("id", Lang.string "source_dumper") :: p) @ proto in
      let fo = Pipe_output.new_file_output p in
      let ratio = Lang.to_float (List.assoc "ratio" p) in
      let latency = Time.of_float (Lazy.force Frame.duration /. ratio) in
      let clock = Clock.clock ~start:false "source_dumper" in
      Clock.unify ~pos:fo#pos fo#clock (Clock.create_known clock);
      ignore (clock#start_outputs (fun _ -> true) ());
      log#info "Start dumping source (ratio: %.02fx)" ratio;
      while (not (Atomic.get should_stop)) && fo#is_ready () do
        let start_time = Time.time () in
        clock#end_tick;
        sleep_until (start_time |+| latency)
      done;
      log#info "Source dumped.";
      fo#leave s;
      Lang.unit)

let _ =
  let log = Log.make ["source"; "drop"] in
  Lang.add_builtin ~base:source "drop" ~category:(`Source `Liquidsoap)
    ~descr:"Animate the source as fast as possible, dropping its output."
    ~flags:[`Experimental]
    [
      ("", Lang.source_t (Lang.univ_t ()), None, Some "Source to animate.");
      ( "ratio",
        Lang.float_t,
        Some (Lang.float 50.),
        Some
          "Time ratio. A value of `50` means process data at `50x` real rate, \
           when possible." );
    ]
    Lang.unit_t
    (fun p ->
      let module Time = (val Clock.time_implementation () : Liq_time.T) in
      let open Time in
      let s = List.assoc "" p |> Lang.to_source in
      let o =
        new Output.dummy
          ~infallible:false
          ~on_start:(fun () -> ())
          ~on_stop:(fun () -> ())
          ~autostart:true (Lang.source s)
      in
      let ratio = Lang.to_float (List.assoc "ratio" p) in
      let latency = Time.of_float (Lazy.force Frame.duration /. ratio) in
      let clock = Clock.clock ~start:false "source_dropper" in
      Clock.unify ~pos:o#pos o#clock (Clock.create_known clock);
      ignore (clock#start_outputs (fun _ -> true) ());
      log#info "Start dropping source (ratio: %.02fx)" ratio;
      while (not (Atomic.get should_stop)) && o#is_ready () do
        let start_time = Time.time () in
        clock#end_tick;
        sleep_until (start_time |+| latency)
      done;
      log#info "Source dropped.";
      o#leave s;
      Lang.unit)
