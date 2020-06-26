(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

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

include Frame_settings
open Frame_content

(** Data types *)

type 'a fields = { audio : 'a; video : 'a; midi : 'a }

(** High-level description of the content. *)
type kind = [ `Any | `Internal | `Format of format | `Params of params ]

let none = `Params Frame_content.None.params

let audio_pcm =
  `Format (Frame_content.Audio.lift_format Frame_content.Audio.format)

let audio_n = function
  | 0 -> none
  | c ->
      `Params
        (Frame_content.Audio.lift_params
           [Audio_converter.Channel_layout.layout_of_channels c])

let audio_mono = `Params (Frame_content.Audio.lift_params [`Mono])
let audio_stereo = `Params (Frame_content.Audio.lift_params [`Stereo])

let video_yuv420p =
  `Format (Frame_content.Video.lift_format Frame_content.Video.format)

let midi_native =
  `Format (Frame_content.Midi.lift_format Frame_content.Midi.format)

let midi_n c = `Params (Frame_content.Midi.lift_params [`Channels c])

type content_kind = kind fields

(** Precise description of the channel types for the current track. *)
type content_type = params fields

type content = data fields

(** Compatibilities between content kinds, types and values.
  * [sub a b] if [a] is more permissive than [b]..
  * TODO this is the other way around... it's correct in Lang, phew! *)

let map_fields fn c =
  { audio = fn c.audio; video = fn c.video; midi = fn c.midi }

let type_of_content = map_fields params

let string_of_params p =
  let format = Frame_content.format p in
  match Frame_content.string_of_params p with
    | "" -> Frame_content.string_of_format format
    | s -> Printf.sprintf "%s(%s)" (Frame_content.string_of_format format) s

let string_of_kind = function
  | `Any -> "any"
  | `Internal -> "internal"
  | `Params p -> string_of_params p
  | `Format f -> string_of_format f

let string_of_fields fn { audio; video; midi } =
  Printf.sprintf "{audio=%s,video=%s,midi=%s}" (fn audio) (fn video) (fn midi)

let string_of_content_kind = string_of_fields string_of_kind
let string_of_content_type = string_of_fields string_of_params

(* Frames *)

(** A metadata is just a mutable hash table.
  * It might be a good idea to straighten that up in the future. *)
type metadata = (string, string) Hashtbl.t

type t = {
  (* Presentation time, in multiple of frame size. *)
  mutable pts : int64;
  (* End of track markers.
   * A break at the end of the buffer is not an end of track.
   * So maybe we should rather call that an end-of-fill marker,
   * and notice that end-of-fills in the middle of a buffer are
   * end-of-tracks.
   * If needed, the end-of-track needs to be put at the beginning of
   * the next frame. *)
  mutable breaks : int list;
  (* Metadata can be put anywhere in the stream. *)
  mutable metadata : (int * metadata) list;
  mutable content : content;
}

(** Create a content chunk. All chunks have the same size. *)
let create_content = map_fields make

let create ctype =
  { pts = 0L; breaks = []; metadata = []; content = create_content ctype }

let dummy =
  let data = Frame_content.None.data in
  {
    pts = 0L;
    breaks = [];
    metadata = [];
    content = { audio = data; video = data; midi = data };
  }

let content_type { content } = map_fields params content
let audio { content; _ } = content.audio
let set_audio frame audio = frame.content <- { frame.content with audio }
let video { content; _ } = content.video
let set_video frame video = frame.content <- { frame.content with video }
let midi { content; _ } = content.midi
let set_midi frame midi = frame.content <- { frame.content with midi }

(** Content independent *)

let position b = match b.breaks with [] -> 0 | a :: _ -> a
let is_partial b = position b < !!size
let breaks b = b.breaks
let set_breaks b breaks = b.breaks <- breaks
let add_break b br = b.breaks <- br :: b.breaks

let clear (b : t) =
  b.breaks <- [];
  b.metadata <- []

let clear_from (b : t) pos =
  b.breaks <- List.filter (fun p -> p <= pos) b.breaks;
  b.metadata <- List.filter (fun (p, _) -> p <= pos) b.metadata

(* Same as clear but leaves the last metadata at position -1. *)
let advance b =
  b.pts <- Int64.succ b.pts;
  b.breaks <- [];
  let max a (p, m) =
    match a with Some (pa, _) when pa > p -> a | _ -> Some (p, m)
  in
  let rec last a = function [] -> a | b :: l -> last (max a b) l in
  b.metadata <-
    (match last None b.metadata with None -> [] | Some (_, e) -> [(-1, e)])

(** Presentation time stuff. *)

let pts { pts } = pts
let set_pts frame pts = frame.pts <- pts

(** Metadata stuff *)

exception No_metadata

let set_metadata b t m = b.metadata <- (t, m) :: b.metadata

let get_metadata b t =
  try Some (List.assoc t b.metadata) with Not_found -> None

let free_metadata b t =
  b.metadata <- List.filter (fun (tt, _) -> t <> tt) b.metadata

let free_all_metadata b = b.metadata <- []

let get_all_metadata b =
  List.sort
    (fun (x, _) (y, _) -> compare x y)
    (List.filter (fun (x, _) -> x <> -1) b.metadata)

let set_all_metadata b l = b.metadata <- l

let get_past_metadata b =
  try Some (List.assoc (-1) b.metadata) with Not_found -> None

let blit_content src src_pos dst dst_pos len =
  let blit src dst = blit src src_pos dst dst_pos len in
  blit src.audio dst.audio;
  blit src.video dst.video;
  blit src.midi dst.midi

(** Copy data from [src] to [dst].
  * This triggers changes of contents layout if needed. *)
let blit src src_pos dst dst_pos len =
  (* Assuming that the tracks have the same track layout,
   * copy a chunk of data from [src] to [dst]. *)
  blit_content src.content src_pos dst.content dst_pos len

(** Raised by [get_chunk] when no chunk is available. *)
exception No_chunk

(** [get_chunk dst src] gets the (end of) next chunk from [src]
  * (a chunk is a region of a frame between two breaks).
  * Metadata relevant to the copied chunk is copied as well,
  * and content layout is changed if needed. *)
let get_chunk ab from =
  assert (is_partial ab);
  let p = position ab in
  let copy_chunk i =
    add_break ab i;
    blit from p ab p (i - p);

    (* If the last metadata before [p] differ in [from] and [ab],
     * copy the one from [from] to [p] in [ab].
     * Note: equality probably does not make much sense for hash tables,
     * but even physical equality should work here, it seems.. *)
    begin
      let before_p l =
        match
          List.sort
            (fun (a, _) (b, _) -> compare b a) (* the greatest *)
            (List.filter (fun x -> fst x < p) l)
          (* that is less than p *)
        with
          | [] -> None
          | x :: _ -> Some (snd x)
      in
      match (before_p from.metadata, before_p ab.metadata) with
        | Some b, a -> if a <> Some b then set_metadata ab p b
        | None, _ -> ()
    end;

    (* Copy new metadata blocks for this chunk.
     * We exclude blocks at the end of chunk, leaving them to be copied
     * during the next get_chunk. *)
    List.iter
      (fun (mp, m) -> if p <= mp && mp < i then set_metadata ab mp m)
      from.metadata
  in
  let rec aux foffset f =
    (* We always have p >= foffset *)
    match f with
      | [] -> raise No_chunk
      | i :: tl ->
          (* Breaks are between ticks, they do range from 0 to size. *)
          assert (0 <= i && i <= !!size);
          if i = 0 && ab.breaks = [] then
            (* The only empty track that we copy,
             * trying to copy empty tracks in the middle could be useful
             * for packets like those forged by add, with a fake first break,
             * but isn't needed (yet) and is painful to implement. *)
            copy_chunk 0
          else if foffset <= p && i > p then copy_chunk i
          else aux i tl
  in
  aux 0 (List.rev from.breaks)

let copy = map_fields copy
