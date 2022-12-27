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

(** A frame kind type is a purely abstract type representing a
    frame kind. *)
let frame_t ?pos audio video midi =
  Type.make ?pos
    (Type.Constr
       {
         Type.constructor = "stream_kind";
         Type.params =
           [(`Covariant, audio); (`Covariant, video); (`Covariant, midi)];
       })

(** Type of audio formats that can encode frame of a given kind. *)
let format_t ?pos k =
  Type.make ?pos
    (Type.Constr
       { Type.constructor = "format"; Type.params = [(`Covariant, k)] })
