(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

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

(** {1 Functions for typing} *)

open Type

(** A typing environment. *)
type env = (string * scheme) list

(** Instantiate a type. *)
val instantiate : level:int -> generalized:var list -> t -> t

(** Find all generalizable variables. *)
val generalizable : level:int -> t -> var list

type explanation

exception Type_Error of explanation

val print_type_error : (string -> unit) -> explanation -> unit

(** Subtyping. *)
val ( <: ) : t -> t -> unit

(** Suptyping. *)
val ( >: ) : t -> t -> unit

(** Minimum of two types. *)
val min_type : ?pos:pos option -> ?level:int -> t -> t -> t
