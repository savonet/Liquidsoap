/*****************************************************************************

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

 *****************************************************************************/

%{

  open Lang_values
  open Lang_values.Ground

  (** Create a new value with an unknown type. *)
  let mk ~pos e =
    let kind =
      T.fresh_evar ~level:(-1) ~pos:(Some pos)
    in
      if Lazy.force Lang_values.debug then
        Printf.eprintf "%s (%s): assigned type var %s\n"
          (T.print_pos (Utils.get_some kind.T.pos))
          (try Lang_values.print_term {t=kind;term=e} with _ -> "<?>")
          (T.print kind) ;
      { t = kind ; term = e }

  let mk_fun ~pos args body =
    let bound = List.map (fun (_,x,_,_) -> x) args in
    let fv = Lang_values.free_vars ~bound body in
      mk ~pos (Fun (fv,args,body))

  let mk_let ~pos (doc,replace,pat,def) body =
    mk ~pos (Let { doc ; replace ; pat ; gen = [] ; def ; body })

  let mk_rec_fun ~pos pat args body =
    let name = match pat with PVar [name] -> name | _ -> assert false in
    let bound = List.map (fun (_,x,_,_) -> x) args in
    let bound = name::bound in
    let fv = Lang_values.free_vars ~bound body in
      mk ~pos (RFun (name,fv,args,body))

  let mk_enc ~pos e =
    begin
     try
      let (_:Encoder.factory) = Encoder.get_factory e in
      ()
     with Not_found -> raise (Unsupported_format (pos, e))
    end;
    mk ~pos (Encoder e)

  (** Time intervals *)

  let time_units = [| 7*24*60*60 ; 24*60*60 ; 60*60 ; 60 ; 1 |]

  (** Given a date specified as a list of four values (whms),
    * return a date in seconds from the beginning of the week. *)
  let date ~pos =
    let to_int = function None -> 0 | Some i -> i in
    let rec aux = function
      | None::tl -> aux tl
      | [] -> raise (Parse_error (pos, "Invalid time."))
      | l ->
          let a = Array.of_list l in
          let n = Array.length a in
          let tu = time_units and tn = Array.length time_units in
            Array.fold_left (+) 0
              (Array.mapi (fun i s ->
                             let s =
                               if n=4 && i=0 then
                                 (to_int s) mod 7
                               else
                                 to_int s
                             in
                               tu.(tn-1 + i - n+1) * s) a)
    in
      aux

  (** Give the index of the first non-None value in the list. *)
  let last_index l =
    let rec last_index n = function
      | x::tl -> if x=None then last_index (n+1) tl else n
      | [] -> n
    in
      last_index 0 l

  (** Give the precision of a date-as-list.
    * For example, the precision of Xs is 1, XmYs is 60, XhYmZs 3600, etc. *)
  let precision d = time_units.(last_index d)

  (** Give the duration of a data-as-list.
   * For example, the duration of Xs is 1, Xm 60, XhYm 60, etc. *)
  let duration d =
    time_units.(Array.length time_units - 1 - last_index (List.rev d))

  let between ~pos d1 d2 =
    let p1 = precision d1 in
    let p2 = precision d2 in
    let t1 = date ~pos d1 in
    let t2 = date ~pos d2 in
      if p1<>p2 then
        raise (Parse_error (pos,
                            "Invalid time interval: precisions differ."));
      (t1,t2,p1)

  let during ~pos d =
    let t,d,p = date ~pos d, duration d, precision d in
      (t,t+d,p)

  let mk_time_pred ~pos (a,b,c) =
    let args = List.map (fun x -> "", mk ~pos (Ground (Int x))) [a;b;c] in
      mk ~pos (App (mk ~pos (Var "time_in_mod"), args))

  let mk_var_mult bin mul =
    if bin <> "+" then raise Parsing.Parse_error else
      Lang_values.type_of_mul ~pos:None ~level:(-1) (Frame.At_least mul)

  let mk_ty ~pos name args =
    match name with
      | "_" -> Lang_types.fresh_evar ~level:(-1) ~pos:None
      | "unit" -> Lang_types.make Lang_types.unit
      | "bool" -> Lang_types.make (Lang_types.Ground Lang_types.Bool)
      | "int" -> Lang_types.make (Lang_types.Ground Lang_types.Int)
      | "float" -> Lang_types.make (Lang_types.Ground Lang_types.Float)
      | "string" -> Lang_types.make (Lang_types.Ground Lang_types.String)
      | "source" | "active_source" ->
          (* TODO less confusion in hiding the stream_kind constructed type *)
          (* TODO print position in error message *)
          let audio,video,midi =
            match args with
              | ["",a;"",v;"",m] -> a,v,m
              | l when List.length l > 3 ->
                  raise (Parse_error (pos, "Invalid type parameters."))
              | l ->
                  List.iter
                    (fun (lbl,_) ->
                      if not (List.mem lbl ["audio";"video";"midi"]) then
                        raise (Parse_error (pos,
                                            "Invalid type parameters.")))
                    l ;
                  let assoc x =
                    try List.assoc x l with
                      | Not_found ->
                          Lang_types.fresh_evar ~level:(-1) ~pos:None
                  in
                    assoc "audio", assoc "video", assoc "midi"
          in
            Lang_values.source_t
              ~active:(name <> "source")
              (Lang_values.frame_kind_t audio video midi)
      | _ -> raise (Parse_error (pos, "Unknown type constructor."))

%}

