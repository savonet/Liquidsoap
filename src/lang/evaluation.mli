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

(** To be filled when source values are instantiated. *)
val source_eval_check : (k:Frame.content_kind -> Value.t -> unit) ref

(** To be filled when encoder values are instantiated. *)
type encoder_params =
  (string * [ `Value of Value.t | `Encoder of encoder ]) list

and encoder = string * encoder_params

val make_encoder : (pos:Pos.Option.t -> Term.t -> encoder -> Value.t) ref
val has_encoder : (Value.t -> bool) ref
val liq_libs_dir : (unit -> string) ref
val version : (unit -> string) ref

(** Evaluate a term in a given environment. *)
val eval : ?env:(string * (Type.scheme * Value.t)) list -> Term.t -> Value.t

(** Evaluate a toplevel term. *)
val eval_toplevel : ?interactive:bool -> Term.t -> Value.t

(** Apply a function to arguments. *)
val apply : ?pos:Pos.t -> Value.t -> (string * Value.t) list -> Value.t
