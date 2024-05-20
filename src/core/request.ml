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

(** Plug for resolving, that is obtaining a file from an URI. [src/protocols]
    plugins provide ways to resolve URIs: fetch, generate, ... *)

let conf =
  Dtools.Conf.void ~p:(Configure.conf#plug "request") "requests configuration"

let log = Log.make ["request"]

(** File utilities. *)

let remove_file_proto s =
  (* First remove file:// 🤮 *)
  let s =
    Pcre.substitute ~rex:(Pcre.regexp "^file://") ~subst:(fun _ -> "") s
  in
  (* Then remove file: 😇 *)
  Pcre.substitute ~rex:(Pcre.regexp "^file:") ~subst:(fun _ -> "") s

let home_unrelate s = Lang_string.home_unrelate (remove_file_proto s)

let parse_uri uri =
  try
    let i = String.index uri ':' in
    Some
      (String.sub uri 0 i, String.sub uri (i + 1) (String.length uri - (i + 1)))
  with _ -> None

type metadata_resolver = {
  priority : unit -> int;
  resolver :
    metadata:Frame.metadata ->
    extension:string option ->
    mime:string ->
    string ->
    (string * string) list;
}

(** Log *)

type log = (Unix.tm * string) Queue.t

let pretty_date date =
  Printf.sprintf "%d/%02d/%02d %02d:%02d:%02d" (date.Unix.tm_year + 1900)
    (date.Unix.tm_mon + 1) date.Unix.tm_mday date.Unix.tm_hour date.Unix.tm_min
    date.Unix.tm_sec

let string_of_log log =
  Queue.fold
    (fun s (date, msg) ->
      s
      ^
      if s = "" then Printf.sprintf "[%s] %s" (pretty_date date) msg
      else Printf.sprintf "\n[%s] %s" (pretty_date date) msg)
    "" log

(** Requests.
    The purpose of a request is to get a valid file. The file can contain media
    in which case validity implies finding a working decoder, or can be
    something arbitrary, like a playlist.
    This file is fetched using protocols. For example the fetching can involve
    querying a mysql database, receiving a list of new URIS, using http to
    download the first URI, check it, fail, using smb to download the second,
    success, have the file played, finish the request, erase the temporary
    downloaded file.
    This process involve a tree of URIs, represented by a list of lists.
    Metadata is attached to every file in the tree, and the view of the
    metadata from outside is the merging of all the metadata on the path
    from the current active URI to the root.
    At the end of the previous example, the tree looks like:
    [ [ "/tmp/localfile_from_smb" ] ;
      [
        (* Some http://something was there but was removed without producing
           anything. *)
        "smb://something" ; (* The successfully downloaded URI *)
        "ftp://another/uri" ;
        (* maybe some more URIs are here, ready in case of more failures *)
      ] ;
      [ "mydb://myrequest" ] (* And this is the initial URI *)
    ]
  *)

type indicator = {
  string : string;
  temporary : bool;
  mutable metadata : Frame.metadata;
}

type status = Idle | Resolving | Ready | Playing | Destroyed

type t = {
  id : int;
  initial_uri : string;
  resolve_metadata : bool;
  excluded_metadata_resolvers : string list;
  cue_in_metadata : string option;
  cue_out_metadata : string option;
  mutable ctype : Frame.content_type option;
  (* No kind for raw requests *)
  persistent : bool;
  (* The status of a request gives partial information of what's being done with
     the request. The info is only partial because things can happen in
     parallel. For example you can resolve a request in order to get a new file
     from it while it is being played. For this reason, the separate resolving
     and on_air information is not completely redundant, and do not necessarily
     need to be part of the status information.  Actually this need is quite
     rare, and I'm not sure this is a good choice. I'm wondering, so I keep the
     current design. *)
  mutable status : status;
  mutable resolving : float option;
  mutable on_air : float option;
  logger : Log.t;
  log : log;
  mutable root_metadata : Frame.metadata;
  mutable indicators : indicator list list;
  mutable decoder : (unit -> Decoder.file_decoder_ops) option;
}

let ctype r = r.ctype
let initial_uri r = r.initial_uri
let status r = r.status

let indicator ?(metadata = Frame.Metadata.empty) ?temporary s =
  { string = home_unrelate s; temporary = temporary = Some true; metadata }

(** Length *)
let dresolvers_doc = "Methods to extract duration from a file."

let dresolvers = Plug.create ~doc:dresolvers_doc "audio file formats (duration)"

exception Duration of float

let compute_duration ~metadata file =
  try
    Plug.iter dresolvers (fun _ resolver ->
        try
          let ans = resolver ~metadata file in
          raise (Duration ans)
        with
          | Duration e -> raise (Duration e)
          | _ -> ());
    raise Not_found
  with Duration d -> d

let duration ~metadata file =
  try
    match
      ( Frame.Metadata.find_opt "duration" metadata,
        Frame.Metadata.find_opt "cue_in" metadata,
        Frame.Metadata.find_opt "cue_out" metadata )
    with
      | _, Some cue_in, Some cue_out ->
          Some (float_of_string cue_out -. float_of_string cue_in)
      | _, None, Some cue_out -> Some (float_of_string cue_out)
      | Some v, _, _ -> Some (float_of_string v)
      | None, cue_in, None ->
          let duration = compute_duration ~metadata file in
          let duration =
            match cue_in with
              | Some cue_in -> duration -. float_of_string cue_in
              | None -> duration
          in
          Some duration
  with _ -> None

(** Manage requests' metadata *)

let iter_metadata t f =
  f t.root_metadata;
  List.iter
    (function [] -> assert false | h :: _ -> f h.metadata)
    t.indicators

let set_metadata t k v =
  match t.indicators with
    | [] -> t.root_metadata <- Frame.Metadata.add k v t.root_metadata
    | [] :: _ -> assert false
    | (h :: _) :: _ -> h.metadata <- Frame.Metadata.add k v h.metadata

let set_root_metadata t k v =
  t.root_metadata <- Frame.Metadata.add k v t.root_metadata

exception Found of string

let get_metadata t k =
  try
    iter_metadata t (fun h ->
        try raise (Found (Frame.Metadata.find k h)) with Not_found -> ());
    None
  with Found s -> Some s

let get_all_metadata t =
  let h = ref Frame.Metadata.empty in
  iter_metadata t
    (Frame.Metadata.iter (fun k v ->
         if not (Frame.Metadata.mem k !h) then h := Frame.Metadata.add k v !h));
  !h

(** Logging *)

let add_log t i =
  t.logger#info "%s" i;
  Queue.add (Unix.localtime (Unix.time ()), i) t.log

let get_log t = t.log

(* Indicator tree management *)

exception No_indicator
exception Request_resolved

let () =
  Printexc.register_printer (function
    | No_indicator -> Some "All options exhausted while processing request"
    | _ -> None)

let string_of_indicators t =
  let i = t.indicators in
  let string_of_list l = "[" ^ String.concat ", " l ^ "]" in
  let i = List.map (List.map (fun i -> i.string)) i in
  let i = List.map string_of_list i in
  string_of_list i

let peek_indicator t =
  match t.indicators with
    | (h :: _) :: _ -> h
    | [] :: _ -> assert false
    | [] -> raise No_indicator

let rec pop_indicator t =
  let i, repop =
    match t.indicators with
      | (h :: l) :: ll ->
          t.indicators <- (if l = [] then ll else l :: ll);
          (h, l = [] && ll <> [])
      | [] :: _ -> assert false
      | [] -> raise No_indicator
  in
  if i.temporary then (
    try Unix.unlink i.string
    with e -> log#severe "Unlink failed: %S" (Printexc.to_string e));
  t.decoder <- None;
  if repop then pop_indicator t

let conf_metadata_decoders =
  Dtools.Conf.list
    ~p:(conf#plug "metadata_decoders")
    ~d:[] "Decoders and order used to decode files' metadata."

let conf_metadata_decoder_priorities =
  Dtools.Conf.void
    ~p:(conf_metadata_decoders#plug "priorities")
    "Priorities used for applying metadata decoders. Decoder with the highest \
     priority take precedence."

let conf_request_metadata_priority =
  Dtools.Conf.int ~d:5
    ~p:(conf_metadata_decoder_priorities#plug "request_metadata")
    "Priority for the request metadata. This include metadata set via \
     `annotate`."

let f c v =
  match c#get_d with
    | None -> c#set_d (Some [v])
    | Some d -> c#set_d (Some (d @ [v]))

let get_decoders conf decoders =
  let f cur name =
    match Plug.get decoders name with
      | Some p -> (name, p) :: cur
      | None ->
          log#severe "Cannot find decoder %s" name;
          cur
  in
  List.sort
    (fun (_, d) (_, d') -> Stdlib.compare (d'.priority ()) (d.priority ()))
    (List.fold_left f [] (List.rev conf#get))

let mresolvers_doc = "Methods to extract metadata from a file."

let mresolvers =
  Plug.create
    ~register_hook:(fun name _ -> f conf_metadata_decoders name)
    ~doc:mresolvers_doc "metadata formats"

let conf_duration =
  Dtools.Conf.bool
    ~p:(conf_metadata_decoders#plug "duration")
    ~d:false
    "Compute duration in the \"duration\" metadata, if the metadata is not \
     already present. This can take a long time and the use of this option is \
     not recommended: the proper way is to have a script precompute the \
     \"duration\" metadata."

let conf_recode =
  Dtools.Conf.bool
    ~p:(conf_metadata_decoders#plug "recode")
    ~d:true "Re-encode metadata strings in UTF-8"

let conf_recode_excluded =
  Dtools.Conf.list
    ~d:["apic"; "metadata_block_picture"; "coverart"]
    ~p:(conf_recode#plug "exclude")
    "Exclude these metadata from automatic recording."

let resolve_metadata ~initial_metadata ~excluded name =
  let decoders = get_decoders conf_metadata_decoders mresolvers in
  let decoders =
    List.filter (fun (name, _) -> not (List.mem name excluded)) decoders
  in
  let high_priority_decoders, low_priority_decoders =
    List.partition
      (fun (_, { priority }) ->
        conf_request_metadata_priority#get < priority ())
      decoders
  in
  let convert =
    if conf_recode#get then (
      let excluded = conf_recode_excluded#get in
      fun k v -> if not (List.mem k excluded) then Charset.convert v else v)
    else fun _ x -> x
  in
  let extension = try Some (Utils.get_ext name) with _ -> None in
  let mime = Magic_mime.lookup name in
  let get_metadata ~metadata decoders =
    List.fold_left
      (fun metadata (_, { resolver }) ->
        try
          let ans = resolver ~metadata:initial_metadata ~extension ~mime name in
          List.fold_left
            (fun metadata (k, v) ->
              let k = String.lowercase_ascii (convert k k) in
              let v = convert k v in
              if not (Frame.Metadata.mem k metadata) then
                Frame.Metadata.add k v metadata
              else metadata)
            metadata ans
        with _ -> metadata)
      metadata decoders
  in
  let metadata =
    get_metadata ~metadata:Frame.Metadata.empty high_priority_decoders
  in
  let metadata =
    get_metadata
      ~metadata:(Frame.Metadata.append initial_metadata metadata)
      low_priority_decoders
  in
  if conf_duration#get then (
    match duration ~metadata name with
      | None -> metadata
      | Some d -> Frame.Metadata.add "duration" (string_of_float d) metadata)
  else metadata

(** Sys.file_exists doesn't make a difference between existing files and files
    without enough permissions to list their attributes, for example when they
    are in a directory without x permission.  The two following functions allow a
    more precise diagnostic.  We do not use them everywhere in this file, but
    only when splitting existence and readability checks yields better logs. *)

let file_exists name =
  try
    Unix.access name [Unix.F_OK];
    true
  with
    | Unix.Unix_error (Unix.EACCES, _, _) -> true
    | Unix.Unix_error _ -> false

let file_is_readable name =
  try
    Unix.access name [Unix.R_OK];
    true
  with Unix.Unix_error _ -> false

let read_metadata t =
  if t.resolve_metadata then (
    let indicator = peek_indicator t in
    let name = indicator.string in
    if file_exists name then
      if not (file_is_readable name) then
        log#important "Read permission denied for %s!"
          (Lang_string.quote_string name)
      else (
        let metadata =
          resolve_metadata ~initial_metadata:(get_all_metadata t)
            ~excluded:t.excluded_metadata_resolvers name
        in
        indicator.metadata <- Frame.Metadata.append indicator.metadata metadata))

let local_check t =
  read_metadata t;
  let check_decodable ctype =
    while t.decoder = None && file_exists (peek_indicator t).string do
      let indicator = peek_indicator t in
      let name = indicator.string in
      let metadata =
        if t.resolve_metadata then get_all_metadata t else Frame.Metadata.empty
      in
      if not (file_is_readable name) then (
        log#important "Read permission denied for %s!"
          (Lang_string.quote_string name);
        add_log t "Read permission denied!";
        pop_indicator t)
      else (
        match Decoder.get_file_decoder ~metadata ~ctype name with
          | Some (decoder_name, f) ->
              t.decoder <- Some f;
              set_root_metadata t "decoder" decoder_name;
              t.status <- Ready
          | None -> pop_indicator t)
    done
  in
  (match t.ctype with None -> () | Some t -> check_decodable t);
  raise Request_resolved

let push_indicators t l =
  if l <> [] then (
    let hd = List.hd l in
    add_log t
      (Printf.sprintf "Pushed [%s;...]." (Lang_string.quote_string hd.string));
    t.indicators <- l :: t.indicators;
    t.decoder <- None;
    let indicator = peek_indicator t in
    if file_exists indicator.string then read_metadata t)

let resolved t = match t.status with Ready | Playing -> true | _ -> false

(** [get_filename request] returns
  * [Some f] if the request successfully lead to a local file [f],
  * [None] otherwise. *)
let get_filename t =
  if resolved t then Some (List.hd (List.hd t.indicators)).string else None

let update_metadata t =
  let replace k v = t.root_metadata <- Frame.Metadata.add k v t.root_metadata in
  replace "rid" (string_of_int t.id);
  replace "initial_uri" t.initial_uri;

  (* TOP INDICATOR *)
  replace "temporary"
    (match t.indicators with
      | (h :: _) :: _ -> if h.temporary then "true" else "false"
      | _ -> "false");
  begin
    match get_filename t with Some f -> replace "filename" f | None -> ()
  end;

  (* STATUS *)
  begin
    match t.resolving with
      | Some d -> replace "resolving" (pretty_date (Unix.localtime d))
      | None -> ()
  end;
  begin
    match t.on_air with
      | Some d ->
          replace "on_air" (pretty_date (Unix.localtime d));
          replace "on_air_timestamp" (Printf.sprintf "%.02f" d)
      | None -> ()
  end;
  begin
    match t.ctype with
      | None -> ()
      | Some ct -> replace "kind" (Frame.string_of_content_type ct)
  end;
  replace "status"
    (match t.status with
      | Idle -> "idle"
      | Resolving -> "resolving"
      | Ready -> "ready"
      | Playing -> "playing"
      | Destroyed -> "destroyed")

let get_metadata t k =
  update_metadata t;
  get_metadata t k

let get_all_metadata t =
  update_metadata t;
  get_all_metadata t

(** Global management *)

module Pool = Pool.Make (struct
  type req = t
  type t = req

  let id { id } = id

  let destroyed =
    {
      id = 0;
      initial_uri = "";
      cue_in_metadata = None;
      cue_out_metadata = None;
      ctype = None;
      resolve_metadata = false;
      excluded_metadata_resolvers = [];
      persistent = false;
      status = Destroyed;
      resolving = None;
      on_air = None;
      logger = Log.make [];
      log = Queue.create ();
      root_metadata = Frame.Metadata.empty;
      indicators = [];
      decoder = None;
    }

  let destroyed id = { destroyed with id }
  let is_destroyed { status } = status = Destroyed
end)

let get_id t = t.id
let from_id id = Pool.find id
let all_requests () = Pool.fold (fun k _ l -> k :: l) []

let alive_requests () =
  Pool.fold (fun k v l -> if v.status <> Destroyed then k :: l else l) []

let is_on_air t = t.on_air <> None

let on_air_requests () =
  Pool.fold (fun k v l -> if is_on_air v then k :: l else l) []

let is_resolving t = t.status = Resolving

let resolving_requests () =
  Pool.fold (fun k v l -> if is_resolving v then k :: l else l) []

(** Creation *)

let leak_warning =
  Dtools.Conf.int ~p:(conf#plug "leak_warning") ~d:100
    "Number of requests at which a leak warning should be issued."

let destroy ?force t =
  if t.status <> Destroyed then (
    if t.status = Playing then t.status <- Ready;
    if force = Some true || not t.persistent then (
      t.on_air <- None;
      t.status <- Idle;

      (* Freeze the metadata *)
      t.root_metadata <- get_all_metadata t;

      (* Remove the URIs, unlink temporary files *)
      while t.indicators <> [] do
        pop_indicator t
      done;
      t.status <- Destroyed;
      add_log t "Request finished."))

let finalise = destroy ~force:true

let clean () =
  Pool.iter (fun _ r -> if r.status <> Destroyed then destroy ~force:true r);
  Pool.clear ()

let create ?(resolve_metadata = true) ?(excluded_metadata_resolvers = [])
    ?(metadata = []) ?(persistent = false) ?(indicators = []) ~cue_in_metadata
    ~cue_out_metadata u =
  (* Find instantaneous request loops *)
  let () =
    let n = Pool.size () in
    if n > 0 && n mod leak_warning#get = 0 then
      log#severe
        "There are currently %d RIDs, possible request leak! Please check that \
         you don't have a loop on empty/unavailable requests."
        n
  in
  let t =
    let req =
      {
        id = 0;
        initial_uri = u;
        cue_in_metadata;
        cue_out_metadata;
        ctype = None;
        resolve_metadata;
        excluded_metadata_resolvers;
        (* This is fixed when resolving the request. *)
        persistent;
        on_air = None;
        resolving = None;
        status = Idle;
        decoder = None;
        logger = Log.make [];
        log = Queue.create ();
        root_metadata = Frame.Metadata.empty;
        indicators = [];
      }
    in
    Pool.add (fun id ->
        { req with id; logger = Log.make ["request"; string_of_int id] })
  in
  List.iter
    (fun (k, v) -> t.root_metadata <- Frame.Metadata.add k v t.root_metadata)
    metadata;
  push_indicators t (if indicators = [] then [indicator u] else indicators);
  Gc.finalise finalise t;
  t

let on_air t =
  t.on_air <- Some (Unix.time ());
  t.status <- Playing;
  add_log t "Currently on air."

let get_cue ~r = function
  | None -> None
  | Some m -> (
      match get_metadata r m with
        | None -> None
        | Some v -> (
            match float_of_string_opt v with
              | None ->
                  r.logger#important "Invalid cue metadata %s: %s" m v;
                  None
              | Some v -> Some v))

let get_decoder r =
  match r.decoder with
    | None -> None
    | Some d -> (
        let decoder = d () in
        let open Decoder in
        let initial_pos =
          match get_cue ~r r.cue_in_metadata with
            | Some cue_in ->
                r.logger#info "Cueing in to position: %.02f" cue_in;
                let cue_in = Frame.main_of_seconds cue_in in
                let seeked = decoder.fseek cue_in in
                if seeked <> cue_in then
                  r.logger#important
                    "Initial seek mismatch! Expected: %d, effective: %d" cue_in
                    seeked;
                seeked
            | None -> 0
        in
        match get_cue ~r r.cue_out_metadata with
          | None -> Some decoder
          | Some cue_out ->
              let cue_out = Frame.main_of_seconds cue_out in
              let pos = Atomic.make initial_pos in
              let fread len =
                if cue_out <= Atomic.get pos then decoder.fread 0
                else (
                  let old_pos = Atomic.get pos in
                  let len = min len (cue_out - old_pos) in
                  let buf = decoder.fread len in
                  let filled = Frame.position buf in
                  let new_pos = old_pos + filled in
                  Atomic.set pos new_pos;
                  if cue_out <= new_pos then (
                    r.logger#info "Cueing out at position: %.02f"
                      (Frame.seconds_of_main cue_out);
                    Frame.slice buf (cue_out - old_pos))
                  else (
                    if Frame.is_partial buf then
                      r.logger#important
                        "End of track reached before cue-out point!";
                    buf))
              in
              let remaining () =
                match (decoder.remaining (), cue_out - Atomic.get pos) with
                  | -1, r -> r
                  | r, r' -> min r r'
              in
              Some { decoder with fread; remaining })

(** Plugins registration. *)

type resolver = string -> log:(string -> unit) -> float -> indicator list

type protocol = {
  resolve : string -> log:(string -> unit) -> float -> indicator list;
  static : bool;
}

let protocols_doc =
  "Methods to get a file. They are the first part of URIs: 'protocol:args'."

let protocols = Plug.create ~doc:protocols_doc "protocols"

let is_static s =
  if Sys.file_exists (home_unrelate s) then true
  else (
    match parse_uri s with
      | Some (proto, _) -> (
          match Plug.get protocols proto with
            | Some handler -> handler.static
            | None -> false)
      | None -> false)

(** Resolving engine. *)

type resolve_flag = Resolved | Failed | Timeout

exception ExnTimeout

let should_fail = Atomic.make false

let () =
  Lifecycle.before_core_shutdown ~name:"Requests shutdown" (fun () ->
      Atomic.set should_fail true)

let resolve ~ctype t timeout =
  assert (
    t.ctype = None || Frame.compatible (Option.get t.ctype) (Option.get ctype));
  log#debug "Resolving request %s." (string_of_indicators t);
  t.ctype <- ctype;
  t.resolving <- Some (Unix.time ());
  t.status <- Resolving;
  let maxtime = Unix.time () +. timeout in
  let resolve_step () =
    let i = peek_indicator t in
    log#f 6 "Resolve step %s in %s." i.string (string_of_indicators t);
    (* If the file is local we only need to check that it's valid, we'll
       actually do that in a single local_check for all local indicators on the
       top of the stack. *)
    if file_exists i.string then local_check t
    else (
      match parse_uri i.string with
        | Some (proto, arg) -> (
            match Plug.get protocols proto with
              | Some handler ->
                  add_log t
                    (Printf.sprintf "Resolving %s (timeout %.0fs)..."
                       (Lang_string.quote_string i.string)
                       timeout);
                  let production =
                    handler.resolve ~log:(add_log t) arg maxtime
                  in
                  if production = [] then (
                    log#info
                      "Failed to resolve %s! For more info, see server command \
                       `request.trace %d`."
                      (Lang_string.quote_string i.string)
                      t.id;
                    ignore (pop_indicator t))
                  else push_indicators t production
              | None ->
                  log#important "Unknown protocol %S in URI %s!" proto
                    (Lang_string.quote_string i.string);
                  add_log t "Unknown protocol!";
                  pop_indicator t)
        | None ->
            let log_level = if i.string = "" then 4 else 3 in
            log#f log_level "Nonexistent file or ill-formed URI %s!"
              (Lang_string.quote_string i.string);
            add_log t "Nonexistent file or ill-formed URI!";
            pop_indicator t)
  in
  let result =
    try
      while true do
        if Atomic.get should_fail then raise No_indicator;
        let timeleft = maxtime -. Unix.time () in
        if timeleft > 0. then resolve_step ()
        else (
          add_log t "Global timeout.";
          raise ExnTimeout)
      done;
      assert false
    with
      | Request_resolved -> Resolved
      | ExnTimeout -> Timeout
      | No_indicator ->
          add_log t "Every possibility failed!";
          Failed
  in
  log#debug "Resolved to %s." (string_of_indicators t);
  let excess = Unix.time () -. maxtime in
  if excess > 0. then log#severe "Time limit exceeded by %.2f secs!" excess;
  t.resolving <- None;
  if result <> Resolved then t.status <- Idle else t.status <- Ready;
  result

(* Make a few functions more user-friendly, internal stuff is over. *)

let peek_indicator t = (peek_indicator t).string

module Value = Value.MkCustom (struct
  type content = t

  let name = "request"

  let to_json ~pos _ =
    Runtime_error.raise ~pos ~message:"Requests cannot be represented as json"
      "json"

  let to_string r = Printf.sprintf "<request(id=%d)>" (get_id r)
  let compare = Stdlib.compare
end)
