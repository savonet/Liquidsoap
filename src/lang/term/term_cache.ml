open Term_hash

type t = {
  env : (string * Value.t) list;
  trim : bool;
  parsed_term : Parsed_term.t;
}
[@@deriving hash]

let cache_filename ?name ~trim parsed_term =
  let report fn =
    match name with
      | None -> fn ()
      | Some name -> Startup.time (Printf.sprintf "%s hash computation" name) fn
  in
  let hash =
    report (fun () ->
        hash { env = Environment.default_environment (); trim; parsed_term })
  in
  Printf.sprintf "%s.liq-cache" hash

let retrieve ?name ~trim parsed_term : Term.t option =
  let report fn =
    match name with
      | None -> fn ()
      | Some name -> Startup.time (Printf.sprintf "%s cache retrieval" name) fn
  in
  report (fun () ->
      if Cache.enabled () then
        Cache.retrieve ?name (cache_filename ?name ~trim parsed_term)
      else None)

let cache ~trim ~parsed_term term =
  Cache.store (cache_filename ~trim parsed_term) term
