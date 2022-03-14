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

class mean ~normalize source =
  object
    inherit
      operator
        ~audio_in:Frame.audio_pcm
        (Source.Kind.of_kind Lang.audio_mono)
        [source] ~name:"mean"

    inherit
      Conversion.base
        ~audio:true source
        ~converter:(fun ~frame tmp_frame ->
          (* Compute the mean of audio channels *)
          let start = Frame.position frame in
          let len = Frame.position tmp_frame - start in
          let content = AFrame.pcm frame in
          let tmp_content = AFrame.pcm tmp_frame in
          let amp =
            if normalize then 1. /. float (Array.length tmp_content) else 1.
          in
          let ( ! ) = Frame.audio_of_main in
          for i = !start to !(start + len) - 1 do
            content.(0).(i) <-
              Array.fold_left (fun m b -> m +. b.(i)) 0. tmp_content *. amp
          done;
          Frame.set_audio frame (Frame_content.Audio.lift_data content))
  end

let () =
  let in_kind =
    Lang.frame_kind_t
      ~audio:(Lang.kind_t Frame.audio_pcm)
      ~video:(Lang.univ_t ()) ~midi:(Lang.univ_t ())
  in
  let out_kind =
    let { Frame.video; midi } = Lang.of_frame_kind_t in_kind in
    Lang.frame_kind_t ~audio:(Lang.kind_t Frame.audio_mono) ~video ~midi
  in
  Lang.add_operator "mean"
    [
      ( "normalize",
        Lang.bool_t,
        Some (Lang.bool true),
        Some "Divide the output volume by the number of channels." );
      ( "",
        Lang.source_t in_kind,
        None,
        Some "Source whose mean should be computed." );
    ]
    ~return_t:out_kind ~category:`Conversion
    ~descr:"Produce mono audio by taking the mean of all audio channels."
    (fun p ->
      let normalize = Lang.to_bool (List.assoc "normalize" p) in
      let s = Lang.to_source (Lang.assoc "" 1 p) in
      (new mean ~normalize s :> Source.source))
