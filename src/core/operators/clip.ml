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

open Mm
open Source

class clip ~field (source : source) =
  object
    inherit operator ~name:"clip" [source]
    method stype = source#stype
    method remaining = source#remaining
    method seek = source#seek
    method seek_source = source
    method private _is_ready = source#is_ready
    method abort_track = source#abort_track
    method self_sync = source#self_sync

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let b = Content.Audio.get_data (Frame.get buf field) in
      let position = AFrame.position buf in
      Audio.clip b offset (position - offset)
  end

let _ =
  let frame_t = Format_type.audio () in
  Lang.add_track_operator ~base:Modules.track_audio "clip"
    [("", frame_t, None, None)]
    ~return_t:frame_t ~category:`Audio
    ~descr:
      "Clip samples, i.e. ensure that all values are between -1 and 1: values \
       lower than -1 become -1 and values higher than 1 become 1. `nan` values \
       become `0.`"
    (fun p ->
      let f v = List.assoc v p in
      let field, src = Lang.to_track (f "") in
      (field, new clip ~field src))
