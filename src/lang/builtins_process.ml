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

open Lang_builtins

let log = Dtools.Log.make ["lang";"run_process"]

let () =
  let ret_t = Lang.product_t
    (Lang.product_t Lang.string_t Lang.string_t)
    (Lang.product_t Lang.string_t Lang.string_t)
  in
  let env_t =
    Lang.product_t Lang.string_t Lang.string_t
  in
  let path_t =
    Lang.list_t Lang.string_t
  in
  add_builtin "run_process" ~cat:Sys
    ~descr:"Run a process in a shell environment. Returns: \
            `((stdout,stderr),status)` where status is one of: \
            `(\"exit\",\"<code>\")`, `(\"killed\",\"<signal number>\")`, \
            `(\"stopped\",\"<signal number>\")`, `(\"exception\",\"<exception description>\")`, \
            `(\"timeout\",\"<run time>\")`."
    ["env",Lang.list_t env_t,
     Some (Lang.list ~t:env_t []),Some "Process environment";
     "inherit_env", Lang.bool_t,
     Some (Lang.bool true), Some "Inherit calling process's environment when \
       `env` parameter is empty.";
     "tmpdir", Lang.string_t, Some (Lang.string Sandbox.conf_tmp#get),
     Some "Temporary directory for sandboxing.";
     "rwdirs", path_t, Some (Lang.list ~t:Lang.string_t (List.map Lang.string Sandbox.conf_rw#get)),
     Some "Read/write directories for sandboxing.";
     "rodirs", path_t, Some (Lang.list ~t:Lang.string_t (List.map Lang.string Sandbox.conf_ro#get)),
     Some "Read-only directories for sandboxing.";
     "network", Lang.bool_t, Some (Lang.bool true),
     Some "Enable or disable network inside sandboxed environment.";
     "timeout", Lang.float_t,Some (Lang.float (-1.)),
     Some "Cancel process after `timeout` has elapsed. Ignored if negative.";
     "",Lang.string_t,None,Some "Command to run"] ret_t
    (fun p ->
       let env = Lang.to_list
         (List.assoc "env" p)
       in
       let env = List.map (fun e ->
         let (k,v) = Lang.to_product e in
         Lang.to_string k, Lang.to_string v) env
       in
       let sandbox_tmp =
         Lang.to_string (List.assoc "tmpdir" p)
       in
       let sandbox_rw =
         List.map Lang.to_string
           (Lang.to_list (List.assoc "rwdirs" p))
       in
       let sandbox_ro =
         List.map Lang.to_string
           (Lang.to_list (List.assoc "rodirs" p))
       in
       let sandbox_network =
         Lang.to_bool (List.assoc "network" p)
       in
       let inherit_env = Lang.to_bool
         (List.assoc "inherit_env" p)
       in
       let env =
         if env = [] && inherit_env then
           Utils.environment ()
         else
           env
       in
       let timeout = Lang.to_float
         (List.assoc "timeout" p)
       in
       let env = List.map
         (fun (k,v) -> Printf.sprintf "%s=%s" k v)
         env
       in
       let env = Array.of_list env in
       let cmd =
         Sandbox.cmd ~tmp:sandbox_tmp ~rw:sandbox_rw ~ro:sandbox_ro
           ~network:sandbox_network (Lang.to_string (List.assoc "" p))
       in
       let buflen = 1024 in
       let out_buf = Buffer.create buflen in
       let err_buf = Buffer.create buflen in
       let on_done (timed_out,status) =
         let stdout = Buffer.contents out_buf in
         let stderr = Buffer.contents err_buf in
         let status, arg =
           match timed_out, status with
             | f, _ when 0. <= f ->
                "timeout", (string_of_float f)
             | _, Some (`Exception e) ->
                "exception", (Printexc.to_string e)
             | _, Some (`Status s) ->
                 begin match s with
                   | Unix.WEXITED c -> "exit", (string_of_int c)
                   | Unix.WSIGNALED s -> "killed", (string_of_int s)
                   | Unix.WSTOPPED s -> "stopped", (string_of_int s)
                 end
             | _ -> assert false
         in
         Lang.product
           (Lang.product (Lang.string stdout) (Lang.string stderr))
           (Lang.product (Lang.string status) (Lang.string arg))
       in
       let synchronous () =
         log#f 4 "Executing %s" cmd;
         let ((in_chan,out_ch,err_chan) as p) = Unix.open_process_full cmd env in
         close_out out_ch;
         let pull buf ch =
           let tmp = Bytes.create 1024 in
           let rec aux () =
             let n = input ch tmp 0 1024 in
               if n = 0 then () else
                begin
                 Buffer.add_subbytes buf tmp 0 n;
                 aux()
                end
           in
           aux ()
         in
         pull out_buf in_chan;
         pull err_buf err_chan;
         (-1.,Some (`Status (Unix.close_process_full p)))
       in
       let asynchronous () =
         let out_pipe,in_pipe = Unix.pipe () in
         Tutils.finalize ~k:(fun () ->
           ignore(Unix.close in_pipe);
           ignore(Unix.close out_pipe))
           (fun () ->
             let pull buf fn =
               let bytes = Bytes.create buflen in
               let ret = fn bytes 0 buflen in
               Buffer.add_subbytes buf bytes 0 ret;
              `Continue
             in
             let on_stdout = pull out_buf in
             let on_stderr = pull err_buf in
             let status = ref None in
             let on_stop s =
                status := Some s;
                begin
                  try
                    ignore(Unix.write in_pipe (Bytes.of_string " ") 0 1);
                  with _ -> ()
                end;
                false
             in
             let on_start _ =
               `Stop
             in
             log#f 4 "Executing %s" cmd;
             let log s = log#f 4 "%s" s in
             let p = Process_handler.run ~env ~on_start ~on_stop
                       ~on_stdout ~on_stderr ~log cmd
             in
             let timed_out =
               try
                 Tutils.wait_for (`Read out_pipe) timeout ;
                 (-1.)
               with Tutils.Timeout f ->
                 Process_handler.kill p;
                 f
             in
             (timed_out, !status))
       in
       on_done (if 0. <= timeout && Tutils.has_started() then asynchronous() else synchronous ()))
