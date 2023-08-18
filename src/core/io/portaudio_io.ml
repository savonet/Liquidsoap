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

open Mm

(** Dedicated clock. *)
let get_clock = Tutils.lazy_cell (fun () -> Clock.clock "portaudio")

let initialized = ref false

let () =
  Extra_args.add
    ( ["--list-portaudio-devices"],
      Arg.Unit
        (fun () ->
          Portaudio.init ();
          let c = Portaudio.get_device_count () in
          Printf.printf "Portaudio has %d devices:\n%!" c;
          let rec f p =
            if p < c then (
              let {
                Portaudio.d_name;
                d_host_api;
                d_max_input_channels;
                d_max_output_channels;
                d_default_low_input_latency;
                d_default_low_output_latency;
                d_default_high_input_latency;
                d_default_high_output_latency;
                d_default_sample_rate;
              } =
                Portaudio.get_device_info p
              in
              Printf.printf
                {|
Device ID %d:
- name: %s
- host API: %d
- max input channels: %d
- max output channels: %d
- default low input latency: %.02f
- default low output latency: %.02f
- default high input latency: %.02f
- default high output latency: %.02f
- default sample rate: %.02f
|}
                p d_name d_host_api d_max_input_channels d_max_output_channels
                d_default_low_input_latency d_default_low_output_latency
                d_default_high_input_latency d_default_high_output_latency
                d_default_sample_rate;
              f (p + 1))
          in
          f 0;
          Portaudio.terminate ();
          exit 0),
      "List all available portaudio devices" )

class virtual base =
  object (self)
    inherit Source.no_seek

    initializer
      if not !initialized then (
        Portaudio.init ();
        initialized := true)

    method virtual log : Log.t

    (* TODO: inline this to be more efficient? *)
    method handle lbl f =
      try f () with
        | Portaudio.Error n ->
            let bt = Printexc.get_raw_backtrace () in
            let exn =
              Failure
                (Printf.sprintf "Portaudio error in %s: %s" lbl
                   (Portaudio.string_of_error n))
            in
            Printexc.raise_with_backtrace exn bt
        | Portaudio.Unanticipated_host_error ->
            let n, s = Portaudio.get_last_host_error () in
            if n = 0 then
              self#log#important "Unanticipated host error in %s. (ignoring)"
                lbl
            else
              self#log#important
                "Unanticipated host error %d in %s: %s. (ignoring)" n lbl s
  end

let open_device ~mode ~latency ~channels ~buflen device_id =
  let samples_per_second = Lazy.force Frame.audio_rate in
  match device_id with
    | None ->
        Portaudio.open_default_stream ~format:Portaudio.format_float32 0
          channels samples_per_second buflen
    | Some device ->
        let device_info = Portaudio.get_device_info device in
        let inparams, outparams =
          match mode with
            | `Input ->
                let latency =
                  Option.value
                    ~default:device_info.Portaudio.d_default_high_output_latency
                    latency
                in
                ( Some
                    {
                      Portaudio.channels;
                      device;
                      sample_format = Portaudio.format_float32;
                      latency;
                    },
                  None )
            | `Output ->
                let latency =
                  Option.value
                    ~default:device_info.Portaudio.d_default_high_input_latency
                    latency
                in
                ( None,
                  Some
                    {
                      Portaudio.channels;
                      device;
                      sample_format = Portaudio.format_float32;
                      latency;
                    } )
        in
        Portaudio.open_stream inparams outparams (float samples_per_second)
          buflen []

class output ~clock_safe ~start ~on_start ~on_stop ~infallible ~device_id
  ~latency buflen val_source =
  object (self)
    inherit base

    inherit!
      Output.output
        ~infallible ~on_stop ~on_start ~name:"output.portaudio"
          ~output_kind:"output.portaudio" val_source start as super

    method! private set_clock =
      super#set_clock;
      if clock_safe then
        Clock.unify ~pos:self#pos self#clock
          (Clock.create_known (get_clock () :> Source.clock))

    val mutable stream = None
    method! self_sync = (`Dynamic, stream <> None)

    method private open_device =
      self#handle "open_device" (fun () ->
          stream <-
            Some
              (open_device ~mode:`Output ~latency ~channels:self#audio_channels
                 ~buflen device_id));
      self#handle "start_stream" (fun () ->
          Portaudio.start_stream (Option.get stream))

    method private close_device =
      match stream with
        | None -> ()
        | Some s ->
            Portaudio.close_stream s;
            stream <- None

    method start = self#open_device
    method stop = self#close_device

    method! reset =
      self#close_device;
      self#open_device

    method send_frame memo =
      let stream = Option.get stream in
      let buf = AFrame.pcm memo in
      self#handle "write_stream" (fun () ->
          let len = Audio.length buf in
          Portaudio.write_stream stream buf 0 len)
  end

