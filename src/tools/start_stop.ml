(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

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

(* [`Start] and [`Stop] are explicit states resulting of a
   user command. [`Idle] is a default state at init or after a source
   failure. [`Idle] is used to captures situations where the output is
   stopped by can be restarted immediately when its underlying source
   becomes available again. In contrast, [`Stopped] indicates an
   explicit user-requested stop and the output will not automatically
   restart. *)
type state = [ `Started | `Stopped | `Idle ]

(** Base class for sources with start/stop methods. Class ineheriting it should
    declare their own [start]/[stop] method and users should call [#set_start]  *)
class virtual base ~(on_start : unit -> unit) ~(on_stop : unit -> unit) =
  object (self)
    val mutable state : state = `Idle
    method state = state
    method virtual private start : unit
    method virtual private stop : unit
    method virtual stype : Source.source_t

    (* Default [reset] method. Can be overriden if necessary. *)
    method reset =
      self#stop;
      self#start

    method transition_to (s : state) =
      match (s, state) with
        | `Started, `Stopped | `Started, `Idle ->
            self#start;
            on_start ();
            state <- `Started
        | `Started, `Started -> ()
        | `Stopped, `Started ->
            self#stop;
            on_stop ();
            state <- `Stopped
        | `Stopped, `Idle -> state <- `Stopped
        | `Stopped, `Stopped -> ()
        | `Idle, `Started ->
            self#stop;
            on_stop ();
            state <- `Idle
        | `Idle, `Stopped | `Idle, `Idle -> ()
  end

class virtual active_source ?get_clock ~name ~content_kind ~clock_safe
  ~(on_start : unit -> unit) ~(on_stop : unit -> unit) ~fallible ~autostart () =
  let get_clock =
    Option.value ~default:(fun () -> new Clock.clock name) get_clock
  in
  object (self)
    inherit Source.active_source ~name content_kind as super
    inherit base ~on_start ~on_stop as base
    method stype = if fallible then Source.Fallible else Source.Infallible
    method private wake_up _ = if autostart then base#transition_to `Started
    method private sleep = base#transition_to `Stopped
    method is_ready = state = `Started
    val mutable clock = None

    method private get_clock =
      match clock with
        | Some c -> c
        | None ->
            let c = get_clock () in
            clock <- Some c;
            c

    method private set_clock =
      super#set_clock;
      if clock_safe then
        Clock.unify self#clock
          (Clock.create_known (self#get_clock :> Clock.clock))

    method virtual private get_frame : Frame.t -> unit
    method virtual private memo : Frame.t

    method private output =
      if self#is_ready && AFrame.is_partial self#memo then
        self#get_frame self#memo
  end

let output_proto =
  [
    ( "on_start",
      Lang.fun_t [] Lang.unit_t,
      Some (Lang.val_cst_fun [] Lang.unit),
      Some "Callback executed when input starts." );
    ( "on_stop",
      Lang.fun_t [] Lang.unit_t,
      Some (Lang.val_cst_fun [] Lang.unit),
      Some "Callback executed when input stops." );
    ( "start",
      Lang.bool_t,
      Some (Lang.bool true),
      Some "Start input as soon as it is available." );
  ]

let active_source_proto ~fallible_opt ~clock_safe =
  output_proto
  @ [
      ( "clock_safe",
        Lang.bool_t,
        Some (Lang.bool clock_safe),
        Some "Force the use of a dedicated clock" );
    ]
  @
  match fallible_opt with
    | `Nope -> []
    | `Yep v ->
        [
          ( "fallible",
            Lang.bool_t,
            Some (Lang.bool v),
            Some
              "Allow the source to fail. If set to `false`, `start` must be \
               `true` and `stop` method raises an error." );
        ]

type 'a meth = string * Lang.scheme * string * ('a -> Lang.value)

let meth :
    unit -> < state : state ; transition_to : state -> unit ; .. > meth list =
 fun () ->
  Lang.
    [
      ( "is_started",
        ([], fun_t [] bool_t),
        "`true` if the output or source is started.",
        fun s -> val_fun [] (fun _ -> bool (s#state = `Started)) );
      ( "start",
        ([], fun_t [] unit_t),
        "Ask the source or output to start.",
        fun s ->
          val_fun [] (fun _ ->
              s#transition_to `Started;
              unit) );
      ( "stop",
        ([], fun_t [] unit_t),
        "Ask the source or output to stop.",
        fun s ->
          val_fun [] (fun _ ->
              if s#stype = Source.Infallible then
                raise
                  Term.(
                    Runtime_error
                      {
                        kind = "input";
                        msg = Some "Source is infallible and cannot be stopped";
                        pos = [];
                      });
              s#transition_to `Stopped;
              unit) );
    ]
