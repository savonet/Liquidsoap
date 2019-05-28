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

open Source

module Generator = Generator.From_audio_video_plus
module Generated = Generated.From_audio_video_plus

type next_stop = [
  | `Metadata of Frame.metadata
  | `Break_and_metadata of Frame.metadata
  | `Break
  | `Sleep
  | `Nothing
]

type chunk = {
  sbuf: Bytes.t;
  next: next_stop;
  mutable ofs: int;
  mutable len: int
}

exception Not_enough_data

let read_header =
  let really_input buf s ofs len =
    if Buffer.length buf < len then
      raise Not_enough_data;
    Buffer.blit buf 0 s ofs len;
    Utils.buffer_drop buf len
  in
  let b = Bytes.create 1 in
  let input_byte buf =
    if Buffer.length buf < 1 then
      raise Not_enough_data;
    Buffer.blit buf 0 b 0 1;
    Utils.buffer_drop buf 1;
    Char.code (Bytes.get b 0)
  in
  let input buf s ofs len =
    let len =
      max (Buffer.length buf) len
    in
    Buffer.blit buf 0 s ofs len;
    Utils.buffer_drop buf len;
    len
  in
  let seek _ _ = assert false in
  let close _ = () in
  Wav_aiff.read_header {Wav_aiff.
    really_input;input_byte;input;seek;close
  }
    
class pipe ~kind ~process ~bufferize ~max ~restart ~restart_on_error (source:source) =
  (* We need a temporary log until the source has an id *)
  let log_ref = ref (fun _ -> ()) in
  let log = (fun x -> !log_ref x) in
  let log_error = ref (fun _ -> ()) in
  let sample_rate = Frame.audio_of_seconds 1. in
  let audio_src_rate = float sample_rate in
  let channels = (Frame.type_of_kind kind).Frame.audio in
  let abg_max_len = Frame.audio_of_seconds max in
  let samplesize = ref 16 in
  let converter = ref
    (Rutils.create_from_iff ~format:`Wav ~channels ~samplesize:!samplesize
                            ~audio_src_rate)
  in
  let header = 
    Bytes.unsafe_of_string
      (Wav_aiff.wav_header ~channels ~sample_rate
                           ~sample_size:16 ())
  in
  let on_start push =
    Process_handler.write header push;
    `Continue
  in
  let abg = Generator.create ~log ~kind `Audio in
  let buf = Buffer.create 1024 in
  let mutex = Mutex.create () in
  let next_stop = ref `Nothing in
  let is_first = ref true in
  let process_data () =
    (* Round to a multiple of sample_size * channels *)
    let len =
      let ratio =
        !samplesize * channels
      in
      (Buffer.length buf / ratio) * ratio
    in
    let data =
      Buffer.sub buf 0 len
    in
    Utils.buffer_drop buf len;
    let data = !converter data in
    let len = Array.length data.(0) in
    let buffered = Generator.length abg in
    Generator.put_audio abg data 0 (Array.length data.(0));
    if abg_max_len < buffered+len then
      `Delay (Frame.seconds_of_audio (buffered+len-abg_max_len))
    else
      `Continue
  in
  let on_stdout pull =
    Buffer.add_bytes buf
      (Process_handler.read 1024 pull);
    let done_with_header =
      Tutils.mutexify mutex (fun () ->
        if !is_first then
          let contents = Buffer.contents buf in
          try
            let wav = read_header buf in
            if Wav_aiff.channels wav <> channels then
              failwith "Invalid channels from pipe process!";
            samplesize := Wav_aiff.sample_size wav;
            converter :=
              Rutils.create_from_iff ~format:`Wav ~channels
                ~samplesize:!samplesize
                ~audio_src_rate:(float (Wav_aiff.sample_rate wav));
            is_first := false;
            true
           with Not_enough_data ->
             Buffer.reset buf;
             Buffer.add_string buf contents;
             false
        else true) ()
    in
    if done_with_header then process_data () else `Continue
  in
  let on_stderr stderr =
    (!log_error) (Bytes.unsafe_to_string (Process_handler.read 1024 stderr));
    `Continue
  in
  let on_stop = Tutils.mutexify mutex (fun e ->
    let ret = !next_stop in
    next_stop := `Nothing;
    is_first := true;
    ignore(process_data ());
    Buffer.reset buf;
    let should_restart =
      match e with
        | `Status s when s <> (Unix.WEXITED 0) ->
             restart_on_error
        | `Exception _ ->
             restart_on_error
        | _ ->
            true
    in
    match should_restart, ret with
      | false, _ -> false
      | _, `Sleep -> false
      | _, `Break_and_metadata m ->
          Generator.add_metadata abg m;
          Generator.add_break abg;
          true
      | _, `Metadata m ->
          Generator.add_metadata abg m;
          true
      | _, `Break ->
          Generator.add_break abg;
          true
      | _, `Nothing -> restart)
  in
