let () =
  let location = Sys.getcwd () in
  let tests =
    List.filter
      (fun f -> Filename.extension f = ".liq")
      (Array.to_list (Sys.readdir location))
  in
  List.iteri
    (fun pos test ->
      Printf.printf
        {|
(rule
 (alias runtest_%d)
 (package liquidsoap)
 (deps
  %s
  ../media/all_media_files
  ../../src/bin/liquidsoap.exe
  (source_tree ../../src/libs)
  (:stdlib ../../src/libs/stdlib.liq)
  (:test_liq ../test.liq)
  (:run_test ../run_test.exe))
 (action (run %%{run_test} %s liquidsoap %%{test_liq} %s)))
  |}
        (pos mod 2) test test test)
    tests;

  let output_tests =
    List.filter
      (fun f -> Filename.extension f = ".output")
      (Array.to_list (Sys.readdir location))
  in
  List.iter
    (fun test ->
      Printf.printf
        {|
(rule
 (alias runtest)
 (package liquidsoap)
 (deps
  %s
  (:check_output ../check_output.exe)
  (:run_test ../run_test.exe))
 (action (run %%{run_test} %s %%{check_output})))
  |}
        test test)
    output_tests
