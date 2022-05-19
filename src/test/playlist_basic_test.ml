let () =
  assert (
    Playlist_basic.parse_extinf "#EXTINF:,- songname" = [("song", "songname")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:,-songname" = [("song", "songname")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:,artist - title"
    = [("artist", "artist"); ("title", "title")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:,artist-title"
    = [("artist", "artist"); ("title", "title")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:123,- songname"
    = [("extinf_duration", "123"); ("song", "songname")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:123,-songname"
    = [("extinf_duration", "123"); ("song", "songname")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:123 ,artist - title"
    = [("extinf_duration", "123"); ("artist", "artist"); ("title", "title")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:123,artist-title"
    = [("extinf_duration", "123"); ("artist", "artist"); ("title", "title")]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:123 foo=\"bla\",gni=\"gnu\",- songname"
    = [
        ("extinf_duration", "123");
        ("foo", "bla");
        ("gni", "gnu");
        ("song", "songname");
      ]);
  assert (
    Playlist_basic.parse_extinf "#EXTINF:123 foo=\"bla,-songname"
    = [("extinf_duration", "123"); ("song", "songname")]);
  assert (
    Playlist_basic.parse_extinf
      "#EXTINF:123 foo=\"bla\",gni=\"gnu\",artist - title"
    = [
        ("extinf_duration", "123");
        ("foo", "bla");
        ("gni", "gnu");
        ("artist", "artist");
        ("title", "title");
      ]);
  assert (
    Playlist_basic.parse_extinf
      "#EXTINF:123 foo=\"bla\",gni=\"gnu\",artist-title"
    = [
        ("extinf_duration", "123");
        ("foo", "bla");
        ("gni", "gnu");
        ("artist", "artist");
        ("title", "title");
      ])
