(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2022 Savonet team

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

let () =
  Lang.add_module "string.annotate";
  Lang.add_builtin "string.annotate.parse" ~category:`String
    ~descr:
      "Parse a string of the form `<key>=<value>,...:<uri>` as given by the \
       `annotate:` protocol" [("", Lang.string_t, None, None)]
    (Lang.product_t Lang.metadata_t Lang.string_t) (fun p ->
      let v = List.assoc "" p in
      try
        let metadata, uri = Annotate.parse (Lang.to_string v) in
        Lang.product
          (Lang.metadata (Utils.hashtbl_of_list metadata))
          (Lang.string uri)
      with Annotate.Error err ->
        raise
          (Runtime_error.Runtime_error
             {
               Runtime_error.kind = "string";
               msg = err;
               pos = (match v.Value.pos with None -> [] | Some p -> [p]);
             }))

let () =
  Lang.add_builtin "string.recode" ~category:`String
    ~descr:"Convert a string. Effective only if Camomile is enabled."
    [
      ( "in_enc",
        Lang.nullable_t Lang.string_t,
        Some Lang.null,
        Some "Input encoding. Autodetected if null." );
      ( "out_enc",
        Lang.string_t,
        Some (Lang.string "UTF-8"),
        Some "Output encoding." );
      ("", Lang.string_t, None, None);
    ]
    Lang.string_t
    (fun p ->
      let in_enc =
        Lang.to_valued_option Lang.to_string (List.assoc "in_enc" p)
      in
      let out_enc = Lang.to_string (List.assoc "out_enc" p) in
      let string = Lang.to_string (List.assoc "" p) in
      Lang.string (Camomile_utils.recode_tag ?in_enc ~out_enc string))

let () =
  Lang.add_module "string.base64";
  Lang.add_module "url"

let () =
  Lang.add_builtin "string.base64.decode" ~category:`String
    ~descr:"Decode a Base64 encoded string." [("", Lang.string_t, None, None)]
    Lang.string_t (fun p ->
      let string = Lang.to_string (List.assoc "" p) in
      try Lang.string (Utils.decode64 string)
      with _ ->
        Runtime_error.error ~message:"Invalid base64 string!" "invalid")

let () =
  Lang.add_builtin "string.base64.encode" ~category:`String
    ~descr:"Encode a string in Base64." [("", Lang.string_t, None, None)]
    Lang.string_t (fun p ->
      let string = Lang.to_string (List.assoc "" p) in
      Lang.string (Utils.encode64 string))

let () =
  Lang.add_builtin "url.decode" ~category:`String
    ~descr:"Decode an encoded url (e.g. \"%20\" becomes \" \")."
    [
      ("plus", Lang.bool_t, Some (Lang.bool true), None);
      ("", Lang.string_t, None, None);
    ]
    Lang.string_t
    (fun p ->
      let plus = Lang.to_bool (List.assoc "plus" p) in
      let string = Lang.to_string (List.assoc "" p) in
      Lang.string (Http.url_decode ~plus string))

let () =
  Lang.add_builtin "url.encode" ~category:`String
    ~descr:"Encode an url (e.g. \" \" becomes \"%20\")."
    [
      ("plus", Lang.bool_t, Some (Lang.bool true), None);
      ("", Lang.string_t, None, None);
    ]
    Lang.string_t
    (fun p ->
      let plus = Lang.to_bool (List.assoc "plus" p) in
      let string = Lang.to_string (List.assoc "" p) in
      Lang.string (Http.url_encode ~plus string))

let () =
  Lang.add_builtin "%" ~category:`String
    ~descr:
      "`pattern % [...,(k,v),...]` changes in the pattern occurrences of:\n\n\
       - `$(k)` into `v`\n\
       - `$(if $(k2),\"a\",\"b\") into \"a\" if k2 is found in the list, \"b\" \
       otherwise."
    [("", Lang.string_t, None, None); ("", Lang.metadata_t, None, None)]
    Lang.string_t (fun p ->
      let s = Lang.to_string (Lang.assoc "" 1 p) in
      let l =
        List.map
          (fun p ->
            let a, b = Lang.to_product p in
            (Lang.to_string a, Lang.to_string b))
          (Lang.to_list (Lang.assoc "" 2 p))
      in
      Lang.string (Utils.interpolate (fun k -> List.assoc k l) s))

let () =
  Lang.add_builtin "string.id" ~category:`String
    ~descr:"Generate an identifier with given operator name."
    [("", Lang.string_t, None, Some "Operator name.")] Lang.string_t (fun p ->
      let name = List.assoc "" p |> Lang.to_string in
      Lang.string (Source.generate_id name))

let () =
  Lang.add_module "string.apic";
  let t =
    Lang.method_t Lang.string_t
      [
        ("mime", ([], Lang.string_t), "Mime type");
        ("picture_type", ([], Lang.int_t), "Picture type");
        ("description", ([], Lang.string_t), "Description");
      ]
  in
  Lang.add_builtin "string.apic.parse" ~category:`File
    [("", Lang.string_t, None, Some "APIC data.")] t
    ~descr:
      "Parse APIC ID3v2 tags (such as those obtained in the APIC tag from \
       `file.metadata.id3v2`). The returned values are: mime, picture type, \
       description, and picture data." (fun p ->
      let apic = Lang.to_string (List.assoc "" p) in
      let apic = Metadata.ID3v2.parse_apic apic in
      Lang.meth
        (Lang.string apic.Metadata.ID3v2.data)
        [
          ("mime", Lang.string apic.Metadata.ID3v2.mime);
          ("picture_type", Lang.int apic.Metadata.ID3v2.picture_type);
          ("description", Lang.string apic.Metadata.ID3v2.description);
        ])
