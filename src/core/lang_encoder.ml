(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2023 Savonet team

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

open Liquidsoap_lang
open Term
open Term.Ground

module V = Lang_core.MkAbstract (struct
  type content = Encoder.format

  let name = "encoder"
  let descr = Encoder.string_of_format

  let to_json ~pos _ =
    Runtime_error.raise ~pos
      ~message:(Printf.sprintf "Encoders cannot be represented as json")
      "json"

  let compare = Stdlib.compare
end)

module L = struct
  (** Type of audio formats that can encode frame of a given kind. *)
  let format_t ?pos k =
    Type.make ?pos
      (Type.Constr { Type.constructor = "format"; params = [(`Covariant, k)] })

  let to_format = V.of_value
  let format = V.to_value
end

let has_started = ref false
let () = Lifecycle.before_start (fun () -> has_started := true)

let raise_error ~pos message =
  match !has_started with
    | false -> raise (Lang_error.Encoder_error (pos, message))
    | true ->
        Runtime_error.raise ~message
          ~pos:(match pos with None -> [] | Some pos -> [pos])
          "encoder"

let raise_generic_error (l, t) =
  match t with
    | `Value v ->
        raise_error ~pos:v.Value.pos
          (Printf.sprintf
             "unknown parameter name (%s) or invalid parameter value (%s)" l
             (Value.to_string v))
    | `Encoder _ -> raise_error ~pos:None "unexpected subencoder"

(* An encoder. *)
type encoder = {
  (* Compute the kind of the encoder. *)
  type_of_encoder : Term.encoder_params -> Type.t Frame.Fields.t;
  (* Actually create the encoder. *)
  make : Hooks.encoder_params -> Encoder.format;
}

let encoders = ref []

(** Register an encoder. *)
let register name type_of_encoder make =
  encoders := (name, { type_of_encoder; make }) :: !encoders

(** Find an encoder with given name. *)
let find_encoder name = List.assoc name !encoders

let channels_of_params ?(default = 2) p =
  match
    List.find_map
      (function
        | "", `Term { term = Ground (String "stereo") } -> Some 2
        | "", `Term { term = Ground (String "mono") } -> Some 1
        | "stereo", `Term { term = Ground (Bool b); _ } ->
            Some (if b then 2 else 1)
        | "stereo", `Term ({ t = { Type.pos } } as tm) ->
            raise_error ~pos
              (Printf.sprintf
                 "Invalid value %s for stereo mode. Only static `true` or \
                  `false` are allowed."
                 (Term.to_string tm))
        | "mono", `Term { term = Ground (Bool b); _ } ->
            Some (if b then 1 else 2)
        | "mono", `Term ({ t = { Type.pos } } as tm) ->
            raise_error ~pos
              (Printf.sprintf
                 "Invalid value %s for mono mode. Only static `true` or \
                  `false` are allowed."
                 (Term.to_string tm))
        | "channels", `Term { term = Ground (Int n) } -> Some n
        | "channels", `Term ({ t = { Type.pos } } as tm) ->
            raise_error ~pos
              (Printf.sprintf
                 "Invalid value %s for channels mode. Only static numbers are \
                  allowed."
                 (Term.to_string tm))
        | _ -> None)
      p
  with
    | Some n -> n
    | None -> default

(** Compute a kind from a non-fully evaluated format. This should give the same
    result than [Encoder.type_of_format] once evaluated... *)
let type_of_encoder ((e, p) : Term.encoder) = (find_encoder e).type_of_encoder p

let type_of_encoder ~pos e =
  let fields = type_of_encoder e in
  let frame_t = Frame_type.make Liquidsoap_lang.Lang.unit_t fields in
  L.format_t ?pos frame_t

let make_encoder ~pos t ((e, p) : Hooks.encoder) =
  try
    let e = (find_encoder e).make p in
    let (_ : Encoder.factory) = Encoder.get_factory e in
    V.to_value e
  with Not_found ->
    raise_error ~pos
      (Printf.sprintf "unsupported format: %s" (Term.to_string t))
