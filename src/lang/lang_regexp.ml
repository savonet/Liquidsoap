type regexp = Builtins_regexp.regexp

let regexp_t = Builtins_regexp.RegExp.t
let to_regexp = Builtins_regexp.RegExp.of_value
let regexp = Builtins_regexp.RegExp.to_value
let descr_of_regexp { Builtins_regexp.descr; _ } = descr
let string_of_regexp = Builtins_regexp.string_of_regexp

module Regexp = struct
  type sub = Regexp.sub = {
    matches : string option list;
    groups : (string * string) list;
  }

  let get_rex = Option.map (fun { Builtins_regexp.regexp } -> regexp)

  let regexp ?(flags = []) s =
    { Builtins_regexp.descr = s; flags; regexp = Regexp.regexp s }

  let regexp_or ?(flags = []) l =
    {
      Builtins_regexp.descr = String.concat "|" l;
      flags;
      regexp = Regexp.regexp_or ~flags l;
    }

  let split ?pat ?rex = Regexp.split ?pat ?rex:(get_rex rex)
  let exec ?pat ?rex = Regexp.exec ?pat ?rex:(get_rex rex)
  let test ?pat ?rex = Regexp.test ?pat ?rex:(get_rex rex)
  let substitute ?pat ?rex = Regexp.substitute ?pat ?rex:(get_rex rex)

  let substitute_first ?pat ?rex =
    Regexp.substitute_first ?pat ?rex:(get_rex rex)
end
