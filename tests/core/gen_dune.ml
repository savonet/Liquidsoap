(* test name, (deps, args) *)
let test_params =
  [
    ("json_test", ("(:json ./json) (:json5 ./json5)", [""]));
    ( "stream_decoder_test",
      ( "(:test_wav ./test.wav) (:test_mp3 ./test.mp3)",
        ["%{test_wav} bla.wav"; "%{test_mp3} bla.wav"] ) );
    ("parsesrt", ("(:test_srt ./test.srt)", ["%{test_srt}"]));
  ]

let () =
  let location = Sys.getcwd () in
  let tests =
    List.sort Stdlib.compare
      (List.filter_map
         (fun f ->
           if f <> "gen_dune.ml" && Filename.extension f = ".ml" then
             Some (Filename.remove_extension f)
           else None)
         (Array.to_list (Sys.readdir location)))
  in
  List.iter
    (fun test ->
      let deps, args =
        match List.assoc_opt test test_params with
          | None -> ("", [""])
          | Some (deps, args) -> (deps, args)
      in
      Printf.printf
        {|
(executable
 (name %s)
 (modules %s)
 (libraries liquidsoap_core liquidsoap_optionals))

(rule
 (alias citest)
 (package liquidsoap)
 (deps
  %s
  (:%s %s.exe))
 (action %s%s%s))

|}
        test test deps test test
        (if List.length args > 1 then "(progn " else "")
        (String.concat " "
           (List.map
              (fun arg -> Printf.sprintf "(run %%{%s} %s)" test arg)
              args))
        (if List.length args > 1 then ")" else ""))
    tests
