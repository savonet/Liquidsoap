let build_config () =
  let path_mode =
    match Liquidsoap_paths.mode with
      | `Default -> "default"
      | `Standalone -> "standalone"
      | `Posix -> "posix"
  in
  [%string
    {|
 * Liquidsoap version  : %{Configure.version ()}

 * Configured paths  
   - mode              : %{path_mode}
   - standard library  : %{Liquidsoap_paths.liq_libs_dir_descr}
   - scripted binaries : %{Liquidsoap_paths.bin_dir_descr}
   - camomile          : %{Liquidsoap_paths.camomile_dir_descr}
   - rundir            : %{Liquidsoap_paths.rundir_descr}
   - logdir            : %{Liquidsoap_paths.logdir_descr}

 * Supported input formats
   - MP3               : %{Mad_option.detected}
   - AAC               : %{Faad_option.detected}
   - Ffmpeg            : %{Ffmpeg_option.detected}
   - Flac (native)     : %{Flac_option.detected}
   - Flac (ogg)        : %{Ogg_flac_option.detected}
   - Opus              : %{Opus_option.detected}
   - Speex             : %{Speex_option.detected}
   - Theora            : %{Theora_option.detected}
   - Vorbis            : %{Vorbis_option.detected}

 * Supported output formats
   - FDK-AAC           : %{Fdkaac_option.detected}
   - Ffmpeg            : %{Ffmpeg_option.detected}
   - MP3               : %{Lame_option.detected}
   - MP3 (fixed-point) : %{Shine_option.detected}
   - Opus              : %{Opus_option.detected}
   - Speex             : %{Speex_option.detected}
   - Theora            : %{Theora_option.detected}
   - Vorbis            : %{Vorbis_option.detected}

 * Tags
   - Taglib (ID3 tags) : %{Taglib_option.detected}
   - Vorbis            : %{Vorbis_option.detected}

 * Input / output
   - ALSA              : %{Alsa_option.detected}
   - AO                : %{Ao_option.detected}
   - FFmpeg            : %{Ffmpeg_option.detected}
   - Icecast/Shoutcast : %{Cry_option.detected}
   - GStreamer         : %{Gstreamer_option.detected}
   - JACK              : %{Bjack_option.detected}
   - OSS               : %{Oss_option.detected}
   - Portaudio         : %{Portaudio_option.detected}
   - Pulseaudio        : %{Pulseaudio_option.detected}
   - SRT               : %{Srt_option.detected}

 * Audio manipulation
   - FFmpeg            : %{Ffmpeg_option.detected}
   - LADSPA            : %{Ladspa_option.detected}
   - Lilv              : %{Lilv_option.detected}
   - Samplerate        : %{Samplerate_option.detected}
   - SoundTouch        : %{Soundtouch_option.detected}

 * Video manipulation
   - camlimages        : %{Camlimages_option.detected}
   - FFmpeg            : %{Ffmpeg_option.detected}
   - frei0r            : %{Frei0r_option.detected}
   - SDL               : %{Sdl_option.detected}

 * MIDI manipulation
   - DSSI              : %{Dssi_option.detected}

 * Visualization
   - GD                : %{Gd_option.detected}
   - Graphics          : %{Graphics_option.detected}
   - SDL               : %{Sdl_option.detected}

 * Additional libraries
   - curl (http)       : %{Ocurl_option.detected}
   - FFmpeg filters:   : %{Ffmpeg_option.detected}
   - FFmpeg devices    : %{Ffmpeg_option.detected}
   - inotify           : %{Inotify_option.detected}
   - irc               : %{Irc_option.detected}
   - lastfm            : %{Lastfm_option.detected}
   - lo                : %{Lo_option.detected}
   - magic             : %{Magic_option.detected}
   - memtrace          : %{Memtrace_option.detected}
   - mem_usage         : %{Mem_usage_option.detected}
   - SecureTransport   : %{Osx_secure_transport_option.detected}
   - ssl               : %{Ssl_option.detected}
   - posix-time2       : %{Posix_time_option.detected}
   - windows service   : %{Winsvc_option.detected}
   - XML playlists     : %{Xmlplaylist_option.detected}

 * Monitoring
   - Prometheus        : %{Prometheus_option.detected}
|}]

let opam_config =
  [%string
    {|
opam-version: "2.0"
variables {
  cry-enabled: %{Cry_option.enabled}
  ffmpeg-enabled: %{Ffmpeg_option.enabled}
  lame-enabled: %{Lame_option.enabled}
  mad-enabled: %{Mad_option.enabled}
  ocurl-enabled: %{Ocurl_option.enabled}
  samperate-enabled: %{Samplerate_option.enabled}
  secure-transport-enabled: %{Osx_secure_transport_option.enabled}
  shine-enabled: %{Shine_option.enabled}
  ssl-enabled: %{Ssl_option.enabled}
  taglib-enabled: %{Taglib_option.enabled}
}
|}]
