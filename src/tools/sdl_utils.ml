(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

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

open Tsdl

module Gen = Image.Generic

type event = 
        [ `AUDIO
        | `CDROM
        | `EVENTTHREAD
        | `EVERYTHING
        | `JOYSTICK
        | `NOPARACHUTE
        | `TIMER
        | `VIDEO ]

let options : Sdl.Init.t option ref = ref None
let start_ttf = ref false

let check f x =
  match f x with
  | Error (`Msg err) -> failwith err
  | Ok ans -> ans

let init l =
  if !options = None then options := Some Sdl.Init.nothing;
  List.iter (fun e -> options := Some Sdl.Init.(Option.get !options + e)) l

let ttf_init () = start_ttf := true

let () = 
  ignore (Dtools.Init.at_start (fun () ->
      if !start_ttf then check Tsdl_ttf.Ttf.init ();
      match !options with
      | Some o -> check Sdl.init o
      | None -> ()
    ))

module Surface = struct
  let to_img surface =
    let fmt = Sdl.get_surface_format_enum surface in
    match fmt with
    (* let width, height = Sdl.get_surface_size surface in *)
    | _ -> failwith ("img_of_surface: unhandled format " ^ string_of_int (Int32.to_int (Sdl.Pixel.to_uint32 fmt)))

  let of_img surface img =
    assert false
end

(*
(** 8bit surfaces always use a palette *)
let from_8 surface =
  keep_alive surface
    (fun () ->
       let width,height,pitch = Sdlvideo.surface_dims surface in
       let image = Sdlvideo.pixel_data_8 surface in
       let a = Video.Image.create width height in
         for i = 0 to width-1 do
           for j = 0 to height-1 do
             let r,g,b =
               Sdlvideo.get_palette_color surface image.{i+j*pitch}
             in
               Video.Image.set_pixel_rgba a i j (r,g,b,0xff)
           done
         done ;
         a)

(** 16bits surfaces contain specially packed RGB *)
let to_16 rgb surface =
  keep_alive surface
    (fun () ->
       let s = Sdlvideo.pixel_data_16 surface in
       let width,height,pitch = Sdlvideo.surface_dims surface in
       let pitch = pitch/2 in (* initial pitch was in bytes *)
       let fmt = Sdlvideo.surface_format surface in
         assert (width = Video.Image.width rgb && height = Video.Image.height rgb) ;
         assert (fmt.Sdlvideo.amask = 0l && not fmt.Sdlvideo.palette) ;
         for i = 0 to width-1 do
           for j = 0 to height-1 do
             let r,g,b,_ = Video.Image.get_pixel_rgba rgb i j in
             let color =
               ((r lsr fmt.Sdlvideo.rloss) lsl fmt.Sdlvideo.rshift) lor
               ((g lsr fmt.Sdlvideo.gloss) lsl fmt.Sdlvideo.gshift) lor
               ((b lsr fmt.Sdlvideo.bloss) lsl fmt.Sdlvideo.bshift)
             in
               (* TODO Samuel: why did you leave this one commented out?
                * Are you not sure of the above code?
                * let color =
                * Int32.to_int (Sdlvideo.map_RGB surface (r,g,b)) in *)
               s.{i+j*pitch} <- color
           done
         done)

(** 24bits surfaces are standard RGB stored in three different bytes,
  * but the order might vary. *)
let from_24 surface =
  keep_alive surface
    (fun () ->
       let width,height,pitch = Sdlvideo.surface_dims surface in
       let fmt = Sdlvideo.surface_format surface in
       let rgb = Sdlvideo.pixel_data_24 surface in
       let a = Video.Image.create width height in
       let col = Array.make 3 0 in
         for i = 0 to width-1 do
           for j = 0 to height-1 do
             for c = 0 to 2 do
               let c' = if fmt.Sdlvideo.rshift = 0 then c else 2-c in
                 col.(c) <- rgb.{c'+i*3+j*pitch}
             done ;
             Video.Image.set_pixel_rgba a i j (col.(0),col.(1),col.(2),0xff)
           done
         done ;
         a)

(** 32bits surfaces are standard RGBA
  * However, the RGB components are (at least sometimes) packed in
  * a different order as in liquidsoap: 0xAARRGGBB.
  *
  * An alternative implementation, which is surprisingly not sensibly
  * faster, uses SDL blitting directly by casting a char* into an int*.
  * The alpha is masked out because we don't want
  * to see video frames on top of each other on screen.
  * This hack might not work the same on different platforms.
      let s =
        Sdlvideo.create_RGB_surface_from_32
        (Obj.magic rgb.RGB.data)
        ~w:rgb.RGB.width
        ~h:rgb.RGB.height
        ~pitch:rgb.RGB.stride
        (* The masks might be endianness dependent *)
        ~rmask:0xffl ~gmask:0xff00l ~bmask:0xff0000l
        ~amask:0l
      in
        Sdlvideo.blit_surface ~src:s ~dst:surface ()
  *)
let to_32_bigarray rgb fmt width height pitch s =
  for i = 0 to width-1 do
    for j = 0 to height-1 do
      let r,g,b,_ = Video.Image.get_pixel_rgba rgb i j in
      let color =
        Int32.of_int
          ((r lsl fmt.Sdlvideo.rshift) lor
           (g lsl fmt.Sdlvideo.gshift) lor
           (b lsl fmt.Sdlvideo.bshift))
      in
      s.{i+j*pitch} <- color
    done
  done

let to_32 rgb surface =
  keep_alive surface
    (fun () ->
      let width,height,stride = Sdlvideo.surface_dims surface in
      let pitch = stride/4 in
      let fmt = Sdlvideo.surface_format surface in
      assert (width = Video.Image.width rgb && height = Video.Image.height rgb);
      assert (fmt.Sdlvideo.amask = 0l && not fmt.Sdlvideo.palette);
      (*
         if fmt.Sdlvideo.rshift = 16 && fmt.Sdlvideo.gshift = 8 &&
            fmt.Sdlvideo.bshift = 0 && not Configure.big_endian
         then
           let s = Sdlvideo.pixel_data surface in
           let pix = Gen.Pixel.BGR32 in
           let sdl = Gen.make_rgb pix ~stride width height s in
           Video.Image.to_generic rgb sdl
         else
       *)
      to_32_bigarray rgb fmt width height pitch
        (Sdlvideo.pixel_data_32 surface))

let from_32 surface =
  keep_alive surface
    (fun () ->
       let img = Sdlvideo.pixel_data_32 surface in
       let width,height,pitch = Sdlvideo.surface_dims surface in
       let fmt = Sdlvideo.surface_format surface in
       (* pitch is in bytes, convert for int32 array *)
       let pitch = pitch/4 in
       let f = Video.Image.create width height in
         assert (fmt.Sdlvideo.rloss = 0 &&
                 fmt.Sdlvideo.gloss = 0 &&
                 fmt.Sdlvideo.bloss = 0) ;
         let (&&) = Int32.logand in
         let (>>) = Int32.shift_right in
           for i = 0 to width-1 do
             for j = 0 to height-1 do
               let pixel = img.{i+j*pitch} in
               let r =
                 Int32.to_int
                   ((pixel && fmt.Sdlvideo.rmask) >> fmt.Sdlvideo.rshift)
               in
               let g =
                 Int32.to_int
                   ((pixel && fmt.Sdlvideo.gmask) >> fmt.Sdlvideo.gshift)
               in
               let b =
                 Int32.to_int
                   ((pixel && fmt.Sdlvideo.bmask) >> fmt.Sdlvideo.bshift)
               in
               let a =
                 Int32.to_int
                   ((pixel && fmt.Sdlvideo.amask) >> fmt.Sdlvideo.ashift)
               in
                 Video.Image.set_pixel_rgba f i j (r,g,b,a)
             done
           done ;
           f)
*)
