(* -*- mode: tuareg; -*- *)
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
  
let log = Dtools.Log.make [ "server" ]
  
let conf =
  Conf.void ~p: (Configure.conf#plug "server") "Server configuration"
    ~comments:
      [ "The server is an abstract text-command-based communication protocol, ";
        "which can be used through several interfaces." ]
  
let conf_timeout =
  Conf.float ~p: (conf#plug "timeout") ~d: 30.
    "Timeout for read/write operations."
    ~comments: [ "A negative value disables timeout." ]
  
let get_timeout () =
  let t = conf_timeout#get in if t < 0. then infinity else t
  
let conf_socket =
  Conf.bool ~p: (conf#plug "socket") ~d: false
    "Support for communication via a UNIX domain socket interface"
    ~comments:
      [ "The main advantage of this method is that you can set very precisely";
        "the access permissions for the socket, just like for any other file.";
        "A useful command to use this interface is: \"socat stdin unix:<path>\"." ]
  
let conf_socket_path =
  Conf.string ~p: (conf_socket#plug "path") ~d: "<sysrundir>/<script>.sock"
    "Path of the UNIX domain socket"
    ~comments:
      [ "In this filename, <pid>, <script> and <sysrundir> are replaced by ";
        "their respective values: PID of the instance of liquidsoap,";
        "base name of the .liq script (if any), default runtime data directory." ]
  
let conf_socket_perms =
  Conf.int ~p: (conf_socket#plug "permissions") ~d: 0o600
    "Socket permissions, up to umask"
    ~comments:
      [ "This parameter is better written in octal notation. Although you can ";
        "write octal numbers like 0o660, they are not displayed back in octal. ";
        "For example, the default value 384 is the decimal for 0o600." ]
  
let conf_telnet =
  Conf.bool ~p: (conf#plug "telnet") ~d: false
    "Support for communication via a telnet interface"
    ~comments:
      [ "This allows you to communicate with the server via a telnet interface,";
        "i.e., a simple text-based communication over TCP.";
        "The standard \"telnet\" command will allow you to communicate through";
        "that interface, as well as the telnet libraries available in most";
        "script languages.";
        "Since there is currently no authentication, you should be careful";
        "about who can access this interface: either restrict it to connections";
        "from localhost (using the bind_addr param) or set up a firewall." ]
  
let conf_telnet_bind_addr =
  Conf.string ~p: (conf_telnet#plug "bind_addr") ~d: "127.0.0.1"
    "Network mask from which the telnet server should accept connections"
  
let conf_telnet_port =
  Conf.int ~p: (conf_telnet#plug "port") ~d: 1234
    "Port on which the telnet server should listen"
  
let conf_telnet_revdns =
  Conf.bool ~p: (conf_telnet#plug "reverse_dns") ~d: true
    "Perform reverse DNS lookup to get the client's hostname from its IP."
  
let log = Log.make [ "server" ]
  
exception Duppy of Duppy.Io.failure
  
(* {1 Manage available commands and namespaces}
 *
 * This needs to be thread safe: (un)registering is done in wakeup/sleep
 * which can be called from arbitrary clock threads. *)
type namespace = string list

let lock = Mutex.create ()
  
let namespaces = Hashtbl.create 10
  
let commands : (string, ((string -> string) * string * string)) Hashtbl.t =
  Hashtbl.create 50
  
(* First, get a fresh namespace *)
let register ns kind =
  let c = ref 0 in
  let mkns () = if !c = 0 then ns else ns @ [ string_of_int !c ] in
  let ns () =
    (while Hashtbl.mem namespaces (mkns ()) do incr c done; mkns ())
  in
    Tutils.mutexify lock
      (fun () -> let ns = ns () in (Hashtbl.add namespaces ns kind; ns)) ()
  
let to_string = String.concat "."
  
let rec prefix_ns cmd ns = to_string (ns @ [ cmd ])
  
(* Then add your commands to that namespace *)
let add ~ns ?usage ~descr cmd handler =
  let usage = match usage with | None -> cmd | Some u -> u in
  let usage = prefix_ns usage ns
  in
    Tutils.mutexify lock
      (fun () ->
         let name = prefix_ns cmd ns
         in
           (if Hashtbl.mem commands name
            then
              log#f 2
                "Server command %s already registered! Previous definition \
                    replaced.."
                name
            else ();
            Hashtbl.replace commands (prefix_ns cmd ns)
              (handler, usage, descr)))
      ()
  
(* ... maybe remove them *)
let remove ~ns cmd =
  Tutils.mutexify lock (fun () -> Hashtbl.remove commands (prefix_ns cmd ns))
    ()
  
let unregister ns =
  Tutils.mutexify lock
    (fun () ->
       let ns_str = to_string ns in
       let ns_len = String.length ns_str in
       let is_prefix cmd =
         ((String.length cmd) > ns_len) &&
           (ns_str = (String.sub cmd 0 ns_len)) in
       let to_remove =
         Hashtbl.fold (fun cmd _ l -> if is_prefix cmd then cmd :: l else l)
           commands []
       in
         (List.iter (Hashtbl.remove commands) to_remove;
          Hashtbl.remove namespaces ns))
    ()
  
(* The usage string sums up all the commands... *)
let usage () =
  let l =
    Tutils.mutexify lock
      (fun () -> Hashtbl.fold (fun k v l -> (k, v) :: l) commands []) () in
  let compare (x, _) (y, _) = compare x y in
  let l = List.sort compare l
  in
    List.fold_left
      (fun s (k, (h, u, _)) -> s ^ (Printf.sprintf "\r\n| %s" u)) "" l
  
(** {1 Handling of a client} *)
(** The very-builtin commands *)
let () =
  let add = add ~ns: []
  in
    (add "exit" ~descr: "Close current server session."
       (fun args -> raise Exit);
     add "quit" ~descr: "Close current server session."
       (fun args -> raise Exit);
     add "help" ~usage: "help [<command>]"
       ~descr: "Get information on available commands."
       (fun args ->
          try
            let args =
              Pcre.substitute ~pat: "\\s*" ~subst: (fun _ -> "") args in
            let (_, us, d) =
              Tutils.mutexify lock (Hashtbl.find commands) args
            in Printf.sprintf "Usage: %s\r\n  %s" us d
          with
          | Not_found ->
              (if args <> ""
               then "No such command: " ^ (args ^ "\r\n")
               else "") ^
                ("Available commands:" ^
                   ((usage ()) ^
                      ("\r\n\r\n" ^
                         "Type \"help <command>\" for more information."))));
     add "list"
       ~descr: "Get the list of available operators with their interfaces."
       (fun _ ->
          Tutils.mutexify lock
            (fun () ->
               String.concat "\r\n"
                 (Hashtbl.fold
                    (fun k v s ->
                       (Printf.sprintf "%s : %s" (to_string k) v) :: s)
                    namespaces []))
            ()))
  
let exec s =
  let (s, args) =
    try
      let c = String.index s ' '
      in
        ((String.sub s 0 c),
         (String.sub s (c + 1) (((String.length s) - c) - 1)))
    with | Not_found -> (s, "")
  in
    try
      let (command, _, _) = Tutils.mutexify lock (Hashtbl.find commands) s
      in command args
    with | Exit -> raise Exit
    | Not_found ->
        "ERROR: unknown command, type \"help\" to get a \
                      list of commands."
    | e -> Printf.sprintf "ERROR: %s" (Utils.error_message e)
  
let handle_client socket ip =
  let on_error e =
    ((match e with
      | Duppy.Io.Io_error -> ()
      | Duppy.Io.Timeout ->
          log#f 4
            "Timeout reached while communicating to \
                      client %s."
            ip
      | Duppy.Io.Unix (c, p, m) ->
          log#f 4 "%s" (Utils.error_message (Unix.Unix_error (c, p, m)))
      | Duppy.Io.Unknown e -> log#f 3 "%s" (Utils.error_message e));
     Duppy e) in
  let h =
    {
      Duppy.Monad.Io.scheduler = Tutils.scheduler;
      socket = socket;
      data = "";
      on_error = on_error;
    } in
  (* Read and process lines *)
  let process =
    let __pa_duppy_0 =
      Duppy.Monad.Io.read ?timeout: (Some (get_timeout ()))
        ~priority: Tutils.Non_blocking ~marker: (Duppy.Io.Split "[\r\n]+") h
    in
      Duppy.Monad.bind __pa_duppy_0
        (fun req ->
           let __pa_duppy_0 =
             Duppy.Monad.Io.exec ~priority: Tutils.Maybe_blocking h
               (try Duppy.Monad.return (exec req)
                with | e -> Duppy.Monad.raise e)
           in
             Duppy.Monad.bind __pa_duppy_0
               (fun ans ->
                  Duppy.Monad.bind
                    (Duppy.Monad.bind
                       (Duppy.Monad.Io.write
                          ?timeout:
                            (Some (* "BEGIN\r\n"; *) (get_timeout ()))
                          ~priority: Tutils.Non_blocking h ans)
                       (fun () ->
                          Duppy.Monad.Io.write
                            ?timeout: (Some (get_timeout ()))
                            ~priority: Tutils.Non_blocking h "\r\nEND\r\n"))
                    (fun () -> Duppy.Monad.return ()))) in
  let close () = try Unix.close socket with | _ -> () in
  let rec run () =
    let raise =
      function
      | (Exit | Duppy Duppy.Io.Timeout as e) ->
          let on_error e =
            (ignore (on_error e);
             log#f 3 "Client %s disconnected while saying goodbye..!" ip;
             close ()) in
          let msg =
            (match e with
             | Exit -> "Bye!\r\n"
             | Duppy Duppy.Io.Timeout -> "Connection timed out.. Bye!\r\n"
             | _ -> assert false) in
          let exec () = (log#f 3 "Client %s disconnected." ip; close ())
          in
            Duppy.Io.write ~timeout: (get_timeout ())
              ~priority: Tutils.Non_blocking ~on_error ~exec Tutils.scheduler
              ~string: msg socket
      | _ ->
          (log#f 3 "Client %s disconnected without saying goodbye..!" ip;
           close ())
    in Duppy.Monad.run ~return: run ~raise: raise process
  in run ()
  
(* {1 The server} *)
let start_socket () =
  let socket_path = Configure.subst_vars conf_socket_path#get in
  let socket_name = Filename.basename socket_path in
  let socket_dir = Filename.dirname socket_path in
  let bind_addr = Unix.ADDR_UNIX socket_path in
  let rights = conf_socket_perms#get in
  let max_conn = 10 in
  let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let rec incoming _ =
    ((try
        let (socket, caller) = Unix.accept sock in
        let ip = Utils.name_of_sockaddr caller
        in (log#f 3 "New client %s." ip; handle_client socket ip)
      with
      | e ->
          log#f 2 "Failed to accept new client: %S" (Utils.error_message e));
     [ {
         Duppy.Task.priority = Tutils.Non_blocking;
         events = [ `Read sock ];
         handler = incoming;
       } ])
  in
    (* Try to close the socket if exists.. *)
    (Unix.setsockopt sock Unix.SO_REUSEADDR true;
     if not (Utils.dir_exists socket_dir)
     then
       failwith
         (Printf.sprintf "Unknown directory for the socket: %s" socket_dir)
     else ();
     if Sys.file_exists socket_path then Unix.unlink socket_path else ();
     Unix.bind sock bind_addr;
     Unix.listen sock max_conn;
     ignore
       (Dtools.Init.at_stop
          (fun () ->
             (log#f 3 "Unlink %s" socket_name; Unix.unlink socket_path)));
     Unix.chmod socket_path rights;
     Duppy.Task.add Tutils.scheduler
       {
         Duppy.Task.priority = Tutils.Non_blocking;
         events = [ `Read sock ];
         handler = incoming;
       })
  
let start_telnet () =
  let port = conf_telnet_port#get in
  let bind_addr_inet = Unix.inet_addr_of_string conf_telnet_bind_addr#get in
  let bind_addr = Unix.ADDR_INET (bind_addr_inet, port) in
  let max_conn = 10 in
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0
  in
    (* Set TCP_NODELAY on the socket *)
    (Unix.setsockopt sock Unix.TCP_NODELAY true;
     let rec incoming _ =
       ((try
           let (socket, caller) = Unix.accept sock in
           let ip = Utils.name_of_sockaddr caller
           in (log#f 3 "New client: %s." ip; handle_client socket ip)
         with
         | e ->
             log#f 2 "Failed to accept new client: %S"
               (Utils.error_message e));
        [ {
            Duppy.Task.priority = Tutils.Non_blocking;
            events = [ `Read sock ];
            handler = incoming;
          } ])
     in
       (Unix.setsockopt sock Unix.SO_REUSEADDR true;
        Unix.bind sock bind_addr;
        Unix.listen sock max_conn;
        Duppy.Task.add Tutils.scheduler
          {
            Duppy.Task.priority = Tutils.Non_blocking;
            events = [ `Read sock ];
            handler = incoming;
          }))
  
let start () =
  let telnet = conf_telnet#get in
  let socket = conf_socket#get
  in
    if telnet || socket
    then
      (Tutils.need_non_blocking_queue ();
       if telnet then start_telnet () else ();
       if socket then start_socket () else ())
    else ()
  
let () = ignore (Dtools.Init.at_start start)
  
(* Re-wrap exec for external use *)
let exec s = try exec s with | Exit -> "ERROR: Attempt to exit!"
  

