let static_tests =
  [
    "icecast_ssl.liq";
    "icecast_tls.liq";
    "icecast_tls_ssl.liq";
    "icecast_ssl_tls.liq";
  ]

let () =
  let location = Sys.getcwd () in
  let tests =
    List.filter
      (fun f ->
        (not (List.mem (Filename.basename f) static_tests))
        && Filename.extension f = ".liq")
      (Build_tools.read_files ~location "")
  in
  List.iter
    (fun test ->
      Printf.printf
        {|
(rule
 (alias citest)
 (package liquidsoap)
 (deps
  %s
  ./file1.mp3
  ./file2.mp3
  ./file3.mp3
  ./jingle1.mp3
  ./jingle2.mp3
  ./jingle3.mp3
  ./file1.png
  ./file2.png
  ./jingles
  ./playlist
  ./huge_playlist
  ./crossfade-plot.old.txt
  ./crossfade-plot.new.txt
  ../../src/bin/liquidsoap.exe
  (package liquidsoap)
  (:test_liq ../test.liq)
  (:run_test ../run_test.exe))
 (action (run %%{run_test} %s liquidsoap %%{test_liq} %s)))
  |}
        test test test)
    tests
