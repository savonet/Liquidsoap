(*****************************************************************************

  Liquidsoap, a programmable stream generator.
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

(** Generate a white noise *)

class noise ~kind duration =
  object
    inherit Synthesized.source ~seek:true ~name:"noise" kind duration

    method private synthesize frame off len =
      (try
         let off = Frame.audio_of_main off in
         let len = Frame.audio_of_main len in
         let b = AFrame.pcm frame in
         Audio.Generator.white_noise b off len
       with Frame_content.Invalid -> ());
      try
        let off = Frame.video_of_main off in
        let len = Frame.video_of_main len in
        let b = VFrame.yuva420p frame in
        Video.iter Video.Image.randomize b off len
      with Frame_content.Invalid -> ()
  end

let () =
  let kind = Lang.internal in
  let return_t = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "noise" ~category:`Input
    ~descr:"Generate audio white noise."
    [
      ( "duration",
        Lang.nullable_t Lang.float_t,
        Some Lang.null,
        Some "Duration in seconds (`null` means infinite)." );
    ]
    ~return_t
    (fun p ->
      let kind = Source.Kind.of_kind kind in
      new noise
        ~kind
        (Lang.to_valued_option Lang.to_float (List.assoc "duration" p)))