object(self)
  inherit source ~name:"pipe" kind
  inherit Generated.source abg ~empty_on_abort:false ~bufferize

  val mutable handler = None
  val to_write = Queue.create ()

  method stype = Source.Fallible

  method private get_handler =
    match handler with
      | Some h -> h
      | None -> raise Process_handler.Finished

  method private get_to_write =
    if source#is_ready then begin
      let tmp = Frame.create kind in
      source#get tmp;
      self#slave_tick;
      let buf = AFrame.content_of_type ~channels tmp 0 in
      let blen = Array.length buf.(0) in
      let slen_of_len len = 2 * len * Array.length buf in
      let slen = slen_of_len blen in
      let sbuf = Bytes.create slen in
      Audio.S16LE.of_audio buf 0 sbuf 0 blen;
      let metadata =
        List.sort (fun (pos,_) (pos',_) -> compare pos pos')
                  (Frame.get_all_metadata tmp)
      in
      let ofs = List.fold_left (fun ofs (pos, m) ->
        let pos = slen_of_len pos in
        let len = pos-ofs in
        let next =
          if pos = slen && (Frame.is_partial tmp) then
            `Break_and_metadata m
          else
            `Metadata m
        in
        Queue.push {sbuf;next;ofs;len} to_write;
        pos) 0 metadata
      in
      if ofs < slen then
        let len = slen-ofs in
        let next =
          if Frame.is_partial tmp then
            `Break
          else
            `Nothing
        in
        Queue.push {sbuf;next;ofs;len} to_write
    end

  method private on_stdin pusher =
    if Queue.is_empty to_write then self#get_to_write;
    try
      let ({sbuf;next;ofs;len} as chunk) = Queue.peek to_write in
      (* Select documentation: large write may still block.. *)
      let wlen = min 1024 len in
      let ret = pusher sbuf ofs wlen in
      if ret = len then begin
        Tutils.mutexify mutex (fun () -> next_stop := next) ();
        ignore(Queue.take to_write); 
        if next <> `Nothing then `Stop else `Continue
      end else begin
        chunk.ofs <- ofs+ret;
        chunk.len <- len-ret;
        `Continue
      end
    with Queue.Empty -> `Continue

  method private slave_tick =
    (Clock.get source#clock)#end_tick;
    source#after_output

  (* See smactross.ml for details. *)
  method private set_clock =
    let slave_clock = Clock.create_known (new Clock.clock self#id) in
    Clock.unify
      self#clock
      (Clock.create_unknown ~sources:[] ~sub_clocks:[slave_clock]) ;
    Clock.unify slave_clock source#clock ;
    Gc.finalise (fun self -> Clock.forget self#clock slave_clock) self

  method wake_up _ =
    source#get_ready [(self:>source)];
    (* Now we can create the log function *)
    log_ref := self#log#info "%s";
    log_error := self#log#warning "%s";
    handler <- Some (Process_handler.run ~on_stop ~on_start ~on_stdout 
                                         ~on_stdin:self#on_stdin
                                         ~on_stderr ~log process)

  method abort_track = source#abort_track

  method sleep =
    Tutils.mutexify mutex (fun () ->
      try
        next_stop := `Sleep;
        Process_handler.stop self#get_handler;
        handler <- None
      with Process_handler.Finished -> ()) ()
end

let k = Lang.audio_any

let proto =
  [
    "process", Lang.string_t, None,
    Some "Process used to pipe data to.";

    "buffer", Lang.float_t, Some (Lang.float 1.),
    Some "Duration of the pre-buffered data." ;

    "max", Lang.float_t, Some (Lang.float 10.),
    Some "Maximum duration of the buffered data.";

    "restart", Lang.bool_t, Some (Lang.bool true),
    Some "Restart process when exited.";

    "restart_on_error", Lang.bool_t, Some (Lang.bool true),
    Some "Restart process when exited with error.";

    "", Lang.source_t (Lang.kind_type_of_kind_format ~fresh:2 k), None, None
    ]

let pipe p kind =
  let f v = List.assoc v p in
  let process, bufferize, max, restart, restart_on_error, src =
    Lang.to_string (f "process"),
    Lang.to_float (f "buffer"),
    Lang.to_float (f "max"),
    Lang.to_bool (f "restart"),
    Lang.to_bool (f "restart_on_error"),
    Lang.to_source (f "")
  in
  ((new pipe ~kind ~bufferize ~max ~restart ~restart_on_error ~process src):>source)

let () =
  Lang.add_operator "pipe" proto
    ~kind:k
    ~category:Lang.SoundProcessing
    ~descr:"Process audio signal through a given process stdin/stdout."
    pipe