%token <string> VAR
%token <string> VARLPAR
%token <string> VARLBRA
%token <string> STRING
%token <int> INT
%token <float> FLOAT
%token <bool> BOOL
%token <int option list> TIME
%token <int option list * int option list> INTERVAL
%token OGG FLAC AUDIO VIDEO FFMPEG OPUS VORBIS VORBIS_CBR VORBIS_ABR THEORA SPEEX GSTREAMER
%token WAV AVI FDKAAC MP3 MP3_VBR MP3_ABR SHINE EXTERNAL
%token EOF
%token BEGIN END REC GETS TILD QUESTION LET
%token <Doc.item * (string*string) list> DEF
%token REPLACES
%token LBAR
%token TRY CATCH DO
%token IF THEN ELSE ELSIF
%token SERVER_WAIT
%token SERVER_WRITE SERVER_READ SERVER_READCHARS SERVER_READLINE
%token LPAR RPAR COMMA SEQ SEQSEQ COLON DOT
%token LBRA RBRA LCUR RCUR
%token FUN YIELDS
%token <string> BIN0
%token <string> BIN1
%token <string> BIN2
%token <string> BIN3
%token TIMES
%token MINUS UMINUS
%token UNDERSCORE
%token NOT
%token REF GET SET
%token<string> PP_IFDEF PP_IFNDEF
%token PP_IFENCODER PP_IFNENCODER PP_ENDIF
%token PP_ENDL PP_DEF PP_DEFINE
%token <string> PP_INCLUDE
%token <string list> PP_COMMENT

%nonassoc YIELDS       /* fun x -> (x+x) */
%right SET             /* expr := (expr + expr), expr := (expr := expr) */
%nonassoc REF          /* ref (1+2) */
%left BIN0             /* ((x+(y*z))==3) or ((not a)==b) */
%left BIN1
%nonassoc NOT
%left BIN2 MINUS
%left BIN3 TIMES
%nonassoc GET          /* (!x)+2 */
%nonassoc LBAR
%left DOT


/* Read %ogg(...) as one block, shifting LPAR rather than reducing %ogg */
%nonassoc no_app
%nonassoc LPAR

%start program
%type <Lang_values.term> program

%start interactive
%type <Lang_values.term> interactive

%%

program:
  | error { raise (Parse_error ($loc, "Syntax error!")) } 
  | EOF { mk ~pos:$loc unit }
  | exprs EOF { $1 }
interactive:
  | error { raise (Parse_error ($loc, "Syntax error!")) }
  | exprs SEQSEQ { $1 }
  | EOF { raise End_of_file }

s: | {} | SEQ  {}
g: | {} | GETS {}

exprs:
  | expr s                   { $1 }
  | expr exprs               { mk ~pos:$loc (Seq ($1,$2)) }
  | expr SEQ exprs           { mk ~pos:$loc (Seq ($1,$3)) }
  | binding s                { mk_let ~pos:$loc($1) $1 (mk ~pos:$loc unit) }
  | binding exprs            { mk_let ~pos:$loc($1) $1 $2 }
  | binding SEQ exprs        { mk_let ~pos:$loc($1) $1 $3 }

