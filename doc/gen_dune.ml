let generated_md =
  [
    ("protocols.md", "--list-protocols-md", None);
    ("reference.md", "--list-functions-md", Some "content/reference-header.md");
    ( "reference-extras.md",
      "--list-extra-functions-md",
      Some "content/reference-header.md" );
    ( "reference-deprecated.md",
      "--list-deprecated-functions-md",
      Some "content/reference-header.md" );
    ("settings.md", "--list-settings", None);
  ]

let mk_html f = Pcre.substitute ~pat:"md(?:\\.in)?$" ~subst:(fun _ -> "html") f

let mk_md ?(content = true) f =
  if Pcre.pmatch ~pat:"md\\.in$" f then
    Pcre.substitute ~pat:"\\.in$" ~subst:(fun _ -> "") (Filename.basename f)
  else if content then "content/" ^ f
  else f

let mk_title = Filename.remove_extension

let mk_subst_rule f =
  if Pcre.pmatch ~pat:"md\\.in$" f then (
    let target = mk_md f in
    Printf.printf
      {|
(rule
  (alias doc)
  (deps
    (:subst_md ./subst_md.exe)
    (:in_md content/%s))
  (target %s)
  (action
    (with-stdout-to %%{target}
      (run %%{subst_md} %%{in_md}))))|}
      f target)

let mk_html_rule ~liq ~content f =
  let liq = liq |> List.map (fun f -> "    " ^ f) |> String.concat "\n" in
  Printf.printf
    {|
(rule
  (alias doc)
  (enabled_if (not %%{bin-available:pandoc}))
  (deps (:no_pandoc no-pandoc))
  (target %s)
  (action (run cp %%{no_pandoc} %%{target})))

(rule
  (alias doc)
  (enabled_if %%{bin-available:pandoc})
  (deps
    liquidsoap.xml
    language.dtd
    template.html
%s
    (:md %s))
  (target %s)
  (action
    (ignore-outputs
      (run pandoc --filter=pandoc-include --syntax-definition=liquidsoap.xml --highlight=pygments %%{md} --metadata pagetitle=%s --template=template.html -o %%{target}))))
|}
    (mk_html f) liq (mk_md ~content f) (mk_html f) (mk_title f)

let mk_generated_rule (file, option, header) =
  let header_deps, header_action, header_close =
    match header with
      | None -> ("", "", "")
      | Some fname ->
          ( [%string {|(:header %{fname})|}],
            {|(progn (cat %{header}) (echo "\n")|},
            ")" )
  in
  let header_action =
    if header_action = "" then "" else "\n      " ^ header_action
  in
  let header_close =
    if header_close = "" then "" else "\n      " ^ header_close
  in
  Printf.printf
    {|
(rule
  (alias doc)
  (deps %s)
  (target %s)
  (action
    (with-stdout-to %s%s
      (setenv PAGER none
        (run %%{bin:liquidsoap} %s)))))%s
|}
    header_deps file file header_action option header_close

let mk_test_rule ~stdlib file =
  let stdlib = stdlib |> List.map (fun f -> "    " ^ f) |> String.concat "\n" in
  Printf.printf
    {|
(rule
  (alias doctest)
  (package liquidsoap)
  (deps
%s
    (:stdlib ../src/libs/stdlib.liq)
    (:test_liq %s)
  )
  (action (run %%{bin:liquidsoap} --no-stdlib %%{stdlib} --check --no-fallible-check %s))
)
|}
    stdlib file file

let mk_html_install f =
  Printf.sprintf {|    (%s as html/%s)|} (mk_html f) (mk_html f)

let rec readdir ?(cur = []) ~location dir =
  List.fold_left
    (fun cur file ->
      let file = Filename.concat dir file in
      if Sys.is_directory (Filename.concat location file) then
        readdir ~cur ~location file
      else file :: cur)
    cur
    (Build_tools.read_files ~location dir)

let () =
  let location = Filename.dirname Sys.executable_name in
  let md =
    Sys.readdir (Filename.concat location "content")
    |> Array.to_list
    |> List.filter (fun f ->
           Filename.extension f = ".md" || Filename.extension f = ".in")
    |> List.sort compare
  in
  let liq =
    Sys.readdir (Filename.concat location "content/liq")
    |> Array.to_list
    |> List.filter (fun f -> Filename.extension f = ".liq")
    |> List.sort compare
    |> List.map (fun f -> "content/liq/" ^ f)
  in
  let stdlib =
    Sys.readdir (Filename.concat location "../src/libs")
    |> Array.to_list
    |> List.filter (fun f -> Filename.extension f = ".liq")
    |> List.sort compare
    |> List.map (fun f -> "../src/libs/" ^ f)
  in
  List.iter mk_generated_rule generated_md;
  List.iter mk_subst_rule md;
  List.iter
    (fun (file, _, _) -> mk_html_rule ~liq ~content:false file)
    generated_md;
  List.iter (mk_html_rule ~liq ~content:true) md;
  List.iter (mk_test_rule ~stdlib) liq;
  let files =
    List.map
      (fun f -> Printf.sprintf {|    (orig/%s as html/%s)|} f f)
      (readdir ~location:(Filename.concat location "orig") "")
    @ List.map (fun (f, _, _) -> mk_html_install f) generated_md
    @ List.map mk_html_install md
  in
  let files = files |> List.sort compare |> String.concat "\n" in
  Printf.printf
    {|
(install
  (section doc)
  (package liquidsoap)
  (files
%s
  )
)
|}
    files
