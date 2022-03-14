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

open Source

type mode = Encode | Decode

class msstereo ~kind (source : source) mode width =
  object
    inherit operator ~name:"stereo.ms.encode" kind [source]
    method stype = source#stype
    method is_ready = source#is_ready
    method remaining = source#remaining
    method seek = source#seek
    method self_sync = source#self_sync
    method abort_track = source#abort_track

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let buffer = AFrame.pcm buf in
      for i = offset to AFrame.position buf - 1 do
        match mode with
          | Encode ->
              let left = buffer.(0).(i) and right = buffer.(1).(i) in
              buffer.(0).(i) <- 0.5 *. (left +. right);

              (* mid *)
              buffer.(1).(i) <- 0.5 *. (left -. right)
              (* side *)
          | Decode ->
              let mid = buffer.(0).(i) and side = buffer.(1).(i) in
              buffer.(0).(i) <- mid +. (side *. width);

              (* left *)
              buffer.(1).(i) <- mid -. (side *. width)
        (* right *)
      done
  end

let () =
  Lang.add_module "stereo.ms";
  let kind = Lang.audio_stereo in
  let return_t = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "stereo.ms.encode"
    [("", Lang.source_t return_t, None, None)]
    ~return_t ~category:`Audio
    ~descr:"Encode left+right stereo to mid+side stereo (M/S)."
    (fun p ->
      let s = Lang.to_source (Lang.assoc "" 1 p) in
      let kind = Source.Kind.of_kind kind in
      new msstereo ~kind s Encode 0.);
  Lang.add_operator "stereo.ms.decode"
    [
      ( "width",
        Lang.float_t,
        Some (Lang.float 1.),
        Some "Width of the stereo field." );
      ("", Lang.source_t return_t, None, None);
    ]
    ~return_t ~category:`Audio
    ~descr:"Decode mid+side stereo (M/S) to left+right stereo."
    (fun p ->
      let s = Lang.to_source (Lang.assoc "" 1 p) in
      let w = Lang.to_float (Lang.assoc "width" 1 p) in
      let kind = Source.Kind.of_kind kind in
      new msstereo ~kind s Decode w)

class spatializer ~kind ~width (source : source) =
  object
    inherit operator ~name:"stereo.width" kind [source]
    method stype = source#stype
    method is_ready = source#is_ready
    method remaining = source#remaining
    method seek = source#seek
    method self_sync = source#self_sync
    method abort_track = source#abort_track

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let position = AFrame.position buf in
      let buf = AFrame.pcm buf in
      let width = width () in
      let width = (width +. 1.) /. 2. in
      let a =
        let w = width in
        let w' = 1. -. width in
        w /. sqrt ((w *. w) +. (w' *. w'))
      in
      for i = offset to position - 1 do
        let left = buf.(0).(i) in
        let right = buf.(1).(i) in
        let mid = (left +. right) /. 2. in
        let side = (left -. right) /. 2. in
        buf.(0).(i) <- ((1. -. a) *. mid) -. (a *. side);
        buf.(1).(i) <- ((1. -. a) *. mid) +. (a *. side)
      done
  end

let () =
  let kind = Lang.audio_stereo in
  let return_t = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "stereo.width"
    [
      ( "",
        Lang.getter_t Lang.float_t,
        Some (Lang.float 0.),
        Some "Width of the signal (-1: mono, 0.: original, 1.: wide stereo)." );
      ("", Lang.source_t return_t, None, None);
    ]
    ~return_t ~category:`Audio
    ~descr:"Spacializer which allows controlling the width of the signal."
    (fun p ->
      let width = Lang.assoc "" 1 p |> Lang.to_float_getter in
      let s = Lang.assoc "" 2 p |> Lang.to_source in
      let kind = Source.Kind.of_kind kind in
      new spatializer ~kind ~width s)