/* Sequences of expressions without bindings */
exprss:
  | expr { $1 }
  | expr SEQ exprss { mk ~pos:$loc (Seq ($1,$3)) }

/* General expressions. */
expr:
  | LPAR expr COLON ty RPAR          { Lang_types.(<:) $2.Lang_values.t $4 ; $2 }
  | UMINUS FLOAT                     { mk ~pos:$loc (Ground (Float (-. $2))) }
  | UMINUS INT                       { mk ~pos:$loc (Ground (Int (- $2))) }
  | UMINUS LPAR expr RPAR            { mk ~pos:$loc (App (mk ~pos:$loc($1) (Var "~-"), ["", $3])) }
  | LPAR expr RPAR                   { $2 }
  | INT                              { mk ~pos:$loc (Ground (Int $1)) }
  | NOT expr                         { mk ~pos:$loc (App (mk ~pos:$loc($1) (Var "not"), ["", $2])) }
  | BOOL                             { mk ~pos:$loc (Ground (Bool $1)) }
  | FLOAT                            { mk ~pos:$loc (Ground (Float  $1)) }
  | STRING                           { mk ~pos:$loc (Ground (String $1)) }
  | VAR                              { mk ~pos:$loc (Var $1) }
  | varlist                          { mk ~pos:$loc (List $1) }
  | REF expr                         { mk ~pos:$loc (App (mk ~pos:$loc($1) (Var "ref"), ["", $2])) }
  | GET expr                         { mk ~pos:$loc (App (mk ~pos:$loc($1) (Invoke (mk ~pos:$loc($1) (Var "ref"), "get")), ["", $2])) }
  | expr SET expr                    { mk ~pos:$loc (App (mk ~pos:$loc($2) (Invoke (mk ~pos:$loc($1) (Var "ref"), "set")), ["", $1; "", $3])) }
  | MP3 app_opt                      { mk_enc ~pos:$loc (Lang_mp3.make_cbr $2) }
  | MP3_VBR app_opt                  { mk_enc ~pos:$loc (Lang_mp3.make_vbr $2) }
  | MP3_ABR app_opt                  { mk_enc ~pos:$loc (Lang_mp3.make_abr $2) }
  | SHINE app_opt                    { mk_enc ~pos:$loc (Lang_shine.make $2) }
  | FDKAAC app_opt                   { mk_enc ~pos:$loc (Lang_fdkaac.make $2) }
  | FLAC app_opt                     { mk_enc ~pos:$loc (Lang_flac.make $2) }
  | FFMPEG ffmpeg_opt                { mk_enc ~pos:$loc (Lang_ffmpeg.make $2) }
  | EXTERNAL app_opt                 { mk_enc ~pos:$loc (Lang_external_encoder.make $2) }
  | GSTREAMER app_opt                { mk_enc ~pos:$loc (Lang_gstreamer.make ~pos:$loc $2) }
  | WAV app_opt                      { mk_enc ~pos:$loc (Lang_wav.make $2) }
  | AVI app_opt                      { mk_enc ~pos:$loc (Lang_avi.make $2) }
  | OGG LPAR ogg_items RPAR          { mk_enc ~pos:$loc (Encoder.Ogg $3) }
  | top_level_ogg_item               { mk_enc ~pos:$loc (Encoder.Ogg [$1]) }
  | LPAR RPAR                        { mk ~pos:$loc (Tuple []) }
  | LPAR inner_tuple RPAR            { mk ~pos:$loc (Tuple $2) }
  | expr DOT LCUR record RCUR        { $4 ~pos:$loc $1 }
  | LCUR record RCUR                 { $2 ~pos:$loc (mk ~pos:$loc (Tuple [])) }
  | LCUR RCUR                        { mk ~pos:$loc (Tuple []) }
  | expr DOT VAR                     { mk ~pos:$loc (Invoke ($1, $3)) }
  | expr DOT VARLPAR app_list RPAR   { mk ~pos:$loc (App (mk ~pos:($startpos($1),$endpos($3)) (Invoke ($1, $3)), $4)) }
  | REF DOT VARLPAR app_list RPAR    { mk ~pos:$loc (App (mk ~pos:($startpos($1),$endpos($3)) (Invoke (mk ~pos:$loc($1) (Var "ref"), $3)), $4)) }
  | VARLPAR app_list RPAR            { mk ~pos:$loc (App (mk ~pos:$loc($1) (Var $1), $2)) }
  | VARLBRA expr RBRA                { mk ~pos:$loc (App (mk ~pos:$loc (Var "_[_]"), ["", mk ~pos:$loc($1) (Var $1); "", $2])) }
  | expr DOT VARLBRA expr RBRA       { mk ~pos:$loc (App (mk ~pos:$loc (Var "_[_]"), ["", mk ~pos:($startpos($1),$endpos($3)) (Invoke ($1, $3)); "", $4])) }
  | BEGIN exprs END                  { $2 }
  | FUN LPAR arglist RPAR YIELDS expr{ mk_fun ~pos:$loc $3 $6 }
  | LCUR exprss RCUR                 { mk_fun ~pos:$loc [] $2 }
  | expr LBAR expr                   { let maybe = mk ~pos:$loc($1) (Var "maybe") in
                                       let op =  mk ~pos:$loc($1) (Invoke (maybe, "case")) in
                                       let handler = mk_fun ~pos:$loc($3) [] $3 in
                                       mk ~pos:$loc (App (op, ["",$1;"",handler])) }
  | TRY exprs CATCH bindvar COLON varlist DO exprs END
                                     { let fn = mk_fun ~pos:$loc($2) [] $2 in
                                       let err_arg = ["", $4, T.fresh_evar ~level:(-1) ~pos:(Some $loc($4)), None] in
                                       let errors = mk ~pos:$loc (List $6) in
                                       let handler =  mk_fun ~pos:$loc($8) err_arg $8 in
                                       let error_module = mk ~pos:$loc($1) (Var "error") in
                                       let op = mk ~pos:$loc($1) (Invoke (error_module, "catch")) in
                                       mk ~pos:$loc (App (op, ["errors", errors; "", fn; "", handler])) }
  | TRY exprs CATCH bindvar DO exprs END { let fn = mk_fun ~pos:$loc($2) [] $2 in
                                       let err_arg = ["", $4, T.fresh_evar ~level:(-1) ~pos:(Some $loc($4)), None] in
                                       let handler = mk_fun ~pos:$loc($6) err_arg $6 in
                                       let errors = mk ~pos:$loc (List []) in
                                       let error_module = mk ~pos:$loc($1) (Var "error") in
                                       let op = mk ~pos:$loc($1) (Invoke (error_module, "catch")) in
                                       mk ~pos:$loc (App (op, ["errors", errors; "", fn; "", handler])) }
  | IF exprs THEN exprs if_elsif END { let cond = $2 in
                                       let then_b = mk_fun ~pos:($startpos($3),$endpos($4)) [] $4 in
                                       let else_b = $5 in
                                       let op = mk ~pos:$loc($1) (Var "if") in
                                       mk ~pos:$loc (App (op, ["", cond; "else", else_b; "then", then_b])) }
  | SERVER_WAIT exprs THEN exprs END { let condition = $2 in
                                       let op = mk ~pos:$loc (Var "server.wait") in
                                       let after = mk_fun ~pos:$loc($4) [] $4 in
                                       mk ~pos:$loc (App (op, ["", condition; "", after])) }
  | SERVER_WRITE expr THEN exprs END { let data = $2 in
                                       let after = mk_fun ~pos:$loc($4) [] $4 in
                                       let op = mk ~pos:$loc (Var "server.write") in
                                       mk ~pos:$loc (App (op, ["",after;"",data])) }
  | SERVER_READ expr COLON VAR THEN exprs END {
                                       let marker = $2 in
                                       let arg = mk_ty ~pos:$loc($4) "string" [] in
                                       let after = mk_fun ~pos:$loc($6) ["",$4,arg,None] $6 in
                                       let op = mk ~pos:$loc (Var "server.read") in
                                       mk ~pos:$loc (App (op, ["",after;"",marker])) }
  | SERVER_READCHARS expr COLON VAR THEN exprs END {
                                       let len = $2 in
                                       let arg = mk_ty ~pos:$loc($4) "string" [] in
                                       let after = mk_fun ~pos:$loc($6) ["",$4,arg,None] $6 in
                                       let op = mk ~pos:$loc (Var "server.readchars") in
                                       mk ~pos:$loc (App (op, ["",after;"",len])) }
  | SERVER_READLINE VAR THEN exprs END {
                                       let arg = mk_ty ~pos:$loc($4) "string" [] in
                                       let after = mk_fun ~pos:$loc($4) ["",$2,arg,None] $4 in
                                       let op = mk ~pos:$loc (Var "server.readline") in
                                       mk ~pos:$loc (App (op, ["",after])) }

  | expr BIN0 expr                 { mk ~pos:$loc (App (mk ~pos:$loc($2) (Var $2), ["",$1;"",$3])) }
  | expr BIN1 expr                 { mk ~pos:$loc (App (mk ~pos:$loc($2) (Var $2), ["",$1;"",$3])) }
  | expr BIN2 expr                 { mk ~pos:$loc (App (mk ~pos:$loc($2) (Var $2), ["",$1;"",$3])) }
  | expr BIN3 expr                 { mk ~pos:$loc (App (mk ~pos:$loc($2) (Var $2), ["",$1;"",$3])) }
  | expr TIMES expr                { mk ~pos:$loc (App (mk ~pos:$loc($2) (Var "*"), ["",$1;"",$3])) }
  | expr MINUS expr                { mk ~pos:$loc (App (mk ~pos:$loc($2) (Var "-"), ["",$1;"",$3])) }
  | INTERVAL                       { mk_time_pred ~pos:$loc (between ~pos:$loc (fst $1) (snd $1)) }
  | TIME                           { mk_time_pred ~pos:$loc (during ~pos:$loc $1) }

