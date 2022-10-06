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

type Type.custom += Kind of (Content_base.kind * Type.t)
type Type.custom += Format of Content_base.format
type Type.constr_t += InternalMedia
type descr = [ `Format of Content_base.format | `Kind of Content_base.kind ]

let get_format = function Format f -> f | _ -> assert false
let get_kind = function Kind k -> k | _ -> assert false

let format_handler f =
  {
    Type.typ = Format f;
    copy_with = (fun _ f -> Format (Content_base.duplicate (get_format f)));
    occur_check = (fun _ _ f -> ignore (get_format f));
    filter_vars =
      (fun _ l f ->
        ignore (get_format f);
        l);
    repr = (fun _ _ f -> `Constr (Content.string_of_format (get_format f), []));
    subtype = (fun _ f f' -> Content_base.merge (get_format f) (get_format f'));
    sup =
      (fun _ f f' ->
        Content_base.merge (get_format f) (get_format f');
        f);
    to_string = (fun f -> Content_base.string_of_format (get_format f));
  }

let format_descr f = Type.Custom (format_handler f)

let string_of_kind (k, ty) =
  match (Type.deref ty).Type.descr with
    | Type.(Custom { typ = Format f }) -> Content.string_of_format f
    | _ ->
        Printf.sprintf "%s(%s)"
          (Content_base.string_of_kind k)
          (Type.to_string ty)

let repr_of_kind repr l (k, ty) =
  match (Type.deref ty).Type.descr with
    | Type.(Custom { typ = Format f }) ->
        `Constr (Content.string_of_format f, [])
    | _ -> `Constr (Content_base.string_of_kind k, [(Type.Covariant, repr l ty)])

let kind_handler k =
  {
    Type.typ = Kind k;
    copy_with =
      (fun copy_with k ->
        let k, ty = get_kind k in
        Kind (k, copy_with ty));
    occur_check =
      (fun occur_check vars k ->
        let _, ty = get_kind k in
        occur_check vars ty);
    filter_vars =
      (fun filter_vars l k ->
        let _, ty = get_kind k in
        filter_vars l ty);
    repr = (fun repr l k -> repr_of_kind repr l (get_kind k));
    subtype =
      (fun subtype k k' ->
        let k, t = get_kind k in
        let k', t' = get_kind k' in
        assert (k = k');
        subtype t t');
    sup =
      (fun sup k k' ->
        let k, t = get_kind k in
        let k', t' = get_kind k' in
        assert (k = k');
        Kind (k, sup t t'));
    to_string = (fun k -> string_of_kind (get_kind k));
  }

let descr descr =
  let k =
    match descr with
      | `Format f -> (Content.kind f, Type.make (format_descr f))
      | `Kind k -> (k, Liquidsoap_lang.Lang.univ_t ())
  in
  Type.Custom (kind_handler k)

let rec content_type ~default ty =
  match (Type.deref ty).Type.descr with
    | Type.Custom { Type.typ = Kind (k, ty) } ->
        content_type ~default:(fun () -> Content_base.default_format k) ty
    | Type.Custom { Type.typ = Format f } -> f
    | Type.Var _ -> default ()
    | _ -> assert false

let internal_media : Type.constr =
  object
    method t = InternalMedia
    method descr = "an internal media type (none, pcm, yuva420p or midi)"

    method satisfied ~subtype:_ ~satisfies:_ b =
      let b = Type.demeth b in
      match (Type.deref b).Type.descr with
        | Type.Custom { Type.typ = Kind (k, _) }
          when Content_base.is_internal_kind k ->
            ()
        | Type.Custom { Type.typ = Format f }
          when Content_base.is_internal_format f ->
            ()
        | _ -> raise Type.Unsatisfied_constraint
  end
