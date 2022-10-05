let audio_decoding_tests =
  [
    ("Mono decoding", "test_mono.liq");
    ("Stereo decoding", "test_stereo.liq");
    ("FFmpeg audio decoder", "test_ffmpeg_audio_decoder.liq");
  ]

let video_decoding_tests =
  [
    ("FFmpeg video decoder", "test_ffmpeg_video_decoder.liq");
    ("FFmpeg video size", "test_video_size.liq");
  ]

let audio_video_decoding_tests =
  [
    ("FFmpeg add text filter", "test_ffmpeg_add_text.liq");
    ("FFmpeg copy decoder", "test_ffmpeg_copy_decoder.liq");
    ("FFmpeg copy+encode decode", "test_ffmpeg_copy_and_encode_decoder.liq");
    ("FFmpeg filter", "test_ffmpeg_filter.liq");
    ("FFmpeg raw decoder test", "test_ffmpeg_raw_decoder.liq");
    ("FFmpeg raw+encode decoder", "test_ffmpeg_raw_and_encode_decoder.liq");
    ("FFmpeg raw+copy decoder", "test_ffmpeg_raw_and_copy_decoder.liq");
  ]

let standalone_tests =
  [
    "test_ffmpeg_inline_encode_decode.liq";
    "test_ffmpeg_inline_encode_decode_audio.liq";
    "test_ffmpeg_inline_encode_decode_video.liq";
    "test_ffmpeg_distributed_hls.liq";
    "test_ffmpeg_raw_hls.liq";
    "test_taglib.liq";
  ]

let audio_formats =
  [
    "%flac(stereo).flac";
    "%flac(mono).flac";
    "%wav(stereo).wav";
    "%wav(mono).wav";
    "%mp3(mono).mp3";
    "%mp3(stereo).mp3";
    "%ogg(%vorbis(mono)).ogg";
    "%ogg(%vorbis(stereo)).ogg";
    "%ogg(%flac(mono)).ogg";
    "%ogg(%flac(stereo)).ogg";
    "%ogg(%opus(mono)).ogg";
    "%ogg(%opus(stereo)).ogg";
    {|%ffmpeg(format="mp4",%audio(codec="aac"),%video.none).mp4|};
  ]

let video_formats =
  [{|%ffmpeg(format="mp4",%audio.none,%video(codec="libx264")).mp4|}]

let audio_video_formats =
  [
    {|%ffmpeg(format="mp4",%audio(codec="aac",channels=1),%video(codec="libx264")).mp4|};
    {|%ffmpeg(format="mp4",%audio(codec="aac",channels=2),%video(codec="libx264")).mp4|};
  ]

let formats = audio_formats @ audio_video_formats @ video_formats

let encoder_format format =
  match List.rev (String.split_on_char '.' format) with
    | _ :: l -> String.concat "." (List.rev l)
    | _ -> assert false

let escaped_format =
  String.map (function
    | '%' -> '@'
    | '"' -> '\''
    | '(' -> '['
    | ')' -> ']'
    | c -> c)

let encoder_script format =
  Printf.sprintf "%s_encoder.liq" (escaped_format (encoder_format format))

let mk_encoder source pos format =
  Printf.printf
    {|
(rule
  (alias runtest_%d)
  (package liquidsoap)
  (target %s)
  (deps
    (:mk_encoder_test ./mk_encoder_test.sh)
    (:test_encoder_in ./test_encoder.liq.in))
  (action
    (with-stdout-to %%{target}
      (run %%{mk_encoder_test} %S %s %S))))|}
    (pos mod 4) (encoder_script format) (encoder_format format) source
    (escaped_format format)

let mk_encoded_file pos format =
  Printf.printf
    {|
(rule
 (alias runtest_%d)
 (package liquidsoap)
 (target %s)
 (deps
  (:encoder %s)
  (source_tree ../../src/libs)
  ../../src/bin/liquidsoap.exe
  (:stdlib ../../src/libs/stdlib.liq)
  (:test_liq ../test.liq)
  (:run_test ../run_test.exe))
 (action
   (run %%{run_test} %%{encoder} liquidsoap %%{test_liq} %%{encoder} -- %S)))|}
    (pos mod 4) (escaped_format format) (encoder_script format)
    (encoder_format format)

let () =
  List.iteri (mk_encoder "sine") audio_formats;
  List.iteri (mk_encoder "noise") (audio_video_formats @ video_formats);
  List.iteri mk_encoded_file formats;
  Printf.printf
    {|
(rule
  (alias runtest)
  (package liquidsoap)
  (target all_media_files)
  (deps
    %s)
  (action (run touch %%{target})))|}
    (String.concat "\n" (List.map escaped_format formats))

let file_test ~pos ~label ~test fname =
  Printf.printf
    {|
(rule
 (alias runtest_%d)
 (package liquidsoap)
 (deps
  all_media_files
  %s
  ../../src/bin/liquidsoap.exe
  (source_tree ../../src/libs)
  (:stdlib ../../src/libs/stdlib.liq)
  (:test_liq ../test.liq)
  (:run_test ../run_test.exe))
 (action
  (run %%{run_test} %S liquidsoap %%{test_liq} %s -- %S)))|}
    (pos mod 4) test label test fname

let () =
  List.iter
    (fun format ->
      let fname = escaped_format format in
      List.iteri
        (fun pos (name, test) ->
          file_test ~pos ~label:(name ^ " test for " ^ fname) ~test fname)
        audio_decoding_tests)
    audio_formats

let () =
  List.iter
    (fun format ->
      let fname = escaped_format format in
      List.iteri
        (fun pos (name, test) ->
          file_test ~pos ~label:(name ^ " test for " ^ fname) ~test fname)
        video_decoding_tests)
    (video_formats @ audio_video_formats)

let () =
  List.iter
    (fun format ->
      let fname = escaped_format format in
      List.iteri
        (fun pos (name, test) ->
          file_test ~pos ~label:(name ^ " test for " ^ fname) ~test fname)
        audio_video_decoding_tests)
    audio_video_formats

let () =
  List.iteri
    (fun pos test -> file_test ~pos ~label:test ~test "")
    standalone_tests
