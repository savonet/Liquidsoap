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

class on_frame ~kind f s =
  object
    inherit Source.operator ~name:"on_frame" kind [s]
    method stype = s#stype
    method is_ready = s#is_ready
    method abort_track = s#abort_track
    method remaining = s#remaining
    method seek n = s#seek n
    method self_sync = s#self_sync

    method private get_frame ab =
      s#get ab;
      ignore (Lang.apply f [])
  end

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "source.on_frame"
    [
      ("", Lang.source_t k, None, None);
      ( "",
        Lang.fun_t [] Lang.unit_t,
        None,
        Some
          "Function called on every frame. It should be fast because it is \
           executed in the main streaming thread." );
    ]
    ~category:`Track ~descr:"Call a given handler on every frame." ~return_t:k
    (fun p ->
      let s = Lang.assoc "" 1 p |> Lang.to_source in
      let f = Lang.assoc "" 2 p in
      let kind = Source.Kind.of_kind kind in
      new on_frame ~kind f s)

(** Operations on frames. *)
class frame_op ~name ~kind f default s =
  object
    inherit Source.operator ~name kind [s]
    method stype = s#stype
    method is_ready = s#is_ready
    method abort_track = s#abort_track
    method remaining = s#remaining
    method seek n = s#seek n
    method self_sync = s#self_sync
    val mutable value = default
    method value : Lang.value = value

    method private get_frame buf =
      let off = Frame.position buf in
      s#get buf;
      let pos = Frame.position buf in
      value <- f buf off (pos - off)
  end

let () = Lang.add_module "source.frame"

let op name descr f_t f default =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator ("source.frame." ^ name)
    [("", Lang.source_t k, None, None)]
    ~category:`Track ~descr
    ~return_t:(Lang.method_t k [("frame_" ^ name, ([], f_t), descr)])
    ~meth:[("frame_" ^ name, ([], f_t), descr, fun s -> s#value)]
    (fun p ->
      let s = List.assoc "" p |> Lang.to_source in
      let kind = Source.Kind.of_kind kind in
      new frame_op ~name ~kind f default s)

let () =
  op "duration" "Compute the duration of the last frame." Lang.float_t
    (fun _ _ len -> Lang.float (Frame.seconds_of_main len))
    (Lang.float 0.);
  op "rms" "Compute the rms of the last frame." Lang.float_t
    (fun buf off len ->
      let rms =
        Mm.Audio.Analyze.rms (AFrame.pcm buf) (Frame.audio_of_main off)
          (Frame.audio_of_main len)
      in
      let rms = Array.fold_left max 0. rms in
      Lang.float rms)
    (Lang.float 0.)
