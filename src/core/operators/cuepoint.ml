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

open Source

(* The [cue_cut] class is able to skip over the beginning and end
 * of a track according to cue points. *)

(** For each track, the state may be:
  *  - `Idle if no track has started
  *  - `No_cue_out
  *  - `Cue_out (elapsed,cue_out))
  *    if a cue_out point has been set,
  *    where both positions (current and end position) are given
  *    relative to the beginning of the track (not relative to cue_in).
  * There is no need to store cue_in point information as it is
  * performed immediately. *)
type state = [ `Idle | `No_cue_out | `Cue_out of int * int ]

class cue_cut ~m_cue_in ~m_cue_out ~on_cue_in ~on_cue_out source_val =
  let source = Lang.to_source source_val in
  object (self)
    inherit operator ~name:"cue_cut" [source]
    inherit! Child_support.base ~check_self_sync:true [source_val]
    val mutable state : state = `Idle
    method stype = source#stype
    method private can_generate_data = source#is_ready
    method abort_track = source#abort_track
    method self_sync = source#self_sync
    method seek_source = source#seek_source

    method remaining =
      let source_remaining = source#remaining in
      match state with
        | `Idle | `No_cue_out -> source#remaining
        | `Cue_out (elapsed, cue_out) ->
            let target = cue_out - elapsed in
            if source_remaining = -1 then target
            else min source#remaining target

    method private get_cue_points buf =
      match Frame.get_metadata buf 0 with
        | None -> (None, None)
        | Some table ->
            let get key =
              try
                let content = Frame.Metadata.find key table in
                try Some (Frame.main_of_seconds (float_of_string content))
                with _ ->
                  self#log#severe "Ill-formed metadata %s=%S!" key content;
                  None
              with Not_found -> None
            in
            let cue_in = get m_cue_in in
            let cue_out = get m_cue_out in
            (* Sanity checks
             * We ignore invalid values rather than setting
             * cue-out = cue-in since this would result in empty
             * tracks and potential loops. *)
            let cue_in =
              match cue_in with
                | Some i when i <= 0 ->
                    if i < 0 then
                      self#log#severe "Ignoring negative cue-in point.";
                    None
                | i -> i
            in
            let cue_out =
              match (cue_in, cue_out) with
                | Some i, Some o when o < i ->
                    self#log#severe
                      "Ignoring cue-out point before cue-in. Note that cue-out \
                       should be given relative to the beginning of the file.";
                    None
                | None, Some o when o < 0 ->
                    self#log#severe "Ignoring negative cue-out point.";
                    None
                | _, cue_out -> cue_out
            in
            self#log#info "Cue points : %s / %s"
              (match cue_in with
                | None -> "none"
                | Some t -> string_of_float (Frame.seconds_of_main t))
              (match cue_out with
                | None -> "none"
                | Some t -> string_of_float (Frame.seconds_of_main t));
            (cue_in, cue_out)

    method private cue_in ?(in_pos = 0) ?out_pos buf =
      self#log#important "Cueing in...";
      on_cue_in ();
      let length = Frame.position buf in
      let seek_pos = in_pos - length in

      let buf, elapsed =
        if seek_pos > 0 then (
          let seeked_pos = source#seek seek_pos in
          if seeked_pos <> seek_pos then
            self#log#info "Seeked to %.03f instead of %.03f"
              (Frame.seconds_of_main (seeked_pos + length))
              (Frame.seconds_of_main in_pos);

          let buf = self#child_get in
          let new_pos = Frame.position buf in

          (buf, length + seeked_pos + new_pos))
        else (
          if in_pos > 0 then
            self#log#info
              "Cue-in point %.03f is already past current position %.03f"
              (Frame.seconds_of_main in_pos)
              (Frame.seconds_of_main length);
          (buf, length))
      in

      match out_pos with
        | None ->
            state <- `No_cue_out;
            buf
        | Some pos when pos < elapsed ->
            self#log#important
              "Initial seek reached %i ticks past cue-out point!" (elapsed - pos);
            self#cue_out
        | Some pos ->
            state <- `Cue_out (elapsed, pos);
            buf

    method private cue_out =
      self#log#important "Cueing out...";
      source#abort_track;
      on_cue_out ();
      state <- `Idle;
      if source#is_ready then self#generate_data else self#empty_frame

    method private child_get =
      if source#is_ready then (
        let frame = ref self#empty_frame in
        self#child_on_output (fun () -> frame := source#get_data);
        let frame = !frame in
        match Frame.track_marks frame with
          | p :: _ :: _ ->
              self#log#important
                "Source created multiple tracks in a single frame! Sub-frame \
                 tracks cannot be handled by this operator and are merged into \
                 a single one..";
              Frame.add_track_mark (Frame.drop_track_marks frame) p
          | _ -> frame)
      else self#empty_frame

    method private split_frame buf_frame =
      match Frame.track_marks buf_frame with
        | p :: _ ->
            ( Frame.slice buf_frame p,
              Some
                (Frame.chunk ~start:p ~stop:(Frame.position buf_frame) buf_frame)
            )
        | [] -> (buf_frame, None)

    method private generate_data =
      let frame = self#child_get in
      let buf, next_frame = self#split_frame frame in
      let length = Frame.position buf in
      match (next_frame, state) with
        | Some buf, _ ->
            (match state with
              | `Cue_out (elapsed, cue_out) ->
                  if elapsed + length < cue_out then
                    self#log#important
                      "End of track reached before cue-out point."
              | _ -> ());
            let in_pos, out_pos = self#get_cue_points buf in
            if in_pos <> None then
              self#log#debug "Cue in at %.03f s."
                (Option.get in_pos |> Frame.seconds_of_main);

            if out_pos <> None then
              self#log#debug "Cue out at %.03f s."
                (Option.get out_pos |> Frame.seconds_of_main);

            self#cue_in ?in_pos ?out_pos buf
        | None, `Idle | None, `No_cue_out -> frame
        | None, `Cue_out (elapsed, cue_out) when cue_out < elapsed + length ->
            self#cue_out
        | None, `Cue_out (elapsed, cue_out) ->
            state <- `Cue_out (elapsed + length, cue_out);
            frame
  end

let _ =
  let return_t = Lang.frame_t (Lang.univ_t ()) Frame.Fields.empty in
  Lang.add_operator "cue_cut" ~return_t ~category:`Track
    ~descr:
      "Start track after a cue in point and stop it at cue out point. The cue \
       points are given as metadata, in seconds from the beginning of tracks."
    [
      ( "cue_in_metadata",
        Lang.string_t,
        Some (Lang.string "liq_cue_in"),
        Some "Metadata for cue in points." );
      ( "cue_out_metadata",
        Lang.string_t,
        Some (Lang.string "liq_cue_out"),
        Some "Metadata for cue out points." );
      ( "on_cue_in",
        Lang.fun_t [] Lang.unit_t,
        Some (Lang.val_cst_fun [] Lang.unit),
        Some "Callback to execute on cue in" );
      ( "on_cue_out",
        Lang.fun_t [] Lang.unit_t,
        Some (Lang.val_cst_fun [] Lang.unit),
        Some "Callback to execute on cue out" );
      ("", Lang.source_t return_t, None, None);
    ]
    (fun p ->
      let m_cue_in = Lang.to_string (Lang.assoc "cue_in_metadata" 1 p) in
      let m_cue_out = Lang.to_string (Lang.assoc "cue_out_metadata" 1 p) in
      let on_cue_in = Lang.assoc "on_cue_in" 1 p in
      let on_cue_in () = ignore (Lang.apply on_cue_in []) in
      let on_cue_out = Lang.assoc "on_cue_out" 1 p in
      let on_cue_out () = ignore (Lang.apply on_cue_out []) in
      let s = Lang.assoc "" 1 p in
      new cue_cut ~m_cue_in ~m_cue_out ~on_cue_in ~on_cue_out s)
