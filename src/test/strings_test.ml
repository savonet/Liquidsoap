let () =
  let buf = Strings.of_list ["a"; "bc"; ""; "de"] in
  assert (Strings.length buf = 5);
  assert (Strings.to_string buf = "abcde");
  let b = Bytes.create 2 in
  assert (Strings.to_string (Strings.drop buf 1) = "bcde");
  assert (Strings.to_string (Strings.drop buf 2) = "cde");
  assert (Strings.to_string (Strings.drop buf 5) = "");
  assert (Strings.to_string (Strings.keep buf 2) = "de");
  assert (Strings.to_string (Strings.keep buf 3) = "bcde");
  Strings.blit buf 1 b 0 2;
  assert (Bytes.unsafe_to_string b = "bc");
  Strings.blit buf 2 b 0 2;
  assert (Bytes.unsafe_to_string b = "cd");
  assert (Strings.to_string (Strings.sub buf 1 2) = "bc");
  assert (Strings.to_string (Strings.sub buf 2 2) = "cd")
