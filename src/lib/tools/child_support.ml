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

(** Utility for operators that need to control child source clocks. See [clock.mli]
    for a more detailed description. *)

let finalise_child_clock child_clock source =
  Clock.forget source#clock child_clock

class virtual base ~check_self_sync children_val =
  let children = List.map Lang.to_source children_val in
  object (self)
    initializer
    if check_self_sync then
      List.iter
        (fun c ->
          if (Lang.to_source c)#self_sync <> (`Static, false) then
            raise
              (Error.Invalid_value
                 ( c,
                   "This source may control its own latency and cannot be used \
                    with this operator." )))
        children_val

    val mutable child_clock = None

    (* If [true] during [#after_output], issue a [#end_tick] call
       on the child clock, which makes it perform a whole streaming
       loop. *)
    val mutable needs_tick = true
    method virtual id : string
    method virtual clock : Source.clock_variable
    method private child_clock = Option.get child_clock

    method private set_clock =
      child_clock <-
        Some
          (Clock.create_known
             (new Clock.clock ~start:false (Printf.sprintf "%s.child" self#id)));

      Clock.unify self#clock
        (Clock.create_unknown ~sources:[] ~sub_clocks:[self#child_clock]);

      List.iter (fun c -> Clock.unify self#child_clock c#clock) children;

      Gc.finalise (finalise_child_clock self#child_clock) self

    method private child_tick =
      (Clock.get self#child_clock)#end_tick;
      List.iter (fun c -> c#after_output) children;
      needs_tick <- false

    (* This methods always set [need_tick] to true. If the source is not
       [#is_ready], [#after_output] is called during a clock tick,
       which means that the children clock is _always_ animated by the
       main clock when the source becomes unavailable. Otherwise, we
       expect the source to make a decision about executing a child clock
       tick as part of its [#get_frame] implementation. See [cross.ml] or
       [soundtouch.ml] as examples. *)
    method before_output = needs_tick <- true
    method after_output = if needs_tick then self#child_tick
  end