ty:
  | VAR                       { mk_ty ~pos:$loc $1 [] }
  | VARLPAR ty_args RPAR      { mk_ty ~pos:$loc $1 $2 }
  | REF LPAR ty RPAR          { Lang_values.ref_t ~pos:(Some $loc) $3 }
  | LBRA ty RBRA              { Lang_types.make (Lang_types.List $2) }
  | LPAR ty_tuple RPAR        { Lang_types.make (Lang_types.Tuple $2) }
  | INT                       { Lang_values.type_of_int $1 }
  | TIMES BIN2 INT            { mk_var_mult $2 $3 }
  | INT BIN2 TIMES            { mk_var_mult $2 $1 }
  | LPAR argsty RPAR YIELDS ty{ Lang_types.make (Lang_types.Arrow ($2,$5)) }

ty_tuple:
  | ty TIMES ty { [$1; $3] }
  | ty TIMES ty_tuple { $1::$3 }

ty_args:
  |                      { [] }
  | ty_arg               { [$1] }
  | ty_arg COMMA ty_args { $1::$3 }

ty_arg:
  | ty { "",$1 }
  | VAR GETS ty { $1,$3 }

argty:
  | ty                    { false,"",$1 }
  | VAR COLON ty          { false,$1,$3 }
  | QUESTION VAR COLON ty { true,$2,$4 }

