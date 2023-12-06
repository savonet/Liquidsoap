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

class on_end ~delay f s =
  object (self)
    inherit Source.operator ~name:"on_end" [s]
    inherit Latest_metadata.source
    val mutable executed = false
    method stype = s#stype
    method private can_generate_data = s#is_ready
    method remaining = s#remaining
    method abort_track = s#abort_track
    method seek_source = s#seek_source
    method self_sync = s#self_sync
    method private on_new_metadata = ()

    method private generate_data =
      let buf = s#get_data in
      self#save_latest_metadata buf;
      let rem = Frame.seconds_of_main s#remaining in
      if (not executed) && ((0. <= rem && rem <= delay ()) || s#has_track_mark)
      then (
        ignore
          (Lang.apply f
             [("", Lang.float rem); ("", Lang.metadata latest_metadata)]);
        executed <- true);
      if s#has_track_mark then (
        self#clear_latest_metadata;
        executed <- false);
      buf
  end

let _ =
  let return_t = Lang.frame_t (Lang.univ_t ()) Frame.Fields.empty in
  Lang.add_operator ~base:Muxer.source "on_end"
    [
      ( "delay",
        Lang.getter_t Lang.float_t,
        Some (Lang.float 5.),
        Some
          "Execute handler when remaining time is less or equal to this value."
      );
      ("", Lang.source_t return_t, None, None);
      ( "",
        Lang.fun_t
          [(false, "", Lang.float_t); (false, "", Lang.metadata_t)]
          Lang.unit_t,
        None,
        Some
          "Function to execute. First argument is the remaining time, second \
           is the latest metadata. That function should be fast because it is \
           executed in the main streaming thread." );
    ]
    ~category:`Track
    ~descr:
      "Call a given handler when there is less than a given amount of time \
       remaining before then end of track."
    ~return_t
    (fun p ->
      let delay = Lang.to_float_getter (List.assoc "delay" p) in
      let s = Lang.assoc "" 1 p |> Lang.to_source in
      let f = Lang.assoc "" 2 p in
      new on_end ~delay f s)
