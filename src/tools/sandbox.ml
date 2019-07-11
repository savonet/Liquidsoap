(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

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

let log = Log.make ["sandbox"]

let conf_sandbox =
  Dtools.Conf.string ~p:(Configure.conf#plug "sandbox")
    "Use sandboxing for external process. One of: `\"enabled\"`, \
     `\"disabled\"` or `\"auto\"`."

let conf_binary =
  Dtools.Conf.string ~p:(conf_sandbox#plug "binary") ~d:"bwrap"
  "Sandbox binary to use."

let conf_tmp =
  Dtools.Conf.string ~p:(conf_sandbox#plug "tmpdir") ~d:(Filename.get_temp_dir_name())
  "Temporary directory."

let conf_rw =
  Dtools.Conf.list ~p:(conf_sandbox#plug "rw") ~d:[]
  "Read/write directories"

let conf_ro =
  Dtools.Conf.list ~p:(conf_sandbox#plug "ro") ~d:["/"]
  "Read-only directories"

let conf_network =
  Dtools.Conf.bool ~p:(conf_sandbox#plug "network") ~d:true
  "Enable network"

let is_docker = lazy (
  Sys.unix && Sys.command "grep 'docker\\|lxc' /proc/1/cgroup >/dev/null 2>&1" = 0
)

let () =
  ignore(Dtools.Init.at_start (fun () ->
    if Lazy.force is_docker then
     begin
      log#important "Running inside a docker container, disabling sandboxing..";
      conf_sandbox#set "disabled" 
     end
    else if Utils.which_opt ~path:Configure.path conf_binary#get = None then
     begin
      log#important "Could not find binary %s, disabling sandboxing.." conf_binary#get;
      conf_sandbox#set "disabled"
     end
    else if conf_sandbox#get = "disabled" then
      log#important "Sandboxing disabled"
    else
     begin
      log#important "Sandboxing using bubblewrap at %s" (Utils.which ~path:Configure.path conf_binary#get);
      log#important "Temporary directory: %s" conf_tmp#get;
      log#important "Read/write directories: %s" (String.concat ", " conf_rw#get);  
      log#important "Read-only directories: %s" (String.concat ", " conf_ro#get);
      log#important "Network allowed: %b" conf_network#get
     end
  ))

type t = string

type sandboxer = {
  init : tmp:string -> network:bool -> t;
  mount: t -> flag:[`Rw|`Ro] -> string -> t;
  cmd:   t -> string -> string
}

let disabled = {
  init = (fun ~tmp:_ ~network:_ -> "");
  mount = (fun t ~flag:_ _ -> t);
  cmd = fun _ cmd -> cmd
} 

let bwrap = {
  init = (fun ~tmp ~network -> Printf.sprintf
    "--new-session \
     --setenv TMPDIR %S --setenv TMP %S --setenv TEMPDIR %S --setenv TEMP %S \
     %s" tmp tmp tmp tmp (if network then "" else "--unshare-net"));
  mount = (fun t ~flag path ->
    match flag with
      | `Ro ->
        Printf.sprintf "%s --ro-bind %S %S" t path path
      | `Rw ->
        Printf.sprintf "%s --bind %S %S" t path path);
   cmd = (fun opts cmd ->
     let binary = Utils.which ~path:Configure.path conf_binary#get in
     Printf.sprintf "%s %s --tmpfs /run --proc /proc --dev /dev %s" binary opts cmd)
}

let cmd ?tmp ?rw ?ro ?network cmd =
  let sandboxer =
    (* This is intended to be extendable with more tools in the
       future.. *)
    match conf_sandbox#get with
      | "disabled" -> disabled
      | _ -> bwrap
  in
  let f d v =
    match v with
      | None -> d
      | Some v -> v
  in
  let tmp = f conf_tmp#get tmp in
  let rw = f conf_rw#get rw in
  let ro = f conf_ro#get ro in
  let network = f conf_network#get network in
  let t = sandboxer.init ~tmp ~network in
  let t =
    List.fold_left (fun t path -> sandboxer.mount t ~flag:`Ro path) t ro
  in
  let t =
    sandboxer.mount t ~flag:`Rw tmp
  in
  let t =
    List.fold_left (fun t path -> sandboxer.mount t ~flag:`Rw path) t rw
  in
  let cmd =
    sandboxer.cmd t cmd
  in
  log#debug "Command: %s" cmd;
  cmd
   