argsty:
  |                    { [] }
  | argty              { [$1] }
  | argty COMMA argsty { $1::$3 }

varlist:
  | LBRA inner_list RBRA { $2 }
inner_list:
  | expr COMMA inner_list  { $1::$3 }
  | expr                   { [$1] }
  |                        { [] }

inner_tuple:
  | expr COMMA expr { [$1;$3] }
  | expr COMMA inner_tuple { $1::$3 }

app_list_elem:
  | VAR GETS expr { $1,$3 }
  | expr          { "",$1 }
app_list:
  |                              { [] }
  | app_list_elem                { [$1] }
  | app_list_elem COMMA app_list { $1::$3 }

bindvar:
  | VAR { $1 }
  | UNDERSCORE { "_" }

pattern:
  | bindvar { PVar [$1] }
  | LPAR pattern_list RPAR { PTuple $2 }

subfield:
  | VAR DOT in_subfield { $1::$3 }

in_subfield:
  | VAR { [$1] }
  | VAR DOT in_subfield { $1::$3 }

pattern_list:
  | pattern COMMA pattern { [$1;$3] }
  | pattern COMMA pattern_list { $1::$3 }

binding:
  | bindvar GETS expr { (Doc.none (),[]),false,PVar [$1],$3 }
  | LET replaces pattern GETS expr { (Doc.none (),[]),$2,$3,$5 }
  | LET replaces subfield GETS expr { (Doc.none (),[]),$2,PVar $3,$5 }
  | DEF replaces pattern g exprs END {
      let body = $5 in
      $1,$2,$3,body
    }
  | DEF replaces varlpar arglist RPAR g exprs END {
      let arglist = $4 in
      let body = mk_fun ~pos:$loc arglist $7 in
      $1,$2,PVar $3,body
        }
  /* We don't handle recursive fields for now... */
  | DEF REC VARLPAR arglist RPAR g exprs END {
      let doc = $1 in
      let pat = PVar [$3] in
      let arglist = $4 in
      let body = mk_rec_fun ~pos:$loc pat arglist $7 in
      doc,false,pat,body
    }

