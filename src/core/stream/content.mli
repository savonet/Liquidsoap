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

open Mm

(** Generic content registration API. *)

module Contents = Liquidsoap_lang.Content.Contents

(* Raised during any invalid operation below. *)
exception Invalid

(* Raised when calling [merge] below. *)
exception Incompatible_format of Contents.format * Contents.format

type internal_content_type = [ `None | `Audio | `Video | `Midi ]

module type ContentSpecs = sig
  type kind
  type params
  type data

  (** Data *)

  val internal_content_type : internal_content_type option

  (* Size is in main ticks. *)
  val make : size:int -> params -> data

  (* [blit src src_pos dst dst_pos len] copies data from [src] 
   * into [dst]. *)
  val blit : data -> int -> data -> int -> int -> unit

  (* [fill src src_pos dst dst_pos len] assigns data from [src]
   * into [dst] without copying when possible. *)
  val fill : data -> int -> data -> int -> int -> unit
  val sub : data -> int -> int -> data
  val copy : data -> data
  val clear : data -> unit
  val is_empty : data -> bool

  (** Params *)

  val params : data -> params
  val merge : params -> params -> params
  val compatible : params -> params -> bool
  val string_of_params : params -> string

  (* [parse_param "label" "value"] *)
  val parse_param : string -> string -> params option

  (** Kind *)

  val kind : kind
  val default_params : kind -> params
  val string_of_kind : kind -> string
  val kind_of_string : string -> kind option
end

module type Content = sig
  include ContentSpecs

  (** Data *)

  val is_data : Contents.data -> bool
  val lift_data : data -> Contents.data
  val get_data : Contents.data -> data

  (** Format *)

  val is_format : Contents.format -> bool
  val lift_params : params -> Contents.format
  val get_params : Contents.format -> params

  (** Kind *)

  val is_kind : Contents.kind -> bool
  val lift_kind : kind -> Contents.kind
  val get_kind : Contents.kind -> kind
end

module MkContent (C : ContentSpecs) :
  Content
    with type kind = C.kind
     and type params = C.params
     and type data = C.data

type format = Contents.format
type kind = Contents.kind
type data = Contents.data

(** Data *)

val make : size:int -> format -> data
val blit : data -> int -> data -> int -> int -> unit
val fill : data -> int -> data -> int -> int -> unit
val sub : data -> int -> int -> data
val copy : data -> data
val clear : data -> unit
val is_empty : data -> bool

(** Format *)

val format : data -> format
val duplicate : format -> format
val merge : format -> format -> unit
val compatible : format -> format -> bool
val string_of_format : format -> string

(* [parse_param kind "label" "value"] *)
val parse_param : kind -> string -> string -> format

(** Kind *)

val kind : format -> kind
val default_format : kind -> format
val string_of_kind : kind -> string
val kind_of_string : string -> kind

(** Internal content types. *)

(* None content type is abstract and only used
   via its params and data. *)
module None : sig
  val data : Contents.data
  val format : Contents.format
  val is_format : Contents.format -> bool
end

module Audio : sig
  include
    Content
      with type kind = [ `Pcm ]
       and type params = Contents.audio_params
       and type data = Audio.Mono.buffer array

  val kind : Contents.kind
  val channels_of_format : Contents.format -> int
  val format_of_channels : int -> Contents.format
end

module Video : sig
  include
    Content
      with type kind = [ `Canvas ]
       and type params = Contents.video_params
       and type data = Video.Canvas.t

  val kind : Contents.kind
  val dimensions_of_format : Contents.format -> int * int
end

module Midi : sig
  include
    Content
      with type kind = [ `Midi ]
       and type params = Contents.midi_params
       and type data = MIDI.Multitrack.buffer

  val kind : Contents.kind
end

val default_audio : unit -> Contents.format
val default_video : unit -> Contents.format
val default_midi : unit -> Contents.format
val is_internal_kind : kind -> bool
val is_internal_format : format -> bool

(* Some tools *)
val merge_param : name:string -> 'a option * 'a option -> 'a option
val print_optional : (string * string option) list -> string
