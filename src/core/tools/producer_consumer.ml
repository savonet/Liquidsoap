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

module Generator = Generator.From_audio_video

type write_payload = [ `Frame of Frame.t | `Flush ]
type write_frame = write_payload -> unit

let write_to_buffer ~content g = function
  | `Frame frame ->
      Generator.feed_from_frame ~mode:content g frame;
      let excess = Generator.length g - Lazy.force Frame.size in
      if 0 < excess then Generator.remove g excess
  | `Flush -> ()

(* This here is tricky:
 * - We want to use the output API to have a method for
 *   generating data when calling a clock tick.
 * - We want to opt-out of the generic child_process
 *   clock animation framework.
 * Thus, we manually mark this operator as ready only
 * before we're about to pull from it. *)
class consumer ~write_frame ~name ~kind ~source () =
  let s = Lang.to_source source in
  let infallible = s#stype = `Infallible in
  let noop () = () in
  object
    inherit
      Output.output
        ~content_kind:kind ~output_kind:name ~infallible ~on_start:noop
          ~on_stop:noop source true as super

    val mutable output_enabled = false
    method set_output_enabled v = output_enabled <- v
    method reset = ()
    method start = ()
    method stop = write_frame `Flush
    method output = if output_enabled then super#output
    method private send_frame frame = write_frame (`Frame frame)
  end

(** The source which produces data by reading the buffer.
    We do NOT want to use [operator] here b/c the [consumers]
    may have different content-kind when this is used in the muxers. *)
class producer ~check_self_sync ~consumers ~name ~kind g =
  let infallible = List.for_all (fun s -> s#stype = `Infallible) consumers in
  let self_sync_type = Utils.self_sync_type consumers in
  object (self)
    inherit Source.source kind ~name as super

    inherit
      Child_support.base
        ~check_self_sync
        (List.map (fun s -> Lang.source (s :> Source.source)) consumers) as child_support

    method self_sync =
      ( Lazy.force self_sync_type,
        List.fold_left (fun cur s -> cur || snd s#self_sync) false consumers )

    method stype = if infallible then `Infallible else `Fallible

    method seek len =
      let len = min (Generator.length g) len in
      Generator.remove g len;
      len

    method remaining =
      match List.fold_left (fun r p -> min r p#remaining) (-1) consumers with
        | -1 -> -1
        | r -> Generator.remaining g + r

    method is_ready = List.for_all (fun c -> c#is_ready) consumers

    method wake_up a =
      super#wake_up a;
      List.iter
        (fun c -> c#get_ready ?dynamic:None [(self :> Source.source)])
        consumers

    method sleep =
      super#sleep;
      List.iter
        (fun c ->
          c#leave ?failed_to_start:None ?dynamic:None (self :> Source.source))
        consumers

    method private get_frame buf =
      let b = Frame.breaks buf in
      List.iter (fun c -> c#set_output_enabled true) consumers;
      while Generator.length g < Lazy.force Frame.size && self#is_ready do
        self#child_tick
      done;
      List.iter (fun c -> c#set_output_enabled false) consumers;
      Generator.fill g buf;
      if List.length b + 1 <> List.length (Frame.breaks buf) then (
        let cur_pos = Frame.position buf in
        Frame.set_breaks buf (b @ [cur_pos]))

    method before_output =
      super#before_output;
      child_support#before_output

    method after_output =
      super#after_output;
      child_support#after_output

    method abort_track =
      Generator.add_break g;
      List.iter (fun c -> c#abort_track) consumers
  end
