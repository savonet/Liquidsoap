(*****************************************************************************

  Liquidsoap, a programmable stream generator.
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
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

class merge_metadata tracks =
  let sources = List.map snd tracks in
  let self_sync_type = Utils.self_sync_type sources in
  object (self)
    inherit Source.operator ~name:"track.metadata.merge" sources
    initializer Typing.(self#frame_type <: Lang.unit_t)
    method stype = `Infallible

    method self_sync =
      ( Lazy.force self_sync_type,
        List.exists (fun s -> s#is_ready && snd s#self_sync) sources )

    method abort_track = List.iter (fun s -> s#abort_track) sources
    method private can_generate_frame = true

    method seek_source =
      match List.filter (fun s -> s#is_ready) sources with
        | s :: [] -> s
        | _ -> (self :> Source.source)

    method remaining = -1

    method private generate_frame =
      List.fold_left
        (fun frame source ->
          if source#is_ready then
            Frame.add_all_metadata frame
              (Frame.get_all_metadata source#get_frame)
          else frame)
        (Frame.create ~length:(Lazy.force Frame.size) self#content_type)
        sources
  end

let _ =
  let metadata_t = Format_type.metadata in
  Lang.add_track_operator ~base:Muxer.track_metadata "merge" ~category:`Track
    ~descr:
      "Merge metadata from all given tracks. If two sources have metadata with \
       the same label at the same time, the one from the last source in the \
       list takes precedence."
    ~return_t:metadata_t
    [("", Lang.list_t metadata_t, None, None)]
    (fun p ->
      let tracks = List.map Lang.to_track (Lang.to_list (List.assoc "" p)) in
      (Frame.Fields.metadata, new merge_metadata tracks))
