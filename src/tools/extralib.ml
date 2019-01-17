let id x = x

module List = struct
  include List

  let init n f =
    let rec aux k =
      if k = n then [] else
        (f k)::(aux (k+1))
    in
    aux 0

  let rec may_map f = function
    | x::t ->
      (
        match f x with
        | Some x -> x::(may_map f t)
        | None -> may_map f t
      )
    | [] -> []

  let rec assoc_nth l n = function
    | [] -> raise Not_found
    | (x,v)::t when x = l ->
      if n = 0 then
        v
      else
        assoc_nth l (n-1) t
    | _::t -> assoc_nth l n t

  let assoc_all x l =
    may_map (fun (y,v) -> if x = y then Some v else None) l

  let rec last = function
    | [x] -> x
    | _::l -> last l
    | [] -> raise Not_found
end

module String = struct
  include String

  let split_char c s =
    let rec aux res n =
      try
        let n' = index_from s n c in
        let s0 = sub s n (n'-n) in
        aux (s0::res) (n'+1)
      with
      | Not_found ->
        (if n = 0 then s else sub s n (length s - n)) :: res
    in
    List.rev (aux [] 0)
end

let read_retry read s buf off len =
  let r = ref 0 in
  let loop = ref true in
  while !loop do
    let n = read s buf (off + !r) (len - !r) in
    r := !r + n;
    loop := !r <> 0 && !r < len
  done;
  !r

open Unix

(* Adapted from unix.ml *)

let shell = "/bin/sh"

let rec waitpid_non_intr pid =
  try waitpid [] pid
  with Unix_error (EINTR, _, _) -> waitpid_non_intr pid

let rec file_descr_not_standard fd =
  let fd = Obj.magic fd in
  if fd >= 3 then fd else file_descr_not_standard (dup fd)

let safe_close fd =
  try close fd with Unix_error(_,_,_) -> ()

let perform_redirections new_stdin new_stdout new_stderr =
  let new_stdin = file_descr_not_standard new_stdin in
  let new_stdout = file_descr_not_standard new_stdout in
  let new_stderr = file_descr_not_standard new_stderr in
  (*  The three dup2 close the original stdin, stdout, stderr,
      which are the descriptors possibly left open
      by file_descr_not_standard *)
  dup2 ~cloexec:false new_stdin stdin;
  dup2 ~cloexec:false new_stdout stdout;
  dup2 ~cloexec:false new_stderr stderr;
  safe_close new_stdin;
  safe_close new_stdout;
  safe_close new_stderr

 let open_proc prog args envopt input output error =
  match fork() with
    | 0 -> perform_redirections input output error;
      (match envopt with
         | Some env -> execve prog args env
         | None     -> execv prog args)
    | id -> id

let open_process_args_full prog args env =
  let (in_read, in_write) = pipe ~cloexec:true () in
  let (out_read, out_write) =
    try pipe ~cloexec:true ()
    with e -> close in_read; close in_write; raise e in
  let (err_read, err_write) =
    try pipe ~cloexec:true ()
    with e -> close in_read; close in_write;
              close out_read; close out_write; raise e in
  let inchan = in_channel_of_descr in_read in
  let outchan = out_channel_of_descr out_write in
  let errchan = in_channel_of_descr err_read in
  let pid =
    try
      open_proc prog args (Some env) out_read in_write err_write
    with e ->
      close out_read; close out_write;
      close in_read; close in_write;
      close err_read; close err_write;
      raise e
  in
  close out_read;
  close in_write;
  close err_write;
  (pid, inchan, outchan, errchan)

let open_process_shell fn cmd =
  fn shell [|shell; "-c"; cmd|]

let open_process_full cmd =
  open_process_shell open_process_args_full cmd

let close_process_full (inchan, outchan, errchan) =
  close_in inchan;
  begin try close_out outchan with Sys_error _ -> () end;
  close_in errchan

module Unix = struct
  include Unix

  let read_retry = read_retry Unix.read
end