class input ~clock_safe ~start ~on_start ~on_stop ~fallible ~device_id ~latency
  buflen =
  object (self)
    inherit base

    inherit
      Start_stop.active_source
        ~get_clock ~clock_safe ~name:"input.portaudio" ~on_start ~on_stop
          ~fallible ~autostart:start ()

    method private start = self#open_device
    method private stop = self#close_device
    val mutable stream = None
    method self_sync = (`Dynamic, stream <> None)
    method abort_track = ()
    method remaining = -1
    method seek_source = (self :> Source.source)

    method private open_device =
      self#handle "open_device" (fun () ->
          stream <-
            Some
              (open_device ~mode:`Input ~latency ~channels:self#audio_channels
                 ~buflen device_id));
      self#handle "start_stream" (fun () ->
          Portaudio.start_stream (Option.get stream))

    method private close_device =
      Portaudio.close_stream (Option.get stream);
      stream <- None

    method get_frame frame =
      assert (0 = AFrame.position frame);
      let stream = Option.get stream in
      let buf = AFrame.pcm frame in
      self#handle "read_stream" (fun () ->
          Portaudio.read_stream stream buf 0 (Array.length buf.(0)));
      AFrame.add_break frame (AFrame.size ())
  end

let _ =
  let frame_t =
    Lang.frame_t (Lang.univ_t ())
      (Frame.Fields.make ~audio:(Format_type.audio ()) ())
  in
  Lang.add_operator ~base:Modules.output "portaudio"
    (Output.proto
    @ [
        ( "clock_safe",
          Lang.bool_t,
          Some (Lang.bool true),
          Some "Force the use of the dedicated Portaudio clock." );
        ( "buflen",
          Lang.int_t,
          Some (Lang.int 256),
          Some "Length of a buffer in samples." );
        ( "device_id",
          Lang.nullable_t Lang.int_t,
          Some Lang.null,
          Some "Device ID. Uses default device if `null`." );
        ( "latency",
          Lang.nullable_t Lang.float_t,
          Some Lang.null,
          Some "Device latency. Only used when specifying device ID." );
        ("", Lang.source_t frame_t, None, None);
      ])
    ~return_t:frame_t ~category:`Output ~meth:Output.meth
    ~descr:"Output the source's stream to a portaudio output device."
    (fun p ->
      let e f v = f (List.assoc v p) in
      let buflen = e Lang.to_int "buflen" in
      let device_id =
        Lang.to_valued_option Lang.to_int (List.assoc "device_id" p)
      in
      let latency =
        Lang.to_valued_option Lang.to_float (List.assoc "latency" p)
      in
      let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
      let start = Lang.to_bool (List.assoc "start" p) in
      let on_start =
        let f = List.assoc "on_start" p in
        fun () -> ignore (Lang.apply f [])
      in
      let on_stop =
        let f = List.assoc "on_stop" p in
        fun () -> ignore (Lang.apply f [])
      in
      let source = List.assoc "" p in
      let clock_safe = Lang.to_bool (List.assoc "clock_safe" p) in
      (new output
         ~start ~on_start ~on_stop ~infallible ~clock_safe ~device_id ~latency
         buflen source
        :> Output.output))

let _ =
  let return_t =
    Lang.frame_t Lang.unit_t
      (Frame.Fields.make ~audio:(Format_type.audio ()) ())
  in
  Lang.add_operator ~base:Modules.input "portaudio"
    (Start_stop.active_source_proto ~clock_safe:true ~fallible_opt:(`Yep false)
    @ [
        ( "buflen",
          Lang.int_t,
          Some (Lang.int 256),
          Some "Length of a buffer in samples." );
        ( "device_id",
          Lang.nullable_t Lang.int_t,
          Some Lang.null,
          Some "Device ID. Uses default device if `null`." );
        ( "latency",
          Lang.nullable_t Lang.float_t,
          Some Lang.null,
          Some "Device latency. Only used when specifying device ID." );
      ])
    ~return_t ~category:`Input ~meth:(Start_stop.meth ())
    ~descr:"Stream from a portaudio input device."
    (fun p ->
      let e f v = f (List.assoc v p) in
      let buflen = e Lang.to_int "buflen" in
      let device_id =
        Lang.to_valued_option Lang.to_int (List.assoc "device_id" p)
      in
      let latency =
        Lang.to_valued_option Lang.to_float (List.assoc "latency" p)
      in
      let clock_safe = Lang.to_bool (List.assoc "clock_safe" p) in
      let start = Lang.to_bool (List.assoc "start" p) in
      let fallible = Lang.to_bool (List.assoc "fallible" p) in
      let on_start =
        let f = List.assoc "on_start" p in
        fun () -> ignore (Lang.apply f [])
      in
      let on_stop =
        let f = List.assoc "on_stop" p in
        fun () -> ignore (Lang.apply f [])
      in
      new input
        ~clock_safe ~start ~on_start ~on_stop ~fallible ~device_id ~latency
        buflen)
