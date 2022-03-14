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

open Source

class biquad ~kind (source : source) filter_type freq q gain =
  let samplerate = float (Frame.audio_of_seconds 1.) in
  object (self)
    inherit operator ~name:"biquad_filter" kind [source] as super
    val mutable p0 = 0.
    val mutable p1 = 0.
    val mutable p2 = 0.
    val mutable q1 = 0.
    val mutable q2 = 0.
    val mutable x1 = [||]
    val mutable x2 = [||]
    val mutable y0 = [||]
    val mutable y1 = [||]
    val mutable y2 = [||]

    (* Last frequency used to initialize parameters. Used to detect when we
       should re-compute coefficients. *)
    val mutable last_freq = 0.
    val mutable last_q = 0.
    val mutable last_gain = 0.

    (* Digital filter based on "Cookbook formulae for audio EQ biquad filter
       coefficients" by Robert Bristow-Johnson <rbj@audioimagination.com>.  URL:
       http://www.musicdsp.org/files/Audio-EQ-Cookbook.txt *)
    method private init =
      let chans = self#audio_channels in
      if Array.length x1 <> chans then (
        x1 <- Array.make chans 0.;
        x2 <- Array.make chans 0.;
        y0 <- Array.make chans 0.;
        y1 <- Array.make chans 0.;
        y2 <- Array.make chans 0.);
      let freq = freq () in
      let q = q () in
      let gain = gain () in
      if last_freq <> freq || last_q <> q || last_gain <> gain then (
        last_freq <- freq;
        last_q <- q;
        last_gain <- gain;
        let w0 = 2. *. Float.pi *. freq /. samplerate in
        let sin_w0 = sin w0 in
        let cos_w0 = cos w0 in
        let alpha = sin_w0 /. (2. *. q) in
        let b0, b1, b2, a0, a1, a2 =
          match filter_type with
            | `Low_pass ->
                let b1 = 1. -. cos w0 in
                let b0 = b1 /. 2. in
                (b0, b1, b0, 1. +. alpha, -2. *. cos_w0, 1. -. alpha)
            | `High_pass ->
                let b1 = 1. +. cos_w0 in
                let b0 = b1 /. 2. in
                let b1 = -.b1 in
                (b0, b1, b0, 1. +. alpha, -2. *. cos_w0, 1. -. alpha)
            | `Band_pass ->
                let b0 = sin_w0 /. 2. in
                (b0, 0., -.b0, 1. +. alpha, -2. *. cos_w0, 1. -. alpha)
            | `Notch ->
                let b1 = -2. *. cos_w0 in
                (1., b1, 1., 1. +. alpha, b1, 1. -. alpha)
            | `All_pass ->
                let b0 = 1. -. alpha in
                let b1 = -2. *. cos_w0 in
                let b2 = 1. +. alpha in
                (b0, b1, b2, b2, b1, b0)
            | `Peaking ->
                let a = if gain = 0. then 1. else 10. ** (gain /. 40.) in
                let ama = alpha *. a in
                let ada = alpha /. a in
                let b1 = -2. *. cos_w0 in
                (1. +. ama, b1, 1. -. ama, 1. +. ada, b1, 1. -. ada)
            | `Low_shelf ->
                let a = if gain = 0. then 1. else 10. ** (gain /. 40.) in
                let s = 2. *. sqrt a *. alpha in
                ( a *. (a +. 1. -. ((a -. 1.) *. cos_w0) +. s),
                  2. *. a *. (a -. 1. -. ((a +. 1.) *. cos_w0)),
                  a *. (a +. 1. -. ((a -. 1.) *. cos_w0) -. s),
                  a +. 1. +. ((a -. 1.) *. cos_w0) +. s,
                  (-2. *. (a -. 1.)) +. ((a +. 1.) *. cos_w0),
                  a +. 1. +. ((a -. 1.) *. cos_w0) -. s )
            | `High_shelf ->
                let a = if gain = 0. then 1. else 10. ** (gain /. 40.) in
                let s = 2. *. sqrt a *. alpha in
                ( a *. (a +. 1. +. ((a -. 1.) *. cos_w0) +. s),
                  -2. *. a *. (a -. 1. +. ((a +. 1.) *. cos_w0)),
                  a *. (a +. 1. +. ((a -. 1.) *. cos_w0) -. s),
                  a +. 1. -. ((a -. 1.) *. cos_w0) +. s,
                  (2. *. (a -. 1.)) -. ((a +. 1.) *. cos_w0),
                  a +. 1. -. ((a -. 1.) *. cos_w0) -. s )
        in
        p0 <- b0 /. a0;
        p1 <- b1 /. a0;
        p2 <- b2 /. a0;
        q1 <- a1 /. a0;
        q2 <- a2 /. a0)

    method stype = source#stype
    method remaining = source#remaining
    method seek = source#seek
    method self_sync = source#self_sync
    method is_ready = source#is_ready
    method abort_track = source#abort_track

    method wake_up a =
      super#wake_up a;
      self#init

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let position = AFrame.position buf in
      let buf = AFrame.pcm buf in
      self#init;
      for c = 0 to self#audio_channels - 1 do
        let buf = buf.(c) in
        for i = offset to position - 1 do
          let x0 = buf.(i) in
          let y0 =
            (p0 *. x0)
            +. (p1 *. x1.(c))
            +. (p2 *. x2.(c))
            -. (q1 *. y1.(c))
            -. (q2 *. y2.(c))
          in
          buf.(i) <- y0;
          x2.(c) <- x1.(c);
          x1.(c) <- x0;
          y2.(c) <- y1.(c);
          y1.(c) <- y0
        done
      done
  end

let () =
  Lang.add_module "filter.iir.eq";
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.lowshelf"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Corner frequency");
      ( "slope",
        Lang.getter_t Lang.float_t,
        Some (Lang.float 1.),
        Some "Shelf slope (dB/octave)" );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"Low shelf biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "slope"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `Low_shelf freq param (fun () -> 0.)
        :> Source.source))

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.highshelf"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Center frequency");
      ( "slope",
        Lang.getter_t Lang.float_t,
        Some (Lang.float 1.),
        Some "Shelf slope (in dB/octave)" );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"High shelf biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "slope"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `High_shelf freq param (fun () -> 0.)
        :> Source.source))

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.low"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Corner frequency");
      ("q", Lang.getter_t Lang.float_t, Some (Lang.float 1.), Some "Q");
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"Low-pass biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "q"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `Low_pass freq param (fun () -> 0.)
        :> Source.source))

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.high"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Corner frequency");
      ("q", Lang.getter_t Lang.float_t, Some (Lang.float 1.), Some "Q");
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"High-pass biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "q"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `High_pass freq param (fun () -> 0.)
        :> Source.source))

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.bandpass"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Center frequency");
      ("q", Lang.getter_t Lang.float_t, Some (Lang.float 1.), Some "Q");
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"Band-pass biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "q"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `Band_pass freq param (fun () -> 0.)
        :> Source.source))

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.allpass"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Center frequency");
      ( "bandwidth",
        Lang.getter_t Lang.float_t,
        Some (Lang.float (1. /. 3.)),
        Some "Bandwidth (in octaves)" );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"All-pass biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "bandwidth"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `All_pass freq param (fun () -> 0.)
        :> Source.source))

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.notch"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Center frequency");
      ("q", Lang.getter_t Lang.float_t, Some (Lang.float 1.), Some "Q");
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"Band-pass biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "q"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `Notch freq param (fun () -> 0.) :> Source.source))

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter.iir.eq.peak"
    [
      ("frequency", Lang.getter_t Lang.float_t, None, Some "Center frequency");
      ("q", Lang.getter_t Lang.float_t, Some (Lang.float 1.), Some "Q");
      ( "gain",
        Lang.getter_t Lang.float_t,
        Some (Lang.float 1.),
        Some "Gain (in dB)" );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:`Audio ~descr:"Peak EQ biquad filter."
    (fun p ->
      let f v = List.assoc v p in
      let freq, param, gain, src =
        ( Lang.to_float_getter (f "frequency"),
          Lang.to_float_getter (f "q"),
          Lang.to_float_getter (f "gain"),
          Lang.to_source (f "") )
      in
      let kind = Source.Kind.of_kind kind in
      (new biquad ~kind src `Peaking freq param gain :> Source.source))
