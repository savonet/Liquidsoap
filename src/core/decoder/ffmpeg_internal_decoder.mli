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

val mk_audio_decoder :
  channels:int ->
  stream:(Avutil.input, Avutil.audio, [ `Frame ]) Av.stream ->
  field:Frame.field ->
  pcm_kind:Content.kind ->
  Avutil.audio Avcodec.params ->
  buffer:Decoder.buffer ->
  Avutil.audio Avutil.Frame.t ->
  unit

val mk_video_decoder :
  width:int ->
  height:int ->
  stream:(Avutil.input, Avutil.video, [ `Frame ]) Av.stream ->
  field:Frame.field ->
  Avutil.video Avcodec.params ->
  buffer:Decoder.buffer ->
  [ `Video ] Avutil.Frame.t ->
  unit
