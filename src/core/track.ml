(*****************************************************************************

  Liquidsoap, a programmable stream generator.
  Copyright 2003-2024 Savonet team

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

include Liquidsoap_lang.Lang_core.MkAbstract (struct
  type content = Frame.field * Source.source

  let name = "track"

  let descr (f, s) =
    Printf.sprintf "track(source=%s,field=%s)" s#id
      (Frame.Fields.string_of_field f)

  let to_json ~pos _ =
    Runtime_error.raise ~pos ~message:"Tracks cannot be represented as json"
      "json"

  let compare (f1, s1) (f2, s2) = Stdlib.compare (f1, s1#id) (f2, s2#id)
  let comparison_op = None
end)
