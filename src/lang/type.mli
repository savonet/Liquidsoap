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

(** Show debugging information. *)
val debug : bool ref

(** Show variables levels. *)
val debug_levels : bool ref

(** {1 Positions} *)

type pos = Lexing.position * Lexing.position

val print_single_pos : Lexing.position -> string
val print_pos : ?prefix:string -> pos -> string
val print_pos_opt : ?prefix:string -> pos option -> string
val print_pos_list : ?prefix:string -> pos list -> string

(** {1 Ground types} *)

type variance = Covariant | Contravariant | Invariant
type ground = ..

type ground +=
  | Bool
  | Int
  | String
  | Float
  | Request
  | Format of Frame_content.format

val register_ground_printer : (ground -> string option) -> unit
val print_ground : ground -> string
val register_ground_resolver : (string -> ground option) -> unit
val resolve_ground : string -> ground
val resolve_ground_opt : string -> ground option

(** {1 Types} *)

type constr = Num | Ord | Dtools | InternalMedia
type constraints = constr list

val print_constr : constr -> string

type t = { pos : pos option; descr : descr }

and constructed = { constructor : string; params : (variance * t) list }

and meth = {
  meth : string;
  scheme : scheme;
  doc : string;
  json_name : string option;
}

and repr_t = { t : t; json_repr : [ `Tuple | `Object ] }

and descr =
  | Constr of constructed
  | Ground of ground
  | Getter of t
  | List of repr_t
  | Tuple of t list
  | Nullable of t
  | Meth of meth * t
  | Arrow of (bool * string * t) list * t
  | Var of invar ref

and invar = Free of var | Link of variance * t

and var = { name : int; mutable level : int; mutable constraints : constraints }

and scheme = var list * t

val unit : descr

(** Create a type from its value. *)
val make : ?pos:pos -> descr -> t

(** Remove links in a type: this function should always be called before
    matching on types. *)
val deref : t -> t

(** Create a fresh variable. *)
val var : ?constraints:constraints -> ?level:int -> ?pos:pos -> unit -> t

(** Compare two variables for equality. This comparison should always be used to
    compare variables (as opposed to =). *)
val var_eq : var -> var -> bool

(** Find all variables satisfying a predicate. *)
val filter_vars : (var -> bool) -> t -> var list

(** Add a method to a type. *)
val meth :
  ?pos:pos -> ?json_name:string -> string -> scheme -> ?doc:string -> t -> t

(** Add a submethod to a type. *)
val meths : ?pos:pos -> string list -> scheme -> t -> t

(** Remove all methods in a type. *)
val demeth : t -> t

(** Split a type between methods and the main type. *)
val split_meths : t -> meth list * t

(** Put the methods of the first type around the second type. *)
val remeth : t -> t -> t

(** Type of a method in a type. *)
val invoke : t -> string -> scheme

(** Type of a submethod in a type. *)
val invokes : t -> string list -> scheme

(** {1 Representation of types} *)

(** Representation of a type. *)
type repr =
  [ `Constr of string * (variance * repr) list
  | `Ground of ground
  | `List of repr
  | `Tuple of repr list
  | `Nullable of repr
  | `Meth of string * (var_repr list * repr) * repr
  | `Arrow of (bool * string * repr) list * repr
  | `Getter of repr
  | `EVar of var_repr  (** existential variable *)
  | `UVar of var_repr  (** universal variable *)
  | `Ellipsis  (** omitted sub-term *)
  | `Range_Ellipsis  (** omitted sub-terms (in a list, e.g. list of args) *)
  | `Debug of string * repr * string ]

and var_repr = string * constraints

(** Representation of a type. *)
val repr : ?filter_out:(t -> bool) -> ?generalized:var list -> t -> repr

(** Print the representation of a type. *)
val print_repr : Format.formatter -> repr -> unit

(** {1 Typing errors} *)

type explanation = bool * t * t * repr * repr

exception Type_error of explanation

val print_type_error : (string -> unit) -> explanation -> unit

(** {1 Printing and documentation} *)

val pp_type : Format.formatter -> t -> unit
val pp_scheme : Format.formatter -> scheme -> unit
val print : ?generalized:var list -> t -> string
val print_scheme : scheme -> string
val doc_of_type : generalized:var list -> t -> Doc.item
val doc_of_meths : meth list -> Doc.item
