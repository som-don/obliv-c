// Original from c-torture
#include <varargs.h>

#include "testharness.h"

typedef double TYPE;

void vafunction (dummy1, dummy2, va_alist)
  TYPE dummy1, dummy2;
  va_dcl
{
  va_list ap;

  va_start(ap);
  if (dummy1 != 888.) exit(1);
  if (dummy2 != 999.) exit(2);
  if (va_arg (ap, TYPE) != 1.) exit(3);
  if (va_arg (ap, TYPE) != 2.) exit(4);
  if (va_arg (ap, TYPE) != 3.) exit(5);
  if (va_arg (ap, TYPE) != 4.) exit(6);
  if (va_arg (ap, TYPE) != 5.) exit(7);
  if (va_arg (ap, TYPE) != 6.) exit(8);
  if (va_arg (ap, TYPE) != 7.) exit(9);
  if (va_arg (ap, TYPE) != 8.) exit(10);
  if (va_arg (ap, TYPE) != 9.) exit(11);
  va_end(ap);
}


int main (void)
{
  vafunction( 888., 999., 1., 2., 3., 4., 5., 6., 7., 8., 9. );

  SUCCESS;
}
