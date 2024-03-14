(*****************************************************************************

  Liquidsoap, a programmable stream generator.
  Copyright 20032024 Savonet team

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
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 021101301  USA

 *****************************************************************************)

let clock =
  Lang.add_builtin "clock" ~category:`Liquidsoap
    ~descr:"Decorate a clock with all its methods."
    [("", Lang_source.ClockValue.base_t, None, None)]
    Lang_source.ClockValue.t
    (fun p -> Lang_source.ClockValue.(to_value (of_value (List.assoc "" p))))

let autostart =
  Lang.add_builtin ~base:clock "autostart" ~category:`Liquidsoap
    ~descr:
      "`true` if clocks start automatically when new output and sources are \
       created." [] Lang.bool_t (fun _ -> Lang.bool (Clock.autostart ()))

let _ =
  Lang.add_builtin ~base:autostart "set" ~category:`Liquidsoap
    ~descr:"Set clock autostart."
    [("", Lang.bool_t, None, None)]
    Lang.unit_t
    (fun p ->
      Clock.set_autostart (Lang.to_bool (List.assoc "" p));
      Lang.unit)

let _ =
  Lang.add_builtin ~base:clock "create" ~category:`Liquidsoap
    ~descr:"Create a new clock"
    [
      ( "id",
        Lang.nullable_t Lang.string_t,
        Some Lang.null,
        Some "Identifier for the new clock." );
      ( "sync",
        Lang.string_t,
        Some (Lang.string "auto"),
        Some
          "Clock sync mode. Should be one of: `\"auto\"`, `\"CPU\"`, \
           `\"unsynced\"` or `\"passive\"`. Defaults to `\"auto\"`. Defaults \
           to: \"auto\"" );
    ]
    Lang_source.ClockValue.t
    (fun p ->
      let id = Lang.to_valued_option Lang.to_string (List.assoc "id" p) in
      let sync = List.assoc "sync" p in
      let sync =
        try Clock.active_sync_mode_of_string (Lang.to_string sync)
        with _ ->
          raise
            (Error.Invalid_value
               ( sync,
                 "Invalid sync mode! Should be one of: `\"auto\"`, `\"CPU\"`, \
                  `\"unsynced\"` or `\"passive\"`" ))
      in
      let pos = match Lang.pos p with p :: _ -> Some p | [] -> None in
      Lang_source.ClockValue.to_value (Clock.create ?pos ?id ~sync ()))
