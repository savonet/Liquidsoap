(*****************************************************************************
  
  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2013 Savonet team
  
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

open Dtools
open Printf
  
(** Runner module signature. *)
module type Runner_t =
sig
  val options : (string list * Arg.spec * string) list
end

let usage =
  "Usage : liquidsoap [OPTION, SCRIPT or EXPR]...\n\
  \ - SCRIPT for evaluating a liquidsoap script file;\n\
  \ - EXPR for evaluating a scripting expression;\n\
  \ - OPTION is one of the options listed below:\n"

let () =
  Configure.conf#plug "init" Init.conf ;
  Configure.conf#plug "log" Log.conf

(* Should we not run the active sources? *)
let dont_run = ref false

(* Should we start even without active sources? *)
let force_start =
  Dtools.Conf.bool
    ~p:(Dtools.Init.conf#plug "force_start") ~d:false
    "Start liquidsoap even without any active source"
    ~comments:[
      "This should be reserved for advanced dynamic uses of liquidsoap."
    ]

(* Do not run, don't even check the scripts. *)
let parse_only = ref false

(* Should we load the pervasives? *)
let pervasives = ref true

(* Have we been used for an other purpose than streaming? *)
let secondary_task = ref false

(* Shall we start an interactive interpreter (REPL) *)
let interactive = ref false

(** [load_libs] should be called before loading a script or looking up
  * the documentation, to make sure that pervasive libraries have been loaded,
  * unless the user explicitly opposed to it. *)
let load_libs =
  let loaded = ref false in
    fun () ->
      if !pervasives && not !loaded then begin
        let save = !Configure.display_types in
          Configure.display_types := false ;
          Lang.load_libs ~parse_only:!parse_only () ;
          loaded := true ;
          Configure.display_types := save
      end

(** Evaluate a script or expression.
  * This used to be done immediately, which made it possible to
  * write things like "liquidsoap myscript.liq -h myop" and get
  * some doc on an operator.
  * Now, we delay each evaluation because the last item has to be treated
  * as a non-library, ie. all defined variables should be used.
  * By default the last item is (the only one) not treated as a library,
  * for better diagnosis, but this can be disabled (which is useful
  * when --checking a lib). *)

let last_item_lib = ref false

let do_eval, eval =
  let delayed = ref None in
  let eval src ~lib =
    load_libs () ;
    match src with
      | `StdIn ->
          Log.conf_stdout#set_d (Some true) ;
          Log.conf_file#set_d (Some false) ;
          Lang.from_in_channel ~lib ~parse_only:!parse_only stdin
      | `Expr_or_File expr when (not (Sys.file_exists expr)) ->
          Log.conf_stdout#set_d (Some true) ;
          Log.conf_file#set_d (Some false) ;
          Lang.from_string ~lib ~parse_only:!parse_only expr
      | `Expr_or_File f ->
          let basename = Filename.basename f in
          let basename =
            try Filename.chop_extension basename with _ -> basename
          in
            Configure.var_script := basename ;
            Lang.from_file ~lib ~parse_only:!parse_only f
  in
  let force ~lib =
    match !delayed with Some f -> f ~lib ; delayed := None | None -> ()
  in
    force,
    (fun src -> force ~lib:true ; delayed := Some (eval src))

let load_libs () =
  do_eval ~lib:true ;
  load_libs ()

let lang_doc name =
  secondary_task := true ;
  load_libs () ;
  try
    Doc.print_lang (Lang_values.builtins#get_subsection name)
  with
    | Not_found -> Printf.printf "Plugin not found!\n%!"

let process_request s =
  load_libs () ;
  secondary_task := true ;
  let kind =
    { Frame.audio = Frame.Variable ;
      Frame.video = Frame.Variable ;
      Frame.midi = Frame.Variable }
  in
  let req = Request.create ~kind s in
    match Request.resolve req 20. with
      | Request.Failed ->
          Printf.printf "Request resolution failed.\n" ;
          Request.destroy req ;
          exit 2
      | Request.Timeout ->
          Printf.printf "Request resolution timeout.\n" ;
          Request.destroy req ;
          exit 1
      | Request.Resolved ->
          let metadata = Request.get_all_metadata req in
          let metadata = Request.string_of_metadata metadata in
            Printf.printf "Request resolved.\n%s\n" metadata ;
            Printf.printf "Computing duration: %!" ;
            begin try
              Printf.printf "%.2f sec.\n"
                (Request.duration (Utils.get_some (Request.get_filename req)))
            with
              Not_found -> Printf.printf "failed.\n"
            end ;
            Request.destroy req

module LiqConf =
struct
  (** Contains clones of Dtools.Conf.(descr|dump) but with a liq syntax. *)

  let format_string = Printf.sprintf "%S"
  let format_list l =
    "[" ^ (String.concat "," (List.map format_string l)) ^ "]"

  let get_string t =
    try
      match t#kind with
        | None -> None
        | Some "unit" -> Some "()"
        | Some "int" -> Some (string_of_int (Conf.as_int t)#get)
        | Some "float" -> Some (string_of_float (Conf.as_float t)#get)
        | Some "bool" -> Some (string_of_bool (Conf.as_bool t)#get)
        | Some "string" -> Some (format_string (Conf.as_string t)#get)
        | Some "list" -> Some (format_list (Conf.as_list t)#get)
        | _ -> assert false
    with
      | Conf.Undefined _ -> None

  let get_d_string t =
    let mapopt f = (function None -> None | Some x -> Some (f x)) in
      try
        match t#kind with
          | None -> None
          | Some "unit" -> mapopt (fun () -> "()") (Conf.as_unit t)#get_d
          | Some "int" -> mapopt string_of_int (Conf.as_int t)#get_d
          | Some "float" -> mapopt string_of_float (Conf.as_float t)#get_d
          | Some "bool" -> mapopt string_of_bool (Conf.as_bool t)#get_d
          | Some "string" -> mapopt format_string (Conf.as_string t)#get_d
          | Some "list" -> mapopt format_list (Conf.as_list t)#get_d
          | _ -> assert false
      with
        | Conf.Undefined _ -> None

  let string_of_path p =
    String.concat "." p

  let dump ?(prefix=[]) t =
    let rec aux prefix t =
      let p s = if prefix = "" then s else prefix ^ "." ^ s in
      let subs =
        List.map (function s -> aux (p s) (t#path [s])) t#subs
      in
        begin match get_d_string t, get_string t with
          | None, None ->
              "" (* Printf.sprintf "# set %-30s\n" prefix *)
          | Some p, None ->
              Printf.sprintf "# set(%S,%s)\n" prefix p
          | Some p, Some p' when p' = p ->
              Printf.sprintf "# set(%S,%s)\n" prefix p
          | _, Some p ->
              Printf.sprintf "set(%S,%s)\n" prefix p
        end ^
        String.concat "" subs
    in
      aux (string_of_path prefix) (t#path prefix)

  let descr ?(liqi=false) ?(prefix=[]) t =
    let rec aux level prefix t =
      let p s = if prefix = "" then s else prefix ^ "." ^ s in
      let subs =
        List.map (function s -> aux (level+1) (p s) (t#path [s])) t#subs
      in
      let title,default,set,comment =
        if liqi then
          Printf.sprintf "h%d. %s\n",
          Printf.sprintf "Default: @%s@\n",
          Printf.sprintf "%%%%\n\
                          set(%S,%s)\n\
                          %%%%\n",
          (fun l -> String.concat ""
                     (List.map (fun s -> Printf.sprintf "%s\n" s) l))
        else
          (fun _ ->
             if t#kind = None then
               Printf.sprintf "### %s\n\n"
             else
               Printf.sprintf "## %s\n"),
          Printf.sprintf "# Default: %s\n",
          Printf.sprintf "set(%S,%s)\n",
          (fun l -> Printf.sprintf "# Comments:\n%s"
                  (String.concat ""
                    (List.map (fun s -> Printf.sprintf "#  %s\n" s) l)))
      in
        begin match t#kind, get_string t with
        | None, None -> title level t#descr
        | Some _, Some p ->
            title level t#descr ^
            begin match get_d_string t with
              | None -> ""
              | Some d -> default d
            end ^
            set prefix p ^
            begin match t#comments with
              | [] -> ""
              | l -> comment l
            end ^
            "\n"
        | _ -> ""
        end ^
        String.concat "" subs
    in
      aux 2 (string_of_path prefix) (t#path prefix)

  let descr_key t p =
    try
      print_string (descr ~prefix:(Conf.path_of_string p) t);
      exit 0
    with
      | Dtools.Conf.Unbound _ ->
          Printf.eprintf
            "The key '%s' is not a valid configuration key.\n%!"
            p ;
          exit 1

  let args t =
    [
      ["--conf-descr-key"],
      Arg.String (descr_key t),
      "Describe a configuration key.";
      ["--conf-descr"],
      Arg.Unit (fun () ->
        print_string (descr t); exit 0),
      "Display a described table of the configuration keys.";
      ["--conf-descr-liqi"],
      Arg.Unit (fun () ->
        print_string (descr ~liqi:true t); exit 0),
      "Display a described table of the configuration keys in liqi (documentation wiki) format.";
      ["--conf-dump"],
      Arg.Unit (fun () ->
        print_string (dump t); exit 0),
      "Dump the configuration state";
    ]

end

let format_doc s =
  let prefix = "\t  " in
  let indent = 8+2 in
  let max_width = 80 in
  let s = Pcre.split ~pat:" " s in
  let s =
    let rec join line width = function
      | [] -> [line]
      | hd::tl ->
          let hdw = String.length hd in
          let w = width + 1 + hdw in
            if w < max_width then
              join (line^" "^hd) w tl
            else
              line :: join (prefix^hd) hdw tl
    in
      match s with
        | hd::tl ->
            join (prefix ^ hd) (indent + String.length hd) tl
        | [] -> []
  in
    String.concat "\n" s

let log = Log.make ["main"]

let options = [
    ["-"],
    Arg.Unit (fun () -> eval `StdIn),
    "Read script from standard input." ;

    ["-r"],
    Arg.String process_request,
    "Process a request." ;

    ["-h"],
    Arg.String lang_doc,
    "Get help about a scripting value: \
     source, operator, builtin or library function, etc.";

    ["-c";"--check"],
    Arg.Unit (fun () ->
                secondary_task := true ;
                dont_run := true),
    "Check and evaluate scripts but do not perform any streaming." ;

    ["-cl";"--check-lib"],
    Arg.Unit (fun () ->
                last_item_lib := true ;
                secondary_task := true ;
                dont_run := true),
    "Like --check but treats all scripts and expressions as libraries, \
     so that unused toplevel variables are not reported." ;

    ["-p";"--parse-only"],
    Arg.Unit (fun () ->
                secondary_task := true ;
                parse_only := true),
    "Parse scripts but do not type-check and run them." ;

    ["-q";"--quiet"],
    Arg.Unit (fun () -> Log.conf_stdout#set false),
    "Do not print log messages on standard output." ;

    ["-v";"--verbose"],
    Arg.Unit (fun () -> Log.conf_stdout#set true),
    "Print log messages on standard output." ;

    ["-f";"--force-start"],
    Arg.Unit (fun () -> force_start#set true),
    "For advanced dynamic uses: force liquidsoap to start \
     even when no active source is initially defined." ;

    ["--debug"],
    Arg.Unit (fun () -> Log.conf_level#set (max 4 Log.conf_level#get)),
    "Print debugging log messages." ]
    @
    (if Configure.dynlink then
        [["--dynamic-plugins-dir"],
            Arg.String (fun d ->
            Dyntools.load_plugins_dir d),
         "Directory where to look for plugins."]
      else
        [])
    @
    [["--errors-as-warnings"],
    Arg.Set Lang_values.errors_as_warnings,
    "Issue warnings instead of fatal errors for unused variables \
     and ignored expressions. If you are not sure about it, it is better \
     to not use it." ]
    @
    (* Unix.fork is not implemented in Win32. *)
    (if Sys.os_type <> "Win32" then
      [["-d";"--daemon"],
       Arg.Unit (fun f -> Init.conf_daemon#set true),
       "Run in daemon mode."]
     else [])
    @
    [["-t";"--enable-telnet"],
    Arg.Unit (fun _ -> Server.conf_telnet#set true),
    "Enable the telnet server." ;

    ["-T";"--disable-telnet"],
    Arg.Unit (fun _ -> Server.conf_telnet#set false),
    "Disable the telnet server." ;

    ["-u";"--enable-unix-socket"],
    Arg.Unit (fun _ -> Server.conf_socket#set true),
    "Enable the unix socket." ;

    ["-U";"--disable-unix-socket"],
    Arg.Unit (fun _ -> Server.conf_socket#set false),
    "Disable the unix socket." ;

    ["--list-plugins-xml"],
    Arg.Unit (fun () ->
                secondary_task := true ;
                load_libs () ;
                Doc.print_xml (Plug.plugs:Doc.item)),
    Printf.sprintf
      "List all plugins (builtin scripting values, \
       supported formats and protocols), \
       output as XML." ;

    ["--list-plugins"],
    Arg.Unit (fun () ->
                secondary_task := true ;
                load_libs () ;
                Doc.print (Plug.plugs:Doc.item)),
    Printf.sprintf
      "List all plugins (builtin scripting values, \
       supported formats and protocols)." ;

    ["--no-pervasives"],
    Arg.Clear pervasives,
    Printf.sprintf
      "Do not load pervasives script libraries (i.e., %s/*.liq)."
      Configure.libs_dir ;

    ["-i"],
    Arg.Set Configure.display_types,
    "Display infered types." ;

    ["--version"],
    Arg.Unit (fun () ->
                Printf.printf
                  "Liquidsoap %s%s\n\
                   Copyright (c) 2003-2013 Savonet team\n\
                   Liquidsoap is open-source software, \
                   released under GNU General Public License.\n\
                   See <http://liquidsoap.fm> for more information.\n"
                   Configure.version SVN.rev ;
                exit 0),
    "Display liquidsoap's version." ;

    ["--interactive"],
    Arg.Set interactive,
    "Start an interactive interpreter." ;

    ["--"],
    Arg.Unit (fun () -> Arg.current := Array.length Sys.argv - 1),
    "Stop parsing the command-line and pass subsequent items to the script."

    ] @ (LiqConf.args Configure.conf)

let expand_options options =
  let options =
    List.sort (fun (x,_,_) (y,_,_) -> compare x y)  options
  in
  List.fold_left
    (fun l (la,b,c) ->
        let ta = List.hd (List.rev la) in
        let expand =
          List.map
            (fun a -> (a,b,
                       if a = ta then "\n" ^ format_doc c else ""))
            la
        in
        l@expand) [] options

module Make(Runner : Runner_t) =
struct
let () = 
  log#f 3 "Liquidsoap %s%s" Configure.version SVN.rev ;
  log#f 3 "Using:%s" Configure.libs_versions ;
  if Configure.scm_snapshot then
    List.iter (log#f 2 "%s")
      ["";
       "DISCLAIMER: This version of Liquidsoap has been";
       "compiled from a snapshot of the development code.";
       "As such, it should not be used in production";
       "unless you know what you are doing!";
       "";
       "We are, however, very interested in any feedback";
       "about our development code and committed to fix";
       "issues as soon as possible.";
       "";
       "If you are interested in collaborating to";
       "the development of Liquidsoap, feel free to";
       "drop us a mail at <savonet-devl@lists.sf.net>";
       "or to join the #savonet IRC channel on Freenode.";
       "";
       "Please send any bug report or feature request";
       "at <https://github.com/savonet/liquidsoap/issues>.";
       "";
       "We hope you enjoy this snapshot build of Liquidsoap!";
       ""]

(** Just like Arg.parse_argv but with Arg.parse's behavior on errors.. *)
let parse argv l f msg =
  try
    Arg.parse_argv argv l f msg ;
  with
    | Arg.Bad msg -> Printf.eprintf "%s" msg ; exit 2
    | Arg.Help msg -> Printf.printf "%s" msg ; exit 0

let absolute s =
  if String.length s > 0 && s.[0] <> '/' then
    (Unix.getcwd ())^"/"^s
  else
    s

(* Load plugins and dynamic loaded libraries: 
 * these should be loaded as early as possible since we want to be
 * able to use them in scripts... *)
let () =
  Configure.load_dynlinks ();
  Configure.load_plugins_dir Configure.plugins_dir

(* Startup *)
let () =
  Random.self_init () ;
  
  (* Set the default values. *)
  Log.conf_file_path#set_d (Some "<syslogdir>/<script>.log") ;
  Init.conf_daemon_pidfile#set_d (Some true) ;
  Init.conf_daemon_pidfile_path#set_d (Some "<sysrundir>/<script>.pid") ;
  
  (* We only allow evaluation of
   * lazy configuration keys now. *)
  Frame.allow_lazy_config_eval ();
  
  (* Parse command-line, and notably load scripts. *)
  parse Shebang.argv (expand_options Runner.options) (fun s -> eval (`Expr_or_File s)) usage ;
  do_eval ~lib:!last_item_lib
  
(* When the log/pid paths have their definitive values,
 * expand substitutions and check directories.
 * This should be ran just before Dtools init. *)
let check_directories () =
  
  (* Now that the paths have their definitive value, expand <shortcuts>. *)
  let subst conf = conf#set (Configure.subst_vars conf#get) in
  subst Log.conf_file_path ;
  subst Init.conf_daemon_pidfile_path ;
  
  let check_dir conf_path kind =
    let path = conf_path#get in
    let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then
        let routes = Configure.conf#routes conf_path#ut in
          Printf.printf
            "FATAL ERROR: %s directory %S does not exist.\n\
             To change it, add the following to your script:\n\
            \  set(%S, \"<path>\")\n"
            kind dir (Conf.string_of_path (List.hd routes)) ;
          exit 1
  in
    if Log.conf_file#get then
      check_dir Log.conf_file_path "Log" ;
    if Init.conf_daemon#get && Init.conf_daemon_pidfile#get then
      check_dir Init.conf_daemon_pidfile_path "PID"
  
(* Now that outputs have been defined, we can start the main loop. *)
let () =
  let cleanup () =
    log#f 3 "Shutdown started!" ;
    Clock.stop () ;
    log#f 3 "Waiting for threads to terminate..." ;
    Tutils.join_all () ;
    log#f 3 "Cleaning downloaded files..." ;
    Request.clean () ;
    log#f 3 "Freeing memory..." ;
    Gc.full_major ()
  in
  let main () =
    (* See http://caml.inria.fr/mantis/print_bug_page.php?bug_id=4640
     * for this: we want Unix EPIPE error and not SIGPIPE, which
     * crashes the program.. *)
    if Sys.os_type <> "Win32" then
     begin
      Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
      ignore (Unix.sigprocmask Unix.SIG_BLOCK [Sys.sigpipe])
     end;
    (* On Windows we need to initiate shutdown ourselves by catching INT
     * since dtools doesn't do it. *)
    if Sys.os_type = "Win32" then
      Sys.set_signal Sys.sigint
        (Sys.Signal_handle (fun _ -> Tutils.shutdown ())) ;
    (* TODO if start fails (e.g. invalid password or mountpoint) it
     *   raises an exception and dtools catches it so we don't get
     *   a backtrace (by default at least). *)
    Clock.start () ;
    Tutils.main ()
  in
    ignore (Init.at_stop cleanup) ;
    if !interactive then begin
      load_libs () ;
      Log.conf_stdout#set_d (Some false) ;
      Log.conf_file#set_d (Some true) ;
      let default_log =
        Filename.temp_file
          (Printf.sprintf "liquidsoap-%d-" (Unix.getpid ())) ".log"
      in
      Log.conf_file_path#set_d (Some default_log) ;
      ignore (Init.at_stop (fun _ -> Sys.remove default_log)) ;
      check_directories () ;
      ignore (Thread.create Lang.interactive ()) ;
      Init.init main
    end else if Source.has_outputs () || force_start#get then
      if not !dont_run then begin
        check_directories () ;
        Init.init ~prohibit_root:true main
      end else
        cleanup ()
    else
      (* If there's no output and no secondary task has been performed,
       * warn the user that his scripts didn't define any output. *)
      if not !secondary_task then
        Printf.printf "No output defined, nothing to do.\n"
end
