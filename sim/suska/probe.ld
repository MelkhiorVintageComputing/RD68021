/* The probe's image: vectors at 0, code at $400. */
SECTIONS
{
  . = 0;
  .vectors : { *(.vectors) }
  . = 0x400;
  .text : { *(.text) }
}
