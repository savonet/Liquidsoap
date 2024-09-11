open Term_hash

type t = { env : (string * Value.t) list; parsed_term : Parsed_term.t }
[@@deriving hash]

let cache_filename ?name parsed_term =
  let report fn =
    match name with
      | None -> fn ()
      | Some name -> Startup.time (Printf.sprintf "%s hash computation" name) fn
  in
  let hash =
    report (fun () ->
        hash { env = Environment.default_environment (); parsed_term })
  in
  Printf.sprintf "%s.liq-cache" hash

let retrieve ?name ?(dirtype = `User) parsed_term : Term.t option =
  if Cache.enabled () then (
    let report fn =
      match name with
        | None -> fn ()
        | Some name ->
            Startup.time (Printf.sprintf "%s cache retrieval" name) fn
    in
    report (fun () ->
        Cache.retrieve ?name ~dirtype (cache_filename ?name parsed_term)))
  else None

let cache ?(dirtype = `User) ~parsed_term term =
  Cache.store ~dirtype (cache_filename parsed_term) term
