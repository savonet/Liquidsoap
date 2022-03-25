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
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

(** Abstract classes for easy creation of output nodes. *)

(** Parameters needed to instantiate an output. *)
val proto : (string * Lang.t * Lang.value option * string option) list

class virtual output :
  content_kind:Source.Kind.t
  -> output_kind:string
  -> ?name:string
  -> infallible:bool
  -> on_start:(unit -> unit)
  -> on_stop:(unit -> unit)
  -> Lang.value
  -> bool
  -> object
       inherit Source.active_source
       method stype : Source.source_t
       method self_sync : Source.self_sync
       method remaining : int
       method output : unit
       method private get_frame : Frame.t -> unit
       method abort_track : unit
       method is_ready : bool
       method state : Start_stop.state
       method transition_to : Start_stop.state -> unit
       method private add_metadata : Request.metadata -> unit
       method private metadata_queue : Request.metadata Queue.t
       method private reset : unit
       method private nb_frames : int64
       method virtual private send_frame : Frame.t -> unit
       method virtual private start : unit
       method virtual private stop : unit
     end

(** Default methods on output values. *)
val meth : (string * Lang.scheme * string * (output -> Lang.value)) list

class virtual encoded :
  content_kind:Source.Kind.t
  -> output_kind:string
  -> name:string
  -> infallible:bool
  -> on_start:(unit -> unit)
  -> on_stop:(unit -> unit)
  -> autostart:bool
  -> Lang.value
  -> object
       inherit output
       method private send_frame : Frame.t -> unit
       method virtual private encode : Frame.t -> int -> int -> 'a

       method virtual private insert_metadata :
         Meta_format.export_metadata -> unit

       method virtual private send : 'a -> unit
       method private reset : unit
       method virtual private start : unit
       method virtual private stop : unit
     end

class dummy :
  infallible:bool
  -> on_start:(unit -> unit)
  -> on_stop:(unit -> unit)
  -> autostart:bool
  -> kind:Source.Kind.t
  -> Lang.value
  -> object
       inherit output
       method private reset : unit
       method private start : unit
       method private stop : unit
       method private send_frame : Frame.t -> unit
     end