replaces:
  | { false }
  | REPLACES { true }

varlpar:
  | VARLPAR         { [$1] }
  | VAR DOT varlpar { $1::$3 }
  | REF DOT varlpar { "ref"::$3 }

arglist:
  |                   { [] }
  | arg               { [$1] }
  | arg COMMA arglist { $1::$3 }
arg:
  | TILD VAR opt { $2, $2, T.fresh_evar ~level:(-1) ~pos:(Some $loc($2)), $3 }
  | TILD VAR GETS UNDERSCORE opt { $2, "_", T.fresh_evar ~level:(-1) ~pos:(Some $loc($2)), $5 }
  | bindvar opt  { "", $1, T.fresh_evar ~level:(-1) ~pos:(Some $loc($1)), $2 }
opt:
  | GETS expr { Some $2 }
  |           { None }

if_elsif:
  | ELSIF exprs THEN exprs if_elsif { let cond = $2 in
                                      let then_b = mk_fun ~pos:($startpos($3), $endpos($4)) [] $4 in
                                      let else_b = $5 in
                                      let op = mk ~pos:$loc($1) (Var "if") in
                                      mk_fun ~pos:$loc [] (mk ~pos:$loc (App (op,["",cond; "else",else_b; "then",then_b]))) }
  | ELSE exprs                      { mk_fun ~pos:($startpos($1),$endpos($2)) [] $2 }
  |                                 { mk_fun ~pos:$loc [] (mk ~pos:$loc unit) }


app_opt:
  | %prec no_app { [] }
  | LPAR app_list RPAR { $2 }

ogg_items:
  | ogg_item { [$1] }
  | ogg_item COMMA ogg_items { $1::$3 }
top_level_ogg_item:
  | VORBIS app_opt     { Lang_vorbis.make $2 }
  | VORBIS_CBR app_opt { Lang_vorbis.make_cbr $2 }
  | VORBIS_ABR app_opt { Lang_vorbis.make_abr $2 }
  | THEORA app_opt     { Lang_theora.make $2 }
  | SPEEX app_opt      { Lang_speex.make $2 }
  | OPUS app_opt       { Lang_opus.make $2 }
ogg_item:
  | FLAC app_opt       { Lang_flac.make_ogg $2 }
  | top_level_ogg_item { $1 }

ffmpeg_param:
  | STRING GETS expr { $1,$3 }
  | VAR GETS expr        { $1,$3 }
ffmpeg_params:
  |                                  { [] }
  | ffmpeg_param                     { [$1] }
  | ffmpeg_param COMMA ffmpeg_params { $1::$3 }

ffmpeg_list_elem:
  | AUDIO LPAR ffmpeg_params RPAR { `Audio  $3 }
  | VIDEO LPAR ffmpeg_params RPAR { `Video  $3 }
  | ffmpeg_param                  { `Option $1 }
ffmpeg_list:
  |                                    { [] }
  | ffmpeg_list_elem                   { [$1] }
  | ffmpeg_list_elem COMMA ffmpeg_list { $1::$3 }

ffmpeg_opt:
  | %prec no_app { [] }
  | LPAR ffmpeg_list RPAR { $2 }

record:
  | VAR GETS expr { fun ~pos e -> mk ~pos (Meth ($1, $3, e)) }
  | record COMMA VAR GETS expr { fun ~pos e -> mk ~pos (Meth ($3, $5, $1 ~pos e)) }
