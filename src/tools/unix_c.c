#include <caml/alloc.h>
#include <caml/misc.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <caml/memory.h>
#include <locale.h>
#include <stdio.h>
#include <stddef.h>
#include <time.h>
#include <errno.h>

#ifdef WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

/* Some libraries mess with locale. In OCaml, locale should always
 * be "C", otherwise float_of_string and other functions do not behave
 * as expected. This issues arises in particular when using telnet 
 * commands that need floats and when loading modules in bytecode mode.. */
CAMLprim value liquidsoap_set_locale(value unit)
{
  /* This will prevent further call to setlocale to override
   * "C" */
#ifdef WIN32
  putenv("LANG=C");
  putenv("LC_ALL=C");
#else
  setenv("LANG","C",1);
  setenv("LC_ALL","C",1);
#endif
  /* This set the locale to "C". */
  setlocale (LC_ALL, "C");
  return Val_unit;
}

CAMLprim value liquidsoap_get_timezone() {
  tzset();
  return Val_long(timezone);
}

CAMLprim value liquidsoap_get_timezone_by_name() {
  CAMLparam0();
  CAMLlocal1(ret);
  tzset();
  ret = caml_alloc_tuple(2);
  Store_field(ret, 0, caml_copy_string(tzname[0]));
  Store_field(ret, 1, caml_copy_string(tzname[1]));
  CAMLreturn(ret);
}

CAMLprim value liquidsoap_mktime(value _tm) {
  CAMLparam1(_tm);
  struct tm tm;
  time_t time;

  tm.tm_sec = Int_val(Field(_tm, 0));
  tm.tm_min = Int_val(Field(_tm, 1));
  tm.tm_hour = Int_val(Field(_tm, 2));
  tm.tm_mday = Int_val(Field(_tm, 3));
  tm.tm_mon = Int_val(Field(_tm, 4));
  tm.tm_year = Int_val(Field(_tm, 5));
  tm.tm_wday = 0;
  tm.tm_yday = 0;
  tm.tm_isdst = Field(_tm, 6) == Val_int(0) ? -1 : Bool_val(Field(Field(_tm, 6), 0));
  time = mktime(&tm);
  if (time == -1) unix_error(ERANGE, "mktime", Nothing);

  CAMLreturn(caml_copy_double((double)time));
}

CAMLprim value liquidsoap_get_pagesize() {
#ifdef WIN32
  SYSTEM_INFO systemInfo;
  GetSystemInfo(&systemInfo);
  return Val_int(systemInfo.dwPageSize);
#else
  return Val_int(getpagesize());
#endif
}
