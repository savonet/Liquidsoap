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

open Mm

let log = Log.make ["input"; "jack"]
let bjack_clock = Tutils.lazy_cell (fun () -> new Clock.clock "bjack")

class jack_in ~kind ~clock_safe ~on_start ~on_stop ~fallible ~autostart
  ~nb_blocks ~server =
  let samples_per_frame = AFrame.size () in
  let samples_per_second = Lazy.force Frame.audio_rate in
  let seconds_per_frame = float samples_per_frame /. float samples_per_second in
  let bytes_per_sample = 2 in

  object (self)
    inherit
      Start_stop.active_source
        ~name:"input.jack" ~content_kind:kind ~clock_safe ~on_start ~on_stop
          ~fallible ~autostart () as active_source

    inherit Source.no_seek
    inherit [Bytes.t] IoRing.input ~nb_blocks as ioring

    method private wake_up l =
      active_source#wake_up l;
      (* We need to know the number of channels to initialize the ioring. We
           defer this until the kind is known. *)
      let blank () =
        Bytes.make
          (samples_per_frame * self#audio_channels * bytes_per_sample)
          '0'
      in
      ioring#init blank

    method private sleep =
      active_source#sleep;
      ioring#sleep

    method abort_track = ()
    method remaining = -1
    val mutable sample_freq = samples_per_second
    val mutable device = None
    method self_sync = (`Dynamic, device <> None)

    method close =
      match device with
        | Some d ->
            Bjack.close d;
            device <- None
        | None -> ()

    method private get_device =
      match device with
        | None ->
            let server_name = match server with "" -> None | s -> Some s in
            let dev =
              try
                Bjack.open_t ~rate:samples_per_second
                  ~bits_per_sample:(bytes_per_sample * 8)
                  ~input_channels:self#audio_channels ~output_channels:0
                  ~flags:[] ?server_name
                  ~ringbuffer_size:
                    (nb_blocks * samples_per_frame * bytes_per_sample)
                  ~client_name:self#id ()
              with Bjack.Open ->
                failwith "Could not open JACK device: is the server running?"
            in
            Bjack.set_all_volume dev 100;
            device <- Some dev;
            dev
        | Some d -> d

    method private pull_block block =
      let dev = self#get_device in
      let length = Bytes.length block in
      let ans = ref (Bjack.read dev length) in
      while String.length !ans < length do
        Thread.delay (seconds_per_frame /. 2.);
        let len = length - String.length !ans in
        let tmp = Bjack.read dev len in
        ans := !ans ^ tmp
      done;
      String.blit !ans 0 block 0 length

    method private get_frame buf =
      assert (0 = AFrame.position buf);
      let buffer = ioring#get_block in
      let fbuf = AFrame.pcm buf in
      Audio.S16LE.to_audio
        (Bytes.unsafe_to_string buffer)
        0 fbuf 0 samples_per_frame;
      AFrame.add_break buf samples_per_frame

    method reset = ()
  end

let () =
  let kind = Lang.audio_pcm in
  let return_t = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "input.jack"
    (Start_stop.active_source_proto ~clock_safe:true ~fallible_opt:(`Yep false)
    @ [
        ( "buffer_size",
          Lang.int_t,
          Some (Lang.int 2),
          Some "Set buffer size, in frames. Must be >= 1." );
        ( "server",
          Lang.string_t,
          Some (Lang.string ""),
          Some "Jack server to connect to." );
      ])
    ~meth:(Start_stop.meth ()) ~return_t ~category:`Input
    ~descr:"Get stream from jack."
    (fun p ->
      let clock_safe = Lang.to_bool (List.assoc "clock_safe" p) in
      let fallible = Lang.to_bool (List.assoc "fallible" p) in
      let autostart = Lang.to_bool (List.assoc "start" p) in
      let on_start =
        let f = List.assoc "on_start" p in
        fun () -> ignore (Lang.apply f [])
      in
      let on_stop =
        let f = List.assoc "on_stop" p in
        fun () -> ignore (Lang.apply f [])
      in
      let nb_blocks = Lang.to_int (List.assoc "buffer_size" p) in
      let server = Lang.to_string (List.assoc "server" p) in
      let kind = Kind.of_kind kind in
      (new jack_in
         ~kind ~clock_safe ~nb_blocks ~server ~fallible ~on_start ~on_stop
         ~autostart
        :> Start_stop.active_source))
