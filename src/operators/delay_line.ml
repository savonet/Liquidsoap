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
open Source

class delay ~kind (source : source) duration =
  let length () = Frame.audio_of_seconds (duration ()) in
  object (self)
    inherit operator ~name:"amplify" kind [source] as super
    val mutable override = None
    method stype = source#stype
    method is_ready = source#is_ready
    method remaining = source#remaining
    method abort_track = source#abort_track
    method seek = source#seek
    method self_sync = source#self_sync

    (** Length of the buffer in samples. *)
    val mutable buffer_length = 0

    (** Ringbuffer. *)
    val mutable buffer = [||]

    (** Position in the buffer. *)
    val mutable pos = 0

    (** Make sure that the buffer has required size. *)
    method prepare n =
      if buffer_length <> n then (
        buffer <- Audio.create self#audio_channels n;
        buffer_length <- n)

    method wake_up a =
      super#wake_up a;
      self#prepare (length ())

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let position = AFrame.position buf in
      let buf = AFrame.pcm buf in
      let length = length () in
      self#prepare length;
      if length > 0 then
        for i = offset to position - 1 do
          for c = 0 to self#audio_channels - 1 do
            let x = buf.(c).(i) in
            buf.(c).(i) <- buffer.(c).(pos);
            buffer.(c).(pos) <- x
          done;
          pos <- (pos + 1) mod length
        done
  end

let () =
  let kind = Lang.audio_pcm in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "delay_line"
    [
      ( "",
        Lang.getter_t Lang.float_t,
        None,
        Some "Duration of the delay in seconds." );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio
    ~descr:"Delay the audio signal by a given amount of time."
    (fun p ->
      let duration = Lang.assoc "" 1 p |> Lang.to_float_getter in
      let s = Lang.assoc "" 2 p |> Lang.to_source in
      let kind = Source.Kind.of_kind kind in
      new delay ~kind s duration)
