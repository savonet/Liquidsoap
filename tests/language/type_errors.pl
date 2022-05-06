#!/usr/bin/perl -w

use strict ;

my $liquidsoap = "../../src/liquidsoap";
die unless -f $liquidsoap ;

$liquidsoap = "$liquidsoap --no-stdlib ../../libs/stdlib.liq ../../libs/deprecations.liq -c";

sub section {
  print "\n*** $_[0] ***\n\n" ;
}

sub incorrect {
  my $expr = pop ;
  print "Incorrect expression $expr...\n" ;
  system "$liquidsoap '$expr' >/dev/null 2>&1" ;
  die unless (($?>>8)==1) ;
  print "\n" ;
}

sub correct {
  my $expr = pop ;
  print "Correct expression $expr...\n" ;
  system "$liquidsoap -i '$expr' >/dev/null 2>&1" ;
  die unless (($?>>8)==0) ;
  print "\n";
}

section("LISTS");
incorrect('ignore([4,"x"])');
correct('ignore([input.harbor("foo"), sine()])');
correct('ignore([sine(), input.harbor("foo")])');
correct('ignore([1, ...[2,3,4], ...[5,6], 7])');
correct('let [x,y,...z] = [1,2]');
correct('let [] = [1,2]');
incorrect('let [...z, x, ...t] = [1,2]');

section("BASIC");
incorrect('[1]==["1"]');
incorrect('1==["1"]');
incorrect('1==(1,"1")');
# In some of those examples the type error could be reported for a
# sub-expression since we have location information.
# With the concise error, it's still pretty good currently.
incorrect('(1,1)==(1,"1")');
incorrect('(1,1)==("1",1)');
incorrect('1==request.create("")');
incorrect('fun(x)->x(snd(x))');
incorrect('{a = 5, b = 3} == {a = 6}');

correct('true ? "foo" : "bar"');
incorrect('false ? true : "bar"');

section("SUBTYPING");
incorrect('(1:unit)');
# Next one requires the inference of a subtype (fixed vs. variable arity)
correct('ignore(audio_to_stereo(add([])))');
correct('ignore((blank():source(audio=pcm,video=canvas,midi=none)))');

section("CONSTRAINTS");
incorrect('"bl"+"a"');
incorrect('(fun(a,b)->a+b)==(fun(a,b)->a+b)');
incorrect('fun(x)->x(x)'); # TODO is it an accident that we get same varname
incorrect('def f(x) y=snd(x) y(x) end');

section("LET GENERALIZATION");
correct('def f(x) = y=x ; y end ignore(f(3)+snd(f((1,2))))');
incorrect('def f(x) = y=x ; y end ignore(f(3)+"3")');

section("ARGUMENTS");
# The errors should be about the type of the param, not of the function.
incorrect('1+"1"');
# Also, a special simple error is expected for obvious labelling mistakes.
incorrect('fallback(transitions=[],xxxxxxxxxxx=[])');
incorrect('fallback(transitions=[],transitions=[])');

section("FUNCTIONS");
# Partial application is not supported anymore
incorrect('def f(x,y) = y end ignore(f(2))');
incorrect('fallback(transitions=[fun(~l)->1],[blank()])');
incorrect('fallback(transitions=[fun(~l=1)->1],[blank()])');
incorrect('fallback(transitions=[fun(x,y=blank())->y],[blank()])');
incorrect('fallback(transitions=[fun(x,y)->0],[blank()])');
correct('fallback(transitions=[fun(x,y,a=2)->x],[blank()])');
incorrect('fallback(transitions=[fun(x,y)->y+1],[blank()])');
correct('x=fun(f)->f(3) y=x(fun(f,u="1")->u) ignore(y)');

section("CONTENT KIND");
incorrect('output.file(%vorbis(stereo),"foo",mean(blank()))');
incorrect('output.file(%vorbis(stereo),"foo",video.add_image(blank()))');
incorrect('def f(x) = output.file(%vorbis(stereo),"",x) output.file(%vorbis(mono),"",x) end');
incorrect('add([output.file(%vorbis(stereo),"",blank()),output.file(%vorbis(mono),"",blank())])');
incorrect('add([mean(blank()),audio_to_stereo(add([]))])');

section("PATTERNS");
incorrect("let [x = {foo}, y = (foo), z] = l");
incorrect("let _.{foo=123} = {foo=123}");
incorrect("let v.{foo=123} = {foo=123}");

section("ENCODERS");
correct('%ffmpeg(%video(codec="h264_nvenc"))');
correct('%ffmpeg(%video(codec="h264_nvenc",hwaccel="none"))');
correct('%ffmpeg(%video(codec="h264_nvenc",hwaccel="auto",hwaccel_device="none"))');
correct('%ffmpeg(%video(codec="h264_nvenc",hwaccel_device="foo"))');
correct('%ffmpeg(format="mpegts",
                %audio(
                  codec="aac",
                  channels=2,
                  ar=44100
                ))');
correct('%ffmpeg(format="mpegts",
               %audio(
                 codec="aac",
                 channels=2,
                 ar=44100,
                 b="96k"
               ))');
correct('%ffmpeg(format="mpegts",
               %audio(
                codec="aac",
                channels=2,
                ar=44100,
                b="192k"
              ))');
correct('%ffmpeg(
         format="mpegts",
         %audio(
            codec="aac",
            b="128k",
            channels=2,
            ar=44100
         ),
         %video(
           codec="libx264",
           b="5M"
         )
       )');
correct('%ffmpeg(
        format="mp4",
        movflags="+dash+skip_sidx+skip_trailer+frag_custom",
        frag_duration=10,
        %audio(
          codec="aac",
          b="128k",
          channels=2,
          ar=44100),
        %video(
          codec="libx264",
          b="5M"
        )
      )');
correct('%ffmpeg(
         format="mpegts",
         %audio.raw(
            codec="aac",
            b="128k",
            channels=2,
            ar=44100
         ),
         %video.raw(
           codec="libx264",
           b="5M"
         )
       )');
correct('%ffmpeg(
        format="mp4",
        movflags="+dash+skip_sidx+skip_trailer+frag_custom",
        frag_duration=10,
        %audio.raw(
          codec="aac",
          b="128k",
          channels=2,
          ar=44100),
        %video.raw(
          codec="libx264",
          b="5M"
        )
      )');
correct('%ffmpeg(
         format="mpegts",
         %audio.copy,
         %video.copy)');
correct('%ffmpeg(
        format="mp4",
        movflags="+dash+skip_sidx+skip_trailer+frag_custom",
        frag_duration=10,
        %audio.copy,
        %video.copy)');
correct('%ffmpeg(%audio.copy(ignore_keyframe), %video.copy(ignore_keyframe))');
correct('%ffmpeg(%audio.copy(wait_for_keyframe), %video.copy(wait_for_keyframe))');

# The following is not technically checking on type errors but runtime invalid values.
section("INVALID VALUES");
incorrect('crossfade(input.http(self_sync=true,"http://foo.bar"))');
incorrect('crossfade(fallback([input.http("http://foo.bar"), input.http(self_sync=true,"http://foo.bar")]))');
incorrect('crossfade(sequence([input.http("http://foo.bar"), input.http(self_sync=true,"http://foo.bar")]))');
incorrect('crossfade(add([input.http("http://foo.bar"), input.http(self_sync=true,"http://foo.bar")]))');

print "Everything's good!\n" ;
