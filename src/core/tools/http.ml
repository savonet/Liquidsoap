type uri = {
  protocol : string;
  host : string;
  port : int option;
  path : string;
}

type event = Cry.event
type socket = Cry.socket
type transport = Cry.transport

let connect = Cry.unix_connect
let unix_transport = Cry.unix_transport
let unix_socket = Cry.unix_socket
let user_agent = Configure.vendor

let args_split s =
  let args = Hashtbl.create 2 in
  let fill_arg arg =
    match Pcre.split ~pat:"=" arg with
      | e :: l ->
          (* There should be only arg=value *)
          List.iter
            (fun v ->
              Hashtbl.replace args (Lang_string.url_decode e)
                (Lang_string.url_decode v))
            l
      | [] -> ()
  in
  List.iter fill_arg (Pcre.split ~pat:"&" s);
  args

let parse_url url =
  let basic_rex =
    Pcre.regexp "^([Hh][Tt][Tt][Pp][sS]?)://([^/:]+)(:[0-9]+)?(/.*)?$"
  in
  let sub =
    try Pcre.exec ~rex:basic_rex url
    with Not_found -> (* raise Invalid_url *)
                      failwith "Invalid URL."
  in
  let protocol = Pcre.get_substring sub 1 in
  let host = Pcre.get_substring sub 2 in
  let port =
    try
      let port = Pcre.get_substring sub 3 in
      let port = String.sub port 1 (String.length port - 1) in
      let port = int_of_string port in
      Some port
    with Not_found -> None
  in
  let path = try Pcre.get_substring sub 4 with Not_found -> "/" in
  { protocol; host; port; path }

let is_url path = Pcre.pmatch ~pat:"^[Hh][Tt][Tt][Pp][sS]?://.+" path

let dirname url =
  let rex = Pcre.regexp "^([Hh][Tt][Tt][Pp][sS]?://.+/)[^/]*$" in
  let s = Pcre.exec ~rex url in
  Pcre.get_substring s 1

(* An ugly code to read until we see [\r]?\n n times. *)
let read_crlf ?(log = fun _ -> ()) ?(max = 4096) ?(count = 2) ~timeout
    (socket : socket) =
  (* We read until we see [\r]?\n n times *)
  let ans = Buffer.create 10 in
  let n = ref 0 in
  let count_n = ref 0 in
  let stop = ref false in
  let c = Bytes.create 1 in
  (* We need to parse char by char because
   * we want to make sure we stop at the exact
   * end of [\r]?\n in order to pass a socket
   * which is placed at the exact char after it.
   * The maximal length is a security but it may
   * be lifted.. *)
  while !count_n < count && !n < max && not !stop do
    (* This is quite ridiculous but we have
     * no way to know how much data is available
     * in the socket.. *)
    socket#wait_for ~log `Read timeout;
    let h = socket#read c 0 1 in
    if h < 1 then stop := true
    else (
      let c = Bytes.get c 0 in
      Buffer.add_char ans c;
      if c = '\n' then incr count_n else if c <> '\r' then count_n := 0);
    incr n
  done;
  Buffer.contents ans

let read ~timeout (socket : socket) len =
  if len = 0 then ""
  else (
    socket#wait_for `Read timeout;
    let buf = Bytes.create len in
    let len = socket#read buf 0 len in
    Bytes.sub_string buf 0 len)

let really_read ~timeout (socket : socket) len =
  let start_time = Unix.gettimeofday () in
  let buf = Buffer.create len in
  let rec f () =
    let now = Unix.gettimeofday () in
    let remaining = start_time +. timeout -. now in
    if remaining <= 0. then failwith "timeout!";
    socket#wait_for `Read remaining;
    let rem = len - Buffer.length buf in
    let s = Bytes.create rem in
    let n = socket#read s 0 rem in
    Buffer.add_subbytes buf s 0 n;
    if n = 0 || Buffer.length buf = len then Buffer.contents buf else f ()
  in
  f ()

(* Read chunked transfer. *)
let read_chunked ~timeout (socket : socket) =
  let read = read_crlf ~count:1 ~timeout socket in
  let len = List.hd (Pcre.split ~pat:"[\r]?\n" read) in
  let len = List.hd (Pcre.split ~pat:";" len) in
  let len = int_of_string ("0x" ^ len) in
  let s = really_read socket ~timeout len in
  ignore (read_crlf ~count:1 ~timeout socket);
  (s, len)
