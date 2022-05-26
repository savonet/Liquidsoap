(** Constants describing configuration options of liquidsoap. *)

(** String describing the OS *)
val host : string

(** String describing the version. *)
val version : unit -> string

val restart : bool ref
val git_snapshot : bool

(** String describing the software. *)
val vendor : unit -> string

(** Where to look for standard .liq scripts to include *)
val liq_libs_dir : unit -> string

(** Where to look for private executables. *)
val bin_dir : unit -> string

(** Standard path. *)
val path : unit -> string list

(** Executable extension. *)
val ext_exe : string

(** Default font file *)
val default_font : string

(** Maximal id for a request. *)
val requests_max_id : int

val requests_table_size : int

(** Configured directories. Typically /var/(run|log)/liquidsoap. *)
val rundir : unit -> string

val logdir : unit -> string

(** Display inferred types. *)
val display_types : bool ref

(** String containing versions of all enabled bindings. *)
val libs_versions : unit -> string
