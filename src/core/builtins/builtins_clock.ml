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

let () =
  let proto =
    [
      ( "id",
        Lang.nullable_t Lang.string_t,
        Some Lang.null,
        Some
          "Identifier for the new clock. The default empty string means that \
           the identifier of the first source will be used." );
      ( "sync",
        Lang.string_t,
        Some (Lang.string "auto"),
        Some
          "Synchronization mode. One of: `\"auto\"`, `\"cpu\"`, or `\"none\"`. \
           Defaults to `\"auto\"`, which synchronizes with the CPU clock if \
           none of the active sources are attached to their own clock (e.g. \
           ALSA input, etc). `\"cpu\"` always synchronizes with the CPU clock. \
           `\"none\"` removes all synchronization control." );
    ]
  in
  let assign id sync l =
    match l with
      | [] -> Lang.unit
      | hd :: _ as sources ->
          let id = Option.value ~default:(Lang.to_source hd)#id id in
          let sync =
            match Lang.to_string sync with
              | s when s = "auto" -> `Auto
              | s when s = "cpu" -> `CPU
              | s when s = "none" -> `None
              | _ -> raise (Error.Invalid_value (sync, "Invalid sync value"))
          in
          let clock = new Clock.clock ~sync id in
          List.iter
            (fun s ->
              try
                let s = Lang.to_source s in
                Clock.unify s#clock (Clock.create_known (clock :> Clock.clock))
              with
                | Source.Clock_conflict (a, b) ->
                    raise (Error.Clock_conflict (s.Lang.pos, a, b))
                | Source.Clock_loop (a, b) ->
                    raise (Error.Clock_loop (s.Lang.pos, a, b)))
            sources;
          Lang.unit
  in
  Lang.add_builtin "clock.assign_new" ~category:`Liquidsoap
    ~descr:"Create a new clock and assign it to a list of sources."
    (proto
    @ [
        ( "",
          Lang.list_t (Lang.source_t (Lang.content_t Lang.any)),
          None,
          Some "List of sources to which the new clock will be assigned." );
      ])
    Lang.unit_t
    (fun p ->
      let id = Lang.to_valued_option Lang.to_string (List.assoc "id" p) in
      let sync = List.assoc "sync" p in
      let l = Lang.to_list (List.assoc "" p) in
      assign id sync l)

let () =
  Lang.add_builtin "clock.unify" ~category:`Liquidsoap
    ~descr:"Enforce that a list of sources all belong to the same clock."
    [("", Lang.list_t (Lang.source_t (Lang.content_t Lang.any)), None, None)]
    Lang.unit_t
    (fun p ->
      let l = List.assoc "" p in
      try
        match Lang.to_source_list l with
          | [] -> Lang.unit
          | hd :: tl ->
              List.iter (fun s -> Clock.unify hd#clock s#clock) tl;
              Lang.unit
      with
        | Source.Clock_conflict (a, b) ->
            raise (Error.Clock_conflict (l.Lang.pos, a, b))
        | Source.Clock_loop (a, b) ->
            raise (Error.Clock_loop (l.Lang.pos, a, b)))

let () =
  let t = Lang.product_t Lang.string_t Lang.int_t in
  Lang.add_builtin "clock.status" ~category:`Liquidsoap
    ~descr:"Get the current time (in clock ticks) for all allocated clocks." []
    (Lang.list_t t) (fun _ ->
      let l =
        Clock.fold
          (fun clock l ->
            Lang.product (Lang.string clock#id) (Lang.int clock#get_tick) :: l)
          []
      in
      let l =
        Lang.product (Lang.string "uptime")
          (Lang.int
             (int_of_float (Utils.uptime () /. Lazy.force Frame.duration)))
        :: l
      in
      Lang.list l)
