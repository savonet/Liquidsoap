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

(** A request is something from which we can produce a file. *)

(** An indicator is a resource location (URI), when meaningful, it can be
    declared as temporary if liquidsoap should destroy it after usage (this means
    deleting a local file). *)
type indicator

(** Root configuration node. *)
val conf : Dtools.Conf.ut

(** Create an indicator. *)
val indicator :
  ?metadata:Frame.metadata -> ?temporary:bool -> string -> indicator

(** Raised when trying to set an invalid status, e.g. playing when not ready. *)
exception Invalid_state

(** Type of requests, which are devices for obtaining a local file from an
    URI. *)
type t

(** Create a request. *)
val create :
  ?resolve_metadata:bool ->
  ?excluded_metadata_resolvers:string list ->
  ?metadata:Frame.Metadata.t ->
  ?persistent:bool ->
  ?temporary:bool ->
  cue_in_metadata:string option ->
  cue_out_metadata:string option ->
  string ->
  t

(** Return the request's initial uri. *)
val initial_uri : t -> string

(** Destroying of a requests causes its file to be deleted if it's a temporary
    one, for example a downloaded file. If the metadata ["persistent"] is set to
    ["true"], destroying doesn't happen, unless [force] is set too.  Persistent
    sources are useful for static URIs (see below for the definition of
    staticity, and in [src/sources/one_file.ml] for an example of use). *)
val destroy : ?force:bool -> t -> unit

(** Status of a request. *)
type status =
  [ `Idle
  | `Resolving of float
  | `Ready
  | `Playing of float
  | `Destroyed
  | `Failed ]

(** Current status of a request. *)
val status : t -> status

(** {1 General management} *)

(** Called at exit, for cleaning temporary files and destroying all the
    requests, even persistent ones. *)
val cleanup : unit -> unit

(** Identifier of a request. *)
val id : t -> int

(** Get the list of all requests. *)
val all : unit -> t list

(** Retrieve a request from its id. *)
val from_id : int -> t option

(** Mark the request as playing. *)
val is_playing : t -> unit

(** Mark the request as done playing. *)
val done_playing : t -> unit

(** {1 Resolving}

    Resolving consists in many steps. Every step consist in rewriting the
    first URI into other URIs. The process ends when the last URI
    is a local filename. For example, the initial URI can be a database query,
    which is then turned into a remote locations, which is then
    tentatively downloaded...
    At each step [protocol.resolve uri timeout] is called,
    and the function is expected to push the new URIs in the request. *)

(** Something that resolves an URI. *)
type resolver = string -> log:(string -> unit) -> float -> indicator option

(** A protocol, which can resolve associated URIs. *)
type protocol = { resolve : resolver; static : bool }

(** A static request [r] is such that every resolving leads to the same file.
    Sometimes, it allows removing useless destroy/create/resolve. *)
val is_static : string -> bool

(** Resolving can fail because an URI is invalid, or doesn't refer to a valid
  * audio file, or simply because there was no enough time left. *)
type resolve_flag = [ `Resolved | `Failed | `Timeout ]

(** Metadata resolvers priorities. *)
val conf_metadata_decoder_priorities : Dtools.Conf.ut

(** [resolve request timeout] tries to resolve the request within
    [timeout] seconds. *)
val resolve : t -> float -> resolve_flag

(** [resolved r] if there's an available local filename. It can be true even if
    the resolving hasn't been run, if the initial URI was already a local
    filename. *)
val resolved : t -> bool

(** Return a valid local filename if there is one, which means that the request
    is ready. *)
val get_filename : t -> string option

(** {1 Metadatas} *)

(** Metadata are resolved from the first indicator to the last,
    the last one overriding the ones before. The only exception are
    root metadata, which are metadata internal to liquidsoap such
    as request id and etc. These cannot be overridden by resolvers. *)
val metadata : t -> Frame.metadata

(** {1 Logging}
    Every request has a separate log in which its history can be written. *)

type log = (Unix.tm * string) Queue.t

val string_of_log : log -> string
val add_log : t -> string -> unit
val get_log : t -> log

(** {1 Media operations}

    These operations are only meaningful for media requests, and might raise
    exceptions otherwise. *)

(** [duration ~metadata filename] computes the duration of audio data contained in
    [filename]. The computation may be expensive.
    @raise Not_found if no duration computation method is found. *)
val duration : metadata:Frame.metadata -> string -> float option

(** [true] is a decoder exists for the given content-type. *)
val has_decoder : ctype:Frame.content_type -> t -> bool

(** Return a decoder if the file has been resolved, guaranteed to have
    available data to deliver. *)
val get_decoder :
  ctype:Frame.content_type -> t -> Decoder.file_decoder_ops option

(** {1 Plugs} *)

(** Functions for computing duration. *)
val dresolvers : (metadata:Frame.metadata -> string -> float) Plug.t

(** Type for a metadata resolver. Resolvers are executed in priority
    order and the first returned metadata take precedence over any other
    one later returned. *)
type metadata_resolver = {
  priority : unit -> int;
  resolver :
    metadata:Frame.metadata ->
    extension:string option ->
    mime:string ->
    string ->
    (string * string) list;
}

(** Functions for resolving metadata. Metadata filling isn't included in Decoder
    because we want it to occur immediately after request resolution. *)
val mresolvers : metadata_resolver Plug.t

(** Resolve metadata for a local file: *)
val resolve_metadata :
  initial_metadata:Frame.metadata ->
  excluded:string list ->
  string ->
  Frame.metadata

(** Functions for resolving URIs. *)
val protocols : protocol Plug.t

module Value : Value.Custom with type content := t
